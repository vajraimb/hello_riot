open Std
open Std.Collections

module Kb = Portal.Kb
module Router = Portal.Router
module Chunked = Portal.Chunked
module Sse = Portal.Sse
module Handoff = Portal.Handoff

let mk_model = fun ~in_p ~out_p name ->
  {
    Kb.name;
    tier = 4;
    strengths = [ "coding"; "general" ];
    weaknesses = [];
    context_window = 128000;
    max_output = 8192;
    latency = Kb.Medium;
    in_price_nano = in_p;
    out_price_nano = out_p;
    cache_hit_price_nano = 10;
  }

let mk_account = fun ~models ~budget name ->
  {
    Portal.Config.name;
    provider = "bench";
    protocol = "openai";
    thinking = "disabled";
    base_url = "http://127.0.0.1:1";
    api_key_env = None;
    models;
    enabled = true;
    rpm = 0;
    tpm = 0;
    daily_limit = 0;
    monthly_budget_nano = budget;
    supports_prefill = false;
    quota_error_codes = [];
    quota_reset = "daily";
    stream_usage = false;
    connect_ip = "";
  }

let bench_config =
  {
    Portal.Config.server_host = "127.0.0.1";
    server_port = 0;
    data_dir = "./.oasis-bench-data";
    auth_token_env = None;
    agents = [];
    accounts =
      [
        mk_account ~models:[ "m-a" ] ~budget:0 "acc_a";
        mk_account ~models:[ "m-b" ] ~budget:0 "acc_b";
        mk_account ~models:[ "m-c" ] ~budget:0 "acc_c";
      ];
    kb = [ mk_model ~in_p:100 ~out_p:200 "m-a"; mk_model ~in_p:300 ~out_p:600 "m-b"; mk_model ~in_p:500 ~out_p:900 "m-c" ];
    policy =
      {
        Portal.Config.goal = "balanced";
        routes = [];
        agent_categories = [ "coding" ];
        max_fallback = 2;
        max_handoffs = 2;
        handoff_notice = true;
        session_ttl_s = 600;
        explore_every = 0;
        judge = "";
        judge_every = 10;
      };
  }

let bench_lookups =
  {
    Router.month_spent = (fun _ -> 0);
    day_requests = (fun _ -> 0);
    snapshot =
      (fun name ->
        {
          Router.latency_ema_ms = 300;
          latency_samples = 1;
          in_flight = 0;
          breaker_open = false;
          requests_in_window = 0;
          parked = false;
        });
    quality = (fun ~account:_ ~category:_ -> { Portal.Quality.sum = 0; n = 0 });
  }

let bench_task =
  { Router.category = "coding"; model = None; est_in_tokens = 500; est_out_tokens = 500 }

let bench_route_scored = fun () ->
  let _ =
    Router.route_scored bench_config bench_lookups ~goal:Router.Balanced bench_task
  in
  ()

let bench_kb_fit = fun () ->
  let m = mk_model ~in_p:100 ~out_p:200 "m-a" in
  let _ = Kb.fit m ~category:"coding" in
  ()

let bench_cost = fun () ->
  let m = mk_model ~in_p:100 ~out_p:200 "m-a" in
  let _ = Kb.est_cost_nano m ~cache_tokens:100 ~in_tokens:1000 ~out_tokens:500 in
  ()

let bench_chunked = fun () ->
  let wire = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n" in
  let rec go d =
    match Chunked.feed d wire with
    | Ok (More (_, d')) -> go d'
    | Ok (Done (_, _)) -> ()
    | Error _ -> ()
  in
  go Chunked.init

let bench_sse = fun () ->
  let wire = "data: hello\n\ndata: {\"a\":1}\n\n" in
  let (_, s) = Sse.feed Sse.init wire in
  let (_, _s') = Sse.feed s "data: bye\n\n" in
  ()

let bench_handoff_splice = fun () ->
  let sent = "0123456789" in
  let cont = sent ^ " tail-end" in
  let (_, _) =
    Handoff.feed (Handoff.init ~sent_so_far:sent) cont
  in
  ()

let bench_json_roundtrip = fun () ->
  let j =
    Std.Data.Json.obj
      [
        ("id", Std.Data.Json.string "x");
        ("choices", Std.Data.Json.array [ Std.Data.Json.int 1 ]);
      ]
  in
  let s = Std.Data.Json.to_string j in
  let _ = Std.Data.Json.from_string s in
  ()

let benchmarks =
  Bench.[
    with_config
      ~config:{ iterations = 1000; warmup = 50 }
      "route_scored: 3 accounts scored decision"
      bench_route_scored;
    with_config
      ~config:{ iterations = 5000; warmup = 100 }
      "kb: category fit score"
      bench_kb_fit;
    with_config
      ~config:{ iterations = 5000; warmup = 100 }
      "kb: nano-dollar cost estimate"
      bench_cost;
    with_config
      ~config:{ iterations = 2000; warmup = 50 }
      "chunked: decode 2-chunk stream"
      bench_chunked;
    with_config
      ~config:{ iterations = 2000; warmup = 50 }
      "sse: parse 3 events"
      bench_sse;
    with_config
      ~config:{ iterations = 5000; warmup = 100 }
      "handoff: splice continuation"
      bench_handoff_splice;
    with_config
      ~config:{ iterations = 1000; warmup = 50 }
      "json: obj roundtrip"
      bench_json_roundtrip;
  ]

let main ~args =
  Bench.Cli.main ~name:"portal_bench" ~benchmarks ~args

let () = Runtime.run ~main ~args:Env.args ()
