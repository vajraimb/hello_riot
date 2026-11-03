open Std
open Std.Collections

(** Agent message bus: every agent has an inbox; agents deliver messages to
    each other and to the user through the portal (Reason-Network-style, but
    centralized in Oasis and persisted to JSONL). *)

type entry = {
  id: string;
  from: string;
  to_agent: string;
  text: string;
  ts_ms: int;
  read: bool;
}

type t = {
  dir: string;
  (* agent -> entries (newest first) *)
  boxes: (string, entry list) ConcurrentHashMap.t;
}

let init = fun ~dir ->
  let _ = Fs.create_dir_all (Path.from_string dir |> Result.unwrap) in
  { dir; boxes = ConcurrentHashMap.with_capacity ~size:64 }

let new_id = fun () ->
  let pick bound =
    match Random.int bound with
    | Ok v -> v
    | Error _ -> 0
  in
  "msg-" ^ Int.to_string (pick 1000000000) ^ "-" ^ Int.to_string (pick 1000000)

let now_ms = fun () ->
  (* std Instant has no epoch; use the signals monotonic-ish counter as an
     ordering key and store real wall-clock-ish ordering via seq *)
  Portal_signals.now_ms ()

(** Persist one message line to the agent's jsonl file (append-only). *)
let persist = fun (t : t) ~(e : entry) ->
  let path = t.dir ^ "/" ^ e.to_agent ^ ".jsonl" in
  let line =
    Std.Data.Json.to_string
      (Std.Data.Json.obj
        [
          ("id", Std.Data.Json.string e.id);
          ("from", Std.Data.Json.string e.from);
          ("to", Std.Data.Json.string e.to_agent);
          ("text", Std.Data.Json.string e.text);
          ("ts_ms", Std.Data.Json.int e.ts_ms);
          ("read", Std.Data.Json.bool e.read);
        ])
    ^ "\n"
  in
  match Fs.File.open_append (Path.from_string path |> Result.unwrap) with
  | Ok file -> (
      match Fs.File.write_all file line with
      | Ok () -> (match Fs.File.close file with _ -> ())
      | Error _ -> ()
    )
  | Error _ -> ()

(** Deliver a message into [to_agent]'s inbox. *)
let deliver = fun (t : t) ~from ~to_agent ~text ->
  let e = { id = new_id (); from; to_agent; text; ts_ms = now_ms (); read = false } in
  let _ =
    ConcurrentHashMap.insert
      t.boxes
      ~key:to_agent
      ~value:(e :: (ConcurrentHashMap.get t.boxes ~key:to_agent |> Option.unwrap_or ~default:[]))
  in
  persist t ~e;
  e.id

(** Read (and mark read) all messages for an agent, newest first. *)
let check = fun (t : t) ~agent ->
  let entries =
    ConcurrentHashMap.get t.boxes ~key:agent |> Option.unwrap_or ~default:[]
  in
  let unread = List.filter entries ~fn:(fun e -> not e.read) in
  (* mark read in memory (persistence is append-only; a full rewrite on
     check would be overkill for a personal portal) *)
  let all =
    List.map entries ~fn:(fun e -> if e.read then e else { e with read = true })
  in
  let _ = ConcurrentHashMap.insert t.boxes ~key:agent ~value:all in
  unread

let pending_count = fun (t : t) ~agent ->
  ConcurrentHashMap.get t.boxes ~key:agent
  |> Option.unwrap_or ~default:[]
  |> List.fold_left ~init:0 ~fn:(fun acc e -> if e.read then acc else acc + 1)

(** Load history from disk into memory (called at startup). *)
let load = fun (t : t) ->
  match Fs.read_dir (Path.from_string t.dir |> Result.unwrap) with
  | Error _ -> ()
  | Ok entries ->
      let entries = Iter.MutIterator.to_list entries in
      List.for_each entries ~fn:(fun entry_path ->
        let name = Path.basename entry_path in
        if String.ends_with ~suffix:".jsonl" name then (
          match Fs.read_to_string (Path.from_string (t.dir ^ "/" ^ name) |> Result.unwrap) with
          | Error _ -> ()
          | Ok content ->
              let lines = String.split ~by:"\n" content in
              let parsed =
                List.filter_map lines ~fn:(fun line ->
                  if String.is_empty line then None
                  else
                    match Std.Data.Json.from_string line with
                    | Error _ -> None
                    | Ok j ->
                        let get_str k =
                          Std.Data.Json.get_field k j
                          |> Option.and_then ~fn:Std.Data.Json.get_string
                          |> Option.unwrap_or ~default:""
                        in
                        let get_bool k =
                          Std.Data.Json.get_field k j
                          |> Option.and_then ~fn:Std.Data.Json.get_bool
                          |> Option.unwrap_or ~default:false
                        in
                        let get_int k =
                          Std.Data.Json.get_field k j
                          |> Option.and_then ~fn:Std.Data.Json.get_int
                          |> Option.unwrap_or ~default:0
                        in
                        Some
                          {
                            id = get_str "id";
                            from = get_str "from";
                            to_agent = get_str "to";
                            text = get_str "text";
                            ts_ms = get_int "ts_ms";
                            read = get_bool "read";
                          })
                |> List.rev
              in
              let agent = String.sub name ~offset:0 ~len:(String.length name - 6) in
              let _ = ConcurrentHashMap.insert t.boxes ~key:agent ~value:parsed in
              ()
        ) else
          ()
      )
