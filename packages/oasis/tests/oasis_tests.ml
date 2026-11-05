open Std
open Std.Collections

module Client = Oasis.Client
module Chunked = Oasis.Chunked
module Sse = Oasis.Sse
module Handoff = Oasis.Handoff
module Mock = Oasis.Mock
module Json = Std.Data.Json
module Kb = Oasis.Kb
module Config = Oasis.Config
module Ledger = Oasis.Ledger
module Router = Oasis.Router
module Signals = Oasis.Signals
module Session = Oasis.Session
module Anthropic = Oasis.Anthropic
module Agent = Oasis.Agent
module Mcp = Oasis.Mcp
module Inbox = Oasis.Inbox
module Discover = Oasis.Discover
module Classify = Oasis.Classify
module Activity = Oasis.Activity
module Gateway = Oasis.Gateway
module Setup = Oasis.Setup

let dir_seq = ref 0

(* learned latency / quality persist in data_dir: each gateway config gets
   its own so tests do not learn from each other *)
let unique_dir = fun prefix ->
  dir_seq := !dir_seq + 1;
  "./.oasis-test-data/" ^ prefix ^ "-" ^ Int.to_string (Signals.now_ms ()) ^ "-" ^ Int.to_string !dir_seq


(* ---------- chunked decoding ---------- *)

let test_chunked_single_chunk = fun _ctx ->
  match Chunked.feed Chunked.init "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n" with
  | Error e -> Error ("chunked decode failed: " ^ e)
  | Ok (Done (pieces, _d)) ->
      Test.assert_equal ~expected:["hello"; " world"] ~actual:pieces;
      Ok ()
  | Ok (More _) -> Error "expected Done"

let test_chunked_fragmented = fun _ctx ->
  let feeds = [ "5\r\nhel"; "lo\r\n6\r\n wor"; "ld\r\n0\r\n\r\n" ] in
  let rec go d acc = function
    | [] -> Error "expected Done before feeds exhausted"
    | chunk :: rest -> (
        match Chunked.feed d chunk with
        | Error e -> Error ("chunked decode failed: " ^ e)
        | Ok (More (pieces, d')) -> go d' (acc @ pieces) rest
        | Ok (Done (pieces, _d)) ->
            Test.assert_equal ~expected:["hel"; "lo"; " wor"; "ld"] ~actual:(acc @ pieces);
            Ok ()
      )
  in
  go Chunked.init [] feeds

let test_chunked_extensions = fun _ctx ->
  (* chunk extension after size, per RFC 7230 *)
  match Chunked.feed Chunked.init "3;foo=bar\r\nabc\r\n0\r\n\r\n" with
  | Error e -> Error ("chunked ext decode failed: " ^ e)
  | Ok (Done (pieces, _d)) ->
      Test.assert_equal ~expected:["abc"] ~actual:pieces;
      Ok ()
  | Ok (More _) -> Error "expected Done"

(* ---------- request / response parsing ---------- *)

let test_request_serialization = fun _ctx ->
  let req =
    Client.make_request
      ~method_:"POST"
      ~path:"/v1/chat/completions"
      ~headers:[ ("Host", "x"); ("Content-Type", "application/json") ]
      ~body:"{}"
      ()
  in
  let wire = Client.serialize_request req in
  Test.assert_equal ~expected:true ~actual:(String.contains wire "POST /v1/chat/completions HTTP/1.1");
  Test.assert_equal ~expected:true ~actual:(String.contains wire "Host: x\r\n");
  Test.assert_equal ~expected:true ~actual:(String.contains wire "Content-Length: 2\r\n\r\n{}");
  Ok ()

let test_response_head_parsing = fun _ctx ->
  let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Rate-Limit: 60\r\n" in
  match Client.parse_response_head head with
  | Error e -> Error (Client.error_to_string e)
  | Ok resp ->
      Test.assert_equal ~expected:200 ~actual:resp.Client.status;
      Test.assert_equal ~expected:"OK" ~actual:resp.Client.reason;
      Test.assert_equal
        ~expected:(Some "application/json")
        ~actual:(Client.get_header resp "Content-Type");
      Test.assert_equal
        ~expected:(Some "60")
        ~actual:(Client.get_header resp "x-rate-limit");
      Ok ()

(* ---------- SSE ---------- *)

let test_sse_aggregation = fun _ctx ->
  let (evs1, s1) = Sse.feed Sse.init "data: hello\ndata: world\n\n" in
  let (evs2, _s2) =
    Sse.feed s1 "data: {\"a\":1}\n\nevent: done\ndata: bye\n\n"
  in
  let events = evs1 @ evs2 in
  Test.assert_equal ~expected:3 ~actual:(List.length events);
  (match events with
   | [ e1; e2; e3 ] ->
       Test.assert_equal ~expected:"hello\nworld" ~actual:e1.Sse.data;
       Test.assert_equal ~expected:"{\"a\":1}" ~actual:e2.Sse.data;
       Test.assert_equal ~expected:"bye" ~actual:e3.Sse.data;
       Test.assert_equal ~expected:"done" ~actual:e3.Sse.event_type;
       Test.assert_equal ~expected:false ~actual:e3.Sse.done_sentinel;
       Ok ()
   | _ -> Error "unexpected event list")

let test_sse_done_sentinel = fun _ctx ->
  let (evs, _s) = Sse.feed Sse.init "data: [DONE]\n\n" in
  match evs with
  | [ e ] ->
      Test.assert_equal ~expected:true ~actual:e.Sse.done_sentinel;
      Ok ()
  | _ -> Error "expected one event"

let test_sse_crlf_and_comments = fun _ctx ->
  let (evs, _s) = Sse.feed Sse.init ": keepalive\r\ndata: ok\r\n\r\n" in
  match evs with
  | [ e ] ->
      Test.assert_equal ~expected:"ok" ~actual:e.Sse.data;
      Ok ()
  | _ -> Error "expected one event"

(* ---------- seamless handoff splice ---------- *)

let test_handoff_full_prefix = fun _ctx ->
  let sent = "你好世界" in
  let (fwd, _) =
    Handoff.feed (Handoff.init ~sent_so_far:sent) (sent ^ "，接下来继续写")
  in
  Test.assert_equal ~expected:"，接下来继续写" ~actual:fwd;
  Ok ()

let test_handoff_early_divergence = fun _ctx ->
  let (fwd, _) =
    Handoff.feed (Handoff.init ~sent_so_far:"abcd") "完全不同的内容"
  in
  Test.assert_equal ~expected:"完全不同的内容" ~actual:fwd;
  Ok ()

let test_handoff_partial_prefix_divergence = fun _ctx ->
  let (fwd, _) = Handoff.feed (Handoff.init ~sent_so_far:"abcd") "abXY" in
  Test.assert_equal ~expected:"XY" ~actual:fwd;
  Ok ()

let test_handoff_exact_match_forwards_nothing = fun _ctx ->
  let (fwd, _) = Handoff.feed (Handoff.init ~sent_so_far:"abcd") "abcd" in
  Test.assert_equal ~expected:"" ~actual:fwd;
  Ok ()

let test_handoff_incremental_property = fun _ctx ->
  (* Feeding the continuation in arbitrary fragments must forward the same
     total as a single feed. *)
  let sent = "0123456789" in
  let cont = sent ^ " tail-end" in
  let single =
    Handoff.feed (Handoff.init ~sent_so_far:sent) cont |> fun (fwd, _) -> fwd
  in
  let pieces = [ "0123"; "456"; "789 tail"; "-"; "end" ] in
  let rec go st acc = function
    | [] -> acc
    | p :: rest ->
        let (fwd, st') = Handoff.feed st p in
        go st' (acc ^ fwd) rest
  in
  let multi = go (Handoff.init ~sent_so_far:sent) "" pieces in
  Test.assert_equal ~expected:single ~actual:multi;
  Test.assert_equal ~expected:" tail-end" ~actual:multi;
  Ok ()


let handoff_feed_all = fun ~sent pieces ->
  let rec go st acc = function
    | [] ->
        let (last, st') = Handoff.finish st in
        let s = match last with Handoff.Forward s | Handoff.Restart_with s -> s in
        (List.rev (s :: acc), st')
    | p :: rest ->
        let (step, st') = Handoff.step st p in
        let s = match step with Handoff.Forward s | Handoff.Restart_with s -> s in
        go st' (s :: acc) rest
  in
  go (Handoff.init ~sent_so_far:sent) [] pieces

let test_handoff_utf8_mid_char_divergence = fun _ctx ->
  (* 世 = E4 B8 96 and 丢 = E4 B8 A2 share two bytes: a byte-level matcher
     would forward a stray A2 continuation byte *)
  let (pieces, st) = handoff_feed_all ~sent:"你好世界" [ "你好丢失的部分" ] in
  let out = String.concat "" pieces in
  Test.assert_equal ~expected:"丢失的部分" ~actual:out;
  Test.assert_equal ~expected:true ~actual:(Handoff.is_valid_utf8 out);
  Test.assert_equal ~expected:6 ~actual:(Handoff.matched_bytes st);
  Test.assert_equal ~expected:(Some 6) ~actual:(Handoff.diverged_at st);
  Test.assert_equal ~expected:(Some Handoff.Approximate) ~actual:(Handoff.level st);
  Ok ()

let test_handoff_utf8_split_across_feeds = fun _ctx ->
  let (pieces, _) = handoff_feed_all ~sent:"ab" [ "a"; "b\xE4"; "\xB8"; "\xA2c" ] in
  List.for_each pieces ~fn:(fun p -> Test.assert_equal ~expected:true ~actual:(Handoff.is_valid_utf8 p));
  Test.assert_equal ~expected:"丢c" ~actual:(String.concat "" pieces);
  Ok ()

let test_handoff_classify_levels = fun _ctx ->
  let level_of ~sent cont =
    let (_, st) = handoff_feed_all ~sent [ cont ] in
    Handoff.level st
  in
  (* full replay then new text *)
  Test.assert_equal ~expected:(Some Handoff.Exact) ~actual:(level_of ~sent:"abc" "abc def");
  (* direct continuation without replay *)
  Test.assert_equal ~expected:(Some Handoff.Exact) ~actual:(level_of ~sent:"The answer is" " forty-two.");
  (* drift late in the replay *)
  Test.assert_equal ~expected:(Some Handoff.Approximate) ~actual:(level_of ~sent:"Hello world, this is" "Hello there");
  (* drift early in the replay: a new answer *)
  Test.assert_equal ~expected:(Some Handoff.Restart) ~actual:(level_of ~sent:"Sure, here is the answer" "Sure! Here it is");
  (* diverges at byte 0 but opens like the original: a new answer *)
  Test.assert_equal ~expected:(Some Handoff.Restart) ~actual:(level_of ~sent:"Hello world" "hello world again");
  Test.assert_equal ~expected:"G3" ~actual:(Handoff.level_to_string Handoff.Restart);
  Ok ()

let test_handoff_restart_forwards_whole_answer = fun _ctx ->
  match Handoff.step (Handoff.init ~sent_so_far:"Sure, here is the answer") "Sure! Here it is" with
  | (Handoff.Restart_with s, _) ->
      Test.assert_equal ~expected:"Sure! Here it is" ~actual:s;
      Ok ()
  | (Handoff.Forward s, _) -> Error ("expected restart, got forward: " ^ s)

let test_handoff_undecided_head_waits = fun _ctx ->
  (* divergence at byte 0 holds output until the head window can be judged *)
  let st0 = Handoff.init ~sent_so_far:"Hello world" in
  let (s1, st1) = Handoff.step st0 "hel" in
  Test.assert_equal ~expected:true ~actual:(match s1 with Handoff.Forward "" -> true | _ -> false);
  Test.assert_equal ~expected:None ~actual:(Handoff.level st1);
  let (s2, st2) = Handoff.finish st1 in
  Test.assert_equal ~expected:true ~actual:(match s2 with Handoff.Restart_with "hel" -> true | _ -> false);
  Test.assert_equal ~expected:(Some Handoff.Restart) ~actual:(Handoff.level st2);
  Ok ()

let rand = fun bound -> match Random.int bound with Ok v -> v | Error _ -> 0

let test_handoff_random_utf8_property = fun _ctx ->
  let alphabet = [| "a"; "b"; " "; "é"; "你"; "丢"; "世"; "界"; "😀" |] in
  let rand_text n =
    String.concat "" (List.init ~count:n ~fn:(fun _ -> Array.get_unchecked alphabet ~at:(rand (Array.length alphabet))))
  in
  let rec split_random s acc =
    let len = String.length s in
    if len = 0 then List.rev acc
    else
      let k = 1 + rand len in
      split_random (String.sub s ~offset:k ~len:(len - k)) (String.sub s ~offset:0 ~len:k :: acc)
  in
  let rec round i =
    if i >= 100 then
      Ok ()
    else
      let sent_chars = 1 + rand 20 in
      let sent = rand_text sent_chars in
      let keep = rand (String.length sent + 1) in
      (* cut the replayed prefix back to a character boundary *)
      let rec boundary k =
        if k = 0 || k >= String.length sent then k
        else if Char.code (String.get_unchecked sent ~at:k) land 0xC0 = 0x80 then boundary (k - 1)
        else k
      in
      let keep = boundary keep in
      let cont = String.sub sent ~offset:0 ~len:keep ^ rand_text (rand 12) in
      let frags = split_random cont [] in
      match (try Ok (handoff_feed_all ~sent frags) with Failure m -> Error m) with
      | Error m ->
          Error (m ^ " sent=" ^ String.escaped sent ^ " frags=" ^ String.concat "|" (List.map frags ~fn:String.escaped))
      | Ok (pieces, _) ->
      if List.all pieces ~fn:Handoff.is_valid_utf8 && Handoff.is_valid_utf8 (String.concat "" pieces) then
        round (i + 1)
      else
        Error ("invalid utf-8 forwarded: sent=" ^ sent ^ " cont=" ^ cont)
  in
  round 0

(* ---------- integration: mock + client ---------- *)

let test_mid_stream_quota_death_then_seamless_continuation = fun _ctx ->
  match Mock.start () with
  | Error e -> Error ("mock start failed: " ^ e)
  | Ok mock ->
      (* Scenario A: SSE stream that dies mid-flight (quota exhausted). Cut the
         connection 3 bytes into the second chunked frame, i.e. inside its
         chunk-size line, so only the first event is fully delivered. *)
      let header_len = String.length (Mock.stream_header 200) in
      let frame1 = Mock.chunked_frame "data: ev1\n\n" in
      Mock.set_scenario
        mock
        {
          (Mock.default_scenario) with
          sse = [ "ev1"; "ev2"; "ev3" ];
          cut_after_bytes = header_len + String.length frame1 + 3;
        };
      let addr = Net.Addr.tcp Net.Addr.loopback mock.pool.port in
      (
        match Client.connect_plain addr with
        | Error e ->
            Error (Client.error_to_string e)
        | Ok conn ->
            let req =
              Client.make_request
                ~method_:"POST"
                ~path:"/v1/chat/completions"
                ~headers:[ ("Host", "mock") ]
                ~body:"{}"
                ()
            in
            (
              match Client.request conn req with
              | Error e ->
                  Client.close conn;
                  Error (Client.error_to_string e)
              | Ok (resp, body) ->
                  (* Drain the dying stream, collecting SSE events. *)
                  let rec drain sse_state events =
                    match body.Client.read_some () with
                    | Error _ -> (events, sse_state) (* EOF/cut = mid-stream death *)
                    | Ok "" -> (events, sse_state)
                    | Ok chunk ->
                        let (evs, s') = Sse.feed sse_state chunk in
                        drain s' (events @ evs)
                  in
                  let (events_a, _sse_state) = drain Sse.init [] in
                  Test.assert_equal ~expected:200 ~actual:resp.Client.status;
                  Test.assert_equal ~expected:["ev1"] ~actual:(List.map events_a ~fn:(fun e -> e.Sse.data));
                  (* ---- Phase 2: fallback account B "continues" the dead
                     stream by reproducing the prefix plus new text. ---- *)
                  let sent_so_far = "ev1" in
                  Mock.set_scenario
                    mock
                    {
                      (Mock.default_scenario) with
                      body = sent_so_far ^ " ev2 ev3";
                    };
                  (
                    match Client.connect_plain addr with
                    | Error e ->
                        Client.close conn;
                        Error (Client.error_to_string e)
                    | Ok conn_b ->
                        let req_b =
                          Client.make_request
                            ~method_:"POST"
                            ~path:"/v1/chat/completions"
                            ~headers:[ ("Host", "mock") ]
                            ~body:"{}"
                            ()
                        in
                        (
                          match Client.request_string conn_b req_b with
                          | Error e ->
                              Client.close conn;
                              Client.close conn_b;
                              Error (Client.error_to_string e)
                          | Ok (_resp_b, cont) ->
                              let (fwd, _) =
                                Handoff.feed
                                  (Handoff.init ~sent_so_far)
                                  cont
                              in
                              Client.close conn;
                              Client.close conn_b;
                              Test.assert_equal
                                ~expected:" ev2 ev3"
                                ~actual:fwd;
                              Test.assert_equal
                                ~expected:"ev1 ev2 ev3"
                                ~actual:(sent_so_far ^ fwd);
                              Ok ()
                        )
                  )
            )
      )

(* ---------- M1: model KB ---------- *)

let mk_kb_model = fun ?(tier = 3) ?(strengths = []) ?(weaknesses = []) ?(in_p = 100) ?(out_p = 200) name ->
  {
    Kb.name;
    tier;
    strengths;
    weaknesses;
    context_window = 100000;
    max_output = 8192;
    latency = Kb.Medium;
    in_price_nano = in_p;
    out_price_nano = out_p;
    cache_hit_price_nano = 10;
  }

let test_kb_fit_scoring = fun _ctx ->
  let coder = mk_kb_model ~tier:4 ~strengths:[ "coding" ] "m-a" in
  let writer = mk_kb_model ~tier:4 ~weaknesses:[ "coding" ] "m-b" in
  Test.assert_equal ~expected:90 ~actual:(Kb.fit coder ~category:"coding");
  Test.assert_equal ~expected:70 ~actual:(Kb.fit writer ~category:"coding");
  Test.assert_equal ~expected:80 ~actual:(Kb.fit coder ~category:"writing");
  Ok ()

let test_kb_cost_and_context = fun _ctx ->
  let m = mk_kb_model ~in_p:150 ~out_p:600 "m-a" in
  Test.assert_equal ~expected:150300 ~actual:(Kb.est_cost_nano m ~cache_tokens:0 ~in_tokens:2 ~out_tokens:250);
  (* cache-hit tokens billed at cache price (10 nano/token) *)
  Test.assert_equal
    ~expected:150400
    ~actual:(Kb.est_cost_nano m ~cache_tokens:10 ~in_tokens:2 ~out_tokens:250);
  Test.assert_equal ~expected:true ~actual:(Kb.context_ok m ~in_tokens:1000 ~out_tokens:1000);
  Test.assert_equal
    ~expected:false
    ~actual:(Kb.context_ok m ~in_tokens:100000 ~out_tokens:1000);
  Ok ()

(* ---------- M1: TOML config ---------- *)

let test_config_toml_parse = fun _ctx ->
  let source =
    {|
[server]
host = "127.0.0.1"
port = 8787
data_dir = "./.oasis-test-data"

[[models]]
name = "m-a"
tier = 4
strengths = ["coding", "general"]
context_window = 65536
max_output = 8192
latency = "fast"
in_price_nano = 150
out_price_nano = 300

[[accounts]]
name = "acc_a"
base_url = "https://api.example.com"
api_key_env = "TEST_KEY"
models = ["m-a"]
enabled = true
daily_limit = 10
monthly_budget_nano = 1000000

[[routes]]
category = "coding"
accounts = ["acc_a"]

[policy]
goal = "cheapest"
max_fallback = 3
|}
  in
  let path = Path.from_string "./.oasis-test-config.toml" |> Result.unwrap in
  (
    match Fs.write source path with
    | Error e ->
        Error ("write config failed: " ^ IO.error_message e)
    | Ok () -> (
        match Config.load "./.oasis-test-config.toml" with
        | Error e ->
            Error ("config load failed: " ^ e)
        | Ok cfg ->
            let _ = Fs.remove_file path in
            Test.assert_equal ~expected:8787 ~actual:cfg.Config.server_port;
            Test.assert_equal ~expected:1 ~actual:(List.length cfg.Config.accounts);
            Test.assert_equal ~expected:1 ~actual:(List.length cfg.Config.kb);
            Test.assert_equal
              ~expected:"cheapest"
              ~actual:cfg.Config.policy.Config.goal;
            (
              match List.head cfg.Config.accounts with
              | None -> Error "no accounts parsed"
              | Some a ->
                  Test.assert_equal ~expected:"acc_a" ~actual:a.Config.name;
                  Test.assert_equal
                    ~expected:(Some "TEST_KEY")
                    ~actual:a.Config.api_key_env;
                  Test.assert_equal ~expected:[ "m-a" ] ~actual:a.Config.models;
                  Test.assert_equal ~expected:"" ~actual:a.Config.connect_ip;
                  (
                    match List.head cfg.Config.kb with
                    | None -> Error "no kb parsed"
                    | Some m ->
                        Test.assert_equal ~expected:4 ~actual:m.Oasis.Kb.tier;
                        Test.assert_equal
                          ~expected:true
                          ~actual:(List.any m.Oasis.Kb.strengths ~fn:(String.equal "coding"));
                        Ok ()
                  )
            )
      )
  )

(* ---------- M1: router ---------- *)

let mk_config = fun ~accounts ~kb ~routes ~max_fallback ->
  {
    Config.server_host = "127.0.0.1";
    server_port = 0;
    data_dir = unique_dir "gw";
    auth_token_env = None;
    workspace_dir = "";
    accounts;
    agents = [];
    kb;
    policy =
      {
        Config.goal = "balanced";
        routes;
        agent_categories = [ "coding" ];
        max_fallback;
        max_handoffs = 2;
        handoff_notice = true;
        session_ttl_s = 600;
        explore_every = 0;
        judge = "";
        judge_every = 10;
      };
  }

let mk_account = fun ?(enabled = true) ?(budget = 0) ?(daily = 0) ?(models = [ "m-a" ]) ?(prefill = true) name ->
  {
    Config.name;
    provider = "test";
    protocol = "openai";
    thinking = "disabled";
    base_url = "http://127.0.0.1:1";
    api_key_env = None;
    models;
    enabled;
    rpm = 0;
    tpm = 0;
    daily_limit = daily;
    monthly_budget_nano = budget;
    supports_prefill = prefill;
    quota_error_codes = [];
    quota_reset = "daily";
    stream_usage = false;
    connect_ip = "";
  }

let zero_lookups =
  {
    Router.month_spent = (fun _ -> 0);
    Router.day_requests = (fun _ -> 0);
  }

let test_router_category_order_and_fallback = fun _ctx ->
  let kb = [ mk_kb_model "m-a"; mk_kb_model "m-b" ] in
  let config =
    mk_config
      ~accounts:[ mk_account "acc_a"; mk_account "acc_b"; mk_account "acc_c" ]
      ~kb
      ~routes:[ { Config.category = "coding"; accounts = [ "acc_c"; "acc_a" ] } ]
      ~max_fallback:2
  in
  let task = { Router.category = "coding"; model = None; est_in_tokens = 10; est_out_tokens = 100 } in
  let d = Router.route config zero_lookups task in
  Test.assert_equal ~expected:(Some "acc_c") ~actual:d.Router.chosen;
  Test.assert_equal ~expected:[ "acc_a" ] ~actual:d.Router.fallback_order;
  (* unknown category falls back to config order *)
  let task2 = { Router.category = "general"; model = None; est_in_tokens = 10; est_out_tokens = 100 } in
  let d2 = Router.route config zero_lookups task2 in
  Test.assert_equal ~expected:(Some "acc_a") ~actual:d2.Router.chosen;
  Ok ()

let test_router_model_mismatch_rejects = fun _ctx ->
  let kb = [ mk_kb_model "m-a" ] in
  let config =
    mk_config
      ~accounts:[ mk_account ~models:[ "m-a" ] "acc_a"; mk_account ~models:[ "m-b" ] "acc_b" ]
      ~kb
      ~routes:[]
      ~max_fallback:1
  in
  let task = { Router.category = "general"; model = Some "m-b"; est_in_tokens = 10; est_out_tokens = 100 } in
  let d = Router.route config zero_lookups task in
  Test.assert_equal ~expected:(Some "acc_b") ~actual:d.Router.chosen;
  Test.assert_equal
    ~expected:true
    ~actual:(List.any d.Router.rejected ~fn:(fun r -> String.equal r.Router.reason "model_not_served"));
  Ok ()

let test_router_budget_and_daily_rejects = fun _ctx ->
  let kb = [ mk_kb_model ~in_p:100 ~out_p:200 "m-a" ] in
  let config =
    mk_config
      ~accounts:[ mk_account ~budget:1000 "acc_a"; mk_account ~daily:0 "acc_b" ]
      ~kb
      ~routes:[]
      ~max_fallback:1
  in
  let lookups =
    {
      Router.month_spent = (fun name -> if String.equal name "acc_a" then 900 else 0);
      Router.day_requests = (fun name -> if String.equal name "acc_b" then 5 else 0);
    }
  in
  let task = { Router.category = "general"; model = None; est_in_tokens = 10; est_out_tokens = 100 } in
  let d = Router.route config lookups task in
  (* acc_a: est cost 10*100+100*200=21000 > remaining 100 → rejected;
     acc_b: day_requests 5 not >= limit 0 → unlimited → chosen *)
  Test.assert_equal ~expected:(Some "acc_b") ~actual:d.Router.chosen;
  Test.assert_equal
    ~expected:true
    ~actual:(List.any d.Router.rejected ~fn:(fun r -> String.equal r.Router.reason "budget_exhausted"));
  (* tight daily limit blocks acc_b *)
  let config2 =
    mk_config
      ~accounts:[ mk_account ~budget:1000 "acc_a"; mk_account ~daily:1 "acc_b" ]
      ~kb
      ~routes:[]
      ~max_fallback:1
  in
  let d2 = Router.route config2 lookups task in
  Test.assert_equal ~expected:None ~actual:d2.Router.chosen;
  Ok ()

(* ---------- M1: ledger ---------- *)

let test_ledger_pure_transitions = fun _ctx ->
  let s0 = Ledger.empty_state in
  let u day cost =
    {
      Ledger.seq = 0;
      unix_s = day * 86400;
      account = "a";
      model = "m";
      in_tokens = 0;
      out_tokens = 0;
      cache_tokens = 0;
      cost_nano = cost;
      latency_ms = 0;
      status = "ok";
    }
  in
  let s1 = Ledger.apply_record s0 (u 100 500) in
  Test.assert_equal ~expected:500 ~actual:s1.Ledger.month_cost_nano;
  Test.assert_equal ~expected:1 ~actual:s1.Ledger.day_requests;
  let s2 = Ledger.apply_record s1 (u 100 300) in
  Test.assert_equal ~expected:2 ~actual:s2.Ledger.day_requests;
  Test.assert_equal ~expected:800 ~actual:s2.Ledger.month_cost_nano;
  (* next day resets daily count but keeps month spend *)
  let s3 = Ledger.apply_record s2 (u 101 100) in
  Test.assert_equal ~expected:1 ~actual:s3.Ledger.day_requests;
  Test.assert_equal ~expected:900 ~actual:s3.Ledger.month_cost_nano;
  Ok ()

let test_ledger_format_usd = fun _ctx ->
  Test.assert_equal ~expected:"$0.000000150" ~actual:(Ledger.format_usd 150);
  Test.assert_equal ~expected:"$5.000000000" ~actual:(Ledger.format_usd 5000000000);
  Ok ()

(* ---------- M1: gateway integration ---------- *)

let openai_ok_body = fun ~content ->
  Json.to_string
    (Json.obj
      [
        ("id", Json.string "chatcmpl-1");
        (
          "choices",
          Json.array
            [
              Json.obj
                [
                  (
                    "message",
                    Json.obj
                      [
                        ("role", Json.string "assistant");
                        ("content", Json.string content);
                      ]
                  );
                ]
            ]
        );
        (
          "usage",
          Json.obj
            [
              ("prompt_tokens", Json.int 10);
              ("completion_tokens", Json.int 5);
            ]
        );
      ])

let gw_req = fun ~method_ ~port ~path ~headers ~body ->
  let addr = Net.Addr.tcp Net.Addr.loopback port in
  match Client.connect_plain addr with
  | Error e -> Error (Client.error_to_string e)
  | Ok conn ->
      let req =
        Client.make_request
          ~method_
          ~path
          ~headers:(("Host", "gw") :: headers)
          ~body
          ()
      in
      let res = Client.request_string conn req in
      Client.close conn;
      (
        match res with
        | Error e -> Error (Client.error_to_string e)
        | Ok (resp, body_str) -> Ok (resp.Client.status, body_str)
      )

let gw_post = gw_req ~method_:"POST"

let gw_get = fun ~port ~path ->
  gw_req ~method_:"GET" ~port ~path ~headers:[] ~body:""

let test_gateway_budget_blocks_all = fun _ctx ->
  match Mock.start () with
  | Error e -> Error ("mock start: " ^ e)
  | Ok mock ->
      Mock.set_scenario mock { (Mock.default_scenario) with body = openai_ok_body ~content:"x" };
      let kb = [ mk_kb_model ~in_p:100 ~out_p:200 "m-a" ] in
      let config =
        mk_config
          ~accounts:
            [
              {
                (mk_account ~budget:1 "acc_a") with
                Config.base_url = "http://127.0.0.1:" ^ Int.to_string mock.pool.port;
              };
            ]
          ~kb
          ~routes:[]
          ~max_fallback:0
      in
      (
        match Gateway.start ~config_path:None ~config:config ~port:0 () with
        | Error e ->
            Error ("gateway start: " ^ e)
        | Ok gw_pool -> (
            let body =
              Json.to_string
                (Json.obj
                  [
                    ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "hi") ] ]);
                  ])
            in
            let res =
              gw_post
                ~port:gw_pool.port
                ~path:"/v1/chat/completions"
                ~headers:[ ("Content-Type", "application/json") ]
                ~body
            in
            (
              match res with
              | Error e -> Error e
              | Ok (status, resp_body) ->
                  Test.assert_equal ~expected:402 ~actual:status;
                  Test.assert_equal
                    ~expected:true
                    ~actual:(String.contains resp_body "budget_exhausted");
                  Ok ()
            )
          )
      )

let test_gateway_connect_ip_overrides_dns = fun _ctx ->
  match Mock.start () with
  | Error e -> Error ("mock start: " ^ e)
  | Ok mock ->
      Mock.set_scenario mock { (Mock.default_scenario) with body = openai_ok_body ~content:"via-ip" };
      let config =
        mk_config
          ~accounts:
            [
              {
                (mk_account "acc_a") with
                Config.base_url = "http://oasis-unresolvable.invalid:" ^ Int.to_string mock.pool.port;
                connect_ip = "127.0.0.1";
              };
            ]
          ~kb:[ mk_kb_model "m-a" ]
          ~routes:[]
          ~max_fallback:0
      in
      (
        match Gateway.start ~config_path:None ~config ~port:0 () with
        | Error e -> Error ("gateway start: " ^ e)
        | Ok gw_pool -> (
            let body =
              Json.to_string
                (Json.obj
                  [
                    ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "hi") ] ]);
                  ])
            in
            match
              gw_post
                ~port:gw_pool.port
                ~path:"/v1/chat/completions"
                ~headers:[ ("Content-Type", "application/json") ]
                ~body
            with
            | Error e -> Error e
            | Ok (status, resp_body) ->
                Test.assert_equal ~expected:200 ~actual:status;
                Test.assert_equal ~expected:true ~actual:(String.contains resp_body "via-ip");
                Ok ()
          )
      )

