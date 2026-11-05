open Std
open Std.Collections

(** Admin JSON endpoints under [/api]. *)

module Trail = Oasis_net.Trail
module Json = Std.Data.Json

open Oasis_state
open Oasis_ws
open Oasis_upstream
open Oasis_decisions
open Oasis_conductor
open Oasis_exec_agent
open Oasis_exec_account

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
      config.Oasis_config.kb
      ~fn:(fun m ->
        Json.obj
          [
            ("name", Json.string m.Oasis_kb.name);
            ("tier", Json.int m.Oasis_kb.tier);
            ("context_window", Json.int m.Oasis_kb.context_window);
            ("max_output", Json.int m.Oasis_kb.max_output);
            ("latency", Json.string (Oasis_kb.latency_to_string m.Oasis_kb.latency));
            (
              "strengths",
              Json.array (List.map m.Oasis_kb.strengths ~fn:Json.string)
            );
            (
              "weaknesses",
              Json.array (List.map m.Oasis_kb.weaknesses ~fn:Json.string)
            );
          ])
  in
  Trail.json ctx (Json.obj [ ("object", Json.string "list"); ("data", Json.array models) ])

let handle_list_accounts = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let accounts =
    List.map
      config.Oasis_config.accounts
      ~fn:(fun a ->
        let spent = Oasis_ledger.month_spent state.ledger a.Oasis_config.name in
        let budget = a.Oasis_config.monthly_budget_nano in
        let s = Oasis_signals.get state.signals a.Oasis_config.name in
        let breaker_str =
          match s.Oasis_signals.breaker with
          | Oasis_signals.Closed -> "closed"
          | Oasis_signals.Half_open -> "half_open"
          | Oasis_signals.Open_until _ -> "open"
        in
        Json.obj
          [
            ("name", Json.string a.Oasis_config.name);
            ("provider", Json.string a.Oasis_config.provider);
            ("base_url", Json.string a.Oasis_config.base_url);
            (
              "models",
              Json.array (List.map a.Oasis_config.models ~fn:Json.string)
            );
            ("enabled", Json.bool a.Oasis_config.enabled);
            ("day_requests", Json.int (Oasis_ledger.day_requests state.ledger a.Oasis_config.name));
            ("daily_limit", Json.int a.Oasis_config.daily_limit);
            ("month_spent_usd", Json.string (Oasis_ledger.format_usd spent));
            (
              "month_budget_usd",
              if budget > 0 then
                Json.string (Oasis_ledger.format_usd budget)
              else
                Json.string "unlimited"
            );
            ("latency_ema_ms", Json.int s.Oasis_signals.latency_ema_ms);
            ("total_requests", Json.int s.Oasis_signals.total_requests);
            ("in_flight", Json.int s.Oasis_signals.in_flight);
            ("breaker", Json.string breaker_str);
            ("requests_in_window", Json.int s.Oasis_signals.requests_in_window);
            (
              "parked_until_ms",
              if Oasis_signals.is_parked s (Oasis_signals.now_ms ()) then Json.int s.Oasis_signals.parked_until_ms
              else Json.null
            );
            ("auth_invalid", Json.bool s.Oasis_signals.auth_invalid);
            ("supports_prefill", Json.bool a.Oasis_config.supports_prefill);
            (
              "last_error",
              match s.Oasis_signals.last_error with Some e -> Json.string e | None -> Json.null
            );
          ])
  in
  Trail.json
    ctx
    (Json.obj
      [
        ("accounts", Json.array accounts);
        ("cost_routing_effective", Json.bool (Oasis_router.cost_routing_effective config));
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
        ("schema", Json.int Oasis_router.decision_schema);
        ("decisions", Json.array (decisions_json state ~limit));
      ])

let handle_list_ledger = fun (state : state) (ctx : Trail.ctx) ->
  let entries = Oasis_ledger.recent state.ledger ~len:100 in
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
                    ("seq", Json.int u.Oasis_ledger.seq);
                    ("account", Json.string u.Oasis_ledger.account);
                    ("model", Json.string u.Oasis_ledger.model);
                    ("in_tokens", Json.int u.Oasis_ledger.in_tokens);
                    ("out_tokens", Json.int u.Oasis_ledger.out_tokens);
                    ("cost_usd", Json.string (Oasis_ledger.format_usd u.Oasis_ledger.cost_nano));
                    ("latency_ms", Json.int u.Oasis_ledger.latency_ms);
                    ("status", Json.string u.Oasis_ledger.status);
                  ]))
        )
      ])

let discover_home = fun (state : state) ->
  let config = Sync.Atomic.get state.config in
  let from_agents =
    List.filter_map config.Oasis_config.agents ~fn:(fun a ->
      if String.is_empty a.Oasis_agent.home then None else Some a.Oasis_agent.home)
    |> List.head
  in
  match from_agents with
  | Some h -> h
  | None -> (
      match Env.var Env.String ~name:"REAL_HOME" with
      | Some h -> h
      | None -> Oasis_config.user_home ()
    )

