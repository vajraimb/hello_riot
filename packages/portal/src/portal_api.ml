open Std
open Std.Collections

(** Admin JSON endpoints under [/api]. *)

module Trail = Hello_riot.Trail
module Json = Std.Data.Json

open Portal_state
open Portal_ws
open Portal_upstream
open Portal_decisions
open Portal_conductor
open Portal_exec_agent
open Portal_exec_account

let handle_list_requests = fun (state : state) (ctx : Trail.ctx) ->
  let path = audit_file state in
  match Fs.read_to_string (Path.from_string path |> Result.unwrap) with
  | Error _ -> Trail.json ctx (Json.obj [ ("requests", Json.array []) ])
  | Ok content ->
      let lines = String.split ~by:"\n" content in
      let items =
        List.filter_map lines ~fn:(fun l ->
          if String.is_empty l then None
          else Json.from_string l |> Result.to_option)
        |> List.rev |> List.take ~len:50
      in
      Trail.json ctx (Json.obj [ ("requests", Json.array items) ])


(* ---------- admin handlers ---------- *)

let handle_list_models = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let models =
    List.map
      config.Portal_config.kb
      ~fn:(fun m ->
        Json.obj
          [
            ("name", Json.string m.Portal_kb.name);
            ("tier", Json.int m.Portal_kb.tier);
            ("context_window", Json.int m.Portal_kb.context_window);
            ("max_output", Json.int m.Portal_kb.max_output);
            ("latency", Json.string (Portal_kb.latency_to_string m.Portal_kb.latency));
            (
              "strengths",
              Json.array (List.map m.Portal_kb.strengths ~fn:Json.string)
            );
            (
              "weaknesses",
              Json.array (List.map m.Portal_kb.weaknesses ~fn:Json.string)
            );
          ])
  in
  Trail.json ctx (Json.obj [ ("object", Json.string "list"); ("data", Json.array models) ])

let handle_list_accounts = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let accounts =
    List.map
      config.Portal_config.accounts
      ~fn:(fun a ->
        let spent = Portal_ledger.month_spent state.ledger a.Portal_config.name in
        let budget = a.Portal_config.monthly_budget_nano in
        let s = Portal_signals.get state.signals a.Portal_config.name in
        let breaker_str =
          match s.Portal_signals.breaker with
          | Portal_signals.Closed -> "closed"
          | Portal_signals.Half_open -> "half_open"
          | Portal_signals.Open_until _ -> "open"
        in
        Json.obj
          [
            ("name", Json.string a.Portal_config.name);
            ("provider", Json.string a.Portal_config.provider);
            ("base_url", Json.string a.Portal_config.base_url);
            (
              "models",
              Json.array (List.map a.Portal_config.models ~fn:Json.string)
            );
            ("enabled", Json.bool a.Portal_config.enabled);
            ("day_requests", Json.int (Portal_ledger.day_requests state.ledger a.Portal_config.name));
            ("daily_limit", Json.int a.Portal_config.daily_limit);
            ("month_spent_usd", Json.string (Portal_ledger.format_usd spent));
            (
              "month_budget_usd",
              if budget > 0 then
                Json.string (Portal_ledger.format_usd budget)
              else
                Json.string "unlimited"
            );
            ("latency_ema_ms", Json.int s.Portal_signals.latency_ema_ms);
            ("total_requests", Json.int s.Portal_signals.total_requests);
            ("in_flight", Json.int s.Portal_signals.in_flight);
            ("breaker", Json.string breaker_str);
            ("requests_in_window", Json.int s.Portal_signals.requests_in_window);
            (
              "parked_until_ms",
              if Portal_signals.is_parked s (Portal_signals.now_ms ()) then Json.int s.Portal_signals.parked_until_ms
              else Json.null
            );
            ("auth_invalid", Json.bool s.Portal_signals.auth_invalid);
            ("supports_prefill", Json.bool a.Portal_config.supports_prefill);
            (
              "last_error",
              match s.Portal_signals.last_error with Some e -> Json.string e | None -> Json.null
            );
          ])
  in
  Trail.json
    ctx
    (Json.obj
      [
        ("accounts", Json.array accounts);
        ("cost_routing_effective", Json.bool (Portal_router.cost_routing_effective config));
      ])

let handle_list_decisions = fun (state : state) (ctx : Trail.ctx) ->
  let limit =
    query_param ctx "limit" |> Option.and_then ~fn:Int.from_string_opt
    |> Option.unwrap_or ~default:200 |> max 1 |> min decisions_keep
  in
  Trail.json
    ctx
    (Json.obj
      [
        ("schema", Json.int Portal_router.decision_schema);
        ("decisions", Json.array (decisions_json state ~limit));
      ])