(* ---------- M2: real-time signals ---------- *)

let test_signals_ema_and_trip = fun _ctx ->
  let s1 = Signals.ema_update ~alpha:250 ~previous:800 ~sample:1200 in
  Test.assert_equal ~expected:900 ~actual:s1;
  Test.assert_equal
    ~expected:false
    ~actual:(Signals.should_trip ~requests:4 ~errors:4);
  Test.assert_equal
    ~expected:true
    ~actual:(Signals.should_trip ~requests:10 ~errors:5);
  Test.assert_equal
    ~expected:false
    ~actual:(Signals.should_trip ~requests:10 ~errors:4);
  Ok ()

let test_signals_consecutive_failure_breaker = fun _ctx ->
  (* failures spread far apart in time (across window rolls) must still trip
     the breaker — an account failing on every request is unusable *)
  let s = ref (Signals.fresh ()) in
  let rec fail_n n t =
    if n <= 0 then !s
    else (
      s := Signals.record_failure !s ~error:"insufficient_balance" t;
      fail_n (n - 1) (t + 120000)
    )
  in
  let s5 = fail_n 5 0 in
  (
    match s5.Signals.breaker with
    | Signals.Open_until _ -> Ok ()
    | _ -> Error "expected breaker to open after 5 consecutive failures across window rolls"
  )

let test_signals_window_and_breaker = fun _ctx ->
  let s0 = Signals.fresh () in
  let s1 = Signals.record_success s0 ~latency_ms:100 ~tokens:50 1000 in
  Test.assert_equal ~expected:1 ~actual:s1.Signals.requests_in_window;
  let s2 = Signals.record_success s1 ~latency_ms:200 ~tokens:50 59000 in
  Test.assert_equal ~expected:2 ~actual:s2.Signals.requests_in_window;
  let s3 = Signals.record_success s2 ~latency_ms:200 ~tokens:50 61000 in
  Test.assert_equal ~expected:1 ~actual:s3.Signals.requests_in_window;
  let rec fail_n n s =
    if n <= 0 then s
    else fail_n (n - 1) (Signals.record_failure s ~error:"boom" 62000)
  in
  let s5 = fail_n 5 s3 in
  (
    match s5.Signals.breaker with
    | Signals.Open_until _ ->
        Test.assert_equal
          ~expected:false
          ~actual:(Signals.breaker_allows s5 63000);
        Test.assert_equal
          ~expected:true
          ~actual:(Signals.breaker_allows s5 93000);
        Ok ()
    | _ -> Error "expected breaker to open after 5 failures"
  )

(* ---------- M2: scored routing ---------- *)

let mk_snap = fun ?(ema = 200) ?(samples = 1) ?(inflight = 0) ?(breaker_open = false) ?(rpm_used = 0) () ->
  {
    Router.latency_ema_ms = ema;
    latency_samples = samples;
    in_flight = inflight;
    breaker_open;
    requests_in_window = rpm_used;
    parked = false;
  }

let mk_scored_lookups = fun ~spent ~day ~snap ->
  {
    Router.month_spent = spent;
    day_requests = day;
    snapshot = snap;
    quality = (fun ~account:_ ~category:_ -> { Oasis.Quality.sum = 0; n = 0 });
  }

let test_router_v2_cheapest_goal = fun _ctx ->
  let kb =
    [
      mk_kb_model ~in_p:100 ~out_p:200 "m-cheap";
      mk_kb_model ~in_p:500 ~out_p:900 "m-expensive";
    ]
  in
  let config =
    mk_config
      ~accounts:
        [
          mk_account ~models:[ "m-cheap" ] "acc_cheap";
          mk_account ~models:[ "m-expensive" ] "acc_pricey";
        ]
      ~kb
      ~routes:[]
      ~max_fallback:1
  in
  let lookups =
    mk_scored_lookups
      ~spent:(fun _ -> 0)
      ~day:(fun _ -> 0)
      ~snap:(fun name ->
        mk_snap ~ema:(if String.equal name "acc_cheap" then 800 else 50) ())
  in
  let task = { Router.category = "general"; model = None; est_in_tokens = 100; est_out_tokens = 100 } in
  let d = Router.route_scored config lookups ~goal:Router.Cheapest task in
  Test.assert_equal ~expected:(Some "acc_cheap") ~actual:d.Router.chosen;
  let d2 = Router.route_scored config lookups ~goal:Router.Fastest task in
  Test.assert_equal ~expected:(Some "acc_pricey") ~actual:d2.Router.chosen;
  Ok ()

let test_router_v2_breaker_blocks = fun _ctx ->
  let kb = [ mk_kb_model "m-a" ] in
  let config =
    mk_config
      ~accounts:[ mk_account "acc_a"; mk_account "acc_b" ]
      ~kb
      ~routes:[]
      ~max_fallback:1
  in
  let lookups =
    mk_scored_lookups
      ~spent:(fun _ -> 0)
      ~day:(fun _ -> 0)
      ~snap:(fun name ->
        mk_snap ~breaker_open:(String.equal name "acc_a") ())
  in
  let task = { Router.category = "general"; model = None; est_in_tokens = 10; est_out_tokens = 10 } in
  let d = Router.route_scored config lookups ~goal:Router.Balanced task in
  Test.assert_equal ~expected:(Some "acc_b") ~actual:d.Router.chosen;
  Test.assert_equal
    ~expected:true
    ~actual:(List.any d.Router.rejected ~fn:(fun r -> String.equal r.Router.reason "circuit_open"));
  Ok ()

(* ---------- M2: gateway streaming + seamless handoff ---------- *)

let extract_choice_text = fun ev ->
  if ev.Sse.done_sentinel then
    None
  else
    Some
      (Json.from_string ev.Sse.data
      |> Result.unwrap_or ~default:(Json.string ev.Sse.data)
      |> fun j ->
      Json.get_field "choices" j
      |> Option.and_then ~fn:Json.get_array
      |> Option.and_then ~fn:List.head
      |> Option.and_then ~fn:(fun c -> Json.get_field "delta" c)
      |> Option.and_then ~fn:(fun d -> Json.get_field "content" d)
      |> Option.and_then ~fn:Json.get_string
      |> Option.unwrap_or ~default:"")

let gw_stream_collect = fun ~port ~path ~headers ~body ->
  let addr = Net.Addr.tcp Net.Addr.loopback port in
  match Client.connect_plain addr with
  | Error e -> Error (Client.error_to_string e)
  | Ok conn ->
      let req =
        Client.make_request
          ~method_:"POST"
          ~path
          ~headers:(("Host", "gw") :: headers)
          ~body
          ()
      in
      let res = Client.request conn req in
      (
        match res with
        | Error e ->
            Client.close conn;
            Error (Client.error_to_string e)
        | Ok (resp, body) ->
            let raw = ref "" in
            let rec drain sse_state events =
              match body.Client.read_some () with
              | Error _ -> (events, sse_state)
              | Ok "" -> (events, sse_state)
              | Ok chunk ->
                  raw := !raw ^ chunk;
                  let (evs, s') = Sse.feed sse_state chunk in
                  drain s' (events @ evs)
            in
            let (events, _) = drain Sse.init [] in
            Client.close conn;
            Ok (resp.Client.status, events, !raw)
      )

let test_gateway_end_to_end_scenarios = fun _ctx ->
  match Mock.start () with
  | Error e -> Error ("mock start: " ^ e)
  | Ok mock_a -> (
      match Mock.start () with
      | Error e -> Error ("mock start: " ^ e)
      | Ok mock_b ->
          let kb = [ mk_kb_model "m-x" ] in
          let config =
            mk_config
              ~accounts:
                [
                  {
                    (mk_account "acc_a") with
                    Config.base_url = "http://127.0.0.1:" ^ Int.to_string mock_a.pool.port;
                    Config.models = [ "m-x" ];
                  };
                  {
                    (mk_account "acc_b") with
                    Config.base_url = "http://127.0.0.1:" ^ Int.to_string mock_b.pool.port;
                    Config.models = [ "m-x" ];
                  };
                ]
              ~kb
              ~routes:[ { Config.category = "coding"; accounts = [ "acc_a"; "acc_b" ] } ]
              ~max_fallback:1
          in
          (
            match Gateway.start ~config_path:None ~config ~port:0 () with
            | Error e -> Error ("gateway start: " ^ e)
            | Ok gw_pool -> (
                let chat_body = fun ~stream () ->
                  Json.to_string
                    (Json.obj
                      [
                        ("model", Json.string "m-x");
                        (
                          "messages",
                          Json.array
                            [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "hi") ] ]
                        );
                        ("max_tokens", Json.int 64);
                        ("stream", Json.bool stream);
                      ])
                in
                let post_chat () =
                  gw_post
                    ~port:gw_pool.port
                    ~path:"/v1/chat/completions"
                    ~headers:[ ("X-Oasis-Category", "coding"); ("Content-Type", "application/json") ]
                    ~body:(chat_body ~stream:false ())
                in
                let stream_chat () =
                  gw_stream_collect
                    ~port:gw_pool.port
                    ~path:"/v1/chat/completions"
                    ~headers:[ ("X-Oasis-Category", "coding"); ("Content-Type", "application/json") ]
                    ~body:(chat_body ~stream:true ())
                in
                (* ---- S1: non-stream ok via acc_a ---- *)
                Mock.set_scenario mock_a { (Mock.default_scenario) with body = openai_ok_body ~content:"s1" };
                Mock.set_scenario mock_b { (Mock.default_scenario) with body = openai_ok_body ~content:"s1b" };
                (
                  match post_chat () with
                  | Error e -> Error ("s1: " ^ e)
                  | Ok (status, resp_body) ->
                      Test.assert_equal ~expected:200 ~actual:status;
                      Test.assert_equal ~expected:true ~actual:(String.contains resp_body "s1");
                      (* ---- S2: acc_a 429 -> fallback acc_b ---- *)
                      Mock.set_scenario mock_a { (Mock.default_scenario) with status = 429; body = "{}" };
                      (
                        match post_chat () with
                        | Error e -> Error ("s2: " ^ e)
                        | Ok (status2, resp_body2) ->
                            Test.assert_equal ~expected:200 ~actual:status2;
                            Test.assert_equal ~expected:true ~actual:(String.contains resp_body2 "s1b");
                            let dec = gw_get ~port:gw_pool.port ~path:"/api/decisions" in
                            (
                              match dec with
                              | Error e -> Error ("s2 dec: " ^ e)
                              | Ok (_, dec_body) ->
                                  Test.assert_equal ~expected:true ~actual:(String.contains dec_body "\"chosen\":\"acc_b\"");
                                  Test.assert_equal ~expected:true ~actual:(String.contains dec_body "\"status\":429");
                                  (* ---- S3: SSE happy path ---- *)
                                  Mock.set_scenario mock_a { (Mock.default_scenario) with sse = [ "hello"; " stream" ] };
                                  (
                                    match stream_chat () with
                                    | Error e -> Error ("s3: " ^ e)
                                    | Ok (status3, events, _raw) ->
                                        Test.assert_equal ~expected:200 ~actual:status3;
                                        let done3 = List.any events ~fn:(fun ev -> ev.Sse.done_sentinel) in
                                        Test.assert_equal ~expected:true ~actual:done3;
                                        let contents3 = List.filter_map events ~fn:extract_choice_text in
                                        Test.assert_equal ~expected:"hello stream" ~actual:(String.concat "" contents3);
                                        (* ---- S4: mid-stream death -> seamless handoff ---- *)
                                        let header_len = String.length (Mock.stream_header 200) in
                                        let frame1 = Mock.chunked_frame "data: ev1\n\n" in
                                        Mock.set_scenario
                                          mock_a
                                          {
                                            (Mock.default_scenario) with
                                            sse = [ "ev1"; "ev2"; "ev3" ];
                                            cut_after_bytes = header_len + String.length frame1 + 3;
                                          };
                                        Mock.set_scenario mock_b { (Mock.default_scenario) with sse = [ "ev1 ev2 ev3" ] };
                                        (
                                          match stream_chat () with
                                          | Error e -> Error ("s4: " ^ e)
                                          | Ok (status4, events4, _raw4) ->
                                              Test.assert_equal ~expected:200 ~actual:status4;
                                              let done4 = List.any events4 ~fn:(fun ev -> ev.Sse.done_sentinel) in
                                              Test.assert_equal ~expected:true ~actual:done4;
                                              let contents4 = List.filter_map events4 ~fn:extract_choice_text in
                                              (* THE assertion: continuous text, zero duplicates *)
                                              Test.assert_equal ~expected:"ev1 ev2 ev3" ~actual:(String.concat "" contents4);
                                              let dec2 = gw_get ~port:gw_pool.port ~path:"/api/decisions" in
                                              (
                                                match dec2 with
                                                | Error e -> Error ("s4 dec: " ^ e)
                                                | Ok (_, dec2_body) ->
                                              let dec2 = gw_get ~port:gw_pool.port ~path:"/api/decisions" in
                                              (
                                                match dec2 with
                                                | Error e -> Error ("s4 dec: " ^ e)
                                                | Ok (_, dec2_body) ->
                                                    Test.assert_equal ~expected:true ~actual:(String.contains dec2_body "\"chosen\":\"acc_b\"");
                                                    Test.assert_equal ~expected:true ~actual:(String.contains dec2_body "\"account\":\"acc_a\"");
                                                    (* ---- S5: sticky session pins account, handoff re-pins ---- *)
                                                    let sticky_headers =
                                                      [
                                                        ("X-Oasis-Category", "coding");
                                                        ("X-Oasis-Session", "sess-1");
                                                        ("Content-Type", "application/json");
                                                      ]
                                                    in
                                                    Mock.set_scenario mock_a { (Mock.default_scenario) with body = openai_ok_body ~content:"s5a" };
                                                    Mock.set_scenario mock_b { (Mock.default_scenario) with body = openai_ok_body ~content:"s5b" };
                                                    (
                                                      match
                                                        gw_post
                                                          ~port:gw_pool.port
                                                          ~path:"/v1/chat/completions"
                                                          ~headers:sticky_headers
                                                          ~body:(chat_body ~stream:false ())
                                                      with
                                                      | Error e -> Error ("s5a: " ^ e)
                                                      | Ok (s5a_status, s5a_body) ->
                                                          Test.assert_equal ~expected:200 ~actual:s5a_status;
                                                          (* The router may legitimately prefer either account after
                                                             S4's mid-stream death (latency/failure history), so pin
                                                             whichever served first and kill that one. *)
                                                          let first_is_a = String.contains s5a_body "s5a" in
                                                          Test.assert_equal ~expected:true ~actual:(first_is_a || String.contains s5a_body "s5b");
                                                          let (pinned_mock, other_content, pinned_content) =
                                                            if first_is_a then (mock_a, "s5b", "s5a") else (mock_b, "s5a", "s5b")
                                                          in
                                                          (* the pinned account dies -> handoff re-pins the session to the other *)
                                                          Mock.set_scenario pinned_mock { (Mock.default_scenario) with status = 429; body = "{}" };
                                                          (
                                                            match
                                                              gw_post
                                                                ~port:gw_pool.port
                                                                ~path:"/v1/chat/completions"
                                                                ~headers:sticky_headers
                                                                ~body:(chat_body ~stream:false ())
                                                            with
                                                            | Error e -> Error ("s5b: " ^ e)
                                                            | Ok (s5b_status, s5b_body) ->
                                                                Test.assert_equal ~expected:200 ~actual:s5b_status;
                                                                Test.assert_equal ~expected:true ~actual:(String.contains s5b_body other_content);
                                                                (* the first account recovers, but the session stays re-pinned *)
                                                                Mock.set_scenario pinned_mock { (Mock.default_scenario) with body = openai_ok_body ~content:pinned_content };
                                                                (
                                                                  match
                                                                    gw_post
                                                                      ~port:gw_pool.port
                                                                      ~path:"/v1/chat/completions"
                                                                      ~headers:sticky_headers
                                                                      ~body:(chat_body ~stream:false ())
                                                                  with
                                                                  | Error e -> Error ("s5c: " ^ e)
                                                                  | Ok (s5c_status, s5c_body) ->
                                                                      Test.assert_equal ~expected:200 ~actual:s5c_status;
                                                                      Test.assert_equal
                                                                        ~expected:true
                                                                        ~actual:(String.contains s5c_body other_content);
                                                                      (* ---- S6: MCP tools over the same gateway ---- *)
                                                                      let mcp_post body =
                                                                        gw_post
                                                                          ~port:gw_pool.port
                                                                          ~path:"/mcp"
                                                                          ~headers:[ ("Content-Type", "application/json") ]
                                                                          ~body
                                                                      in
                                                                      (
                                                                        match
                                                                          mcp_post
                                                                            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
                                                                        with
                                                                        | Error e -> Error ("s6-init: " ^ e)
                                                                        | Ok (s6a_s, s6a_b) ->
                                                                            Test.assert_equal ~expected:200 ~actual:s6a_s;
                                                                            Test.assert_equal
                                                                              ~expected:true
                                                                              ~actual:(String.contains s6a_b "protocolVersion");
                                                                            (
                                                                              match
                                                                                mcp_post
                                                                                  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
                                                                              with
                                                                              | Error e -> Error ("s6-list: " ^ e)
                                                                              | Ok (s6b_s, s6b_b) ->
                                                                                  Test.assert_equal ~expected:200 ~actual:s6b_s;
                                                                                  Test.assert_equal ~expected:true ~actual:(String.contains s6b_b "oasis_ask");
                                                                                  (
                                                                                    match
                                                                                      mcp_post
                                                                                        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"oasis_ask\",\"arguments\":{\"prompt\":\"hi\",\"category\":\"coding\"}}}"
                                                                                    with
                                                                                    | Error e -> Error ("s6-call: " ^ e)
                                                                                    | Ok (s6c_s, s6c_b) ->
                                                                                        Test.assert_equal ~expected:200 ~actual:s6c_s;
                                                                                        Test.assert_equal
                                                                                          ~expected:true
                                                                                          ~actual:(String.contains s6c_b "\"isError\":false");
                                                                                        Test.assert_equal
                                                                                          ~expected:true
                                                                                          ~actual:(String.contains s6c_b "routed via");
                                                                                        (
                                                                                          match
                                                                                            mcp_post
                                                                                              "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"wat\"}"
                                                                                          with
                                                                                          | Error e -> Error ("s6-err: " ^ e)
                                                                                          | Ok (s6d_s, s6d_b) ->
                                                                                              Test.assert_equal ~expected:501 ~actual:s6d_s;
                                                                                              Test.assert_equal
                                                                                                ~expected:true
                                                                                                ~actual:(String.contains s6d_b "-32601");
                                                                                              Ok ()
                                                                                      )
                                                                                  )
                                                                          )
                                                                      )
                                                                )
                                                          )
                                                    )
                                              )
                                        )
                                  )
                            )
                      )
                )
            )
      )
      )
      )

