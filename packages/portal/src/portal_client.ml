open Std

(** Minimal HTTP/1.1 client over plain TCP or TLS (transport-agnostic via
    IO.Reader/IO.Writer). Supports Content-Length, chunked, and close-delimited
    response bodies. All socket I/O must be driven from a blocking lane
    ([Runtime.spawn_blocked]) or from plain tests. *)

type error =
  | Connect_failed of string
  | Tls_failed of string
  | Write_failed of string
  | Read_failed of string
  | Bad_response of string
  | Too_large

let error_to_string = function
  | Connect_failed s -> "connect_failed: " ^ s
  | Tls_failed s -> "tls_failed: " ^ s
  | Write_failed s -> "write_failed: " ^ s
  | Read_failed s -> "read_failed: " ^ s
  | Bad_response s -> "bad_response: " ^ s
  | Too_large -> "response head exceeded 64KiB"

type conn = {
  reader: IO.Reader.t;
  writer: IO.Writer.t;
  close: unit -> unit;
}

type request = {
  method_: string;
  path: string;
  headers: (string * string) list;
  body: string;
}

type response = {
  status: int;
  reason: string;
  headers: (string * string) list;
}

type body_reader = {
  read_some: unit -> (string, error) result;
  read_all: unit -> (string, error) result;
}

let close = fun conn -> conn.close ()

let make_request = fun ~method_ ~path ?(headers = []) ?(body = "") () ->
  { method_; path; headers; body }

let serialize_request = fun (req : request) ->
  let has_host =
    List.any req.headers ~fn:(fun (k, _) ->
      String.equal (String.lowercase_ascii k) "host")
  in
  let headers =
    if has_host then req.headers else ("Host", "localhost") :: req.headers
  in
  let header_lines =
    List.map headers ~fn:(fun (k, v) -> k ^ ": " ^ v ^ "\r\n") |> String.concat ""
  in
  req.method_ ^ " " ^ req.path ^ " HTTP/1.1\r\n"
  ^ header_lines
  ^ "Content-Length: "
  ^ Int.to_string (String.length req.body)
  ^ "\r\n\r\n"
  ^ req.body

let connect_plain = fun (addr : Net.Addr.stream_addr) ->
  match Net.TcpStream.connect addr with
  | Error _ ->
      Error
        (Connect_failed
          (Net.Addr.ip addr ^ ":" ^ Int.to_string (Net.Addr.port addr)))
  | Ok tcp ->
      Ok
        {
          reader = Net.TcpStream.to_reader tcp;
          writer = Net.TcpStream.to_writer tcp;
          close = (fun () -> Net.TcpStream.close tcp);
        }

let connect_tls = fun ~hostname (addr : Net.Addr.stream_addr) ->
  match Net.TcpStream.connect addr with
  | Error _ ->
      Error (Connect_failed (hostname ^ ":" ^ Int.to_string (Net.Addr.port addr)))
  | Ok tcp -> (
      match Net.TlsStream.from_tcp_client ~hostname tcp with
      | Error _ ->
          Net.TcpStream.close tcp;
          Error (Tls_failed ("TLS handshake with " ^ hostname ^ " failed"))
      | Ok tls ->
          Ok
            {
              reader = Net.TlsStream.to_reader tls;
              writer = Net.TlsStream.to_writer tls;
              close = (fun () -> Net.TcpStream.close tcp);
            }
    )

let send_request = fun conn (req : request) ->
  match IO.write_all conn.writer ~from:(IO.Buffer.from_string (serialize_request req)) with
  | Ok () -> Ok ()
  | Error e -> Error (Write_failed (IO.error_message e))

let find_sub = fun s ~pattern ->
  let n = String.length s in
  let m = String.length pattern in
  if m = 0 then
    Some 0
  else
    let rec loop i =
      if i + m > n then
        None
      else
        let rec eq j =
          if j >= m then
            true
          else if
            Char.equal
              (String.get_unchecked s ~at:(i + j))
              (String.get_unchecked pattern ~at:j)
          then
            eq (j + 1)
          else
            false
        in
        if eq 0 then Some i else loop (i + 1)
    in
    loop 0

