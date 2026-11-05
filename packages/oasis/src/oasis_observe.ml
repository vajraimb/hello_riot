open Std
open Std.Collections

(** Opt-in readings of plan and usage already visible in agent apps.

    The setup wizard asks once. When the answer is yes, a loop looks every
    15 minutes at windows the user already opened (Cursor, Claude, Codex, Gemini,
    Kimi, Grok, ZCode, DeepSeek Harness, WorkBuddy, Perplexity)
    through the [agent-desktop] accessibility tree. It records only a plan
    name, a usage ratio, a token count, and a reset line. It does not click,
    type, or focus those apps, and it does not keep the rest of the tree. *)

module Json = Std.Data.Json

type seen = {
  plan: string;
  usage: string;
  tokens: string;
  reset: string;
}

type reading = {
  app: string;
  plan: string;
  usage: string;
  tokens: string;
  reset: string;
  seen_unix: int;
}

let empty_seen = { plan = ""; usage = ""; tokens = ""; reset = "" }

let readings = Sync.Atomic.make ([] : reading list)

let note = Sync.Atomic.make ""

let consent_path = fun () -> Oasis_config.home () ^ "/observe-apps"

let allowed = fun () ->
  match Path.from_string (consent_path ()) with
  | Error _ -> false
  | Ok p -> (
      match Fs.read_to_string p with
      | Ok s -> String.equal (String.trim s) "yes"
      | Error _ -> false
    )

let set_allowed = fun on ->
  match Path.from_string (consent_path ()) with
  | Error _ -> ()
  | Ok p ->
      if on then (
        let _ = Fs.write "yes\n" p in
        let _ = Fs.set_permissions p (Fs.Permissions.from_mode 0o600) in
        ()
      ) else
        let _ = Fs.remove_file p in
        ()

let watched =
  [
    "Cursor";
    "Claude";
    "Codex";
    "ChatGPT";
    "Gemini";
    "Kimi";
    "Grok";
    "Grok Bot";
    "ZCode";
    "DeepSeek Harness";
    "WorkBuddy";
    "Perplexity";
  ]

let is_watched = fun name -> List.any watched ~fn:(String.equal name)

let plans = [ "free"; "pro"; "pro+"; "plus"; "premium"; "ultra"; "super"; "max"; "team"; "business"; "enterprise"; "go"; "hobby" ]

let lower = fun s -> String.lowercase_ascii (String.trim s)

let is_plan = fun s -> List.any plans ~fn:(String.equal (lower s))

let is_current_plan = fun s -> String.equal (lower s) "current plan"

let ends = fun s suffix ->
  let n = String.length suffix in
  let m = String.length s in
  if m < n then
    false
  else
    String.equal suffix (String.sub s ~offset:(m - n) ~len:n)

let is_digits = fun s -> (not (String.is_empty s)) && String.for_all s ~fn:(fun c -> c >= '0' && c <= '9')

let usage_of = fun s ->
  let s = String.trim s in
  let s = if ends s " used" then String.sub s ~offset:0 ~len:(String.length s - 5) else s in
  if ends s "%" then
    let n = String.sub s ~offset:0 ~len:(String.length s - 1) in
    if is_digits n && String.length n <= 3 then Some (n ^ "%") else None
  else
    None

let digits_only = fun s ->
  let n = String.length s in
  let rec go i acc =
    if i >= n then
      acc
    else
      let c = String.get_unchecked s ~at:i in
      let acc = if c >= '0' && c <= '9' then acc ^ String.make ~len:1 ~char:c else acc in
      go (i + 1) acc
  in
  go 0 ""

let fraction_of = fun s ->
  let s = String.trim s in
  if String.length s > 40 || not (String.contains s "/") then
    None
  else
    match String.split ~by:"/" s with
    | [ a; b ] ->
        let a = digits_only a in
        let b = digits_only b in
        if is_digits a && is_digits b && (not (String.is_empty a)) && (not (String.is_empty b)) then Some (a ^ "/" ^ b) else None
    | _ -> None

let upper_suffix = fun c -> if c = 'k' || c = 'K' then 'K' else if c = 'm' || c = 'M' then 'M' else 'B'

let is_magnitude_suffix = fun c -> c = 'k' || c = 'K' || c = 'm' || c = 'M' || c = 'b' || c = 'B'