let test_session_pin_lookup_expiry = fun _ctx ->
  let t = Session.init () in
  Session.pin t ~session:"s1" ~account:"acc_a" ~now_ms:1000;
  Test.assert_equal
    ~expected:(Some "acc_a")
    ~actual:(Session.lookup t ~session:"s1" ~now_ms:2000 ~ttl_ms:10000);
  Session.pin t ~session:"s1" ~account:"acc_b" ~now_ms:3000;
  Test.assert_equal
    ~expected:(Some "acc_b")
    ~actual:(Session.lookup t ~session:"s1" ~now_ms:4000 ~ttl_ms:10000);
  Test.assert_equal
    ~expected:None
    ~actual:(Session.lookup t ~session:"s1" ~now_ms:20000 ~ttl_ms:10000);
  Test.assert_equal
    ~expected:None
    ~actual:(Session.lookup t ~session:"unknown" ~now_ms:20000 ~ttl_ms:10000);
  Ok ()

let test_deepseek_real_roundtrip = fun _ctx ->
  (* Manual network diagnostic: reads the key from ./.ds-key when present.
     Skipped silently otherwise, so the suite stays hermetic. *)
  let p = Path.from_string "./.ds-key" |> Result.unwrap in
  match Fs.read_to_string p with
  | Error _ -> Ok ()
  | Ok key_file ->
      let key = String.trim key_file in
      let host = "api.deepseek.com" in
      let addr = Net.Addr.from_host_and_port ~host ~port:443 |> Result.unwrap in
      (
        match Client.connect_tls ~hostname:host addr with
        | Error e -> Error (Client.error_to_string e)
        | Ok conn ->
            let body =
              Json.to_string
                (Json.obj
                  [
                    ("model", Json.string "deepseek-chat");
                    (
                      "messages",
                      Json.array
                        [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "1+1=?") ] ]
                    );
                    ("max_tokens", Json.int 64);
                    ("stream", Json.bool false);
                  ])
            in
            let req =
              Client.make_request
                ~method_:"POST"
                ~path:"/v1/chat/completions"
                ~headers:
                  [
                    ("Host", host);
                    ("Content-Type", "application/json");
                    ("Authorization", "Bearer " ^ key);
                    ("Connection", "close");
                  ]
                ~body
                ()
            in
            (
              match Client.request conn req with
              | Error e ->
                  Client.close conn;
                  Error (Client.error_to_string e)
              | Ok (resp, body_reader) ->
                  (
                    match body_reader.Client.read_all () with
                    | Error e ->
                        Client.close conn;
                        Error (Client.error_to_string e)
                    | Ok s ->
                        Client.close conn;
                        if String.contains s "\"choices\"" then
                          Ok ()
                        else
                          Error
                            ("real: status="
                            ^ Int.to_string resp.Client.status
                            ^ " body_len="
                            ^ Int.to_string (String.length s)
                            ^ " body="
                            ^ String.sub s ~offset:0 ~len:(min 100 (String.length s)))
                  )
            )
      )

(* ---------- Anthropic protocol adapter ---------- *)

let test_anthropic_to_request = fun _ctx ->
  let messages =
    Json.array
      [
        Json.obj [ ("role", Json.string "system"); ("content", Json.string "be brief") ];
        Json.obj [ ("role", Json.string "user"); ("content", Json.string "hi") ];
        Json.obj [ ("role", Json.string "assistant"); ("content", Json.string "hello") ];
      ]
  in
  let body = Anthropic.to_request ~thinking:"disabled" ~model:"glm-4.6" ~messages ~max_tokens:64 ~stream:false in
  Test.assert_equal ~expected:true ~actual:(String.contains body "\"system\":\"be brief\"");
  Test.assert_equal
    ~expected:true
    ~actual:(String.contains body "\"role\":\"user\"");
  Test.assert_equal
    ~expected:true
    ~actual:(String.contains body "\"role\":\"assistant\"");
  Test.assert_equal
    ~expected:false
    ~actual:(String.contains body "\"role\":\"system\"");
  Ok ()

let test_anthropic_from_response = fun _ctx ->
  let resp =
    "{\"model\":\"glm-4.6\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\"},{\"type\":\"text\",\"text\":\"1+1=2\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}"
  in
  let oai = Anthropic.from_response resp in
  let content =
    Json.get_field "choices" oai
    |> Option.and_then ~fn:Json.get_array
    |> Option.and_then ~fn:List.head
    |> Option.and_then ~fn:(fun ch -> Json.get_field "message" ch)
    |> Option.and_then ~fn:(fun m -> Json.get_field "content" m)
    |> Option.and_then ~fn:Json.get_string
    |> Option.unwrap_or ~default:""
  in
  Test.assert_equal ~expected:"1+1=2" ~actual:content;
  let in_t =
    Json.get_field "usage" oai
    |> Option.and_then ~fn:(fun u -> Json.get_field "prompt_tokens" u)
    |> Option.and_then ~fn:Json.get_int
    |> Option.unwrap_or ~default:0
  in
  Test.assert_equal ~expected:10 ~actual:in_t;
  Ok ()

let test_anthropic_stream_events = fun _ctx ->
  Test.assert_equal
    ~expected:(Some "hello")
    ~actual:(Anthropic.extract_delta_text "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}");
  Test.assert_equal
    ~expected:None
    ~actual:(Anthropic.extract_delta_text "{\"type\":\"content_block_start\",\"index\":0}");
  Test.assert_equal
    ~expected:true
    ~actual:(Anthropic.is_stream_end "{\"type\":\"message_stop\"}");
  Test.assert_equal
    ~expected:false
    ~actual:(Anthropic.is_stream_end "{\"type\":\"message_delta\"}");
  Ok ()

(* ---------- gateway: anthropic protocol end-to-end ---------- *)

let anth_msg = fun ~text ->
  "{\"model\":\"glm-4.6\",\"content\":[{\"type\":\"text\",\"text\":\"" ^ text ^ "\"}],\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}"

let test_gateway_anthropic_non_stream_and_stream = fun _ctx ->
  match Mock.start () with
  | Error e -> Error ("mock start: " ^ e)
  | Ok mock ->
      Mock.set_scenario mock { (Mock.default_scenario) with body = anth_msg ~text:"glm-reply" };
      let kb = [ mk_kb_model "glm-4.6" ] in
      let config =
        mk_config
          ~accounts:
            [
              {
                (mk_account ~models:[ "glm-4.6" ] "acc_glm") with
                Config.protocol = "anthropic";
                Config.base_url = "http://127.0.0.1:" ^ Int.to_string mock.pool.port;
              };
            ]
          ~kb
          ~routes:[]
          ~max_fallback:0
      in
      (
        match Gateway.start ~config_path:None ~config ~port:0 () with
        | Error e -> Error ("gateway start: " ^ e)
        | Ok gw_pool -> (
            let body =
              Json.to_string
                (Json.obj
                  [
                    ("model", Json.string "glm-4.6");
                    ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "hi") ] ]);
                    ("max_tokens", Json.int 64);
                    ("stream", Json.bool false);
                  ])
            in
            (
              match
                gw_post
                  ~port:gw_pool.port
                  ~path:"/v1/chat/completions"
                  ~headers:[ ("Content-Type", "application/json") ]
                  ~body
              with
              | Error e -> Error ("s1: " ^ e)
              | Ok (status, resp_body) ->
                  Test.assert_equal ~expected:200 ~actual:status;
                  Test.assert_equal
                    ~expected:true
                    ~actual:(String.contains resp_body "glm-reply");
                  Test.assert_equal
                    ~expected:true
                    ~actual:(String.contains resp_body "\"prompt_tokens\":7");
                  (* stream: anthropic SSE events through the gateway *)
                  Mock.set_scenario
                    mock
                    {
                      (Mock.default_scenario) with
                      sse =
                        [
                          "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}";
                          "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}";
                          "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" glm\"}}";
                          "{\"type\":\"message_stop\"}";
                        ];
                    };
                  let stream_body =
                    Json.to_string
                      (Json.obj
                        [
                          ("model", Json.string "glm-4.6");
                          ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "hi") ] ]);
                          ("max_tokens", Json.int 64);
                          ("stream", Json.bool true);
                        ])
                  in
                  (
                    match
                      gw_stream_collect
                        ~port:gw_pool.port
                        ~path:"/v1/chat/completions"
                        ~headers:[ ("Content-Type", "application/json") ]
                        ~body:stream_body
                    with
                    | Error e -> Error ("s2: " ^ e)
                    | Ok (status2, events2, _raw2) ->
                        Test.assert_equal ~expected:200 ~actual:status2;
                        let done2 = List.any events2 ~fn:(fun ev -> ev.Sse.done_sentinel) in
                        Test.assert_equal ~expected:true ~actual:done2;
                        let contents2 = List.filter_map events2 ~fn:extract_choice_text in
                        Test.assert_equal ~expected:"hi glm" ~actual:(String.concat "" contents2);
                        Ok ()
                  )
            )
          )
      )

let test_gateway_cross_protocol_seamless_handoff = fun _ctx ->
  (* account A speaks Anthropic and dies mid-stream; account B speaks
     OpenAI and continues. The handoff must splice cleanly across protocols. *)
  match Mock.start () with
  | Error e -> Error ("mock a: " ^ e)
  | Ok mock_a -> (
      match Mock.start () with
      | Error e -> Error ("mock b: " ^ e)
      | Ok mock_b ->
          let header_len = String.length (Mock.stream_header 200) in
          let frame1 = Mock.chunked_frame "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ev1\"}}\n\n" in
          Mock.set_scenario
            mock_a
            {
              (Mock.default_scenario) with
              sse =
                [
                  "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ev1\"}}";
                  "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ev2\"}}";
                  "{\"type\":\"message_stop\"}";
                ];
              cut_after_bytes = header_len + String.length frame1 + 3;
            };
          Mock.set_scenario mock_b { (Mock.default_scenario) with sse = [ "ev1 ev2 ev3" ] };
          let kb = [ mk_kb_model "m-x" ] in
          let config =
            mk_config
              ~accounts:
                [
                  {
                    (mk_account "acc_a") with
                    Config.protocol = "anthropic";
                    Config.models = [ "m-x" ];
                    Config.base_url = "http://127.0.0.1:" ^ Int.to_string mock_a.pool.port;
                  };
                  {
                    (mk_account "acc_b") with
                    Config.protocol = "openai";
                    Config.models = [ "m-x" ];
                    Config.base_url = "http://127.0.0.1:" ^ Int.to_string mock_b.pool.port;
                  };
                ]
              ~kb
              ~routes:[ { Config.category = "general"; accounts = [ "acc_a"; "acc_b" ] } ]
              ~max_fallback:1
          in
          (
            match Gateway.start ~config_path:None ~config ~port:0 () with
            | Error e -> Error ("gateway: " ^ e)
            | Ok gw_pool -> (
                let body =
                  Json.to_string
                    (Json.obj
                      [
                        ("model", Json.string "m-x");
                        ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "ev1 ev2 ev3") ] ]);
                        ("max_tokens", Json.int 64);
                        ("stream", Json.bool true);
                      ])
                in
                (
                  match
                    gw_stream_collect
                      ~port:gw_pool.port
                      ~path:"/v1/chat/completions"
                      ~headers:[ ("X-Oasis-Category", "general"); ("Content-Type", "application/json") ]
                      ~body
                  with
                  | Error e -> Error e
                  | Ok (status, events, _raw) ->
                      let done_seen = List.any events ~fn:(fun ev -> ev.Sse.done_sentinel) in
                      let contents = List.filter_map events ~fn:extract_choice_text in
                      if status != 200 then
                        Error ("status=" ^ Int.to_string status)
                      else if not done_seen then
                        Error ("no DONE; events=" ^ (List.map events ~fn:(fun e -> e.Sse.data) |> String.concat " | "))
                      else if not (String.equal "ev1 ev2 ev3" (String.concat "" contents)) then
                        Error ("content=" ^ String.concat "" contents)
                      else
                        Ok ()
                )
              )
          )
  )

(* ---------- agent adapters ---------- *)

let mk_agent = fun ?(tier = 4) ?(command = "/bin/sh") ?(args = [ "{prompt}" ]) ?(strengths = [ "coding" ]) ?(timeout_s = 10) ?(concurrency = 2) ?(models = []) ?(home = "") name ->
  {
    Agent.name;
    command;
    args_template = args;
    home;
    models;
    workdir = "";
    timeout_s;
    capabilities = [ "terminal"; "files" ];
    tier;
    strengths;
    weaknesses = [];
    context_window = 200000;
    max_output = 32768;
    latency = "slow";
    enabled = true;
    concurrency_limit = concurrency;
    allowed_workdirs = [];
    env_passthrough = [];
    resume_args = [];
  }

let fix = fun name -> Agent.absolute ("./packages/oasis/tests/fixtures/" ^ name)

let test_agent_build_args = fun _ctx ->
  let a = mk_agent ~args:[ "-p"; "--model"; "{model}"; "{prompt}" ] "x" in
  let args = Agent.build_args a ~model:"m1" ~prompt:"hello world" in
  Test.assert_equal ~expected:[ "-p"; "--model"; "m1"; "hello world" ] ~actual:args;
  Ok ()

let test_agent_claude_stream_json_parse = fun _ctx ->
  let line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi there\"},{\"type\":\"tool_use\",\"name\":\"bash\"}]}}" in
  Test.assert_equal
    ~expected:(Some "hi there")
    ~actual:(Agent.extract_text ~command:"claude" line);
  Test.assert_equal
    ~expected:None
    ~actual:(Agent.extract_text ~command:"claude" "{\"type\":\"tool_use\",\"name\":\"bash\"}");
  Test.assert_equal
    ~expected:None
    ~actual:(Agent.extract_text ~command:"claude" "{\"type\":\"result\",\"result\":\"hi there\"}");
  Test.assert_equal
    ~expected:(Some "plain line\n")
    ~actual:(Agent.extract_text ~command:"gemini" "plain line");
  Ok ()

let test_agent_cursor_stream_json_parse = fun _ctx ->
  let assistant = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"PONG\"}]},\"session_id\":\"s\"}" in
  Test.assert_equal ~expected:(Some "PONG") ~actual:(Agent.extract_text ~command:"cursor-agent" assistant);
  Test.assert_equal
    ~expected:None
    ~actual:(Agent.extract_text ~command:"cursor-agent" "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"PONG\"}");
  Test.assert_equal
    ~expected:None
    ~actual:(Agent.extract_text ~command:"cursor-agent" "{\"type\":\"tool_call\",\"subtype\":\"started\"}");
  Ok ()

module Steps = Oasis.Steps
module Feed = Oasis.Feed

let steps_of = fun ~command line ->
  Steps.parse ~command line |> Option.unwrap_or ~default:[]

let kinds = fun steps -> List.map steps ~fn:Steps.kind

let sfield = fun s k -> Steps.str s k |> Option.unwrap_or ~default:""

let test_steps_parse_agents = fun _ctx ->
  (* claude: tool_use + tool_result *)
  let s = steps_of ~command:"claude" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\"},{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls /tmp\",\"description\":\"d\"}}]}}" in
  Test.assert_equal ~expected:[ "thinking"; "tool" ] ~actual:(kinds s);
  Test.assert_equal ~expected:"ls /tmp" ~actual:(sfield (List.get_unchecked s ~at:1) "input");
  let s = steps_of ~command:"/opt/bin/claude" "{\"type\":\"user\",\"message\":{\"content\":[{\"tool_use_id\":\"t1\",\"type\":\"tool_result\",\"content\":\"a\\nb\",\"is_error\":true}]}}" in
  Test.assert_equal ~expected:[ "tool_result" ] ~actual:(kinds s);
  Test.assert_equal ~expected:(Some false) ~actual:(Json.get_field "ok" (List.get_unchecked s ~at:0) |> Option.and_then ~fn:Json.get_bool);
  (* cursor: thinking delta, tool_call started/completed *)
  let s = steps_of ~command:"cursor-agent" "{\"type\":\"thinking\",\"subtype\":\"delta\",\"text\":\"Run\"}" in
  Test.assert_equal ~expected:[ "thinking" ] ~actual:(kinds s);
  Test.assert_equal ~expected:true ~actual:(Steps.is_delta (List.get_unchecked s ~at:0));
  let s = steps_of ~command:"cursor-agent" "{\"type\":\"tool_call\",\"subtype\":\"started\",\"call_id\":\"c1\",\"tool_call\":{\"shellToolCall\":{\"args\":{\"command\":\"ls\"}}}}" in
  Test.assert_equal ~expected:"shell" ~actual:(sfield (List.get_unchecked s ~at:0) "name");
  let s = steps_of ~command:"cursor-agent" "{\"type\":\"tool_call\",\"subtype\":\"completed\",\"call_id\":\"c1\",\"tool_call\":{\"shellToolCall\":{\"args\":{},\"result\":{\"success\":{\"stdout\":\"x\\n\",\"exitCode\":0}}}}}" in
  Test.assert_equal ~expected:"x" ~actual:(sfield (List.get_unchecked s ~at:0) "output");
  (* gemini *)
  let s = steps_of ~command:"gemini" "{\"type\":\"tool_use\",\"tool_name\":\"run_shell_command\",\"tool_id\":\"g1\",\"parameters\":{\"command\":\"pwd\"}}" in
  Test.assert_equal ~expected:"pwd" ~actual:(sfield (List.get_unchecked s ~at:0) "input");
  let s = steps_of ~command:"gemini" "{\"type\":\"message\",\"role\":\"assistant\",\"content\":\"DONE\",\"delta\":true}" in
  Test.assert_equal ~expected:[ "text" ] ~actual:(kinds s);
  Test.assert_equal ~expected:[] ~actual:(kinds (steps_of ~command:"gemini" "{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}"));
  (* kimi: think + tool_calls (arguments are a json string) *)
  let s = steps_of ~command:"kimi" "{\"role\":\"assistant\",\"content\":[{\"type\":\"think\",\"think\":\"ok\"}],\"tool_calls\":[{\"id\":\"k1\",\"function\":{\"name\":\"Shell\",\"arguments\":\"{\\\"command\\\":\\\"ls -la\\\"}\"}}]}" in
  Test.assert_equal ~expected:[ "thinking"; "tool" ] ~actual:(kinds s);
  Test.assert_equal ~expected:"ls -la" ~actual:(sfield (List.get_unchecked s ~at:1) "input");
  let s = steps_of ~command:"kimi" "{\"role\":\"tool\",\"content\":[{\"type\":\"text\",\"text\":\"<system>Command executed successfully.</system>\"},{\"type\":\"text\",\"text\":\"out\"}],\"tool_call_id\":\"k1\"}" in
  Test.assert_equal ~expected:"out" ~actual:(sfield (List.get_unchecked s ~at:0) "output");
  (* grok *)
  let s = steps_of ~command:"grok" "{\"type\":\"tool_call\",\"toolCallId\":\"x1\",\"toolName\":\"run_terminal_command\",\"rawInput\":{\"command\":\"ls\"}}" in
  Test.assert_equal ~expected:"run_terminal_command" ~actual:(sfield (List.get_unchecked s ~at:0) "name");
  let s = steps_of ~command:"grok" "{\"type\":\"tool_call_update\",\"toolCallId\":\"x1\",\"status\":\"completed\",\"rawOutput\":{\"output_for_prompt\":\"exit: 0\\n/tmp\\n\",\"exit_code\":0}}" in
  Test.assert_equal ~expected:(Some true) ~actual:(Json.get_field "ok" (List.get_unchecked s ~at:0) |> Option.and_then ~fn:Json.get_bool);
  Test.assert_equal ~expected:[] ~actual:(kinds (steps_of ~command:"grok" "{\"type\":\"tool_call_update\",\"toolCallId\":\"x1\",\"status\":\"in_progress\"}"));
  (* non-json output of a known CLI and unknown CLIs stay plain text *)
  Test.assert_equal ~expected:true ~actual:(Option.is_none (Steps.parse ~command:"gemini" "Loaded cached credentials."));
  Test.assert_equal ~expected:true ~actual:(Option.is_none (Steps.parse ~command:"opencode" "{\"type\":\"text\"}"));
  Ok ()

let test_steps_answer_join = fun _ctx ->
  let run ~command lines =
    let jn = Steps.joiner () in
    List.fold_left lines ~init:"" ~fn:(fun acc l ->
      let text, _ = Agent.consume_line jn ~command l in
      acc ^ text)
  in
  Test.assert_equal
    ~expected:"Running it.\n\nDONE"
    ~actual:
      (run
        ~command:"cursor-agent"
        [
          "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Running it.\"}]}}";
          "{\"type\":\"tool_call\",\"subtype\":\"started\",\"call_id\":\"c\",\"tool_call\":{\"shellToolCall\":{\"args\":{}}}}";
          "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"DONE\"}]}}";
          "{\"type\":\"result\",\"result\":\"Running it.DONE\"}";
        ]);
  Test.assert_equal
    ~expected:"I'll run\n\nDONE"
    ~actual:
      (run
        ~command:"grok"
        [
          "{\"type\":\"text\",\"data\":\"I'll\"}";
          "{\"type\":\"text\",\"data\":\" run\"}";
          "{\"type\":\"tool_call\",\"toolCallId\":\"x\",\"toolName\":\"t\",\"rawInput\":{}}";
          "{\"type\":\"text\",\"data\":\"DONE\"}";
        ]);
  Test.assert_equal ~expected:"a\nb\n" ~actual:(run ~command:"opencode" [ "a"; ""; "b" ]);
  Ok ()

let test_steps_clip_utf8 = fun _ctx ->
  Test.assert_equal ~expected:"你…" ~actual:(Steps.clip "你好" 4);
  Test.assert_equal ~expected:"abc" ~actual:(Steps.clip "abc" 5);
  Ok ()

let test_classify_prompts = fun _ctx ->
  let cat text =
    let c, _ = Classify.classify text in
    c
  in
  Test.assert_equal ~expected:"research" ~actual:(cat "后天上海的天气如何");
  Test.assert_equal ~expected:"research" ~actual:(cat "今天美元兑人民币汇率多少");
  Test.assert_equal ~expected:"research" ~actual:(cat "帮我查一下 riot 这个项目");
  Test.assert_equal ~expected:"research" ~actual:(cat "What is the latest version of OCaml?");
  Test.assert_equal ~expected:"coding" ~actual:(cat "这个 python 函数为什么报错");
  Test.assert_equal ~expected:"coding" ~actual:(cat "```\nlet x = 1\n```\n解释一下");
  Test.assert_equal ~expected:"coding" ~actual:(cat "现在这段代码怎么重构？");
  Test.assert_equal ~expected:"coding" ~actual:(cat "建立ocaml代码项目用三个不同的数据源对给定地区的给定日期的天气预报进行比较汇总");
  Test.assert_equal ~expected:"research" ~actual:(cat "帮我查一下怎么用 python 写一个天气爬虫");
  Test.assert_equal ~expected:"writing" ~actual:(cat "帮我润色这封邮件");
  Test.assert_equal ~expected:"general" ~actual:(cat "解释一下量子纠缠");
  Test.assert_equal ~expected:"general" ~actual:(cat "let me know your thoughts on stoicism");
  let _, hits = Classify.classify "后天上海的天气如何" in
  Test.assert_equal ~expected:[ "天气"; "后天" ] ~actual:hits;
  Ok ()

let test_feed_explains_inferred_category = fun _ctx ->
  let feed = Feed.create () in
  let ev type_ data = Feed.apply feed ~type_ ~request_id:"r1" (Json.obj data) in
  ev
    "task_started"
    [
      ("category", Json.string "research");
      ("category_source", Json.string "auto");
      ("category_hits", Json.array [ Json.string "天气"; Json.string "后天" ]);
    ];
  ev "routed" [ ("chosen", Json.string "perplexity"); ("candidates", Json.array []) ];
  match Feed.find feed "r1" with
  | None -> Error "task not in feed"
  | Some t ->
      Test.assert_equal ~expected:true ~actual:(String.starts_with ~prefix:"按内容判定为「联网检索」（命中：天气、后天）" t.Feed.route_summary);
      Ok ()

let test_feed_folds_events = fun _ctx ->
  let feed = Feed.create () in
  let ev type_ data = Feed.apply feed ~type_ ~request_id:"r1" (Json.obj data) in
  let step agent s = ev "agent_step" [ ("agent", Json.string agent); ("step", s) ] in
  ev "task_started" [ ("title", Json.string "fix the bug"); ("category", Json.string "coding"); ("source", Json.string "mcp") ];
  ev
    "routed"
    [
      ("mode", Json.string "agent");
      ("chosen", Json.string "claude_code");
      ("candidates", Json.array [ Json.obj [ ("name", Json.string "claude_code"); ("score", Json.int 90) ]; Json.obj [ ("name", Json.string "cursor_agent"); ("score", Json.int 80) ] ]);
      ("rejected", Json.array [ Json.obj [ ("name", Json.string "kimi_cli"); ("reason", Json.string "circuit_open") ] ]);
    ];
  ev "attempt_started" [ ("account", Json.string "claude_code") ];
  step "claude_code" (Steps.thinking ~delta:true "pla");
  step "claude_code" (Steps.thinking ~delta:true "n");
  step "claude_code" (Steps.tool ~id:"t1" ~name:"Bash" ~input:(Json.obj [ ("command", Json.string "ls") ]));
  step "claude_code" (Steps.narration "DONE");
  ev "task_done" [ ("chosen", Json.string "claude_code"); ("ok", Json.bool true) ];
  match Feed.find feed "r1" with
  | None -> Error "task not in feed"
  | Some t ->
      Test.assert_equal ~expected:"ok" ~actual:t.Feed.status;
      Test.assert_equal ~expected:"claude_code" ~actual:t.Feed.executor;
      Test.assert_equal ~expected:"mcp" ~actual:t.Feed.source;
      Test.assert_equal ~expected:"DONE" ~actual:t.Feed.answer;
      Test.assert_equal ~expected:true ~actual:(String.contains t.Feed.route_summary "claude_code");
      Test.assert_equal ~expected:true ~actual:(String.contains t.Feed.route_summary "熔断");
      (* route, attempt, merged thinking, tool, text, done *)
      Test.assert_equal ~expected:6 ~actual:(List.length t.Feed.timeline);
      let thinking =
        List.find t.Feed.timeline ~fn:(fun e -> String.equal (sfield e "step") "thinking")
      in
      Test.assert_equal ~expected:(Some "plan") ~actual:(thinking |> Option.map ~fn:(fun e -> sfield e "text"));
      Ok ()