let handle_list_ledger = fun (state : state) (ctx : Trail.ctx) ->
  let entries = Portal_ledger.recent state.ledger ~len:100 in
  Trail.json
    ctx
    (Json.obj
      [
        (
          "entries",
          Json.array
            (List.map
              entries
              ~fn:(fun u ->
                Json.obj
                  [
                    ("seq", Json.int u.Portal_ledger.seq);
                    ("account", Json.string u.Portal_ledger.account);
                    ("model", Json.string u.Portal_ledger.model);
                    ("in_tokens", Json.int u.Portal_ledger.in_tokens);
                    ("out_tokens", Json.int u.Portal_ledger.out_tokens);
                    ("cost_usd", Json.string (Portal_ledger.format_usd u.Portal_ledger.cost_nano));
                    ("latency_ms", Json.int u.Portal_ledger.latency_ms);
                    ("status", Json.string u.Portal_ledger.status);
                  ]))
        )
      ])

let discover_home = fun (state : state) ->
  let config = Sync.Atomic.get state.config in
  let from_agents =
    List.filter_map config.Portal_config.agents ~fn:(fun a ->
      if String.is_empty a.Portal_agent.home then None else Some a.Portal_agent.home)
    |> List.head
  in
  match from_agents with
  | Some h -> h
  | None -> (
      match Env.var Env.String ~name:"REAL_HOME" with
      | Some h -> h
      | None -> "/Users/vajra"
    )

let handle_list_agents = fun (state : state) (ctx : Trail.ctx) ->
  let home = discover_home state in
  let statuses = Portal_discover.scan ~home in
  let config = Sync.Atomic.get state.config in
  let configured =
    List.map config.Portal_config.agents ~fn:(fun a ->
      let s = Portal_signals.get state.signals a.Portal_agent.name in
      Json.obj
        [
          ("name", Json.string a.Portal_agent.name);
          ("command", Json.string a.Portal_agent.command);
          ("enabled", Json.bool a.Portal_agent.enabled);
          ("tier", Json.int a.Portal_agent.tier);
          ("strengths", Json.array (List.map a.Portal_agent.strengths ~fn:Json.string));
          ("latency_ema_ms", Json.int s.Portal_signals.latency_ema_ms);
          ("in_flight", Json.int s.Portal_signals.in_flight);
          ("total_requests", Json.int s.Portal_signals.total_requests);
          ("consecutive_failures", Json.int s.Portal_signals.consecutive_failures);
          (
            "breaker",
            Json.string
              (match s.Portal_signals.breaker with
               | Portal_signals.Closed -> "closed"
               | Portal_signals.Half_open -> "half_open"
               | Portal_signals.Open_until _ -> "open")
          );
          ("last_error", match s.Portal_signals.last_error with Some e -> Json.string e | None -> Json.null);
        ])
  in
  Trail.json
    ctx
    (Json.obj
      [
        ("agents", Json.array (List.map statuses ~fn:Portal_discover.status_json));
        ("configured", Json.array configured);
      ])

let handle_list_feed = fun (state : state) (ctx : Trail.ctx) ->
  let limit =
    query_param ctx "limit" |> Option.and_then ~fn:Int.from_string_opt
    |> Option.unwrap_or ~default:100 |> max 1 |> min Portal_feed.keep
  in
  Trail.json
    ctx
    (Json.obj
      [ ("tasks", Json.array (List.map (Portal_feed.recent state.feed ~limit) ~fn:Portal_feed.summary_json)) ])

let handle_feed_task = fun (state : state) (ctx : Trail.ctx) ->
  match query_param ctx "id" |> Option.and_then ~fn:(Portal_feed.find state.feed) with
  | Some t -> Trail.json ctx (Portal_feed.detail_json t)
  | None ->
      Trail.json
        ~status:Net.Http.Status.NotFound
        ctx
        (Json.obj [ ("error", Json.string "unknown task (the feed keeps the newest tasks in memory only)") ])

