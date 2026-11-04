open Std
open Std.Collections

(** Streaming conductor: one client SSE stream across upstream legs, with
    mid-stream handoff (G1/G2/G3, spec §3). *)

module Trail = Hello_riot.Trail
module Json = Std.Data.Json

open Portal_state
open Portal_ws
open Portal_upstream
open Portal_decisions

(* ---------- streaming conductor ---------- *)

type conductor_ctx = {
  c_state: state;
  client_stream: Net.TcpStream.t;
  config: Portal_config.t;
  task: Portal_router.task;
  decision: Portal_router.decision;
  messages: Json.t;
  max_tokens: int;
  session: string option;
  request_id: string;
  handoff_allowed: bool;
  extra: (string * Json.t) list;
}

type conductor_state = {
  cc: conductor_ctx;
  mutable candidates: string list;
  mutable attempts: Portal_router.attempt list;
  mutable sent_text: string;
  mutable handoff: Portal_handoff.t option;
  mutable sse_state: Portal_sse.t;
  mutable tokens_out: int;
  mutable usage_in: int option;
  mutable usage_out: int option;
  mutable handoff_count: int;
  mutable handoff_from: (string * string) option;
  mutable open_handoff: Portal_router.handoff option;
  mutable handoffs: Portal_router.handoff list;
  mutable restart_on_content: string option;
  mutable current_account: string;
  mutable current_model: string;
  mutable current_protocol: string;
  mutable leg_start: Time.Instant.t;
  mutable leg_id: int;
  mutable awaiting_leg_end: bool;
  mutable saw_finish_reason: bool;
  mutable thinking_buf: string;
  mutable thought_any: bool;
  mutable tool_calls_sent: bool;
  mutable finished: bool;
}

let restart_notice = fun ~account ->
  "\n\n[Oasis: 上游中断，已切换到 " ^ account ^ " 重新生成]\n\n"

