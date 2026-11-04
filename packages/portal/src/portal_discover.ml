open Std
open Std.Collections

module Json = Std.Data.Json

(** Local agent discovery: scan the machine for installed agents, their
    login state, and recent activity (AIUsage-flavored inventory). *)

type agent_status = {
  name: string;
  command: string;
  installed: bool;
  logged_in: bool;
  last_activity_s: float option;
  active: bool;
  projects: string list;
}

let status_json = fun (s : agent_status) ->
  Json.obj
    [
      ("name", Json.string s.name);
      ("command", Json.string s.command);
      ("installed", Json.bool s.installed);
      ("logged_in", Json.bool s.logged_in);
      (
        "last_activity_s",
        match s.last_activity_s with
        | None -> Json.null
        | Some t -> Json.float t
      );
      ("active", Json.bool s.active);
      ("projects", Json.array (List.map s.projects ~fn:(fun p -> Json.string p)));
    ]

let find_command = fun ~home cmd ->
  let dirs =
    [
      home ^ "/.local/bin";
      home ^ "/bin";
      "/opt/homebrew/bin";
      "/usr/local/bin";
      "/usr/bin";
      "/opt/bin";
    ]
  in
  List.any dirs ~fn:(fun d ->
    match Fs.exists (Path.from_string (d ^ "/" ^ cmd) |> Result.unwrap) with
    | Ok true -> true
    | _ -> false)

let read_json_file = fun path ->
  match Fs.read_to_string (Path.from_string path |> Result.unwrap) with
  | Error _ -> None
  | Ok content -> Json.from_string content |> Result.to_option

let file_exists = fun path ->
  match Fs.exists (Path.from_string path |> Result.unwrap) with
  | Ok true -> true
  | _ -> false

let dir_exists = fun path -> file_exists path

(** Claude Code login: oauthAccount present in ~/.claude.json *)
let claude_logged_in = fun ~home ->
  match read_json_file (home ^ "/.claude.json") with
  | None -> false
  | Some j -> (
      match Json.get_field "oauthAccount" j with
      | Some (Json.Object _) -> true
      | Some (Json.String s) -> not (String.is_empty s)
      | _ -> false
    )

(** Tail of a file: last [n] bytes. *)
let file_tail = fun path ~n ->
  match Fs.read_to_string (Path.from_string path |> Result.unwrap) with
  | Error _ -> ""
  | Ok content ->
      let len = String.length content in
      if len <= n then content
      else String.sub content ~offset:(len - n) ~len:n

(** Parse the cwd out of the last JSONL line of a claude session file. *)
let last_cwd_of_jsonl = fun path ->
  let tail = file_tail path ~n:8192 in
  let lines = String.split ~by:"\n" tail in
  let rec find = function
    | [] -> None
    | line :: rest -> (
        match Json.from_string line with
        | Error _ -> find rest
        | Ok j ->
            let cwd =
              Json.get_field "cwd" j |> Option.and_then ~fn:Json.get_string
            in
            (match cwd with Some c when not (String.is_empty c) -> Some c | _ -> find rest)
      )
  in
  find (List.rev lines)

(** Claude Code activity: newest jsonl under ~/.claude/projects/<md5>/ *)
let claude_activity = fun ~home ~now_s ->
  let root = home ^ "/.claude/projects" in
  match Fs.read_dir (Path.from_string root |> Result.unwrap) with
  | Error _ -> (None, [])
  | Ok entries ->
      let entries = Iter.MutIterator.to_list entries in
      let rec scan acc_proj acc_time = function
        | [] -> (acc_time, List.rev acc_proj)
        | project_dir :: rest -> (
            let dir_name = Path.basename project_dir in
            let project_path = root ^ "/" ^ dir_name in
            match Fs.read_dir (Path.from_string project_path |> Result.unwrap) with
            | Error _ -> scan acc_proj acc_time rest
            | Ok files ->
                let files = Iter.MutIterator.to_list files in
                let jsonls =
                  List.filter files ~fn:(fun p ->
                    String.ends_with ~suffix:".jsonl" (Path.basename p))
                in
                (* newest modified jsonl *)
                let newest =
                  List.fold_left jsonls ~init:None ~fn:(fun best p ->
                    match Fs.metadata (Path.from_string (project_path ^ "/" ^ Path.basename p) |> Result.unwrap) with
                    | Error _ -> best
                    | Ok m ->
                        let t = Fs.Metadata.modified m in
                        (match best with
                         | None -> Some (t, p)
                         | Some (bt, _) -> if t > bt then Some (t, p) else best))
                in
                (
                  match newest with
                  | None -> scan acc_proj acc_time rest
                  | Some (t, jsonl_path) ->
                      let cwd =
                        last_cwd_of_jsonl (project_path ^ "/" ^ Path.basename jsonl_path)
                        |> Option.unwrap_or ~default:dir_name
                      in
                      let acc_time' =
                        match acc_time with
                        | None -> Some t
                        | Some bt -> Some (if t > bt then t else bt)
                      in
                      let acc_proj' = (t, cwd) :: acc_proj in
                      scan acc_proj' acc_time' rest
                )
          )
      in
      let (last_s, proj_list) = scan [] None entries in
      let proj_sorted =
        List.sort proj_list ~compare:(fun (t1, _) (t2, _) ->
          if t1 > t2 then LT else if t1 < t2 then GT else EQ)
      in
      let projects =
        List.map proj_sorted ~fn:(fun (_, cwd) -> cwd) |> List.take ~len:3
      in
      let _ = now_s in
      (last_s, projects)

let agent = fun ~name ~command ~installed ~logged_in ~activity ~now_s ->
  let (last_s, projects) = activity in
  {
    name;
    command;
    installed;
    logged_in;
    last_activity_s = last_s;
    active =
      (match last_s with Some t -> now_s -. t < 600.0 | None -> false);
    projects;
  }

(** Scan everything; [now_s] is wall-clock epoch seconds. *)
let scan = fun ~home ->
  let now_s = Time.SystemTime.now () |> Time.SystemTime.secs_float in
  let mk name cmd installed logged_in activity =
    agent ~name ~command:cmd ~installed ~logged_in ~activity ~now_s
  in
  [
    mk "claude_code" "claude" (find_command ~home "claude") (claude_logged_in ~home) (claude_activity ~home ~now_s);
    mk "opencode" "opencode" (find_command ~home "opencode")
      (file_exists (home ^ "/.local/share/opencode/auth.json"))
      (None, []);
    mk "gemini_cli" "gemini" (find_command ~home "gemini")
      (dir_exists (home ^ "/.gemini") || dir_exists (home ^ "/.config/gemini"))
      (None, []);
    mk "codex_cli" "codex" (find_command ~home "codex")
      (file_exists (home ^ "/.codex/auth.json"))
      (None, []);
    mk "kimi_cli" "kimi" (find_command ~home "kimi") (dir_exists (home ^ "/.kimi")) (None, []);
    mk "grok_cli" "grok" (find_command ~home "grok" || file_exists (home ^ "/.grok/bin/grok"))
      (dir_exists (home ^ "/.grok"))
      (None, []);
    mk "cursor_agent" "cursor-agent" (find_command ~home "cursor-agent")
      (file_exists (home ^ "/.cursor/cli-config.json"))
      (None, []);
  ]
