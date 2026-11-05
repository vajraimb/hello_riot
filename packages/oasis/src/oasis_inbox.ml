open Std
open Std.Collections

(** Agent message bus: every agent has an inbox; agents deliver messages to
    each other and to the user through Oasis (Reason-Network-style, but
    centralized in Oasis and persisted to JSONL). *)

type entry = {
  id: string;
  from: string;
  to_agent: string;
  text: string;
  ts_ms: int;
  read: bool;
  truncated: bool;
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
  Oasis_signals.now_ms ()

module Json = Std.Data.Json

(** Inbox texts are capped so one agent can't flood another's context. *)
let max_text_bytes = 16 * 1024

(** Agent names become file names under [dir]. *)
let valid_name = fun name ->
  let ok_char c =
    match c with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> true
    | _ -> false
  in
  if String.is_empty name then false
  else if String.length name > 64 then false
  else if String.starts_with ~prefix:"." name then false
  else
    let rec all i = if i >= String.length name then true else if ok_char (String.get_unchecked name ~at:i) then all (i + 1) else false in
    all 0

(** Longest prefix of [s] of at most [max] bytes that doesn't split a UTF-8
    sequence. *)
let utf8_truncate = fun s ~max ->
  if String.length s <= max then s
  else
    let is_cont i = Char.code (String.get_unchecked s ~at:i) land 0xC0 = 0x80 in
    let rec back i = if i > 0 then if is_cont i then back (i - 1) else i else 0 in
    String.sub s ~offset:0 ~len:(back max)

(** What an agent sees when it reads its inbox: the sender is asserted by
    whoever called [oasis_send_message], so it is labelled as unverified. *)
let render_for_agent = fun (e : entry) ->
  "[来自 " ^ e.from ^ "，未经验证的消息] " ^ e.text
  ^ if e.truncated then "\n[Oasis: 消息超过 16KB，已截断]" else ""

let append_line = fun (t : t) ~agent line ->
  let path = t.dir ^ "/" ^ agent ^ ".jsonl" in
  match Fs.File.open_append (Path.from_string path |> Result.unwrap) with
  | Ok file -> (
      match Fs.File.write_all file (line ^ "\n") with
      | Ok () -> (match Fs.File.close file with _ -> ())
      | Error _ -> ()
    )
  | Error _ -> ()

(** Persist one message line to the agent's jsonl file (append-only). *)
let persist = fun (t : t) ~(e : entry) ->
  append_line t ~agent:e.to_agent
    (Json.to_string
      (Json.obj
        [
          ("id", Json.string e.id);
          ("from", Json.string e.from);
          ("to", Json.string e.to_agent);
          ("text", Json.string e.text);
          ("ts_ms", Json.int e.ts_ms);
          ("read", Json.bool e.read);
          ("truncated", Json.bool e.truncated);
        ]))

(** Deliver a message into [to_agent]'s inbox; returns the message id. *)
let deliver = fun (t : t) ~from ~to_agent ~text ->
  if not (valid_name to_agent) then Error ("invalid recipient name: " ^ to_agent)
  else
    let kept = utf8_truncate text ~max:max_text_bytes in
    let e =
      {
        id = new_id ();
        from;
        to_agent;
        text = kept;
        ts_ms = now_ms ();
        read = false;
        truncated = String.length kept < String.length text;
      }
    in
    let _ =
      ConcurrentHashMap.insert
        t.boxes
        ~key:to_agent
        ~value:(e :: (ConcurrentHashMap.get t.boxes ~key:to_agent |> Option.unwrap_or ~default:[]))
    in
    persist t ~e;
    Ok e.id

(** Read (and mark read) all messages for an agent, newest first. Read marks
    are appended as [{"read_at", "id"}] lines and replayed by [load]. *)
let check = fun (t : t) ~agent ->
  let entries =
    ConcurrentHashMap.get t.boxes ~key:agent |> Option.unwrap_or ~default:[]
  in
  let unread = List.filter entries ~fn:(fun e -> not e.read) in
  let all =
    List.map entries ~fn:(fun e -> if e.read then e else { e with read = true })
  in
  let _ = ConcurrentHashMap.insert t.boxes ~key:agent ~value:all in
  if valid_name agent then (
    let at = now_ms () in
    List.for_each unread ~fn:(fun e ->
      append_line t ~agent (Json.to_string (Json.obj [ ("id", Json.string e.id); ("read_at", Json.int at) ])))
  );
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
              let read_ids =
                List.filter_map lines ~fn:(fun line ->
                  match Json.from_string line with
                  | Ok j when Option.is_some (Json.get_field "read_at" j) ->
                      Json.get_field "id" j |> Option.and_then ~fn:Json.get_string
                  | _ -> None)
              in
              let was_read id = List.any read_ids ~fn:(String.equal id) in
              let parsed =
                List.filter_map lines ~fn:(fun line ->
                  if String.is_empty line then None
                  else
                    match Std.Data.Json.from_string line with
                    | Error _ -> None
                    | Ok j when Option.is_some (Json.get_field "read_at" j) -> None
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
                            read = get_bool "read" || was_read (get_str "id");
                            truncated = get_bool "truncated";
                          })
                |> List.rev
              in
              let agent = String.sub name ~offset:0 ~len:(String.length name - 6) in
              let _ = ConcurrentHashMap.insert t.boxes ~key:agent ~value:parsed in
              ()
        ) else
          ()
      )
