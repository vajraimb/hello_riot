open Std
open Std.Collections

module Json = Std.Data.Json

(** Learned answer quality per (executor, category), from user ratings and
    sampled model reviews. Scores are 0..100. The static KB/agent fit acts as
    a prior worth [prior_weight] observations, so a handful of ratings nudge
    the fit and many ratings dominate it. *)

let prior_weight = 5

type stat = {
  sum: int;
  n: int;
}

type t = (string, stat) ConcurrentHashMap.t

let create = fun () : t -> ConcurrentHashMap.with_capacity ~size:64

let key = fun ~account ~category -> account ^ "|" ^ category

let get = fun (t : t) ~account ~category ->
  ConcurrentHashMap.get t ~key:(key ~account ~category) |> Option.unwrap_or ~default:{ sum = 0; n = 0 }

let add = fun (t : t) ~account ~category ~score ~weight ->
  let k = key ~account ~category in
  ConcurrentHashMap.compute t ~key:k ~fn:(fun cur ->
    let s = Option.unwrap_or cur ~default:{ sum = 0; n = 0 } in
    let s' = { sum = s.sum + (weight * score); n = s.n + weight } in
    if s'.n <= 0 then ConcurrentHashMap.Remove () else ConcurrentHashMap.Insert ({ s' with sum = max 0 s'.sum }, ()))

let record = fun (t : t) ~account ~category ~score -> add t ~account ~category ~score ~weight:1

(** Withdraws an earlier observation (a user changing their rating). *)
let unrecord = fun (t : t) ~account ~category ~score -> add t ~account ~category ~score ~weight:(-1)

let mean = fun (s : stat) -> if s.n <= 0 then 0 else s.sum / s.n

(** Static fit blended with what was observed. *)
let blend = fun ~static (s : stat) ->
  if s.n <= 0 then static else ((static * prior_weight) + s.sum) / (prior_weight + s.n)

(** User 👍 / 👎 as a score. *)
let of_rating = fun r -> if r > 0 then 100 else 0

(** Reviewer 1..5 as a score. *)
let of_review = fun s -> (min 5 (max 1 s) - 1) * 25

let save = fun (t : t) ~path ->
  let entries = ref [] in
  ConcurrentHashMap.for_each t ~fn:(fun k s ->
    entries := (k, Json.array [ Json.int s.sum; Json.int s.n ]) :: !entries);
  match Path.from_string path with
  | Error _ -> ()
  | Ok p ->
      let _ = Fs.write (Json.to_string (Json.obj !entries)) p in
      ()

let load = fun (t : t) ~path ->
  match Path.from_string path with
  | Error _ -> ()
  | Ok p -> (
      match Fs.read_to_string p with
      | Error _ -> ()
      | Ok content -> (
          match Json.from_string content |> Result.to_option |> Option.and_then ~fn:Json.get_object with
          | None -> ()
          | Some fields ->
              List.for_each fields ~fn:(fun (k, v) ->
                match Json.get_array v |> Option.map ~fn:(List.filter_map ~fn:Json.get_int) with
                | Some [ sum; n ] when n > 0 ->
                    let _ = ConcurrentHashMap.insert t ~key:k ~value:{ sum; n } in
                    ()
                | _ -> ())
        )
    )
