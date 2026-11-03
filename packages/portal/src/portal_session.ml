open Std
open Std.Collections

(** Sticky session registry: pin a session_id to the account that served it,
    so multi-turn conversations keep their context on one account. Entries
    expire after [ttl] of inactivity; state lives in a shared map (ETS-style,
    survives actor restarts). *)

type entry = {
  account: string;
  last_access_ms: int;
}

type t = (string, entry) ConcurrentHashMap.t

let init = fun () -> ConcurrentHashMap.with_capacity ~size:64

let pin = fun (t : t) ~session ~account ~now_ms ->
  let _ = ConcurrentHashMap.insert t ~key:session ~value:{ account; last_access_ms = now_ms } in
  ()

(** Returns the pinned account if the session is known and fresh. *)
let lookup = fun (t : t) ~session ~now_ms ~ttl_ms ->
  match ConcurrentHashMap.get t ~key:session with
  | None -> None
  | Some entry ->
      if now_ms - entry.last_access_ms > ttl_ms then
        None
      else (
        let _ =
          ConcurrentHashMap.insert
            t
            ~key:session
            ~value:{ entry with last_access_ms = now_ms }
        in
        Some entry.account
      )

let remove = fun (t : t) ~session ->
  let _ = ConcurrentHashMap.remove t ~key:session in
  ()

let default_ttl_ms = 10 * 60 * 1000