let test_agent_fit = fun _ctx ->
  let a = mk_agent ~tier:5 ~strengths:[ "coding" ] "x" in
  Test.assert_equal ~expected:100 ~actual:(Agent.fit a ~category:"coding");
  Test.assert_equal ~expected:90 ~actual:(Agent.fit a ~category:"writing");
  Ok ()

let mk_config_agents = fun ~accounts ~kb ~routes ~max_fallback ~agents ->
  {
    Config.server_host = "127.0.0.1";
    server_port = 0;
    data_dir = unique_dir "gw";
    auth_token_env = None;
    workspace_dir = "";
    accounts;
    agents;
    kb;
    policy =
      {
        Config.goal = "balanced";
        routes;
        agent_categories = [ "coding" ];
        max_fallback;
        max_handoffs = 2;
        handoff_notice = true;
        session_ttl_s = 600;
        explore_every = 0;
        judge = "";
        judge_every = 10;
      };
  }

let test_gateway_agent_non_stream_and_fallback = fun _ctx ->
  (* coding 类别自动走 agent；agent A 失败 -> agent B 接上 *)
  let kb = [ mk_kb_model "m-x" ] in
  let config =
    mk_config_agents
      ~accounts:[ mk_account "acc_api" ]
      ~agents:
        [
          mk_agent ~args:[ fix "agent_fail.sh" ] "agent_a";
          mk_agent ~args:[ fix "agent_ok.sh" ] "agent_b";
        ]
      ~kb
      ~routes:[]
      ~max_fallback:1
  in
  (
    match Gateway.start ~config_path:None ~config ~port:0 () with
    | Error e -> Error ("gateway: " ^ e)
    | Ok gw_pool -> (
        let body =
          Json.to_string
            (Json.obj
              [
                ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "写一个函数") ] ]);
                ("max_tokens", Json.int 128);
              ])
        in
        (
          match
            gw_post
              ~port:gw_pool.port
              ~path:"/v1/chat/completions"
              ~headers:[ ("X-Oasis-Category", "coding"); ("Content-Type", "application/json") ]
              ~body
          with
          | Error e -> Error ("agent: " ^ e)
          | Ok (status, resp_body) ->
              Test.assert_equal ~expected:200 ~actual:status;
              Test.assert_equal
                ~expected:true
                ~actual:(String.contains resp_body "hello from fake agent");
              let dec = gw_get ~port:gw_pool.port ~path:"/api/decisions" in
              (
                match dec with
                | Error e -> Error e
                | Ok (_, dec_body) ->
                    Test.assert_equal
                      ~expected:true
                      ~actual:(String.contains dec_body "\"chosen\":\"agent_b\"");
                    Test.assert_equal
                      ~expected:true
                      ~actual:(String.contains dec_body "\"account\":\"agent_a\"");
                    Ok ()
              )
        )
      )
  )

let test_gateway_feed_records_agent_steps = fun _ctx ->
  let config =
    mk_config_agents
      ~accounts:[ mk_account "acc_api" ]
      ~agents:[ mk_agent ~command:(fix "claude") ~args:[ "{prompt}" ] "fake_claude" ]
      ~kb:[ mk_kb_model "m-x" ]
      ~routes:[]
      ~max_fallback:0
  in
  match Gateway.start ~config_path:None ~config ~port:0 () with
  | Error e -> Error ("gateway: " ^ e)
  | Ok gw -> (
      let body =
        Json.to_string
          (Json.obj
            [
              ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "列一下 /tmp") ] ]);
              ("max_tokens", Json.int 64);
            ])
      in
      match
        gw_post
          ~port:gw.port
          ~path:"/v1/chat/completions"
          ~headers:[ ("X-Oasis-Category", "coding"); ("Content-Type", "application/json"); ("X-Oasis-Source", "dashboard") ]
          ~body
      with
      | Error e -> Error ("chat: " ^ e)
      | Ok (status, resp) -> (
          Test.assert_equal ~expected:200 ~actual:status;
          Test.assert_equal ~expected:true ~actual:(String.contains resp "DONE");
          Test.assert_equal ~expected:false ~actual:(String.contains resp "ls /tmp");
          match gw_get ~port:gw.port ~path:"/api/feed" with
          | Error e -> Error e
          | Ok (_, feed_body) -> (
              let id =
                Json.from_string feed_body |> Result.to_option
                |> Option.and_then ~fn:(Json.get_field "tasks")
                |> Option.and_then ~fn:Json.get_array
                |> Option.and_then ~fn:List.head
                |> Option.and_then ~fn:(fun t -> Steps.str t "id")
              in
              match id with
              | None -> Error ("no task in feed: " ^ feed_body)
              | Some id -> (
                  match gw_get ~port:gw.port ~path:("/api/feed/task?id=" ^ id) with
                  | Error e -> Error e
                  | Ok (_, task) -> (
                      let missing =
                        List.find
                          [ "\"status\":\"ok\""; "\"source\":\"dashboard\""; "列一下 /tmp"; "\"step\":\"tool\""; "ls /tmp | head -3";
                            "\"step\":\"tool_result\""; "\"step\":\"thinking\""; "\"kind\":\"attempt_end\"" ]
                          ~fn:(fun needle -> not (String.contains task needle))
                      in
                      match missing with
                      | Some needle -> Error ("feed task lacks " ^ needle ^ ": " ^ task)
                      | None -> Ok ()
                    )
                )
            )
        )
    )

let test_gateway_agent_stream_and_explicit_chat = fun _ctx ->
  let kb = [ mk_kb_model "m-x" ] in
  let config =
    mk_config_agents
      ~accounts:[ mk_account "acc_api" ]
      ~agents:[ mk_agent ~args:[ fix "agent_ok.sh" ] "agent_a" ]
      ~kb
      ~routes:[]
      ~max_fallback:0
  in
  (
    match Gateway.start ~config_path:None ~config ~port:0 () with
    | Error e -> Error ("gateway: " ^ e)
    | Ok gw_pool -> (
        let body =
          Json.to_string
            (Json.obj
              [
                ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "hi") ] ]);
                ("max_tokens", Json.int 128);
                ("stream", Json.bool true);
              ])
        in
        (
          match
            gw_stream_collect
              ~port:gw_pool.port
              ~path:"/v1/chat/completions"
              ~headers:[ ("X-Oasis-Category", "coding"); ("Content-Type", "application/json") ]
              ~body
          with
          | Error e -> Error ("stream: " ^ e)
          | Ok (status, events, _raw) ->
              Test.assert_equal ~expected:200 ~actual:status;
              let done_seen = List.any events ~fn:(fun ev -> ev.Sse.done_sentinel) in
              Test.assert_equal ~expected:true ~actual:done_seen;
              let contents = List.filter_map events ~fn:extract_choice_text in
              Test.assert_equal
                ~expected:true
                ~actual:(String.contains (String.concat "" contents) "hello from fake agent");
              Ok ()
        )
      )
  )

(* ---------- MCP endpoint ---------- *)

let test_mcp_parse = fun _ctx ->
  let r = Mcp.parse "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"params\":{}}" in
  (
    match r with
    | Error e -> Error e
    | Ok rpc ->
        Test.assert_equal ~expected:"tools/list" ~actual:rpc.Mcp.method_;
        Test.assert_equal
          ~expected:true
          ~actual:(match rpc.Mcp.id with Some (Json.Int 7) -> true | _ -> false);
        let notif = Mcp.parse "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" in
        (
          match notif with
          | Error e -> Error e
          | Ok n ->
              Test.assert_equal ~expected:true ~actual:(Mcp.is_notification n);
              Ok ()
        )
  )

type Message.t += Agent_collect_done of (string, string) result

let test_agent_home_env_injection = fun _ctx ->
  let a = mk_agent ~args:[ fix "agent_home.sh" ] ~home:"/custom/home" "agent_home" in
  let me = self () in
  let _ =
    Runtime.spawn_blocked (fun () ->
      let res = Agent.collect ~agent:a ~model:"" ~prompt:"" () in
      send me (Agent_collect_done res);
      Ok ())
  in
  let selector msg =
    match msg with
    | Agent_collect_done r -> Select r
    | _ -> Skip
  in
  match receive ~selector ~timeout:(Time.Duration.from_secs 30) () with
  | Ok txt ->
      Test.assert_equal ~expected:true ~actual:(String.contains txt "/custom/home");
      Ok ()
  | Error e -> Error ("collect failed: " ^ e)
  | exception Receive_timeout -> Error "collect timeout"

let test_gateway_agent_async_task = fun _ctx ->
  let config =
    mk_config_agents
      ~accounts:[ mk_account "acc_api" ]
      ~agents:[ mk_agent ~args:[ fix "agent_ok.sh" ] ~timeout_s:20 "agent_async" ]
      ~kb:[ mk_kb_model "m-x" ]
      ~routes:[]
      ~max_fallback:0
  in
  (
    match Gateway.start ~config_path:None ~config ~port:0 () with
    | Error e -> Error ("gateway: " ^ e)
    | Ok gw_pool -> (
        let mcp_post body =
          gw_post
            ~port:gw_pool.port
            ~path:"/mcp"
            ~headers:[ ("Content-Type", "application/json") ]
            ~body
        in
        let submit =
          mcp_post
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"oasis_agent_task\",\"arguments\":{\"prompt\":\"hi\",\"category\":\"coding\"}}}"
        in
        (
          match submit with
          | Error e -> Error ("submit: " ^ e)
          | Ok (s1, b1) ->
              Test.assert_equal ~expected:200 ~actual:s1;
              (* extract task_id from the text *)
              let text1 =
                match Json.from_string b1 with
                | Ok j -> (
                    match Json.get_field "result" j with
                    | None -> ""
                    | Some r -> (
                        match Json.get_field "content" r |> Option.and_then ~fn:Json.get_array |> Option.and_then ~fn:List.head with
                        | None -> ""
                        | Some blk -> Json.get_field "text" blk |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:""
                      )
                  )
                | Error _ -> ""
              in
              let task_id =
                let parts = String.split ~by:" " text1 in
                match parts with
                | "task" :: "started:" :: tid :: _ -> tid
                | _ -> ""
              in
              Test.assert_equal
                ~expected:false
                ~actual:(String.is_empty task_id);
              (* poll until done (fake agent is fast) *)
              let rec poll n =
                if n > 10 then
                  Error "task never finished"
                else
                  let body =
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"oasis_task_status\",\"arguments\":{\"task_id\":\""
                    ^ task_id ^ "\"}}}"
                  in
                  (
                    match mcp_post body with
                    | Error e -> Error ("poll: " ^ e)
                    | Ok (_, b2) -> (
                        match Json.from_string b2 with
                        | Error _ -> Error "bad json"
                        | Ok j -> (
                            match
                              Json.get_field "result" j
                              |> Option.and_then ~fn:(fun r ->
                                Json.get_field "content" r
                                |> Option.and_then ~fn:Json.get_array
                                |> Option.and_then ~fn:List.head
                                |> Option.and_then ~fn:(fun blk -> Json.get_field "text" blk)
                                |> Option.and_then ~fn:Json.get_string)
                            with
                            | None -> Error "no text"
                            | Some t ->
                                if String.contains t "running" then (
                                  sleep (Time.Duration.from_millis 200);
                                  poll (n + 1)
                                ) else if String.contains t "hello from fake agent" then
                                  Ok ()
                                else
                                  Error ("unexpected status: " ^ t)
                          )
                      )
                  )
              in
              (
                match
                  mcp_post
                    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"oasis_task_status\",\"arguments\":{\"task_id\":\"task-from-before-restart\"}}}"
                with
                | Error e -> Error ("stale poll: " ^ e)
                | Ok (_, b3) ->
                    Test.assert_equal ~expected:true ~actual:(String.contains b3 "\"text\":\"unknown: no task task-from-before-restart");
                    Test.assert_equal ~expected:false ~actual:(String.contains b3 "\"isError\":true");
                    poll 0
              )
        )
      )
  )

let test_inbox_bus = fun _ctx ->
  let dir = unique_dir "inbox" in
  let t = Inbox.init ~dir in
  let id1 = Inbox.deliver t ~from:"agent_a" ~to_agent:"agent_b" ~text:"hello b" |> Result.unwrap in
  Test.assert_equal ~expected:false ~actual:(String.is_empty id1);
  let _ = Inbox.deliver t ~from:"user" ~to_agent:"agent_b" ~text:"second" in
  let unread = Inbox.check t ~agent:"agent_b" in
  Test.assert_equal ~expected:2 ~actual:(List.length unread);
  (* check again: now empty *)
  let again = Inbox.check t ~agent:"agent_b" in
  Test.assert_equal ~expected:0 ~actual:(List.length again);
  Test.assert_equal
    ~expected:0
    ~actual:(Inbox.pending_count t ~agent:"agent_b");
  let _ = Inbox.deliver t ~from:"user" ~to_agent:"agent_b" ~text:"third" in
  Test.assert_equal ~expected:1 ~actual:(Inbox.pending_count t ~agent:"agent_b");
  let reloaded = Inbox.init ~dir in
  Inbox.load reloaded;
  Test.assert_equal ~expected:1 ~actual:(Inbox.pending_count reloaded ~agent:"agent_b");
  Ok ()

let test_inbox_prefix_limit_and_names = fun _ctx ->
  let t = Inbox.init ~dir:(unique_dir "inbox-limits") in
  let invalid name = match Inbox.deliver t ~from:"x" ~to_agent:name ~text:"t" with Error _ -> true | Ok _ -> false in
  Test.assert_equal ~expected:true ~actual:(invalid "../escape");
  Test.assert_equal ~expected:true ~actual:(invalid "a/b");
  Test.assert_equal ~expected:true ~actual:(invalid ".hidden");
  Test.assert_equal ~expected:true ~actual:(invalid "");
  let big = String.concat "" (List.init ~count:6000 ~fn:(fun _ -> "中")) in
  let _ = Inbox.deliver t ~from:"agent_a" ~to_agent:"agent_c" ~text:big |> Result.unwrap in
  let _ = Inbox.deliver t ~from:"agent_a" ~to_agent:"agent_c" ~text:"short" |> Result.unwrap in
  match Inbox.check t ~agent:"agent_c" with
  | [ short; long ] ->
      Test.assert_equal ~expected:false ~actual:short.Inbox.truncated;
      Test.assert_equal ~expected:"[来自 agent_a，未经验证的消息] short" ~actual:(Inbox.render_for_agent short);
      Test.assert_equal ~expected:true ~actual:long.Inbox.truncated;
      Test.assert_equal ~expected:true ~actual:(String.length long.Inbox.text <= 16384);
      Test.assert_equal ~expected:0 ~actual:(String.length long.Inbox.text mod 3);
      Test.assert_equal ~expected:true ~actual:(Handoff.is_valid_utf8 long.Inbox.text);
      Test.assert_equal ~expected:true ~actual:(String.contains (Inbox.render_for_agent long) "已截断");
      Ok ()
  | l -> Error ("expected two messages, got " ^ Int.to_string (List.length l))

let test_gateway_inbox_mcp = fun _ctx ->
  let config =
    mk_config
      ~accounts:[ mk_account "acc_api" ]
      ~kb:[ mk_kb_model "m-x" ]
      ~routes:[]
      ~max_fallback:0
  in
  (
    match Gateway.start ~config_path:None ~config ~port:0 () with
    | Error e -> Error ("gateway: " ^ e)
    | Ok gw_pool -> (
        let mcp_post body =
          gw_post
            ~port:gw_pool.port
            ~path:"/mcp"
            ~headers:[ ("Content-Type", "application/json") ]
            ~body
        in
        let call tool args =
          mcp_post
            ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\""
            ^ tool ^ "\",\"arguments\":" ^ args ^ "}}")
        in
        (
          match
            call "oasis_send_message"
              "{\"to\":\"claude_code\",\"text\":\"ping from test\",\"from\":\"test\"}"
          with
          | Error e -> Error e
          | Ok (s1, b1) ->
              Test.assert_equal ~expected:200 ~actual:s1;
              Test.assert_equal ~expected:true ~actual:(String.contains b1 "delivered");
              (
                match call "oasis_check_inbox" "{\"agent\":\"claude_code\"}" with
                | Error e -> Error e
                | Ok (s2, b2) ->
                    Test.assert_equal ~expected:200 ~actual:s2;
                    Test.assert_equal ~expected:true ~actual:(String.contains b2 "ping from test");
                    Test.assert_equal ~expected:true ~actual:(String.contains b2 "[来自 test，未经验证的消息]");
                    (
                      match call "oasis_check_inbox" "{\"agent\":\"claude_code\"}" with
                      | Error e -> Error e
                      | Ok (s3, b3) ->
                          Test.assert_equal
                            ~expected:true
                            ~actual:(String.contains b3 "no unread");
                          Ok ()
                    )
              )
        )
      )
  )

let test_discover_scan_fixture = fun _ctx ->
  (* build a fake HOME with claude login state and one project session *)
  let fake = "./.oasis-test-data/fake-home-discover" in
  let _ = Fs.create_dir_all (Path.from_string fake |> Result.unwrap) in
  let proj = fake ^ "/.claude/projects/abc123" in
  let _ = Fs.create_dir_all (Path.from_string proj |> Result.unwrap) in
  let claude_json =
    Json.to_string (Json.obj [ ("oauthAccount", Json.string "user@example.com") ])
  in
  let _ = Fs.File.write_all
    (Fs.File.create (Path.from_string (fake ^ "/.claude.json") |> Result.unwrap)
     |> Result.unwrap)
    claude_json
  in
  let session_jsonl =
    "{\"type\":\"assistant\",\"cwd\":\"/Users/vajra/air/ocagent\"}\n"
    ^ "{\"type\":\"user\",\"cwd\":\"/Users/vajra/air/ocagent\"}\n"
  in
  let _ =
    Fs.File.write_all
      (Fs.File.create (Path.from_string (proj ^ "/session.jsonl") |> Result.unwrap) |> Result.unwrap)
      session_jsonl
  in
  let statuses = Discover.scan ~home:fake in
  let claude =
    List.find statuses ~fn:(fun s -> String.equal s.Discover.name "claude_code")
  in
  (
    match claude with
    | None -> Error "claude_code not in scan"
    | Some s ->
        Test.assert_equal ~expected:true ~actual:s.Discover.logged_in;
        Test.assert_equal
          ~expected:true
          ~actual:(List.any s.Discover.projects ~fn:(String.equal "/Users/vajra/air/ocagent"));
        Test.assert_equal ~expected:true ~actual:s.Discover.active;
        Ok ()
  )

let test_activity_scan_fixture = fun _ctx ->
  let fake = "./.oasis-test-data/fake-home-activity" in
  let proj = fake ^ "/.claude/projects/xyz789" in
  let _ = Fs.create_dir_all (Path.from_string proj |> Result.unwrap) in
  let lines =
    "{\"type\":\"user\",\"sessionId\":\"s1\",\"cwd\":\"/Users/vajra/demo\",\"message\":{\"role\":\"user\",\"content\":\"帮我重构登录模块\"}}\n"
    ^ "{\"type\":\"assistant\",\"sessionId\":\"s1\",\"cwd\":\"/Users/vajra/demo\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"好的，我先看看现有代码\"},{\"type\":\"tool_use\",\"name\":\"bash\"}]}}\n"
  in
  let _ =
    Fs.File.write_all
      (Fs.File.create (Path.from_string (proj ^ "/sess.jsonl") |> Result.unwrap) |> Result.unwrap)
      lines
  in
  let summaries = Activity.scan ~home:fake ~limit:10 in
  (
    match List.head summaries with
    | None -> Error "no summaries"
    | Some s ->
        Test.assert_equal ~expected:"/Users/vajra/demo" ~actual:s.Activity.project;
        Test.assert_equal ~expected:2 ~actual:s.Activity.turns;
        Test.assert_equal
          ~expected:true
          ~actual:(String.contains s.Activity.last_excerpt "好的");
        Ok ()
  )

let test_signals_release_in_flight = fun _ctx ->
  let s = Signals.mark_in_flight (Signals.fresh ()) in
  Test.assert_equal ~expected:1 ~actual:s.Signals.in_flight;
  let s2 = Signals.release_in_flight s in
  Test.assert_equal ~expected:0 ~actual:s2.Signals.in_flight;
  (* no breaker impact *)
  Test.assert_equal ~expected:true ~actual:(Signals.breaker_allows s2 (Signals.now_ms ()));
  Ok ()

let test_config_enabled_false_parses = fun _ctx ->
  let src =
    {|
[server]
host = "127.0.0.1"
port = 8788
data_dir = "./.oasis-test-data"

[[agents]]
name = "bad_agent"
command = "sh"
enabled = false

[[agents]]
name = "good_agent"
command = "sh"
enabled = true
|}
  in
  let path = "./.oasis-test-config2.toml" in
  let _ =
    Fs.File.write_all
      (Fs.File.create (Path.from_string path |> Result.unwrap) |> Result.unwrap)
      src
  in
  match Config.load path with
  | Error e -> Error ("config load failed: " ^ e)
  | Ok cfg ->
      let bad = List.find cfg.Config.agents ~fn:(fun a -> String.equal a.Agent.name "bad_agent") in
      let good = List.find cfg.Config.agents ~fn:(fun a -> String.equal a.Agent.name "good_agent") in
      (
        match (bad, good) with
        | (Some b, Some g) ->
            Test.assert_equal ~expected:false ~actual:b.Agent.enabled;
            Test.assert_equal ~expected:true ~actual:g.Agent.enabled;
            Ok ()
        | _ -> Error "agents missing"
      )

(* ---------- spec 0.3 §3.6: handoff acceptance H1–H8 ---------- *)

let start_mocks = fun n ->
  let rec go k acc =
    if k = 0 then Ok (List.rev acc)
    else
      match Mock.start () with
      | Error e -> Error ("mock start: " ^ e)
      | Ok m -> go (k - 1) (m :: acc)
  in
  go n []

let acc_name = fun i -> "acc_" ^ Int.to_string i

let handoff_config = fun ?(prefill = fun _ -> true) ?(max_handoffs = 2) mocks ->
  let accounts =
    List.enumerate mocks
    |> List.map ~fn:(fun (i, (m : Mock.t)) ->
      {
        (mk_account ~models:[ "m-x" ] ~prefill:(prefill i) (acc_name i)) with
        Config.base_url = "http://127.0.0.1:" ^ Int.to_string m.pool.port;
      })
  in
  let base =
    mk_config
      ~accounts
      ~kb:[ mk_kb_model "m-x" ]
      ~routes:[ { Config.category = "general"; accounts = List.map accounts ~fn:(fun a -> a.Config.name) } ]
      ~max_fallback:(List.length mocks)
  in
  { base with Config.policy = { base.Config.policy with Config.max_handoffs } }

(** A stream that delivers [first] and then dies inside the next frame. *)
let dying_after = fun first rest ->
  {
    (Mock.default_scenario) with
    sse = first :: rest;
    cut_after_bytes =
      String.length (Mock.stream_header 200)
      + String.length (Mock.chunked_frame ("data: " ^ first ^ "\n\n"))
      + 3;
  }

let h_stream = fun ?(headers = []) ?(extra = []) ~port () ->
  let body =
    Json.to_string
      (Json.obj
        ([
           ("model", Json.string "m-x");
           ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "q") ] ]);
           ("max_tokens", Json.int 64);
           ("stream", Json.bool true);
         ]
        @ extra))
  in
  match
    gw_stream_collect
      ~port
      ~path:"/v1/chat/completions"
      ~headers:(("X-Oasis-Category", "general") :: ("Content-Type", "application/json") :: headers)
      ~body
  with
  | Error e -> Error e
  | Ok (status, events, _) ->
      let deltas = List.filter_map events ~fn:extract_choice_text in
      Ok (status, events, deltas)

let latest_handoffs = fun ~port ->
  match gw_get ~port ~path:"/api/decisions" with
  | Error e -> Error e
  | Ok (_, body) -> (
      match
        Json.from_string body |> Result.to_option
        |> Option.and_then ~fn:(fun j -> Json.get_field "decisions" j)
        |> Option.and_then ~fn:Json.get_array
        |> Option.and_then ~fn:List.head
      with
      | None -> Error ("no decisions: " ^ body)
      | Some d ->
          Ok
            (Json.get_field "handoffs" d |> Option.and_then ~fn:Json.get_array
            |> Option.unwrap_or ~default:[])
    )

let h_field_str = fun h k -> Json.get_field k h |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:""
let h_field_int = fun h k -> Json.get_field k h |> Option.and_then ~fn:Json.get_int |> Option.unwrap_or ~default:(-1)

