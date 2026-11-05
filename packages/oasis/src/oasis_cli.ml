open Std

(** Oasis binary: gateway server + CLI client.

    Server mode:      oasis [--config PATH] [--example-config]
                      (default config: $OASIS_HOME/oasis.toml, i.e. ~/.oasis/oasis.toml)
    Client commands:  oasis [--server URL] <models|status|budget|decisions|reload|ask ...> *)

module Client = Oasis.Client
module Sse = Oasis.Sse
module Json = Std.Data.Json

let example_config =
  {|# Oasis — 个人 AI 账户门户配置示例
# 金额单位: nano-dollars (1 USD = 1_000_000_000 nano)
# 价格: 每 token 的 nano-dollars (例: $0.15/1M tokens = 150)

[server]
host = "127.0.0.1"
port = 9899
# data_dir = "~/.oasis/data"            # 默认；agent 工作目录默认在 ~/.oasis/workspaces
# auth_token_env = "OASIS_AUTH_TOKEN"   # 设置后所有 API 需 Bearer；非回环 host 必须设置

[[models]]
name = "deepseek-chat"
tier = 4
strengths = ["coding", "analysis", "general"]
weaknesses = ["long_doc"]
context_window = 65536
max_output = 8192
latency = "medium"
in_price_nano = 140
out_price_nano = 280
cache_hit_price_nano = 14

[[accounts]]
name = "deepseek_pro"
provider = "deepseek"
base_url = "https://api.deepseek.com"
api_key_env = "DEEPSEEK_API_KEY"
models = ["deepseek-chat"]
enabled = true
rpm = 60
tpm = 100000
daily_limit = 500
monthly_budget_nano = 5000000000   # $5

[[routes]]
category = "coding"
accounts = ["deepseek_pro"]

[policy]
goal = "balanced"
max_fallback = 2
|}

(** First run: the config does not exist yet, so the example is written
    there to edit (keys stay in environment variables, never in the file). *)
let ensure_default_config = fun path ->
  match Path.from_string path with
  | Error _ -> ()
  | Ok p -> (
      match Fs.exists p with
      | Ok true -> ()
      | _ ->
          let _ = Fs.create_dir_all (Path.from_string (Oasis.Config.home ()) |> Result.unwrap) in
          (match Fs.write example_config p with
           | Ok () -> println ("已生成默认配置 " ^ path ^ "，按需编辑后重启（API key 只放环境变量）")
           | Error _ -> ()))

let banner = fun (config : Oasis.Config.t) ~config_path (pool : Oasis_net.Atacama.pool) ->
  println "======================================================";
  println "  Oasis — 个人 AI 账户门户 (Riot / OCaml)";
  println "======================================================";
  println
    ("  OpenAI 兼容端点 : http://127.0.0.1:"
    ^ Int.to_string pool.Oasis_net.Atacama.port
    ^ "/v1/chat/completions");
  println
    ("  仪表盘           : http://127.0.0.1:"
    ^ Int.to_string pool.Oasis_net.Atacama.port
    ^ "/");
  println "  模型列表         : GET /v1/models";
  println "  路由决策         : GET /api/decisions";
  println "  成本账本         : GET /api/ledger";
  println ("  配置             : " ^ config_path);
  println ("  数据             : " ^ config.Oasis.Config.data_dir);
  println ("  agent 工作目录   : " ^ Oasis.Workspace.root config);
  println "======================================================"

let rec keep_alive = fun () ->
  sleep (Time.Duration.from_secs 60);
  keep_alive ()

(* ---------- CLI client ---------- *)

let default_server = "http://127.0.0.1:9899"

(** Token for a gateway with [server.auth_token_env] set, from [OASIS_AUTH_TOKEN]. *)
let cli_auth_headers = fun () ->
  match Env.var Env.String ~name:"OASIS_AUTH_TOKEN" with
  | Some t when not (String.is_empty (String.trim t)) -> [ ("Authorization", "Bearer " ^ String.trim t) ]
  | _ -> []