(** Grouping commas from the right, so 9888476 becomes 9,888,476. *)
let regroup = fun digits ->
  let n = String.length digits in
  let rec go i acc =
    if i < 0 then
      acc
    else
      let acc = String.make ~len:1 ~char:(String.get_unchecked digits ~at:i) ^ acc in
      let placed = n - i in
      if i > 0 then
        if placed mod 3 = 0 then go (i - 1) ("," ^ acc) else go (i - 1) acc
      else
        acc
  in
  if n = 0 then "" else go (n - 1) ""

(** A plain count (9,888,476) or an abbreviated one (262.6M). *)
let token_count_of = fun s ->
  let s = String.trim s in
  let n = String.length s in
  if n = 0 || n > 20 || String.contains s "%" || String.contains s "/" || String.contains s " " then
    None
  else
    let last = String.get_unchecked s ~at:(n - 1) in
    let (body, suf) =
      if is_magnitude_suffix last then
        (String.sub s ~offset:0 ~len:(n - 1), String.make ~len:1 ~char:(upper_suffix last))
      else
        (s, "")
    in
    let bn = String.length body in
    if bn = 0 then
      None
    else if not (String.is_empty suf) then
      let rec body_ok i dots =
        if i >= bn then
          dots <= 1
        else
          let c = String.get_unchecked body ~at:i in
          if c >= '0' && c <= '9' then
            body_ok (i + 1) dots
          else if c = '.' && dots = 0 && i > 0 && i < bn - 1 then
            body_ok (i + 1) 1
          else
            false
      in
      if body_ok 0 0 then Some (body ^ suf) else None
    else if String.contains body "," then
      let d = digits_only body in
      if is_digits d && String.equal body (regroup d) then Some d else None
    else if is_digits body then
      Some body
    else
      None

(** Caption for a consumed-token total. Peak, chart, and trend labels are not. *)
let token_total_label = fun s ->
  let l = lower (String.trim s) in
  let n = String.length l in
  if n = 0 || n > 24 then
    false
  else if not (String.contains l "token") then
    false
  else if
    String.contains l "peak" || String.contains l "trend" || String.contains l "chart" || String.contains l "activity"
    || String.contains l "daily" || String.contains l "峰"
  then
    false
  else
    true

let prefers_total = fun s ->
  let l = lower s in
  String.contains l "total" || String.contains s "总"

(** Perplexity shows a credit balance, not a token count. *)
let credit_balance_label = fun s ->
  let l = lower (String.trim s) in
  let n = String.length l in
  n > 0 && n <= 40 && String.contains l "available" && String.contains l "credit"

let count_within = fun names i ->
  let len = List.length names in
  let rec go offsets =
    match offsets with
    | [] -> None
    | j :: rest ->
        if j < 0 || j >= len then
          go rest
        else
          match token_count_of (List.get_unchecked names ~at:j) with
          | Some v -> Some v
          | None -> go rest
  in
  go [ i + 1; i + 2; i - 1; i - 2 ]

let adjacent_count = fun names i prefer_before ->
  let len = List.length names in
  let at j = if j < 0 || j >= len then None else token_count_of (List.get_unchecked names ~at:j) in
  if prefer_before then
    match at (i - 1) with
    | Some v -> Some v
    | None -> at (i + 1)
  else
    match at (i + 1) with
    | Some v -> Some v
    | None -> at (i - 1)

let has_digit = fun s -> String.exists s ~fn:(fun c -> c >= '0' && c <= '9')

let reset_of = fun s ->
  let t = String.trim s in
  let l = lower t in
  if
    String.length t >= 8
    && String.length t <= 100
    && String.contains l "reset"
    && has_digit t
    && not (String.contains t "。")
  then
    Some t
  else
    None

let short = fun s ->
  let s = String.trim s in
  if String.is_empty s || String.length s > 120 then None else Some s

let neighbor = fun names i needles ->
  let len = List.length names in
  let lo = if i > 4 then i - 4 else 0 in
  let hi = if i + 4 < len then i + 4 else len - 1 in
  let rec go j =
    if j > hi then
      false
    else
      let l = lower (List.get_unchecked names ~at:j) in
      if List.any needles ~fn:(fun n -> String.contains l n) then true else go (j + 1)
  in
  go lo

(** A usage percent only counts beside a short label. Chat quotes mention the
    same words, so a sentence, a comma, or a "Plan & Usage" button does not. *)
