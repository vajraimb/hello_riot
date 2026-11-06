open Std
open Std.Collections

(** Committee mode: the same question goes to 2–3 chosen members in parallel.
    A member is an API account or a local agent. Each answer lands on the
    task timeline as it arrives, then the router picks one model to write a
    synthesis. The reply is the synthesis followed by every member's own
    answer. *)

module Trail = Oasis_net.Trail
module Json = Std.Data.Json

open Oasis_state
open Oasis_ws
open Oasis_upstream
open Oasis_decisions

let min_members = 2

let max_members = 3

(** ["a, b,a"] → [["a"; "b"]] *)
let parse_members = fun (header : string) ->
  String.split_on_char ',' header
  |> List.map ~fn:String.trim
  |> List.filter ~fn:(fun s -> not (String.is_empty s))
  |> List.fold_left ~init:[] ~fn:(fun acc m -> if List.any acc ~fn:(String.equal m) then acc else acc @ [ m ])

type Message.t +=
  | Committee_agent_result of (string, string) result
  | Committee_agent_spawned of Process.t

(** Runs an agent without forwarding each stdout line back to this actor.
    Line-by-line forwarding fills the mailbox, the reader stops, and the
    CLI blocks once its stdout pipe is full. *)
let run_agent = fun ~agent ~model ~prompt ->
  let reply_to = self () in
  let _ =
    Runtime.spawn_blocked (fun () ->
      let res =
        Oasis_agent.collect
          ~on_spawn:(fun p -> send reply_to (Committee_agent_spawned p))
          ~agent
          ~model
          ~prompt
          ()
      in
      send reply_to (Committee_agent_result res);
      Ok ())
  in
  let proc = ref None in
  let selector msg =
    match msg with
    | Committee_agent_result r -> Select (`Result r)
    | Committee_agent_spawned p -> Select (`Spawned p)
    | Task_cancel reason -> Select (`Cancel reason)
    | _ -> Skip
  in
  let rec wait () =
    match receive ~selector () with
    | `Result res -> res
    | `Spawned p ->
        proc := Some p;
        wait ()
    | `Cancel reason ->
        (match !proc with
         | Some p -> ignore (Runtime.spawn_blocked (fun () -> Oasis_agent.kill_group p; Ok ()))
         | None -> ());
        Error (cancel_error reason)
  in
  wait ()

type seat =
  | Seat_account of Oasis_config.account
  | Seat_agent of Oasis_agent.agent

let seat_key = fun seat ->
  match seat with
  | Seat_account a -> "account:" ^ a.Oasis_config.name
  | Seat_agent a -> "agent:" ^ a.Oasis_agent.name

(** Shown in the answer and on the timeline. Agents are marked so a summary
    can tell them apart from an account of the same name. *)
let seat_label = fun seat ->
  match seat with
  | Seat_account a -> a.Oasis_config.name
  | Seat_agent a -> a.Oasis_agent.name ^ "（agent）"

let drop_prefix = fun s prefix ->
  if String.starts_with ~prefix s then
    let n = String.length prefix in
    Some (String.sub s ~offset:n ~len:(String.length s - n))
  else None

let find_agent = fun (config : Oasis_config.t) name ->
  List.find config.Oasis_config.agents ~fn:(fun a -> String.equal a.Oasis_agent.name name)

let account_seat = fun (config : Oasis_config.t) name ->
  match Oasis_config.find_account config name with
  | Some a when a.Oasis_config.enabled -> Ok (Seat_account a)
  | Some _ -> Error "disabled"
  | None -> Error "missing"

let agent_seat = fun (config : Oasis_config.t) name ->
  match find_agent config name with
  | Some a when a.Oasis_agent.enabled -> Ok (Seat_agent a)
  | Some _ -> Error "disabled"
  | None -> Error "missing"

(** [agent:name] and [account:name] pick a kind. A bare name is an account
    when one exists, otherwise an agent. *)
let resolve_member = fun (config : Oasis_config.t) token ->
  match drop_prefix token "agent:" with
  | Some name when not (String.is_empty name) -> agent_seat config name
  | Some _ -> Error "missing"
  | None -> (
      match drop_prefix token "account:" with
      | Some name when not (String.is_empty name) -> account_seat config name
      | Some _ -> Error "missing"
      | None -> (
          match Oasis_config.find_account config token with
          | Some a when a.Oasis_config.enabled -> Ok (Seat_account a)
          | Some _ -> Error "disabled"
          | None -> agent_seat config token))

(** One non-stream call to one account, outside routing and fallback;
    signals and the ledger are updated like any attempt. *)
let call_account = fun (state : state) (config : Oasis_config.t) ~(name : string) ~(messages : Json.t) ->
  match Oasis_config.find_account config name with
  | None -> Error "unknown_account"
  | Some account -> (
      let model = List.head account.Oasis_config.models |> Option.unwrap_or ~default:"" in
      let anthropic = String.equal account.Oasis_config.protocol "anthropic" in
      let auth_headers =
        match Oasis_config.api_key_of account with
        | Some k ->
            if anthropic then [ ("x-api-key", k); ("anthropic-version", "2023-06-01") ]
            else [ ("Authorization", "Bearer " ^ k) ]
        | None -> []
      in
      let req_body =
        if anthropic then
          Oasis_anthropic.to_request ~thinking:account.Oasis_config.thinking ~model ~messages
            ~max_tokens:(anthropic_max_tokens config ~model None) ~stream:false
        else upstream_body ~model ~messages ~max_tokens:None ~stream:false ()
      in
      let (scheme, host, port_opt, path_prefix) = parse_base_url account.Oasis_config.base_url in
      let headers = ("Content-Type", "application/json") :: ("Host", host) :: ("Connection", "close") :: auth_headers in
      let _ = Oasis_signals.update state.signals name ~fn:Oasis_signals.mark_in_flight in
      match
        blocking_call ~connect_ip:account.Oasis_config.connect_ip ~scheme ~host
          ~port:(port_opt |> Option.unwrap_or ~default:443)
          ~path:(chat_path_of ~protocol:account.Oasis_config.protocol path_prefix)
          ~headers ~body:req_body ()
      with
      | Error err when Option.is_some (cancel_reason_of err) ->
          let _ = Oasis_signals.update state.signals name ~fn:Oasis_signals.release_in_flight in
          Error err
      | Error err ->
          let _ = apply_failure state config ~account:name ~status:None ~body:"" ~err in
          Error err
      | Ok (200, resp, latency_ms) ->
          let conv = if anthropic then Oasis_anthropic.from_response resp |> Json.to_string else resp in
          let (in_t, out_t, cache_t) = extract_usage conv in
          let cost = cost_of config name model in_t out_t cache_t in
          Oasis_ledger.record state.ledger ~account:name ~model ~in_tokens:in_t ~out_tokens:out_t ~cache_tokens:cache_t
            ~cost_nano:cost ~latency_ms ~status:"ok" ();
          let text = response_text conv in
          if String.is_empty (String.trim text) then (
            let _ = Oasis_signals.update state.signals name ~fn:(Oasis_signals.record_latency ~latency_ms) in
            Error "empty_answer"
          ) else (
            let _ =
              Oasis_signals.update state.signals name ~fn:(fun s ->
                Oasis_signals.record_success s ~latency_ms ~tokens:(in_t + out_t) (Oasis_signals.now_ms ()))
            in
            Ok (text, latency_ms)
          )
      | Ok (status, resp, _) ->
          let err = "upstream_http_" ^ Int.to_string status ^ ": " ^ Oasis_steps.clip resp 300 in
          let _ = apply_failure state config ~account:name ~status:(Some status) ~body:resp ~err in
          Error err
    )

(** One headless agent run. An agent with no workdir of its own gets a
    private directory under the conversation, so parallel members do not
    share a tree and nothing is written into the gateway's directory. *)
let call_agent = fun (state : state) (config : Oasis_config.t) ~workspace ~body (agent : Oasis_agent.agent) ->
  let placed =
    if not (String.is_empty agent.Oasis_agent.workdir) then Ok agent
    else
      let id = workspace ^ "-" ^ agent.Oasis_agent.name in
      match Oasis_workspace.prepare config ~id with
      | Ok dir -> Ok { agent with Oasis_agent.workdir = dir }
      | Error e -> Error e
  in
  match placed with
  | Error e -> Error e
  | Ok agent ->
      let name = agent.Oasis_agent.name in
      let _ = Oasis_signals.update state.signals name ~fn:Oasis_signals.mark_in_flight in
      let t0 = Time.Instant.now () in
      let model = List.head agent.Oasis_agent.models |> Option.unwrap_or ~default:"" in
      let prompt = Oasis_exec_agent.agent_prompt_of_body body in
      match run_agent ~agent ~model ~prompt with
      | Error err when Option.is_some (cancel_reason_of err) ->
          let _ = Oasis_signals.update state.signals name ~fn:Oasis_signals.release_in_flight in
          Error err
      | Error err ->
          let _ =
            Oasis_signals.update state.signals name ~fn:(fun s ->
              Oasis_signals.record_failure s ~error:err (Oasis_signals.now_ms ()))
          in
          Error err
      | Ok text ->
          let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed t0) in
          if String.is_empty (String.trim text) then (
            let _ = Oasis_signals.update state.signals name ~fn:(Oasis_signals.record_latency ~latency_ms) in
            Error "empty_answer"
          ) else (
            let _ =
              Oasis_signals.update state.signals name ~fn:(fun s ->
                Oasis_signals.record_success s ~latency_ms ~tokens:(String.length text / 4) (Oasis_signals.now_ms ()))
            in
            Ok (text, latency_ms)
          )

let call_seat = fun (state : state) (config : Oasis_config.t) ~workspace ~body seat ->
  match seat with
  | Seat_account account ->
      let messages = Json.get_field "messages" body |> Option.unwrap_or ~default:(Json.array []) in
      call_account state config ~name:account.Oasis_config.name ~messages
  | Seat_agent agent -> call_agent state config ~workspace ~body agent

let synthesis_prompt = fun ~(question : string) (answers : (string * string) list) ->
  "下面是 " ^ Int.to_string (List.length answers) ^ " 位 AI 对同一个问题的回答。请你作为主持人写一份汇总：先给出综合结论，"
  ^ "再分别列出各方共识、主要分歧（标明是谁的观点）和各自独到之处；发现明显错误要指出。不要逐段复述原文，不要加总标题（外层已有），小节用加粗短语而不是 # 标题，用问题的语言作答。\n\n"
  ^ "【问题】\n" ^ Oasis_steps.clip question 6000 ^ "\n\n"
  ^ String.concat "\n\n" (List.map answers ~fn:(fun (name, text) -> "【" ^ name ^ " 的回答】\n" ^ Oasis_steps.clip text 12000))

let completion_json = fun ~request_id ~(content : string) (extra : (string * Json.t) list) ->
  Json.obj
    ([
       ("id", Json.string ("chatcmpl-" ^ request_id));
       ("object", Json.string "chat.completion");
       ("model", Json.string "oasis-committee");
       (
         "choices",
         Json.array
           [
             Json.obj
               [
                 ("index", Json.int 0);
                 ("message", Json.obj [ ("role", Json.string "assistant"); ("content", Json.string content) ]);
                 ("finish_reason", Json.string "stop");
               ];
           ]
       );
     ]
    @ extra)

let handle = fun (state : state) (ctx : Trail.ctx) (body : Json.t) ~(members : string list) ~(category : string)
    ~(goal : Oasis_router.goal) ~(request_id : string) ~(workspace : string) ->
  let config = Sync.Atomic.get state.config in
  let reject msg =
    emit_task_done ~error:msg state ~request_id ~chosen:None ~attempts:0 ~ok:false;
    Trail.json ~status:Net.Http.Status.BadRequest ctx (Json.obj [ ("error", Json.string msg) ])
  in
  let resolved = List.map members ~fn:(fun token -> (token, resolve_member config token)) in
  let unusable = List.filter_map resolved ~fn:(fun (token, r) -> match r with Error _ -> Some token | Ok _ -> None) in
  let seats =
    List.fold_left resolved ~init:[] ~fn:(fun acc (token, r) ->
      match r with
      | Error _ -> acc
      | Ok seat ->
          if List.any acc ~fn:(fun (_, s) -> String.equal (seat_key s) (seat_key seat)) then acc
          else acc @ [ (token, seat) ])
  in
  let n = List.length members in
  if n < min_members || n > max_members then reject "委员会需要 2–3 个不同的成员"
  else if not (List.is_empty unusable) then reject ("这些成员不存在或已停用：" ^ String.concat "、" unusable)
  else if List.length seats < min_members then reject "委员会需要 2–3 个不同的成员"
  else (
    let n = List.length seats in
    let tokens = List.map seats ~fn:(fun (token, _) -> token) in
    broadcast_event state ~type_:"committee_started" ~request_id
      ~data:(Json.obj [ ("members", Json.array (List.map tokens ~fn:Json.string)) ]);
    let parent = self () in
    let kids = ref [] in
    List.enumerate seats
    |> List.for_each ~fn:(fun (i, (_, seat)) ->
      emit_attempt_started state ~request_id ~account:(seat_label seat);
      let pid = spawn (fun () -> send parent (Committee_answer (i, call_seat state config ~workspace ~body seat)); Ok ()) in
      kids := pid :: !kids;
      ());
    let selector msg =
      match msg with
      | Committee_answer (i, r) -> Select (`Answer (i, r))
      | Task_cancel reason -> Select (`Cancel reason)
      | _ -> Skip
    in
    let cancelled = ref None in
    let rec collect acc remaining =
      if remaining = 0 then acc
      else
        match receive ~selector () with
        | `Cancel reason ->
            List.for_each !kids ~fn:(fun pid -> send pid (Task_cancel reason));
            cancelled := Some reason;
            acc
        | `Answer (i, r) ->
            let _, seat = List.get_unchecked seats ~at:i in
            let name = seat_label seat in
            (
              match r with
              | Ok (text, latency_ms) ->
                  emit_attempt_finished state ~request_id ~account:name ~status:(Some 200) ~latency_ms ~error:None;
                  broadcast_event state ~type_:"committee_member" ~request_id
                    ~data:(Json.obj [ ("account", Json.string name); ("ok", Json.bool true); ("text", Json.string text); ("latency_ms", Json.int latency_ms) ])
              | Error e ->
                  emit_attempt_finished state ~request_id ~account:name ~status:None ~latency_ms:0 ~error:(Some e);
                  broadcast_event state ~type_:"committee_member" ~request_id
                    ~data:(Json.obj [ ("account", Json.string name); ("ok", Json.bool false); ("error", Json.string e) ])
            );
            collect ((i, r) :: acc) (remaining - 1)
    in
    watch_task state ~request_id ();
    let results = collect [] n in
    let per_member =
      List.enumerate seats
      |> List.map ~fn:(fun (i, (_, seat)) ->
        let name = seat_label seat in
        ( name,
          List.find results ~fn:(fun (j, _) -> j = i)
          |> Option.map ~fn:(fun (_, r) -> r)
          |> Option.unwrap_or ~default:(Error "超时未作答") ))
    in
    let answered = List.filter_map per_member ~fn:(fun (name, r) -> match r with Ok (t, _) -> Some (name, t) | Error _ -> None) in
    let sections =
      List.map per_member ~fn:(fun (name, r) ->
        match r with
        | Ok (t, _) -> "## " ^ name ^ "\n\n" ^ t
        | Error e -> "## " ^ name ^ "\n\n（未能作答：" ^ Oasis_feed.error_text e ^ "）")
      |> String.concat "\n\n"
    in
    let members_json =
      Json.array
        (List.map per_member ~fn:(fun (name, r) ->
          Json.obj [ ("account", Json.string name); ("ok", Json.bool (match r with Ok _ -> true | Error _ -> false)) ]))
    in
    let cancelled_reply reason =
      unwatch_task state ~request_id;
      emit_task_done ~cancelled:true ~error:(cancel_text reason) ~answer:sections state ~request_id ~chosen:None ~attempts:n ~ok:false;
      Trail.json ~status:(Net.Http.Status.from_int 499) ctx
        (Json.obj [ ("error", Json.string (cancel_error reason)); ("message", Json.string (cancel_text reason)); ("members", members_json) ])
    in
    match answered with
    | _ when Option.is_some !cancelled -> cancelled_reply (Option.unwrap_or !cancelled ~default:"user")
    | [] ->
        unwatch_task state ~request_id;
        let msg = "委员会成员都没能作答" in
        emit_task_done ~error:msg state ~request_id ~chosen:None ~attempts:n ~ok:false;
        Trail.json ~status:Net.Http.Status.BadGateway ctx (Json.obj [ ("error", Json.string msg); ("members", members_json) ])
    | [ (only, _) ] ->
        unwatch_task state ~request_id;
        let content = "只有 " ^ only ^ " 给出了回答，无需汇总。\n\n" ^ sections in
        emit_task_done ~answer:content state ~request_id ~chosen:(Some only) ~attempts:n ~ok:true;
        Trail.json ctx (completion_json ~request_id ~content [ ("oasis", Json.obj [ ("members", members_json) ]) ])
    | _ ->
        let question = Oasis_feed.last_user_text body in
        let prompt = synthesis_prompt ~question answered in
        let task =
          { Oasis_router.category = "analysis"; model = None; est_in_tokens = String.length prompt / 3; est_out_tokens = 2048 }
        in
        let decision = Oasis_router.route_scored config (make_lookups state) ~goal task in
        emit_routed state ~request_id ~mode:"committee" decision;
        let candidates = match decision.Oasis_router.chosen with Some c -> c :: decision.Oasis_router.fallback_order | None -> [] in
        let synth_messages = Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string prompt) ] ] in
        let rec synthesize = function
          | [] -> None
          | name :: rest -> (
              emit_attempt_started state ~request_id ~account:name;
              match call_account state config ~name ~messages:synth_messages with
              | Ok (text, latency_ms) ->
                  emit_attempt_finished state ~request_id ~account:name ~status:(Some 200) ~latency_ms ~error:None;
                  Some (name, text)
              | Error e when Option.is_some (cancel_reason_of e) ->
                  emit_attempt_finished state ~request_id ~account:name ~status:None ~latency_ms:0 ~error:(Some e);
                  cancelled := cancel_reason_of e;
                  None
              | Error e ->
                  emit_attempt_finished state ~request_id ~account:name ~status:None ~latency_ms:0 ~error:(Some e);
                  synthesize rest)
        in
        let summary = synthesize candidates in
        unwatch_task state ~request_id;
        match !cancelled with
        | Some reason -> cancelled_reply reason
        | None ->
        let (chosen, content) =
          match summary with
          | Some (s, text) -> (s, "## 汇总（" ^ s ^ "）\n\n" ^ text ^ "\n\n---\n\n" ^ sections)
          | None ->
              let first = match answered with (name, _) :: _ -> name | [] -> "committee" in
              (first, "（汇总失败：没有可用的汇总模型，以下为各家原文）\n\n" ^ sections)
        in
        emit_task_done ~answer:content state ~request_id ~chosen:(Some chosen) ~attempts:(n + 1) ~ok:true;
        Trail.json ctx
          (completion_json ~request_id ~content
             [ ("oasis", Json.obj [ ("members", members_json); ("summarizer", Json.string chosen) ]) ])
  )
