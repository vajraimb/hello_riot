open Std
open Std.Collections

(** Chat completions over accounts: synchronous fallback chain and the
    [/v1/chat/completions] handler (stream → conductor, agent → exec_agent). *)

module Trail = Hello_riot.Trail
module Json = Std.Data.Json

open Portal_state
open Portal_ws
open Portal_upstream
open Portal_decisions
open Portal_conductor
open Portal_exec_agent

(* ---------- shared synchronous chat execution (HTTP + MCP) ---------- *)

type chat_sync_result = {
  cst_status: int;
  cst_body: string;
  cst_decision: Portal_router.decision;
}

let execute_chat_sync = fun (state : state) (config : Portal_config.t) ~(decision : Portal_router.decision) ~(candidates : string list) ~(model : string option) ~(messages : Json.t) ~(max_tokens : int option) ?(extra = []) ~(session : string option) ~(request_id : string) () ->
    let rec try_attempts acc = function
      | [] ->
          let decision' =
            { decision with Portal_router.attempts = List.rev acc }
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
                    ("decision", Portal_router.decision_json decision');
                  ]);
            cst_decision = decision';
          }
      | name :: rest -> (
          emit_attempt_started state ~request_id ~account:name;
          match Portal_config.find_account config name with
          | None ->
              emit_attempt_finished state ~request_id ~account:name ~status:None ~latency_ms:0 ~error:(Some "unknown_account");
              try_attempts
                ({
                   Portal_router.account = name;
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
                    List.head account.Portal_config.models
                    |> Option.unwrap_or ~default:""
              in
              let anthropic = String.equal account.Portal_config.protocol "anthropic" in
              let auth_headers =
                match Portal_config.api_key_of account with
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
                  Portal_anthropic.to_request
                    ~thinking:account.Portal_config.thinking
                    ~model:upstream_model
                    ~messages:
                      (messages)
                    ~max_tokens:(anthropic_max_tokens config ~model:upstream_model max_tokens)
                    ~stream:false
                else
                  upstream_body ~extra ~model:upstream_model ~messages ~max_tokens ~stream:false ()
              in
              let (scheme, host, port_opt, path_prefix) =
                parse_base_url account.Portal_config.base_url
              in
              let port = port_opt |> Option.unwrap_or ~default:443 in
              let chat_path = chat_path_of ~protocol:account.Portal_config.protocol path_prefix in
              let headers =
                ("Content-Type", "application/json")
                :: ("Host", host)
                :: ("Connection", "close")
                :: auth_headers
              in
              let _ =
                Portal_signals.update
                  state.signals
                  name
                  ~fn:Portal_signals.mark_in_flight
              in
              let call_result =
                blocking_call
                  ~connect_ip:account.Portal_config.connect_ip
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
                    let _ = Portal_signals.update state.signals name ~fn:Portal_signals.release_in_flight in
                    emit_attempt_finished state ~request_id ~account:name ~status:None ~latency_ms:0 ~error:(Some err);
                    let decision' = { decision with Portal_router.attempts = List.rev acc } in
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
                         Portal_router.account = name;
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
                    let _ = Portal_signals.update state.signals name ~fn:(Portal_signals.record_latency ~latency_ms) in
                    emit_attempt_finished state ~request_id ~account:name ~status:(Some 200) ~latency_ms ~error:(Some err);
                    try_attempts
                      ({
                         Portal_router.account = name;
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
                          Portal_anthropic.from_response resp_body
                          |> Json.to_string
                        else
                          resp_body
                      in
                      let (in_t, out_t, cache_t) = extract_usage resp_body_conv in
                      let cost = cost_of config name upstream_model in_t out_t cache_t in
                      let _ =
                        Portal_signals.update
                          state.signals
                          name
                          ~fn:(fun s ->
                            Portal_signals.record_success
                              s
                              ~latency_ms
                              ~tokens:(in_t + out_t)
                              (Portal_signals.now_ms ()))
                      in
                      Portal_ledger.record
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
                          Portal_router.account = name;
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
                          Portal_router.chosen = Some name;
                          Portal_router.attempts = List.rev (attempt :: acc);
                        }
                      in
                      record_decision state decision';
                      emit_task_done ~answer:(response_text resp_body_conv) state ~request_id ~chosen:(Some name) ~attempts:(List.length acc + 1) ~ok:true;
                      (* re-pin the session to the account that actually
                         served the request (fallback may have switched) *)
                      (
                        match session with
                        | Some sid ->
                            Portal_session.pin
                              state.sessions
                              ~session:sid
                              ~account:name
                              ~now_ms:(Portal_signals.now_ms ())
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
                      Portal_ledger.record
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
                           Portal_router.account = name;
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
let handle_chat = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let body = parse_json_body ctx in
  let stream_requested =
    Json.get_field "stream" body |> Option.and_then ~fn:Json.get_bool
    |> Option.unwrap_or ~default:false
  in
  let model =
    Json.get_field "model" body |> Option.and_then ~fn:Json.get_string
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
    | None -> Portal_classify.classify (Portal_feed.last_user_text body)
  in
  let goal =
    get_header ctx "x-oasis-goal"
    |> Option.unwrap_or ~default:config.Portal_config.policy.Portal_config.goal
    |> Portal_router.goal_of_string
  in
  let goal_str =
    get_header ctx "x-oasis-goal"
    |> Option.unwrap_or ~default:config.Portal_config.policy.Portal_config.goal
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
          ("title", Json.string (Portal_feed.title_of_body body));
          ("prompt", Json.string (Portal_steps.clip (Portal_feed.last_user_text body) 8000));
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
      Portal_router.category;
      model;
      est_in_tokens = est_in;
      est_out_tokens = max_tokens |> Option.unwrap_or ~default:1024;
    }
  in
  let pinned_agent =
    get_header ctx "x-oasis-agent" |> Option.map ~fn:String.trim |> Option.and_then ~fn:(fun a -> if String.is_empty a then None else Some a)
  in
  let committee =
    get_header ctx "x-oasis-committee" |> Option.map ~fn:Portal_committee.parse_members |> Option.unwrap_or ~default:[]
  in
  if not (List.is_empty committee) then
    Portal_committee.handle state ctx body ~members:committee ~category ~goal ~request_id
  else
  let mode =
    match get_header ctx "x-oasis-mode" with
    | _ when Option.is_some pinned_agent -> `Agent
    | Some "agent" -> `Agent
    | Some "chat" -> `Chat
    | _ ->
        (* an inferred category never escalates a plain request to agents *)
        if
          Option.is_some explicit_category
          && List.any
               config.Portal_config.policy.Portal_config.agent_categories
               ~fn:(String.equal category)
        then
          `Agent
        else
          `Chat
  in
  let use_agent =
    (match mode with `Agent -> true | `Chat -> false)
    && not (List.is_empty config.Portal_config.agents)
  in
  if use_agent then
    handle_chat_agent ?pinned:pinned_agent state ctx body ~category ~stream_requested ~request_id
  else
  let decision =
    Portal_router.route_scored
      config
      (make_lookups state)
      ~goal
      task
    |> maybe_explore state
  in
  (* sticky session: if the session is pinned to an account that still
     passes the hard constraints, prefer it (multi-turn context stays on
     one account) *)
  let session =
    get_header ctx "x-oasis-session"
  in
  let (decision, candidates) =
    match session with
    | None -> (decision, decision.Portal_router.chosen)
    | Some sid -> (
        match
          Portal_session.lookup
            state.sessions
            ~session:sid
            ~now_ms:(Portal_signals.now_ms ())
            ~ttl_ms:(config.Portal_config.policy.Portal_config.session_ttl_s * 1000)
        with
        | Some pinned
          when List.any
               ((match decision.Portal_router.chosen with
                 | Some c -> [ c ]
                 | None -> [])
               @ decision.Portal_router.fallback_order)
               ~fn:(String.equal pinned) ->
            let rest =
              List.filter
                ((match decision.Portal_router.chosen with
                  | Some c -> [ c ]
                  | None -> [])
                @ decision.Portal_router.fallback_order)
                ~fn:(fun a -> not (String.equal a pinned))
            in
            ({ decision with Portal_router.chosen = Some pinned; Portal_router.fallback_order = rest }, Some pinned)
        | _ -> (decision, decision.Portal_router.chosen)
      )
  in
  let candidates =
    match candidates with
    | Some c -> c :: decision.Portal_router.fallback_order
    | None -> []
  in
  let needs_openai = requires_openai_protocol body in
  let routable = candidates in
  let candidates =
    if needs_openai then
      List.filter candidates ~fn:(fun name ->
        match Portal_config.find_account config name with
        | Some a -> not (String.equal a.Portal_config.protocol "anthropic")
        | None -> false)
    else
      candidates
  in
  let extra = passthrough_fields body in
  emit_routed state ~request_id ~mode:"account" decision;
  (* pin at dispatch (updated again on successful handoff) *)
  (
    match (session, List.head candidates) with
    | (Some sid, Some acct) ->
        Portal_session.pin
          state.sessions
          ~session:sid
          ~account:acct
          ~now_ms:(Portal_signals.now_ms ())
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
          ("decision", Portal_router.decision_json decision);
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
          ("decision", Portal_router.decision_json decision);
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
