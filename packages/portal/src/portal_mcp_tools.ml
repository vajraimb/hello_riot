open Std
open Std.Collections

(** MCP tools ([oasis_ask], [oasis_agent_task], inbox, status…) and the
    [/mcp] JSON-RPC endpoint. *)

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

let mcp_get_str = fun (params : Json.t) key ->
  Json.get_field key params |> Option.and_then ~fn:Json.get_string
let mcp_get_int = fun (params : Json.t) key ->
  Json.get_field key params |> Option.and_then ~fn:Json.get_int
let mcp_extract_text = fun (body : string) ->
  match Json.from_string body with
  | Error _ -> body
  | Ok j -> (
      let content =
        Json.get_field "choices" j
        |> Option.and_then ~fn:Json.get_array
        |> Option.and_then ~fn:List.head
        |> Option.and_then ~fn:(fun ch -> Json.get_field "message" ch)
        |> Option.and_then ~fn:(fun m -> Json.get_field "content" m)
        |> Option.and_then ~fn:Json.get_string
      in
      match content with
      | Some t when not (String.is_empty t) -> t
      | _ -> (
          match Json.get_field "error" j |> Option.and_then ~fn:Json.get_string with
          | Some e -> "error: " ^ e
          | None -> body
        )
    )
let mcp_tool_agents = fun (state : state) ->
  let home = discover_home state in
  let statuses = Portal_discover.scan ~home in
  let lines =
    List.map statuses ~fn:(fun s ->
      let activity =
        match s.Portal_discover.last_activity_s with
        | None -> "no activity"
        | Some t ->
            "last " ^ Int.to_string (int_of_float ((Time.SystemTime.now () |> Time.SystemTime.secs_float) -. t)) ^ "s ago"
      in
      let projects =
        if List.is_empty s.Portal_discover.projects then ""
        else " projects=[" ^ String.concat ", " s.Portal_discover.projects ^ "]"
      in
      s.Portal_discover.name
      ^ ": installed=" ^ (if s.Portal_discover.installed then "yes" else "no")
      ^ " logged_in=" ^ (if s.Portal_discover.logged_in then "yes" else "no")
      ^ " active=" ^ (if s.Portal_discover.active then "yes" else "no")
      ^ " " ^ activity ^ projects)
  in
  Ok (String.concat "\n" lines)

let portal_task_summaries = fun (state : state) ->
  (* agent tasks the portal itself dispatched (not in claude's local session
     files): surface them in the activity timeline too *)
  recent_decisions state
  |> List.take ~len:50
  |> List.filter ~fn:(fun d ->
    (not (List.is_empty d.Portal_router.attempts))
    && (match List.head d.Portal_router.attempts with
        | Some a -> Option.is_some a.Portal_router.status
        | None -> false))
  |> List.filter_map ~fn:(fun d ->
    match d.Portal_router.attempts with
    | attempt :: _ -> (
        match attempt.Portal_router.status with
        | Some 200 when not (String.is_empty attempt.Portal_router.model) ->
            Some
              {
                Portal_activity.project = "portal-agent-task";
                session_id = "portal-" ^ Int.to_string attempt.Portal_router.latency_ms;
                last_ts = 0.0;
                turns = 1;
                tools = 0;
                last_excerpt =
                  "agent " ^ attempt.Portal_router.account ^ " 完成任务 ("
                  ^ Int.to_string attempt.Portal_router.latency_ms ^ "ms)";
              }
        | _ -> None
      )
    | _ -> None
  )

let handle_list_activity = fun (state : state) (ctx : Trail.ctx) ->
  let home = discover_home state in
  let limit = 20 in
  let query = None in
  let summaries =
    Portal_activity.scan ~home ~limit @ portal_task_summaries state
  in
  let summaries =
    match query with
    | None -> summaries
    | Some q ->
        List.filter summaries ~fn:(fun s ->
          String.contains s.Portal_activity.last_excerpt q
          || String.contains s.Portal_activity.project q)
  in
  Trail.json
    ctx
    (Json.obj
      [ ("sessions", Json.array (List.map summaries ~fn:Portal_activity.summary_json)) ])
