open Std
open Std.Collections

(** Oasis gateway: OpenAI-compatible HTTP front (Nomad/Trail) with real-time
    scored routing (KB fit × cost × latency EMA × load, weights from the
    goal), explainable decisions, cost ledger, SSE streaming, and seamless
    mid-stream handoff to a fallback account when the upstream dies or runs
    out of quota. Outbound I/O runs on dedicated blocking lanes
    (Runtime.spawn_blocked). *)

module Trail = Hello_riot.Trail
module Json = Std.Data.Json
open Portal_state
open Portal_ws
open Portal_upstream
open Portal_decisions
open Portal_conductor
open Portal_exec_agent
open Portal_exec_account
open Portal_api
open Portal_mcp_tools
open Portal_http

let parse_base_url = Portal_upstream.parse_base_url

let percent_decode = Portal_state.percent_decode

let hash8 = Portal_state.hash8

let start = fun ~config_path ?(config : Portal_config.t option) ~port () ->
  let config =
    match config with
    | Some c -> Ok c
    | None -> (
        match config_path with
        | None -> Error "no config"
        | Some p -> Portal_config.load p
      )
  in
  match config with
  | Error e -> Error e
  | Ok config
    when (not (Portal_config.is_loopback_host config.Portal_config.server_host))
         && Option.is_none (Portal_config.auth_token config) ->
      Error
        ("server.host = "
        ^ config.Portal_config.server_host
        ^ " is not loopback: set server.auth_token_env to an environment variable holding a token")
  | Ok config ->
      let state =
        {
          config_path;
          config = Sync.Atomic.make config;
          ledger =
            Portal_ledger.init
              ~data_dir:config.Portal_config.data_dir
              ();
          decisions = Agent.start ~fn:(fun () -> []);
          signals = Portal_signals.init ();
          sessions = Portal_session.init ();
          tasks = Portal_task.init ();
          inbox = Portal_inbox.init ~dir:(config.Portal_config.data_dir ^ "/inbox");
          ws_clients = ConcurrentHashMap.with_capacity ~size:64;
          decision_history = Sync.Atomic.make [];
          decisions_appended = Sync.Atomic.make 0;
          feed = Portal_feed.create ();
          quality = Portal_quality.create ();
          route_turns = Sync.Atomic.make 0;
          running = ConcurrentHashMap.with_capacity ~size:64;
          threads = Portal_thread.create ();
        }
      in
      load_decision_history state;
      let _ = Portal_inbox.load state.inbox in
      Portal_signals.load_parked state.signals ~path:(parked_file state);
      Portal_signals.load_latency state.signals ~path:(data_path state "latency.json");
      Portal_quality.load state.quality ~path:(quality_file state);
      Portal_thread.load state.threads ~path:(threads_file state);
      Portal_judge.start state;
      if
        String.equal config.Portal_config.policy.Portal_config.goal "cheapest"
        && not (Portal_router.cost_routing_effective config)
      then
        eprintln
          "[oasis] WARN: policy.goal = \"cheapest\" but fewer than two [[models]] have prices; cost routing is ineffective";
      let _ =
        Portal_agent_worker.start
          ~agents:config.Portal_config.agents
          ()
      in
      let ws_callbacks : Hello_riot.Nomad.ws_callbacks =
        {
          on_open =
            (fun stream conn_id ->
              let _ = ConcurrentHashMap.insert state.ws_clients ~key:conn_id ~value:stream in
              ());
          on_frame = (fun _stream _conn_id _frame -> Hello_riot.Atacama.Continue);
          on_close =
            (fun conn_id ->
              let _ = ConcurrentHashMap.remove state.ws_clients ~key:conn_id in
              ());
        }
      in
      Hello_riot.Nomad.start_link
        ~name:"oasis_gateway"
        ~host:config.Portal_config.server_host
        ~port
        ~acceptor_count:4
        ~max_connections:256
        ~trail:(build_trail state)
        ~ws_callbacks
        ()
