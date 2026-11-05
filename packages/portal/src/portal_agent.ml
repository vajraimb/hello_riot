open Std
open Std.Collections

module Json = Std.Data.Json

(** Local AI-agent adapters: run headless agent CLIs (Claude Code, opencode,
    gemini, codex) as subprocesses and expose their output as chat streams.
    Agent subprocesses live on blocking lanes. They run until they exit or
    are cancelled; a watchdog kills them only when [timeout_s] > 0 (set by
    config or by the caller). *)

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
  allowed_workdirs: string list;
  env_passthrough: string list;
  resume_args: string list;  (** [{session}] placeholder; [] = default for the CLI *)
}

type Message.t +=
  | Agent_line of int * string
  | Agent_done of int * int
  | Agent_timeout of int
  | Agent_spawned of int * Process.t

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

(* ---------- sessions ---------- *)

let command_name = fun (a : agent) ->
  match List.rev (String.split_on_char '/' a.command) with n :: _ -> n | [] -> a.command

(** How each known CLI resumes a session by id (verified with claude 2.x,
    cursor-agent, gemini, grok; kimi per its help). *)
let default_resume_args = fun name ->
  match name with
  | "claude" | "cursor-agent" | "gemini" | "grok" -> [ "--resume"; "{session}" ]
  | "kimi" -> [ "--session"; "{session}" ]
  | _ -> []

let resume_args = fun (a : agent) ->
  if List.is_empty a.resume_args then default_resume_args (command_name a) else a.resume_args

(** The agent set up to continue [session], or None when its CLI has no
    known way to resume. The resume flags go first: some templates end in
    a flag that takes the prompt as its value ([-p {prompt}]). *)
let with_resume = fun (a : agent) ~session ->
  match resume_args a with
  | [] -> None
  | ra ->
      let ra = List.map ra ~fn:(fun x -> if String.equal x "{session}" then session else x) in
      Some { a with args_template = ra @ a.args_template }

(** The CLI session id a stdout line announces ([session_id] for claude,
    cursor-agent, gemini; [sessionId] for grok). *)
let session_id_of_line = fun (line : string) ->
  if not (String.contains line "ession") then None
  else
    match Json.from_string line with
    | Error _ -> None
    | Ok j -> (
        let field k = Json.get_field k j |> Option.and_then ~fn:Json.get_string in
        match field "session_id" with
        | Some s when not (String.is_empty s) -> Some s
        | _ -> (match field "sessionId" with Some s when not (String.is_empty s) -> Some s | _ -> None)
      )

(* ---------- output parsing ---------- *)

(** Text blocks of a stream-json [assistant] line. *)
let assistant_text = fun j ->
  match Json.get_field "message" j with
  | None -> None
  | Some message -> (
      match Json.get_field "content" message |> Option.and_then ~fn:Json.get_array with
      | None -> None
      | Some blocks ->
          let texts =
            List.filter_map blocks ~fn:(fun block ->
              match Json.get_field "type" block |> Option.and_then ~fn:Json.get_string with
              | Some "text" -> Json.get_field "text" block |> Option.and_then ~fn:Json.get_string
              | _ -> None)
          in
          if List.is_empty texts then None else Some (String.concat "" texts)
    )

(** [extract_text ~command line] pulls the visible assistant text from one
    line of agent stdout. Json event lines of known agent CLIs are parsed
    (Portal_steps); other output is plain text. Returns None for lines that
    carry no user-visible text (tool events, json bookkeeping, the final
    [result] line that repeats every assistant segment). *)
let extract_text = fun ~command (line : string) ->
  match Portal_steps.parse ~command line with
  | Some steps -> (
      match Portal_steps.answer_piece (Portal_steps.joiner ()) steps with
      | "" -> None
      | t -> Some t
    )
  | None ->
      if String.is_empty (String.trim line) then None
      else Some (line ^ "\n")

(** Stateful variant for whole runs: returns the answer text one line adds
    (separators included) and the work steps it carries. *)
let consume_line = fun (jn : Portal_steps.joiner) ~command (line : string) ->
  match Portal_steps.parse ~command line with
  | Some steps -> (Portal_steps.answer_piece jn steps, steps)
  | None ->
      if String.is_empty (String.trim line) then ("", [])
      else (line ^ "\n", [])

(* ---------- workdir / env sandboxing (spec §5.2) ---------- *)

