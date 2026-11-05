open Std

module Json = Std.Data.Json

(** v1 static scheduler: hard-constraint filtering over a category routing
    table, producing an explainable decision (chosen account, fallback chain,
    and per-account rejection reasons). Pure w.r.t. account state, which is
    injected as lookup functions. *)

type task = {
  category: string;
  model: string option;
  est_in_tokens: int;
  est_out_tokens: int;
}

type rejected = {
  account: string;
  reason: string;
}

type attempt = {
  account: string;
  model: string;
  status: int option;
  error: string option;
  latency_ms: int;
  cost_nano: int;
}

(** One mid-stream account switch (spec §3.4). [level] is G1/G2/G3, or
    G0 when the continuation leg itself failed before it was classified. *)
type handoff = {
  from_account: string;
  to_account: string;
  reason: string;
  sent_bytes: int;
  matched_bytes: int;
  diverged: bool;
  level: string;
  model_changed: bool;
  at_ms: int;
}

type decision = {
  task_category: string;
  chosen: string option;
  fallback_order: string list;
  rejected: rejected list;
  attempts: attempt list;
  scores: (string * int) list;
  parts: (string * Json.t) list;
  explored: bool;
  unpriced: string list;
  handoffs: handoff list;
}

let decision_schema = 2

type goal =
  | Cheapest
  | Fastest
  | Best
  | Balanced

let goal_of_string = function
  | "cheapest" -> Cheapest
  | "fastest" -> Fastest
  | "best" -> Best
  | _ -> Balanced

type account_snapshot = {
  latency_ema_ms: int;
  latency_samples: int;
  in_flight: int;
  breaker_open: bool;
  requests_in_window: int;
  parked: bool;
}

type lookups = {
  month_spent: string -> int;
  day_requests: string -> int;
}

let empty_decision = fun category ->
  {
    task_category = category;
    chosen = None;
    fallback_order = [];
    rejected = [];
    attempts = [];
    scores = [];
    parts = [];
    explored = false;
    unpriced = [];
    handoffs = [];
  }

let handoff_json = fun (h : handoff) ->
  Json.obj
    [
      ("from", Json.string h.from_account);
      ("to", Json.string h.to_account);
      ("reason", Json.string h.reason);
      ("sent_bytes", Json.int h.sent_bytes);
      ("matched_bytes", Json.int h.matched_bytes);
      ("diverged", Json.bool h.diverged);
      ("level", Json.string h.level);
      ("model_changed", Json.bool h.model_changed);
      ("at_ms", Json.int h.at_ms);
    ]

let decision_json = fun (d : decision) ->
  Json.obj
    [
      ("schema", Json.int decision_schema);
      ("task_category", Json.string d.task_category);
      (
        "chosen",
        match d.chosen with Some c -> Json.string c | None -> Json.null
      );
      (
        "fallback_order",
        Json.array (List.map d.fallback_order ~fn:Json.string)
      );
      (
        "rejected",
        Json.array
          (List.map
            d.rejected
            ~fn:(fun r ->
              Json.obj
                [
                  ("account", Json.string r.account);
                  ("reason", Json.string r.reason);
                ]))
      );
      (
        "attempts",
        Json.array
          (List.map
            d.attempts
            ~fn:(fun a ->
              Json.obj
                [
                  ("account", Json.string a.account);
                  ("model", Json.string a.model);
                  (
                    "status",
                    match a.status with
                    | Some s -> Json.int s
                    | None -> Json.null
                  );
                  (
                    "error",
                    match a.error with
                    | Some e -> Json.string e
                    | None -> Json.null
                  );
                  ("latency_ms", Json.int a.latency_ms);
                  ("cost_nano", Json.int a.cost_nano);
                ]))
      );
      (
        "scores",
        Json.array
          (List.map
            d.scores
            ~fn:(fun (name, score) ->
              Json.obj
                [
                  ("account", Json.string name);
                  ("score", Json.int score);
                  ("price_known", Json.bool (not (List.any d.unpriced ~fn:(String.equal name))));
                  ("parts", List.find d.parts ~fn:(fun (n, _) -> String.equal n name) |> Option.map ~fn:(fun (_, p) -> p) |> Option.unwrap_or ~default:Json.null);
                ]))
      );
      ("handoffs", Json.array (List.map d.handoffs ~fn:handoff_json));
      ("explored", Json.bool d.explored);
    ]

