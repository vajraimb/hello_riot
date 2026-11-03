open Std
open Std.Collections
open Std.Net

(**
   Trail — Composable HTTP/1.1 & RFC 6455 WebSocket Pipeline, Router & Codec
   (Equivalent to Elixir's Plug + WebSock on Riot's Actor Runtime)
*)

module Ws = struct
  type frame =
    | Text of string
    | Binary of string
    | Ping of string
    | Pong of string
    | Close

  let websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  let compute_accept_key = fun client_key ->
    let combined = String.trim client_key ^ websocket_guid in
    let sha1_hash = Crypto.Sha1.hash_string combined in
    Crypto.Digest.base64 sha1_hash

  let encode_frame = fun ~opcode payload ->
    let len = String.length payload in
    let b0 = Char.from_int_unchecked (0x80 lor (opcode land 0x0F)) in
    let header =
      if len < 126 then
        String.from_char b0 ^ String.from_char (Char.from_int_unchecked len)
      else if len < 65536 then
        String.from_char b0
        ^ String.from_char (Char.from_int_unchecked 126)
        ^ String.from_char (Char.from_int_unchecked ((len lsr 8) land 0xFF))
        ^ String.from_char (Char.from_int_unchecked (len land 0xFF))
      else
        String.from_char b0
        ^ String.from_char (Char.from_int_unchecked 127)
        ^ String.make ~len:4 ~char:(Char.from_int_unchecked 0)
        ^ String.from_char (Char.from_int_unchecked ((len lsr 24) land 0xFF))
        ^ String.from_char (Char.from_int_unchecked ((len lsr 16) land 0xFF))
        ^ String.from_char (Char.from_int_unchecked ((len lsr 8) land 0xFF))
        ^ String.from_char (Char.from_int_unchecked (len land 0xFF))
    in
    header ^ payload

  let write_raw = fun stream data ->
    let buf = IO.Bytes.from_string data in
    let total = IO.Bytes.length buf in
    let rec loop pos =
      if pos >= total then
        Ok ()
      else
        match TcpStream.write stream buf ~pos ~len:(total - pos) () with
        | Ok 0 -> Error "websocket closed"
        | Ok n -> loop (pos + n)
        | Error _ -> Error "websocket write error"
    in
    loop 0

  let send_text = fun stream text -> write_raw stream (encode_frame ~opcode:0x1 text)

  let send_pong = fun stream payload -> write_raw stream (encode_frame ~opcode:0xA payload)

  let send_close = fun stream -> write_raw stream (encode_frame ~opcode:0x8 "")

  (** Decode one RFC 6455 frame from a raw byte buffer, returning (frame, remaining_bytes) if complete. *)
  let try_decode_frame = fun buf ->
    let total = String.length buf in
    if total < 2 then
      None
    else
      let b0 = Char.code (String.get_unchecked buf ~at:0) in
      let b1 = Char.code (String.get_unchecked buf ~at:1) in
      let opcode = b0 land 0x0F in
      let masked = (b1 land 0x80) != 0 in
      let len7 = b1 land 0x7F in
      let (payload_len, header_offset) =
        if len7 < 126 then
          (len7, 2)
        else if len7 = 126 then
          if total < 4 then
            (-1, 4)
          else
            let hi = Char.code (String.get_unchecked buf ~at:2) in
            let lo = Char.code (String.get_unchecked buf ~at:3) in
            ((hi lsl 8) lor lo, 4)
        else if total < 10 then
          (-1, 10)
          else
            let b6 = Char.code (String.get_unchecked buf ~at:6) in
            let b7 = Char.code (String.get_unchecked buf ~at:7) in
            let b8 = Char.code (String.get_unchecked buf ~at:8) in
            let b9 = Char.code (String.get_unchecked buf ~at:9) in
            ((b6 lsl 24) lor (b7 lsl 16) lor (b8 lsl 8) lor b9, 10)
      in
      if payload_len < 0 then
        None
      else
        let mask_len =
          if masked then
            4
          else
            0
        in
        let frame_total = header_offset + mask_len + payload_len in
        if total < frame_total then
          None
        else
          let payload_start = header_offset + mask_len in
          let payload =
            if masked then
              String.init
                ~len:payload_len
                ~fn:(fun i ->
                  let raw_byte = Char.code (String.get_unchecked buf ~at:(payload_start + i)) in
                  let mask_byte =
                    Char.code (String.get_unchecked buf ~at:(header_offset + (i mod 4)))
                  in
                  Char.from_int_unchecked (raw_byte lxor mask_byte))
            else
              String.sub buf ~offset:payload_start ~len:payload_len
          in
          let rest = String.sub buf ~offset:frame_total ~len:(total - frame_total) in
          let frame =
            match opcode with
            | 0x1 -> Text payload
            | 0x2 -> Binary payload
            | 0x8 -> Close
            | 0x9 -> Ping payload
            | 0xA -> Pong payload
            | _ -> Text payload
          in
          Some (frame, rest)
end

type action =
  | Respond of Http.Response.t
  | UpgradeWs of (TcpStream.t -> string -> unit)
  | RespondStream of (TcpStream.t -> (unit, string) result)