let usage_label = fun s ->
  let l = lower s in
  let n = String.length (String.trim s) in
  n > 0
  && n <= 48
  && (not (String.contains s "，"))
  && (not (String.contains s "。"))
  && (not (String.contains s "、"))
  && (not (String.contains l "plan &"))
  && (not (String.contains l "model"))
  && (String.contains l "usage" || String.contains l "limit" || String.contains l "额度" || String.contains l "weekly")

let near_usage_label = fun names i ->
  let len = List.length names in
  let lo = if i > 4 then i - 4 else 0 in
  let hi = if i + 4 < len then i + 4 else len - 1 in
  let rec go j =
    if j > hi then
      false
    else if usage_label (List.get_unchecked names ~at:j) then
      true
    else
      go (j + 1)
  in
  go lo

let extract = fun (names : string list) ->
  let names = List.filter_map names ~fn:short in
  let len = List.length names in
  let plan = ref "" in
  let usage = ref "" in
  let tokens = ref "" in
  let total_locked = ref false in
  let reset = ref "" in
  let rec loop i =
    if i >= len then
      ()
    else (
      let name = List.get_unchecked names ~at:i in
      if String.is_empty !plan && is_current_plan name then (
        let rec look k =
          if k > 3 || i + k >= len then
            ()
          else
            let cand = List.get_unchecked names ~at:(i + k) in
            if is_plan cand then plan := cand else look (k + 1)
        in
        look 1
      );
      if String.is_empty !usage then (
        match usage_of name with
        | Some u when near_usage_label names i -> usage := u
        | _ -> ()
      );
      if (not !total_locked) && token_total_label name then (
        match adjacent_count names i (prefers_total name) with
        | Some v ->
            tokens := v;
            if prefers_total name then total_locked := true
        | None -> ()
      );
      if (not !total_locked) && String.is_empty !tokens && credit_balance_label name then (
        match count_within names i with
        | Some v -> tokens := v ^ " credits"
        | None -> ()
      );
      if String.is_empty !tokens then (
        match fraction_of name with
        | Some f when neighbor names i [ "token"; "usage"; "额度"; "limit" ] -> tokens := f
        | _ -> ()
      );
      if String.is_empty !reset then (
        match reset_of name with
        | Some r -> reset := r
        | None -> ()
      );
      loop (i + 1)
    )
  in
  loop 0;
  { plan = !plan; usage = !usage; tokens = !tokens; reset = !reset }

let useful = fun (s : seen) ->
  (not (String.is_empty s.plan)) || (not (String.is_empty s.usage)) || (not (String.is_empty s.tokens)) || (not (String.is_empty s.reset))

let names_of = fun body ->
  match Json.from_string body with
  | Error _ -> []
  | Ok j ->
      let acc = ref [] in
      let rec walk j =
        match Json.get_object j with
        | None -> (
            match Json.get_array j with
            | None -> ()
            | Some items -> List.for_each items ~fn:walk
          )
        | Some _ ->
            (match Json.get_field "name" j |> Option.and_then ~fn:Json.get_string with
            | Some n -> (
                match short n with
                | Some s -> acc := s :: !acc
                | None -> ()
              )
            | None -> ());
            match Json.get_field "children" j |> Option.and_then ~fn:Json.get_array with
            | Some kids -> List.for_each kids ~fn:walk
            | None -> (
                match Json.get_field "tree" j with
                | Some t -> walk t
                | None -> (
                    match Json.get_field "data" j with
                    | Some d -> walk d
                    | None -> ()
                  )
              )
      in
      walk j;
      List.rev !acc

let error_code = fun body ->
  match Json.from_string body with
  | Error _ -> ""
  | Ok j ->
      Json.get_field "error" j
      |> Option.and_then ~fn:(fun e -> Json.get_field "code" e)
      |> Option.and_then ~fn:Json.get_string
      |> Option.unwrap_or ~default:""

let now_s = fun () -> Time.SystemTime.to_unix_timestamp (Time.SystemTime.now ())

