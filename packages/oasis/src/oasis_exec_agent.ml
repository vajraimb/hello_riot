open Std
open Std.Collections

(** Agent pool routing and execution (subprocess agents behind the chat API). *)

module Trail = Oasis_net.Trail
module Json = Std.Data.Json

open Oasis_state
open Oasis_ws
open Oasis_upstream
open Oasis_decisions
open Oasis_conductor

(* ---------- agent routing and execution ---------- *)

(** Agents run headless: nobody can answer an interactive question tool, so
    questions go into the answer and the user replies in the next turn. *)
let unattended_note =
  "[Oasis] 你在无人值守模式下运行，没有人能实时回答，提问类工具（如 AskUserQuestion）不可用。"
  ^ "遇到需要用户决定的事：能选合理的默认就直接选，并在最后说明你的选择；"
  ^ "必须由用户决定的，把问题和可选项写在回答末尾，然后结束本轮——用户会在下一轮回复，你再接着做。\n\n"

let agent_prompt_of_body = fun (body : Json.t) ->
  let messages =
    Json.get_field "messages" body |> Option.and_then ~fn:Json.get_array
    |> Option.unwrap_or ~default:[]
  in
  let systems =
    List.filter_map messages ~fn:(fun m ->
      match Json.get_field "role" m |> Option.and_then ~fn:Json.get_string with
      | Some "system" ->
          Json.get_field "content" m |> Option.and_then ~fn:Json.get_string
      | _ -> None)
  in
  let rest =
    List.filter_map messages ~fn:(fun m ->
      match Json.get_field "role" m |> Option.and_then ~fn:Json.get_string with
      | Some ("user" | "assistant") ->
          let role =
            Json.get_field "role" m |> Option.and_then ~fn:Json.get_string
            |> Option.unwrap_or ~default:"user"
          in
          let content =
            Json.get_field "content" m |> Option.and_then ~fn:Json.get_string
            |> Option.unwrap_or ~default:""
          in
          Some (role ^ ": " ^ content)
      | _ -> None)
  in
  let system_prefix =
    if List.is_empty systems then ""
    else String.concat "\n" systems ^ "\n\n"
  in
  unattended_note ^ system_prefix ^ String.concat "\n" rest

(** [?only] pins the pool to one agent the user picked: no exploration, no
    substitutes. *)
let route_agents = fun ?only (state : state) (config : Oasis_config.t) (category : string) (model : string option) ->
  let now = Oasis_signals.now_ms () in
  let candidates =
    List.filter config.Oasis_config.agents ~fn:(fun a ->
      a.Oasis_agent.enabled
      && match only with Some n -> String.equal a.Oasis_agent.name n | None -> true)
  in
  let rejects = ref [] in
  let passing =
    List.filter_map candidates ~fn:(fun a ->
      let model_ok =
        match model with
        | None -> true
        | Some m -> List.any a.Oasis_agent.models ~fn:(String.equal m)
      in
      let s = Oasis_signals.get state.signals a.Oasis_agent.name in
      let breaker_open =
        match s.Oasis_signals.breaker with
        | Oasis_signals.Open_until deadline -> now < deadline
        | _ -> false
      in
      let concurrency_ok = s.Oasis_signals.in_flight < max 1 a.Oasis_agent.concurrency_limit in
      if not model_ok then (
        rejects := { Oasis_router.account = a.Oasis_agent.name; reason = "model_not_served" } :: !rejects;
        None
      ) else if breaker_open then (
        rejects := { Oasis_router.account = a.Oasis_agent.name; reason = "circuit_open" } :: !rejects;
        None
      ) else if not concurrency_ok then (
        rejects := { Oasis_router.account = a.Oasis_agent.name; reason = "concurrency_limit" } :: !rejects;
        None
      ) else
        let fit =
          Oasis_quality.blend
            ~static:(Oasis_agent.fit a ~category)
            (Oasis_quality.get state.quality ~account:a.Oasis_agent.name ~category)
        in
        let lat =
          if s.Oasis_signals.latency_samples = 0 then 50
          else Oasis_router.latency_score_agent ~ema_ms:s.Oasis_signals.latency_ema_ms
        in
        Some (a, fit + lat)
    )
  in
  let sorted =
    List.sort passing ~compare:(fun (_, s1) (_, s2) ->
      if s1 > s2 then LT else if s1 < s2 then GT else EQ)
  in
  let chosen = List.head sorted |> Option.map ~fn:(fun (a, _) -> a.Oasis_agent.name) in
  let fallback_order =
    match chosen with
    | None -> []
    | Some nm ->
        List.filter_map sorted ~fn:(fun (a, _) ->
          if String.equal a.Oasis_agent.name nm then None else Some a.Oasis_agent.name)
  in
  {
    Oasis_router.task_category = category;
    chosen;
    fallback_order;
    rejected = List.rev !rejects;
    attempts = [];
    scores = List.map sorted ~fn:(fun (a, sc) -> (a.Oasis_agent.name, sc));
    parts = [];
    explored = false;
    unpriced = [];
    handoffs = [];
  }
  |> fun d -> if Option.is_some only then d else maybe_explore state d