let cli_get = fun ~server ~path ->
  let (_scheme, host, port_opt, _path) = Oasis.Gateway.parse_base_url server in
  let port = port_opt |> Option.unwrap_or ~default:80 in
  let addr = Net.Addr.from_host_and_port ~host ~port |> Result.unwrap in
  match Client.connect_plain addr with
  | Error e -> Error (Client.error_to_string e)
  | Ok conn ->
      let req =
        Client.make_request ~method_:"GET" ~path ~headers:(("Host", host) :: cli_auth_headers ()) ()
      in
      let res = Client.request_string conn req in
      Client.close conn;
      (
        match res with
        | Error e -> Error (Client.error_to_string e)
        | Ok (resp, body) -> Ok (resp.Client.status, body)
      )

let cli_post_json = fun ~server ~path ~headers ~body ->
  let (_scheme, host, port_opt, _path) = Oasis.Gateway.parse_base_url server in
  let port = port_opt |> Option.unwrap_or ~default:80 in
  let addr = Net.Addr.from_host_and_port ~host ~port |> Result.unwrap in
  match Client.connect_plain addr with
  | Error e -> Error (Client.error_to_string e)
  | Ok conn ->
      let req =
        Client.make_request
          ~method_:"POST"
          ~path
          ~headers:(("Host", host) :: (cli_auth_headers () @ headers))
          ~body
          ()
      in
      let res = Client.request_string conn req in
      Client.close conn;
      (
        match res with
        | Error e -> Error (Client.error_to_string e)
        | Ok (resp, body) -> Ok (resp.Client.status, body)
      )

let get_str = fun j field ->
  Json.get_field field j |> Option.and_then ~fn:Json.get_string

let get_int = fun j field ->
  Json.get_field field j |> Option.and_then ~fn:Json.get_int

let get_arr = fun j field ->
  Json.get_field field j |> Option.and_then ~fn:Json.get_array
  |> Option.unwrap_or ~default:[]

let pad = fun s width ->
  s ^ String.make ~len:(max 1 (width - String.length s)) ~char:' '

let cmd_models = fun ~server ->
  match cli_get ~server ~path:"/v1/models" with
  | Error e -> Error ("models: " ^ e)
  | Ok (_, body) -> (
      match Json.from_string body with
      | Error _ -> Error "models: bad json"
      | Ok j ->
          let models = get_arr j "data" in
          println "MODEL           TIER  CTX       MAXOUT  LATENCY  STRENGTHS";
          List.for_each
            models
            ~fn:(fun m ->
              let name = get_str m "name" |> Option.unwrap_or ~default:"?" in
              let tier = get_int m "tier" |> Option.unwrap_or ~default:0 in
              let ctx = get_int m "context_window" |> Option.unwrap_or ~default:0 in
              let mo = get_int m "max_output" |> Option.unwrap_or ~default:0 in
              let lat = get_str m "latency" |> Option.unwrap_or ~default:"?" in
              let strengths =
                get_arr m "strengths"
                |> List.filter_map ~fn:Json.get_string
                |> String.concat ","
              in
              println
                (pad name 16
                ^ Int.to_string tier
                ^ "     "
                ^ Int.to_string ctx
                ^ "   "
                ^ Int.to_string mo
                ^ "      "
                ^ pad lat 8
                ^ strengths));
          Ok ()
    )

