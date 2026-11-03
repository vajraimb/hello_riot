open Std
open Std.Collections

module Json = Std.Data.Json

(** Local AI-agent adapters: run headless agent CLIs (Claude Code, opencode,
    gemini, codex) as subprocesses and expose their output as chat streams.
    Agent subprocesses live on blocking lanes; a watchdog kills them on
    timeout. *)

type agent = {
  name: string;
  command: string;
  args_template: string list;
  home: string;
  models: string list;
  workdir: string;
  timeout_s: int;
  capabilities: string list;
  tier: int;
  strengths: string list;
  weaknesses: string list;
  context_window: int;
  max_output: int;
  latency: string;
  enabled: bool;
  concurrency_limit: int;
}

type Message.t +=
  | Agent_line of int * string
  | Agent_done of int * int
  | Agent_timeout of int

let contains_cap = fun (a : agent) cap ->
  List.any a.capabilities ~fn:(String.equal cap)

let fit = fun (a : agent) ~category ->
  let base = 40 + (min 5 (max 1 a.tier)) * 10 in
  let with_strength =
    if List.any a.strengths ~fn:(String.equal category) then base + 10 else base
  in
  if List.any a.weaknesses ~fn:(String.equal category) then
    max 0 (with_strength - 10)
  else
    min 100 with_strength

(** Replace {prompt} / {model} placeholders in the args template. *)
let build_args = fun (a : agent) ~model ~prompt ->
  List.map
    a.args_template
    ~fn:(fun arg ->
      let arg =
        if String.equal arg "{prompt}" then prompt else arg
      in
      if String.equal arg "{model}" then model else arg)

(* ---------- output parsing ---------- *)

(** [extract_text ~command line] pulls the visible assistant text from one
    line of agent stdout. Claude Code's stream-json lines are parsed; other
    agents are treated as plain text. Returns None for lines that carry no
    user-visible text (tool events, json bookkeeping). *)
let extract_text = fun ~command (line : string) ->
  if String.equal command "claude" then (
    match Json.from_string line with
    | Error _ -> None
    | Ok j -> (
        match Json.get_field "type" j |> Option.and_then ~fn:Json.get_string with
        | Some "assistant" -> (
            match Json.get_field "message" j with
            | None -> None
            | Some message -> (
                match
                  Json.get_field "content" message |> Option.and_then ~fn:Json.get_array
                with
                | None -> None
                | Some blocks ->
                    let texts =
                      List.filter_map blocks ~fn:(fun block ->
                        match
                          Json.get_field "type" block
                          |> Option.and_then ~fn:Json.get_string
                        with
                        | Some "text" ->
                            Json.get_field "text" block
                            |> Option.and_then ~fn:Json.get_string
                        | _ -> None)
                    in
                    if List.is_empty texts then None
                    else Some (String.concat "" texts)
              )
          )
        | Some "result" ->
            (* final result line: prefer the result text *)
            Json.get_field "result" j |> Option.and_then ~fn:Json.get_string
        | _ -> None
      )
  ) else
    (* opencode / gemini / codex: plain text lines *)
    if String.is_empty (String.trim line) then None
    else Some (line ^ "\n")

(* ---------- execution ---------- *)

let spawn_proc = fun ~(agent : agent) ~args () ->
  let stdio =
    {
      Process.stdin = Process.Stdin.Null;
      stdout = Process.Stdout.Pipe;
      stderr = Process.Stderr.Null;
    }
  in
  let workdir =
    if String.is_empty agent.workdir then None
    else Some (Path.from_string agent.workdir |> Result.unwrap)
  in
  let env =
    if String.is_empty agent.home then None
    else Some [| ("HOME", agent.home) |]
  in
  Process.spawn ~program:agent.command ~args ?env ?current_dir:workdir ~stdio ()

let watchdog = fun ~(proc : Process.t) ~timeout_s ~to_pid ~leg ->
  (* SIGKILL the subprocess after [timeout_s]; runs on its own blocking lane *)
  Runtime.spawn_blocked (fun () ->
    sleep (Time.Duration.from_secs (max 1 timeout_s));
    (match Process.try_wait proc with
     | Ok (Some (Process.Exited _ | Process.Signaled _)) -> ()
     | _ ->
         let _ = Process.kill proc ~signal:9 in
         send to_pid (Agent_timeout leg));
    Ok ())