let capture = fun ~program ~args ~timeout_s ->
  let stdio = { Process.stdin = Process.Stdin.Null; stdout = Process.Stdout.Pipe; stderr = Process.Stderr.Null } in
  match Process.spawn ~program ~args ~stdio () with
  | Error _ -> None
  | Ok proc ->
      let deadline = now_s () + timeout_s in
      let buf = ref "" in
      let raw = IO.Bytes.create ~size:8192 in
      let rec read_some () =
        match Process.stdout proc with
        | None -> false
        | Some file -> (
            match Fs.File.read file raw ~offset:0 ~len:8192 with
            | Ok n when n > 0 ->
                let chunk = IO.Bytes.to_string raw |> fun s -> String.sub s ~offset:0 ~len:n in
                buf := !buf ^ chunk;
                true
            | _ -> false
          )
      in
      let exited () =
        match Process.try_wait proc with
        | Ok (Some (Process.Exited _ | Process.Signaled _)) -> true
        | _ -> false
      in
      let rec loop () =
        if String.length !buf > 1500000 || now_s () > deadline then
          let _ = Process.kill proc ~signal:9 in
          ()
        else if read_some () then
          loop ()
        else if exited () then
          let _ = read_some () in
          ()
        else (
          sleep (Time.Duration.from_millis 30);
          loop ()
        )
      in
      loop ();
      let _ = Process.close proc in
      Some !buf

let argv = fun items -> Array.init ~count:(List.length items) ~fn:(fun i -> List.get_unchecked items ~at:i)

type window = { app: string; wid: string }

let open_windows = fun ~program ->
  match capture ~program ~args:(argv [ "list-windows" ]) ~timeout_s:8 with
  | None -> []
  | Some body -> (
      match Json.from_string body with
      | Error _ -> []
      | Ok j ->
          let arr = Json.get_field "data" j |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[] in
          let found = ref [] in
          List.for_each arr ~fn:(fun w ->
            match Json.get_field "app_name" w |> Option.and_then ~fn:Json.get_string with
            | None -> ()
            | Some name -> (
                match Json.get_field "id" w |> Option.and_then ~fn:Json.get_string with
                | None -> ()
                | Some wid ->
                    let visible = Json.get_field "visible" w |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false in
                    let minimized = Json.get_field "minimized" w |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false in
                    if visible && (not minimized) && is_watched name then found := { app = name; wid } :: !found
              ));
          List.rev !found
    )

let app_names = fun wins ->
  let found = ref [] in
  List.for_each wins ~fn:(fun w -> if not (List.any !found ~fn:(String.equal w.app)) then found := w.app :: !found);
  List.rev !found

let fill = fun a b -> if String.is_empty a then b else a

let merge_seen = fun (a : seen) (b : seen) ->
  { plan = fill a.plan b.plan; usage = fill a.usage b.usage; tokens = fill a.tokens b.tokens; reset = fill a.reset b.reset }

let reading_of = fun ~app (s : seen) ->
  { app; plan = s.plan; usage = s.usage; tokens = s.tokens; reset = s.reset; seen_unix = now_s () }

let same = fun (a : reading) (s : seen) ->
  String.equal a.plan s.plan && String.equal a.usage s.usage && String.equal a.tokens s.tokens && String.equal a.reset s.reset

let reading_json = fun (r : reading) ->
  Json.obj
    [
      ("app", Json.string r.app);
      ("plan", Json.string r.plan);
      ("usage", Json.string r.usage);
      ("tokens", Json.string r.tokens);
      ("reset", Json.string r.reset);
      ("seen_unix", Json.int r.seen_unix);
    ]

let remember = fun ~data_dir ~app (s : seen) ->
  let cur = Sync.Atomic.get readings in
  let old = List.find cur ~fn:(fun r -> String.equal r.app app) in
  let changed = match old with None -> true | Some r -> not (same r s) in
  let next = reading_of ~app s in
  let rest = List.filter cur ~fn:(fun r -> not (String.equal r.app app)) in
  Sync.Atomic.set readings (next :: rest);
  let body =
    Json.to_string
      (Json.obj
        [
          ("note", Json.string (Sync.Atomic.get note));
          ("readings", Json.array (List.map (Sync.Atomic.get readings) ~fn:reading_json));
        ])
  in
  match Path.from_string (data_dir ^ "/app-usage.json") with
  | Error _ -> ()
  | Ok p ->
      let _ = Fs.write body p in
      let _ = Fs.set_permissions p (Fs.Permissions.from_mode 0o600) in
      if changed then
        match Path.from_string (data_dir ^ "/app-usage.jsonl") with
        | Error _ -> ()
        | Ok log ->
            let prev = match Fs.read_to_string log with Ok t -> t | Error _ -> "" in
            let _ = Fs.write (prev ^ Json.to_string (reading_json next) ^ "\n") log in
            let _ = Fs.set_permissions log (Fs.Permissions.from_mode 0o600) in
            ()
      else
        ()

