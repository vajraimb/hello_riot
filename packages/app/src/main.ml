open Std
open Std.Collections

module Aegis = Hello_riot.Aegis_otp
module Atacama = Hello_riot.Atacama
module Trail = Hello_riot.Trail

let print_supervision_banner = fun (cluster : Aegis.cluster) ->
  println "======================================================================";
  println "  AegisOTP — Riot Industrial OTP Stack (Atacama + Nomad + Trail)";
  println "======================================================================";
  println
    (
      "  [ShardSupervisor]  PID="
      ^ Pid.to_string (Supervisor.to_pid cluster.shard_sup)
      ^ " (Strategy: OneForOne, Shards: "
      ^ Int.to_string cluster.num_shards
      ^ ")"
    );
  List.for_each
    (Supervisor.which_children cluster.shard_sup)
    ~fn:(fun (c : Supervisor.child_info) ->
      let pid_str =
        Option.map c.pid ~fn:Pid.to_string |> Option.unwrap_or ~default:"stopped"
      in
      println ("    |- " ^ c.id ^ " -> Actor PID=" ^ pid_str ^ " [Permanent]"));
  println
    (
      "  [Atacama TCP Pool] Listen=127.0.0.1:"
      ^ Int.to_string cluster.tcp_pool.port
      ^ " | AcceptorSup="
      ^ Pid.to_string (Supervisor.to_pid cluster.tcp_pool.acceptor_sup)
      ^ " | DynamicConnSup="
      ^ Pid.to_string (Supervisor.Dynamic.to_pid cluster.tcp_pool.conn_sup)
    );
  println
    (
      "  [Nomad Web/WS]     Listen=http://127.0.0.1:"
      ^ Int.to_string cluster.http_pool.port
      ^ " | AcceptorSup="
      ^ Pid.to_string (Supervisor.to_pid cluster.http_pool.acceptor_sup)
      ^ " | DynamicConnSup="
      ^ Pid.to_string (Supervisor.Dynamic.to_pid cluster.http_pool.conn_sup)
    );
  println "----------------------------------------------------------------------";
  println ("  Web Control Plane : http://127.0.0.1:" ^ Int.to_string cluster.http_pool.port ^ "/");
  println ("  OTP Tree REST API : http://127.0.0.1:" ^ Int.to_string cluster.http_pool.port ^ "/api/otp/tree");
  println ("  WebSocket Stream  : ws://127.0.0.1:" ^ Int.to_string cluster.http_pool.port ^ "/ws");
  println ("  Atacama TCP CLI   : nc 127.0.0.1 " ^ Int.to_string cluster.tcp_pool.port);
  println "======================================================================"

let verify_tcp_and_http_clients = fun ~tcp_port ~http_port ->
  let tcp_addr = Net.Addr.tcp Net.Addr.loopback tcp_port in
  (
    match Net.TcpStream.connect tcp_addr with
    | Error _ -> println "[Self-Test] TCP client connect failed"
    | Ok stream ->
        let buf = IO.Bytes.create ~size:2048 in
        let _ = Net.TcpStream.read stream buf () in
        let cmd = IO.Bytes.from_string "PING\r\nQUIT\r\n" in
        let _ = Net.TcpStream.write stream cmd ~pos:0 ~len:(IO.Bytes.length cmd) () in
        (
          match Net.TcpStream.read stream buf () with
          | Ok n when n > 0 ->
              let reply = IO.Bytes.sub_string buf ~offset:0 ~len:n |> String.trim in
              println ("[Self-Test] Atacama TCP Reply: " ^ reply)
          | _ -> ()
        );
        Net.TcpStream.close stream
  );
  let http_addr = Net.Addr.tcp Net.Addr.loopback http_port in
  match Net.TcpStream.connect http_addr with
  | Error _ -> println "[Self-Test] HTTP client connect failed"
  | Ok stream ->
      let req =
        IO.Bytes.from_string
          "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      in
      let _ = Net.TcpStream.write stream req ~pos:0 ~len:(IO.Bytes.length req) () in
      let buf = IO.Bytes.create ~size:4096 in
      (
        match Net.TcpStream.read stream buf () with
        | Ok n when n > 0 ->
            let resp = IO.Bytes.sub_string buf ~offset:0 ~len:n in
            let first_line =
              String.split ~by:"\r\n" resp
              |> List.head
              |> Option.unwrap_or ~default:""
            in
            println ("[Self-Test] Nomad HTTP Status: " ^ first_line)
        | _ -> ()
      );
      Net.TcpStream.close stream

let rec keep_alive_forever = fun () ->
  sleep (Time.Duration.from_secs 60);
  keep_alive_forever ()

let main ~args =
  let is_self_test =
    List.any args ~fn:(fun a -> String.equal a "--self-test")
  in
  let tcp_port =
    if is_self_test then
      19110
    else
      9110
  in
  let http_port =
    if is_self_test then
      19880
    else
      9880
  in
  match Aegis.start ~host:"127.0.0.1" ~tcp_port ~http_port ~num_shards:4 () with
  | Error err ->
      eprintln ("Failed to start AegisOTP: " ^ err);
      Error (Failure err)
  | Ok cluster ->
      print_supervision_banner cluster;
      if is_self_test then (
        verify_tcp_and_http_clients ~tcp_port ~http_port;
        let _ = Aegis.kv_set cluster ~key:"smoke:key" ~value:"smoke_ok" in
        let (old_pid, new_pid, old_e, new_e) =
          Aegis.crash_shard_and_await_recovery
            cluster
            ~shard_id:1
            ~reason:"self-test fault injection"
        in
        println
          (
            "[Self-Test] Shard #1 crashed & self-healed: "
            ^ old_pid
            ^ " (epoch "
            ^ Int.to_string old_e
            ^ ") -> "
            ^ new_pid
            ^ " (epoch "
            ^ Int.to_string new_e
            ^ ")"
          );
        let (elapsed_us, digests) =
          Aegis.run_workpool_batch ~tasks_count:4 ~iterations:500
        in
        println
          (
            "[Self-Test] WorkerPool completed "
            ^ Int.to_string (List.length digests)
            ^ " parallel tasks in "
            ^ Int.to_string elapsed_us
            ^ " us"
          );
        Aegis.stop cluster;
        Ok ()
      ) else
        keep_alive_forever ()

let () = Runtime.run ~main ~args:Env.args ()
