open Std
open Std.Collections

(** Real-time per-account signals (懂实时情况): request windows (RPM/TPM),
    latency EMA, error rate, in-flight count, and a circuit breaker. State
    lives in shared structures (ETS-style) so it survives actor restarts.

    Pure transition helpers are exported for unit tests; the stateful
    wrapper stores everything in a ConcurrentHashMap. *)

type breaker_state =
  | Closed
  | Open_until of int
  | Half_open

type signals = {
  window_start_ms: int;
  requests_in_window: int;
  tokens_in_window: int;
  latency_ema_ms: int;
  errors_in_window: int;
  total_requests: int;
  consecutive_failures: int;
  in_flight: int;
  breaker: breaker_state;
  last_error: string option;
  parked_until_ms: int;
  auth_invalid: bool;
}

type error_class =
  | Transient
  | Quota
  | Client of { auth: bool }

let fresh = fun () ->
  {
    window_start_ms = 0;
    requests_in_window = 0;
    tokens_in_window = 0;
    latency_ema_ms = 800;
    errors_in_window = 0;
    total_requests = 0;
    consecutive_failures = 0;
    in_flight = 0;
    breaker = Closed;
    last_error = None;
    parked_until_ms = 0;
    auth_invalid = false;
  }

(** Wall-clock milliseconds since the Unix epoch. Breaker deadlines, rate
    windows and quota parking all compare against this, and parking is
    persisted across restarts, so it must not be a per-process counter. *)
let now_ms = fun () ->
  Time.Duration.to_millis (Time.SystemTime.duration_since_epoch ())

(* ---------- secret redaction (spec §5.3) ---------- *)

let is_secret_char = fun c ->
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '~' | '+' | '/' | '=' -> true
  | _ -> false

(** Replaces the token after each [marker] with [****] when it is at least
    [min_len] characters long. *)
let mask_after = fun s ~marker ~min_len ->
  let n = String.length s in
  let m = String.length marker in
  let out = StringBuilder.create ~size:n in
  let matches_at i =
    if i + m > n then false else String.equal (String.sub s ~offset:i ~len:m) marker
  in
  let rec token_end j = if j < n then if is_secret_char (String.get_unchecked s ~at:j) then token_end (j + 1) else j else j in
  let rec go i =
    if i < n then
      if matches_at i then (
        let j = token_end (i + m) in
        StringBuilder.add_string out marker;
        if j - (i + m) >= min_len then StringBuilder.add_string out "****"
        else StringBuilder.add_string out (String.sub s ~offset:(i + m) ~len:(j - (i + m)));
        go j
      ) else (
        StringBuilder.add_char out (String.get_unchecked s ~at:i);
        go (i + 1)
      )
  in
  go 0;
  StringBuilder.contents out

(** Upstream error bodies sometimes echo the key back; nothing that reaches
    decisions, signals, the dashboard or logs may carry one. *)
let redact_secrets = fun s ->
  mask_after s ~marker:"Bearer " ~min_len:1 |> mask_after ~marker:"sk-" ~min_len:8

(* ---------- failure classification (spec §2.4.1) ---------- *)

let default_quota_markers =
  [ "1113"; "insufficient_quota"; "insufficient_balance"; "balance"; "credit"; "quota"; "余额" ]

let contains_ci = fun haystack needle ->
  String.contains (String.lowercase_ascii haystack) (String.lowercase_ascii needle)

(** [classify_error ~status ~body ~quota_codes] decides how a failed upstream
    call affects the account: [Quota] parks it until its quota resets,
    [Client] errors never trip the breaker, everything else is [Transient]. *)
let classify_error = fun ~(status : int option) ~(body : string) ~(quota_codes : string list) ->
  let quota_marked () =
    List.any (default_quota_markers @ quota_codes) ~fn:(fun m -> contains_ci body m)
  in
  match status with
  | Some 402 -> Quota
  | Some 429 -> if quota_marked () then Quota else Transient
  | Some (401 | 403) -> Client { auth = true }
  | Some (400 | 404 | 413 | 422) -> Client { auth = false }
  | _ -> Transient