(** Absolute, [..]-free path with empty and [.] segments removed and no
    trailing slash ("/" stays "/"). *)
let normalize_abs_path = fun path ->
  if not (String.starts_with ~prefix:"/" path) then Error ("workdir must be absolute: " ^ path)
  else
    let segments =
      String.split ~by:"/" path
      |> List.filter ~fn:(fun s -> not (String.is_empty s || String.equal s "."))
    in
    if List.any segments ~fn:(String.equal "..") then Error ("workdir must not contain '..': " ^ path)
    else Ok ("/" ^ String.concat "/" segments)

let path_within = fun ~root path ->
  if String.equal root "/" then true
  else if String.equal path root then true
  else String.starts_with ~prefix:(root ^ "/") path

(** [resolve_workdir agent requested] is the directory the agent runs in.
    A requested workdir must sit inside [allowed_workdirs] (or the agent's own
    [workdir] when that list is empty); without a request the configured
    [workdir] is used. *)
let resolve_workdir = fun (a : agent) (requested : string option) ->
  match requested with
  | None -> Ok a.workdir
  | Some req -> (
      match normalize_abs_path req with
      | Error e -> Error e
      | Ok path ->
          let roots =
            (if List.is_empty a.allowed_workdirs then [ a.workdir ] else a.allowed_workdirs)
            |> List.filter ~fn:(fun r -> not (String.is_empty r))
            |> List.filter_map ~fn:(fun r -> normalize_abs_path r |> Result.to_option)
          in
          if List.any roots ~fn:(fun root -> path_within ~root path) then Ok path
          else Error ("workdir not allowed for agent " ^ a.name ^ ": " ^ path)
    )

(** Variables a child agent inherits; everything else (API keys in
    particular) is dropped. *)
let base_env_keys = [ "PATH"; "LANG"; "LC_ALL"; "TERM"; "USER"; "LOGNAME"; "SHELL"; "TMPDIR" ]

let child_env = fun (a : agent) ->
  let inherited =
    base_env_keys @ a.env_passthrough
    |> List.filter ~fn:(fun k -> not (String.equal k "HOME"))
    |> List.filter_map ~fn:(fun k ->
      match Env.var Env.String ~name:k with
      | Some v -> Some (k, v)
      | None -> None)
  in
  let home =
    if not (String.is_empty a.home) then Some a.home else Env.var Env.String ~name:"HOME"
  in
  match home with
  | Some h -> ("HOME", h) :: inherited
  | None -> inherited

(* ---------- execution ---------- *)

(** Runs [agent.command] under [env -i] so the child sees only
    [child_env]: [Process.spawn ~env] would merge into the gateway's own
    environment, which holds every upstream API key. *)
let group_leader_script =
  {|setpgrp(0, 0);
my $pid = fork();
exit 127 unless defined $pid;
if ($pid == 0) { exec { $ARGV[0] } @ARGV or exit 127 }
waitpid($pid, 0);
my $st = $?;
if (open(my $ps, '-|', '/bin/ps', '-A', '-o', 'pid=,pgid=')) {
  my @rest = map { $_->[0] } grep { $_->[1] == $$ && $_->[0] != $$ } map { [split ' '] } <$ps>;
  close($ps);
  kill 'KILL', @rest if @rest;
}
exit($st & 127 ? 128 + ($st & 127) : $st >> 8);|}

