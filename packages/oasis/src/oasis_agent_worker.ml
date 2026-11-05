open Std
open Std.Collections

(** Agent task runner: executes an agent subprocess on a blocking lane and
    delivers the result back to the caller.

    NOTE (docs §16.20): OTP-style supervision was attempted here
    (Supervisor.Dynamic + long-lived worker actors) but this Riot version
    hangs on spawn-from-test-actor, shows invisible cross-actor
    ConcurrentHashMap state, and crashes (SIGSEGV) in the test harness.
    Oasis keeps the simpler per-task blocking-lane execution, which is
    battle-tested; supervision is a documented follow-up. *)

type Message.t +=
  | Agent_call_result of (string, string) result
  | Agent_call_line of string
  | Agent_call_spawned of Process.t

(** [on_line] runs in the caller's actor for every raw stdout line. Waits
    for the agent to finish; a [Oasis_state.Task_cancel] sent to the caller
    kills the subprocess tree and returns [Oasis_state.cancel_error]. *)
let run_task = fun ?on_line ~(name : string) ~(agent : Oasis_agent.agent) ~model ~prompt () ->
  ignore name;
  let reply_to = self () in
  let forward =
    match on_line with
    | None -> fun (_ : string) -> ()
    | Some _ -> fun line -> send reply_to (Agent_call_line line)
  in
  let _ =
    Runtime.spawn_blocked (fun () ->
      let res =
        Oasis_agent.collect ~on_line:forward ~on_spawn:(fun p -> send reply_to (Agent_call_spawned p)) ~agent ~model ~prompt ()
      in
      send reply_to (Agent_call_result res);
      Ok ())
  in
  let proc = ref None in
  let selector msg =
    match msg with
    | Agent_call_result r -> Select (`Result r)
    | Agent_call_line l -> Select (`Line l)
    | Agent_call_spawned p -> Select (`Spawned p)
    | Oasis_state.Task_cancel reason -> Select (`Cancel reason)
    | _ -> Skip
  in
  let rec wait () =
    match receive ~selector () with
    | `Result res -> res
    | `Spawned p ->
        proc := Some p;
        wait ()
    | `Line l ->
        (match on_line with Some f -> f l | None -> ());
        wait ()
    | `Cancel reason ->
        (match !proc with
         | Some p -> ignore (Runtime.spawn_blocked (fun () -> Oasis_agent.kill_group p; Ok ()))
         | None -> ());
        Error (Oasis_state.cancel_error reason)
  in
  wait ()

(** No-op kept for API symmetry. *)
let start = fun ~(agents : Oasis_agent.agent list) () ->
  ignore agents;
  Ok ()