let load = fun ~data_dir ->
  match Path.from_string (data_dir ^ "/app-usage.json") with
  | Error _ -> ()
  | Ok p -> (
      match Fs.read_to_string p with
      | Error _ -> ()
      | Ok body -> (
          match Json.from_string body with
          | Error _ -> ()
          | Ok j ->
              let rs =
                Json.get_field "readings" j |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
                |> List.filter_map ~fn:(fun item ->
                  match Json.get_field "app" item |> Option.and_then ~fn:Json.get_string with
                  | None -> None
                  | Some app ->
                      let str k = Json.get_field k item |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:"" in
                      let seen_unix = Json.get_field "seen_unix" item |> Option.and_then ~fn:Json.get_int |> Option.unwrap_or ~default:0 in
                      Some { app; plan = str "plan"; usage = str "usage"; tokens = str "tokens"; reset = str "reset"; seen_unix })
              in
              Sync.Atomic.set readings rs;
              match Json.get_field "note" j |> Option.and_then ~fn:Json.get_string with
              | Some n -> Sync.Atomic.set note n
              | None -> ()
        )
    )

let unread = Sync.Atomic.make ""

let look = fun ~program ~app ~wid ->
  let args = argv [ "snapshot"; "--app"; app; "--window-id"; wid; "--compact"; "--max-depth"; "14"; "--timeout-ms"; "3000" ] in
  match capture ~program ~args ~timeout_s:8 with
  | None -> ("skip", empty_seen)
  | Some body ->
      let code = error_code body in
      if String.equal code "PERM_DENIED" then (
        Sync.Atomic.set note "permission";
        ("permission", empty_seen)
      ) else if String.equal code "TIMEOUT" then
        ("timeout", empty_seen)
      else (
        if not (String.equal (Sync.Atomic.get note) "permission") then Sync.Atomic.set note "";
        let seen = extract (names_of body) in
        if useful seen then ("read", seen) else ("blank", empty_seen)
      )

let join_comma = fun xs ->
  let rec go = fun xs ->
    match xs with
    | [] -> ""
    | [ x ] -> x
    | x :: rest -> x ^ ", " ^ go rest
  in
  go xs

let poll = fun ~data_dir ->
  match Oasis_discover.locate_command ~home:(Oasis_config.user_home ()) "agent-desktop" with
  | None -> Sync.Atomic.set note "no_tool"
  | Some program -> (
      if String.equal (Sync.Atomic.get note) "no_tool" then Sync.Atomic.set note "";
      match open_windows ~program with
      | [] -> ()
      | wins ->
          let apps = app_names wins in
          let timed = ref [] in
          List.for_each apps ~fn:(fun app ->
            if not (String.equal (Sync.Atomic.get note) "permission") then
              let mine = List.filter wins ~fn:(fun w -> String.equal w.app app) in
              let acc = ref empty_seen in
              let any_read = ref false in
              let any_timeout = ref false in
              let any_ok = ref false in
              List.for_each mine ~fn:(fun w ->
                if not (String.equal (Sync.Atomic.get note) "permission") then
                  let (outcome, seen) = look ~program ~app:w.app ~wid:w.wid in
                  if String.equal outcome "timeout" then
                    any_timeout := true
                  else
                    any_ok := true;
                  if useful seen then (
                    any_read := true;
                    acc := merge_seen !acc seen
                  ));
              if !any_read then remember ~data_dir ~app !acc;
              if !any_timeout && not !any_ok then timed := app :: !timed);
          Sync.Atomic.set unread (join_comma (List.rev !timed));
          if String.is_empty (Sync.Atomic.get note) && List.length (Sync.Atomic.get readings) = 0 then
            Sync.Atomic.set note ("idle:" ^ join_comma apps)
    )

let poll_every_s = 15 * 60

let start = fun ~data_dir ->
  load ~data_dir;
  let _ =
    spawn (fun () ->
      sleep (Time.Duration.from_secs 8);
      let rec loop () =
        if allowed () then poll ~data_dir;
        sleep (Time.Duration.from_secs poll_every_s);
        loop ()
      in
      loop ())
  in
  ()

let status_json = fun () ->
  Json.obj
    [
      ("allowed", Json.bool (allowed ()));
      ("note", Json.string (Sync.Atomic.get note));
      ("unread", Json.string (Sync.Atomic.get unread));
      ("readings", Json.array (List.map (Sync.Atomic.get readings) ~fn:reading_json));
    ]