let notice_for = fun i -> "\n\n[Oasis: 上游中断，已切换到 " ^ acc_name i ^ " 重新生成]\n\n"

(** Runs one handoff scenario: [setup] programs the mocks, [check] inspects
    the client deltas, the latest decision's handoffs and the mocks. *)
let handoff_case = fun ?prefill ?max_handoffs ?(extra = []) ?(headers = []) ~n ~setup ~check () ->
  match start_mocks n with
  | Error e -> Error e
  | Ok mocks -> (
      setup mocks;
      match Gateway.start ~config_path:None ~config:(handoff_config ?prefill ?max_handoffs mocks) ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          let res = h_stream ~headers ~extra ~port:gw.port () in
          match res with
          | Error e -> Error e
          | Ok (status, events, deltas) -> (
              if status != 200 then Error ("status " ^ Int.to_string status)
              else
                match latest_handoffs ~port:gw.port with
                | Error e -> Error e
                | Ok handoffs -> check ~gw ~mocks ~events ~deltas ~handoffs
            )
        )
    )

let nth_mock = fun mocks i -> List.get_unchecked mocks ~at:i

(** Minimal dashboard WebSocket client: handshake, then server frames
    (unmasked) are decoded into text payloads. *)
let ws_connect = fun ~port ->
  match Net.TcpStream.connect (Net.Addr.tcp Net.Addr.loopback port) with
  | Error _ -> Error "ws connect failed"
  | Ok s ->
      let req =
        IO.Bytes.from_string
          "GET /ws HTTP/1.1\r\nHost: gw\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
      in
      let _ = Net.TcpStream.write s req ~pos:0 ~len:(IO.Bytes.length req) () in
      let buf = IO.Bytes.create ~size:65536 in
      let rec head acc =
        match String.split ~by:"\r\n\r\n" acc with
        | h :: (_ :: _ as rest) ->
            if String.contains h " 101 " then Ok (s, String.concat "\r\n\r\n" rest)
            else Error ("ws handshake: " ^ h)
        | _ -> (
            match Net.TcpStream.read s buf ~timeout:(Time.Duration.from_secs 5) () with
            | Ok n when n > 0 -> head (acc ^ IO.Bytes.sub_string buf ~offset:0 ~len:n)
            | _ -> Error "ws handshake: no response"
          )
      in
      head ""

let ws_frames = fun data ->
  let byte i = Char.to_int (String.get_unchecked data ~at:i) in
  let total = String.length data in
  let rec go pos acc =
    if pos + 2 > total then (List.rev acc, String.sub data ~offset:pos ~len:(total - pos))
    else
      let l7 = byte (pos + 1) land 0x7f in
      let (len, hdr) =
        if l7 = 126 then
          if pos + 4 > total then (-1, 0) else ((byte (pos + 2) lsl 8) lor byte (pos + 3), 4)
        else if l7 = 127 then
          if pos + 10 > total then (-1, 0)
          else (List.fold_left [ 2; 3; 4; 5; 6; 7; 8; 9 ] ~init:0 ~fn:(fun a k -> (a lsl 8) lor byte (pos + k)), 10)
        else (l7, 2)
      in
      if len < 0 || pos + hdr + len > total then (List.rev acc, String.sub data ~offset:pos ~len:(total - pos))
      else go (pos + hdr + len) (String.sub data ~offset:(pos + hdr) ~len :: acc)
  in
  go 0 []

(** Reads dashboard events until one satisfies [stop] (or reads time out). *)
let ws_collect_events = fun (s, leftover) ~stop ->
  let buf = IO.Bytes.create ~size:65536 in
  let rec loop pending acc =
    let (frames, rest) = ws_frames pending in
    let events =
      List.filter_map frames ~fn:(fun f ->
        match Json.from_string f with
        | Ok j when String.equal (h_field_str j "type") "event" -> Some j
        | _ -> None)
    in
    let acc = acc @ events in
    if List.any events ~fn:stop then acc
    else
      match Net.TcpStream.read s buf ~timeout:(Time.Duration.from_secs 3) () with
      | Ok n when n > 0 -> loop (rest ^ IO.Bytes.sub_string buf ~offset:0 ~len:n) acc
      | _ -> acc
  in
  let evs = loop leftover [] in
  Net.TcpStream.close s;
  evs

let expect_level = fun handoffs lvl ->
  match handoffs with
  | [ h ] ->
      if String.equal (h_field_str h "level") lvl then Ok h
      else Error ("expected " ^ lvl ^ ", got " ^ Json.to_string h)
  | _ -> Error ("expected one handoff, got " ^ Int.to_string (List.length handoffs))

let test_h1_exact_replay = fun _ctx ->
  handoff_case ~n:2
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) (dying_after "ev1" [ "ev2" ]);
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ " ev2 ev3" ]; echo_prefix = Mock.Echo_exact })
    ~check:(fun ~gw:_ ~mocks ~events:_ ~deltas ~handoffs ->
      Test.assert_equal ~expected:"ev1 ev2 ev3" ~actual:(String.concat "" deltas);
      let req_b = Mock.last_request (nth_mock mocks 1) in
      Test.assert_equal ~expected:(Some "ev1") ~actual:(Mock.assistant_prefix req_b);
      match expect_level handoffs "G1" with
      | Error e -> Error e
      | Ok h ->
          Test.assert_equal ~expected:3 ~actual:(h_field_int h "matched_bytes");
          Test.assert_equal ~expected:"acc_0" ~actual:(h_field_str h "from");
          Test.assert_equal ~expected:"acc_1" ~actual:(h_field_str h "to");
          Ok ())
    ()

let test_stream_finish_reason_without_done = fun _ctx ->
  handoff_case ~n:2
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0)
        {
          (Mock.default_scenario) with
          sse =
            [
              "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"alpha \"}}]}";
              "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"beta\"},\"finish_reason\":\"stop\"}]}";
            ];
          send_done = false;
        };
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ "unused" ] })
    ~check:(fun ~gw:_ ~mocks:_ ~events:_ ~deltas ~handoffs ->
      Test.assert_equal ~expected:"alpha beta" ~actual:(String.concat "" deltas);
      Test.assert_equal ~expected:0 ~actual:(List.length handoffs);
      Ok ())
    ()

let test_stream_eof_without_finish_is_a_cut = fun _ctx ->
  handoff_case ~n:2
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) { (Mock.default_scenario) with sse = [ "ev1" ]; send_done = false };
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ " ev2" ]; echo_prefix = Mock.Echo_exact })
    ~check:(fun ~gw:_ ~mocks:_ ~events:_ ~deltas ~handoffs ->
      Test.assert_equal ~expected:"ev1 ev2" ~actual:(String.concat "" deltas);
      match expect_level handoffs "G1" with
      | Error e -> Error e
      | Ok h ->
          Test.assert_equal ~expected:"upstream_stream_ended_early" ~actual:(h_field_str h "reason");
          Ok ())
    ()

let reasoning_only_sse =
  [
    "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\",\"reasoning_content\":\"let me think\"}}]}";
    "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\",\"reasoning_content\":\" harder\"},\"finish_reason\":\"length\"}]}";
  ]

let test_stream_reasoning_only_fails_over = fun _ctx ->
  match start_mocks 2 with
  | Error e -> Error e
  | Ok mocks -> (
      Mock.set_scenario (nth_mock mocks 0) { (Mock.default_scenario) with sse = reasoning_only_sse };
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ "answer" ] };
      match Gateway.start ~config_path:None ~config:(handoff_config mocks) ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          match ws_connect ~port:gw.port with
          | Error e -> Error e
          | Ok ws -> (
              sleep (Time.Duration.from_millis 100);
              match h_stream ~port:gw.port () with
              | Error e -> Error e
              | Ok (_, _, deltas) ->
                  Test.assert_equal ~expected:"answer" ~actual:(String.concat "" deltas);
                  let evs =
                    ws_collect_events ws ~stop:(fun j -> String.equal (h_field_str j "event") "task_done")
                  in
                  let data j = Json.get_field "data" j |> Option.unwrap_or ~default:(Json.obj []) in
                  let is ev j = String.equal (h_field_str j "event") ev in
                  let first_fail =
                    List.find evs ~fn:(fun j -> is "attempt_finished" j && String.equal (h_field_str (data j) "account") "acc_0")
                  in
                  Test.assert_equal
                    ~expected:"empty_answer_reasoning_exhausted"
                    ~actual:(first_fail |> Option.map ~fn:(fun j -> h_field_str (data j) "error") |> Option.unwrap_or ~default:"");
                  let thinking =
                    List.filter_map evs ~fn:(fun j ->
                      if is "agent_step" j then
                        Json.get_field "step" (data j) |> Option.map ~fn:(fun st -> h_field_str st "text")
                      else None)
                  in
                  Test.assert_equal ~expected:"let me think harder" ~actual:(String.concat "" thinking);
                  Test.assert_equal ~expected:false ~actual:(List.any evs ~fn:(is "handoff"));
                  Ok ()
            )
        )
    )

let test_nonstream_empty_answer_fails_over = fun _ctx ->
  match start_mocks 2 with
  | Error e -> Error e
  | Ok mocks -> (
      Mock.set_scenario (nth_mock mocks 0)
        {
          (Mock.default_scenario) with
          body =
            "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"\",\"reasoning_content\":\"hmm\"},\"finish_reason\":\"length\"}]}";
        };
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with body = openai_ok_body ~content:"real answer" };
      match Gateway.start ~config_path:None ~config:(handoff_config mocks) ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          let body =
            Json.to_string
              (Json.obj
                [
                  ("model", Json.string "m-x");
                  ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "q") ] ]);
                  ("max_tokens", Json.int 64);
                ])
          in
          match gw_post ~port:gw.port ~path:"/v1/chat/completions" ~headers:[ ("Content-Type", "application/json") ] ~body with
          | Error e -> Error e
          | Ok (status, resp) ->
              Test.assert_equal ~expected:200 ~actual:status;
              Test.assert_equal ~expected:true ~actual:(String.contains resp "real answer");
              Ok ()
        )
    )

let test_ws_events_trace_streaming_handoff = fun _ctx ->
  match start_mocks 2 with
  | Error e -> Error e
  | Ok mocks -> (
      Mock.set_scenario (nth_mock mocks 0) (dying_after "ev1" [ "ev2" ]);
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ " ev2 ev3" ]; echo_prefix = Mock.Echo_exact };
      match Gateway.start ~config_path:None ~config:(handoff_config mocks) ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          match ws_connect ~port:gw.port with
          | Error e -> Error e
          | Ok ws -> (
              (* the server registers the socket right after writing the 101 *)
              sleep (Time.Duration.from_millis 100);
              match h_stream ~port:gw.port () with
              | Error e -> Error e
              | Ok (_, _, deltas) ->
                  Test.assert_equal ~expected:"ev1 ev2 ev3" ~actual:(String.concat "" deltas);
                  let evs =
                    ws_collect_events ws ~stop:(fun j -> String.equal (h_field_str j "event") "task_done")
                  in
                  let data j = Json.get_field "data" j |> Option.unwrap_or ~default:(Json.obj []) in
                  let tag j =
                    let d = data j in
                    let acct = h_field_str d "account" in
                    h_field_str j "event" ^ (if String.is_empty acct then "" else ":" ^ acct)
                  in
                  let tags = List.map evs ~fn:tag in
                  let expected =
                    [
                      "task_started";
                      "routed";
                      "attempt_started:acc_0";
                      "attempt_finished:acc_0";
                      "attempt_started:acc_1";
                      "handoff";
                      "attempt_finished:acc_1";
                      "task_done";
                    ]
                  in
                  Test.assert_equal ~expected:(String.concat " " expected) ~actual:(String.concat " " tags);
                  match List.find evs ~fn:(fun j -> String.equal (h_field_str j "event") "handoff") with
                  | None -> Error "no handoff event"
                  | Some j ->
                      let h = data j in
                      Test.assert_equal ~expected:"G1" ~actual:(h_field_str h "level");
                      Test.assert_equal ~expected:3 ~actual:(h_field_int h "matched_bytes");
                      Test.assert_equal ~expected:3 ~actual:(h_field_int h "sent_bytes");
                      Test.assert_equal ~expected:(Some false) ~actual:(Json.get_field "diverged" h |> Option.and_then ~fn:Json.get_bool);
                      let done_ = List.rev evs |> List.head |> Option.map ~fn:data |> Option.unwrap_or ~default:(Json.obj []) in
                      Test.assert_equal ~expected:"acc_1" ~actual:(h_field_str done_ "chosen");
                      Test.assert_equal ~expected:(Some true) ~actual:(Json.get_field "ok" done_ |> Option.and_then ~fn:Json.get_bool);
                      Ok ()
            )
        )
    )

let test_h2_direct_continuation = fun _ctx ->
  handoff_case ~n:2
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) (dying_after "ev1" [ "ev2" ]);
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ " ev2 ev3" ] })
    ~check:(fun ~gw:_ ~mocks:_ ~events:_ ~deltas ~handoffs ->
      Test.assert_equal ~expected:"ev1 ev2 ev3" ~actual:(String.concat "" deltas);
      match expect_level handoffs "G1" with
      | Error e -> Error e
      | Ok h ->
          Test.assert_equal ~expected:0 ~actual:(h_field_int h "matched_bytes");
          Ok ())
    ()

let test_h3_multibyte_divergence = fun _ctx ->
  handoff_case ~n:2
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) (dying_after "你好世界" [ "后面的内容" ]);
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ "你好丢失的部分" ] })
    ~check:(fun ~gw:_ ~mocks:_ ~events:_ ~deltas ~handoffs ->
      List.for_each deltas ~fn:(fun d ->
        Test.assert_equal ~expected:true ~actual:(Handoff.is_valid_utf8 d);
        Test.assert_equal ~expected:false ~actual:(String.contains d "\xEF\xBF\xBD"));
      Test.assert_equal ~expected:"你好世界丢失的部分" ~actual:(String.concat "" deltas);
      match expect_level handoffs "G2" with
      | Error e -> Error e
      | Ok h ->
          Test.assert_equal ~expected:6 ~actual:(h_field_int h "matched_bytes");
          Ok ())
    ()

let test_h4_mutated_replay = fun _ctx ->
  let sent = "The quick brown fox" in
  handoff_case ~n:2
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) (dying_after sent [ " jumps" ]);
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ " jumps" ]; echo_prefix = Mock.Echo_mutated })
    ~check:(fun ~gw:_ ~mocks:_ ~events:_ ~deltas ~handoffs ->
      let mutated = Mock.mutate_at_60pct sent in
      let k = String.length sent * 3 / 5 in
      Test.assert_equal
        ~expected:(sent ^ String.sub mutated ~offset:k ~len:(String.length mutated - k) ^ " jumps")
        ~actual:(String.concat "" deltas);
      match expect_level handoffs "G2" with
      | Error e -> Error e
      | Ok h ->
          Test.assert_equal ~expected:k ~actual:(h_field_int h "matched_bytes");
          Ok ())
    ()

let test_h5_restart_with_notice = fun _ctx ->
  let sent = "The quick brown fox" in
  handoff_case ~n:2
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) (dying_after sent [ " jumps" ]);
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ "Tx completely new answer" ] })
    ~check:(fun ~gw:_ ~mocks:_ ~events:_ ~deltas ~handoffs ->
      Test.assert_equal
        ~expected:(sent ^ notice_for 1 ^ "Tx completely new answer")
        ~actual:(String.concat "" deltas);
      match expect_level handoffs "G3" with
      | Error e -> Error e
      | Ok _ -> Ok ())
    ()

let test_h5b_non_prefill_account_restarts = fun _ctx ->
  handoff_case ~n:2
    ~prefill:(fun i -> i = 0)
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) (dying_after "partial" [ " more" ]);
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ "fresh answer" ] })
    ~check:(fun ~gw:_ ~mocks ~events:_ ~deltas ~handoffs ->
      Test.assert_equal ~expected:("partial" ^ notice_for 1 ^ "fresh answer") ~actual:(String.concat "" deltas);
      Test.assert_equal ~expected:None ~actual:(Mock.assistant_prefix (Mock.last_request (nth_mock mocks 1)));
      match expect_level handoffs "G3" with
      | Error e -> Error e
      | Ok _ -> Ok ())
    ()

let test_h6_handoff_limit = fun _ctx ->
  handoff_case ~n:3
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) (dying_after "alpha" [ "x" ]);
      Mock.set_scenario (nth_mock mocks 1) (dying_after " beta" [ "x" ]);
      Mock.set_scenario (nth_mock mocks 2) (dying_after " gamma" [ "x" ]))
    ~check:(fun ~gw:_ ~mocks:_ ~events ~deltas ~handoffs ->
      if not (String.equal "alpha beta gamma" (String.concat "" deltas)) then
        Error ("deltas=" ^ String.concat "|" deltas ^ " handoffs=" ^ String.concat ";" (List.map handoffs ~fn:Json.to_string))
      else (
      Test.assert_equal ~expected:true ~actual:(List.any events ~fn:(fun ev -> String.contains ev.Sse.data "oasis_upstream_failed"));
      Test.assert_equal ~expected:true ~actual:(List.any events ~fn:(fun ev -> ev.Sse.done_sentinel));
      Test.assert_equal ~expected:2 ~actual:(List.length handoffs);
      Test.assert_equal ~expected:[ "G1"; "G1" ] ~actual:(List.map handoffs ~fn:(fun h -> h_field_str h "level"));
      Ok ()))
    ()

let test_h7_tools_request_restarts = fun _ctx ->
  handoff_case ~n:2
    ~extra:[ ("tools", Json.array [ Json.obj [ ("type", Json.string "function") ] ]) ]
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) (dying_after "alpha" [ "x" ]);
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ "alpha beta" ]; echo_prefix = Mock.Echo_exact })
    ~check:(fun ~gw:_ ~mocks ~events:_ ~deltas ~handoffs ->
      Test.assert_equal ~expected:None ~actual:(Mock.assistant_prefix (Mock.last_request (nth_mock mocks 1)));
      Test.assert_equal ~expected:("alpha" ^ notice_for 1 ^ "alpha beta") ~actual:(String.concat "" deltas);
      match expect_level handoffs "G3" with
      | Error e -> Error e
      | Ok _ -> Ok ())
    ()

let test_h8_session_pin_migrates = fun _ctx ->
  handoff_case ~n:2
    ~headers:[ ("X-Oasis-Session", "h8") ]
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) (dying_after "ev1" [ "ev2" ]);
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ " ev2" ] })
    ~check:(fun ~gw ~mocks ~events:_ ~deltas ~handoffs:_ ->
      Test.assert_equal ~expected:"ev1 ev2" ~actual:(String.concat "" deltas);
      Mock.set_scenario (nth_mock mocks 0) { (Mock.default_scenario) with body = openai_ok_body ~content:"from-a" };
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with body = openai_ok_body ~content:"from-b" };
      match
        gw_post
          ~port:gw.port
          ~path:"/v1/chat/completions"
          ~headers:[ ("X-Oasis-Category", "general"); ("X-Oasis-Session", "h8"); ("Content-Type", "application/json") ]
          ~body:"{\"model\":\"m-x\",\"messages\":[{\"role\":\"user\",\"content\":\"next\"}]}"
      with
      | Error e -> Error e
      | Ok (_, body) ->
          Test.assert_equal ~expected:true ~actual:(String.contains body "from-b");
          Ok ())
    ()

(* ---------- tools / structured-output passthrough ---------- *)

let tool_call_chunk = fun ?(finish = false) delta ->
  Json.to_string
    (Json.obj
      [
        ("object", Json.string "chat.completion.chunk");
        (
          "choices",
          Json.array
            [
              Json.obj
                [
                  ("index", Json.int 0);
                  ("delta", delta);
                  ("finish_reason", if finish then Json.string "tool_calls" else Json.null);
                ];
            ]
        );
      ])

let tc_open =
  tool_call_chunk
    (Json.obj
      [
        (
          "tool_calls",
          Json.array
            [
              Json.obj
                [
                  ("index", Json.int 0);
                  ("id", Json.string "call_1");
                  ("type", Json.string "function");
                  ("function", Json.obj [ ("name", Json.string "get_weather"); ("arguments", Json.string "") ]);
                ];
            ]
        );
      ])

let tc_args =
  tool_call_chunk
    (Json.obj
      [
        (
          "tool_calls",
          Json.array
            [ Json.obj [ ("index", Json.int 0); ("function", Json.obj [ ("arguments", Json.string "{\"city\":\"SH\"}") ]) ] ]
        );
      ])

let tc_finish = tool_call_chunk ~finish:true (Json.obj [])

let tools_extra =
  [
    (
      "tools",
      Json.array
        [
          Json.obj
            [
              ("type", Json.string "function");
              ("function", Json.obj [ ("name", Json.string "get_weather"); ("parameters", Json.obj []) ]);
            ];
        ]
    );
    ("tool_choice", Json.string "auto");
    ("temperature", Json.float 0.2);
  ]

let test_tools_sync_passthrough = fun _ctx ->
  match start_mocks 1 with
  | Error e -> Error e
  | Ok mocks -> (
      let tool_body =
        "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"SH\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":7}}"
      in
      Mock.set_scenario (nth_mock mocks 0) { (Mock.default_scenario) with body = tool_body };
      match Gateway.start ~config_path:None ~config:(handoff_config mocks) ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          let body =
            Json.to_string
              (Json.obj
                ([
                   ("model", Json.string "m-x");
                   ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "weather?") ] ]);
                   ("max_tokens", Json.int 64);
                 ]
                @ tools_extra))
          in
          match
            gw_post ~port:gw.port ~path:"/v1/chat/completions"
              ~headers:[ ("X-Oasis-Category", "general"); ("Content-Type", "application/json") ]
              ~body
          with
          | Error e -> Error e
          | Ok (status, resp) ->
              Test.assert_equal ~expected:200 ~actual:status;
              let up = Mock.last_request (nth_mock mocks 0) in
              Test.assert_equal ~expected:true ~actual:(String.contains up "\"tools\"");
              Test.assert_equal ~expected:true ~actual:(String.contains up "\"get_weather\"");
              Test.assert_equal ~expected:true ~actual:(String.contains up "\"tool_choice\":\"auto\"");
              Test.assert_equal ~expected:true ~actual:(String.contains up "\"temperature\"");
              Test.assert_equal ~expected:true ~actual:(String.contains resp "\"tool_calls\"");
              Test.assert_equal ~expected:true ~actual:(String.contains resp "call_1");
              Test.assert_equal ~expected:true ~actual:(String.contains resp "\"finish_reason\":\"tool_calls\"");
              Ok ()
        )
    )

let test_tools_stream_relays_tool_calls = fun _ctx ->
  handoff_case ~n:1 ~extra:tools_extra
    ~setup:(fun mocks ->
      Mock.set_scenario (nth_mock mocks 0) { (Mock.default_scenario) with sse = [ tc_open; tc_args; tc_finish ] })
    ~check:(fun ~gw:_ ~mocks ~events ~deltas:_ ~handoffs ->
      let datas = List.map events ~fn:(fun ev -> ev.Sse.data) in
      Test.assert_equal ~expected:true ~actual:(List.any datas ~fn:(String.equal tc_open));
      Test.assert_equal ~expected:true ~actual:(List.any datas ~fn:(String.equal tc_args));
      Test.assert_equal ~expected:true ~actual:(List.any datas ~fn:(String.equal tc_finish));
      Test.assert_equal ~expected:true ~actual:(List.any events ~fn:(fun ev -> ev.Sse.done_sentinel));
      Test.assert_equal ~expected:true ~actual:(String.contains (Mock.last_request (nth_mock mocks 0)) "\"tools\"");
      Test.assert_equal ~expected:0 ~actual:(List.length handoffs);
      Ok ())
    ()

let test_tools_cut_mid_tool_call_fails_without_restart = fun _ctx ->
  handoff_case ~n:2 ~extra:tools_extra
    ~setup:(fun mocks ->
      let header_len = String.length (Mock.stream_header 200) in
      let frame1 = Mock.chunked_frame ("data: " ^ tc_open ^ "\n\n") in
      Mock.set_scenario (nth_mock mocks 0)
        {
          (Mock.default_scenario) with
          sse = [ tc_open; tc_args; tc_finish ];
          cut_after_bytes = header_len + String.length frame1 + 3;
        };
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with sse = [ tc_open; tc_args; tc_finish ] })
    ~check:(fun ~gw:_ ~mocks ~events ~deltas ~handoffs:_ ->
      let datas = List.map events ~fn:(fun ev -> ev.Sse.data) in
      Test.assert_equal ~expected:true ~actual:(List.any datas ~fn:(String.equal tc_open));
      Test.assert_equal ~expected:false ~actual:(List.any datas ~fn:(String.equal tc_args));
      Test.assert_equal ~expected:true ~actual:(List.any datas ~fn:(fun d -> String.contains d "oasis_upstream_failed"));
      Test.assert_equal ~expected:true ~actual:(List.any datas ~fn:(fun d -> String.contains d "tool call"));
      Test.assert_equal ~expected:"" ~actual:(String.concat "" deltas);
      Test.assert_equal ~expected:"" ~actual:(Mock.last_request (nth_mock mocks 1));
      Ok ())
    ()

