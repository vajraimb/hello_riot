open Std
open Std.Collections

(** Decision ring buffer with [decisions.jsonl] persistence, and failure
    classification applied to account signals. *)

module Trail = Hello_riot.Trail
module Json = Std.Data.Json

open Portal_state
open Portal_ws
open Portal_upstream

(* ---------- decisions.jsonl (spec §6) ---------- *)

let decisions_keep = 1000

let decisions_file = fun (state : state) -> data_path state "decisions.jsonl"

let read_decision_lines = fun path ->
  match Path.from_string path with
  | Error _ -> []
  | Ok p -> (
      match Fs.read_to_string p with
      | Error _ -> []
      | Ok content ->
          String.split ~by:"\n" content |> List.filter ~fn:(fun l -> not (String.is_empty l))
    )

let drop_to_last = fun lines ~keep -> List.rev lines |> List.take ~len:keep |> List.rev

(** Rewrites the file with its newest [decisions_keep] lines and returns
    them, oldest first. *)
let compact_decisions = fun path ->
  let lines = read_decision_lines path |> drop_to_last ~keep:decisions_keep in
  (
    match Path.from_string path with
    | Error _ -> ()
    | Ok p ->
        let _ = Fs.write (String.concat "" (List.map lines ~fn:(fun l -> l ^ "\n"))) p in
        ()
  );
  lines

let append_decision = fun (state : state) (j : Json.t) ->
  let path = decisions_file state in
  (
    match Path.from_string path with
    | Error _ -> ()
    | Ok p -> (
        match Fs.File.open_append p with
        | Ok file ->
            let _ = Fs.File.write_all file (Json.to_string j ^ "\n") in
            let _ = Fs.File.close file in
            ()
        | Error _ -> ()
      )
  );
  let n = Sync.Atomic.get state.decisions_appended + 1 in
  if n >= decisions_keep then (
    let _ = compact_decisions path in
    Sync.Atomic.set state.decisions_appended 0
  ) else Sync.Atomic.set state.decisions_appended n

(** Decisions recorded by earlier runs, newest first, loaded at start. *)
let load_decision_history = fun (state : state) ->
  let lines = compact_decisions (decisions_file state) in
  let parsed = List.filter_map lines ~fn:(fun l -> Json.from_string l |> Result.to_option) in
  Sync.Atomic.set state.decision_history (List.rev parsed)

let record_decision = fun (state : state) (d : Portal_router.decision) ->
  let d =
    {
      d with
      Portal_router.attempts =
        List.map d.Portal_router.attempts ~fn:(fun (a : Portal_router.attempt) ->
          { a with Portal_router.error = Option.map a.Portal_router.error ~fn:Portal_signals.redact_secrets });
    }
  in
  let _ =
    Agent.get_and_update state.decisions ~fn:(fun ds ->
      append_decision state (Portal_router.decision_json d);
      ((), List.take (d :: ds) ~len:200))
  in
  broadcast_json
    state
    (Json.obj
      [
        ("type", Json.string "decision");
        ("decision", Portal_router.decision_json d);
      ]);
  ()

let recent_decisions = fun (state : state) ->
  Agent.get state.decisions ~fn:(fun ds -> ds)

(** Live decisions followed by persisted history from earlier runs. *)
let decisions_json = fun (state : state) ~limit ->
  let live = recent_decisions state |> List.map ~fn:Portal_router.decision_json in
  List.take (live @ Sync.Atomic.get state.decision_history) ~len:limit

(** Apply a failed upstream call to the account's signals according to its
    error class (spec §2.4.1). *)
let apply_failure = fun (state : state) (config : Portal_config.t) ~account ~status ~body ~err ->
  let quota_codes, reset =
    match Portal_config.find_account config account with
    | Some a -> (a.Portal_config.quota_error_codes, a.Portal_config.quota_reset)
    | None -> ([], "daily")
  in
  let cls = Portal_signals.classify_error ~status ~body ~quota_codes in
  let now = Portal_signals.now_ms () in
  let _ =
    Portal_signals.update state.signals account ~fn:(fun s ->
      match cls with
      | Portal_signals.Transient -> Portal_signals.record_failure s ~error:err now
      | Portal_signals.Quota ->
          Portal_signals.record_quota s ~error:err
            ~until_ms:(Portal_signals.quota_reset_at ~now_ms:now ~reset)
      | Portal_signals.Client { auth } -> Portal_signals.record_client_error s ~error:err ~auth)
  in
  (
    match cls with
    | Portal_signals.Quota -> Portal_signals.save_parked state.signals ~path:(parked_file state)
    | _ -> ()
  );
  cls