let handle_list_agents = fun (state : state) (ctx : Trail.ctx) ->
  let home = discover_home state in
  let statuses = Oasis_discover.scan ~home in
  let config = Sync.Atomic.get state.config in
  let configured =
    List.map config.Oasis_config.agents ~fn:(fun a ->
      let s = Oasis_signals.get state.signals a.Oasis_agent.name in
      Json.obj
        [
          ("name", Json.string a.Oasis_agent.name);
          ("command", Json.string a.Oasis_agent.command);
          ("enabled", Json.bool a.Oasis_agent.enabled);
          ("tier", Json.int a.Oasis_agent.tier);
          ("strengths", Json.array (List.map a.Oasis_agent.strengths ~fn:Json.string));
          ("latency_ema_ms", Json.int s.Oasis_signals.latency_ema_ms);
          ("in_flight", Json.int s.Oasis_signals.in_flight);
          ("total_requests", Json.int s.Oasis_signals.total_requests);
          ("consecutive_failures", Json.int s.Oasis_signals.consecutive_failures);
          (
            "breaker",
            Json.string
              (match s.Oasis_signals.breaker with
               | Oasis_signals.Closed -> "closed"
               | Oasis_signals.Half_open -> "half_open"
               | Oasis_signals.Open_until _ -> "open")
          );
          ("last_error", match s.Oasis_signals.last_error with Some e -> Json.string e | None -> Json.null);
        ])
  in
  Trail.json
    ctx
    (Json.obj
      [
        ("agents", Json.array (List.map statuses ~fn:Oasis_discover.status_json));
        ("configured", Json.array configured);
      ])

let handle_list_feed = fun (state : state) (ctx : Trail.ctx) ->
  let limit =
    query_param ctx "limit" |> Option.and_then ~fn:Int.from_string_opt
    |> Option.unwrap_or ~default:100 |> max 1 |> min Oasis_feed.keep
  in
  Trail.json
    ctx
    (Json.obj
      [ ("tasks", Json.array (List.map (Oasis_feed.recent state.feed ~limit) ~fn:Oasis_feed.summary_json)) ])

let handle_feed_task = fun (state : state) (ctx : Trail.ctx) ->
  match query_param ctx "id" |> Option.and_then ~fn:(Oasis_feed.find state.feed) with
  | Some t -> Trail.json ctx (Oasis_feed.detail_json t)
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
    (Json.obj [ ("threads", Json.array (List.map (Oasis_thread.recent state.threads ~limit) ~fn:Oasis_thread.summary_json)) ])

(** GET /api/thread?id=: every turn of one conversation. *)
let handle_get_thread = fun (state : state) (ctx : Trail.ctx) ->
  match query_param ctx "id" |> Option.and_then ~fn:(Oasis_thread.get state.threads) with
  | Some th -> Trail.json ctx (Oasis_thread.to_json th)
  | None -> Trail.json ~status:Net.Http.Status.NotFound ctx (Json.obj [ ("error", Json.string "没有这个对话") ])