let test_tools_need_openai_protocol = fun _ctx ->
  match start_mocks 1 with
  | Error e -> Error e
  | Ok mocks -> (
      let base = handoff_config mocks in
      let config =
        {
          base with
          Config.accounts =
            List.map base.Config.accounts ~fn:(fun a -> { a with Config.protocol = "anthropic" });
        }
      in
      match Gateway.start ~config_path:None ~config ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          match h_stream ~extra:tools_extra ~port:gw.port () with
          | Error e -> Error e
          | Ok (status, _, _) ->
              Test.assert_equal ~expected:400 ~actual:status;
              Test.assert_equal ~expected:"" ~actual:(Mock.last_request (nth_mock mocks 0));
              Ok ()
        )
    )

(* ---------- spec 0.3 §2.3–2.4: unknown prices, agent latency, quota parking ---------- *)

let test_router_unknown_price_is_neutral = fun _ctx ->
  let kb =
    [
      mk_kb_model ~in_p:100 ~out_p:200 "m-cheap";
      mk_kb_model ~in_p:500 ~out_p:900 "m-pricey";
      mk_kb_model ~in_p:0 ~out_p:0 "m-unknown";
    ]
  in
  let config =
    mk_config
      ~accounts:
        [
          mk_account ~models:[ "m-unknown" ] "acc_unknown";
          mk_account ~models:[ "m-pricey" ] "acc_pricey";
          mk_account ~models:[ "m-cheap" ] "acc_cheap";
        ]
      ~kb
      ~routes:[]
      ~max_fallback:2
  in
  let lookups = mk_scored_lookups ~spent:(fun _ -> 0) ~day:(fun _ -> 0) ~snap:(fun _ -> mk_snap ()) in
  let task = { Router.category = "general"; model = None; est_in_tokens = 100; est_out_tokens = 100 } in
  let d = Router.route_scored config lookups ~goal:Router.Cheapest task in
  Test.assert_equal ~expected:(Some "acc_cheap") ~actual:d.Router.chosen;
  Test.assert_equal ~expected:[ "acc_cheap"; "acc_unknown"; "acc_pricey" ] ~actual:(List.map d.Router.scores ~fn:(fun (n, _) -> n));
  Test.assert_equal ~expected:[ "acc_unknown" ] ~actual:d.Router.unpriced;
  let j = Json.to_string (Router.decision_json d) in
  Test.assert_equal ~expected:true ~actual:(String.contains j "\"price_known\":false");
  Test.assert_equal ~expected:true ~actual:(String.contains j "\"schema\":2");
  Test.assert_equal ~expected:true ~actual:(Router.cost_routing_effective config);
  Test.assert_equal
    ~expected:false
    ~actual:(Router.cost_routing_effective { config with Config.kb = [ mk_kb_model "m-cheap"; mk_kb_model ~in_p:0 ~out_p:0 "m-unknown" ] });
  Ok ()

let test_router_agent_latency_scale = fun _ctx ->
  Test.assert_equal ~expected:100 ~actual:(Router.latency_score_agent ~ema_ms:0);
  Test.assert_equal ~expected:85 ~actual:(Router.latency_score_agent ~ema_ms:30_000);
  Test.assert_equal ~expected:40 ~actual:(Router.latency_score_agent ~ema_ms:120_000);
  Test.assert_equal ~expected:0 ~actual:(Router.latency_score_agent ~ema_ms:600_000);
  Ok ()

let test_router_relative_latency = fun _ctx ->
  Test.assert_equal ~expected:100 ~actual:(Router.latency_score ~fastest_ms:5_000 ~ema_ms:5_000 ~samples:3);
  Test.assert_equal ~expected:50 ~actual:(Router.latency_score ~fastest_ms:5_000 ~ema_ms:10_000 ~samples:3);
  Test.assert_equal ~expected:2 ~actual:(Router.latency_score ~fastest_ms:5_000 ~ema_ms:210_000 ~samples:3);
  Test.assert_equal ~expected:50 ~actual:(Router.latency_score ~fastest_ms:5_000 ~ema_ms:0 ~samples:0);
  Ok ()

let test_router_best_avoids_very_slow = fun _ctx ->
  let kb =
    [
      mk_kb_model ~tier:5 ~strengths:[ "coding" ] "m-deep";
      mk_kb_model ~tier:4 ~strengths:[ "coding" ] "m-quick";
    ]
  in
  let config =
    mk_config
      ~accounts:[ mk_account ~models:[ "m-deep" ] "acc_deep"; mk_account ~models:[ "m-quick" ] "acc_quick" ]
      ~kb ~routes:[] ~max_fallback:1
  in
  let snap ema = fun _ -> mk_snap ~ema () in
  let lookups f = mk_scored_lookups ~spent:(fun _ -> 0) ~day:(fun _ -> 0) ~snap:f in
  let task = { Router.category = "coding"; model = None; est_in_tokens = 100; est_out_tokens = 100 } in
  (* equally fast: the stronger model wins *)
  let d = Router.route_scored config (lookups (snap 5_000)) ~goal:Router.Best task in
  Test.assert_equal ~expected:(Some "acc_deep") ~actual:d.Router.chosen;
  (* 3.5 minutes against 8 seconds: quality no longer outweighs the wait *)
  let slow name = if String.equal name "acc_deep" then mk_snap ~ema:210_000 () else mk_snap ~ema:8_000 () in
  let d2 = Router.route_scored config (lookups slow) ~goal:Router.Best task in
  Test.assert_equal ~expected:(Some "acc_quick") ~actual:d2.Router.chosen;
  Test.assert_equal ~expected:2 ~actual:(List.length d2.Router.parts);
  Ok ()

let test_quality_blend = fun _ctx ->
  let q = Oasis.Quality.create () in
  let get () = Oasis.Quality.get q ~account:"a" ~category:"coding" in
  Test.assert_equal ~expected:100 ~actual:(Oasis.Quality.blend ~static:100 (get ()));
  for _ = 1 to 5 do Oasis.Quality.record q ~account:"a" ~category:"coding" ~score:0 done;
  Test.assert_equal ~expected:50 ~actual:(Oasis.Quality.blend ~static:100 (get ()));
  Oasis.Quality.unrecord q ~account:"a" ~category:"coding" ~score:0;
  Test.assert_equal ~expected:4 ~actual:(get ()).Oasis.Quality.n;
  Test.assert_equal ~expected:0 ~actual:(Oasis.Quality.get q ~account:"a" ~category:"writing").Oasis.Quality.n;
  Test.assert_equal ~expected:75 ~actual:(Oasis.Quality.of_review 4);
  Ok ()

let test_router_explore = fun _ctx ->
  let d =
    { (Router.empty_decision "general") with
      Router.chosen = Some "a"; fallback_order = [ "b" ]; scores = [ ("a", 90); ("b", 80); ("c", 70) ] }
  in
  let samples = function "a" -> 10 | "b" -> 3 | _ -> 0 in
  let e = Router.explore d ~samples in
  Test.assert_equal ~expected:(Some "c") ~actual:e.Router.chosen;
  Test.assert_equal ~expected:[ "a" ] ~actual:e.Router.fallback_order;
  Test.assert_equal ~expected:true ~actual:e.Router.explored;
  let settled = Router.explore d ~samples:(fun _ -> 9) in
  Test.assert_equal ~expected:(Some "a") ~actual:settled.Router.chosen;
  Test.assert_equal ~expected:false ~actual:settled.Router.explored;
  Ok ()

let test_judge_parse = fun _ctx ->
  Test.assert_equal
    ~expected:(Some (4, "准确"))
    ~actual:(Oasis.Judge.parse_verdict "```json\n{\"score\": 4, \"reason\": \"准确\"}\n```");
  Test.assert_equal ~expected:None ~actual:(Oasis.Judge.parse_verdict "{\"score\": 9}");
  Test.assert_equal ~expected:None ~actual:(Oasis.Judge.parse_verdict "no json");
  Test.assert_equal ~expected:("deepseek_pro", Some "deepseek-flash") ~actual:(Oasis.Judge.parse_judge "deepseek_pro:deepseek-flash");
  Test.assert_equal ~expected:("kimi_work", None) ~actual:(Oasis.Judge.parse_judge "kimi_work");
  Ok ()

let test_feed_ratings_and_answer = fun _ctx ->
  let feed = Feed.create () in
  let ev type_ data = Feed.apply feed ~type_ ~request_id:"r1" (Json.obj data) in
  ev "task_started" [ ("prompt", Json.string "q?"); ("category", Json.string "general") ];
  ev "task_done" [ ("chosen", Json.string "acc"); ("ok", Json.bool true); ("answer", Json.string "the answer") ];
  ev "task_rated" [ ("by", Json.string "user"); ("rating", Json.int (-1)) ];
  ev "task_rated" [ ("by", Json.string "judge"); ("score", Json.int 2); ("reason", Json.string "不准"); ("reviewer", Json.string "j") ];
  match Feed.find feed "r1" with
  | None -> Error "missing"
  | Some t ->
      Test.assert_equal ~expected:"q?" ~actual:t.Feed.prompt;
      Test.assert_equal ~expected:"the answer" ~actual:t.Feed.answer;
      Test.assert_equal ~expected:(-1) ~actual:t.Feed.user_rating;
      Test.assert_equal ~expected:2 ~actual:t.Feed.review_score;
      Ok ()

let test_gateway_rating_feeds_routing = fun _ctx ->
  match start_mocks 1 with
  | Error e -> Error e
  | Ok mocks -> (
      Mock.set_scenario (nth_mock mocks 0) { (Mock.default_scenario) with body = openai_ok_body ~content:"fine" };
      match Gateway.start ~config_path:None ~config:(handoff_config mocks) ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          let body =
            Json.to_string
              (Json.obj [ ("model", Json.string "m-x"); ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "q") ] ]) ])
          in
          let chat () = gw_post ~port:gw.port ~path:"/v1/chat/completions" ~headers:[ ("Content-Type", "application/json") ] ~body in
          match chat () with
          | Error e -> Error e
          | Ok _ -> (
              match gw_get ~port:gw.port ~path:"/api/feed?limit=1" with
              | Error e -> Error e
              | Ok (_, feed_body) -> (
                  let id =
                    Json.from_string feed_body |> Result.to_option
                    |> Option.and_then ~fn:(Json.get_field "tasks") |> Option.and_then ~fn:Json.get_array
                    |> Option.and_then ~fn:List.head |> Option.map ~fn:(fun t -> h_field_str t "id") |> Option.unwrap_or ~default:""
                  in
                  let rate r =
                    gw_post ~port:gw.port ~path:"/api/feed/rate" ~headers:[ ("Content-Type", "application/json") ]
                      ~body:(Json.to_string (Json.obj [ ("id", Json.string id); ("rating", Json.int r) ]))
                  in
                  match rate (-1) with
                  | Error e -> Error e
                  | Ok (st, rb) ->
                      Test.assert_equal ~expected:200 ~actual:st;
                      Test.assert_equal ~expected:true ~actual:(String.contains rb "\"rated\":1");
                      (* changing the verdict replaces it rather than adding a second one *)
                      (match rate 1 with
                       | Ok (_, rb2) -> Test.assert_equal ~expected:true ~actual:(String.contains rb2 "\"mean\":100")
                       | Error e -> Test.assert_equal ~expected:"" ~actual:e);
                      Test.assert_equal ~expected:true ~actual:(String.contains rb "\"rated\":1");
                      Ok ()
                )
            )
        )
    )

let test_committee_members_and_feed = fun _ctx ->
  Test.assert_equal ~expected:[ "a"; "b" ] ~actual:(Oasis.Committee.parse_members " a, b,a ,");
  let feed = Feed.create () in
  let ev type_ data = Feed.apply feed ~type_ ~request_id:"r1" (Json.obj data) in
  ev "task_started" [ ("title", Json.string "q") ];
  ev "committee_started" [ ("members", Json.array [ Json.string "a"; Json.string "b" ]) ];
  ev "committee_member" [ ("account", Json.string "a"); ("ok", Json.bool true); ("text", Json.string "A says") ];
  ev "committee_member" [ ("account", Json.string "b"); ("ok", Json.bool false); ("error", Json.string "upstream timeout (240s)") ];
  ev "routed" [ ("mode", Json.string "committee"); ("chosen", Json.string "c"); ("candidates", Json.array []) ];
  match Feed.find feed "r1" with
  | None -> Error "missing"
  | Some t ->
      Test.assert_equal ~expected:"committee" ~actual:t.Feed.mode;
      Test.assert_equal ~expected:true ~actual:(String.contains t.Feed.route_summary "委员会：a、b");
      Test.assert_equal ~expected:true ~actual:(String.contains t.Feed.route_summary "汇总交给 c");
      Test.assert_equal ~expected:2 ~actual:(List.length (List.filter t.Feed.timeline ~fn:(fun e -> String.equal (sfield e "kind") "member")));
      Ok ()

let test_gateway_committee = fun _ctx ->
  match start_mocks 3 with
  | Error e -> Error e
  | Ok mocks -> (
      List.enumerate mocks
      |> List.for_each ~fn:(fun (i, m) ->
        Mock.set_scenario m { (Mock.default_scenario) with body = openai_ok_body ~content:("answer-" ^ Int.to_string i) });
      match Gateway.start ~config_path:None ~config:(handoff_config mocks) ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          let body =
            Json.to_string
              (Json.obj [ ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "q") ] ]) ])
          in
          let post members =
            gw_post ~port:gw.port ~path:"/v1/chat/completions"
              ~headers:[ ("Content-Type", "application/json"); ("X-Oasis-Committee", members) ] ~body
          in
          match post "acc_0, acc_1" with
          | Error e -> Error e
          | Ok (status, resp) -> (
              Test.assert_equal ~expected:200 ~actual:status;
              Test.assert_equal ~expected:true ~actual:(String.contains resp "汇总（");
              Test.assert_equal ~expected:true ~actual:(String.contains resp "## acc_0\\n\\nanswer-0");
              Test.assert_equal ~expected:true ~actual:(String.contains resp "## acc_1\\n\\nanswer-1");
              match post "acc_0" with
              | Error e -> Error e
              | Ok (status2, _) ->
                  Test.assert_equal ~expected:400 ~actual:status2;
                  Ok ())
        )
    )

let chat_body = fun text ->
  Json.to_string
    (Json.obj [ ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string text) ] ]) ])

let test_gateway_client_deadline_accounts = fun _ctx ->
  match start_mocks 2 with
  | Error e -> Error e
  | Ok mocks -> (
      List.for_each mocks ~fn:(fun m ->
        Mock.set_scenario m
          { (Mock.default_scenario) with body = openai_ok_body ~content:"late"; sse = [ "data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}\n\n"; "data: [DONE]\n\n" ]; delay_ms = 3000 });
      match Gateway.start ~config_path:None ~config:(handoff_config mocks) ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          let t0 = Oasis.Signals.now_ms () in
          match
            gw_post ~port:gw.port ~path:"/v1/chat/completions"
              ~headers:[ ("Content-Type", "application/json"); ("X-Oasis-Timeout", "1") ] ~body:(chat_body "q")
          with
          | Error e -> Error e
          | Ok (status, resp) -> (
              Test.assert_equal ~expected:499 ~actual:status;
              Test.assert_equal ~expected:true ~actual:(String.contains resp "cancelled:timeout:1");
              Test.assert_equal ~expected:true ~actual:(Oasis.Signals.now_ms () - t0 < 2800);
              let stream_body =
                Json.to_string
                  (Json.obj
                    [ ("stream", Json.bool true); ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "q") ] ]) ])
              in
              match
                gw_post ~port:gw.port ~path:"/v1/chat/completions"
                  ~headers:[ ("Content-Type", "application/json"); ("X-Oasis-Timeout", "1") ] ~body:stream_body
              with
              | Error e -> Error e
              | Ok (_, sresp) -> (
                  Test.assert_equal ~expected:true ~actual:(String.contains sresp "oasis_cancelled");
                  Test.assert_equal ~expected:false ~actual:(String.contains sresp "late");
                  match gw_get ~port:gw.port ~path:"/api/feed?limit=5" with
                  | Error e -> Error e
                  | Ok (_, feed) ->
                      Test.assert_equal ~expected:true ~actual:(String.contains feed "\"status\":\"cancelled\"");
                      Ok ()))))

let latest_thread = fun ~port ->
  match gw_get ~port ~path:"/api/feed?limit=1" with
  | Error e -> Error e
  | Ok (_, feed) -> (
      match Json.from_string feed |> Result.to_option |> Option.and_then ~fn:(Json.get_field "tasks") |> Option.and_then ~fn:Json.get_array with
      | Some (t :: _) -> Ok (Json.get_field "thread" t |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:"")
      | _ -> Error "empty feed")

let test_gateway_thread_carries_history = fun _ctx ->
  match start_mocks 1 with
  | Error e -> Error e
  | Ok mocks -> (
      let m = List.get_unchecked mocks ~at:0 in
      Mock.set_scenario m { (Mock.default_scenario) with body = openai_ok_body ~content:"first-answer" };
      match Gateway.start ~config_path:None ~config:(handoff_config mocks) ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          let post headers text =
            gw_post ~port:gw.port ~path:"/v1/chat/completions" ~headers:(("Content-Type", "application/json") :: headers) ~body:(chat_body text)
          in
          match post [] "first-question" with
          | Error e -> Error e
          | Ok _ -> (
              match latest_thread ~port:gw.port with
              | Error e -> Error e
              | Ok th -> (
                  Test.assert_equal ~expected:true ~actual:(String.starts_with ~prefix:"th-" th);
                  match post [ ("X-Oasis-Thread", th) ] "second-question" with
                  | Error e -> Error e
                  | Ok (status, _) -> (
                      Test.assert_equal ~expected:200 ~actual:status;
                      let sent = Mock.last_request m in
                      Test.assert_equal ~expected:true ~actual:(String.contains sent "first-question");
                      Test.assert_equal ~expected:true ~actual:(String.contains sent "first-answer");
                      Test.assert_equal ~expected:true ~actual:(String.contains sent "second-question");
                      match gw_get ~port:gw.port ~path:("/api/thread?id=" ^ th) with
                      | Error e -> Error e
                      | Ok (_, tj) ->
                          let turns =
                            Json.from_string tj |> Result.to_option |> Option.and_then ~fn:(Json.get_field "turns")
                            |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
                          in
                          Test.assert_equal ~expected:2 ~actual:(List.length turns);
                          Ok ())))))

let test_gateway_thread_resumes_agent_session = fun _ctx ->
  let agent = { (mk_agent ~command:(fix "agent_session.sh") ~args:[ "{prompt}" ] "agent_s") with Agent.resume_args = [ "--resume"; "{session}" ] } in
  let config =
    mk_config_agents ~accounts:[ mk_account "acc_api" ] ~agents:[ agent; mk_agent ~args:[ fix "agent_ok.sh" ] "agent_other" ]
      ~kb:[ mk_kb_model "m-x" ] ~routes:[] ~max_fallback:1
  in
  match Gateway.start ~config_path:None ~config ~port:0 () with
  | Error e -> Error ("gateway: " ^ e)
  | Ok gw -> (
      let post headers text =
        gw_post ~port:gw.port ~path:"/v1/chat/completions" ~headers:(("Content-Type", "application/json") :: headers) ~body:(chat_body text)
      in
      match post [ ("X-Oasis-Agent", "agent_s") ] "build-it" with
      | Error e -> Error e
      | Ok (_, first) -> (
          Test.assert_equal ~expected:false ~actual:(String.contains first "--resume");
          match latest_thread ~port:gw.port with
          | Error e -> Error e
          | Ok th -> (
              match post [ ("X-Oasis-Thread", th) ] "now-test-it" with
              | Error e -> Error e
              | Ok (status, second) ->
                  Test.assert_equal ~expected:200 ~actual:status;
                  (* same agent, its own session, only the new message *)
                  Test.assert_equal ~expected:true ~actual:(String.contains second "args: --resume sess-42 now-test-it");
                  Test.assert_equal ~expected:false ~actual:(String.contains second "build-it");
                  Ok ())))

let test_gateway_agent_runs_in_task_workspace = fun _ctx ->
  let config =
    mk_config_agents ~accounts:[ mk_account "acc_api" ] ~agents:[ mk_agent ~command:(fix "agent_write.sh") ~args:[ "{prompt}" ] "agent_w" ]
      ~kb:[ mk_kb_model "m-x" ] ~routes:[] ~max_fallback:1
  in
  match Gateway.start ~config_path:None ~config ~port:0 () with
  | Error e -> Error ("gateway: " ^ e)
  | Ok gw -> (
      let post headers text =
        gw_post ~port:gw.port ~path:"/v1/chat/completions" ~headers:(("Content-Type", "application/json") :: headers) ~body:(chat_body text)
      in
      let cwd_of body =
        match String.split ~by:"cwd=" body with
        | _ :: rest :: _ -> (match String.split ~by:"\\n" rest with d :: _ -> String.trim d | [] -> "")
        | _ -> ""
      in
      match post [ ("X-Oasis-Agent", "agent_w") ] "write-files" with
      | Error e -> Error e
      | Ok (_, first) -> (
          match latest_thread ~port:gw.port with
          | Error e -> Error e
          | Ok th -> (
              let dir = cwd_of first in
              if not (String.ends_with ~suffix:("/workspaces/" ^ th) dir) then Error ("agent ran in " ^ dir ^ ", not the workspace of " ^ th ^ ": " ^ first) else
              match post [ ("X-Oasis-Thread", th) ] "again" with
              | Error e -> Error e
              | Ok (_, second) -> (
                  (* every turn of a conversation shares the directory *)
                  Test.assert_equal ~expected:dir ~actual:(cwd_of second);
                  match gw_get ~port:gw.port ~path:("/api/workspace?id=" ^ th) with
                  | Error e -> Error e
                  | Ok (_, listing) -> (
                      let paths =
                        Json.from_string listing |> Result.to_option |> Option.and_then ~fn:(Json.get_field "files")
                        |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
                        |> List.filter_map ~fn:(fun f -> Json.get_field "path" f |> Option.and_then ~fn:Json.get_string)
                      in
                      Test.assert_equal ~expected:[ "notes.txt"; "src/main.ml" ] ~actual:paths;
                      match gw_get ~port:gw.port ~path:("/api/workspace/file?id=" ^ th ^ "&path=notes.txt") with
                      | Error e -> Error e
                      | Ok (status, file) -> (
                          Test.assert_equal ~expected:200 ~actual:status;
                          Test.assert_equal ~expected:true ~actual:(String.contains file "turn\\nturn");
                          match gw_get ~port:gw.port ~path:("/api/workspace/file?id=" ^ th ^ "&path=../../threads.json") with
                          | Error e -> Error e
                          | Ok (status, _) ->
                              Test.assert_equal ~expected:404 ~actual:status;
                              Ok ()))))))

let test_upstream_body_max_tokens_passthrough = fun _ctx ->
  let messages = Json.array [] in
  let has_max b = String.contains b "max_tokens" in
  Test.assert_equal ~expected:false ~actual:(has_max (Oasis.Upstream.upstream_body ~model:"m" ~messages ~max_tokens:None ~stream:false ()));
  Test.assert_equal ~expected:true ~actual:(has_max (Oasis.Upstream.upstream_body ~model:"m" ~messages ~max_tokens:(Some 99) ~stream:false ()));
  let s1 = Signals.record_latency (Signals.fresh ()) ~latency_ms:4_000 in
  Test.assert_equal ~expected:4_000 ~actual:s1.Signals.latency_ema_ms;
  Test.assert_equal ~expected:1 ~actual:s1.Signals.latency_samples;
  Ok ()

let test_signals_classify_error = fun _ctx ->
  let c ?(codes = []) status body =
    Signals.error_class_to_string (Signals.classify_error ~status ~body ~quota_codes:codes)
  in
  Test.assert_equal ~expected:"quota" ~actual:(c (Some 402) "");
  Test.assert_equal ~expected:"quota" ~actual:(c (Some 429) "{\"error\":{\"code\":\"1113\",\"message\":\"余额不足\"}}");
  Test.assert_equal ~expected:"quota" ~actual:(c (Some 429) "{\"error\":{\"type\":\"Insufficient_Quota\"}}");
  Test.assert_equal ~expected:"transient" ~actual:(c (Some 429) "{\"error\":\"rate limited\"}");
  Test.assert_equal ~expected:"quota" ~actual:(c ~codes:[ "E_TOKENS_GONE" ] (Some 429) "E_TOKENS_GONE");
  Test.assert_equal ~expected:"client_auth" ~actual:(c (Some 401) "");
  Test.assert_equal ~expected:"client_auth" ~actual:(c (Some 403) "");
  Test.assert_equal ~expected:"client" ~actual:(c (Some 400) "");
  Test.assert_equal ~expected:"client" ~actual:(c (Some 413) "");
  Test.assert_equal ~expected:"transient" ~actual:(c (Some 503) "quota");
  Test.assert_equal ~expected:"transient" ~actual:(c None "");
  Ok ()

