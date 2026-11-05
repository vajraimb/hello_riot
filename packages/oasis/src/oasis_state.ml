open Std
open Std.Collections

(** Gateway runtime state shared by every request handler, plus small
    request helpers and the metadata-only audit log. *)

module Trail = Oasis_net.Trail
module Json = Std.Data.Json

type Message.t +=
  | Upstream_result of (int * string * int, string) result
  | Upstream_chunk of int * string
  | Upstream_failed of int * string
  | Upstream_head of int * int * string
  | Upstream_ended of int
  | Conductor_done of (unit, string) result
  | Committee_answer of int * (string * int, string) result
  | Task_cancel of string

type state = {
  config_path: string option;
  config: Oasis_config.t Sync.Atomic.t;
  ledger: Oasis_ledger.t;
  decisions: Oasis_router.decision list Agent.t;
  signals: Oasis_signals.t;
  sessions: Oasis_session.t;
  tasks: Oasis_task.t;
  inbox: Oasis_inbox.t;
  ws_clients: (int, Net.TcpStream.t) ConcurrentHashMap.t;
  decision_history: Json.t list Sync.Atomic.t;
  decisions_appended: int Sync.Atomic.t;
  feed: Oasis_feed.t;
  quality: Oasis_quality.t;
  route_turns: int Sync.Atomic.t;
  running: (string, Pid.t) ConcurrentHashMap.t;
  threads: Oasis_thread.t;
}

let threads_file = fun (state : state) -> (Sync.Atomic.get state.config).Oasis_config.data_dir ^ "/threads.json"

(* ---------- cancellation ---------- *)

(** [Task_cancel] reasons: "user" (stop button / API) or "timeout:<secs>"
    (deadline the caller asked for via X-Oasis-Timeout). Oasis itself never
    imposes a task deadline. *)
let watch_task = fun (state : state) ?pid ~request_id () ->
  if not (String.is_empty request_id) then
    let pid = match pid with Some p -> p | None -> self () in
    ignore (ConcurrentHashMap.insert state.running ~key:request_id ~value:pid)

let unwatch_task = fun (state : state) ~request_id ->
  ignore (ConcurrentHashMap.remove state.running ~key:request_id)

let is_running = fun (state : state) ~request_id ->
  Option.is_some (ConcurrentHashMap.get state.running ~key:request_id)

let cancel_task = fun (state : state) ~request_id ~reason ->
  match ConcurrentHashMap.get state.running ~key:request_id with
  | None -> false
  | Some pid ->
      send pid (Task_cancel reason);
      true

let cancel_error = fun reason -> "cancelled:" ^ reason

let cancel_reason_of = fun err ->
  if String.starts_with ~prefix:"cancelled:" err then
    Some (String.sub err ~offset:10 ~len:(String.length err - 10))
  else None

let cancel_text = fun reason ->
  if String.starts_with ~prefix:"timeout:" reason then
    "超过调用方设定的时限（" ^ String.sub reason ~offset:8 ~len:(String.length reason - 8) ^ "s），已停止"
  else "已手动停止"

(** Arms the caller's X-Oasis-Timeout: cancels the task after [secs] if it
    is still running then. *)
let arm_deadline = fun (state : state) ~request_id ~secs ->
  if secs > 0 then
    ignore
      (spawn (fun () ->
        (try
           let (_ : unit) = receive ~selector:(fun _ -> Skip) ~timeout:(Time.Duration.from_secs secs) () in
           ()
         with Receive_timeout -> ());
        ignore (cancel_task state ~request_id ~reason:("timeout:" ^ Int.to_string secs));
        Ok ()))

let header_timeout = fun (ctx : Trail.ctx) ->
  Net.Http.Request.get_header ctx.req "x-oasis-timeout"
  |> Option.and_then ~fn:(fun s -> Int.from_string_opt (String.trim s))
  |> Option.and_then ~fn:(fun n -> if n > 0 then Some n else None)

(* ---------- helpers ---------- *)

let data_path = fun (state : state) name ->
  (Sync.Atomic.get state.config).Oasis_config.data_dir ^ "/" ^ name

let parked_file = fun (state : state) -> data_path state "parked.json"

let parse_json_body = fun (ctx : Trail.ctx) ->
  match Net.Http.Request.body_string ctx.req with
  | None -> Json.obj []
  | Some s -> (
      match Json.from_string s with
      | Ok j -> j
      | Error _ -> Json.obj []
    )

let get_header = fun (ctx : Trail.ctx) name ->
  Net.Http.Request.get_header ctx.req name

let constant_time_equal = fun a b ->
  if String.length a != String.length b then false
  else
    let diff = ref 0 in
    for i = 0 to String.length a - 1 do
      diff := !diff lor (Char.code (String.get_unchecked a ~at:i) lxor Char.code (String.get_unchecked b ~at:i))
    done;
    !diff = 0

