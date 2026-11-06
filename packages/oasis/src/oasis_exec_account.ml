open Std
open Std.Collections

(** Chat completions over accounts: synchronous fallback chain and the
    [/v1/chat/completions] handler (stream → conductor, agent → exec_agent). *)

module Trail = Oasis_net.Trail
module Json = Std.Data.Json

open Oasis_state
open Oasis_ws
open Oasis_upstream
open Oasis_decisions
open Oasis_conductor
open Oasis_exec_agent

(* ---------- shared synchronous chat execution (HTTP + MCP) ---------- *)

type chat_sync_result = {
  cst_status: int;
  cst_body: string;
  cst_decision: Oasis_router.decision;
}

let execute_chat_sync = fun (state : state) (config : Oasis_config.t) ~(decision : Oasis_router.decision) ~(candidates : string list) ~(model : string option) ~(messages : Json.t) ~(max_tokens : int option) ?(extra = []) ~(session : string option) ~(request_id : string) () ->
    let rec try_attempts acc = function
      | [] ->
          let decision' =
            { decision with Oasis_router.attempts = List.rev acc }
          in
          record_decision state decision';
          emit_task_done state ~request_id ~chosen:None ~attempts:(List.length acc) ~ok:false;
          {
            cst_status = 502;
            cst_body =
              Json.to_string
                (Json.obj
                  [
                    ("error", Json.string "all_upstreams_failed");
                    ("decision", Oasis_router.decision_json decision');
                  ]);
            cst_decision = decision';
          }
      | name :: rest -> (
          emit_attempt_started state ~request_id ~account:name;
          match Oasis_config.find_account config name with
          | None ->
              emit_attempt_finished state ~request_id ~account:name ~status:None ~latency_ms:0 ~error:(Some "unknown_account");
              try_attempts
                ({
                   Oasis_router.account = name;
                   model = "";
                   status = None;
                   error = Some "unknown_account";
                   latency_ms = 0;
                   cost_nano = 0;
                 }
                :: acc)
                rest
          | Some account ->
              let upstream_model =
                match model with
                | Some m -> m
                | None ->
                    List.head account.Oasis_config.models
                    |> Option.unwrap_or ~default:""
              in
              let anthropic = String.equal account.Oasis_config.protocol "anthropic" in
              let auth_headers =
                match Oasis_config.api_key_of account with
                | Some k ->
                    if anthropic then
                      [
                        ("x-api-key", k);
                        ("anthropic-version", "2023-06-01");
                      ]
                    else
                      [ ("Authorization", "Bearer " ^ k) ]
                | None -> []
              in
              let req_body =
                if anthropic then
                  Oasis_anthropic.to_request
                    ~thinking:account.Oasis_config.thinking
                    ~model:upstream_model
                    ~messages:
                      (messages)
                    ~max_tokens:(anthropic_max_tokens config ~model:upstream_model max_tokens)
                    ~stream:false
                else
                  upstream_body ~extra ~model:upstream_model ~messages ~max_tokens ~stream:false ()
              in
              let (scheme, host, port_opt, path_prefix) =
                parse_base_url account.Oasis_config.base_url
              in
              let port = port_opt |> Option.unwrap_or ~default:443 in
              let chat_path = chat_path_of ~protocol:account.Oasis_config.protocol path_prefix in
              let headers =
                ("Content-Type", "application/json")
                :: ("Host", host)
                :: ("Connection", "close")
                :: auth_headers
              in
              let _ =
                Oasis_signals.update
                  state.signals
                  name
                  ~fn:Oasis_signals.mark_in_flight
              in
              let call_result =
                blocking_call
                  ~connect_ip:account.Oasis_config.connect_ip
                  ~scheme
                  ~host
                  ~port
                  ~path:chat_path
                  ~headers
                  ~body:req_body
                  ()
              in
              (
                match call_result with
                | Error err when Option.is_some (cancel_reason_of err) ->
                    let reason = cancel_reason_of err |> Option.unwrap_or ~default:"user" in
                    let _ = Oasis_signals.update state.signals name ~fn:Oasis_signals.release_in_flight in
                    emit_attempt_finished state ~request_id ~account:name ~status:None ~latency_ms:0 ~error:(Some err);
                    let decision' = { decision with Oasis_router.attempts = List.rev acc } in
                    record_decision state decision';
                    emit_task_done ~cancelled:true ~error:(cancel_text reason) state ~request_id ~chosen:None ~attempts:(List.length acc + 1) ~ok:false;
                    {
                      cst_status = 499;
                      cst_body = Json.to_string (Json.obj [ ("error", Json.string err); ("message", Json.string (cancel_text reason)) ]);
                      cst_decision = decision';
                    }
                | Error err ->
                    emit_attempt_finished state ~request_id ~account:name ~status:None ~latency_ms:0 ~error:(Some err);
                    let _ = apply_failure state config ~account:name ~status:None ~body:"" ~err in
                    try_attempts
                      ({
                         Oasis_router.account = name;
                         model = upstream_model;
                         status = None;
                         error = Some err;
                         latency_ms = 0;
                         cost_nano = 0;
                       }
                      :: acc)
                      rest
                | Ok (200, resp_body, latency_ms) when (not anthropic) && Option.is_some (empty_answer_of resp_body) ->
                    let err = empty_answer_of resp_body |> Option.unwrap_or ~default:"empty_answer" in
                    let _ = Oasis_signals.update state.signals name ~fn:(Oasis_signals.record_latency ~latency_ms) in
                    emit_attempt_finished state ~request_id ~account:name ~status:(Some 200) ~latency_ms ~error:(Some err);
                    try_attempts
                      ({
                         Oasis_router.account = name;
                         model = upstream_model;
                         status = Some 200;
                         error = Some err;
                         latency_ms;
                         cost_nano = 0;
                       }
                      :: acc)
                      rest
                | Ok (status, resp_body, latency_ms) ->
                    emit_attempt_finished state ~request_id ~account:name ~status:(Some status) ~latency_ms ~error:None;
                    if status = 200 then (
                      let resp_body_conv =
                        if anthropic then
                          Oasis_anthropic.from_response resp_body
                          |> Json.to_string
                        else
                          resp_body
                      in
                      let (in_t, out_t, cache_t) = extract_usage resp_body_conv in
                      let cost = cost_of config name upstream_model in_t out_t cache_t in
                      let _ =
                        Oasis_signals.update
                          state.signals
                          name
                          ~fn:(fun s ->
                            Oasis_signals.record_success
                              s
                              ~latency_ms
                              ~tokens:(in_t + out_t)
                              (Oasis_signals.now_ms ()))
                      in
                      Oasis_ledger.record
                        state.ledger
                        ~account:name
                        ~model:upstream_model
                        ~in_tokens:in_t
                        ~out_tokens:out_t
                        ~cache_tokens:cache_t
                        ~cost_nano:cost
                        ~latency_ms
                        ~status:"ok"
                        ();
                      let attempt =
                        {
                          Oasis_router.account = name;
                          model = upstream_model;
                          status = Some 200;
                          error = None;
                          latency_ms;
                          cost_nano = cost;
                        }
                      in
                      let decision' =
                        {
                          decision with
                          Oasis_router.chosen = Some name;
                          Oasis_router.attempts = List.rev (attempt :: acc);
                        }
                      in
                      record_decision state decision';
                      emit_task_done ~answer:(response_text resp_body_conv) state ~request_id ~chosen:(Some name) ~attempts:(List.length acc + 1) ~ok:true;
                      (* re-pin the session to the account that actually
                         served the request (fallback may have switched) *)
                      (
                        match session with
                        | Some sid ->
                            Oasis_session.pin
                              state.sessions
                              ~session:sid
                              ~account:name
                              ~now_ms:(Oasis_signals.now_ms ())
                        | None -> ()
                      );
                      let body_out =
                        match Json.from_string resp_body_conv with
                        | Ok j -> Json.to_string (normalize_openai_response j)
                        | Error _ ->
                            Json.to_string
                              (Json.obj [ ("content", Json.string resp_body_conv) ])
                      in
                      { cst_status = 200; cst_body = body_out; cst_decision = decision' }
                    ) else (
                      let err =
                        "upstream_http_" ^ Int.to_string status
                      in
                      let _ =
                        apply_failure state config ~account:name ~status:(Some status) ~body:resp_body ~err
                      in
                      Oasis_ledger.record
                        state.ledger
                        ~account:name
                        ~model:upstream_model
                        ~in_tokens:0
                        ~out_tokens:0
                        ~cache_tokens:0
                        ~cost_nano:0
                        ~latency_ms
                        ~status:err
                        ();
                      try_attempts
                        ({
                           Oasis_router.account = name;
                           model = upstream_model;
                           status = Some status;
                           error = None;
                           latency_ms;
                           cost_nano = 0;
                         }
                        :: acc)
                        rest
                    )
              )
        )
    in
    try_attempts [] candidates
let has_role = fun (body : Json.t) role ->
  Json.get_field "messages" body |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
  |> List.any ~fn:(fun m -> String.equal (Json.get_field "role" m |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:"") role)

(** [body] with the thread's earlier turns placed after its system messages.
    Clients that send their own history (any assistant message) are left
    alone. *)
let with_history = fun (body : Json.t) (th : Oasis_thread.thread) ->
  if has_role body "assistant" || List.is_empty th.Oasis_thread.turns then body
  else
    let messages = Json.get_field "messages" body |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[] in
    let is_system m = String.equal (Json.get_field "role" m |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:"") "system" in
    let merged = List.filter messages ~fn:is_system @ Oasis_thread.history_messages th @ List.filter messages ~fn:(fun m -> not (is_system m)) in
    match body with
    | Json.Object fields ->
        Json.obj (List.map fields ~fn:(fun (k, v) -> if String.equal k "messages" then (k, Json.array merged) else (k, v)))
    | j -> j

let handle_chat = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let raw_body = parse_json_body ctx in
  let thread_id =
    match get_header ctx "x-oasis-thread" |> Option.map ~fn:String.trim with
    | Some id when not (String.is_empty id || String.equal id "new") -> id
    | _ -> Oasis_thread.new_id ()
  in
  let prior =
    Oasis_thread.get state.threads thread_id
    |> Option.and_then ~fn:(fun th -> if List.is_empty th.Oasis_thread.turns then None else Some th)
  in
  let last_turn = Option.and_then prior ~fn:Oasis_thread.last_turn in
  let body = match prior with Some th -> with_history raw_body th | None -> raw_body in
  let ctx = Trail.put_resp_header ctx ~name:"X-Oasis-Thread" ~value:thread_id in
  let stream_requested =
    Json.get_field "stream" body |> Option.and_then ~fn:Json.get_bool
    |> Option.unwrap_or ~default:false
  in
  let model =
    match Json.get_field "model" body |> Option.and_then ~fn:Json.get_string with
    | Some m when not (String.is_empty m || String.equal m "auto" || String.equal m "oasis") -> Some m
    | _ -> None
  in
  let max_tokens = Json.get_field "max_tokens" body |> Option.and_then ~fn:Json.get_int in
  let est_in = est_input_tokens body in
  let explicit_category =
    match get_header ctx "x-oasis-category" |> Option.map ~fn:String.trim with
    | Some c when not (String.is_empty c || String.equal c "auto") -> Some c
    | _ -> None
  in
  let category, category_hits =
    match explicit_category with
    | Some c -> (c, [])
    | None -> Oasis_classify.classify (Oasis_feed.last_user_text raw_body)
  in
  let goal =
    get_header ctx "x-oasis-goal"
    |> Option.unwrap_or ~default:config.Oasis_config.policy.Oasis_config.goal
    |> Oasis_router.goal_of_string
  in
  let goal_str =
    get_header ctx "x-oasis-goal"
    |> Option.unwrap_or ~default:config.Oasis_config.policy.Oasis_config.goal
  in
  let request_id = new_request_id () in
  (match header_timeout ctx with Some secs -> arm_deadline state ~request_id ~secs | None -> ());
  audit_log
    state
    ~path:"/v1/chat/completions"
    ~category
    ~goal:goal_str
    ~stream_:stream_requested
    ~request_id
    ~body:(Net.Http.Request.body_string ctx.req |> Option.unwrap_or ~default:"")
    ();
  broadcast_event
    state
    ~type_:"task_started"
    ~request_id
    ~data:
      (Json.obj
        [
          ("category", Json.string category);
          ("goal", Json.string goal_str);
          ("title", Json.string (Oasis_feed.title_of_body body));
          ("prompt", Json.string (Oasis_steps.clip (Oasis_feed.last_user_text body) 8000));
          ("thread", Json.string thread_id);
          ("turn", Json.int (match prior with Some th -> List.length th.Oasis_thread.turns + 1 | None -> 1));
          ("source", Json.string (get_header ctx "x-oasis-source" |> Option.unwrap_or ~default:"api"));
          ("client_ref", Json.string (get_header ctx "x-oasis-client-ref" |> Option.unwrap_or ~default:""));
          ("category_source", Json.string (match explicit_category with Some _ -> "header" | None -> "auto"));
          ("category_hits", Json.array (List.map category_hits ~fn:Json.string));
          (
            "stream",
            Json.bool (Json.get_field "stream" body |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false)
          );
        ]);
  let task =
    {
      Oasis_router.category;
      model;
      est_in_tokens = est_in;
      est_out_tokens = max_tokens |> Option.unwrap_or ~default:1024;
    }
  in
  let pinned_agent =
    get_header ctx "x-oasis-agent" |> Option.map ~fn:String.trim |> Option.and_then ~fn:(fun a -> if String.is_empty a then None else Some a)
  in
  let explicit_mode = Option.is_some (get_header ctx "x-oasis-mode") || Option.is_some pinned_agent in
  (* a follow-up without its own routing headers continues the way the
     previous turn ran *)
  let follow_up = Option.is_some last_turn && not explicit_mode && Option.is_none explicit_category in
  let last_mode = match last_turn with Some x when follow_up -> x.Oasis_thread.mode | _ -> "" in
  let last_executor = match last_turn with Some x -> x.Oasis_thread.executor | None -> "" in
  let committee =
    match get_header ctx "x-oasis-committee" |> Option.map ~fn:Oasis_committee.parse_members with
    | Some m -> m
    | None -> (
        match prior with
        | Some th when String.equal last_mode "committee" -> th.Oasis_thread.members
        | _ -> [])
  in
  if not (List.is_empty committee) then
    Oasis_committee.handle state ctx body ~members:committee ~category ~goal ~request_id ~workspace:thread_id
  else
  let mode =
    match get_header ctx "x-oasis-mode" with
    | _ when Option.is_some pinned_agent -> `Agent
    | None when String.equal last_mode "agent" -> `Agent
    | None when follow_up && not (String.is_empty last_mode) -> `Chat
    | Some "agent" -> `Agent
    | Some "chat" -> `Chat
    | _ ->
        (* an inferred category never escalates a plain request to agents *)
        if
          Option.is_some explicit_category
          && List.any
               config.Oasis_config.policy.Oasis_config.agent_categories
               ~fn:(String.equal category)
        then
          `Agent
        else
          `Chat
  in
  let use_agent =
    (match mode with `Agent -> true | `Chat -> false)
    && not (List.is_empty config.Oasis_config.agents)
  in
  if use_agent then
    handle_chat_agent ?pinned:pinned_agent
      ?prefer:(if String.equal last_mode "agent" && not (String.is_empty last_executor) then Some last_executor else None)
      ?thread:prior ?workspace:(Oasis_thread.workspace_for prior ~id:thread_id) state ctx body ~category ~stream_requested ~request_id
  else
  let decision =
    Oasis_router.route_scored
      config
      (make_lookups state)
      ~goal
      task
    |> maybe_explore state
  in
  let decision, continued =
    if follow_up && not (String.is_empty last_executor) && not (String.equal last_mode "committee") then
      prefer_first decision (Some last_executor)
    else (decision, false)
  in
  (* sticky session: if the session is pinned to an account that still
     passes the hard constraints, prefer it (multi-turn context stays on
     one account) *)
  let session =
    get_header ctx "x-oasis-session"
  in
  let (decision, candidates) =
    match session with
    | None -> (decision, decision.Oasis_router.chosen)
    | Some sid -> (
        match
          Oasis_session.lookup
            state.sessions
            ~session:sid
            ~now_ms:(Oasis_signals.now_ms ())
            ~ttl_ms:(config.Oasis_config.policy.Oasis_config.session_ttl_s * 1000)
        with
        | Some pinned
          when List.any
               ((match decision.Oasis_router.chosen with
                 | Some c -> [ c ]
                 | None -> [])
               @ decision.Oasis_router.fallback_order)
               ~fn:(String.equal pinned) ->
            let rest =
              List.filter
                ((match decision.Oasis_router.chosen with
                  | Some c -> [ c ]
                  | None -> [])
                @ decision.Oasis_router.fallback_order)
                ~fn:(fun a -> not (String.equal a pinned))
            in
            ({ decision with Oasis_router.chosen = Some pinned; Oasis_router.fallback_order = rest }, Some pinned)
        | _ -> (decision, decision.Oasis_router.chosen)
      )
  in
  let candidates =
    match candidates with
    | Some c -> c :: decision.Oasis_router.fallback_order
    | None -> []
  in
  let needs_openai = requires_openai_protocol body in
  let routable = candidates in
  let candidates =
    if needs_openai then
      List.filter candidates ~fn:(fun name ->
        match Oasis_config.find_account config name with
        | Some a -> not (String.equal a.Oasis_config.protocol "anthropic")
        | None -> false)
    else
      candidates
  in
  let extra = passthrough_fields body in
  emit_routed ~continued state ~request_id ~mode:"account" decision;
  (* pin at dispatch (updated again on successful handoff) *)
  (
    match (session, List.head candidates) with
    | (Some sid, Some acct) ->
        Oasis_session.pin
          state.sessions
          ~session:sid
          ~account:acct
          ~now_ms:(Oasis_signals.now_ms ())
    | _ -> ()
  );
  if List.is_empty candidates && not (List.is_empty routable) then (
    record_decision state decision;
    emit_task_done ~error:"请求带了 tools 等参数，但没有可用的 openai 协议账户" state ~request_id ~chosen:None ~attempts:0 ~ok:false;
    Trail.json
      ~status:Net.Http.Status.BadRequest
      ctx
      (Json.obj
        [
          ("error", Json.string "tools_require_openai_protocol_account");
          (
            "message",
            Json.string
              "tools / tool_choice / functions / response_format are only forwarded to protocol = \"openai\" accounts; none is routable for this request"
          );
          ("decision", Oasis_router.decision_json decision);
        ])
  ) else if List.is_empty candidates then (
    record_decision state decision;
    emit_task_done ~error:"没有可用的账户（见路由说明里的排除原因）" state ~request_id ~chosen:None ~attempts:0 ~ok:false;
    Trail.json
      ~status:Net.Http.Status.PaymentRequired
      ctx
      (Json.obj
        [
          ("error", Json.string "no_account_available");
          ("decision", Oasis_router.decision_json decision);
        ])
  ) else if stream_requested then
    Trail.stream ctx (fun client_stream ->
      let cc =
        {
          c_state = state;
          client_stream;
          config;
          task;
          decision;
          messages =
            Json.get_field "messages" body
            |> Option.unwrap_or ~default:(Json.array []);
          max_tokens;
          session;
          request_id;
          handoff_allowed = handoff_applicable body;
          extra;
        }
      in
      let conductor =
        spawn
          (run_conductor cc ~candidates ~parent:(self ()))
      in
      watch_task state ~pid:conductor ~request_id ();
      let selector msg =
        match msg with
        | Conductor_done r -> Select r
        | _ -> Skip
      in
      let r = receive ~selector () in
      unwatch_task state ~request_id;
      r)
  else
    let r =
      watch_task state ~request_id ();
      let r =
        execute_chat_sync
          state
          config
          ~decision
          ~candidates
          ~model
          ~messages:(Json.get_field "messages" body |> Option.unwrap_or ~default:(Json.array []))
          ~max_tokens
          ~extra
          ~session
          ~request_id
          ()
      in
      unwatch_task state ~request_id;
      r
    in
    match Json.from_string r.cst_body with
    | Ok j ->
        Trail.json ~status:(Net.Http.Status.from_int r.cst_status) ctx j
    | Error _ ->
        Trail.json
          ~status:(Net.Http.Status.from_int r.cst_status)
          ctx
          (Json.obj [ ("content", Json.string r.cst_body) ])