let mcp_tool_models = fun (state : state) ->
  let config = Sync.Atomic.get state.config in
  let model_lines =
    List.map config.Portal_config.kb ~fn:(fun m ->
      "model " ^ m.Portal_kb.name
      ^ ": tier=" ^ Int.to_string m.Portal_kb.tier
      ^ " ctx=" ^ Int.to_string m.Portal_kb.context_window
      ^ " out=" ^ Int.to_string m.Portal_kb.max_output
      ^ " latency="
      ^ (match m.Portal_kb.latency with
        | Portal_kb.Fast -> "fast"
        | Portal_kb.Medium -> "medium"
        | Portal_kb.Slow -> "slow")
      ^ " strengths=[" ^ String.concat "," m.Portal_kb.strengths ^ "]")
  in
  let agent_lines =
    List.map config.Portal_config.agents ~fn:(fun a ->
      "agent " ^ a.Portal_agent.name
      ^ ": tier=" ^ Int.to_string a.Portal_agent.tier
      ^ " capabilities=[" ^ String.concat "," a.Portal_agent.capabilities ^ "]"
      ^ " strengths=[" ^ String.concat "," a.Portal_agent.strengths ^ "]"
      ^ " timeout=" ^ Int.to_string a.Portal_agent.timeout_s ^ "s")
  in
  Ok (String.concat "\n" (model_lines @ agent_lines))
let mcp_tool_activity = fun (state : state) (params : Json.t) ->
  let home = discover_home state in
  let limit = mcp_get_int params "limit" |> Option.unwrap_or ~default:10 in
  let query = mcp_get_str params "query" in
  let summaries =
    Portal_activity.scan ~home ~limit:(max 1 limit) @ portal_task_summaries state
  in
  let summaries =
    match query with
    | None -> summaries
    | Some q ->
        List.filter summaries ~fn:(fun s ->
          String.contains s.Portal_activity.last_excerpt q
          || String.contains s.Portal_activity.project q)
  in
  if List.is_empty summaries then
    Ok "no recent agent activity found"
  else
    Ok
      (List.map summaries ~fn:(fun s ->
        "[" ^ s.Portal_activity.project ^ "] turns=" ^ Int.to_string s.Portal_activity.turns
        ^ " tools=" ^ Int.to_string s.Portal_activity.tools
        ^ "\n   最新: " ^ s.Portal_activity.last_excerpt)
      |> String.concat "\n")
let mcp_tool_ask = fun (state : state) (params : Json.t) ->
  match mcp_get_str params "prompt" with
  | None -> Error "missing required parameter: prompt"
  | Some prompt ->
      let config = Sync.Atomic.get state.config in
      let category =
        match mcp_get_str params "category" with
        | Some c when not (String.is_empty c || String.equal c "auto") -> c
        | _ ->
            let c, _ = Portal_classify.classify prompt in
            c
      in
      let goal =
        mcp_get_str params "goal"
        |> Option.unwrap_or ~default:config.Portal_config.policy.Portal_config.goal
      in
      let model = mcp_get_str params "model" in
      let max_tokens = mcp_get_int params "max_tokens" in
      let task =
        { Portal_router.model; category; est_in_tokens = 0; est_out_tokens = max_tokens |> Option.unwrap_or ~default:1024 }
      in
      let request_id = new_request_id () in
      broadcast_event
        state
        ~type_:"task_started"
        ~request_id
        ~data:
          (Json.obj
            [
              ("category", Json.string category);
              ("goal", Json.string goal);
              ("title", Json.string (Portal_feed.title_of_text prompt));
              ("prompt", Json.string (Portal_steps.clip prompt 8000));
              ("source", Json.string "mcp");
              ("mode", Json.string "account");
            ]);
      let decision =
        Portal_router.route_scored
          config
          (make_lookups state)
          ~goal:(Portal_router.goal_of_string goal)
          task
        |> maybe_explore state
      in
      emit_routed state ~request_id ~mode:"account" decision;
      let candidates =
        match decision.Portal_router.chosen with
        | None -> []
        | Some c -> c :: decision.Portal_router.fallback_order
      in
      if List.is_empty candidates then (
        record_decision state decision;
        emit_task_done ~error:"没有可用的账户（见路由说明里的排除原因）" state ~request_id ~chosen:None ~attempts:0 ~ok:false;
        let rejs : Portal_router.rejected list = decision.Portal_router.rejected in
        Error
          ("no_account_available: "
          ^ (List.map rejs ~fn:(fun r -> r.Portal_router.account ^ "(" ^ r.Portal_router.reason ^ ")")
            |> String.concat ", "))
      ) else
        let messages =
          Json.array
            [
              Json.obj
                [ ("role", Json.string "user"); ("content", Json.string prompt) ]
            ]
        in
        let r =
          execute_chat_sync
            state
            config
            ~decision
            ~candidates
            ~model
            ~messages
            ~max_tokens
            ~session:None
            ~request_id
            ()
        in
        let chosen =
          r.cst_decision.Portal_router.chosen |> Option.unwrap_or ~default:"?"
        in
        Ok
          (mcp_extract_text r.cst_body
          ^ "\n\n[routed via " ^ chosen ^ "]")