(** Split [pending] into complete lines, feeding each to [on_line]; returns
    the leftover partial line. *)
let feed_lines = fun ~pending ~text ~on_line ->
  let buf = ref (pending ^ text) in
  let rec loop () =
    match String.index_of !buf ~char:'\n' with
    | None -> !buf
    | Some i ->
        let line = String.sub !buf ~offset:0 ~len:i in
        let rest = String.sub !buf ~offset:(i + 1) ~len:(String.length !buf - i - 1) in
        on_line (String.trim line);
        buf := rest;
        loop ()
  in
  loop ()

(** Poll-based reader: [File.read] chunks while the process lives; after exit
    drain the tail once. Never relies on [File.read_line] (its EOF behavior
    hangs on pipes in this runtime). *)
let drain_proc = fun ~proc ~on_line () ->
  let pending = ref "" in
  let raw = IO.Bytes.create ~size:4096 in
  let rec read_once () =
    match Process.stdout proc with
    | None -> ()
    | Some file -> (
        match Fs.File.read file raw ~offset:0 ~len:4096 with
        | Ok n when n > 0 ->
            let chunk = IO.Bytes.to_string raw |> fun s -> String.sub s ~offset:0 ~len:n in
            pending := feed_lines ~pending:!pending ~text:chunk ~on_line
        | _ -> ()
      )
  in
  let exited () =
    match Process.try_wait proc with
    | Ok (Some (Process.Exited _ | Process.Signaled _)) -> true
    | _ -> false
  in
  let rec loop () =
    if exited () then (
      read_once ();
      if not (String.is_empty !pending) then (
        on_line !pending;
        pending := ""
      )
    ) else (
      read_once ();
      if not (exited ()) then (
        sleep (Time.Duration.from_millis 20);
        loop ()
      )
    )
  in
  loop ()

let exit_code = fun ~proc ->
  match Process.try_wait proc with
  | Ok (Some (Process.Exited c)) -> c
  | Ok (Some (Process.Signaled s)) -> 128 + s
  | _ -> -1

(** Synchronous collection; call ONLY from a blocking lane. *)
let collect = fun ~(agent : agent) ~model ~prompt () ->
  let args =
    let arg_list = build_args agent ~model ~prompt in
    Array.init ~count:(List.length arg_list) ~fn:(fun i -> List.get_unchecked arg_list ~at:i)
  in
  match spawn_proc ~agent ~args () with
  | Error e -> Error ("agent spawn failed: " ^ Process.error_to_string e)
  | Ok proc ->
      let _ = watchdog ~proc ~timeout_s:agent.timeout_s ~to_pid:(self ()) ~leg:0 in
      let buf = ref "" in
      let on_line line =
        buf := !buf ^ (extract_text ~command:agent.command line |> Option.unwrap_or ~default:"")
      in
      drain_proc ~proc ~on_line ();
      let code = exit_code ~proc in
      let _ = Process.close proc in
      if code = 0 then
        Ok !buf
      else if code = 137 then
        Error ("agent timeout (" ^ Int.to_string agent.timeout_s ^ "s)")
      else
        Error ("agent exited with code " ^ Int.to_string code)

(** Streaming run; call ONLY from a blocking lane. Lines go to [to_pid] as
    [Agent_line], the exit code as [Agent_done]. *)
let stream = fun ~(agent : agent) ~model ~prompt ~to_pid ~leg () ->
  let args =
    let arg_list = build_args agent ~model ~prompt in
    Array.init ~count:(List.length arg_list) ~fn:(fun i -> List.get_unchecked arg_list ~at:i)
  in
  match spawn_proc ~agent ~args () with
  | Error e ->
      send to_pid (Agent_done (leg, -1));
      Ok ()
  | Ok proc ->
      let _ = watchdog ~proc ~timeout_s:agent.timeout_s ~to_pid ~leg in
      let on_line line =
        send to_pid (Agent_line (leg, line))
      in
      drain_proc ~proc ~on_line ();
      let code = exit_code ~proc in
      let _ = Process.close proc in
      send to_pid (Agent_done (leg, code));
      Ok ()