let parse_response_head = fun head ->
  match String.split ~by:"\r\n" head with
  | [] -> Error (Bad_response "empty response head")
  | status_line :: header_lines -> (
      let parts =
        String.split ~by:" " status_line
        |> List.filter ~fn:(fun s -> not (String.is_empty s))
      in
      match parts with
      | _version :: code_str :: reason_parts ->
          (match Int.from_string_opt code_str with
           | None -> Error (Bad_response ("unparseable status line: " ^ status_line))
           | Some status ->
               let headers =
                 List.filter_map
                   header_lines
                   ~fn:(fun line ->
                     match String.index_of line ~char:':' with
                     | None -> None
                     | Some idx ->
                         let k =
                           String.sub line ~offset:0 ~len:idx
                           |> String.trim
                           |> String.lowercase_ascii
                         in
                         let v =
                           String.sub
                             line
                             ~offset:(idx + 1)
                             ~len:(String.length line - idx - 1)
                           |> String.trim
                         in
                         Some (k, v))
               in
               Ok
                 {
                   status;
                   reason = String.concat " " reason_parts;
                   headers;
                 })
      | _ -> Error (Bad_response ("malformed status line: " ^ status_line))
    )

let get_header = fun (resp : response) name ->
  let lower = String.lowercase_ascii name in
  List.find resp.headers ~fn:(fun (k, _) -> String.equal k lower)
  |> Option.map ~fn:(fun (_, v) -> v)

let read_response_head = fun conn ->
  let read_buf = IO.Buffer.create ~size:4096 in
  let rec loop acc =
    if String.length acc > 65536 then
      Error Too_large
    else
      match find_sub acc ~pattern:"\r\n\r\n" with
      | Some idx ->
          let head = String.sub acc ~offset:0 ~len:idx in
          let rest =
            String.sub acc ~offset:(idx + 4) ~len:(String.length acc - idx - 4)
          in
          (match parse_response_head head with
           | Error e -> Error e
           | Ok resp -> Ok (resp, rest))
      | None -> (
          match IO.read conn.reader ~into:read_buf with
          | Ok n when n > 0 ->
              let chunk = IO.Buffer.contents read_buf in
              IO.Buffer.clear read_buf;
              loop (acc ^ chunk)
          | Ok _ | Error IO.End_of_file ->
              Error (Read_failed "connection closed before response head")
          | Error e -> Error (Read_failed (IO.error_message e))
        )
  in
  loop ""

type body_mode =
  | Content_length of int
  | Chunked
  | Close_delimited

let body_mode = fun (resp : response) ->
  match get_header resp "transfer-encoding" with
  | Some te when String.contains (String.lowercase_ascii te) "chunked" ->
      Chunked
  | _ -> (
      match get_header resp "content-length" with
      | Some s -> (
          match Int.from_string_opt (String.trim s) with
          | Some n when n > 0 -> Content_length n
          | _ -> Close_delimited)
      | None -> Close_delimited
    )