(** GET /api/workspace?id=: the files a task's agents produced. *)
let handle_workspace = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  match query_param ctx "id" with
  | Some id when Oasis_workspace.exists config ~id -> Trail.json ctx (Oasis_workspace.listing_json config ~id)
  | _ -> Trail.json ~status:Net.Http.Status.NotFound ctx (Json.obj [ ("error", Json.string "这个任务没有工作目录") ])

(** GET /api/workspace/file?id=&path=: one produced file (text, capped). *)
let handle_workspace_file = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  match (query_param ctx "id", query_param ctx "path") with
  | (Some id, Some path) -> (
      match Oasis_workspace.read_file config ~id ~path with
      | Ok j -> Trail.json ctx j
      | Error e -> Trail.json ~status:Net.Http.Status.NotFound ctx (Json.obj [ ("error", Json.string e) ]))
  | _ -> Trail.json ~status:Net.Http.Status.BadRequest ctx (Json.obj [ ("error", Json.string "缺少 id 或 path") ])

(** POST /api/thread/delete {"id": thread | "task": request id, "files": bool}:
    removes a conversation (or a thread-less task) from the feed and from
    threads.json; running turns are stopped first. With [files] its
    workspace directory goes too. *)
let handle_delete = fun (state : state) (ctx : Trail.ctx) ->
  let body = parse_json_body ctx in
  let config = Sync.Atomic.get state.config in
  let str k = Json.get_field k body |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:"" in
  let files = Json.get_field "files" body |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false in
  let thread_id = str "id" and task_id = str "task" in
  let tasks =
    if not (String.is_empty thread_id) then
      List.filter (ConcurrentHashMap.values state.feed) ~fn:(fun t -> String.equal t.Oasis_feed.thread thread_id)
    else Oasis_feed.find state.feed task_id |> Option.map ~fn:(fun t -> [ t ]) |> Option.unwrap_or ~default:[]
  in
  let thread = if String.is_empty thread_id then None else Oasis_thread.get state.threads thread_id in
  if List.is_empty tasks && Option.is_none thread then
    Trail.json ~status:Net.Http.Status.NotFound ctx (Json.obj [ ("error", Json.string "没有这个任务") ])
  else (
    let stopped =
      List.filter tasks ~fn:(fun t -> String.equal t.Oasis_feed.status "running")
      |> List.filter ~fn:(fun t -> cancel_task state ~request_id:t.Oasis_feed.id ~reason:"user")
      |> List.length
    in
    let ids = List.map tasks ~fn:(fun t -> t.Oasis_feed.id) in
    Oasis_feed.remove_where state.feed ~fn:(fun t -> List.any ids ~fn:(String.equal t.Oasis_feed.id));
    if Option.is_some thread then (
      ignore (Oasis_thread.remove state.threads ~id:thread_id);
      Oasis_thread.save state.threads ~path:(threads_file state));
    let workspaces =
      (match thread with Some th when not (String.is_empty th.Oasis_thread.workspace) -> [ th.Oasis_thread.workspace ] | _ -> [])
      @ List.filter_map tasks ~fn:(fun t -> if String.is_empty t.Oasis_feed.workspace then None else Some t.Oasis_feed.workspace)
      |> List.unique ~compare:String.compare
    in
    let removed = if files then List.filter workspaces ~fn:(fun id -> Oasis_workspace.remove config ~id) else [] in
    broadcast_event state ~type_:"thread_deleted" ~request_id:""
      ~data:(Json.obj [ ("thread", Json.string thread_id); ("tasks", Json.array (List.map ids ~fn:Json.string)) ]);
    Trail.json ctx
      (Json.obj
        [
          ("ok", Json.bool true);
          ("tasks", Json.int (List.length ids));
          ("stopped", Json.int stopped);
          ("workspaces_removed", Json.array (List.map removed ~fn:Json.string));
          ("workspaces_kept", Json.array (List.map (if files then [] else workspaces) ~fn:Json.string));
        ]))

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
  match Json.get_field "id" body |> Option.and_then ~fn:Json.get_string |> Option.and_then ~fn:(Oasis_feed.find state.feed) with
  | None -> Trail.json ~status:Net.Http.Status.NotFound ctx (Json.obj [ ("error", Json.string "unknown task") ])
  | Some t when not (String.equal t.Oasis_feed.status "ok") -> bad "only finished, successful tasks can be rated"
  | Some t when String.is_empty t.Oasis_feed.executor -> bad "task has no executor"
  | Some t ->
      let account = t.Oasis_feed.executor in
      let category = if String.is_empty t.Oasis_feed.category then "general" else t.Oasis_feed.category in
      if t.Oasis_feed.user_rating != 0 then
        Oasis_quality.unrecord state.quality ~account ~category ~score:(Oasis_quality.of_rating t.Oasis_feed.user_rating);
      if rating != 0 then Oasis_quality.record state.quality ~account ~category ~score:(Oasis_quality.of_rating rating);
      Oasis_quality.save state.quality ~path:(quality_file state);
      broadcast_event state ~type_:"task_rated" ~request_id:t.Oasis_feed.id
        ~data:(Json.obj [ ("by", Json.string "user"); ("rating", Json.int rating); ("executor", Json.string account) ]);
      let q = Oasis_quality.get state.quality ~account ~category in
      Trail.json ctx
        (Json.obj
          [
            ("ok", Json.bool true);
            ("rating", Json.int rating);
            ("executor", Json.string account);
            ("category", Json.string category);
            ("rated", Json.int q.Oasis_quality.n);
            ("mean", Json.int (Oasis_quality.mean q));
          ])

let handle_list_alerts = fun (state : state) (ctx : Trail.ctx) ->
  let alerts = Oasis_alerts.collect state ~home:(discover_home state) in
  Trail.json ctx (Json.obj [ ("alerts", Json.array (List.map alerts ~fn:Oasis_alerts.alert_json)) ])

let handle_reload = fun (state : state) (ctx : Trail.ctx) ->
  match state.config_path with
  | None ->
      Trail.json
        ~status:Net.Http.Status.BadRequest
        ctx
        (Json.obj [ ("error", Json.string "no config path (in-memory config)") ])
  | Some p -> (
      match Oasis_config.load p with
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
                ("accounts", Json.int (List.length config.Oasis_config.accounts));
              ])
    )

let handle_list_inbox = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let agent_names =
    List.map config.Oasis_config.agents ~fn:(fun a -> a.Oasis_agent.name)
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
                  ("unread", Json.int (Oasis_inbox.pending_count state.inbox ~agent:name));
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
        match Oasis_inbox.deliver state.inbox ~from:"user" ~to_agent ~text with
        | Ok id -> Trail.json ctx (Json.obj [ ("delivered", Json.string id) ])
        | Error e -> Trail.json ~status:Net.Http.Status.BadRequest ctx (Json.obj [ ("error", Json.string e) ])
      )
  | _ ->
      Trail.json
        ~status:Net.Http.Status.BadRequest
        ctx
        (Json.obj [ ("error", Json.string "to_agent and text required") ])