let mcp_tool_agent = fun (state : state) (params : Json.t) ->
  match mcp_get_str params "prompt" with
  | None -> Error "missing required parameter: prompt"
  | Some prompt ->
      let config = Sync.Atomic.get state.config in
      let category =
        mcp_get_str params "category" |> Option.unwrap_or ~default:"coding"
      in
      let mode = mcp_get_str params "mode" |> Option.unwrap_or ~default:"async" in
      let timeout_override = mcp_get_int params "timeout_s" in
      let requested_workdir = mcp_get_str params "workdir" in
      let with_overrides (agent : Portal_agent.agent) =
        match Portal_agent.resolve_workdir agent requested_workdir with
        | Error e -> Error e
        | Ok workdir ->
            let agent = { agent with Portal_agent.workdir } in
            Ok
              (match timeout_override with
               | Some t -> { agent with Portal_agent.timeout_s = t }
               | None -> agent)
      in
      let decision = route_agents state config category None in
      let forced = mcp_get_str params "agent" in
      let candidates =
        match forced with
        | Some a -> (
            match decision.Portal_router.chosen with
            | None -> [ a ]
            | Some c ->
                let rest =
                  List.filter (c :: decision.Portal_router.fallback_order)
                    ~fn:(fun n -> not (String.equal n a))
                in
                a :: rest
          )
        | None -> (
            match decision.Portal_router.chosen with
            | None -> []
            | Some c -> c :: decision.Portal_router.fallback_order
          )
      in
      if List.is_empty candidates then
        Error "no_agent_available"
      else
        let request_id = new_request_id () in
        broadcast_event
          state
          ~type_:"task_started"
          ~request_id
          ~data:
            (Json.obj
              [
                ("category", Json.string category);
                ("goal", Json.string "-");
                ("title", Json.string (Portal_feed.title_of_text prompt));
                ("prompt", Json.string (Portal_steps.clip prompt 8000));
                ("source", Json.string "mcp");
                ("mode", Json.string "agent");
                ("stream", Json.bool false);
              ]);
        emit_routed state ~request_id ~mode:"agent" { decision with Portal_router.chosen = List.head candidates };
        let observe nm (agent : Portal_agent.agent) =
          emit_attempt_started state ~request_id ~account:nm;
          agent_step_observer state ~request_id ~agent:nm ~command:agent.Portal_agent.command
        in
        let finished nm ~latency_ms result =
          emit_attempt_finished
            state
            ~request_id
            ~account:nm
            ~status:(match result with Ok _ -> Some 200 | Error _ -> None)
            ~error:(match result with Ok _ -> None | Error e -> Some e)
            ~latency_ms;
          match result with
          | Ok _ -> emit_task_done state ~request_id ~chosen:(Some nm) ~attempts:1 ~ok:true
          | Error _ -> ()
        in
        let rec run_sync acc = function
          | [] ->
              let decision' =
                { decision with Portal_router.attempts = List.rev acc }
              in
              record_decision state decision';
              emit_task_done
                ~error:(match acc with a :: _ -> "所有 agent 都失败了，最后一个：" ^ (a.Portal_router.error |> Option.unwrap_or ~default:"?") | [] -> "")
                state ~request_id ~chosen:None ~attempts:(List.length acc) ~ok:false;
              Error
                ("all_agents_failed: "
                ^ (List.rev acc
                  |> List.map ~fn:(fun a ->
                    a.Portal_router.account ^ ": "
                    ^ (a.Portal_router.error |> Option.unwrap_or ~default:"?"))
                  |> String.concat "; "))
          | nm :: rest -> (
              match find_agent config nm with
              | None ->
                  run_sync
                    ({
                       Portal_router.account = nm;
                       model = nm;
                       status = None;
                       error = Some "unknown_agent";
                       latency_ms = 0;
                       cost_nano = 0;
                     }
                    :: acc)
                    rest
              | Some agent0 -> (
                  match with_overrides agent0 with
                  | Error e ->
                      run_sync
                        ({
                           Portal_router.account = nm;
                           model = nm;
                           status = None;
                           error = Some e;
                           latency_ms = 0;
                           cost_nano = 0;
                         }
                        :: acc)
                        rest
                  | Ok agent ->
                  let model_for =
                    List.head agent.Portal_agent.models
                    |> Option.unwrap_or ~default:""
                  in
                  let _ =
                    Portal_signals.update state.signals nm ~fn:Portal_signals.mark_in_flight
                  in
                  let t0 = Time.Instant.now () in
                  let on_line = observe nm agent in
                  let result = blocking_agent_call ~on_line ~agent ~model:model_for ~prompt in
                  let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed t0) in
                  finished nm ~latency_ms result;
                  (
                    match result with
                    | Ok text ->
                        let _ =
                          Portal_signals.update state.signals nm ~fn:(fun s ->
                            Portal_signals.record_success
                              s
                              ~latency_ms
                              ~tokens:(String.length text / 4)
                              (Portal_signals.now_ms ()))
                        in
                        let attempt =
                          {
                            Portal_router.account = nm;
                            model = nm;
                            status = Some 200;
                            error = None;
                            latency_ms;
                            cost_nano = 0;
                          }
                        in
                        let decision' =
                          {
                            decision with
                            Portal_router.chosen = Some nm;
                            Portal_router.attempts = List.rev (attempt :: acc);
                          }
                        in
                        record_decision state decision';
                        Ok (text ^ "\n\n[agent: " ^ nm ^ "]")
                    | Error err ->
                        let _ =
                          Portal_signals.update state.signals nm ~fn:(fun s ->
                            Portal_signals.record_failure s ~error:err (Portal_signals.now_ms ()))
                        in
                        run_sync
                          ({
                             Portal_router.account = nm;
                             model = nm;
                             status = None;
                             error = Some err;
                             latency_ms;
                             cost_nano = 0;
                           }
                          :: acc)
                          rest
                  )
                )
            )
        in
        if String.equal mode "sync" then
          run_sync [] candidates
        else
          (* async: start the first candidate in the background and return a task_id *)
          let nm = List.head candidates |> Option.unwrap_or ~default:"" in
          (
            match find_agent config nm with
            | None ->
                emit_task_done ~error:"no_agent_available" state ~request_id ~chosen:None ~attempts:0 ~ok:false;
                Error "no_agent_available"
            | Some agent0 ->
                match with_overrides agent0 with
                | Error e ->
                    emit_task_done ~error:e state ~request_id ~chosen:None ~attempts:0 ~ok:false;
                    Error e
                | Ok agent ->
                let task_id = Portal_task.new_id () in
                let _ = Portal_task.insert state.tasks ~task_id in
                let model_for =
                  List.head agent.Portal_agent.models
                  |> Option.unwrap_or ~default:""
                in
                let _ =
                  Portal_signals.update state.signals nm ~fn:Portal_signals.mark_in_flight
                in
                let _ =
                  Runtime.spawn_blocked (fun () ->
                    let t0 = Time.Instant.now () in
                    let on_line = observe nm agent in
                    let result = Portal_agent.collect ~on_line ~agent ~model:model_for ~prompt () in
                    let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed t0) in
                    finished nm ~latency_ms result;
                    (match result with
                     | Error e -> emit_task_done ~error:e state ~request_id ~chosen:None ~attempts:1 ~ok:false
                     | Ok _ -> ());
                    (
                      match result with
                      | Ok text ->
                          let _ =
                            Portal_signals.update state.signals nm ~fn:(fun s ->
                              Portal_signals.record_success
                                s
                                ~latency_ms
                                ~tokens:(String.length text / 4)
                                (Portal_signals.now_ms ()))
                          in
                          let attempt =
                            {
                              Portal_router.account = nm;
                              model = nm;
                              status = Some 200;
                              error = None;
                              latency_ms;
                              cost_nano = 0;
                            }
                          in
                          let decision' =
                            {
                              decision with
                              Portal_router.chosen = Some nm;
                              Portal_router.attempts = [ attempt ];
                            }
                          in
                          record_decision state decision';
                          Portal_task.set state.tasks ~task_id ~status:(Portal_task.Done (text ^ "\n\n[agent: " ^ nm ^ "]"))
                      | Error err ->
                          let _ =
                            Portal_signals.update state.signals nm ~fn:(fun s ->
                              Portal_signals.record_failure s ~error:err (Portal_signals.now_ms ()))
                          in
                          let attempt =
                            {
                              Portal_router.account = nm;
                              model = nm;
                              status = None;
                              error = Some err;
                              latency_ms;
                              cost_nano = 0;
                            }
                          in
                          let decision' =
                            { decision with Portal_router.attempts = [ attempt ] }
                          in
                          record_decision state decision';
                          Portal_task.set state.tasks ~task_id ~status:(Portal_task.Failed err)
                    );
                    Ok ())
                in
                Ok
                  ("task started: " ^ task_id
                  ^ " (agent: " ^ nm ^ "). Poll oasis_task_status with this task_id for the result.")
          )