(** POST {"id", "rating": 1 | -1 | 0}: the user's verdict on a finished task
    feeds the executor's learned quality for that category (0 withdraws). *)
(** GET /api/threads?limit=: recent conversations, newest first. *)
let handle_list_threads = fun (state : state) (ctx : Trail.ctx) ->
  let limit = query_param ctx "limit" |> Option.and_then ~fn:Int.from_string_opt |> Option.unwrap_or ~default:50 in
  Trail.json ctx
    (Json.obj [ ("threads", Json.array (List.map (Portal_thread.recent state.threads ~limit) ~fn:Portal_thread.summary_json)) ])

(** GET /api/thread?id=: every turn of one conversation. *)
let handle_get_thread = fun (state : state) (ctx : Trail.ctx) ->
  match query_param ctx "id" |> Option.and_then ~fn:(Portal_thread.get state.threads) with
  | Some th -> Trail.json ctx (Portal_thread.to_json th)
  | None -> Trail.json ~status:Net.Http.Status.NotFound ctx (Json.obj [ ("error", Json.string "没有这个对话") ])

(** POST /api/feed/cancel {"id"}: stops a running task (kills the agent
    process / drops the upstream wait); no failover, no health penalty. *)
let handle_cancel_task = fun (state : state) (ctx : Trail.ctx) ->
  let body = parse_json_body ctx in
  match Json.get_field "id" body |> Option.and_then ~fn:Json.get_string with
  | None -> Trail.json ~status:Net.Http.Status.BadRequest ctx (Json.obj [ ("error", Json.string "缺少 id") ])
  | Some id ->
      if cancel_task state ~request_id:id ~reason:"user" then Trail.json ctx (Json.obj [ ("ok", Json.bool true) ])
      else
        Trail.json ~status:Net.Http.Status.NotFound ctx
          (Json.obj [ ("error", Json.string "这个任务已经结束，或不是由本网关执行的") ])

let handle_rate_task = fun (state : state) (ctx : Trail.ctx) ->
  let body = parse_json_body ctx in
  let rating = Json.get_field "rating" body |> Option.and_then ~fn:Json.get_int |> Option.unwrap_or ~default:0 in
  let rating = if rating > 0 then 1 else if rating < 0 then -1 else 0 in
  let bad msg = Trail.json ~status:Net.Http.Status.BadRequest ctx (Json.obj [ ("error", Json.string msg) ]) in
  match Json.get_field "id" body |> Option.and_then ~fn:Json.get_string |> Option.and_then ~fn:(Portal_feed.find state.feed) with
  | None -> Trail.json ~status:Net.Http.Status.NotFound ctx (Json.obj [ ("error", Json.string "unknown task") ])
  | Some t when not (String.equal t.Portal_feed.status "ok") -> bad "only finished, successful tasks can be rated"
  | Some t when String.is_empty t.Portal_feed.executor -> bad "task has no executor"
  | Some t ->
      let account = t.Portal_feed.executor in
      let category = if String.is_empty t.Portal_feed.category then "general" else t.Portal_feed.category in
      if t.Portal_feed.user_rating != 0 then
        Portal_quality.unrecord state.quality ~account ~category ~score:(Portal_quality.of_rating t.Portal_feed.user_rating);
      if rating != 0 then Portal_quality.record state.quality ~account ~category ~score:(Portal_quality.of_rating rating);
      Portal_quality.save state.quality ~path:(quality_file state);
      broadcast_event state ~type_:"task_rated" ~request_id:t.Portal_feed.id
        ~data:(Json.obj [ ("by", Json.string "user"); ("rating", Json.int rating); ("executor", Json.string account) ]);
      let q = Portal_quality.get state.quality ~account ~category in
      Trail.json ctx
        (Json.obj
          [
            ("ok", Json.bool true);
            ("rating", Json.int rating);
            ("executor", Json.string account);
            ("category", Json.string category);
            ("rated", Json.int q.Portal_quality.n);
            ("mean", Json.int (Portal_quality.mean q));
          ])

let handle_list_alerts = fun (state : state) (ctx : Trail.ctx) ->
  let alerts = Portal_alerts.collect state ~home:(discover_home state) in
  Trail.json ctx (Json.obj [ ("alerts", Json.array (List.map alerts ~fn:Portal_alerts.alert_json)) ])

let handle_reload = fun (state : state) (ctx : Trail.ctx) ->
  match state.config_path with
  | None ->
      Trail.json
        ~status:Net.Http.Status.BadRequest
        ctx
        (Json.obj [ ("error", Json.string "no config path (in-memory config)") ])
  | Some p -> (
      match Portal_config.load p with
      | Error e ->
          Trail.json
            ~status:Net.Http.Status.BadRequest
            ctx
            (Json.obj [ ("error", Json.string e) ])
      | Ok config ->
          let _ = Sync.Atomic.set state.config config in
          Trail.json
            ctx
            (Json.obj
              [
                ("status", Json.string "reloaded");
                ("accounts", Json.int (List.length config.Portal_config.accounts));
              ])
    )

let handle_list_inbox = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let agent_names =
    List.map config.Portal_config.agents ~fn:(fun a -> a.Portal_agent.name)
    @ [ "user" ]
  in
  Trail.json
    ctx
    (Json.obj
      [
        (
          "inboxes",
          Json.array
            (List.map agent_names ~fn:(fun name ->
              Json.obj
                [
                  ("agent", Json.string name);
                  ("unread", Json.int (Portal_inbox.pending_count state.inbox ~agent:name));
                ]))
        );
      ])

let handle_inbox_reply = fun (state : state) (ctx : Trail.ctx) ->
  let body = parse_json_body ctx in
  match
    ( Json.get_field "to_agent" body |> Option.and_then ~fn:Json.get_string,
      Json.get_field "text" body |> Option.and_then ~fn:Json.get_string )
  with
  | (Some to_agent, Some text) ->
      (
        match Portal_inbox.deliver state.inbox ~from:"user" ~to_agent ~text with
        | Ok id -> Trail.json ctx (Json.obj [ ("delivered", Json.string id) ])
        | Error e -> Trail.json ~status:Net.Http.Status.BadRequest ctx (Json.obj [ ("error", Json.string e) ])
      )
  | _ ->
      Trail.json
        ~status:Net.Http.Status.BadRequest
        ctx
        (Json.obj [ ("error", Json.string "to_agent and text required") ])
