open Std
open Std.Collections

(** Oasis gateway: OpenAI-compatible HTTP front (Nomad/Trail) with real-time
    scored routing (KB fit × cost × latency EMA × load, weights from the
    goal), explainable decisions, cost ledger, SSE streaming, and seamless
    mid-stream handoff to a fallback account when the upstream dies or runs
    out of quota. Outbound I/O runs on dedicated blocking lanes
    (Runtime.spawn_blocked). *)

module Trail = Oasis_net.Trail
module Json = Std.Data.Json
open Oasis_state
open Oasis_ws
open Oasis_upstream
open Oasis_decisions
open Oasis_conductor
open Oasis_exec_agent
open Oasis_exec_account
open Oasis_api
open Oasis_mcp_tools
open Oasis_http

let parse_base_url = Oasis_upstream.parse_base_url

let percent_decode = Oasis_state.percent_decode

let hash8 = Oasis_state.hash8

let start = fun ~config_path ?(config : Oasis_config.t option) ~port () ->
  let config =
    match config with
    | Some c -> Ok c
    | None -> (
        match config_path with
        | None -> Error "no config"
        | Some p -> Oasis_config.load p
      )
  in
  match config with
  | Error e -> Error e
  | Ok config
    when (not (Oasis_config.is_loopback_host config.Oasis_config.server_host))
         && Option.is_none (Oasis_config.auth_token config) ->
      Error
        ("server.host = "
        ^ config.Oasis_config.server_host
        ^ " is not loopback: set server.auth_token_env to an environment variable holding a token")
  | Ok config ->
      let state =
        {
          config_path;
          config = Sync.Atomic.make config;
          ledger =
            Oasis_ledger.init
              ~data_dir:config.Oasis_config.data_dir
              ();
          decisions = Agent.start ~fn:(fun () -> []);
          signals = Oasis_signals.init ();
          sessions = Oasis_session.init ();
          tasks = Oasis_task.init ();
          inbox = Oasis_inbox.init ~dir:(config.Oasis_config.data_dir ^ "/inbox");
          ws_clients = ConcurrentHashMap.with_capacity ~size:64;
          decision_history = Sync.Atomic.make [];
          decisions_appended = Sync.Atomic.make 0;
          feed = Oasis_feed.create ();
          quality = Oasis_quality.create ();
          route_turns = Sync.Atomic.make 0;
          running = ConcurrentHashMap.with_capacity ~size:64;
          threads = Oasis_thread.create ();
        }
      in
      load_decision_history state;
      let _ = Oasis_inbox.load state.inbox in
      Oasis_signals.load_parked state.signals ~path:(parked_file state);
      Oasis_signals.load_latency state.signals ~path:(data_path state "latency.json");
      Oasis_quality.load state.quality ~path:(quality_file state);
      Oasis_thread.load state.threads ~path:(threads_file state);
      if Oasis_thread.mark_interrupted state.threads > 0 then Oasis_thread.save state.threads ~path:(threads_file state);
      Oasis_judge.start state;
      if
        String.equal config.Oasis_config.policy.Oasis_config.goal "cheapest"
        && not (Oasis_router.cost_routing_effective config)
      then
        eprintln
          "[oasis] WARN: policy.goal = \"cheapest\" but fewer than two [[models]] have prices; cost routing is ineffective";
      let _ =
        Oasis_agent_worker.start
          ~agents:config.Oasis_config.agents
          ()
      in
      let ws_callbacks : Oasis_net.Nomad.ws_callbacks =
        {
          on_open =
            (fun stream conn_id ->
              let _ = ConcurrentHashMap.insert state.ws_clients ~key:conn_id ~value:stream in
              ());
          on_frame = (fun _stream _conn_id _frame -> Oasis_net.Atacama.Continue);
          on_close =
            (fun conn_id ->
              let _ = ConcurrentHashMap.remove state.ws_clients ~key:conn_id in
              ());
        }
      in
      Oasis_net.Nomad.start_link
        ~name:"oasis_gateway"
        ~host:config.Oasis_config.server_host
        ~port
        ~acceptor_count:4
        ~max_connections:256
        ~trail:(build_trail state)
        ~ws_callbacks
        ()
