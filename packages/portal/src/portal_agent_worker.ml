open Std
open Std.Collections

(** Agent task runner: executes an agent subprocess on a blocking lane and
    delivers the result back to the caller.

    NOTE (docs §16.20): OTP-style supervision was attempted here
    (Supervisor.Dynamic + long-lived worker actors) but this Riot version
    hangs on spawn-from-test-actor, shows invisible cross-actor
    ConcurrentHashMap state, and crashes (SIGSEGV) in the test harness.
    The portal keeps the simpler per-task blocking-lane execution, which is
    battle-tested; supervision is a documented follow-up. *)

type Message.t +=
  | Agent_call_result of (string, string) result
  | Agent_call_line of string

(** [on_line] runs in the caller's actor for every raw stdout line. *)
let run_task = fun ?on_line ~(name : string) ~(agent : Portal_agent.agent) ~model ~prompt ~timeout_s () ->
  let reply_to = self () in
  let forward =
    match on_line with
    | None -> fun (_ : string) -> ()
    | Some _ -> fun line -> send reply_to (Agent_call_line line)
  in
  let _ =
    Runtime.spawn_blocked (fun () ->
      let res = Portal_agent.collect ~on_line:forward ~agent ~model ~prompt () in
      send reply_to (Agent_call_result res);
      Ok ())
  in
  let selector msg =
    match msg with
    | Agent_call_result r -> Select (`Result r)
    | Agent_call_line l -> Select (`Line l)
    | _ -> Skip
  in
  let deadline_ms = Portal_signals.now_ms () + (max 60 (timeout_s + 60) * 1000) in
  let rec wait () =
    let left_ms = deadline_ms - Portal_signals.now_ms () in
    if left_ms <= 0 then Error ("agent watchdog timeout (" ^ name ^ ")")
    else
      match receive ~selector ~timeout:(Time.Duration.from_millis left_ms) () with
      | `Result res -> res
      | `Line l ->
          (match on_line with Some f -> f l | None -> ());
          wait ()
      | exception Receive_timeout -> Error ("agent watchdog timeout (" ^ name ^ ")")
  in
  wait ()

(** No-op kept for API symmetry. *)
let start = fun ~(agents : Portal_agent.agent list) () ->
  ignore agents;
  Ok ()
