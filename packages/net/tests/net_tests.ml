open Std
open Std.Collections

module Trail = Oasis_net.Trail

let test_websocket_rfc6455_accept_key = fun _ctx ->
  (* Standard RFC 6455 test vector *)
  let client_key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let accept = Trail.Ws.compute_accept_key client_key in
  Test.assert_equal ~expected:"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" ~actual:accept;
  Ok ()

let test_websocket_frame_roundtrip = fun _ctx ->
  let encoded = Trail.Ws.encode_frame ~opcode:0x1 "oasis-ws" in
  match Trail.Ws.try_decode_frame encoded with
  | Some (Trail.Ws.Text decoded, rest) ->
      Test.assert_equal ~expected:"oasis-ws" ~actual:decoded;
      Test.assert_equal ~expected:"" ~actual:rest;
      Ok ()
  | _ -> Error "Failed to decode encoded RFC 6455 text frame"

let test_trail_pipeline_and_router = fun _ctx ->
  let uri = Net.Uri.from_string "http://localhost/api/ping" |> Result.unwrap in
  let req = Net.Http.Request.get uri in
  let peer = Net.Addr.tcp Net.Addr.loopback 54321 in
  let app =
    Trail.pipeline
      [
        Trail.use_server_header "NomadTest/1.0";
        Trail.use_cors ();
        Trail.router
          [
            Trail.get
              "/api/ping"
              (fun ctx ->
                Trail.json
                  ctx
                  (Data.Json.obj [ ("pong", Data.Json.bool true) ]));
          ];
      ]
  in
  let ctx0 = Trail.make_ctx ~req ~peer ~conn_id:7 ~acceptor_id:2 in
  let ctx1 = app ctx0 in
  match ctx1.Trail.action with
  | Some (Trail.Respond resp) ->
      let status_code = Net.Http.Status.to_int (Net.Http.Response.status resp) in
      Test.assert_equal ~expected:200 ~actual:status_code;
      let srv =
        Net.Http.Response.get_header resp "Server"
        |> Option.unwrap_or ~default:""
      in
      Test.assert_equal ~expected:"NomadTest/1.0" ~actual:srv;
      Ok ()
  | _ -> Error "Expected Trail router to produce HTTP 200 response"

let tests =
  Test.[
    case "RFC 6455 WebSocket Sec-WebSocket-Accept key computation" test_websocket_rfc6455_accept_key;
    case "RFC 6455 WebSocket frame encode and decode roundtrip" test_websocket_frame_roundtrip;
    case "Trail middleware pipeline and router dispatch" test_trail_pipeline_and_router;
  ]

let main ~args =
  Test.Cli.main ~name:"net_tests" ~tests ~args ()

let () = Runtime.run ~main ~args:Env.args ()