let mcp_tool_task_status = fun (state : state) (params : Json.t) ->
  match mcp_get_str params "task_id" with
  | None -> Error "missing required parameter: task_id"
  | Some task_id -> (
      match Portal_task.get state.tasks ~task_id with
      | None ->
          Ok
            ("unknown: no task " ^ task_id
            ^ " on this gateway (task handles are in-memory and do not survive a restart); resubmit if you still need the result")
      | Some (Portal_task.Running) ->
          Ok ("running (agent still working); poll again in a few seconds")
      | Some (Portal_task.Done text) -> Ok text
      | Some (Portal_task.Failed err) -> Ok ("failed: " ^ err)
    )
let mcp_tool_send_message = fun (state : state) (params : Json.t) ->
  match (mcp_get_str params "to", mcp_get_str params "text") with
  | (None, _) -> Error "missing required parameter: to"
  | (_, None) -> Error "missing required parameter: text"
  | (Some to_agent, Some text) ->
      let from =
        mcp_get_str params "from" |> Option.unwrap_or ~default:"mcp-client"
      in
      match Portal_inbox.deliver state.inbox ~from ~to_agent ~text with
      | Error e -> Error e
      | Ok id ->
          Ok
            ("delivered to " ^ to_agent ^ " (message id: " ^ id
            ^ "). The recipient reads it with oasis_check_inbox.")