let cmd_status = fun ~server ->
  match cli_get ~server ~path:"/api/accounts" with
  | Error e -> Error ("status: " ^ e)
  | Ok (_, body) -> (
      match Json.from_string body with
      | Error _ -> Error "status: bad json"
      | Ok j ->
          let accounts = get_arr j "accounts" in
          println "ACCOUNT          BREAKER  LAT_EMA  INFLIGHT  DAY     MONTH / BUDGET";
          List.for_each
            accounts
            ~fn:(fun a ->
              let name = get_str a "name" |> Option.unwrap_or ~default:"?" in
              let breaker = get_str a "breaker" |> Option.unwrap_or ~default:"?" in
              let lat = get_int a "latency_ema_ms" |> Option.unwrap_or ~default:0 in
              let inflight = get_int a "in_flight" |> Option.unwrap_or ~default:0 in
              let day = get_int a "day_requests" |> Option.unwrap_or ~default:0 in
              let daily = get_int a "daily_limit" |> Option.unwrap_or ~default:0 in
              let spent = get_str a "month_spent_usd" |> Option.unwrap_or ~default:"?" in
              let budget = get_str a "month_budget_usd" |> Option.unwrap_or ~default:"?" in
              println
                (pad name 17
                ^ pad breaker 9
                ^ pad (Int.to_string lat ^ "ms") 9
                ^ pad (Int.to_string inflight) 9
                ^ pad (Int.to_string day ^ "/" ^ Int.to_string daily) 8
                ^ spent
                ^ " / "
                ^ budget));
          Ok ()
    )

let cmd_budget = fun ~server ->
  match cli_get ~server ~path:"/api/accounts" with
  | Error e -> Error ("budget: " ^ e)
  | Ok (_, body) -> (
      match Json.from_string body with
      | Error _ -> Error "budget: bad json"
      | Ok j ->
          let accounts = get_arr j "accounts" in
          List.for_each
            accounts
            ~fn:(fun a ->
              let name = get_str a "name" |> Option.unwrap_or ~default:"?" in
              let spent = get_str a "month_spent_usd" |> Option.unwrap_or ~default:"?" in
              let budget = get_str a "month_budget_usd" |> Option.unwrap_or ~default:"?" in
              println (name ^ ": " ^ spent ^ " / " ^ budget));
          Ok ()
    )

let cmd_decisions = fun ~server ->
  match cli_get ~server ~path:"/api/decisions" with
  | Error e -> Error ("decisions: " ^ e)
  | Ok (_, body) -> (
      match Json.from_string body with
      | Error _ -> Error "decisions: bad json"
      | Ok j ->
          let ds = get_arr j "decisions" in
          List.for_each
            (List.take ds ~len:10)
            ~fn:(fun d ->
              let cat = get_str d "task_category" |> Option.unwrap_or ~default:"?" in
              let chosen = get_str d "chosen" |> Option.unwrap_or ~default:"(none)" in
              let attempts =
                get_arr d "attempts"
                |> List.filter_map ~fn:(fun at ->
                  let acct = get_str at "account" |> Option.unwrap_or ~default:"?" in
                  let st =
                    match get_int at "status" with
                    | Some s -> Int.to_string s
                    | None -> "err"
                  in
                  Some (acct ^ "(" ^ st ^ ")"))
                |> String.concat " -> "
              in
              println (cat ^ " → " ^ chosen ^ "  [" ^ attempts ^ "]"));
          Ok ()
    )

let cmd_reload = fun ~server ->
  match cli_post_json ~server ~path:"/api/reload" ~headers:[] ~body:"{}" with
  | Error e -> Error ("reload: " ^ e)
  | Ok (status, body) ->
      println ("reload: HTTP " ^ Int.to_string status ^ " " ^ body);
      Ok ()

