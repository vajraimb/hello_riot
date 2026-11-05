open Std
open Std.Collections
open Std.Net

(**
   Nomad — Industrial HTTP/1.1 & RFC 6455 WebSocket Server over Atacama
   (Equivalent to Elixir's Bandit + Plug/Trail on Riot's Actor Runtime)
*)

type ws_callbacks = {
  on_open: TcpStream.t -> int -> unit;
  on_frame: TcpStream.t -> int -> Trail.Ws.frame -> Atacama.outcome;
  on_close: int -> unit;
}

type conn_mode =
  | HttpMode of string
  | WsMode of {
      buffer: string;
      callbacks: ws_callbacks;
    }

let find_header_end = fun buf ->
  let len = String.length buf in
  let rec loop i =
    if i + 3 >= len then
      None
    else if
      Char.equal (String.get_unchecked buf ~at:i) '\r'
      && Char.equal (String.get_unchecked buf ~at:(i + 1)) '\n'
      && Char.equal (String.get_unchecked buf ~at:(i + 2)) '\r'
      && Char.equal (String.get_unchecked buf ~at:(i + 3)) '\n'
    then
      Some i
    else
      loop (i + 1)
  in
  loop 0

let parse_request_line = fun line ->
  let parts = String.split ~by:" " (String.trim line) in
  match parts with
  | meth_str :: target :: _ ->
      let method_ = Http.Method.from_string meth_str in
      let full_url =
        if String.starts_with ~prefix:"http://" target || String.starts_with ~prefix:"https://" target then
          target
        else if String.starts_with ~prefix:"/" target then
          "http://localhost" ^ target
        else
          "http://localhost/" ^ target
      in
      let uri =
        match Uri.from_string full_url with
        | Ok u -> u
        | Error _ -> Uri.from_string "http://localhost/" |> Result.unwrap
      in
      Ok (method_, uri)
  | _ -> Error "malformed HTTP request line"

let parse_headers = fun lines ->
  List.fold_left
    lines
    ~init:Http.Header.empty
    ~fn:(fun hdrs line ->
      let trimmed = String.trim line in
      if String.is_empty trimmed then
        hdrs
      else
        match String.index_of trimmed ~char:':' with
        | None -> hdrs
        | Some idx ->
            let name = String.sub trimmed ~offset:0 ~len:idx |> String.trim in
            let value =
              String.sub
                trimmed
                ~offset:(idx + 1)
                ~len:(String.length trimmed - idx - 1)
              |> String.trim
            in
            Http.Header.add hdrs name value)

(** Try to parse a complete HTTP/1.1 request from [buf], returning [(req, rest)] if complete. *)
let try_parse_http_request = fun buf ->
  match find_header_end buf with
  | None -> Ok None
  | Some header_end_idx -> (
      let header_block = String.sub buf ~offset:0 ~len:header_end_idx in
      let body_start = header_end_idx + 4 in
      let raw_lines = String.split ~by:"\r\n" header_block in
      match raw_lines with
      | [] -> Error "empty HTTP request"
      | req_line :: header_lines -> (
          match parse_request_line req_line with
          | Error e -> Error e
          | Ok (method_, uri) ->
              let headers = parse_headers header_lines in
              let content_len =
                match Http.Header.get headers "content-length" with
                | None -> 0
                | Some s ->
                    Int.from_string_opt (String.trim s) |> Option.unwrap_or ~default:0
              in
              let total_needed = body_start + content_len in
              let buf_len = String.length buf in
              if buf_len < total_needed then
                Ok None
              else
                let body_str = String.sub buf ~offset:body_start ~len:content_len in
                let remaining =
                  String.sub buf ~offset:total_needed ~len:(buf_len - total_needed)
                in
                let base_req =
                  Http.Request.create method_ uri
                  |> fun r -> Http.Request.with_headers r headers
                in
                let req =
                  if content_len > 0 then
                    Http.Request.with_body base_req body_str
                  else
                    base_req
                in
                Ok (Some (req, remaining))
        )
    )

let serialize_response = fun ?(keep_alive = true) resp ->
  let status = Http.Response.status resp in
  let status_code = Http.Status.to_int status in
  let reason = Http.Status.reason_phrase status in
  let body_str = Http.Response.body_string resp |> Option.unwrap_or ~default:"" in
  let body_len = String.length body_str in
  let conn_val =
    if keep_alive then
      "keep-alive"
    else
      "close"
  in
  let headers =
    Http.Response.headers resp
    |> fun h -> Http.Header.set h "Content-Length" (Int.to_string body_len)
    |> fun h -> Http.Header.set h "Connection" conn_val
  in
  let header_lines =
    Http.Header.to_list headers
    |> List.map ~fn:(fun (k, v) -> k ^ ": " ^ v ^ "\r\n")
    |> String.concat ""
  in
  "HTTP/1.1 "
  ^ Int.to_string status_code
  ^ " "
  ^ reason
  ^ "\r\n"
  ^ header_lines
  ^ "\r\n"
  ^ body_str

let write_all_raw = fun stream payload ->
  let buf = IO.Bytes.from_string payload in
  let total = IO.Bytes.length buf in
  let rec loop pos =
    if pos >= total then
      Ok ()
    else
      match TcpStream.write stream buf ~pos ~len:(total - pos) () with
      | Ok 0 -> Error "client closed connection"
      | Ok n -> loop (pos + n)
      | Error _ -> Error "failed writing HTTP response"
  in
  loop 0