(** [dir] against the gateway's own working directory. *)
let absolute = fun dir ->
  if String.starts_with ~prefix:"/" dir then dir
  else
    match Env.current_dir () with
    | Ok cwd ->
        let rel = if String.starts_with ~prefix:"./" dir then String.sub dir ~offset:2 ~len:(String.length dir - 2) else dir in
        Path.to_string cwd ^ "/" ^ rel
    | Error _ -> dir

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
  let env_args = List.map (child_env agent) ~fn:(fun (k, v) -> k ^ "=" ^ v) in
  (* perl leads a fresh process group so the watchdog can kill the whole
     tree (gemini re-execs into a node child that outlives a SIGKILL of the
     parent). It also reaps the group once the agent exits: helpers such as
     cursor-agent's daemonized worker-server inherit stdout, and a pipe
     held open by them would block the reader forever. *)
  let group_leader = [ "/usr/bin/perl"; "-e"; group_leader_script; "--" ] in
  (* the agent runs in its own workdir, so a relative command path is
     pinned to the gateway's directory first; bare names still go via PATH *)
  let command = if String.contains agent.command "/" then absolute agent.command else agent.command in
  let argv = ("-i" :: env_args) @ group_leader @ (command :: Array.to_list args) in
  let args = Array.init ~count:(List.length argv) ~fn:(fun i -> List.get_unchecked argv ~at:i) in
  Process.spawn ~program:"env" ~args ?current_dir:workdir ~stdio ()

(* The tree is collected before anything is killed: agent CLIs (grok) run
   tool commands in their own process groups, and once their parent dies
   they are reparented to launchd and can no longer be found. *)
let kill_tree_script =
  {|my $root = shift;
my %kids;
if (open(my $ps, '-|', '/bin/ps', '-A', '-o', 'pid=,ppid=')) {
  for (<$ps>) { my ($p, $pp) = split ' '; push @{$kids{$pp}}, $p }
  close($ps);
}
my @todo = ($root);
my @all;
while (@todo) { my $p = shift @todo; push @all, $p; push @todo, @{$kids{$p} || []} }
kill 'KILL', -$root;
kill 'KILL', @all;|}

(** SIGKILL the process group led by [proc] (see [spawn_proc]) and every
    descendant, wherever its process group. *)
let kill_group = fun (proc : Process.t) ->
  let stdio = { Process.stdin = Process.Stdin.Null; stdout = Process.Stdout.Null; stderr = Process.Stderr.Null } in
  (match
     Process.spawn ~program:"/usr/bin/perl" ~args:[| "-e"; kill_tree_script; Int.to_string (Process.pid proc) |] ~stdio ()
   with
   | Error _ -> ()
   | Ok k ->
       let rec reap n =
         match Process.try_wait k with
         | Ok (Some _) | Error _ -> ()
         | Ok None -> if n > 0 then (sleep (Time.Duration.from_millis 10); reap (n - 1))
       in
       reap 100;
       let _ = Process.close k in
       ());
  let _ = Process.kill proc ~signal:9 in
  ()

let watchdog = fun ~(proc : Process.t) ~timeout_s ~to_pid ~leg ->
  (* SIGKILL the subprocess tree after [timeout_s]; runs on its own blocking lane *)
  if timeout_s <= 0 then () else
  ignore @@ Runtime.spawn_blocked (fun () ->
    sleep (Time.Duration.from_secs (max 1 timeout_s));
    (match Process.try_wait proc with
     | Ok (Some (Process.Exited _ | Process.Signaled _)) -> ()
     | _ ->
         kill_group proc;
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

(** Synchronous collection; call ONLY from a blocking lane. [on_line] sees
    every raw stdout line (for step extraction by the caller). *)
let collect = fun ?(on_line = fun (_ : string) -> ()) ?(on_spawn = fun (_ : Process.t) -> ()) ~(agent : agent) ~model ~prompt () ->
  let args =
    let arg_list = build_args agent ~model ~prompt in
    Array.init ~count:(List.length arg_list) ~fn:(fun i -> List.get_unchecked arg_list ~at:i)
  in
  match spawn_proc ~agent ~args () with
  | Error e -> Error ("agent spawn failed: " ^ Process.error_to_string e)
  | Ok proc ->
      on_spawn proc;
      watchdog ~proc ~timeout_s:agent.timeout_s ~to_pid:(self ()) ~leg:0;
      let buf = ref "" in
      let jn = Portal_steps.joiner () in
      let observe = on_line in
      let on_line line =
        observe line;
        let text, _ = consume_line jn ~command:agent.command line in
        buf := !buf ^ text
      in
      drain_proc ~proc ~on_line ();
      let code = exit_code ~proc in
      let _ = Process.close proc in
      if code = 0 then
        Ok !buf
      else if code = 137 && agent.timeout_s > 0 then
        Error ("agent timeout (" ^ Int.to_string agent.timeout_s ^ "s)")
      else if code = 137 then
        Error "agent killed (SIGKILL)"
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
      send to_pid (Agent_spawned (leg, proc));
      watchdog ~proc ~timeout_s:agent.timeout_s ~to_pid ~leg;
      let on_line line =
        send to_pid (Agent_line (leg, line))
      in
      drain_proc ~proc ~on_line ();
      let code = exit_code ~proc in
      let _ = Process.close proc in
      send to_pid (Agent_done (leg, code));
      Ok ()