let cmd_ask = fun ~server ~prompt ~category ~goal ~stream ->
  let body =
    Json.obj
      [
        (
          "messages",
          Json.array
            [ Json.obj [ ("role", Json.string "user"); ("content", Json.string prompt) ] ]
        );
        ("stream", Json.bool stream);
      ]
    |> Json.to_string
  in
  let headers =
    [
      ("Content-Type", "application/json");
      ("X-Oasis-Category", category);
      ("X-Oasis-Goal", goal);
    ]
  in
  if stream then (
    let (_scheme, host, port_opt, _path) = Oasis.Gateway.parse_base_url server in
    let port = port_opt |> Option.unwrap_or ~default:80 in
    let addr = Net.Addr.from_host_and_port ~host ~port |> Result.unwrap in
    match Client.connect_plain addr with
    | Error e -> Error (Client.error_to_string e)
    | Ok conn ->
        let req =
          Client.make_request
            ~method_:"POST"
            ~path:"/v1/chat/completions"
            ~headers:(("Host", host) :: (cli_auth_headers () @ headers))
            ~body
            ()
        in
        (
          match Client.request conn req with
          | Error e ->
              Client.close conn;
              Error (Client.error_to_string e)
          | Ok (resp, body_reader) ->
              if resp.Client.status != 200 then (
                let err = body_reader.Client.read_all () in
                Client.close conn;
                (
                  match err with
                  | Ok s -> Error ("ask: HTTP " ^ Int.to_string resp.Client.status ^ " " ^ s)
                  | Error e -> Error (Client.error_to_string e)
                )
              ) else
                let rec loop sse_state =
                  match body_reader.Client.read_some () with
                  | Error _ -> ()
                  | Ok "" -> ()
                  | Ok chunk ->
                      let (events, sse') = Sse.feed sse_state chunk in
                      List.for_each
                        events
                        ~fn:(fun ev ->
                          if ev.Sse.done_sentinel then
                            print "\n"
                          else
                            let content =
                              match Json.from_string ev.Sse.data with
                              | Error _ -> ev.Sse.data
                              | Ok j ->
                                  Json.get_field "choices" j
                                  |> Option.and_then ~fn:Json.get_array
                                  |> Option.and_then ~fn:List.head
                                  |> Option.and_then ~fn:(fun c -> Json.get_field "delta" c)
                                  |> Option.and_then ~fn:(fun d -> Json.get_field "content" d)
                                  |> Option.and_then ~fn:Json.get_string
                                  |> Option.unwrap_or ~default:ev.Sse.data
                            in
                            print content);
                      loop sse'
                in
                loop Sse.init;
                Client.close conn;
                Ok ()
        )
  ) else
    match cli_post_json ~server ~path:"/v1/chat/completions" ~headers ~body with
    | Error e -> Error ("ask: " ^ e)
    | Ok (status, resp_body) ->
        if status != 200 then
          Error ("ask: HTTP " ^ Int.to_string status ^ " " ^ resp_body)
        else (
          match Json.from_string resp_body with
          | Error _ -> Error "ask: bad json"
          | Ok j ->
              let content =
                Json.get_field "choices" j
                |> Option.and_then ~fn:Json.get_array
                |> Option.and_then ~fn:List.head
                |> Option.and_then ~fn:(fun c -> Json.get_field "message" c)
                |> Option.and_then ~fn:(fun m -> Json.get_field "content" m)
                |> Option.and_then ~fn:Json.get_string
                |> Option.unwrap_or ~default:resp_body
              in
              println content;
              Ok ()
        )

let cli_usage =
  "用法: oasis [--server URL] <models|status|budget|decisions|reload|ask \"...\">\n\
   ask 选项: --category <c> --goal <cheapest|fastest|best|balanced> [--no-stream]\n\
   网关启用鉴权时设置环境变量 OASIS_AUTH_TOKEN"

let cli_main = fun ~server ~args ->
  let category = ref "auto" in
  let goal = ref "balanced" in
  let stream = ref true in
  match args with
  | [] ->
      println cli_usage;
      Ok ()
  | "ask" :: rest -> (
      (* options consume their own values; the rest is the prompt *)
      let rec split acc = function
        | "--category" :: c :: r ->
            category := c;
            split acc r
        | "--goal" :: g :: r ->
            goal := g;
            split acc r
        | "--no-stream" :: r ->
            stream := false;
            split acc r
        | "--stream" :: r ->
            stream := true;
            split acc r
        | w :: r -> split (w :: acc) r
        | [] -> List.rev acc
      in
      let prompt = split [] rest |> String.concat " " in
      if String.is_empty prompt then (
        println "ask 需要一个提问";
        Ok ()
      ) else
        cmd_ask ~server ~prompt ~category:!category ~goal:!goal ~stream:!stream
    )
  | [ "models" ] -> cmd_models ~server
  | [ "status" ] -> cmd_status ~server
  | [ "budget" ] -> cmd_budget ~server
  | [ "decisions" ] -> cmd_decisions ~server
  | [ "reload" ] -> cmd_reload ~server
  | cmd :: _ ->
      eprintln ("未知命令: " ^ cmd);
      println cli_usage;
      Error ("unknown command: " ^ cmd)


(* ---------- self-test ---------- *)

let self_test_pass = ref 0
let self_test_fail = ref 0

let st_check = fun ~label ~actual ~expected ->
  if String.equal actual expected then (
    self_test_pass := !self_test_pass + 1;
    println ("  [PASS] " ^ label)
  ) else (
    self_test_fail := !self_test_fail + 1;
    println ("  [FAIL] " ^ label ^ ": expected=" ^ expected ^ " actual=" ^ actual)
  )

let st_collect_stream = fun ~port ~headers ~body ->
  let addr = Net.Addr.tcp Net.Addr.loopback port in
  match Client.connect_plain addr with
  | Error e -> Error (Client.error_to_string e)
  | Ok conn ->
      let req =
        Client.make_request
          ~method_:"POST"
          ~path:"/v1/chat/completions"
          ~headers:(("Host", "gw") :: headers)
          ~body
          ()
      in
      (
        match Client.request conn req with
        | Error e ->
            Client.close conn;
            Error (Client.error_to_string e)
        | Ok (resp, body_reader) ->
            let rec drain sse_state acc =
              match body_reader.Client.read_some () with
              | Error _ -> (acc, sse_state)
              | Ok "" -> (acc, sse_state)
              | Ok chunk ->
                  let (evs, s') = Sse.feed sse_state chunk in
                  drain s' (acc @ evs)
            in
            let (events, _) = drain Sse.init [] in
            Client.close conn;
            Ok (resp.Client.status, events)
      )

let st_post = fun ~port ~headers ~body ->
  let addr = Net.Addr.tcp Net.Addr.loopback port in
  match Client.connect_plain addr with
  | Error e -> Error (Client.error_to_string e)
  | Ok conn ->
      let req =
        Client.make_request
          ~method_:"POST"
          ~path:"/v1/chat/completions"
          ~headers:(("Host", "gw") :: headers)
          ~body
          ()
      in
      let res = Client.request_string conn req in
      Client.close conn;
      (
        match res with
        | Error e -> Error (Client.error_to_string e)
        | Ok (resp, body) -> Ok (resp.Client.status, body)
      )

let run_self_test = fun () ->
  println "===== Oasis Self-Test =====";
  (
    match Oasis.Mock.start () with
    | Error e -> Error ("mock a: " ^ e)
    | Ok mock_a -> (
        match Oasis.Mock.start () with
        | Error e -> Error ("mock b: " ^ e)
        | Ok mock_b ->
            let kb =
              [
                {
                  Oasis.Kb.name = "m-x";
                  tier = 3;
                  strengths = [ "general" ];
                  weaknesses = [];
                  context_window = 128000;
                  max_output = 8192;
                  latency = Oasis.Kb.Fast;
                  in_price_nano = 100;
                  out_price_nano = 200;
                  cache_hit_price_nano = 10;
                };
              ]
            in
            let mk_account name port =
              {
                Oasis.Config.name;
                provider = "selftest";
                protocol = "openai";
                thinking = "disabled";
                base_url = "http://127.0.0.1:" ^ Int.to_string port;
                api_key_env = None;
                models = [ "m-x" ];
                enabled = true;
                rpm = 0;
                tpm = 0;
                daily_limit = 0;
                monthly_budget_nano = 0;
                supports_prefill = true;
                quota_error_codes = [];
                quota_reset = "daily";
                stream_usage = false;
                connect_ip = "";
              }
            in
            let config =
              {
                Oasis.Config.server_host = "127.0.0.1";
                server_port = 0;
                data_dir = "./.oasis-selftest-data";
                auth_token_env = None;
                workspace_dir = "";
                agents = [];
                accounts = [ mk_account "mock_a" mock_a.pool.port; mk_account "mock_b" mock_b.pool.port ];
                kb;
                policy =
                  {
                    Oasis.Config.goal = "balanced";
                    routes = [ { Oasis.Config.category = "general"; accounts = [ "mock_a"; "mock_b" ] } ];
                    agent_categories = [ "coding" ];
                    max_fallback = 1;
                    max_handoffs = 2;
                    handoff_notice = true;
                    session_ttl_s = 600;
                    explore_every = 0;
                    judge = "";
                    judge_every = 10;
                  };
              }
            in
            (
              match Oasis.Gateway.start ~config_path:None ~config ~port:0 () with
              | Error e -> Error ("gateway: " ^ e)
              | Ok gw_pool -> (
                  let headers =
                    [ ("X-Oasis-Category", "general"); ("Content-Type", "application/json") ]
                  in
                  let body =
                    Json.obj
                      [
                        ("model", Json.string "m-x");
                        ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "hi") ] ]);
                        ("max_tokens", Json.int 64);
                        ("stream", Json.bool false);
                      ]
                    |> Json.to_string
                  in
                  (* S1: non-stream *)
                  Oasis.Mock.set_scenario mock_a { (Oasis.Mock.default_scenario) with body = "{\"choices\":[{\"message\":{\"content\":\"ok-a\"}}]}" };
                  (
                    match st_post ~port:gw_pool.port ~headers ~body with
                    | Error e -> Error ("s1: " ^ e)
                    | Ok (status, resp) ->
                        st_check ~label:"S1 非流式路由" ~actual:(Int.to_string status ^ ":" ^ resp) ~expected:("200:" ^ "{\"choices\":[{\"message\":{\"content\":\"ok-a\"}}]}");
                        (* S2: 429 fallback *)
                        Oasis.Mock.set_scenario mock_a { (Oasis.Mock.default_scenario) with status = 429; body = "{}" };
                        Oasis.Mock.set_scenario mock_b { (Oasis.Mock.default_scenario) with body = "{\"choices\":[{\"message\":{\"content\":\"ok-b\"}}]}" };
                        (
                          match st_post ~port:gw_pool.port ~headers ~body with
                          | Error e -> Error ("s2: " ^ e)
                          | Ok (status2, resp2) ->
                              st_check ~label:"S2 429 回退" ~actual:(Int.to_string status2 ^ ":" ^ resp2) ~expected:("200:" ^ "{\"choices\":[{\"message\":{\"content\":\"ok-b\"}}]}");
                              (* S3: stream happy *)
                              Oasis.Mock.set_scenario mock_a { (Oasis.Mock.default_scenario) with sse = [ "hello"; " stream" ] };
                              let stream_body =
                                Json.obj
                                  [
                                    ("model", Json.string "m-x");
                                    ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "hi") ] ]);
                                    ("max_tokens", Json.int 64);
                                    ("stream", Json.bool true);
                                  ]
                                |> Json.to_string
                              in
                              (
                                match st_collect_stream ~port:gw_pool.port ~headers ~body:stream_body with
                                | Error e -> Error ("s3: " ^ e)
                                | Ok (status3, events3) ->
                                    let contents =
                                      List.filter_map
                                        events3
                                        ~fn:(fun ev ->
                                          if ev.Sse.done_sentinel then None
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
                                              |> Option.unwrap_or ~default:""))
                                    in
                                    st_check ~label:"S3 SSE 流式" ~actual:(Int.to_string status3 ^ ":" ^ String.concat "" contents) ~expected:"200:hello stream";
                                    (* S4: seamless handoff *)
                                    let header_len = String.length (Oasis.Mock.stream_header 200) in
                                    let frame1 = Oasis.Mock.chunked_frame "data: ev1\n\n" in
                                    Oasis.Mock.set_scenario
                                      mock_a
                                      {
                                        (Oasis.Mock.default_scenario) with
                                        sse = [ "ev1"; "ev2"; "ev3" ];
                                        cut_after_bytes = header_len + String.length frame1 + 3;
                                      };
                                    Oasis.Mock.set_scenario mock_b { (Oasis.Mock.default_scenario) with sse = [ "ev1 ev2 ev3" ] };
                                    (
                                      match st_collect_stream ~port:gw_pool.port ~headers ~body:stream_body with
                                      | Error e -> Error ("s4: " ^ e)
                                      | Ok (status4, events4) ->
                                          let contents4 =
                                            List.filter_map
                                              events4
                                              ~fn:(fun ev ->
                                                if ev.Sse.done_sentinel then None
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
                                                    |> Option.unwrap_or ~default:""))
                                          in
                                          st_check ~label:"S4 中途断流+无缝切换(零重复)" ~actual:(Int.to_string status4 ^ ":" ^ String.concat "" contents4) ~expected:"200:ev1 ev2 ev3";
                                          println
                                            ("===== Self-Test 完成: "
                                            ^ Int.to_string !self_test_pass
                                            ^ " passed, "
                                            ^ Int.to_string !self_test_fail
                                            ^ " failed =====");
                                          if !self_test_fail = 0 then Ok () else Error "self-test failed"
                                    )
                              )
                        )
                  )
              )
            )
      )
  )