let find_agent = fun (config : Oasis_config.t) name ->
  List.find config.Oasis_config.agents ~fn:(fun a -> String.equal a.Oasis_agent.name name)

type Message.t +=
  | Agent_call_result of (string, string) result

let blocking_agent_call = fun ?on_line ~agent ~model ~prompt ->
  Oasis_agent_worker.run_task
    ?on_line
    ~name:agent.Oasis_agent.name
    ~agent
    ~model
    ~prompt
    ()

let agent_result_json = fun ~agent ~text ->
  Json.obj
    [
      ("id", Json.string ("agent-" ^ agent.Oasis_agent.name));
      ("object", Json.string "chat.completion");
      ("model", Json.string agent.Oasis_agent.name);
      (
        "choices",
        Json.array
          [
            Json.obj
              [
                ("index", Json.int 0);
                (
                  "message",
                  Json.obj
                    [
                      ("role", Json.string "assistant");
                      ("content", Json.string text);
                    ]
                );
                ("finish_reason", Json.string "stop");
              ]
          ]
      );
      (
        "usage",
        Json.obj
          [
            ("prompt_tokens", Json.int 0);
            ("completion_tokens", Json.int 0);
            ("total_tokens", Json.int 0);
          ]
      );
    ]

(** Puts [prefer] (the agent of the previous turn) first when it is still a
    candidate. *)
let prefer_first = fun (d : Oasis_router.decision) prefer ->
  let all = (match d.Oasis_router.chosen with Some c -> [ c ] | None -> []) @ d.Oasis_router.fallback_order in
  match prefer with
  | Some p when List.any all ~fn:(String.equal p) ->
      ({ d with Oasis_router.chosen = Some p; fallback_order = List.filter all ~fn:(fun a -> not (String.equal a p)) }, true)
  | _ -> (d, false)

(** Emits [agent_session] when an agent announces a (new) CLI session id. *)
let session_watch = fun (state : state) ~request_id ->
  let last = ref "" in
  fun ~agent line ->
    match Oasis_agent.session_id_of_line line with
    | Some sid when not (String.equal sid !last) ->
        last := sid;
        broadcast_event state ~type_:"agent_session" ~request_id
          ~data:(Json.obj [ ("agent", Json.string agent); ("session", Json.string sid) ])
    | _ -> ()

(** Runs an agent that has no configured [workdir] in the task's own
    workspace directory, and tells the feed / thread where that is. *)
let in_workspace = fun (state : state) ~request_id ?workspace (agent : Oasis_agent.agent) ->
  match workspace with
  | Some id when String.is_empty agent.Oasis_agent.workdir -> (
      let config = Sync.Atomic.get state.config in
      match Oasis_workspace.prepare config ~id with
      | Error _ -> agent
      | Ok dir ->
          broadcast_event state ~type_:"workspace" ~request_id ~data:(Json.obj [ ("id", Json.string id); ("dir", Json.string dir) ]);
          { agent with Oasis_agent.workdir = dir })
  | _ -> agent

