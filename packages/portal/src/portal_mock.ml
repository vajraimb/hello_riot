open Std

module Atacama = Hello_riot.Atacama

(** Programmable mock OpenAI-compatible server for tests and local spikes.

    Runs on Atacama (raw HTTP written by hand) with a runtime-swappable
    scenario stored in an atomic cell, so tests can simulate: 200 JSON, 429,
    5xx, SSE streams, latency, and — critically — a mid-stream connection cut
    (quota-exhausted upstream death) via [cut_after_bytes]. *)

type scenario = {
  status: int;
  body: string;
  sse: string list;
  cut_after_bytes: int;
  delay_ms: int;
}

let default_scenario =
  { status = 200; body = "{}"; sse = []; cut_after_bytes = 0; delay_ms = 0 }

type t = {
  pool: Atacama.pool;
  scenario: scenario Sync.Atomic.t;
}

let set_scenario = fun t scenario -> Sync.Atomic.set t.scenario scenario

let stop = fun t -> Atacama.stop t.pool

let reason_phrase = function
  | 200 -> "OK"
  | 400 -> "Bad Request"
  | 401 -> "Unauthorized"
  | 402 -> "Payment Required"
  | 404 -> "Not Found"
  | 429 -> "Too Many Requests"
  | 500 -> "Internal Server Error"
  | 502 -> "Bad Gateway"
  | 503 -> "Service Unavailable"
  | _ -> "Status"

let status_line = fun code ->
  "HTTP/1.1 " ^ Int.to_string code ^ " " ^ reason_phrase code ^ "\r\n"

let hex_of_int = fun n ->
  let digits = "0123456789abcdef" in
  if n = 0 then
    "0"
  else
    let rec go acc n =
      if n = 0 then
        acc
      else
        go (String.from_char (String.get_unchecked digits ~at:(n land 15)) ^ acc) (n lsr 4)
    in
    go "" n

let chunked_frame = fun payload ->
  hex_of_int (String.length payload) ^ "\r\n" ^ payload ^ "\r\n"

let stream_header = fun code ->
  status_line code
  ^ "Content-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"

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

let write_raw = fun stream payload ->
  let buf = IO.Bytes.from_string payload in
  let total = IO.Bytes.length buf in
  let rec loop pos =
    if pos >= total then
      Ok ()
    else
      match Net.TcpStream.write stream buf ~pos ~len:(total - pos) () with
      | Ok 0 -> Error "mock: socket closed during write"
      | Ok n -> loop (pos + n)
      | Error _ -> Error "mock: socket write failed"
  in
  loop 0

let start = fun ?(host = "127.0.0.1") ?(port = 0) () ->
  let scenario = Sync.Atomic.make default_scenario in
  let module H : Atacama.Handler = struct
    type state = {
      buf: string;
    }

    let init = fun (_ctx : Atacama.conn_context) -> { buf = "" }

    let handle_connection = fun (_ctx : Atacama.conn_context) state ->
      Ok (Atacama.Continue, state)

    let handle_close = fun (_ctx : Atacama.conn_context) _state -> ()

    let handle_data = fun (ctx : Atacama.conn_context) chunk state ->
      let buf = state.buf ^ chunk in
      match find_header_end buf with
      | None -> Ok (Atacama.Continue, { buf })
      | Some _idx ->
          let sc = Sync.Atomic.get scenario in
          if sc.delay_ms > 0 then sleep (Time.Duration.from_millis sc.delay_ms);
          let written = ref 0 in
          (* Cut-aware write: when [cut_after_bytes] is set, at most the
             remaining allowance is written and [Cut] is reported, so the
             connection can die mid-frame — exactly like an upstream that
             runs out of quota in the middle of an SSE event. *)
          let write_counted payload =
            if
              sc.cut_after_bytes > 0
              && !written + String.length payload >= sc.cut_after_bytes
            then
              let allow = sc.cut_after_bytes - !written in
              if allow <= 0 then
                Ok `Cut
              else
                let prefix = String.sub payload ~offset:0 ~len:allow in
                (
                  match write_raw ctx.stream prefix with
                  | Error e -> Error e
                  | Ok () ->
                      written := !written + allow;
                      Ok `Cut
                )
            else
              match write_raw ctx.stream payload with
              | Error e -> Error e
              | Ok () ->
                  written := !written + String.length payload;
                  Ok `More
          in
          let result =
            if not (List.is_empty sc.sse) then (
              match write_counted (stream_header sc.status) with
              | Error e -> Error e
              | Ok _ ->
                  let rec emit = function
                    | [] -> (
                        (* normal stream termination, OpenAI-style *)
                        match write_counted (chunked_frame "data: [DONE]\n\n") with
                        | Error e -> Error e
                        | Ok `Cut -> Ok ()
                        | Ok `More -> (
                            match write_counted "0\r\n\r\n" with
                            | Error e -> Error e
                            | Ok _ -> Ok ()
                          )
                      )
                    | ev :: rest -> (
                        match write_counted (chunked_frame ("data: " ^ ev ^ "\n\n")) with
                        | Error e -> Error e
                        | Ok `Cut -> Ok ()
                        | Ok `More -> emit rest
                      )
                  in
                  emit sc.sse
            ) else
              let body = sc.body in
              write_counted
                (status_line sc.status
                ^ "Content-Type: application/json\r\nContent-Length: "
                ^ Int.to_string (String.length body)
                ^ "\r\nConnection: close\r\n\r\n"
                ^ body)
              |> fun res ->
              (match res with
               | Error e -> Error e
               | Ok _ -> Ok ())
          in
          (* NOTE: never close the socket here — returning [Atacama.Close]
             makes the connection actor's finalize close it exactly once. A
             manual close here would double-close the fd and, after fd reuse,
             randomly kill unrelated sockets. *)
          (
            match result with
            | Error e -> Error e
            | Ok () -> Ok (Atacama.Close, { buf = "" })
          )
  end in
  match
    Atacama.start_link
      ~name:"portal_mock"
      ~host
      ~port
      ~acceptor_count:2
      ~max_connections:64
      (module H)
      ()
  with
  | Error e -> Error e
  | Ok pool -> Ok { pool; scenario }