let test_signals_quota_reset_at = fun _ctx ->
  let day = 86_400_000 in
  let d_2026_11_03 = Signals.days_of_civil ~y:2026 ~m:11 ~d:3 in
  let noon = (d_2026_11_03 * day) + (day / 2) in
  Test.assert_equal ~expected:(2026, 11, 3) ~actual:(Signals.civil_of_days d_2026_11_03);
  Test.assert_equal ~expected:((d_2026_11_03 + 1) * day) ~actual:(Signals.quota_reset_at ~now_ms:noon ~reset:"daily");
  Test.assert_equal
    ~expected:(Signals.days_of_civil ~y:2026 ~m:12 ~d:1 * day)
    ~actual:(Signals.quota_reset_at ~now_ms:noon ~reset:"monthly");
  let dec = (Signals.days_of_civil ~y:2026 ~m:12 ~d:31 * day) + 1 in
  Test.assert_equal
    ~expected:(Signals.days_of_civil ~y:2027 ~m:1 ~d:1 * day)
    ~actual:(Signals.quota_reset_at ~now_ms:dec ~reset:"monthly");
  Test.assert_equal ~expected:(2024, 2, 29) ~actual:(Signals.civil_of_days (Signals.days_of_civil ~y:2024 ~m:2 ~d:29));
  Test.assert_equal ~expected:(1970, 1, 1) ~actual:(Signals.civil_of_days 0);
  Ok ()

let test_signals_parked_roundtrip = fun _ctx ->
  let dir = unique_dir "parked" in
  let _ = Fs.create_dir_all (Path.from_string dir |> Result.unwrap) in
  let path = dir ^ "/parked.json" in
  let now = Signals.now_ms () in
  let t = Signals.init () in
  let _ = Signals.update t "acc_q" ~fn:(fun s -> Signals.record_quota s ~error:"quota" ~until_ms:(now + 60_000)) in
  let _ = Signals.update t "acc_expired" ~fn:(fun s -> Signals.record_quota s ~error:"quota" ~until_ms:(now - 1)) in
  let _ = Signals.update t "acc_ok" ~fn:(fun s -> s) in
  Signals.save_parked t ~path;
  let t2 = Signals.init () in
  Signals.load_parked t2 ~path;
  Test.assert_equal ~expected:true ~actual:(Signals.is_parked (Signals.snapshot t2 "acc_q") now);
  Test.assert_equal ~expected:(now + 60_000) ~actual:(Signals.snapshot t2 "acc_q").Signals.parked_until_ms;
  Test.assert_equal ~expected:false ~actual:(Signals.is_parked (Signals.snapshot t2 "acc_expired") now);
  Test.assert_equal ~expected:false ~actual:(Signals.is_parked (Signals.snapshot t2 "acc_ok") now);
  Ok ()

let quota_account_json = fun body name ->
  Json.from_string body |> Result.to_option
  |> Option.and_then ~fn:(Json.get_field "accounts")
  |> Option.and_then ~fn:Json.get_array
  |> Option.unwrap_or ~default:[]
  |> List.find ~fn:(fun a -> String.equal (h_field_str a "name") name)

let test_gateway_quota_parks_across_restart = fun _ctx ->
  match start_mocks 2 with
  | Error e -> Error e
  | Ok mocks -> (
      let base = handoff_config mocks in
      let config = { base with Config.data_dir = unique_dir "quota" } in
      Mock.set_scenario (nth_mock mocks 0)
        { (Mock.default_scenario) with status = 429; body = "{\"error\":{\"code\":\"1113\",\"message\":\"余额不足\"}}" };
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with body = openai_ok_body ~content:"from-b" };
      let post ~port =
        gw_post ~port ~path:"/v1/chat/completions"
          ~headers:[ ("X-Oasis-Category", "general"); ("Content-Type", "application/json") ]
          ~body:"{\"model\":\"m-x\",\"messages\":[{\"role\":\"user\",\"content\":\"q\"}]}"
      in
      let parked_reason ~port =
        match gw_get ~port ~path:"/api/decisions" with
        | Error _ -> false
        | Ok (_, body) -> String.contains body "\"reason\":\"quota_parked\""
      in
      let parked_in_accounts ~port =
        match gw_get ~port ~path:"/api/accounts" with
        | Error _ -> false
        | Ok (_, body) -> (
            match quota_account_json body (acc_name 0) with
            | None -> false
            | Some a -> h_field_int a "parked_until_ms" > Signals.now_ms ()
          )
      in
      match Gateway.start ~config_path:None ~config ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          match post ~port:gw.port with
          | Error e -> Error e
          | Ok (_, body1) -> (
              Test.assert_equal ~expected:true ~actual:(String.contains body1 "from-b");
              Test.assert_equal ~expected:true ~actual:(parked_in_accounts ~port:gw.port);
              match post ~port:gw.port with
              | Error e -> Error e
              | Ok (_, body2) -> (
                  Test.assert_equal ~expected:true ~actual:(String.contains body2 "from-b");
                  Test.assert_equal ~expected:true ~actual:(parked_reason ~port:gw.port);
                  match Gateway.start ~config_path:None ~config ~port:0 () with
                  | Error e -> Error ("gateway restart: " ^ e)
                  | Ok gw2 ->
                      Test.assert_equal ~expected:true ~actual:(parked_in_accounts ~port:gw2.port);
                      Ok ()
                )
            )
        )
    )

let test_gateway_model_auto_routes = fun _ctx ->
  match start_mocks 1 with
  | Error e -> Error e
  | Ok mocks -> (
      let config = { (handoff_config mocks) with Config.data_dir = unique_dir "model-auto" } in
      Mock.set_scenario (nth_mock mocks 0) { (Mock.default_scenario) with body = openai_ok_body ~content:"routed" };
      match Gateway.start ~config_path:None ~config ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw ->
          let post ~model =
            gw_post ~port:gw.port ~path:"/v1/chat/completions"
              ~headers:[ ("Content-Type", "application/json") ]
              ~body:("{\"model\":\"" ^ model ^ "\",\"messages\":[{\"role\":\"user\",\"content\":\"q\"}]}")
          in
          let routed ~model =
            match post ~model with
            | Ok (200, body) -> String.contains body "routed"
            | _ -> false
          in
          Test.assert_equal ~expected:true ~actual:(routed ~model:"auto");
          Test.assert_equal ~expected:true ~actual:(routed ~model:"oasis");
          Test.assert_equal ~expected:false ~actual:(routed ~model:"not-configured");
          Ok ()
    )

(* ---------- spec 0.3 §5.1: bearer auth ---------- *)

let test_gateway_bearer_auth = fun _ctx ->
  let var = "OASIS_TEST_TOKEN_" ^ Int.to_string (Signals.now_ms ()) in
  let _ = Env.set ~var ~value:"s3cret/+=" in
  match start_mocks 1 with
  | Error e -> Error e
  | Ok mocks -> (
      let config = { (handoff_config mocks) with Config.auth_token_env = Some var } in
      match Gateway.start ~config_path:None ~config ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw ->
          let port = gw.port in
          let status ~method_ ~path ~headers =
            match gw_req ~method_ ~port ~path ~headers ~body:"" with
            | Ok (s, _) -> s
            | Error _ -> -1
          in
          Test.assert_equal ~expected:200 ~actual:(status ~method_:"GET" ~path:"/" ~headers:[]);
          Test.assert_equal ~expected:401 ~actual:(status ~method_:"GET" ~path:"/api/accounts" ~headers:[]);
          Test.assert_equal
            ~expected:401
            ~actual:(status ~method_:"GET" ~path:"/api/accounts" ~headers:[ ("Authorization", "Bearer wrong") ]);
          Test.assert_equal
            ~expected:200
            ~actual:(status ~method_:"GET" ~path:"/api/accounts" ~headers:[ ("Authorization", "Bearer s3cret/+=") ]);
          Test.assert_equal ~expected:401 ~actual:(status ~method_:"GET" ~path:"/v1/models" ~headers:[]);
          Test.assert_equal ~expected:401 ~actual:(status ~method_:"POST" ~path:"/v1/chat/completions" ~headers:[]);
          Test.assert_equal ~expected:401 ~actual:(status ~method_:"POST" ~path:"/mcp" ~headers:[]);
          Test.assert_equal ~expected:401 ~actual:(status ~method_:"POST" ~path:"/api/reload" ~headers:[]);
          Test.assert_equal ~expected:401 ~actual:(status ~method_:"GET" ~path:"/ws" ~headers:[]);
          Test.assert_equal
            ~expected:401
            ~actual:(status ~method_:"GET" ~path:"/api/accounts?token=s3cret%2F%2B%3D" ~headers:[]);
          Test.assert_equal ~expected:true ~actual:(String.equal (Gateway.percent_decode "s3cret%2F%2B%3D") "s3cret/+=");
          let _ = Env.remove ~var in
          Ok ()
    )

let test_gateway_loopback_guards = fun _ctx ->
  match start_mocks 1 with
  | Error e -> Error e
  | Ok mocks -> (
      let config = handoff_config mocks in
      let refused =
        match Gateway.start ~config_path:None ~config:{ config with Config.server_host = "0.0.0.0" } ~port:0 () with
        | Ok _ -> false
        | Error e -> String.contains e "auth_token_env"
      in
      Test.assert_equal ~expected:true ~actual:refused;
      match Gateway.start ~config_path:None ~config ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw ->
          let status ~method_ ~path ~headers =
            match gw_req ~method_ ~port:gw.port ~path ~headers ~body:"" with
            | Ok (s, _) -> s
            | Error _ -> -1
          in
          Test.assert_equal ~expected:200 ~actual:(status ~method_:"GET" ~path:"/api/accounts" ~headers:[]);
          Test.assert_equal
            ~expected:200
            ~actual:(status ~method_:"GET" ~path:"/api/accounts" ~headers:[ ("Origin", "http://127.0.0.1:9899") ]);
          Test.assert_equal
            ~expected:200
            ~actual:(status ~method_:"GET" ~path:"/api/accounts" ~headers:[ ("Origin", "http://localhost:9899") ]);
          Test.assert_equal
            ~expected:403
            ~actual:(status ~method_:"POST" ~path:"/v1/chat/completions" ~headers:[ ("Origin", "https://evil.example") ]);
          Test.assert_equal ~expected:405 ~actual:(status ~method_:"GET" ~path:"/api/reload" ~headers:[]);
          (
            match gw_get ~port:gw.port ~path:"/api/accounts" with
            | Ok (_, body) ->
                Test.assert_equal ~expected:true ~actual:(String.contains body "\"cost_routing_effective\":false")
            | Error e -> Test.assert_equal ~expected:"" ~actual:e
          );
          Ok ()
    )

(* ---------- spec 0.3 §5.3: audit redaction ---------- *)

(* ---------- setup wizard ---------- *)

let no_choices : Setup.choices = { enable_accounts = []; enable_agents = []; add_accounts = []; add_agents = []; goal = None }

let user_config =
  "# my notes\n\n[server]\nport = 9899 # keep\n\n[[accounts]]\nname = \"mine\"\nprovider = \"deepseek\"\nbase_url = \"https://api.deepseek.com\"\napi_key_env = \"MY_KEY\"\nmodels = [\n  \"deepseek-v4-pro\",\n]\n\n[[routes]]\ncategory = \"general\"\naccounts = [\n  \"mine\", # main\n]\n"

let test_thread_history_oldest_first = fun _ctx ->
  let turn prompt =
    { Oasis.Thread.request_id = prompt; prompt; answer = "a-" ^ prompt; executor = "x"; mode = "chat"; status = "ok"; finished_ms = 0 }
  in
  let th : Oasis.Thread.thread =
    { id = "t"; title = ""; created_ms = 0; updated_ms = 0; turns = [ turn "one"; turn "two" ]; sessions = []; members = []; workspace = "" }
  in
  let contents =
    Oasis.Thread.history_messages th
    |> List.filter_map ~fn:(fun m -> Json.get_field "content" m |> Option.and_then ~fn:Json.get_string)
  in
  Test.assert_equal ~expected:[ "one"; "a-one"; "two"; "a-two" ] ~actual:contents;
  Ok ()

let show_seen = fun (s : Oasis.Observe.seen) -> s.plan ^ "|" ^ s.usage ^ "|" ^ s.tokens ^ "|" ^ s.reset

let test_observe_plan_page = fun _ctx ->
  let s =
    Oasis.Observe.extract
      [
        "CURRENT PLAN";
        "Super";
        "Get Ultra";
        "Weekly usage resets on Nov 12 (7 days left)";
        "Weekly usage limit";
        "30%";
        "Included usage with your subscription. Resets Nov 12. Used before your credits.";
      ]
  in
  let actual = show_seen s in
  let expected = "Super|30%||Weekly usage resets on Nov 12 (7 days left)" in
  if not (String.equal expected actual) then panic actual;
  Ok ()

let test_observe_ignores_chat = fun _ctx ->
  let s =
    Oasis.Observe.extract
      [
        "Context 16%";
        "Vercel Labs发布了agent-desktop说是通过系统就能看到应用的内容，你可以试试，用来看各种agent的账户性质，token消耗数量和比例，以及reset的时间。如果行的话，把它接进来";
        "Get Ultra";
      ]
  in
  let actual = show_seen s in
  if not (String.equal "|||" actual) then panic actual;
  Ok ()

let test_observe_tokens_near_usage = fun _ctx ->
  let s = Oasis.Observe.extract [ "Weekly usage limit"; "12,345 / 100,000"; "30% used" ] in
  let actual = show_seen s in
  let expected = "|30%|12345/100000|" in
  if not (String.equal expected actual) then panic actual;
  Ok ()

let test_observe_snapshot_tree = fun _ctx ->
  let body =
    "{\"ok\":true,\"data\":{\"tree\":{\"role\":\"window\",\"name\":\"Cursor Agents\",\"children\":[{\"role\":\"text\",\"name\":\"CURRENT PLAN\"},{\"role\":\"text\",\"name\":\"Super\"},{\"role\":\"text\",\"name\":\"Weekly usage limit\"},{\"role\":\"text\",\"name\":\"30%\"}]}}}"
  in
  let s = Oasis.Observe.extract (Oasis.Observe.names_of body) in
  let actual = show_seen s in
  if not (String.equal "Super|30%||" actual) then panic actual;
  Ok ()

let test_observe_token_total = fun _ctx ->
  let zcode = Oasis.Observe.extract [ "262.6M"; "Total tokens"; "95.3M"; "Peak tokens"; "246.5M"; "tokens" ] in
  if not (String.equal "||262.6M|" (show_seen zcode)) then panic (show_seen zcode);
  let deepseek = Oasis.Observe.extract [ "API requests"; "91"; "Tokens"; "9,888,476"; "6M" ] in
  if not (String.equal "||9888476|" (show_seen deepseek)) then panic (show_seen deepseek);
  let model_share = Oasis.Observe.extract [ "Model usage"; "246.5M"; "tokens"; "GLM-5.3"; "100%" ] in
  if not (String.equal "||246.5M|" (show_seen model_share)) then panic (show_seen model_share);
  let credits =
    Oasis.Observe.extract [ "Available credits"; "Manage credits and usage"; "15,028"; "Purchased credits"; "Info"; "5,000" ]
  in
  if not (String.equal "||15028 credits|" (show_seen credits)) then panic (show_seen credits);
  Ok ()

let test_observe_ignores_quoted_plan = fun _ctx ->
  let s =
    Oasis.Observe.extract
      [ "这一页的树里有"; "Super"; "，还有每周额度"; "30%"; "和重置日"; "11 月 12 日"; "Plan & Usage" ]
  in
  let actual = show_seen s in
  if not (String.equal "|||" actual) then panic actual;
  Ok ()

let test_setup_merge_noop_keeps_text = fun _ctx ->
  Test.assert_equal ~expected:user_config ~actual:(Setup.merge ~text:user_config no_choices);
  Ok ()

let test_setup_merge_changes = fun _ctx ->
  let c =
    {
      no_choices with
      enable_accounts = [ ("mine", false) ];
      add_accounts =
        [ { na_name = ""; na_provider = "glm"; na_base_url = "https://api.z.ai/api/anthropic"; na_protocol = "anthropic"; na_env = "GLM_API_KEY"; na_models = [ "glm-5.3" ] } ];
      goal = Some "fastest";
    }
  in
  let out = Setup.merge ~text:user_config c in
  let starts = String.starts_with ~prefix:"# my notes\n\n[server]\nport = 9899 # keep\n" out in
  Test.assert_equal ~expected:true ~actual:starts;
  Test.assert_equal ~expected:true ~actual:(String.contains out "api_key_env = \"MY_KEY\"\nmodels = [\n  \"deepseek-v4-pro\",\n]\nenabled = false\n");
  Test.assert_equal ~expected:true ~actual:(String.contains out "accounts = [\"mine\", \"glm\"]");
  Test.assert_equal ~expected:true ~actual:(String.contains out "goal = \"fastest\"");
  Test.assert_equal ~expected:out ~actual:(Setup.merge ~text:out no_choices);
  let file = "./.oasis-test-config-setup-merge.toml" in
  match Fs.write out (Path.from_string file |> Result.unwrap) with
  | Error e -> Error ("write failed: " ^ IO.error_message e)
  | Ok () -> (
      match Config.load file with
      | Error e -> Error ("merged config does not load: " ^ e)
      | Ok cfg ->
          Test.assert_equal ~expected:[ "mine"; "glm" ] ~actual:(List.map cfg.accounts ~fn:(fun (a : Config.account) -> a.name));
          Ok ())

let test_setup_fresh_skeleton_order = fun _ctx ->
  let out = Setup.merge ~text:"" { no_choices with add_agents = [ ("claude_code", "/usr/bin/claude") ] } in
  let headers = String.split ~by:"\n" out |> List.filter ~fn:(String.starts_with ~prefix:"[") in
  Test.assert_equal ~expected:[ "[server]"; "[policy]"; "[[agents]]" ] ~actual:headers;
  Ok ()

let test_setup_spec_for = fun _ctx ->
  let s = Setup.spec_for ~pid:"gemini" "gemini-3.1-pro-preview" in
  Test.assert_equal ~expected:("gemini-3.1-pro-preview", 5, "medium") ~actual:(s.id, s.tier, s.latency);
  let s = Setup.spec_for ~pid:"openai" "gpt-9-mini" in
  Test.assert_equal ~expected:(3, "fast") ~actual:(s.tier, s.latency);
  let s = Setup.spec_for ~pid:"openai" "geminist-pro" in
  Test.assert_equal ~expected:"medium" ~actual:s.latency;
  Ok ()

let test_setup_parse_secrets = fun _ctx ->
  Test.assert_equal
    ~expected:[ ("A_KEY", "x1"); ("B", "two words"); ("C", "q'd") ]
    ~actual:(Setup.parse_secrets "# c\nexport A_KEY=x1\nB=\"two words\"\n\nC='q'd'\n1BAD=no\nnot a line\n");
  Ok ()

let test_redact_secrets = fun _ctx ->
  Test.assert_equal
    ~expected:"auth failed for Bearer ****, retry"
    ~actual:(Signals.redact_secrets "auth failed for Bearer abc.DEF-123, retry");
  Test.assert_equal
    ~expected:"{\"error\":\"Incorrect API key provided: sk-****\"}"
    ~actual:(Signals.redact_secrets "{\"error\":\"Incorrect API key provided: sk-proj-AbCdEf123456\"}");
  Test.assert_equal ~expected:"task-list ok" ~actual:(Signals.redact_secrets "task-list ok");
  Test.assert_equal ~expected:"sk-short" ~actual:(Signals.redact_secrets "sk-short");
  Test.assert_equal ~expected:(Gateway.hash8 "abc") ~actual:(Gateway.hash8 "abc");
  Test.assert_equal ~expected:8 ~actual:(String.length (Gateway.hash8 "abc"));
  Test.assert_equal ~expected:"811c9dc5" ~actual:(Gateway.hash8 "");
  Test.assert_equal ~expected:false ~actual:(String.equal (Gateway.hash8 "abc") (Gateway.hash8 "abd"));
  Ok ()

let test_gateway_audit_has_no_content_or_keys = fun _ctx ->
  match start_mocks 2 with
  | Error e -> Error e
  | Ok mocks -> (
      let base = handoff_config mocks in
      let config = { base with Config.data_dir = unique_dir "audit" } in
      Mock.set_scenario (nth_mock mocks 0)
        { (Mock.default_scenario) with status = 401; body = "{\"error\":\"Incorrect API key provided: sk-live-0123456789abcdef\"}" };
      Mock.set_scenario (nth_mock mocks 1) { (Mock.default_scenario) with body = openai_ok_body ~content:"fine" };
      match Gateway.start ~config_path:None ~config ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          let body = "{\"model\":\"m-x\",\"messages\":[{\"role\":\"user\",\"content\":\"PRIVATE-PROMPT-TEXT\"}]}" in
          match
            gw_post ~port:gw.port ~path:"/v1/chat/completions"
              ~headers:[ ("X-Oasis-Category", "general"); ("Content-Type", "application/json") ]
              ~body
          with
          | Error e -> Error e
          | Ok (_, resp) ->
              Test.assert_equal ~expected:true ~actual:(String.contains resp "fine");
              let get path = match gw_get ~port:gw.port ~path with Ok (_, b) -> b | Error e -> e in
              let requests = get "/api/requests" in
              Test.assert_equal ~expected:false ~actual:(String.contains requests "PRIVATE-PROMPT-TEXT");
              Test.assert_equal
                ~expected:true
                ~actual:(String.contains requests ("\"body_len\":" ^ Int.to_string (String.length body)));
              Test.assert_equal ~expected:true ~actual:(String.contains requests ("\"body_hash8\":\"" ^ Gateway.hash8 body ^ "\""));
              List.for_each [ "/api/decisions"; "/api/accounts"; "/api/requests" ] ~fn:(fun p ->
                Test.assert_equal ~expected:false ~actual:(String.contains (get p) "0123456789abcdef"));
              Ok ()
        )
    )

(* ---------- spec 0.3 §6: decisions.jsonl ---------- *)

let test_gateway_decisions_survive_restart = fun _ctx ->
  match start_mocks 1 with
  | Error e -> Error e
  | Ok mocks -> (
      let config = { (handoff_config mocks) with Config.data_dir = unique_dir "decisions" } in
      Mock.set_scenario (nth_mock mocks 0) { (Mock.default_scenario) with body = openai_ok_body ~content:"persist-me" };
      let post ~port =
        gw_post ~port ~path:"/v1/chat/completions"
          ~headers:[ ("X-Oasis-Category", "general"); ("Content-Type", "application/json") ]
          ~body:"{\"model\":\"m-x\",\"messages\":[{\"role\":\"user\",\"content\":\"q\"}]}"
      in
      let decisions ~port ~path =
        match gw_get ~port ~path with
        | Error _ -> []
        | Ok (_, body) ->
            Json.from_string body |> Result.to_option
            |> Option.and_then ~fn:(Json.get_field "decisions")
            |> Option.and_then ~fn:Json.get_array
            |> Option.unwrap_or ~default:[]
      in
      match Gateway.start ~config_path:None ~config ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          let _ = post ~port:gw.port in
          let _ = post ~port:gw.port in
          Test.assert_equal ~expected:2 ~actual:(List.length (decisions ~port:gw.port ~path:"/api/decisions"));
          match Gateway.start ~config_path:None ~config ~port:0 () with
          | Error e -> Error ("gateway restart: " ^ e)
          | Ok gw2 ->
              let _ = post ~port:gw2.port in
              let ds = decisions ~port:gw2.port ~path:"/api/decisions" in
              Test.assert_equal ~expected:3 ~actual:(List.length ds);
              Test.assert_equal
                ~expected:true
                ~actual:(List.all ds ~fn:(fun d -> h_field_int d "schema" = 2 && String.equal (h_field_str d "chosen") (acc_name 0)));
              Test.assert_equal ~expected:1 ~actual:(List.length (decisions ~port:gw2.port ~path:"/api/decisions?limit=1"));
              Ok ()
        )
    )

(* ---------- spec 0.3 §6: streaming usage ---------- *)

let test_gateway_stream_usage_recorded = fun _ctx ->
  match start_mocks 1 with
  | Error e -> Error e
  | Ok mocks -> (
      let base = handoff_config mocks in
      let config =
        {
          base with
          Config.data_dir = unique_dir "usage";
          accounts = List.map base.Config.accounts ~fn:(fun a -> { a with Config.stream_usage = true });
        }
      in
      Mock.set_scenario (nth_mock mocks 0)
        {
          (Mock.default_scenario) with
          sse =
            [
              "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}";
              "{\"choices\":[],\"usage\":{\"prompt_tokens\":1234,\"completion_tokens\":567,\"total_tokens\":1801}}";
            ];
        };
      match Gateway.start ~config_path:None ~config ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          match h_stream ~port:gw.port () with
          | Error e -> Error e
          | Ok (_, _, deltas) -> (
              Test.assert_equal ~expected:"hi" ~actual:(String.concat "" deltas);
              let upstream = Json.from_string (Mock.last_request (nth_mock mocks 0)) |> Result.to_option in
              Test.assert_equal
                ~expected:(Some true)
                ~actual:
                  (upstream
                  |> Option.and_then ~fn:(Json.get_field "stream_options")
                  |> Option.and_then ~fn:(Json.get_field "include_usage")
                  |> Option.and_then ~fn:Json.get_bool);
              match gw_get ~port:gw.port ~path:"/api/ledger" with
              | Error e -> Error e
              | Ok (_, body) ->
                  Test.assert_equal ~expected:true ~actual:(String.contains body "\"in_tokens\":1234");
                  Test.assert_equal ~expected:true ~actual:(String.contains body "\"out_tokens\":567");
                  Ok ()
            )
        )
    )

(* ---------- spec 0.3 §5.2: workdir / env whitelist ---------- *)

