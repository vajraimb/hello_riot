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
}

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
  }

let now_ms = fun () ->
  Time.Duration.to_millis (Time.Instant.elapsed (Time.Instant.now ()))

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
    last_error = Some error;
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
