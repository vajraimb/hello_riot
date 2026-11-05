open Std
open Std.Collections

(** Sampled answer review: every [policy.judge_every]-th successful task is
    graded 1..5 by the [policy.judge] model, and the grade feeds the
    executor's learned quality (Oasis_quality). Runs in its own actor off
    the request path; a task served by the judge itself is never graded by
    it, the next eligible one is taken instead. *)

module Json = Std.Data.Json

open Oasis_state
open Oasis_ws
open Oasis_upstream

let system_prompt =
  "你是严格、公正的回答质量评审。只看回答是否准确、完整、切题、对提问者有用；不因篇幅长而加分，"
  ^ "事实错误或答非所问要重罚。只输出一行 JSON：{\"score\": 1 到 5 的整数, \"reason\": \"不超过 30 字的中文理由\"}"

(** "account" or "account:model". *)
let parse_judge = fun (spec : string) ->
  match String.index_of spec ~char:':' with
  | Some i -> (String.sub spec ~offset:0 ~len:i, Some (String.sub spec ~offset:(i + 1) ~len:(String.length spec - i - 1)))
  | None -> (spec, None)

(** Reads {"score": n, "reason": ".."} out of a reply that may wrap it in
    prose or a code fence. *)
let parse_verdict = fun (reply : string) ->
  let len = String.length reply in
  let rec first i = if i >= len then None else if String.get_unchecked reply ~at:i = '{' then Some i else first (i + 1) in
  let rec last i = if i < 0 then None else if String.get_unchecked reply ~at:i = '}' then Some i else last (i - 1) in
  match (first 0, last (len - 1)) with
  | (Some a, Some b) when b > a -> (
      match Json.from_string (String.sub reply ~offset:a ~len:(b - a + 1)) with
      | Ok j -> (
          match Json.get_field "score" j |> Option.and_then ~fn:Json.get_int with
          | Some s when s >= 1 && s <= 5 ->
              Some (s, Json.get_field "reason" j |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:"")
          | _ -> None)
      | Error _ -> None)
  | _ -> None

let review = fun (config : Oasis_config.t) ~judge ~(prompt : string) ~(answer : string) ->
  let (name, model_opt) = parse_judge judge in
  match Oasis_config.find_account config name with
  | None -> Error ("judge account not found: " ^ name)
  | Some acc when String.equal acc.Oasis_config.protocol "anthropic" -> Error "judge account must speak the openai protocol"
  | Some acc -> (
      let model =
        match model_opt with
        | Some m -> m
        | None -> List.head acc.Oasis_config.models |> Option.unwrap_or ~default:""
      in
      let messages =
        Json.array
          [
            Json.obj [ ("role", Json.string "system"); ("content", Json.string system_prompt) ];
            Json.obj
              [
                ("role", Json.string "user");
                ("content", Json.string ("【问题】\n" ^ Oasis_steps.clip prompt 6000 ^ "\n\n【回答】\n" ^ Oasis_steps.clip answer 12000));
              ];
          ]
      in
      let body = upstream_body ~model ~messages ~max_tokens:None ~stream:false () in
      let (scheme, host, port_opt, path_prefix) = parse_base_url acc.Oasis_config.base_url in
      let headers =
        ("Content-Type", "application/json") :: ("Host", host) :: ("Connection", "close")
        :: (match Oasis_config.api_key_of acc with Some k -> [ ("Authorization", "Bearer " ^ k) ] | None -> [])
      in
      match
        blocking_call ~connect_ip:acc.Oasis_config.connect_ip ~timeout_s:300 ~scheme ~host
          ~port:(port_opt |> Option.unwrap_or ~default:443)
          ~path:(chat_path_of ~protocol:acc.Oasis_config.protocol path_prefix)
          ~headers ~body ()
      with
      | Error e -> Error e
      | Ok (200, resp, _) -> (
          match parse_verdict (response_text resp) with
          | Some v -> Ok (name, v)
          | None -> Error "judge reply had no score")
      | Ok (status, _, _) -> Error ("judge http " ^ Int.to_string status)
    )

let grade = fun (state : state) ~judge (t : Oasis_feed.task) ->
  let config = Sync.Atomic.get state.config in
  match review config ~judge ~prompt:t.Oasis_feed.prompt ~answer:t.Oasis_feed.answer with
  | Error e -> eprintln ("[oasis] judge skipped " ^ t.Oasis_feed.id ^ ": " ^ e)
  | Ok (reviewer, (score, reason)) ->
      let category = if String.is_empty t.Oasis_feed.category then "general" else t.Oasis_feed.category in
      Oasis_quality.record state.quality ~account:t.Oasis_feed.executor ~category ~score:(Oasis_quality.of_review score);
      Oasis_quality.save state.quality ~path:(quality_file state);
      broadcast_event state ~type_:"task_rated" ~request_id:t.Oasis_feed.id
        ~data:
          (Json.obj
            [
              ("by", Json.string "judge");
              ("reviewer", Json.string reviewer);
              ("score", Json.int score);
              ("reason", Json.string reason);
              ("executor", Json.string t.Oasis_feed.executor);
            ])

let reviewable = fun (t : Oasis_feed.task) ->
  String.equal t.Oasis_feed.status "ok"
  && (not (String.is_empty t.Oasis_feed.executor))
  && (not (String.is_empty (String.trim t.Oasis_feed.answer)))
  && not (String.is_empty (String.trim t.Oasis_feed.prompt))

let start = fun (state : state) ->
  let seen : (string, unit) ConcurrentHashMap.t = ConcurrentHashMap.with_capacity ~size:256 in
  let due = ref 0 in
  let rec loop () =
    sleep (Time.Duration.from_secs 5);
    let policy = (Sync.Atomic.get state.config).Oasis_config.policy in
    let judge = policy.Oasis_config.judge in
    let every = policy.Oasis_config.judge_every in
    (
      if (not (String.is_empty judge)) && every > 0 then
        let (judge_account, _) = parse_judge judge in
        Oasis_feed.recent state.feed ~limit:50
        |> List.rev
        |> List.for_each ~fn:(fun (t : Oasis_feed.task) ->
          if reviewable t && Option.is_none (ConcurrentHashMap.get seen ~key:t.Oasis_feed.id) then (
            let _ = ConcurrentHashMap.insert seen ~key:t.Oasis_feed.id ~value:() in
            due := !due + 1;
            if !due >= every && not (String.equal t.Oasis_feed.executor judge_account) then (
              due := 0;
              grade state ~judge t
            )
          ))
    );
    loop ()
  in
  let _ = spawn (fun () -> loop ()) in
  ()