let test_agent_resolve_workdir = fun _ctx ->
  let a = { (mk_agent "wd") with Agent.workdir = "/home/u/proj"; allowed_workdirs = [ "/home/u/proj"; "/srv/repos/" ] } in
  let r p = Agent.resolve_workdir a p in
  Test.assert_equal ~expected:(Ok "/home/u/proj") ~actual:(r None);
  Test.assert_equal ~expected:(Ok "/home/u/proj") ~actual:(r (Some "/home/u/proj/"));
  Test.assert_equal ~expected:(Ok "/home/u/proj/sub/dir") ~actual:(r (Some "/home/u/proj//sub/./dir"));
  Test.assert_equal ~expected:(Ok "/srv/repos/x") ~actual:(r (Some "/srv/repos/x"));
  let rejected p = match r (Some p) with Error _ -> true | Ok _ -> false in
  Test.assert_equal ~expected:true ~actual:(rejected "/home/u/proj/../other");
  Test.assert_equal ~expected:true ~actual:(rejected "/home/u/project2");
  Test.assert_equal ~expected:true ~actual:(rejected "relative/path");
  Test.assert_equal ~expected:true ~actual:(rejected "/etc");
  let only_default = { (mk_agent "wd2") with Agent.workdir = "/home/u/proj" } in
  Test.assert_equal ~expected:(Ok "/home/u/proj/a") ~actual:(Agent.resolve_workdir only_default (Some "/home/u/proj/a"));
  Test.assert_equal
    ~expected:true
    ~actual:(match Agent.resolve_workdir only_default (Some "/tmp") with Error _ -> true | Ok _ -> false);
  let unconfigured = mk_agent "wd3" in
  Test.assert_equal
    ~expected:true
    ~actual:(match Agent.resolve_workdir unconfigured (Some "/tmp") with Error _ -> true | Ok _ -> false);
  Ok ()

let test_agent_env_whitelist = fun _ctx ->
  let cwd = Env.current_dir () |> Result.unwrap |> Path.to_string in
  let script = cwd ^ "/packages/oasis/tests/fixtures/agent_env.sh" in
  let _ = Env.set ~var:"DEEPSEEK_API_KEY" ~value:"sk-must-not-leak" in
  let _ = Env.set ~var:"OASIS_PASS_TEST" ~value:"passed-through" in
  let a =
    {
      (mk_agent ~args:[ script ] ~home:"/custom/home" "agent_env") with
      Agent.workdir = "/tmp";
      env_passthrough = [ "OASIS_PASS_TEST" ];
    }
  in
  let me = self () in
  let _ =
    Runtime.spawn_blocked (fun () ->
      let res = Agent.collect ~agent:a ~model:"" ~prompt:"" () in
      send me (Agent_collect_done res);
      Ok ())
  in
  let selector msg =
    match msg with
    | Agent_collect_done r -> Select r
    | _ -> Skip
  in
  let result = receive ~selector ~timeout:(Time.Duration.from_secs 30) () in
  let _ = Env.remove ~var:"DEEPSEEK_API_KEY" in
  let _ = Env.remove ~var:"OASIS_PASS_TEST" in
  match result with
  | Ok txt ->
      Test.assert_equal ~expected:true ~actual:(String.contains txt "HOME=/custom/home");
      Test.assert_equal ~expected:true ~actual:(String.contains txt "KEY=unset");
      Test.assert_equal ~expected:true ~actual:(String.contains txt "PASS=passed-through");
      Test.assert_equal ~expected:true ~actual:(String.contains txt "PATHSET=yes");
      (* macOS: /tmp is a symlink to /private/tmp *)
      Test.assert_equal
        ~expected:true
        ~actual:(String.contains txt "PWD=/tmp" || String.contains txt "PWD=/private/tmp");
      Ok ()
  | Error e -> Error ("collect failed: " ^ e)
  | exception Receive_timeout -> Error "collect timeout"

let pid_alive = fun pid ->
  let stdio = { Process.stdin = Process.Stdin.Null; stdout = Process.Stdout.Null; stderr = Process.Stderr.Null } in
  match Process.spawn ~program:"/bin/kill" ~args:[| "-0"; pid |] ~stdio () with
  | Error _ -> false
  | Ok k ->
      let rec wait () =
        match Process.try_wait k with
        | Ok (Some (Process.Exited c)) -> c = 0
        | Ok (Some _) | Error _ -> false
        | Ok None -> sleep (Time.Duration.from_millis 10); wait ()
      in
      let alive = wait () in
      let _ = Process.close k in
      alive

let test_agent_timeout_kills_process_tree = fun _ctx ->
  let cwd = Env.current_dir () |> Result.unwrap |> Path.to_string in
  let script = cwd ^ "/packages/oasis/tests/fixtures/agent_fork.sh" in
  let pid_file = "/tmp/oasis-agent-fork.pid" in
  let a = mk_agent ~args:[ script; pid_file ] ~timeout_s:1 "agent_fork" in
  let me = self () in
  let _ =
    Runtime.spawn_blocked (fun () ->
      let res = Agent.collect ~agent:a ~model:"" ~prompt:"" () in
      send me (Agent_collect_done res);
      Ok ())
  in
  let selector msg =
    match msg with
    | Agent_collect_done r -> Select r
    | _ -> Skip
  in
  match receive ~selector ~timeout:(Time.Duration.from_secs 30) () with
  | exception Receive_timeout -> Error "collect did not return after the watchdog fired"
  | Ok _ -> Error "expected a timeout"
  | Error _ -> (
      match Fs.read_to_string (Path.from_string pid_file |> Result.unwrap) with
      | Error _ -> Error "fixture did not record the child pid"
      | Ok content ->
          let _ = Fs.remove_file (Path.from_string pid_file |> Result.unwrap) in
          let child = String.trim content in
          sleep (Time.Duration.from_millis 200);
          Test.assert_equal ~expected:false ~actual:(pid_alive child);
          Ok ()
    )

let test_agent_dies_with_gateway = fun _ctx ->
  (* a stand-in gateway (sh) starts the group leader and exits; the leader
     must take the agent's tree down with it *)
  let dir = unique_dir "orphan" in
  let _ = Fs.create_dir_all (Path.from_string dir |> Result.unwrap) in
  let leader = Agent.absolute (dir ^ "/leader.pl") in
  let pid_file = Agent.absolute (dir ^ "/child.pid") in
  let _ = Fs.write Agent.group_leader_script (Path.from_string leader |> Result.unwrap) in
  let cmd = "/usr/bin/perl " ^ leader ^ " /bin/sh " ^ fix "agent_fork.sh" ^ " " ^ pid_file ^ " & sleep 0.5" in
  let stdio = { Process.stdin = Process.Stdin.Null; stdout = Process.Stdout.Null; stderr = Process.Stderr.Null } in
  match Process.spawn ~program:"/bin/sh" ~args:[| "-c"; cmd |] ~stdio () with
  | Error _ -> Error "spawn failed"
  | Ok p -> (
      let rec wait () = match Process.try_wait p with Ok None -> sleep (Time.Duration.from_millis 20); wait () | _ -> () in
      wait ();
      let _ = Process.close p in
      sleep (Time.Duration.from_millis 1200);
      match Fs.read_to_string (Path.from_string pid_file |> Result.unwrap) with
      | Error _ -> Error "fixture did not record the child pid"
      | Ok content ->
          Test.assert_equal ~expected:false ~actual:(pid_alive (String.trim content));
          Ok ())

let test_thread_marks_interrupted_turns = fun _ctx ->
  let t = Oasis.Thread.create () in
  Oasis.Thread.ensure t ~id:"th-1" ~title:"x";
  let turn status request_id =
    { Oasis.Thread.request_id; prompt = "p"; answer = ""; executor = "claude_code"; mode = "agent"; status; finished_ms = 0 }
  in
  Oasis.Thread.append_turn t ~id:"th-1" (turn "ok" "r1");
  Oasis.Thread.append_turn t ~id:"th-1" (turn "running" "r2");
  Test.assert_equal ~expected:1 ~actual:(Oasis.Thread.mark_interrupted t);
  let th = Oasis.Thread.get t "th-1" |> Option.unwrap in
  Test.assert_equal ~expected:[ "ok"; "interrupted" ] ~actual:(List.map th.Oasis.Thread.turns ~fn:(fun x -> x.Oasis.Thread.status));
  (* the follow-up still knows who ran it and that it stopped midway *)
  let msgs = Oasis.Thread.history_messages th |> List.map ~fn:Json.to_string |> String.concat "" in
  Test.assert_equal ~expected:true ~actual:(String.contains msgs "上一轮未完成");
  Ok ()

let test_gateway_delete_thread = fun _ctx ->
  match start_mocks 1 with
  | Error e -> Error e
  | Ok mocks -> (
      let m = List.get_unchecked mocks ~at:0 in
      Mock.set_scenario m { (Mock.default_scenario) with body = openai_ok_body ~content:"a" };
      match Gateway.start ~config_path:None ~config:(handoff_config mocks) ~port:0 () with
      | Error e -> Error ("gateway: " ^ e)
      | Ok gw -> (
          match gw_post ~port:gw.port ~path:"/v1/chat/completions" ~headers:[ ("Content-Type", "application/json") ] ~body:(chat_body "q") with
          | Error e -> Error e
          | Ok _ -> (
              match latest_thread ~port:gw.port with
              | Error e -> Error e
              | Ok th -> (
                  match
                    gw_post ~port:gw.port ~path:"/api/thread/delete" ~headers:[ ("Content-Type", "application/json") ]
                      ~body:(Json.to_string (Json.obj [ ("id", Json.string th); ("files", Json.bool true) ]))
                  with
                  | Error e -> Error e
                  | Ok (status, _) -> (
                      Test.assert_equal ~expected:200 ~actual:status;
                      match (gw_get ~port:gw.port ~path:("/api/thread?id=" ^ th), gw_get ~port:gw.port ~path:"/api/feed?limit=50") with
                      | (Ok (st, _), Ok (_, feed)) ->
                          Test.assert_equal ~expected:404 ~actual:st;
                          Test.assert_equal ~expected:false ~actual:(String.contains feed th);
                          (match
                             gw_post ~port:gw.port ~path:"/api/thread/delete" ~headers:[ ("Content-Type", "application/json") ]
                               ~body:(Json.to_string (Json.obj [ ("id", Json.string th) ]))
                           with
                           | Ok (again, _) ->
                               Test.assert_equal ~expected:404 ~actual:again;
                               Ok ()
                           | Error e -> Error e)
                      | (Error e, _) | (_, Error e) -> Error e)))))

let test_gateway_agent_runs_until_cancelled = fun _ctx ->
  let config =
    mk_config_agents
      ~accounts:[ mk_account "acc_api" ]
      ~agents:[ mk_agent ~args:[ "-c"; "/usr/bin/perl -e 'setpgrp(0,0); exec \"sleep\", \"31\"' & echo $! > /tmp/oasis-cancel-child.pid; wait" ] ~timeout_s:0 "agent_slow" ]
      ~kb:[ mk_kb_model "m-x" ]
      ~routes:[]
      ~max_fallback:1
  in
  match Gateway.start ~config_path:None ~config ~port:0 () with
  | Error e -> Error ("gateway: " ^ e)
  | Ok gw -> (
      let t0 = Oasis.Signals.now_ms () in
      match
        gw_post ~port:gw.port ~path:"/v1/chat/completions"
          ~headers:[ ("Content-Type", "application/json"); ("X-Oasis-Agent", "agent_slow"); ("X-Oasis-Timeout", "1") ]
          ~body:(chat_body "q")
      with
      | Error e -> Error e
      | Ok (status, resp) -> (
          Test.assert_equal ~expected:499 ~actual:status;
          Test.assert_equal ~expected:true ~actual:(String.contains resp "cancelled:timeout:1");
          Test.assert_equal ~expected:true ~actual:(Oasis.Signals.now_ms () - t0 < 8000);
          sleep (Time.Duration.from_millis 300);
          (match Fs.read_to_string (Path.from_string "/tmp/oasis-cancel-child.pid" |> Result.unwrap) with
           | Ok pid ->
               let _ = Fs.remove_file (Path.from_string "/tmp/oasis-cancel-child.pid" |> Result.unwrap) in
               (* the child left the agent's process group, like grok's tool shells *)
               Test.assert_equal ~expected:false ~actual:(pid_alive (String.trim pid))
           | Error _ -> Test.assert_equal ~expected:"child pid file" ~actual:"missing");
          match gw_post ~port:gw.port ~path:"/api/feed/cancel" ~headers:[ ("Content-Type", "application/json") ] ~body:"{\"id\":\"req-none\"}" with
          | Error e -> Error e
          | Ok (st, _) ->
              Test.assert_equal ~expected:404 ~actual:st;
              Ok ()))

let test_agent_exit_reaps_lingering_helpers = fun _ctx ->
  let cwd = Env.current_dir () |> Result.unwrap |> Path.to_string in
  let script = cwd ^ "/packages/oasis/tests/fixtures/agent_linger.sh" in
  let a = mk_agent ~args:[ script ] ~timeout_s:60 "agent_linger" in
  let me = self () in
  let t0 = Time.Instant.now () in
  let _ =
    Runtime.spawn_blocked (fun () ->
      let res = Agent.collect ~agent:a ~model:"" ~prompt:"" () in
      send me (Agent_collect_done res);
      Ok ())
  in
  let selector msg =
    match msg with
    | Agent_collect_done r -> Select r
    | _ -> Skip
  in
  match receive ~selector ~timeout:(Time.Duration.from_secs 20) () with
  | exception Receive_timeout -> Error "collect blocked on a stdout pipe held by a lingering helper"
  | Error e -> Error ("expected success: " ^ e)
  | Ok text ->
      Test.assert_equal ~expected:"answer from lingering agent\n" ~actual:text;
      Test.assert_equal ~expected:true ~actual:(Time.Duration.to_millis (Time.Instant.elapsed t0) < 10000);
      Ok ()

let tests =
  Test.[
    case "chunked decoding: single chunk" test_chunked_single_chunk;
    case "chunked decoding: fragmented across feeds" test_chunked_fragmented;
    case "chunked decoding: chunk extensions" test_chunked_extensions;
    case "request serialization" test_request_serialization;
    case "response head parsing + header lookup" test_response_head_parsing;
    case "SSE aggregation incl multi-line data" test_sse_aggregation;
    case "SSE [DONE] sentinel" test_sse_done_sentinel;
    case "SSE CRLF and comment lines" test_sse_crlf_and_comments;
    case "handoff: full-prefix continuation forwards only new text" test_handoff_full_prefix;
    case "handoff: early divergence forwards everything" test_handoff_early_divergence;
    case "handoff: partial-prefix divergence" test_handoff_partial_prefix_divergence;
    case "handoff: exact match forwards nothing" test_handoff_exact_match_forwards_nothing;
    case "handoff: fragmented feeds equal single feed" test_handoff_incremental_property;
    case "handoff: utf-8 divergence inside a shared lead byte" test_handoff_utf8_mid_char_divergence;
    case "handoff: utf-8 sequence split across feeds" test_handoff_utf8_split_across_feeds;
    case "handoff: G1/G2/G3 classification" test_handoff_classify_levels;
    case "handoff: restart forwards the whole new answer" test_handoff_restart_forwards_whole_answer;
    case "handoff: undecided head waits for the window" test_handoff_undecided_head_waits;
    case "handoff: random utf-8 property (100 rounds)" test_handoff_random_utf8_property;
            case "integration: mid-stream quota death + seamless continuation" test_mid_stream_quota_death_then_seamless_continuation;
    case "kb: fit scoring" test_kb_fit_scoring;
    case "kb: cost estimate and context checks" test_kb_cost_and_context;
    case "config: TOML parse" test_config_toml_parse;
    case "config: enabled=false parses as disabled" test_config_enabled_false_parses;
    case "router: category order and fallback chain" test_router_category_order_and_fallback;
    case "router: model mismatch rejection" test_router_model_mismatch_rejects;
    case "router: budget and daily limit rejection" test_router_budget_and_daily_rejects;
    case "ledger: pure state transitions incl day rollover" test_ledger_pure_transitions;
    case "ledger: usd formatting" test_ledger_format_usd;
            case "gateway: budget blocks all accounts (402)" test_gateway_budget_blocks_all;
    case ~size:Test.Large "gateway: end-to-end scenarios (routing, 429 fallback, SSE, seamless handoff, sticky)" test_gateway_end_to_end_scenarios;
    case "session: pin, lookup and expiry" test_session_pin_lookup_expiry;
    case "anthropic: request conversion" test_anthropic_to_request;
    case "anthropic: response conversion" test_anthropic_from_response;
    case "anthropic: stream event parsing" test_anthropic_stream_events;
    case ~size:Test.Large "gateway: anthropic protocol non-stream + stream" test_gateway_anthropic_non_stream_and_stream;
    case ~size:Test.Large "gateway: cross-protocol seamless handoff" test_gateway_cross_protocol_seamless_handoff;
    case "agent: args template" test_agent_build_args;
    case "agent: claude stream-json parse" test_agent_claude_stream_json_parse;
    case "agent: cursor stream-json parse" test_agent_cursor_stream_json_parse;
    case "steps: parse claude/cursor/gemini/kimi/grok events" test_steps_parse_agents;
    case "steps: answer joins messages and post-tool text" test_steps_answer_join;
    case "steps: clip keeps utf-8 valid" test_steps_clip_utf8;
    case ~size:Test.Large "agent: exit reaps helpers that keep stdout open" test_agent_exit_reaps_lingering_helpers;
    case "classify: prompt content to category" test_classify_prompts;
    case "router: latency scored relative to the fastest" test_router_relative_latency;
    case "router: best goal avoids a very slow account" test_router_best_avoids_very_slow;
    case "upstream: max_tokens only when the client sets it" test_upstream_body_max_tokens_passthrough;
    case "quality: ratings blend into fit" test_quality_blend;
    case "committee: members and feed events" test_committee_members_and_feed;
    case "gateway: committee answers and synthesis" test_gateway_committee;
    case "gateway: thread follow-up carries the conversation" test_gateway_thread_carries_history;
    case ~size:Test.Large "agent: tree dies with the gateway" test_agent_dies_with_gateway;
    case "thread: running turns become interrupted on restart" test_thread_marks_interrupted_turns;
    case ~size:Test.Large "gateway: delete a conversation" test_gateway_delete_thread;
    case ~size:Test.Large "gateway: agents run in the conversation's own workspace" test_gateway_agent_runs_in_task_workspace;
    case ~size:Test.Large "gateway: thread follow-up resumes the agent session" test_gateway_thread_resumes_agent_session;
    case ~size:Test.Large "gateway: caller deadline cancels account calls without failover" test_gateway_client_deadline_accounts;
    case ~size:Test.Large "gateway: agents run until cancelled" test_gateway_agent_runs_until_cancelled;
    case "router: exploration promotes the least-measured" test_router_explore;
    case "judge: verdict and spec parsing" test_judge_parse;
    case "feed: ratings, review and final answer" test_feed_ratings_and_answer;
    case "gateway: user rating feeds learned quality" test_gateway_rating_feeds_routing;
    case "feed: explains inferred category" test_feed_explains_inferred_category;
    case "stream: reasoning-only answer fails over" test_stream_reasoning_only_fails_over;
    case "non-stream: empty answer fails over" test_nonstream_empty_answer_fails_over;
    case "feed: folds events into one task record" test_feed_folds_events;
    case ~size:Test.Large "feed: gateway records agent work steps" test_gateway_feed_records_agent_steps;
    case ~size:Test.Large "agent: watchdog timeout kills the whole process tree" test_agent_timeout_kills_process_tree;
    case "gateway: connect_ip overrides DNS" test_gateway_connect_ip_overrides_dns;
    case "stream: finish_reason then EOF without [DONE] is a clean end" test_stream_finish_reason_without_done;
    case "stream: EOF without finish_reason or [DONE] is a cut" test_stream_eof_without_finish_is_a_cut;
    case "agent: fit scoring" test_agent_fit;
    case ~size:Test.Large "gateway: agent routing + fallback" test_gateway_agent_non_stream_and_fallback;
    case ~size:Test.Large "gateway: agent streaming" test_gateway_agent_stream_and_explicit_chat;
    case "mcp: rpc parsing" test_mcp_parse;
    case "inbox: deliver/check/persist" test_inbox_bus;
    case "inbox: unverified prefix, 16KB cap, recipient names" test_inbox_prefix_limit_and_names;
    case "discover: scan fixture" test_discover_scan_fixture;
    case "activity: scan fixture" test_activity_scan_fixture;
    case ~size:Test.Large "gateway: inbox MCP roundtrip" test_gateway_inbox_mcp;
    case ~size:Test.Large "agent: HOME env injection" test_agent_home_env_injection;
    case ~size:Test.Large "gateway: agent async task + poll" test_gateway_agent_async_task;
    case ~size:Test.Large "real: DeepSeek non-stream roundtrip (needs ./.ds-key)" test_deepseek_real_roundtrip;
    case "signals: ema and trip logic" test_signals_ema_and_trip;
    case "signals: window rollover and breaker" test_signals_window_and_breaker;
    case "signals: consecutive failures trip breaker across window rolls" test_signals_consecutive_failure_breaker;
    case "signals: release_in_flight without breaker impact" test_signals_release_in_flight;
    case "router v2: cheapest vs fastest goal" test_router_v2_cheapest_goal;
    case "router v2: breaker open rejects account" test_router_v2_breaker_blocks;
    case ~size:Test.Large "H1: exact replay is deduplicated (G1)" test_h1_exact_replay;
    case ~size:Test.Large "ws: streaming handoff emits the full event trace" test_ws_events_trace_streaming_handoff;
    case ~size:Test.Large "H2: direct continuation (G1)" test_h2_direct_continuation;
    case ~size:Test.Large "H3: divergence inside a multi-byte char stays valid UTF-8 (G2)" test_h3_multibyte_divergence;
    case ~size:Test.Large "H4: drifting replay forwarded from divergence (G2)" test_h4_mutated_replay;
    case ~size:Test.Large "H5: early divergence restarts with a notice (G3)" test_h5_restart_with_notice;
    case ~size:Test.Large "H5b: non-prefill fallback restarts with a notice (G3)" test_h5b_non_prefill_account_restarts;
    case ~size:Test.Large "H6: handoff limit ends with an SSE error (G0)" test_h6_handoff_limit;
    case ~size:Test.Large "H7: tools requests never splice a prefix (G3)" test_h7_tools_request_restarts;
    case ~size:Test.Large "tools: sync request forwards tools/tool_choice/temperature, tool_calls come back" test_tools_sync_passthrough;
    case ~size:Test.Large "tools: streamed tool_call deltas are relayed verbatim" test_tools_stream_relays_tool_calls;
    case ~size:Test.Large "tools: cut mid tool call ends with an SSE error, no restart" test_tools_cut_mid_tool_call_fails_without_restart;
    case ~size:Test.Large "tools: anthropic-only routes are rejected with 400" test_tools_need_openai_protocol;
    case ~size:Test.Large "H8: session pin migrates to the fallback" test_h8_session_pin_migrates;
    case "router: unknown price is neutral and reported" test_router_unknown_price_is_neutral;
    case "router: agent latency scale" test_router_agent_latency_scale;
    case "signals: failure classification" test_signals_classify_error;
    case "signals: quota reset dates" test_signals_quota_reset_at;
    case "signals: parked persistence roundtrip" test_signals_parked_roundtrip;
    case ~size:Test.Large "gateway: quota 429 parks the account across restarts" test_gateway_quota_parks_across_restart;
    case ~size:Test.Large "gateway: model \"auto\" / \"oasis\" lets Oasis route" test_gateway_model_auto_routes;
    case ~size:Test.Large "gateway: bearer auth on /v1, /api, /mcp, /ws" test_gateway_bearer_auth;
    case ~size:Test.Large "gateway: loopback-only without a token; GET /api/reload is 405" test_gateway_loopback_guards;
    case ~size:Test.Large "gateway: decisions.jsonl survives a restart" test_gateway_decisions_survive_restart;
    case ~size:Test.Large "gateway: streaming usage chunk feeds the ledger" test_gateway_stream_usage_recorded;
    case "thread: history messages are oldest first" test_thread_history_oldest_first;
    case "observe: plan page yields tier, ratio, and reset" test_observe_plan_page;
    case "observe: chat text is not a reading" test_observe_ignores_chat;
    case "observe: token fraction beside usage" test_observe_tokens_near_usage;
    case "observe: token total beside a token caption" test_observe_token_total;
    case "observe: snapshot tree is read from data.tree" test_observe_snapshot_tree;
    case "observe: a quoted plan inside chat is not a reading" test_observe_ignores_quoted_plan;
    case "setup: merge with no choices keeps the file byte for byte" test_setup_merge_noop_keeps_text;
    case "setup: merge toggles, adds, extends routes, keeps user lines" test_setup_merge_changes;
    case "setup: fresh config keeps skeleton order" test_setup_fresh_skeleton_order;
    case "setup: secrets.env parsing" test_setup_parse_secrets;
    case "setup: model specs from the catalog and name heuristics" test_setup_spec_for;
    case "audit: secret redaction and hash8" test_redact_secrets;
    case ~size:Test.Large "gateway: audit log and errors carry no content or keys" test_gateway_audit_has_no_content_or_keys;
    case "agent: workdir resolution against allowed_workdirs" test_agent_resolve_workdir;
    case ~size:Test.Large "agent: env whitelist hides API keys" test_agent_env_whitelist;
          ]

let main ~args =
  Test.Cli.main ~name:"oasis_tests" ~tests ~args ()

let () = Runtime.run ~main ~args:Env.args ()
