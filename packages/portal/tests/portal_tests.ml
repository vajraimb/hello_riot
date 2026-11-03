open Std
open Std.Collections

module Client = Portal.Client
module Chunked = Portal.Chunked
module Sse = Portal.Sse
module Handoff = Portal.Handoff
module Mock = Portal.Mock
module Json = Std.Data.Json
module Kb = Portal.Kb
module Config = Portal.Config
module Ledger = Portal.Ledger
module Router = Portal.Router
module Signals = Portal.Signals
module Session = Portal.Session
module Anthropic = Portal.Anthropic
module Agent = Portal.Agent
module Mcp = Portal.Mcp
module Inbox = Portal.Inbox
module Discover = Portal.Discover
module Activity = Portal.Activity
module Gateway = Portal.Gateway

let unique_dir = fun prefix -> "./.oasis-test-data/" ^ prefix ^ "-" ^ Int.to_string (Signals.now_ms ())


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
                  (
                    match List.head cfg.Config.kb with
                    | None -> Error "no kb parsed"
                    | Some m ->
                        Test.assert_equal ~expected:4 ~actual:m.Portal.Kb.tier;
                        Test.assert_equal
                          ~expected:true
                          ~actual:(List.any m.Portal.Kb.strengths ~fn:(String.equal "coding"));
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
    data_dir = "./.oasis-test-data";
    auth_token_env = None;
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

let mk_snap = fun ?(ema = 200) ?(inflight = 0) ?(breaker_open = false) ?(rpm_used = 0) () ->
  {
    Router.latency_ema_ms = ema;
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
                                                          Test.assert_equal ~expected:true ~actual:(String.contains s5a_body "s5a");
                                                          (* acc_a dies -> handoff acc_b re-pins the session *)
                                                          Mock.set_scenario mock_a { (Mock.default_scenario) with status = 429; body = "{}" };
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
                                                                Test.assert_equal ~expected:true ~actual:(String.contains s5b_body "s5b");
                                                                (* acc_a recovers, but the session stays pinned to acc_b *)
                                                                Mock.set_scenario mock_a { (Mock.default_scenario) with body = openai_ok_body ~content:"s5a" };
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
                                                                        ~actual:(String.contains s5c_body "s5b");
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
  }

let fix = fun name -> "./packages/portal/tests/fixtures/" ^ name

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
    ~expected:(Some "plain line\n")
    ~actual:(Agent.extract_text ~command:"gemini" "plain line");
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
    data_dir = "./.oasis-test-data";
    auth_token_env = None;
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
              poll 0
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
  Test.assert_equal ~expected:0 ~actual:(Router.latency_score ~ema_ms:30_000);
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
          Test.assert_equal ~expected:404 ~actual:(status ~method_:"GET" ~path:"/api/reload" ~headers:[]);
          Ok ()
    )

(* ---------- spec 0.3 §5.3: audit redaction ---------- *)

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
  let script = cwd ^ "/packages/portal/tests/fixtures/agent_env.sh" in
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
      Test.assert_equal ~expected:true ~actual:(String.contains txt "PWD=/tmp");
      Ok ()
  | Error e -> Error ("collect failed: " ^ e)
  | exception Receive_timeout -> Error "collect timeout"

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
    case ~size:Test.Large "H2: direct continuation (G1)" test_h2_direct_continuation;
    case ~size:Test.Large "H3: divergence inside a multi-byte char stays valid UTF-8 (G2)" test_h3_multibyte_divergence;
    case ~size:Test.Large "H4: drifting replay forwarded from divergence (G2)" test_h4_mutated_replay;
    case ~size:Test.Large "H5: early divergence restarts with a notice (G3)" test_h5_restart_with_notice;
    case ~size:Test.Large "H5b: non-prefill fallback restarts with a notice (G3)" test_h5b_non_prefill_account_restarts;
    case ~size:Test.Large "H6: handoff limit ends with an SSE error (G0)" test_h6_handoff_limit;
    case ~size:Test.Large "H7: tools requests never splice a prefix (G3)" test_h7_tools_request_restarts;
    case ~size:Test.Large "H8: session pin migrates to the fallback" test_h8_session_pin_migrates;
    case "router: unknown price is neutral and reported" test_router_unknown_price_is_neutral;
    case "router: agent latency scale" test_router_agent_latency_scale;
    case "signals: failure classification" test_signals_classify_error;
    case "signals: quota reset dates" test_signals_quota_reset_at;
    case "signals: parked persistence roundtrip" test_signals_parked_roundtrip;
    case ~size:Test.Large "gateway: quota 429 parks the account across restarts" test_gateway_quota_parks_across_restart;
    case ~size:Test.Large "gateway: bearer auth on /v1, /api, /mcp, /ws" test_gateway_bearer_auth;
    case ~size:Test.Large "gateway: loopback-only without a token; GET /api/reload is 404" test_gateway_loopback_guards;
    case "audit: secret redaction and hash8" test_redact_secrets;
    case ~size:Test.Large "gateway: audit log and errors carry no content or keys" test_gateway_audit_has_no_content_or_keys;
    case "agent: workdir resolution against allowed_workdirs" test_agent_resolve_workdir;
    case ~size:Test.Large "agent: env whitelist hides API keys" test_agent_env_whitelist;
          ]

let main ~args =
  Test.Cli.main ~name:"portal_tests" ~tests ~args ()

let () = Runtime.run ~main ~args:Env.args ()