let handle_chat_agent = fun ?pinned ?prefer ?thread ?workspace (state : state) (ctx : Trail.ctx) (body : Json.t) ~(category : string) ~(stream_requested : bool) ~(request_id : string) ->
  audit_log state ~path:"/agent-path-enter" ~category ~goal:"-" ~stream_:stream_requested ~request_id ();
  let config = Sync.Atomic.get state.config in
  let model =
    Json.get_field "model" body |> Option.and_then ~fn:Json.get_string
  in
  let decision = route_agents ?only:pinned state config category model in
  let decision, continued = if Option.is_some pinned then (decision, false) else prefer_first decision prefer in
  emit_routed ~pinned:(Option.is_some pinned) ~continued state ~request_id ~mode:"agent" decision;
  let watch_session = session_watch state ~request_id in
  (* a follow-up resumes the agent's own CLI session when it has one; any
     other agent gets the conversation replayed in its prompt *)
  let prompt_for nm (agent : Oasis_agent.agent) prompt0 =
    let resumed =
      match thread with
      | None -> None
      | Some th ->
          Oasis_thread.session_of th ~agent:nm
          |> Option.and_then ~fn:(fun sid -> Oasis_agent.with_resume agent ~session:sid)
    in
    let agent, prompt =
      match resumed with
      | Some a -> (a, Oasis_feed.last_user_text body)
      | None -> (agent, prompt0)
    in
    (in_workspace state ~request_id ?workspace agent, prompt)
  in
  audit_log
    state
    ~path:"/agent-path-routed"
    ~category:(decision.Oasis_router.chosen |> Option.unwrap_or ~default:"none")
    ~goal:(Int.to_string (List.length decision.Oasis_router.fallback_order))
    ~stream_:stream_requested
    ();
  let candidates =
    match decision.Oasis_router.chosen with
    | Some nm -> nm :: decision.Oasis_router.fallback_order
    | None -> []
  in
  if List.is_empty candidates then (
    record_decision state decision;
    emit_task_done ~error:"没有可用的 agent（见路由说明里的排除原因）" state ~request_id ~chosen:None ~attempts:0 ~ok:false;
    Trail.json
      ~status:Net.Http.Status.PaymentRequired
      ctx
      (Json.obj
        [
          ("error", Json.string "no_agent_available");
          ("decision", Oasis_router.decision_json decision);
        ])
  ) else
    let prompt0 = agent_prompt_of_body body in
    if stream_requested then (
      let sent = ref "" in
      let candidates_left = ref candidates in
      let attempts = ref [] in
      let current = ref "" in
      let t0 = ref (Time.Instant.now ()) in
      let joiner = Oasis_steps.joiner () in
      let rec start_agent () =
        match !candidates_left with
        | [] -> false
        | nm :: rest -> (
            candidates_left := rest;
            current := nm;
            joiner.Oasis_steps.broke <- true;
            t0 := Time.Instant.now ();
            match find_agent config nm with
            | None ->
                attempts :=
                  { Oasis_router.account = nm; model = nm; status = None; error = Some "unknown_agent"; latency_ms = 0; cost_nano = 0 }
                  :: !attempts;
                start_agent ()
            | Some agent ->
                let _ =
                  Oasis_signals.update state.signals nm ~fn:Oasis_signals.mark_in_flight
                in
                broadcast_event
                  state
                  ~type_:"attempt_started"
                  ~request_id
                  ~data:(Json.obj [ ("account", Json.string nm) ]);
                let model_for =
                  match model with
                  | Some m -> m
                  | None -> List.head agent.Oasis_agent.models |> Option.unwrap_or ~default:""
                in
                let agent, base_prompt = prompt_for nm agent prompt0 in
                let prompt =
                  if String.is_empty !sent then base_prompt
                  else
                    base_prompt
                    ^ "\n\n[上一个 agent 的输出已部分完成，请直接继续并补全任务。之前输出:]\n"
                    ^ !sent
                in
                (* spawn streaming runner on a blocking lane *)
                let me = self () in
                let leg = ref 1 in
                let runner_pid =
                  Runtime.spawn_blocked (fun () ->
                    let res =
                      Oasis_agent.stream
                        ~leg:!leg
                        ~agent
                        ~model:model_for
                        ~prompt
                        ~to_pid:me
                        ()
                    in
                    (match res with Ok () -> () | Error _ -> ());
                    Ok ())
                in
                let _ = runner_pid in
                true
          )
      in
      Trail.stream ctx (fun client_stream ->
        watch_task state ~request_id ();
        let proc = ref None in
        let finished = ref false in
        let released = ref false in
        let release_slot () =
          if not !released then (
            released := true;
            let _ =
              Oasis_signals.update state.signals !current ~fn:Oasis_signals.release_in_flight
            in
            ()
          )
        in
        let finish_ok () =
          let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed !t0) in
          let _ =
            Oasis_signals.update state.signals !current ~fn:(fun s ->
              Oasis_signals.record_success s ~latency_ms ~tokens:(String.length !sent / 4) (Oasis_signals.now_ms ()))
          in
          released := true;
          let decision' =
            {
              decision with
              Oasis_router.chosen = Some !current;
              Oasis_router.attempts =
                List.rev ({ Oasis_router.account = !current; model = !current; status = Some 200; error = None; latency_ms; cost_nano = 0 } :: !attempts);
            }
          in
          record_decision state decision';
          broadcast_event
            state
            ~type_:"attempt_finished"
            ~request_id
            ~data:
              (Json.obj
                [
                  ("account", Json.string !current);
                  ("status", Json.int 200);
                  ("latency_ms", Json.int latency_ms);
                ]);
          broadcast_event
            state
            ~type_:"task_done"
            ~request_id
            ~data:
              (Json.obj
                [
                  ("chosen", Json.string !current);
                  ("attempts", Json.int (List.length !attempts));
                  ("ok", Json.bool true);
                  ("answer", Json.string (Oasis_steps.clip !sent 60000));
                ]);
          let _ = write_stream client_stream "data: [DONE]\n\n" in
          send (self ()) (Conductor_done (Ok ()))
        in
        let finish_fail reason =
          let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed !t0) in
          let _ =
            Oasis_signals.update state.signals !current ~fn:(fun s ->
              Oasis_signals.record_failure s ~error:reason (Oasis_signals.now_ms ()))
          in
          released := true;
          attempts :=
            { Oasis_router.account = !current; model = !current; status = None; error = Some reason; latency_ms; cost_nano = 0 }
            :: !attempts;
          broadcast_event
            state
            ~type_:"attempt_finished"
            ~request_id
            ~data:
              (Json.obj
                [
                  ("account", Json.string !current);
                  ("error", Json.string reason);
                  ("latency_ms", Json.int latency_ms);
                ]);
          if start_agent () then (
            (* continue streaming from the next agent: reset the finished
               flag and keep the loop running *)
            released := false;
            finished := false;
            true
          ) else (
            let decision' =
              { decision with Oasis_router.attempts = List.rev !attempts }
            in
            record_decision state decision';
            broadcast_event
              state
              ~type_:"task_done"
              ~request_id
              ~data:
                (Json.obj
                  [
                    ("chosen", Json.string "none");
                    ("attempts", Json.int (List.length !attempts));
                    ("ok", Json.bool false);
                    ("error", Json.string ("所有 agent 都失败了，最后一个：" ^ reason));
                    ("answer", Json.string !sent);
                  ]);
            let _ = write_stream client_stream "data: [DONE]\n\n" in
            send (self ()) (Conductor_done (Ok ()));
            false
          )
        in
        let client_gone e =
          finished := true;
          release_slot ();
          emit_task_done
            ~error:("调用方断开了连接，结果未送达（" ^ !current ^ " 仍可能在后台跑完）")
            state ~request_id ~chosen:None ~attempts:(List.length !attempts + 1) ~ok:false;
          send (self ()) (Conductor_done (Error e))
        in
        let _ = start_agent () in
        let rec loop () =
          if not !finished then (
            let selector msg =
              match msg with
              | Oasis_agent.Agent_line (_, line) -> Select (`Line line)
              | Oasis_agent.Agent_done (_, code, note) -> Select (`Done (code, note))
              | Oasis_agent.Agent_timeout _ -> Select `Timeout
              | Oasis_agent.Agent_spawned (_, p) -> Select (`Spawned p)
              | Task_cancel reason -> Select (`Cancel reason)
              | _ -> Skip
            in
            match receive ~selector ~timeout:(Time.Duration.from_secs 10) () with
            | `Spawned p ->
                proc := Some p;
                loop ()
            | `Cancel reason ->
                finished := true;
                (match !proc with
                 | Some p -> ignore (Runtime.spawn_blocked (fun () -> Oasis_agent.kill_group p; Ok ()))
                 | None -> ());
                release_slot ();
                let err = cancel_error reason in
                let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed !t0) in
                attempts :=
                  { Oasis_router.account = !current; model = !current; status = None; error = Some err; latency_ms; cost_nano = 0 }
                  :: !attempts;
                emit_attempt_finished state ~request_id ~account:!current ~status:None ~latency_ms ~error:(Some err);
                record_decision state { decision with Oasis_router.attempts = List.rev !attempts };
                emit_task_done ~cancelled:true ~error:(cancel_text reason) ~answer:!sent state ~request_id ~chosen:None
                  ~attempts:(List.length !attempts) ~ok:false;
                let payload =
                  Json.obj [ ("error", Json.obj [ ("message", Json.string (cancel_text reason)); ("type", Json.string "oasis_cancelled") ]) ]
                in
                let _ = write_stream client_stream ("data: " ^ Json.to_string payload ^ "\n\n") in
                let _ = write_stream client_stream "data: [DONE]\n\n" in
                ()
            | `Line line -> (
                watch_session ~agent:!current line;
                let text, steps =
                  Oasis_agent.consume_line
                    joiner
                    ~command:(match find_agent config !current with Some a -> a.Oasis_agent.command | None -> "")
                    line
                in
                List.for_each steps ~fn:(emit_agent_step state ~request_id ~agent:!current);
                match text with
                | "" -> loop ()
                | text ->
                    sent := !sent ^ text;
                    (match
                      write_stream
                        client_stream
                        ("data: " ^ Json.to_string (delta_chunk_json text) ^ "\n\n")
                    with
                    | Error e -> client_gone e
                    | Ok () -> loop ()
                )
              )
            | `Done (code, note) ->
                finished := true;
                let note = String.trim note in
                let silent = String.is_empty (String.trim !sent) in
                (* A zero exit with an empty answer and a stderr note is a
                   failure: WorkBuddy does this when the CLI is not logged in. *)
                if code = 0 && not (silent && not (String.is_empty note)) then
                  finish_ok ()
                else (
                  (if silent && not (String.is_empty note) then sent := note);
                  let reason =
                    if code = 0 then note
                    else
                      let base = "agent exited with code " ^ Int.to_string code in
                      if String.is_empty note then base else base ^ ": " ^ note
                  in
                  if finish_fail reason then loop ()
                )
            | `Timeout ->
                finished := true;
                if
                  finish_fail
                    ("agent timeout (" ^ Int.to_string (match find_agent config !current with Some a -> a.Oasis_agent.timeout_s | None -> 600) ^ "s)")
                then
                  loop ()
            | exception Receive_timeout ->
                (* heartbeat: agent may work silently for minutes (tool
                   runs); it runs until it exits or the task is cancelled *)
                (match
                  write_stream
                    client_stream
                    "data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"},\"finish_reason\":null}]}\n\n"
                with
                | Error e -> client_gone e
                | Ok () -> loop ()
                )
          )
        in
        loop ();
        unwatch_task state ~request_id;
        (* client disconnected or stream ended without a finish event:
           release the in-flight slot (not the agent's fault) *)
        release_slot ();
        Ok ())
    ) else
      let rec try_agents acc = function
        | [] ->
            let decision' = { decision with Oasis_router.attempts = List.rev acc } in
            record_decision state decision';
            let last_err = match acc with a :: _ -> a.Oasis_router.error |> Option.unwrap_or ~default:"" | [] -> "" in
            emit_task_done
              ~error:(if String.is_empty last_err then "所有 agent 都失败了" else "所有 agent 都失败了，最后一个：" ^ last_err)
              ~answer:last_err
              state ~request_id ~chosen:None ~attempts:(List.length acc) ~ok:false;
            Trail.json
              ~status:Net.Http.Status.BadGateway
              ctx
              (Json.obj
                [
                  ("error", Json.string "all_agents_failed");
                  ("decision", Oasis_router.decision_json decision');
                ])
        | nm :: rest -> (
            match find_agent config nm with
            | None ->
                try_agents
                  ({ Oasis_router.account = nm; model = nm; status = None; error = Some "unknown_agent"; latency_ms = 0; cost_nano = 0 } :: acc)
                  rest
            | Some agent ->
                let model_for =
                  match model with
                  | Some m -> m
                  | None -> List.head agent.Oasis_agent.models |> Option.unwrap_or ~default:""
                in
                let _ =
                  Oasis_signals.update state.signals nm ~fn:Oasis_signals.mark_in_flight
                in
                let t0 = Time.Instant.now () in
                emit_attempt_started state ~request_id ~account:nm;
                let observe =
                  agent_step_observer state ~request_id ~agent:nm ~command:agent.Oasis_agent.command
                in
                let on_line line = watch_session ~agent:nm line; observe line in
                let agent, prompt = prompt_for nm agent prompt0 in
                let result = blocking_agent_call ~on_line ~agent ~model:model_for ~prompt in
                let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed t0) in
                emit_attempt_finished
                  state
                  ~request_id
                  ~account:nm
                  ~status:(match result with Ok _ -> Some 200 | Error _ -> None)
                  ~error:(match result with Ok _ -> None | Error e -> Some e)
                  ~latency_ms;
                (
                  match result with
                  | Ok text ->
                      let _ =
                        Oasis_signals.update state.signals nm ~fn:(fun s ->
                          Oasis_signals.record_success s ~latency_ms ~tokens:(String.length text / 4) (Oasis_signals.now_ms ()))
                      in
                      emit_task_done ~answer:text state ~request_id ~chosen:(Some nm) ~attempts:(List.length acc + 1) ~ok:true;
                      let attempt =
                        { Oasis_router.account = nm; model = nm; status = Some 200; error = None; latency_ms; cost_nano = 0 }
                      in
                      let decision' =
                        {
                          decision with
                          Oasis_router.chosen = Some nm;
                          Oasis_router.attempts = List.rev (attempt :: acc);
                        }
                      in
                      record_decision state decision';
                      Trail.json ctx (agent_result_json ~agent ~text)
                  | Error err when Option.is_some (cancel_reason_of err) ->
                      let reason = cancel_reason_of err |> Option.unwrap_or ~default:"user" in
                      let _ = Oasis_signals.update state.signals nm ~fn:Oasis_signals.release_in_flight in
                      let attempts = List.rev ({ Oasis_router.account = nm; model = nm; status = None; error = Some err; latency_ms; cost_nano = 0 } :: acc) in
                      record_decision state { decision with Oasis_router.attempts };
                      emit_task_done ~cancelled:true ~error:(cancel_text reason) state ~request_id ~chosen:None ~attempts:(List.length attempts) ~ok:false;
                      Trail.json
                        ~status:(Net.Http.Status.from_int 499)
                        ctx
                        (Json.obj [ ("error", Json.string err); ("message", Json.string (cancel_text reason)) ])
                  | Error err ->
                      let _ =
                        Oasis_signals.update state.signals nm ~fn:(fun s ->
                          Oasis_signals.record_failure s ~error:err (Oasis_signals.now_ms ()))
                      in
                      try_agents
                        ({ Oasis_router.account = nm; model = nm; status = None; error = Some err; latency_ms; cost_nano = 0 } :: acc)
                        rest
                )
          )
      in
      watch_task state ~request_id ();
      let r = try_agents [] candidates in
      unwatch_task state ~request_id;
      r
