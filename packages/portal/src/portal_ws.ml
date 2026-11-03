open Std
open Std.Collections

(** Dashboard WebSocket fan-out and raw client-stream writes. *)

module Trail = Hello_riot.Trail
module Json = Std.Data.Json

open Portal_state

let broadcast_json = fun (state : state) (payload : Json.t) ->
  let text = Json.to_string payload in
  let dead = ref [] in
  ConcurrentHashMap.for_each
    state.ws_clients
    ~fn:(fun conn_id stream ->
      match Hello_riot.Trail.Ws.send_text stream text with
      | Ok () -> ()
      | Error _ -> dead := conn_id :: !dead);
  List.for_each !dead ~fn:(fun conn_id ->
    let _ = ConcurrentHashMap.remove state.ws_clients ~key:conn_id in
    ())

let broadcast_event = fun (state : state) ~(type_ : string) ~(request_id : string) ~(data : Json.t) ->
  broadcast_json
    state
    (Json.obj
      [
        ("type", Json.string "event");
        ("event", Json.string type_);
        ("request_id", Json.string request_id);
        ("data", data);
      ])

let write_stream = fun stream payload ->
  let buf = IO.Bytes.from_string payload in
  let total = IO.Bytes.length buf in
  let rec loop pos =
    if pos >= total then
      Ok ()
    else
      match Net.TcpStream.write stream buf ~pos ~len:(total - pos) () with
      | Ok 0 -> Error "client closed connection"
      | Ok n -> loop (pos + n)
      | Error _ -> Error "client write failed"
  in
  loop 0
