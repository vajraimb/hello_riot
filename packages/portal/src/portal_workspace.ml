open Std

module Json = Std.Data.Json

(** Per-task working directories. An agent without a configured [workdir]
    runs in [<root>/<id>], where [id] is the conversation (thread) id — every
    turn of a conversation shares one directory, so a follow-up can build on
    the files the last turn wrote — or the request id for one-shot MCP tasks.
    Nothing lands in the gateway's own directory. *)

let max_files = 500

let max_depth = 8

let max_read = 512 * 1024

let skipped = [ ".git"; "node_modules"; "__pycache__"; ".venv"; "_build"; "target"; ".DS_Store" ]

let absolute = Portal_agent.absolute

let root = fun (config : Portal_config.t) ->
  absolute
    (if String.is_empty config.Portal_config.workspace_dir then config.Portal_config.data_dir ^ "/workspaces"
     else config.Portal_config.workspace_dir)

(** Ids come from Oasis itself (th-… / req-…), but they also arrive back
    through the API, so only plain names are accepted. *)
let valid_id = fun id ->
  (not (String.is_empty id))
  && String.length id <= 64
  && String.for_all id ~fn:(fun c ->
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '-' || c = '_')

let dir_of = fun config ~id -> root config ^ "/" ^ id

(** Creates the directory and returns its absolute path. *)
let prepare = fun config ~id ->
  if not (valid_id id) then Error ("invalid workspace id: " ^ id)
  else
    let dir = dir_of config ~id in
    match Path.from_string dir with
    | Error _ -> Error ("bad workspace path: " ^ dir)
    | Ok p -> (
        match Fs.create_dir_all p with
        | Ok () -> Ok dir
        | Error _ -> Error ("cannot create workspace: " ^ dir))

let exists = fun config ~id ->
  valid_id id
  && (match Path.from_string (dir_of config ~id) with
      | Ok p -> (match Fs.is_dir p with Ok b -> b | Error _ -> false)
      | Error _ -> false)

type entry = {
  path: string;  (** relative to the workspace *)
  size: int;
  modified_ms: int;
}

let list_files = fun config ~id ->
  let base = dir_of config ~id in
  let out = ref [] in
  let count = ref 0 in
  let rec walk rel depth =
    if depth <= max_depth && !count < max_files then
      let full = if String.is_empty rel then base else base ^ "/" ^ rel in
      match Path.from_string full |> Result.to_option |> Option.and_then ~fn:(fun p -> Fs.read_dir p |> Result.to_option) with
      | None -> ()
      | Some it ->
          Iter.MutIterator.to_list it
          |> List.map ~fn:Path.basename
          |> List.sort ~compare:String.compare
          |> List.for_each ~fn:(fun name ->
            if !count < max_files && not (List.any skipped ~fn:(String.equal name)) then
              let r = if String.is_empty rel then name else rel ^ "/" ^ name in
              match Path.from_string (base ^ "/" ^ r) |> Result.to_option |> Option.and_then ~fn:(fun p -> Fs.metadata p |> Result.to_option) with
              | None -> ()
              | Some m ->
                  if Fs.Metadata.is_dir m then walk r (depth + 1)
                  else (
                    count := !count + 1;
                    out :=
                      { path = r; size = Fs.Metadata.len m; modified_ms = Float.to_int (Fs.Metadata.modified m *. 1000.) }
                      :: !out))
  in
  walk "" 0;
  List.rev !out

let entry_json = fun (e : entry) ->
  Json.obj [ ("path", Json.string e.path); ("size", Json.int e.size); ("modified_ms", Json.int e.modified_ms) ]

let listing_json = fun config ~id ->
  let files = list_files config ~id in
  Json.obj
    [
      ("id", Json.string id);
      ("dir", Json.string (dir_of config ~id));
      ("files", Json.array (List.map files ~fn:entry_json));
      ("truncated", Json.bool (List.length files >= max_files));
    ]

(** A file inside the workspace; relative path only, no [..], and the
    resolved target must stay inside (symlinks pointing out are refused). *)
let read_file = fun config ~id ~path ->
  let segments = String.split ~by:"/" path in
  if
    (not (valid_id id))
    || String.is_empty path
    || String.starts_with ~prefix:"/" path
    || List.any segments ~fn:(fun s -> String.equal s ".." || String.is_empty s)
  then Error "bad path"
  else
    let base = dir_of config ~id in
    let canon p = Path.from_string p |> Result.to_option |> Option.and_then ~fn:(fun p -> Fs.canonicalize p |> Result.to_option) |> Option.map ~fn:Path.to_string in
    match (canon base, canon (base ^ "/" ^ path)) with
    | (Some b, Some f) when String.starts_with ~prefix:(b ^ "/") f -> (
        match Path.from_string f |> Result.to_option |> Option.and_then ~fn:(fun p -> Fs.read_to_string p |> Result.to_option) with
        | None -> Error "cannot read"
        | Some content ->
            let size = String.length content in
            let binary = String.contains content "\000" in
            let shown = if binary then "" else if size > max_read then String.sub content ~offset:0 ~len:max_read else content in
            Ok
              (Json.obj
                [
                  ("path", Json.string path);
                  ("size", Json.int size);
                  ("binary", Json.bool binary);
                  ("truncated", Json.bool ((not binary) && size > max_read));
                  ("content", Json.string shown);
                ]))
    | _ -> Error "not found"