let main ~args =
  let config_path = ref "" in
  let server = ref default_server in
  let print_example = ref false in
  let self_test_only = ref false in
  let cli_args = ref [] in
  let rec parse = function
    | "--config" :: p :: rest ->
        config_path := p;
        parse rest
    | "--server" :: s :: rest ->
        server := s;
        parse rest
    | "--example-config" :: rest ->
        print_example := true;
        parse rest
    | "--self-test" :: rest ->
        self_test_only := true;
        parse rest
    | arg :: rest ->
        (* riot run passes the executable path as argv[0]; skip it *)
        if String.contains arg "/" then
          parse rest
        else (
          cli_args := !cli_args @ [ arg ];
          parse rest
        )
    | [] -> ()
  in
  parse args;
  if !print_example then (
    println example_config;
    Ok ()
  ) else if !self_test_only then (
    match run_self_test () with
    | Ok () -> Ok ()
    | Error e ->
        eprintln e;
        Error (Failure e)
  ) else if not (List.is_empty !cli_args) then (
    match cli_main ~server:!server ~args:!cli_args with
    | Ok () -> Ok ()
    | Error e ->
        eprintln e;
        Error (Failure e)
  ) else
    let config_path =
      if String.is_empty !config_path then (
        let p = Oasis.Config.default_config_path () in
        ensure_default_config p;
        p)
      else !config_path
    in
    match Oasis.Config.load config_path with
    | Error e ->
        eprintln ("Oasis 配置加载失败: " ^ e);
        Error (Failure e)
    | Ok config -> (
        match
          Oasis.Gateway.start
            ~config_path:(Some config_path)
            ~config
            ~port:config.Oasis.Config.server_port
            ()
        with
        | Error e ->
            eprintln ("Oasis 启动失败: " ^ e);
            Error (Failure e)
        | Ok pool ->
            banner config ~config_path pool;
            keep_alive ()
      )

let () = Runtime.run ~main ~args:Env.args ()
