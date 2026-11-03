open Std
open Std.Collections

(** Async task registry: long-running agent tasks get a task_id immediately
    and their result is stored here for polling via oasis_task_status. *)

type status =
  | Running
  | Done of string
  | Failed of string

type t = (string, status) ConcurrentHashMap.t

let init = fun () -> ConcurrentHashMap.with_capacity ~size:64

let status_of_string = fun s ->
  match s with
  | "running" -> "running"
  | "done" -> "done"
  | "failed" -> "failed"
  | _ -> "unknown"

let insert = fun (t : t) ~task_id -> ConcurrentHashMap.insert t ~key:task_id ~value:Running

let set = fun (t : t) ~task_id ~status ->
  ConcurrentHashMap.insert t ~key:task_id ~value:status

let get = fun (t : t) ~task_id -> ConcurrentHashMap.get t ~key:task_id

(** Short unique id: random hex pairs. *)
let new_id = fun () ->
  let pick bound =
    match Random.int bound with
    | Ok v -> v
    | Error _ -> 0
  in
  "task-" ^ Int.to_string (pick 1000000000) ^ "-" ^ Int.to_string (pick 1000000)
