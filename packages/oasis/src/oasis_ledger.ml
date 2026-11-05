open Std
open Std.Collections

module Json = Std.Data.Json

(** Cost ledger (懂成本): per-account daily request counts and monthly spend in
    integer nano-dollars, plus a ring of recent usage entries. State lives in
    shared structures (ETS-style), so it survives actor restarts. Persists to
    <data_dir>/ledger.jsonl by snapshot rewrite. *)

type usage = {
  seq: int;
  unix_s: int;
  account: string;
  model: string;
  in_tokens: int;
  out_tokens: int;
  cache_tokens: int;
  cost_nano: int;
  latency_ms: int;
  status: string;
}

type account_state = {
  day_key: int;
  day_requests: int;
  month_cost_nano: int;
  month_requests: int;
}

type t = {
  entries: usage list Agent.t;
  states: (string, account_state) ConcurrentHashMap.t;
  seq: int Sync.Atomic.t;
  data_dir: string option;
}

let empty_state = { day_key = 0; day_requests = 0; month_cost_nano = 0; month_requests = 0 }

let today_key = fun () ->
  Time.SystemTime.to_unix_timestamp (Time.SystemTime.now ()) / 86400

(** Pure state transition, unit-testable (day rollover etc.). *)
let apply_record = fun (s : account_state) (u : usage) ->
  let key = u.unix_s / 86400 in
  let day_requests =
    if s.day_key = key then s.day_requests + 1 else 1
  in
  {
    day_key = key;
    day_requests;
    month_cost_nano = s.month_cost_nano + u.cost_nano;
    month_requests = s.month_requests + 1;
  }

let usage_to_json = fun (u : usage) ->
  Json.obj
    [
      ("seq", Json.int u.seq);
      ("unix_s", Json.int u.unix_s);
      ("account", Json.string u.account);
      ("model", Json.string u.model);
      ("in_tokens", Json.int u.in_tokens);
      ("out_tokens", Json.int u.out_tokens);
      ("cache_tokens", Json.int u.cache_tokens);
      ("cost_nano", Json.int u.cost_nano);
      ("latency_ms", Json.int u.latency_ms);
      ("status", Json.string u.status);
    ]

let init = fun ?data_dir () ->
  (
    match data_dir with
    | None -> ()
    | Some dir -> (
        match Fs.create_dir_all (Path.from_string dir |> Result.unwrap) with
        | Ok () -> ()
        | Error _ -> ()
      )
  );
  {
    entries = Agent.start ~fn:(fun () -> []);
    states = ConcurrentHashMap.with_capacity ~size:16;
    seq = Sync.Atomic.make 0;
    data_dir;
  }

let persist = fun (t : t) ->
  match t.data_dir with
  | None -> ()
  | Some dir ->
      let lines =
        Agent.get t.entries ~fn:(fun es ->
          List.rev es |> List.map ~fn:(fun u -> Json.to_string (usage_to_json u)))
      in
      let body =
        if List.is_empty lines then
          ""
        else
          String.concat "\n" lines ^ "\n"
      in
      let _ =
        Fs.write body (Path.from_string (dir ^ "/ledger.jsonl") |> Result.unwrap)
      in
      ()

let record =
  fun
    t
    ~account
    ~model
    ~in_tokens
    ~out_tokens
    ~cache_tokens
    ~cost_nano
    ~latency_ms
    ~status
    () ->
  let unix_s = Time.SystemTime.to_unix_timestamp (Time.SystemTime.now ()) in
  let seq = Sync.Atomic.fetch_and_add t.seq 1 in
  let u =
    { seq; unix_s; account; model; in_tokens; out_tokens; cache_tokens; cost_nano; latency_ms; status }
  in
  Agent.cast t.entries ~fn:(fun es -> List.take (u :: es) ~len:500);
  let next =
    ConcurrentHashMap.get t.states ~key:account
    |> Option.unwrap_or ~default:empty_state
    |> fun s -> apply_record s u
  in
  let _ = ConcurrentHashMap.insert t.states ~key:account ~value:next in
  persist t

let state_of = fun (t : t) account ->
  ConcurrentHashMap.get t.states ~key:account
  |> Option.unwrap_or ~default:empty_state

let month_spent = fun (t : t) account -> (state_of t account).month_cost_nano

let day_requests = fun (t : t) account -> (state_of t account).day_requests

let recent = fun (t : t) ~len ->
  Agent.get t.entries ~fn:(fun es -> List.take es ~len)

let rec format_usd = fun nano ->
  if nano < 0 then
    "-" ^ format_usd (-nano)
  else
    let dollars = nano / 1_000_000_000 in
    let frac = nano mod 1_000_000_000 in
    let frac_str =
      Int.to_string (frac + 1_000_000_000)
      |> fun s -> String.sub s ~offset:1 ~len:9
    in
    "$" ^ Int.to_string dollars ^ "." ^ frac_str
