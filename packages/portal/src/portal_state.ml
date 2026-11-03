open Std
open Std.Collections

(** Gateway runtime state shared by every request handler, plus small
    request helpers and the metadata-only audit log. *)

module Trail = Hello_riot.Trail
module Json = Std.Data.Json

type Message.t +=
  | Upstream_result of (int * string * int, string) result
  | Upstream_chunk of int * string
  | Upstream_failed of int * string
  | Upstream_head of int * int * string
  | Upstream_ended of int
  | Conductor_done of (unit, string) result

type state = {
  config_path: string option;
  config: Portal_config.t Sync.Atomic.t;
  ledger: Portal_ledger.t;
  decisions: Portal_router.decision list Agent.t;
  signals: Portal_signals.t;
  sessions: Portal_session.t;
  tasks: Portal_task.t;
  inbox: Portal_inbox.t;
  ws_clients: (int, Net.TcpStream.t) ConcurrentHashMap.t;
  decision_history: Json.t list Sync.Atomic.t;
  decisions_appended: int Sync.Atomic.t;
}

(* ---------- helpers ---------- *)

let data_path = fun (state : state) name ->
  (Sync.Atomic.get state.config).Portal_config.data_dir ^ "/" ^ name

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
  let s = Portal_signals.get state.signals account in
  let now = Portal_signals.now_ms () in
  {
    Portal_router.latency_ema_ms = s.Portal_signals.latency_ema_ms;
    in_flight = s.Portal_signals.in_flight;
    breaker_open =
      (match s.Portal_signals.breaker with
       | Portal_signals.Open_until deadline -> now < deadline
       | _ -> false);
    requests_in_window = s.Portal_signals.requests_in_window;
    parked = Portal_signals.is_parked s now;
  }

let make_lookups = fun (state : state) ->
  {
    Portal_router.month_spent = (fun a -> Portal_ledger.month_spent state.ledger a);
    day_requests = (fun a -> Portal_ledger.day_requests state.ledger a);
    snapshot = (fun a -> snapshot_of state a);
  }

let audit_file = fun (state : state) ->
  let config = Sync.Atomic.get state.config in
  config.Portal_config.data_dir ^ "/requests.jsonl"

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
