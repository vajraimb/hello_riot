open Std
open Std.Collections

module Aegis = Hello_riot.Aegis_otp
module Trail = Hello_riot.Trail

let test_starter_greeting = fun _ctx ->
  Test.assert_equal ~expected:"Hello from hello_riot" ~actual:(Hello_riot.hello ());
  Ok ()

let test_fibonacci = fun _ctx ->
  Test.assert_equal ~expected:0 ~actual:(Hello_riot.fib 0);
  Test.assert_equal ~expected:1 ~actual:(Hello_riot.fib 1);
  Test.assert_equal ~expected:1 ~actual:(Hello_riot.fib 2);
  Test.assert_equal ~expected:55 ~actual:(Hello_riot.fib 10);
  Ok ()

let test_websocket_rfc6455_accept_key = fun _ctx ->
  (* Standard RFC 6455 test vector *)
  let client_key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let accept = Trail.Ws.compute_accept_key client_key in
  Test.assert_equal ~expected:"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" ~actual:accept;
  Ok ()

let test_websocket_frame_roundtrip = fun _ctx ->
  let encoded = Trail.Ws.encode_frame ~opcode:0x1 "hello-otp-ws" in
  match Trail.Ws.try_decode_frame encoded with
  | Some (Trail.Ws.Text decoded, rest) ->
      Test.assert_equal ~expected:"hello-otp-ws" ~actual:decoded;
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

let test_worker_pool_sha256_batch = fun _ctx ->
  let (_elapsed_us, digests) =
    Aegis.run_workpool_batch ~tasks_count:4 ~iterations:100
  in
  Test.assert_equal ~expected:4 ~actual:(List.length digests);
  Ok ()

let test_concurrency_demo = fun _ctx ->
  let report = Hello_riot.Concurrency_demo.run_all () in
  Test.assert_equal ~expected:true ~actual:(not (String.is_empty report));
  Ok ()

let tests =
  Test.[
    case "starter greeting" test_starter_greeting;
    case "fibonacci sequence" test_fibonacci;
    case "RFC 6455 WebSocket Sec-WebSocket-Accept key computation" test_websocket_rfc6455_accept_key;
    case "RFC 6455 WebSocket frame encode and decode roundtrip" test_websocket_frame_roundtrip;
    case "Trail middleware pipeline and router dispatch" test_trail_pipeline_and_router;
    case "AegisOTP multi-core WorkerPool SHA-256 batch" test_worker_pool_sha256_batch;
    case "ConcurrencyDemo: ring + supervisor + workerpool + hashmap" test_concurrency_demo;
  ]

let main ~args =
  Test.Cli.main ~name:"hello_riot_tests" ~tests ~args ()

let () = Runtime.run ~main ~args:Env.args ()