type ctx = {
  req: Http.Request.t;
  peer: Addr.stream_addr;
  conn_id: int;
  acceptor_id: int;
  assigns: (string * string) list;
  resp_headers: (string * string) list;
  halted: bool;
  action: action option;
}

type t = ctx -> ctx

let make_ctx = fun ~req ~peer ~conn_id ~acceptor_id ->
  {
    req;
    peer;
    conn_id;
    acceptor_id;
    assigns = [];
    resp_headers = [];
    halted = false;
    action = None;
  }

let assign = fun ctx ~key ~value ->
  { ctx with assigns = (key, value) :: ctx.assigns }

let get_assign = fun ctx ~key ->
  List.find ctx.assigns ~fn:(fun (k, _) -> String.equal k key)
  |> Option.map ~fn:(fun (_, v) -> v)

let put_resp_header = fun ctx ~name ~value ->
  { ctx with resp_headers = (name, value) :: ctx.resp_headers }

let apply_resp_headers = fun ctx resp ->
  List.fold_left
    ctx.resp_headers
    ~init:resp
    ~fn:(fun acc (k, v) -> Http.Response.with_header acc k v)

let send_resp = fun ctx resp ->
  let final_resp = apply_resp_headers ctx resp in
  { ctx with halted = true; action = Some (Respond final_resp) }

let json = fun ?(status = Http.Status.Ok) ctx body_json ->
  let payload = Data.Json.to_string body_json in
  let resp =
    Http.Response.create status
    |> fun r -> Http.Response.with_header r "Content-Type" "application/json; charset=utf-8"
    |> fun r -> Http.Response.with_body r payload
  in
  send_resp ctx resp

let html = fun ?(status = Http.Status.Ok) ctx body_html ->
  let resp =
    Http.Response.create status
    |> fun r -> Http.Response.with_header r "Content-Type" "text/html; charset=utf-8"
    |> fun r -> Http.Response.with_body r body_html
  in
  send_resp ctx resp

let text = fun ?(status = Http.Status.Ok) ctx body_text ->
  let resp =
    Http.Response.create status
    |> fun r -> Http.Response.with_header r "Content-Type" "text/plain; charset=utf-8"
    |> fun r -> Http.Response.with_body r body_text
  in
  send_resp ctx resp

let upgrade_websocket = fun ctx handler ->
  { ctx with halted = true; action = Some (UpgradeWs handler) }

(** Streaming response (SSE): the handler receives the raw client stream and
    writes response body bytes directly. The server writes status line +
    headers (with [Connection: close]) before invoking the handler, and closes
    the connection afterwards. *)
let stream = fun ctx handler ->
  let ctx' =
    ctx
    |> put_resp_header ~name:"Content-Type" ~value:"text/event-stream; charset=utf-8"
    |> put_resp_header ~name:"Cache-Control" ~value:"no-cache"
  in
  { ctx' with halted = true; action = Some (RespondStream handler) }

let pipeline = fun middlewares ctx0 ->
  List.fold_left
    middlewares
    ~init:ctx0
    ~fn:(fun ctx mw ->
      if ctx.halted then
        ctx
      else
        mw ctx)

let use_server_header = fun server_name ctx ->
  put_resp_header ctx ~name:"Server" ~value:server_name
  |> put_resp_header
    ~name:"X-OTP-Acceptor"
    ~value:("acceptor_" ^ Int.to_string ctx.acceptor_id)
  |> put_resp_header ~name:"X-OTP-Conn-Id" ~value:(Int.to_string ctx.conn_id)

let use_cors = fun () ctx ->
  ctx
  |> put_resp_header ~name:"Access-Control-Allow-Origin" ~value:"*"
  |> put_resp_header ~name:"Access-Control-Allow-Methods" ~value:"GET, POST, OPTIONS"
  |> put_resp_header ~name:"Access-Control-Allow-Headers" ~value:"Content-Type"

type route = {
  method_: Http.Method.t option;
  path: string;
  handler: t;
}

let get = fun path handler -> { method_ = Some Http.Method.Get; path; handler }

let post = fun path handler -> { method_ = Some Http.Method.Post; path; handler }

let ws = fun path ws_handler ->
  {
    method_ = Some Http.Method.Get;
    path;
    handler = (fun ctx -> upgrade_websocket ctx ws_handler);
  }

let router = fun routes ctx ->
  let req_method = Http.Request.method_ ctx.req in
  let req_path = Uri.path (Http.Request.uri ctx.req) in
  if Http.Method.equal req_method Http.Method.Options then
    send_resp ctx (Http.Response.no_content ())
  else
    let matched =
      List.find
        routes
        ~fn:(fun r ->
          let method_ok =
            match r.method_ with
            | None -> true
            | Some m -> Http.Method.equal m req_method
          in
          method_ok && String.equal r.path req_path)
    in
    match matched with
    | Some route -> route.handler ctx
    | None ->
        json
          ~status:Http.Status.NotFound
          ctx
          (Data.Json.obj
            [
              ("error", Data.Json.string "route_not_found");
              ("path", Data.Json.string req_path);
              ("method", Data.Json.string (Http.Method.to_string req_method));
            ])