let mcp_tool_check_inbox = fun (state : state) (params : Json.t) ->
  match mcp_get_str params "agent" with
  | None -> Error "missing required parameter: agent"
  | Some agent ->
      let msgs = Portal_inbox.check state.inbox ~agent in
      if List.is_empty msgs then
        Ok ("no unread messages for " ^ agent)
      else
        Ok
          (List.map msgs ~fn:Portal_inbox.render_for_agent |> String.concat "\n---\n")
let mcp_tool_ask_user = fun (state : state) (params : Json.t) ->
  match (mcp_get_str params "from_agent", mcp_get_str params "question") with
  | (None, _) -> Error "missing required parameter: from_agent"
  | (_, None) -> Error "missing required parameter: question"
  | (Some from_agent, Some question) ->
      (* answer channel: the user replies via /api/inbox/reply which delivers
         back to the asking agent's inbox *)
      match Portal_inbox.deliver state.inbox ~from:from_agent ~to_agent:"user" ~text:question with
      | Error e -> Error e
      | Ok _ ->
      Ok
        ("question delivered to the user (asked by " ^ from_agent
        ^ "). The answer will arrive in your inbox: check oasis_check_inbox with agent=" ^ from_agent ^ ".")
let mcp_tool_status = fun (state : state) ->
  let config = Sync.Atomic.get state.config in
  let lines =
    List.map config.Portal_config.accounts ~fn:(fun a ->
      let s = Portal_signals.get state.signals a.Portal_config.name in
      let breaker =
        match s.Portal_signals.breaker with
        | Portal_signals.Open_until _ -> "open"
        | Portal_signals.Half_open -> "half_open"
        | Portal_signals.Closed -> "closed"
      in
      let day =
        Portal_ledger.day_requests state.ledger a.Portal_config.name
      in
      a.Portal_config.name
      ^ ": breaker=" ^ breaker
      ^ " lat_ema=" ^ Int.to_string s.Portal_signals.latency_ema_ms ^ "ms"
      ^ " in_flight=" ^ Int.to_string s.Portal_signals.in_flight
      ^ " day=" ^ Int.to_string day ^ "/"
      ^ Int.to_string a.Portal_config.daily_limit
    )
  in
  Ok (String.concat "\n" lines)
let mcp_tool_decisions = fun (state : state) (params : Json.t) ->
  let limit = mcp_get_int params "limit" |> Option.unwrap_or ~default:10 in
  Ok (decisions_json state ~limit |> List.map ~fn:Json.to_string |> String.concat "\n")


(* ---------- MCP (Model Context Protocol) endpoint ---------- *)

let mcp_execute_tool = fun (state : state) (params : Json.t) ->
  match mcp_get_str params "name" with
  | None -> Error "missing tool name"
  | Some name ->
      let arguments =
        Json.get_field "arguments" params
        |> Option.unwrap_or ~default:(Json.obj [])
      in
      if String.equal name "oasis_ask" then
        mcp_tool_ask state arguments
      else if String.equal name "oasis_agent_task" then
        mcp_tool_agent state arguments
      else if String.equal name "oasis_task_status" then
        mcp_tool_task_status state arguments
      else if String.equal name "oasis_send_message" then
        mcp_tool_send_message state arguments
      else if String.equal name "oasis_check_inbox" then
        mcp_tool_check_inbox state arguments
      else if String.equal name "oasis_ask_user" then
        mcp_tool_ask_user state arguments
      else if String.equal name "oasis_status" then
        mcp_tool_status state
      else if String.equal name "oasis_decisions" then
        mcp_tool_decisions state arguments
      else if String.equal name "oasis_models" then
        mcp_tool_models state
      else if String.equal name "oasis_agents" then
        mcp_tool_agents state
      else if String.equal name "oasis_activity" then
        mcp_tool_activity state arguments
      else
        Error ("unknown tool: " ^ name)

let handle_mcp = fun (state : state) (ctx : Trail.ctx) ->
  match Net.Http.Request.body_string ctx.req with
  | None ->
      Trail.json
        ~status:Net.Http.Status.BadRequest
        ctx
        (Json.obj [ ("error", Json.string "empty body") ])
  | Some body -> (
      match Portal_mcp.parse body with
      | Error e ->
          Trail.json
            ~status:Net.Http.Status.BadRequest
            ctx
            (Json.obj [ ("error", Json.string e) ])
      | Ok rpc ->
          if Portal_mcp.is_notification rpc then
            (* notifications: no JSON-RPC response *)
            Trail.json
              ~status:Net.Http.Status.Accepted
              ctx
              (Json.obj [])
          else
            let id =
              match rpc.Portal_mcp.id with
              | Some i -> i
              | None -> Json.int 0
            in
            let wrap result =
              Portal_mcp.result_payload ~id ~result
              |> Json.from_string
              |> Result.unwrap_or ~default:(Json.obj [])
            in
            if String.equal rpc.Portal_mcp.method_ "initialize" then
              let ctx' =
                Trail.put_resp_header
                  ctx
                  ~name:"Mcp-Session-Id"
                  ~value:"oasis-session-1"
              in
              Trail.json ctx' (wrap (Portal_mcp.initialize_result ()))
            else if String.equal rpc.Portal_mcp.method_ "ping" then
              Trail.json ctx (wrap (Json.obj []))
            else if String.equal rpc.Portal_mcp.method_ "tools/list" then
              Trail.json
                ctx
                (wrap (Json.obj [ ("tools", Portal_mcp.tools_list ()) ]))
            else if String.equal rpc.Portal_mcp.method_ "tools/call" then (
              match mcp_execute_tool state rpc.Portal_mcp.params with
              | Ok text ->
                  Trail.json ctx (wrap (Portal_mcp.call_result ~text ~is_error:false))
              | Error err ->
                  Trail.json ctx (wrap (Portal_mcp.call_result ~text:err ~is_error:true))
            ) else
              let payload =
                Portal_mcp.error_payload
                  ~id
                  ~code:(-32601)
                  ~message:("method not found: " ^ rpc.Portal_mcp.method_)
                |> Json.from_string
                |> Result.unwrap_or ~default:(Json.obj [])
              in
              Trail.json ~status:Net.Http.Status.NotImplemented ctx payload
    )
