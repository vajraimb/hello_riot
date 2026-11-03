open Std
open Std.Collections

(**
   Atacama — Industrial OTP Socket Connection Pool & Acceptor Supervision Tree
   (Equivalent to Elixir's ThousandIsland / Erlang's Ranch on Riot's Actor Runtime)

   Architecture:
   - [EndpointSupervisor] (RestForOne):
     1. [ConnectionSupervisor] (Supervisor.Dynamic): isolates and supervises active
        client connection actors (Temporary restart strategy, bounded by [max_connections]).
     2. [AcceptorSupervisor] (Supervisor OneForOne): supervises [acceptor_count] permanent
        acceptor actors sharing a non-blocking [Net.TcpListener.t].
*)

type outcome =
  | Continue
  | Close

type metrics = {
  accepted_total: int;
  active_connections: int;
  rejected_max_conn: int;
  acceptor_restarts: int;
  bytes_in: int;
  bytes_out: int;
  handler_crashes: int;
}

type conn_context = {
  conn_id: int;
  acceptor_id: int;
  peer: Net.Addr.stream_addr;
  stream: Net.TcpStream.t;
}

module type Handler = sig
  type state

  val init: conn_context -> state

  val handle_connection: conn_context -> state -> (outcome * state, string) result

  val handle_data:
    conn_context ->
    string ->
    state ->
    (outcome * state, string) result

  val handle_close: conn_context -> state -> unit
end

type pool = {
  name: string;
  host: string;
  port: int;
  acceptor_count: int;
  max_connections: int;
  listener: Net.TcpListener.t;
  conn_sup: Supervisor.Dynamic.t;
  acceptor_sup: Supervisor.t;
  metrics_agent: metrics Agent.t;
  next_conn_id: int Sync.Cell.t;
}

let initial_metrics = fun () ->
  {
    accepted_total = 0;
    active_connections = 0;
    rejected_max_conn = 0;
    acceptor_restarts = 0;
    bytes_in = 0;
    bytes_out = 0;
    handler_crashes = 0;
  }

let write_all = fun pool stream payload ->
  let buf = IO.Bytes.from_string payload in
  let total = IO.Bytes.length buf in
  let rec loop pos =
    if pos >= total then (
      Agent.cast
        pool.metrics_agent
        ~fn:(fun m -> { m with bytes_out = m.bytes_out + total });
      Ok ()
    ) else
      match Net.TcpStream.write stream buf ~pos ~len:(total - pos) () with
      | Ok 0 -> Error "socket closed during write"
      | Ok n -> loop (pos + n)
      | Error _ -> Error "socket write failed"
  in
  loop 0

let get_metrics = fun pool -> Agent.get pool.metrics_agent ~fn:(fun m -> m)

let record_bytes_out = fun pool count ->
  Agent.cast
    pool.metrics_agent
    ~fn:(fun m -> { m with bytes_out = m.bytes_out + count })

let run_connection_actor = fun
  (type s)
  (module H : Handler with type state = s)
  pool
  (ctx : conn_context)
  () ->
  let state0 = H.init ctx in
  let finalize state =
    (
      try H.handle_close ctx state with
      | _ -> ()
    );
    Net.TcpStream.close ctx.stream;
    Agent.cast
      pool.metrics_agent
      ~fn:(fun m ->
        let next_active =
          if m.active_connections > 0 then
            m.active_connections - 1
          else
            0
        in
        { m with active_connections = next_active })
  in
  let read_buf = IO.Bytes.create ~size:8192 in
  let rec read_loop state =
    match Net.TcpStream.read ctx.stream read_buf () with
    | Error _ ->
        finalize state;
        Ok ()
    | Ok 0 ->
        finalize state;
        Ok ()
    | Ok n -> (
        let chunk = IO.Bytes.sub_string read_buf ~offset:0 ~len:n in
        Agent.cast
          pool.metrics_agent
          ~fn:(fun m -> { m with bytes_in = m.bytes_in + n });
        let step_result =
          try H.handle_data ctx chunk state with
          | exn -> Error (Exception.to_string exn)
        in
        match step_result with
        | Ok (Continue, next_state) -> read_loop next_state
        | Ok (Close, next_state) ->
            finalize next_state;
            Ok ()
        | Error reason ->
            Agent.cast
              pool.metrics_agent
              ~fn:(fun m -> { m with handler_crashes = m.handler_crashes + 1 });
            finalize state;
            Error (Failure reason)
      )
  in
  let init_result =
    try H.handle_connection ctx state0 with
    | exn -> Error (Exception.to_string exn)
  in
  match init_result with
  | Ok (Continue, state1) -> read_loop state1
  | Ok (Close, state1) ->
      finalize state1;
      Ok ()
  | Error reason ->
      Agent.cast
        pool.metrics_agent
        ~fn:(fun m -> { m with handler_crashes = m.handler_crashes + 1 });
      finalize state0;
      Error (Failure reason)

let spawn_acceptor_loop = fun
  (type s)
  (module H : Handler with type state = s)
  ~acceptor_id
  ~listener
  ~conn_sup
  ~metrics_agent
  ~next_conn_id
  ~pool_ref
  () ->
  let rec accept_loop () =
    match Net.TcpListener.accept listener with
    | Error Net.TcpListener.Closed -> Ok ()
    | Error _ ->
        sleep (Time.Duration.from_millis 10);
        accept_loop ()
    | Ok (stream, peer) -> (
        let conn_id =
          let current = !(next_conn_id) in
          next_conn_id := current + 1;
          current
        in
        let ctx = { conn_id; acceptor_id; peer; stream } in
        match !(pool_ref) with
        | None ->
            Net.TcpStream.close stream;
            accept_loop ()
        | Some pool -> (
            let start_res =
              Supervisor.Dynamic.start_child
                conn_sup
                ~restart:Supervisor.Temporary
                ~shutdown:(Supervisor.Timeout (Time.Duration.from_secs 3))
                ~start:(fun () ->
                  spawn (run_connection_actor (module H) pool ctx))
                ()
            in
            match start_res with
            | Ok _conn_pid ->
                Agent.cast
                  metrics_agent
                  ~fn:(fun m ->
                    {
                      m with
                      accepted_total = m.accepted_total + 1;
                      active_connections = m.active_connections + 1;
                    });
                accept_loop ()
            | Error _ ->
                Agent.cast
                  metrics_agent
                  ~fn:(fun m -> { m with rejected_max_conn = m.rejected_max_conn + 1 });
                Net.TcpStream.close stream;
                accept_loop ()
          )
      )
  in
  accept_loop ()

let start_link = fun
  (type s)
  ~name
  ?(host = "127.0.0.1")
  ~port
  ?(acceptor_count = 4)
  ?(max_connections = 128)
  (module H : Handler with type state = s)
  () ->
  match Net.Addr.from_host_and_port ~host ~port with
  | Error _ -> Error ("Invalid address " ^ host ^ ":" ^ Int.to_string port)
  | Ok addr -> (
      match Net.TcpListener.bind ~reuse_addr:true ~backlog:256 addr with
      | Error _ -> Error ("Failed to bind listener on " ^ host ^ ":" ^ Int.to_string port)
      | Ok listener ->
          let actual_addr = Net.TcpListener.local_addr listener in
          let actual_port = Net.Addr.port actual_addr in
          let metrics_agent = Agent.start ~fn:initial_metrics in
          let conn_sup =
            Supervisor.Dynamic.start_link
              ~intensity:{
                max_restarts = 100;
                window = Time.Duration.from_secs 10;
              }
              ~max_children:max_connections
              ()
          in
          let next_conn_id = ref 1 in
          let pool_ref = ref None in
          let started_acceptors = ref 0 in
          let acceptor_specs =
            List.init
              ~count:acceptor_count
              ~fn:(fun idx ->
                let id = name ^ "_acceptor_" ^ Int.to_string idx in
                Supervisor.child_spec
                  ~id
                  ~restart:Supervisor.Permanent
                  ~start:(fun () ->
                    let count = !started_acceptors in
                    started_acceptors := count + 1;
                    if count >= acceptor_count then
                      Agent.cast
                        metrics_agent
                        ~fn:(fun m -> { m with acceptor_restarts = m.acceptor_restarts + 1 });
                    spawn
                      (spawn_acceptor_loop
                        (module H)
                        ~acceptor_id:idx
                        ~listener
                        ~conn_sup
                        ~metrics_agent
                        ~next_conn_id
                        ~pool_ref))
                  ())
          in
          let acceptor_sup =
            Supervisor.start_link
              ~strategy:Supervisor.OneForOne
              ~intensity:{
                max_restarts = 20;
                window = Time.Duration.from_secs 10;
              }
              ~children:acceptor_specs
              ()
          in
          let pool =
            {
              name;
              host;
              port = actual_port;
              acceptor_count;
              max_connections;
              listener;
              conn_sup;
              acceptor_sup;
              metrics_agent;
              next_conn_id;
            }
          in
          pool_ref := Some pool;
          (* Give acceptors a brief moment to register pool_ref *)
          sleep (Time.Duration.from_millis 5);
          Ok pool
    )

let stop = fun pool ->
  (* Order matters: stop the acceptors BEFORE closing the listener, so no
     actor is suspended in accept when the fd is closed underneath it (a
     close-vs-accept race that corrupts the scheduler reactor and surfaces
     as random segfaults later). *)
  Supervisor.stop pool.acceptor_sup;
  Net.TcpListener.close pool.listener;
  Agent.stop pool.metrics_agent