let route = fun (config : Oasis_config.t) (lookups : lookups) (task : task) ->
  let candidates =
    match Oasis_config.route_for config task.category with
    | Some r -> r.Oasis_config.accounts
    | None ->
        List.map
          config.Oasis_config.accounts
          ~fn:(fun a -> a.Oasis_config.name)
  in
  let rejects = ref [] in
  let check (name : string) : bool =
    match Oasis_config.find_account config name with
    | None ->
        rejects := { account = name; reason = "unknown_account" } :: !rejects;
        false
    | Some acc ->
        if not acc.Oasis_config.enabled then (
          rejects := { account = name; reason = "disabled" } :: !rejects;
          false
        ) else
          let model_opt =
            match task.model with
            | Some m ->
                if List.any acc.Oasis_config.models ~fn:(String.equal m) then
                  Some m
                else
                  None
            | None -> List.head acc.Oasis_config.models
          in
          (
            match model_opt with
            | None ->
                rejects := { account = name; reason = "model_not_served" } :: !rejects;
                false
            | Some model -> (
                match Oasis_kb.find config.Oasis_config.kb model with
                | None -> true
                | Some kb_entry ->
                    let fits_context =
                      Oasis_kb.context_ok
                        kb_entry
                        ~in_tokens:task.est_in_tokens
                        ~out_tokens:task.est_out_tokens
                    in
                    let est_cost =
                      Oasis_kb.est_cost_nano
                        kb_entry
                        ~cache_tokens:0
                        ~in_tokens:task.est_in_tokens
                        ~out_tokens:task.est_out_tokens
                    in
                    let spent = lookups.month_spent name in
                    let budget_ok =
                      if acc.Oasis_config.monthly_budget_nano <= 0 then
                        true
                      else
                        spent + est_cost <= acc.Oasis_config.monthly_budget_nano
                    in
                    let day_ok =
                      if acc.Oasis_config.daily_limit <= 0 then
                        true
                      else
                        lookups.day_requests name < acc.Oasis_config.daily_limit
                    in
                    if not fits_context then (
                      rejects :=
                        { account = name; reason = "context_too_small" } :: !rejects;
                      false
                    ) else if not budget_ok then (
                      rejects :=
                        { account = name; reason = "budget_exhausted" } :: !rejects;
                      false
                    ) else if not day_ok then (
                      rejects :=
                        { account = name; reason = "daily_limit_reached" } :: !rejects;
                      false
                    ) else
                      true
              )
          )
  in
  let passing = List.filter candidates ~fn:check in
  let chosen = List.head passing in
  let fallback_order =
    match chosen with
    | None -> []
    | Some c ->
        List.filter passing ~fn:(fun a -> not (String.equal a c))
        |> List.take ~len:(max 0 config.Oasis_config.policy.Oasis_config.max_fallback)
  in
  {
    task_category = task.category;
    chosen;
    fallback_order;
    rejected = List.rev !rejects;
    attempts = [];
    scores = [];
    parts = [];
    explored = false;
    unpriced = [];
    handoffs = [];
  }

(* ---------- v2: real-time scored routing ---------- *)

type scored_lookups = {
  month_spent: string -> int;
  day_requests: string -> int;
  snapshot: string -> account_snapshot;
  quality: account:string -> category:string -> Oasis_quality.stat;
}

type weights = {
  w_fit: int;
  w_cost: int;
  w_lat: int;
  w_load: int;
}

let weights_of_goal = function
  | Cheapest -> { w_fit = 20; w_cost = 70; w_lat = 5; w_load = 5 }
  | Fastest -> { w_fit = 10; w_cost = 10; w_lat = 70; w_load = 10 }
  | Best -> { w_fit = 60; w_cost = 10; w_lat = 20; w_load = 10 }
  | Balanced -> { w_fit = 35; w_cost = 25; w_lat = 20; w_load = 20 }

(** Speed relative to the fastest measured candidate: as fast → 100, twice as
    slow → 50, ten times → 10. Unmeasured candidates are neutral (50) so
    neither fresh nor known-slow accounts are favoured by default. *)
let latency_score = fun ~fastest_ms ~ema_ms ~samples ->
  if samples <= 0 then 50
  else (100 * max 1 fastest_ms) / max 1 ema_ms

(** Agents run for tens of seconds to minutes: every 2s of EMA costs 1 point,
    so 30s and 120s agents still score differently. *)
let latency_score_agent = fun ~ema_ms ->
  max 0 (100 - (ema_ms / 2000))

let price_known = fun (kbe : Oasis_kb.model_kb) ->
  kbe.Oasis_kb.in_price_nano > 0 || kbe.Oasis_kb.out_price_nano > 0

let unknown_price_cost_score = 50

(** Cost routing only means something once at least two KB models carry a
    real price. *)