let rec process_ws_frames = fun stream conn_id callbacks buf ->
  match Trail.Ws.try_decode_frame buf with
  | None -> Ok (Atacama.Continue, WsMode { buffer = buf; callbacks })
  | Some (frame, rest) -> (
      match frame with
      | Trail.Ws.Close ->
          let _ = Trail.Ws.send_close stream in
          Ok (Atacama.Close, WsMode { buffer = rest; callbacks })
      | Trail.Ws.Ping payload ->
          let _ = Trail.Ws.send_pong stream payload in
          process_ws_frames stream conn_id callbacks rest
      | _ -> (
          match callbacks.on_frame stream conn_id frame with
          | Atacama.Close -> Ok (Atacama.Close, WsMode { buffer = rest; callbacks })
          | Atacama.Continue -> process_ws_frames stream conn_id callbacks rest
        )
    )

let start_link = fun
  ~name
  ?(host = "127.0.0.1")
  ~port
  ?(acceptor_count = 4)
  ?(max_connections = 256)
  ~trail
  ?(ws_callbacks =
    {
      on_open = (fun _stream _id -> ());
      on_frame = (fun _stream _id _frame -> Atacama.Continue);
      on_close = (fun _id -> ());
    })
  () ->
  let module HttpHandler : Atacama.Handler = struct
    type state = conn_mode

    let init = fun (_ctx : Atacama.conn_context) -> HttpMode ""

    let handle_connection = fun (_ctx : Atacama.conn_context) state ->
      Ok (Atacama.Continue, state)

    let rec handle_http_buffer = fun (ctx : Atacama.conn_context) buf ->
      match try_parse_http_request buf with
      | Error msg ->
          let bad = Http.Response.bad_request msg in
          let _ = write_all_raw ctx.stream (serialize_response ~keep_alive:false bad) in
          Ok (Atacama.Close, HttpMode "")
      | Ok None -> Ok (Atacama.Continue, HttpMode buf)
      | Ok (Some (req, rest)) -> (
          let trail_ctx =
            Telemetry.with_span
              "nomad.http.request"
              (fun _span ->
                let c0 =
                  Trail.make_ctx
                    ~req
                    ~peer:ctx.peer
                    ~conn_id:ctx.conn_id
                    ~acceptor_id:ctx.acceptor_id
                in
                trail c0)
          in
          match trail_ctx.Trail.action with
          | Some (Trail.UpgradeWs custom_init) -> (
              match Http.Request.get_header req "sec-websocket-key" with
              | None ->
                  let bad = Http.Response.bad_request "Missing Sec-WebSocket-Key" in
                  let _ =
                    write_all_raw ctx.stream (serialize_response ~keep_alive:false bad)
                  in
                  Ok (Atacama.Close, HttpMode "")
              | Some ws_key ->
                  let accept_key = Trail.Ws.compute_accept_key ws_key in
                  let handshake =
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    ^ "Upgrade: websocket\r\n"
                    ^ "Connection: Upgrade\r\n"
                    ^ "Sec-WebSocket-Accept: "
                    ^ accept_key
                    ^ "\r\n\r\n"
                  in
                  (
                    match write_all_raw ctx.stream handshake with
                    | Error e -> Error e
                    | Ok () ->
                        ws_callbacks.on_open ctx.stream ctx.conn_id;
                        custom_init ctx.stream accept_key;
                        process_ws_frames ctx.stream ctx.conn_id ws_callbacks rest
                  )
            )
          | Some (Trail.RespondStream handler) ->
              (* Write head without Content-Length (close-delimited body),
                 then hand the raw stream to the handler which writes body
                 bytes directly; close the connection afterwards. *)
              let extra_headers =
                List.map
                  trail_ctx.Trail.resp_headers
                  ~fn:(fun (k, v) -> k ^ ": " ^ v ^ "\r\n")
                |> String.concat ""
              in
              let head =
                "HTTP/1.1 200 OK\r\n"
                ^ extra_headers
                ^ "Connection: close\r\n\r\n"
              in
              (
                match write_all_raw ctx.stream head with
                | Error e -> Error e
                | Ok () -> (
                    match handler ctx.stream with
                    | Ok () -> Ok (Atacama.Close, HttpMode "")
                    | Error e -> Error e
                  )
              )
          | Some (Trail.Respond resp) -> (
              let conn_hdr =
                Http.Request.get_header req "connection"
                |> Option.map ~fn:String.lowercase_ascii
                |> Option.unwrap_or ~default:"keep-alive"
              in
              let keep_alive = not (String.contains conn_hdr "close") in
              let wire = serialize_response ~keep_alive resp in
              match write_all_raw ctx.stream wire with
              | Error e -> Error e
              | Ok () ->
                  if keep_alive then
                    if String.is_empty rest then
                      Ok (Atacama.Continue, HttpMode "")
                    else
                      handle_http_buffer ctx rest
                  else
                    Ok (Atacama.Close, HttpMode "")
            )
          | None ->
              let not_found = Http.Response.not_found "Not Found" in
              let _ =
                write_all_raw ctx.stream (serialize_response ~keep_alive:true not_found)
              in
              Ok (Atacama.Continue, HttpMode rest)
        )

    let handle_data = fun (ctx : Atacama.conn_context) chunk state ->
      match state with
      | HttpMode prev -> handle_http_buffer ctx (prev ^ chunk)
      | WsMode { buffer; callbacks } ->
          process_ws_frames ctx.stream ctx.conn_id callbacks (buffer ^ chunk)

    let handle_close = fun (ctx : Atacama.conn_context) state ->
      match state with
      | HttpMode _ -> ()
      | WsMode { callbacks; _ } -> callbacks.on_close ctx.conn_id
  end in
  Atacama.start_link
    ~name
    ~host
    ~port
    ~acceptor_count
    ~max_connections
    (module HttpHandler)
    ()
