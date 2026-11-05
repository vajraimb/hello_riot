open Std
open Std.Collections

module Json = Std.Data.Json

(** Activity aggregation: parse local Claude Code session files (read-only)
    into a unified timeline of what each agent has been doing — the
    AIUsage-Session-Center idea. v1 covers Claude Code jsonl sessions. *)

type session_summary = {
  project: string;
  session_id: string;
  last_ts: float;
  turns: int;
  tools: int;
  last_excerpt: string;
}

let summary_json = fun (s : session_summary) ->
  Json.obj
    [
      ("project", Json.string s.project);
      ("session_id", Json.string s.session_id);
      ("last_ts", Json.float s.last_ts);
      ("turns", Json.int s.turns);
      ("tools", Json.int s.tools);
      ("last_excerpt", Json.string s.last_excerpt);
    ]

let file_tail = fun path ~n ->
  match Fs.read_to_string (Path.from_string path |> Result.unwrap) with
  | Error _ -> ""
  | Ok content ->
      let len = String.length content in
      if len <= n then content
      else String.sub content ~offset:(len - n) ~len:n

(** Extract visible text from a message JSON value (string or content blocks). *)
let message_text = fun (msg : Json.t) ->
  match Json.get_field "content" msg with
  | None -> ""
  | Some (Json.String s) -> s
  | Some (Json.Array blocks) ->
      List.filter_map blocks ~fn:(fun b ->
        match Json.get_field "type" b |> Option.and_then ~fn:Json.get_string with
        | Some "text" ->
            Json.get_field "text" b |> Option.and_then ~fn:Json.get_string
        | Some "tool_use" ->
            Json.get_field "name" b |> Option.and_then ~fn:Json.get_string
            |> Option.map ~fn:(fun n -> "[tool:" ^ n ^ "]")
        | _ -> None)
      |> String.concat " "
  | _ -> ""

let excerpt_of = fun text ->
  let trimmed = String.trim text in
  let len = String.length trimmed in
  if len <= 160 then trimmed
  else String.sub trimmed ~offset:0 ~len:160 ^ "…"

(** Parse the tail of one session jsonl; returns a summary if any user or
    assistant message is found. *)
let summarize_jsonl = fun ~(project : string) ~(last_ts : float) (path : string) ->
  let tail = file_tail path ~n:131072 in
  let lines = String.split ~by:"\n" tail in
  let session_id = ref "" in
  let turns = ref 0 in
  let tools = ref 0 in
  let last_excerpt = ref "" in
  let last_cwd = ref "" in
  List.for_each lines ~fn:(fun line ->
    if not (String.is_empty line) then
      match Json.from_string line with
      | Error _ -> ()
      | Ok j ->
          let get_str k =
            Json.get_field k j |> Option.and_then ~fn:Json.get_string
            |> Option.unwrap_or ~default:""
          in
          let typ = get_str "type" in
          let sid = get_str "sessionId" in
          if not (String.is_empty sid) then session_id := sid;
          (match Json.get_field "cwd" j |> Option.and_then ~fn:Json.get_string with
           | Some c when not (String.is_empty c) -> last_cwd := c
           | _ -> ());
          if String.equal typ "user" || String.equal typ "assistant" then (
            turns := !turns + 1;
            (match Json.get_field "message" j with
             | None -> ()
             | Some msg ->
                 let text = message_text msg in
                 if String.contains text "[tool:" then tools := !tools + 1;
                 if not (String.is_empty (String.trim text)) then
                   last_excerpt := text
            )
          ));
  let project' =
    if String.is_empty !last_cwd then project else !last_cwd
  in
  if !turns = 0 then None
  else
    Some
      {
        project = project';
        session_id = !session_id;
        last_ts;
        turns = !turns;
        tools = !tools;
        last_excerpt = excerpt_of !last_excerpt;
      }

(** Scan all claude projects; returns summaries sorted by recency, newest
    first, capped at [limit]. *)
let scan = fun ~home ~limit ->
  let root = home ^ "/.claude/projects" in
  match Fs.read_dir (Path.from_string root |> Result.unwrap) with
  | Error _ -> []
  | Ok entries ->
      let entries = Iter.MutIterator.to_list entries in
      let summaries =
        List.filter_map entries ~fn:(fun project_dir ->
          let dir_name = Path.basename project_dir in
          let project_path = root ^ "/" ^ dir_name in
          match Fs.read_dir (Path.from_string project_path |> Result.unwrap) with
          | Error _ -> None
          | Ok files ->
              let files = Iter.MutIterator.to_list files in
              let jsonls =
                List.filter files ~fn:(fun p ->
                  String.ends_with ~suffix:".jsonl" (Path.basename p))
              in
              let newest =
                List.fold_left jsonls ~init:None ~fn:(fun best p ->
                  let full = project_path ^ "/" ^ Path.basename p in
                  match Fs.metadata (Path.from_string full |> Result.unwrap) with
                  | Error _ -> best
                  | Ok m ->
                      let t = Fs.Metadata.modified m in
                      (match best with
                       | None -> Some (t, full)
                       | Some (bt, _) -> if t > bt then Some (t, full) else best))
              in
              (
                match newest with
                | None -> None
                | Some (t, jsonl_full) ->
                    summarize_jsonl ~project:dir_name ~last_ts:t jsonl_full
              ))
      in
      List.sort summaries ~compare:(fun a b ->
        if a.last_ts > b.last_ts then LT
        else if a.last_ts < b.last_ts then GT
        else EQ)
      |> List.take ~len:limit