let cost_routing_effective = fun (config : Oasis_config.t) ->
  List.fold_left config.Oasis_config.kb ~init:0 ~fn:(fun n m -> if price_known m then n + 1 else n)
  >= 2

let load_score = fun ~in_flight ->
  max 0 (100 - (in_flight * 15))

let route_scored =
  fun
    (config : Oasis_config.t)
    (lookups : scored_lookups)
    ~(goal : goal)
    (task : task) ->
  let candidates =
    match Oasis_config.route_for config task.category with
    | Some r -> r.Oasis_config.accounts
    | None ->
        List.map
          config.Oasis_config.accounts
          ~fn:(fun a -> a.Oasis_config.name)
  in
  let rejects = ref [] in
  let static_fits = ref [] in
  (* returns (name, model, price_nano (None = unknown), fit, (latency ema, samples), load_score) *)
  let check (name : string) : (string * string * int option * int * (int * int) * int) option =
    match Oasis_config.find_account config name with
    | None ->
        rejects := { account = name; reason = "unknown_account" } :: !rejects;
        None
    | Some acc ->
        if not acc.Oasis_config.enabled then (
          rejects := { account = name; reason = "disabled" } :: !rejects;
          None
        ) else
          let model_opt =
            match task.model with
            | Some m ->
                if List.any acc.Oasis_config.models ~fn:(String.equal m) then
                  Some m
                else
                  None
            | None -> List.head acc.Oasis_config.models
          in
          (
            match model_opt with
            | None ->
                rejects := { account = name; reason = "model_not_served" } :: !rejects;
                None
            | Some model ->
                let kb_entry = Oasis_kb.find config.Oasis_config.kb model in
                let fits_context =
                  match kb_entry with
                  | None -> true
                  | Some kbe ->
                      Oasis_kb.context_ok
                        kbe
                        ~in_tokens:task.est_in_tokens
                        ~out_tokens:task.est_out_tokens
                in
                let price_nano =
                  match kb_entry with
                  | Some kbe when price_known kbe ->
                      Some
                        (Oasis_kb.est_cost_nano
                          kbe
                          ~cache_tokens:0
                          ~in_tokens:task.est_in_tokens
                          ~out_tokens:task.est_out_tokens)
                  | _ -> None
                in
                let fit_static =
                  match kb_entry with
                  | None -> 50
                  | Some kbe -> Oasis_kb.fit kbe ~category:task.category
                in
                let q = lookups.quality ~account:name ~category:task.category in
                let fit = Oasis_quality.blend ~static:fit_static q in
                let spent = lookups.month_spent name in
                let budget_ok =
                  if acc.Oasis_config.monthly_budget_nano <= 0 then
                    true
                  else
                    spent + Option.unwrap_or price_nano ~default:0 <= acc.Oasis_config.monthly_budget_nano
                in
                let day_ok =
                  if acc.Oasis_config.daily_limit <= 0 then
                    true
                  else
                    lookups.day_requests name < acc.Oasis_config.daily_limit
                in
                let snap = lookups.snapshot name in
                let breaker_ok = not snap.breaker_open in
                let parked_ok = not snap.parked in
                let rpm_ok =
                  if acc.Oasis_config.rpm <= 0 then
                    true
                  else
                    snap.requests_in_window < acc.Oasis_config.rpm
                in
                let ok =
                  fits_context
                  && budget_ok
                  && day_ok
                  && parked_ok
                  && breaker_ok
                  && rpm_ok
                in
                if ok then (
                  static_fits := (name, (fit_static, q)) :: !static_fits;
                  Some
                    ( name,
                      model,
                      price_nano,
                      fit,
                      (snap.latency_ema_ms, snap.latency_samples),
                      load_score ~in_flight:snap.in_flight ))
                else (
                  let reason =
                    if not fits_context then
                      "context_too_small"
                    else if not budget_ok then
                      "budget_exhausted"
                    else if not day_ok then
                      "daily_limit_reached"
                    else if not parked_ok then
                      "quota_parked"
                    else if not breaker_ok then
                      "circuit_open"
                    else
                      "rpm_exhausted"
                  in
                  rejects := { account = name; reason } :: !rejects;
                  None
                )
          )
  in
  let passing = List.filter_map candidates ~fn:check in
  let known_prices = List.filter_map passing ~fn:(fun (_, _, p, _, _, _) -> p) in
  let min_price =
    match known_prices with
    | [] -> 0
    | p :: rest -> List.fold_left rest ~init:p ~fn:min
  in
  let max_price = List.fold_left known_prices ~init:min_price ~fn:max in
  let cost_score = function
    | None -> unknown_price_cost_score
    | Some p ->
        if max_price = min_price then 100
        else 100 - (((p - min_price) * 100) / (max_price - min_price))
  in
  let fastest_ms =
    List.filter_map passing ~fn:(fun (_, _, _, _, (ema, n), _) -> if n > 0 then Some ema else None)
    |> List.fold_left ~init:0 ~fn:(fun acc e -> if acc = 0 then e else min acc e)
  in
  let weights = weights_of_goal goal in
  let parts =
    List.map passing ~fn:(fun (name, _, price, fit, (ema, n), load) ->
      ( name,
        Json.obj
          [
            ("fit", Json.int fit);
            (
              "fit_static",
              Json.int (List.find !static_fits ~fn:(fun (n, _) -> String.equal n name) |> Option.map ~fn:(fun (_, (f, _)) -> f) |> Option.unwrap_or ~default:fit)
            );
            (
              "rated",
              Json.int (List.find !static_fits ~fn:(fun (n, _) -> String.equal n name) |> Option.map ~fn:(fun (_, (_, q)) -> q.Oasis_quality.n) |> Option.unwrap_or ~default:0)
            );
            (
              "rating",
              Json.int (List.find !static_fits ~fn:(fun (n, _) -> String.equal n name) |> Option.map ~fn:(fun (_, (_, q)) -> Oasis_quality.mean q) |> Option.unwrap_or ~default:0)
            );
            ("cost", Json.int (cost_score price));
            ("speed", Json.int (latency_score ~fastest_ms ~ema_ms:ema ~samples:n));
            ("load", Json.int load);
            ("latency_ema_ms", Json.int (if n > 0 then ema else 0));
            ("samples", Json.int n);
            ("weights", Json.array [ Json.int weights.w_fit; Json.int weights.w_cost; Json.int weights.w_lat; Json.int weights.w_load ]);
          ] ))
  in
  let indexed =
    List.map
      (List.enumerate passing)
      ~fn:(fun (idx, (name, model, price, fit, (ema, n), load)) ->
        let c_score = cost_score price in
        let lat = latency_score ~fastest_ms ~ema_ms:ema ~samples:n in
        let total =
          ((weights.w_fit * fit)
          + (weights.w_cost * c_score)
          + (weights.w_lat * lat)
          + (weights.w_load * load))
          / 100
        in
        (idx, name, model, total))
  in
  let sorted =
    List.sort
      indexed
      ~compare:(fun (i1, _, _, s1) (i2, _, _, s2) ->
        if s1 > s2 then LT
        else if s1 < s2 then GT
        else if i1 < i2 then LT
        else if i1 > i2 then GT
        else EQ)
  in
  let chosen =
    List.head sorted |> Option.map ~fn:(fun (_, name, _, _) -> name)
  in
  let fallback_order =
    match chosen with
    | None -> []
    | Some c ->
        List.filter_map sorted ~fn:(fun (_, name, _, _) ->
          if String.equal name c then None else Some name)
        |> List.take ~len:(max 0 config.Oasis_config.policy.Oasis_config.max_fallback)
  in
  {
    task_category = task.category;
    chosen;
    fallback_order;
    rejected = List.rev !rejects;
    attempts = [];
    scores = List.map sorted ~fn:(fun (_, name, _, s) -> (name, s));
    parts;
    explored = false;
    unpriced =
      List.filter_map passing ~fn:(fun (name, _, p, _, _, _) ->
        match p with None -> Some name | Some _ -> None);
    handoffs = [];
  }

(* ---------- exploration ---------- *)

(** Candidates measured fewer times than this are worth trying. *)
let explore_min_samples = 5

(** Promote the least-measured passing candidate to first choice, keeping
    the usual winner as its first fallback. Unchanged when every candidate
    already has enough samples. *)
let explore = fun (d : decision) ~(samples : string -> int) ->
  match d.chosen with
  | None -> d
  | Some top ->
      let pick =
        List.fold_left d.scores ~init:None ~fn:(fun best (name, _) ->
          let n = samples name in
          if String.equal name top || n >= explore_min_samples then best
          else
            match best with
            | Some (_, bn) when bn <= n -> best
            | _ -> Some (name, n))
      in
      match pick with
      | None -> d
      | Some (x, _) ->
          let rest = List.filter d.fallback_order ~fn:(fun a -> not (String.equal a x)) in
          let fallback = List.take (top :: rest) ~len:(max 1 (List.length d.fallback_order)) in
          { d with chosen = Some x; fallback_order = fallback; explored = true }