let error_class_to_string = function
  | Transient -> "transient"
  | Quota -> "quota"
  | Client { auth = true } -> "client_auth"
  | Client { auth = false } -> "client"

(** Civil date from days since 1970-01-01 (Howard Hinnant's algorithm). *)
let civil_of_days = fun days ->
  let z = days + 719468 in
  let era = (if z >= 0 then z else z - 146096) / 146097 in
  let doe = z - (era * 146097) in
  let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
  let y = yoe + (era * 400) in
  let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
  let mp = ((5 * doy) + 2) / 153 in
  let d = doy - (((153 * mp) + 2) / 5) + 1 in
  let m = if mp < 10 then mp + 3 else mp - 9 in
  ((if m <= 2 then y + 1 else y), m, d)

let days_of_civil = fun ~y ~m ~d ->
  let y = if m <= 2 then y - 1 else y in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let mp = if m > 2 then m - 3 else m + 9 in
  let doy = (((153 * mp) + 2) / 5) + d - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let day_ms = 86_400_000

(** When a parked account's quota resets: the next UTC midnight, or the
    first day of next month (UTC) for [quota_reset = "monthly"]. *)
let quota_reset_at = fun ~now_ms ~reset ->
  let today = now_ms / day_ms in
  if String.equal reset "monthly" then
    let (y, m, _) = civil_of_days today in
    let (y', m') = if m = 12 then (y + 1, 1) else (y, m + 1) in
    days_of_civil ~y:y' ~m:m' ~d:1 * day_ms
  else
    (today + 1) * day_ms

let is_parked = fun (s : signals) now_ms -> s.parked_until_ms > now_ms

(* ---------- pure transitions (unit-testable) ---------- *)

(** Exponential moving average with alpha applied to the newest sample. *)
let ema_update = fun ~alpha ~previous ~sample ->
  let alpha_n = min 1000 (max 0 alpha) in
  let prev_scaled = previous * (1000 - alpha_n) in
  let sample_scaled = sample * alpha_n in
  (prev_scaled + sample_scaled) / 1000

(** Decide whether a failure trips the breaker (window ≥ 5 requests and
    error rate ≥ 50%). *)
let should_trip = fun ~requests ~errors ->
  if requests < 5 then
    false
  else
    errors * 2 >= requests

let breaker_allows = fun (s : signals) now_ms ->
  match s.breaker with
  | Closed -> true
  | Half_open -> true
  | Open_until deadline ->
      if now_ms >= deadline then true else false

let breaker_after_success = fun (s : signals) now_ms ->
  { s with breaker = Closed; errors_in_window = 0; total_requests = s.total_requests + 1 }

let breaker_after_failure = fun (s : signals) now_ms ->
  let errors = s.errors_in_window + 1 in
  let requests = s.total_requests + 1 in
  let s' = { s with errors_in_window = errors; total_requests = requests; last_error = None } in
  if should_trip ~requests ~errors then
    { s' with breaker = Open_until (now_ms + 30000) }
  else
    s'

(** Lazily roll the 60s window when [window_ms] has elapsed. *)
let roll_window = fun (s : signals) now_ms ->
  if s.window_start_ms = 0 then
    { s with window_start_ms = now_ms; requests_in_window = 0; tokens_in_window = 0; errors_in_window = 0 }
  else if now_ms - s.window_start_ms >= 60000 then
    { s with window_start_ms = now_ms; requests_in_window = 0; tokens_in_window = 0; errors_in_window = 0 }
  else
    s

let record_success = fun (s : signals) ~latency_ms ~tokens now_ms ->
  let s = roll_window s now_ms in
  let next_breaker =
    match s.breaker with
    | Open_until deadline ->
        if now_ms >= deadline then Closed else s.breaker
    | other -> other
  in
  {
    s with
    breaker = next_breaker;
    requests_in_window = s.requests_in_window + 1;
    tokens_in_window = s.tokens_in_window + tokens;
    latency_ema_ms = ema_update ~alpha:250 ~previous:s.latency_ema_ms ~sample:latency_ms;
    total_requests = s.total_requests + 1;
    consecutive_failures = 0;
    in_flight = max 0 (s.in_flight - 1);
    last_error = None;
    auth_invalid = false;
  }

let record_failure = fun (s : signals) ~error now_ms ->
  let s = roll_window s now_ms in
  let errors = s.errors_in_window + 1 in
  let requests = s.total_requests + 1 in
  let consecutive = s.consecutive_failures + 1 in
  (* trip on window error-rate OR on time-independent consecutive failures
     (an account that fails on every request must not stay usable forever) *)
  let rate_trip = should_trip ~requests ~errors in
  let consecutive_trip = consecutive >= 5 in
  let tripped =
    match s.breaker with
    | Closed -> rate_trip || consecutive_trip
    | Half_open -> true
    | Open_until deadline -> now_ms < deadline
  in
  {
    s with
    errors_in_window = errors;
    total_requests = requests;
    consecutive_failures = consecutive;
    in_flight = max 0 (s.in_flight - 1);
    breaker =
      (if tripped then Open_until (now_ms + 30000) else s.breaker);
    last_error = Some (redact_secrets error);
  }

(** Quota/balance exhaustion: park until [until_ms]. Not a latency sample and
    not a breaker event — probing every 30s would only burn requests. *)
let record_quota = fun (s : signals) ~error ~until_ms ->
  {
    s with
    in_flight = max 0 (s.in_flight - 1);
    parked_until_ms = max s.parked_until_ms until_ms;
    last_error = Some (redact_secrets error);
  }

(** The request itself was rejected (4xx): no breaker impact; 401/403 flag
    the account's key as invalid. *)
let record_client_error = fun (s : signals) ~error ~auth ->
  {
    s with
    in_flight = max 0 (s.in_flight - 1);
    auth_invalid = s.auth_invalid || auth;
    last_error = Some (redact_secrets error);
  }

let mark_in_flight = fun (s : signals) ->
  { s with in_flight = s.in_flight + 1 }

(** Release one in-flight slot WITHOUT recording success/failure (used when
    the client disconnects or the stream writer errors — not the agent's
    fault, so no breaker impact). *)
let release_in_flight = fun (s : signals) ->
  { s with in_flight = max 0 (s.in_flight - 1) }

let allow_probe = fun (s : signals) now_ms ->
  match s.breaker with
  | Open_until deadline ->
      if now_ms >= deadline then { s with breaker = Half_open } else s
  | other -> s

(* ---------- stateful wrapper ---------- *)

type t = (string, signals) ConcurrentHashMap.t

let init = fun () -> ConcurrentHashMap.with_capacity ~size:16

let get = fun (t : t) account ->
  ConcurrentHashMap.get t ~key:account |> Option.unwrap_or ~default:(fresh ())

let put = fun (t : t) account s ->
  ConcurrentHashMap.insert t ~key:account ~value:s

(** Atomically-ish update via a pure transition. *)
let update = fun (t : t) account ~fn ->
  let s = get t account in
  let s' = fn s in
  let _ = put t account s' in
  s'

let snapshot = fun (t : t) account -> get t account

(* ---------- parked-account persistence ---------- *)

module Json = Std.Data.Json

(** Parking must survive restarts, otherwise an account that ran out of money
    rejoins the pool on every boot. *)
let save_parked = fun (t : t) ~path ->
  let now = now_ms () in
  let entries = ref [] in
  ConcurrentHashMap.for_each t ~fn:(fun account s ->
    if s.parked_until_ms > now then
      entries := (account, Json.int s.parked_until_ms) :: !entries);
  match Path.from_string path with
  | Error _ -> ()
  | Ok p ->
      let _ = Fs.write (Json.to_string (Json.obj !entries)) p in
      ()

let load_parked = fun (t : t) ~path ->
  let now = now_ms () in
  match Path.from_string path with
  | Error _ -> ()
  | Ok p -> (
      match Fs.read_to_string p with
      | Error _ -> ()
      | Ok content -> (
          match Json.from_string content |> Result.to_option |> Option.and_then ~fn:Json.get_object with
          | None -> ()
          | Some fields ->
              List.for_each fields ~fn:(fun (account, v) ->
                match Json.get_int v with
                | Some until when until > now ->
                    let _ = update t account ~fn:(fun s -> { s with parked_until_ms = until }) in
                    ()
                | _ -> ())
        )
    )