let make_body_reader = fun conn (resp : response) leftover ->
  let read_buf = IO.Buffer.create ~size:8192 in
  let mode = body_mode resp in
  match mode with
  | Content_length n ->
      let pending = ref leftover in
      let remaining = ref n in
      let rec pull () =
        if not (String.is_empty !pending) then
          Ok true
        else
          match IO.read conn.reader ~into:read_buf with
          | Ok k when k > 0 ->
              pending := IO.Buffer.contents read_buf;
              IO.Buffer.clear read_buf;
              Ok true
          | Ok _ | Error IO.End_of_file -> Ok false
          | Error e -> Error (Read_failed (IO.error_message e))
      in
      let read_some () =
        if !remaining <= 0 then
          Ok ""
        else
          match pull () with
          | Error e -> Error e
          | Ok false -> Ok ""
          | Ok true ->
              let take = min !remaining (String.length !pending) in
              let out = String.sub !pending ~offset:0 ~len:take in
              pending :=
                String.sub !pending ~offset:take ~len:(String.length !pending - take);
              remaining := !remaining - take;
              Ok out
      in
      let read_all () =
        let acc = ref "" in
        let rec loop () =
          match read_some () with
          | Error e -> Error e
          | Ok "" -> Ok !acc
          | Ok s ->
              acc := !acc ^ s;
              loop ()
        in
        loop ()
      in
      Ok { read_some; read_all }
  | Close_delimited ->
      let pending = ref leftover in
      let read_some () =
        if not (String.is_empty !pending) then
          let out = !pending in
          pending := "";
          Ok out
        else
          match IO.read conn.reader ~into:read_buf with
          | Ok k when k > 0 ->
              let out = IO.Buffer.contents read_buf in
              IO.Buffer.clear read_buf;
              Ok out
          | Ok _ | Error IO.End_of_file -> Ok ""
          | Error e -> Error (Read_failed (IO.error_message e))
      in
      let read_all () =
        let acc = ref "" in
        let rec loop () =
          match read_some () with
          | Error e -> Error e
          | Ok "" -> Ok !acc
          | Ok s ->
              acc := !acc ^ s;
              loop ()
        in
        loop ()
      in
      Ok { read_some; read_all }
  | Chunked ->
      let decoder = ref Portal_chunked.init in
      let done_ = ref false in
      let out_queue = ref [] in
      (match
        if String.is_empty leftover then
          Ok ()
        else
          match Portal_chunked.feed !decoder leftover with
          | Error e -> Error (Bad_response e)
          | Ok (More (pieces, d)) ->
              decoder := d;
              out_queue := pieces;
              Ok ()
          | Ok (Done (pieces, d)) ->
              decoder := d;
              done_ := true;
              out_queue := pieces;
              Ok ()
      with
      | Error e -> Error e
      | Ok () ->
          let rec fill () =
            if List.is_empty !out_queue && not !done_ then
              match IO.read conn.reader ~into:read_buf with
              | Ok k when k > 0 ->
                  let chunk = IO.Buffer.contents read_buf in
                  IO.Buffer.clear read_buf;
                  (
                    match Portal_chunked.feed !decoder chunk with
                    | Error e -> Error (Bad_response e)
                    | Ok (More (pieces, d)) ->
                        decoder := d;
                        out_queue := pieces;
                        (* a read may deliver only a fragment (TLS record
                           boundaries); keep reading until we can emit
                           something or the body ends *)
                        if List.is_empty !out_queue && not !done_ then
                          fill ()
                        else
                          Ok ()
                    | Ok (Done (pieces, d)) ->
                        decoder := d;
                        done_ := true;
                        out_queue := pieces;
                        Ok ()
                  )
              | Ok _ | Error IO.End_of_file ->
                  if !done_ then
                    Ok ()
                  else
                    Error (Read_failed "EOF before end of chunked body")
              | Error e -> Error (Read_failed (IO.error_message e))
            else
              Ok ()
          in
          let read_some () =
            match fill () with
            | Error e -> Error e
            | Ok () -> (
                match !out_queue with
                | [] -> Ok ""
                | piece :: rest ->
                    out_queue := rest;
                    Ok piece
              )
          in
          let read_all () =
            let acc = ref "" in
            let rec loop () =
              match read_some () with
              | Error e -> Error e
              | Ok "" -> Ok !acc
              | Ok s ->
                  acc := !acc ^ s;
                  loop ()
            in
            loop ()
          in
          Ok { read_some; read_all })

(** Send a request and return the parsed response head plus a body reader. *)
let request = fun conn (req : request) ->
  match send_request conn req with
  | Error e -> Error e
  | Ok () -> (
      match read_response_head conn with
      | Error e -> Error e
      | Ok (resp, leftover) -> (
          match make_body_reader conn resp leftover with
          | Error e -> Error e
          | Ok body -> Ok (resp, body)
        )
    )

(** Send a request and read the entire body into a string. *)
let request_string = fun conn (req : request) ->
  match request conn req with
  | Error e -> Error e
  | Ok (resp, body) -> (
      match body.read_all () with
      | Error e -> Error e
      | Ok s -> Ok (resp, s)
    )