let percent_decode = fun s ->
  let n = String.length s in
  let buf = StringBuilder.create ~size:n in
  let hex c =
    match c with
    | '0' .. '9' -> Some (Char.code c - 48)
    | 'a' .. 'f' -> Some (Char.code c - 87)
    | 'A' .. 'F' -> Some (Char.code c - 55)
    | _ -> None
  in
  let escaped i =
    if i + 2 < n then
      match (hex (String.get_unchecked s ~at:(i + 1)), hex (String.get_unchecked s ~at:(i + 2))) with
      | (Some a, Some b) -> Some (Char.from_int_unchecked ((a * 16) + b))
      | _ -> None
    else None
  in
  let rec go i =
    if i < n then
      match String.get_unchecked s ~at:i with
      | '%' -> (
          match escaped i with
          | Some c ->
              StringBuilder.add_char buf c;
              go (i + 3)
          | None ->
              StringBuilder.add_char buf '%';
              go (i + 1)
        )
      | c ->
          StringBuilder.add_char buf c;
          go (i + 1)
  in
  go 0;
  StringBuilder.contents buf

let query_param = fun (ctx : Trail.ctx) name ->
  match Net.Uri.query (Net.Http.Request.uri ctx.req) with
  | None -> None
  | Some q ->
      String.split ~by:"&" q
      |> List.filter_map ~fn:(fun kv ->
        match String.split ~by:"=" kv with
        | k :: rest when String.equal k name -> Some (percent_decode (String.concat "=" rest))
        | _ -> None)
      |> List.head


let est_input_tokens = fun (body : Json.t) ->
  match Json.get_field "messages" body |> Option.and_then ~fn:Json.get_array with
  | None -> 0
  | Some msgs ->
      let total_chars =
        List.fold_left
          msgs
          ~init:0
          ~fn:(fun acc m ->
            let content =
              Json.get_field "content" m |> Option.and_then ~fn:Json.get_string
              |> Option.unwrap_or ~default:""
            in
            let role =
              Json.get_field "role" m |> Option.and_then ~fn:Json.get_string
              |> Option.unwrap_or ~default:""
            in
            acc + String.length content + String.length role)
      in
      max 1 (total_chars / 4)

let new_request_id = fun () ->
  let pick bound =
    match Random.int bound with
    | Ok v -> v
    | Error _ -> 0
  in
  "req-" ^ Int.to_string (pick 1000000000)

let snapshot_of = fun (state : state) account ->
  let s = Oasis_signals.get state.signals account in
  let now = Oasis_signals.now_ms () in
  {
    Oasis_router.latency_ema_ms = s.Oasis_signals.latency_ema_ms;
    latency_samples = s.Oasis_signals.latency_samples;
    in_flight = s.Oasis_signals.in_flight;
    breaker_open =
      (match s.Oasis_signals.breaker with
       | Oasis_signals.Open_until deadline -> now < deadline
       | _ -> false);
    requests_in_window = s.Oasis_signals.requests_in_window;
    parked = Oasis_signals.is_parked s now;
  }

let make_lookups = fun (state : state) ->
  {
    Oasis_router.month_spent = (fun a -> Oasis_ledger.month_spent state.ledger a);
    day_requests = (fun a -> Oasis_ledger.day_requests state.ledger a);
    snapshot = (fun a -> snapshot_of state a);
    quality = (fun ~account ~category -> Oasis_quality.get state.quality ~account ~category);
  }

let quality_file = fun (state : state) -> data_path state "quality.json"

(** True on every [policy.explore_every]-th routing decision. *)
let explore_turn = fun (state : state) ->
  let every = (Sync.Atomic.get state.config).Oasis_config.policy.Oasis_config.explore_every in
  let n = Sync.Atomic.get state.route_turns + 1 in
  Sync.Atomic.set state.route_turns n;
  if every <= 0 then false else n mod every = 0

(** Applies the exploration turn to a decision; [samples] counts how often
    each candidate has been measured. *)
let maybe_explore = fun (state : state) (d : Oasis_router.decision) ->
  if explore_turn state then
    Oasis_router.explore d ~samples:(fun a -> (Oasis_signals.get state.signals a).Oasis_signals.latency_samples)
  else d

let audit_file = fun (state : state) ->
  let config = Sync.Atomic.get state.config in
  config.Oasis_config.data_dir ^ "/requests.jsonl"

(** FNV-1a (32-bit) as 8 hex digits: lets the audit log correlate identical
    requests without storing their content. *)
let hash8 = fun s ->
  let h = ref 0x811c9dc5 in
  for i = 0 to String.length s - 1 do
    h := ((!h lxor Char.code (String.get_unchecked s ~at:i)) * 0x01000193) land 0xffffffff
  done;
  let hex = "0123456789abcdef" in
  String.concat ""
    (List.init ~count:8 ~fn:(fun k ->
      let nib = (!h lsr ((7 - k) * 4)) land 0xf in
      String.sub hex ~offset:nib ~len:1))

(** One line per request: metadata only, never prompt or completion text. *)
let audit_log = fun (state : state) ~path ~category ~goal ~stream_ ?(request_id = "") ?(body = "") () ->
  let line =
    Json.to_string
      (Json.obj
        [
          ("ts", Json.float (Time.SystemTime.now () |> Time.SystemTime.secs_float));
          ("path", Json.string path);
          ("category", Json.string category);
          ("goal", Json.string goal);
          ("stream", Json.bool stream_);
          ("request_id", Json.string request_id);
          ("body_len", Json.int (String.length body));
          ("body_hash8", Json.string (hash8 body));
        ])
    ^ "\n"
  in
  match Fs.File.open_append (Path.from_string (audit_file state) |> Result.unwrap) with
  | Ok file ->
      let _ = Fs.File.write_all file line in
      let _ = Fs.File.close file in
      ()
  | Error _ -> ()