(** Token usage carried by one streaming event: OpenAI's final usage chunk,
    Anthropic's message_start (input) and message_delta (output). *)
let stream_usage_of = fun ~anthropic (data : string) ->
  match Json.from_string data with
  | Error _ -> (None, None)
  | Ok j ->
      let int_at path =
        List.fold_left path ~init:(Some j) ~fn:(fun acc k ->
          Option.and_then acc ~fn:(fun v -> Json.get_field k v))
        |> Option.and_then ~fn:Json.get_int
      in
      if anthropic then
        match Json.get_field "type" j |> Option.and_then ~fn:Json.get_string with
        | Some "message_start" -> (int_at [ "message"; "usage"; "input_tokens" ], None)
        | Some "message_delta" -> (None, int_at [ "usage"; "output_tokens" ])
        | _ -> (None, None)
      else
        (int_at [ "usage"; "prompt_tokens" ], int_at [ "usage"; "completion_tokens" ])

let run_conductor = fun (cc : conductor_ctx) ~(candidates : string list) ~(parent : Pid.t) () ->
  let me = self () in
  let policy = cc.config.Portal_config.policy in
  let cs =
    {
      cc;
      candidates;
      attempts = [];
      sent_text = "";
      handoff = None;
      sse_state = Portal_sse.init;
      tokens_out = 0;
      usage_in = None;
      usage_out = None;
      handoff_count = 0;
      handoff_from = None;
      open_handoff = None;
      handoffs = [];
      restart_on_content = None;
      current_account = "";
      current_model = "";
      current_protocol = "openai";
      leg_start = Time.Instant.now ();
      leg_id = 0;
      awaiting_leg_end = false;
      saw_finish_reason = false;
      thinking_buf = "";
      thought_any = false;
      tool_calls_sent = false;
      finished = false;
    }
  in
  let sync_open_handoff () =
    match (cs.open_handoff, cs.handoff) with
    | (Some h, Some splice) ->
        let level =
          match Portal_handoff.level splice with
          | Some l -> Portal_handoff.level_to_string l
          | None -> h.Portal_router.level
        in
        cs.open_handoff <-
          Some
            {
              h with
              Portal_router.matched_bytes = Portal_handoff.matched_bytes splice;
              diverged =
                (match Portal_handoff.diverged_at splice with
                 | Some k -> k < h.Portal_router.sent_bytes
                 | None -> false);
              level;
            }
    | _ -> ()
  in
  let close_open_handoff ~unresolved =
    match cs.open_handoff with
    | None -> ()
    | Some h ->
        let h = if String.equal h.Portal_router.level "?" then { h with Portal_router.level = unresolved } else h in
        cs.handoffs <- h :: cs.handoffs;
        cs.open_handoff <- None;
        broadcast_event
          cc.c_state
          ~type_:"handoff"
          ~request_id:cc.request_id
          ~data:(Portal_router.handoff_json h)
  in
  let set_open_level level =
    match cs.open_handoff with
    | Some h -> cs.open_handoff <- Some { h with Portal_router.level }
    | None -> ()
  in
  let decision_now () =
    {
      cc.decision with
      Portal_router.attempts = List.rev cs.attempts;
      handoffs = List.rev cs.handoffs;
    }
  in
  let record_attempt_ok ~cost ~latency_ms =
    {
      Portal_router.account = cs.current_account;
      model = cs.current_model;
      status = Some 200;
      error = None;
      latency_ms;
      cost_nano = cost;
    }
  in
  let finish_ok () =
    if not cs.finished then (
      cs.finished <- true;
      sync_open_handoff ();
      close_open_handoff ~unresolved:"G1";
      let latency_ms =
        Time.Duration.to_millis (Time.Instant.elapsed cs.leg_start)
      in
      let in_tokens = cs.usage_in |> Option.unwrap_or ~default:cc.task.Portal_router.est_in_tokens in
      let out_tokens = cs.usage_out |> Option.unwrap_or ~default:cs.tokens_out in
      let cost =
        cost_of
          cc.config
          cs.current_account
          cs.current_model
          in_tokens
          out_tokens
          0
      in
      let _ =
        Portal_signals.update
          cc.c_state.signals
          cs.current_account
          ~fn:(fun s ->
            Portal_signals.record_success
              s
              ~latency_ms
              ~tokens:out_tokens
              (Portal_signals.now_ms ()))
      in
      Portal_ledger.record
        cc.c_state.ledger
        ~account:cs.current_account
        ~model:cs.current_model
        ~in_tokens
        ~out_tokens
        ~cache_tokens:0
        ~cost_nano:cost
        ~latency_ms
        ~status:"ok"
        ();
      let decision =
        {
          (decision_now ()) with
          Portal_router.chosen = Some cs.current_account;
          Portal_router.attempts = List.rev (record_attempt_ok ~cost ~latency_ms :: cs.attempts);
        }
      in
      record_decision cc.c_state decision;
      emit_attempt_finished cc.c_state ~request_id:cc.request_id ~account:cs.current_account ~status:(Some 200) ~latency_ms ~error:None;
      emit_task_done
        cc.c_state
        ~request_id:cc.request_id
        ~chosen:(Some cs.current_account)
        ~attempts:(List.length decision.Portal_router.attempts)
        ~ok:true;
      (
        match cc.session with
        | Some sid ->
            Portal_session.pin
              cc.c_state.sessions
              ~session:sid
              ~account:cs.current_account
              ~now_ms:(Portal_signals.now_ms ())
        | None -> ()
      );
      let _ = write_stream cc.client_stream "data: [DONE]\n\n" in
      send parent (Conductor_done (Ok ()))
    )
  in
  let finish_failed ~reason =
    if not cs.finished then (
      cs.finished <- true;
      close_open_handoff ~unresolved:"G0";
      record_decision cc.c_state (decision_now ());
      emit_task_done cc.c_state ~request_id:cc.request_id ~chosen:None ~attempts:(List.length cs.attempts) ~ok:false;
      let err =
        Json.obj
          [
            (
              "error",
              Json.obj
                [
                  ("message", Json.string reason);
                  ("type", Json.string "oasis_upstream_failed");
                ]
            );
          ]
      in
      let _ = write_stream cc.client_stream ("data: " ^ Json.to_string err ^ "\n\n") in
      let _ = write_stream cc.client_stream "data: [DONE]\n\n" in
      send parent (Conductor_done (Ok ()))
    )
  in
  let finish_error e =
    if not cs.finished then (
      cs.finished <- true;
      close_open_handoff ~unresolved:"G0";
      record_decision cc.c_state (decision_now ());
      emit_task_done cc.c_state ~request_id:cc.request_id ~chosen:None ~attempts:(List.length cs.attempts) ~ok:false;
      send parent (Conductor_done (Error e))
    )
  in
  let rec start_next () =
    if cs.finished then
      ()
    else
      match cs.candidates with
      | [] ->
          finish_failed ~reason:"all upstream accounts failed"
      | name :: rest -> (
          cs.candidates <- rest;
          emit_attempt_started cc.c_state ~request_id:cc.request_id ~account:name;
          match Portal_config.find_account cc.config name with
          | None ->
              emit_attempt_finished cc.c_state ~request_id:cc.request_id ~account:name ~status:None ~latency_ms:0 ~error:(Some "unknown_account");
              cs.attempts <-
                {
                  Portal_router.account = name;
                  model = "";
                  status = None;
                  error = Some "unknown_account";
                  latency_ms = 0;
                  cost_nano = 0;
                }
                :: cs.attempts;
              start_next ()
          | Some account ->
              let prev_model = cs.current_model in
              cs.current_account <- name;
              cs.leg_id <- cs.leg_id + 1;
              let this_leg = cs.leg_id in
              cs.current_model <- model_for_account account cc.task.Portal_router.model;
              cs.current_protocol <- account.Portal_config.protocol;
              cs.leg_start <- Time.Instant.now ();
              cs.usage_in <- None;
              cs.usage_out <- None;
              cs.tokens_out <- 0;
              let _ =
                Portal_signals.update
                  cc.c_state.signals
                  name
                  ~fn:Portal_signals.mark_in_flight
              in
              let prefill =
                match cs.handoff_from with
                | None -> false
                | Some (from, reason) ->
                    let prefill = account.Portal_config.supports_prefill && cc.handoff_allowed in
                    cs.handoff_from <- None;
                    cs.open_handoff <-
                      Some
                        {
                          Portal_router.from_account = from;
                          to_account = name;
                          reason;
                          sent_bytes = String.length cs.sent_text;
                          matched_bytes = 0;
                          diverged = false;
                          level = (if prefill then "?" else "G3");
                          model_changed = not (String.equal prev_model cs.current_model);
                          at_ms = Portal_signals.now_ms ();
                        };
                    if prefill then (
                      cs.handoff <- Some (Portal_handoff.init ~sent_so_far:cs.sent_text);
                      cs.restart_on_content <- None
                    ) else (
                      cs.handoff <- None;
                      cs.restart_on_content <-
                        Some (if policy.Portal_config.handoff_notice then restart_notice ~account:name else "")
                    );
                    prefill
              in
              let messages_up =
                if prefill then with_assistant_prefix account cc.messages ~sent:cs.sent_text
                else cc.messages
              in
              let (scheme, host, port_opt, path_prefix) =
                parse_base_url account.Portal_config.base_url
              in
              let port = port_opt |> Option.unwrap_or ~default:443 in
              let chat_path = chat_path_of ~protocol:cs.current_protocol path_prefix in
              let body =
                if String.equal cs.current_protocol "anthropic" then
                  Portal_anthropic.to_request
                    ~thinking:(if prefill then "disabled" else account.Portal_config.thinking)
                    ~model:cs.current_model
                    ~messages:messages_up
                    ~max_tokens:cc.max_tokens
                    ~stream:true
                else
                  upstream_body
                    ~stream_usage:account.Portal_config.stream_usage
                    ~extra:cc.extra
                    ~model:cs.current_model
                    ~messages:messages_up
                    ~max_tokens:cc.max_tokens
                    ~stream:true
                    ()
              in
              let _ =
                Runtime.spawn_blocked (fun () ->
                  let res =
                    stream_upstream
                      ~connect_ip:account.Portal_config.connect_ip
                      ~leg_id:this_leg
                      ~scheme
                      ~host
                      ~port
                      ~path:chat_path
                      ~headers:(upstream_headers account host)
                      ~body
                      ~to_pid:me
                      ()
                  in
                  (
                    match res with
                    | Ok () -> ()
                    | Error e -> send me (Upstream_failed (this_leg, e))
                  );
                  Ok ())
              in
              ()
        )
  in
  let emit_pending_notice () =
    match cs.restart_on_content with
    | None -> ()
    | Some notice ->
        cs.restart_on_content <- None;
        cs.sent_text <- "";
        if not (String.is_empty notice) then
          let _ =
            write_stream cc.client_stream ("data: " ^ Json.to_string (delta_chunk_json notice) ^ "\n\n")
          in
          ()
  in
  (* Tool-call deltas are relayed verbatim (ids, indices and argument
     fragments must reach the client untouched); they never take part in a
     prefix splice because tools requests are not handoff-applicable. *)
  let relay_tool_event data =
    emit_pending_notice ();
    cs.tool_calls_sent <- true;
    cs.tokens_out <- cs.tokens_out + (String.length data / 16);
    match write_stream cc.client_stream ("data: " ^ data ^ "\n\n") with
    | Error e -> finish_error e
    | Ok () -> ()
  in
  let forward_to_client text =
    if not (String.is_empty text) then (
      emit_pending_notice ();
      cs.sent_text <- cs.sent_text ^ text;
      cs.tokens_out <- cs.tokens_out + (String.length text / 4);
      match
        write_stream
          cc.client_stream
          ("data: " ^ Json.to_string (delta_chunk_json text) ^ "\n\n")
      with
      | Error e -> finish_error e
      | Ok () -> ()
    )
  in
  let apply_step = function
    | Portal_handoff.Forward text -> forward_to_client text
    | Portal_handoff.Restart_with text ->
        cs.handoff <- None;
        set_open_level "G3";
        cs.restart_on_content <-
          Some (if policy.Portal_config.handoff_notice then restart_notice ~account:cs.current_account else "");
        forward_to_client text
  in
  let handle_content content =
    match cs.handoff with
    | None -> forward_to_client content
    | Some h ->
        let (step, h') = Portal_handoff.step h content in
        cs.handoff <- Some h';
        sync_open_handoff ();
        apply_step step
  in
  let flush_handoff () =
    match cs.handoff with
    | None -> ()
    | Some h ->
        let (step, h') = Portal_handoff.finish h in
        cs.handoff <- Some h';
        sync_open_handoff ();
        apply_step step
  in
  (* thinking goes to the task timeline in batches, never to the client *)
  let flush_thinking () =
    if not (String.is_empty cs.thinking_buf) then (
      emit_agent_step cc.c_state ~request_id:cc.request_id ~agent:cs.current_account
        (Portal_steps.thinking ~delta:true cs.thinking_buf);
      cs.thinking_buf <- ""
    )
  in
  let note_thinking data =
    let r = extract_delta_reasoning data in
    if not (String.is_empty r) then (
      cs.thought_any <- true;
      cs.thinking_buf <- cs.thinking_buf ^ r;
      if String.length cs.thinking_buf >= 240 then flush_thinking ()
    )
  in
  let handle_chunk chunk =
    if not cs.finished then (
      let (events, sse') = Portal_sse.feed cs.sse_state chunk in
      cs.sse_state <- sse';
      List.for_each
        events
        ~fn:(fun ev ->
          if cs.finished || cs.awaiting_leg_end then
            ()
          else
            let anthropic = String.equal cs.current_protocol "anthropic" in
            let is_done =
              if anthropic then
                Portal_anthropic.is_stream_end ev.Portal_sse.data
              else
                ev.Portal_sse.done_sentinel
            in
            if is_done then (
              (* upstream finished cleanly: wait for the blocking lane to
                 signal [Upstream_ended] before closing the client stream *)
              flush_handoff ();
              cs.awaiting_leg_end <- true
            ) else (
              let (u_in, u_out) = stream_usage_of ~anthropic ev.Portal_sse.data in
              if Option.is_some u_in then cs.usage_in <- u_in;
              if Option.is_some u_out then cs.usage_out <- u_out;
              if (not anthropic) && has_finish_reason ev.Portal_sse.data then
                cs.saw_finish_reason <- true;
              if not anthropic then note_thinking ev.Portal_sse.data;
              if (not anthropic) && is_tool_call_event ev.Portal_sse.data then
                relay_tool_event ev.Portal_sse.data
              else
                let content_opt =
                  if anthropic then
                    Portal_anthropic.extract_delta_text ev.Portal_sse.data
                  else
                    Some (extract_delta_content ev.Portal_sse.data)
                in
                match content_opt with
                | None -> ()
                | Some content -> handle_content content
            ))
    )
  in
  let handle_failure ~penalize ~err ~status ~body =
    if not cs.finished then (
      flush_thinking ();
      cs.thought_any <- false;
      let latency_ms =
        Time.Duration.to_millis (Time.Instant.elapsed cs.leg_start)
      in
      if penalize then (
        let _ =
          apply_failure cc.c_state cc.config ~account:cs.current_account ~status ~body ~err
        in
        ()
      );
      Portal_ledger.record
        cc.c_state.ledger
        ~account:cs.current_account
        ~model:cs.current_model
        ~in_tokens:(cs.usage_in |> Option.unwrap_or ~default:cc.task.Portal_router.est_in_tokens)
        ~out_tokens:cs.tokens_out
        ~cache_tokens:0
        ~cost_nano:0
        ~latency_ms
        ~status:"stream_failed"
        ();
      let attempt =
        {
          Portal_router.account = cs.current_account;
          model = cs.current_model;
          status;
          error = Some err;
          latency_ms;
          cost_nano = 0;
        }
      in
      cs.attempts <- attempt :: cs.attempts;
      emit_attempt_finished cc.c_state ~request_id:cc.request_id ~account:cs.current_account ~status ~latency_ms ~error:(Some err);
      (* text held back for head classification was really generated:
         deliver it before failing over *)
      flush_handoff ();
      close_open_handoff ~unresolved:"G0";
      cs.handoff <- None;
      cs.sse_state <- Portal_sse.init;
      cs.awaiting_leg_end <- false;
      cs.saw_finish_reason <- false;
      let delivered = not (String.is_empty cs.sent_text) in
      if cs.tool_calls_sent then
        (* a half-streamed tool call cannot be spliced or restarted without
           the client seeing corrupt arguments *)
        finish_failed ~reason:("upstream " ^ cs.current_account ^ " failed after streaming a tool call: " ^ err)
      else if not delivered then
        start_next ()
      else if cs.handoff_count >= policy.Portal_config.max_handoffs then
        finish_failed ~reason:("handoff limit reached after " ^ cs.current_account ^ " failed: " ^ err)
      else (
        cs.handoff_count <- cs.handoff_count + 1;
        cs.handoff_from <- Some (cs.current_account, err);
        start_next ()
      )
    )
  in
  let rec loop () =
    if not cs.finished then (
      let selector msg =
        match msg with
        | Upstream_chunk (leg, c) when leg = cs.leg_id -> Select (`Chunk c)
        | Upstream_failed (leg, e) when leg = cs.leg_id -> Select (`Failed e)
        | Upstream_head (leg, s, b) when leg = cs.leg_id -> Select (`Head (s, b))
        | Upstream_ended leg when leg = cs.leg_id -> Select `Leg_end
        | _ -> Skip
      in
      match receive ~selector ~timeout:(Time.Duration.from_secs 120) () with
      | `Chunk c ->
          handle_chunk c;
          loop ()
      | `Failed e ->
          handle_failure ~penalize:true ~err:e ~status:None ~body:"";
          loop ()
      | `Head (s, body) ->
          let err =
            if String.is_empty body then
              "upstream_rejected_http_" ^ Int.to_string s
            else
              "upstream_http_" ^ Int.to_string s ^ ": " ^ body
          in
          handle_failure ~penalize:true ~err ~status:(Some s) ~body;
          loop ()
      | `Leg_end ->
          if cs.awaiting_leg_end || cs.saw_finish_reason then flush_handoff ();
          flush_thinking ();
          if (cs.awaiting_leg_end || cs.saw_finish_reason) && String.is_empty cs.sent_text && not cs.tool_calls_sent then (
            (* a clean end with no answer (typically a reasoning model that
               spent max_tokens thinking): fail over, but the account is fine *)
            let err = if cs.thought_any then "empty_answer_reasoning_exhausted" else "empty_answer" in
            handle_failure ~penalize:false ~err ~status:None ~body:"";
            loop ()
          ) else if cs.awaiting_leg_end || cs.saw_finish_reason then
            finish_ok ()
          else (
            (* the upstream closed without a done event: treat as a cut *)
            handle_failure ~penalize:true ~err:"upstream_stream_ended_early" ~status:None ~body:"";
            loop ()
          )
      | exception Receive_timeout ->
          handle_failure ~penalize:true ~err:"upstream_stream_timeout" ~status:None ~body:"";
          loop ()
    )
  in
  start_next ();
  loop ();
  Ok ()
