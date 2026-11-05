open Std

(** Model knowledge base: what each model is good at, its limits, and its
    price. Feeds the scheduler's "fit" score (懂模型). *)

type latency =
  | Slow
  | Medium
  | Fast

type model_kb = {
  name: string;
  tier: int;
  strengths: string list;
  weaknesses: string list;
  context_window: int;
  max_output: int;
  latency: latency;
  in_price_nano: int;
  out_price_nano: int;
  cache_hit_price_nano: int;
}

let latency_of_string = function
  | "fast" -> Fast
  | "medium" -> Medium
  | _ -> Slow

let latency_to_string = function
  | Fast -> "fast"
  | Medium -> "medium"
  | Slow -> "slow"

let find = fun (kb : model_kb list) name ->
  List.find kb ~fn:(fun m -> String.equal m.name name)

let contains_cat = fun cats category ->
  List.any cats ~fn:(fun c -> String.equal c category)

(** 0..100 fit score of a model for a task category. *)
let fit = fun (model : model_kb) ~category ->
  let base = 40 + (min 5 (max 1 model.tier)) * 10 in
  let with_strength =
    if contains_cat model.strengths category then base + 10 else base
  in
  let score =
    if contains_cat model.weaknesses category then with_strength - 10
    else with_strength
  in
  min 100 (max 0 score)

(** Worst-case cost estimate in nano-dollars (int math only). Cached input
    tokens (prompt caching) are billed at [cache_hit_price_nano]. *)
let est_cost_nano = fun (model : model_kb) ~cache_tokens ~in_tokens ~out_tokens ->
  (in_tokens * model.in_price_nano)
  + (out_tokens * model.out_price_nano)
  + (cache_tokens * model.cache_hit_price_nano)

let context_ok = fun (model : model_kb) ~in_tokens ~out_tokens ->
  if in_tokens + out_tokens > model.context_window then false
  else out_tokens <= model.max_output

let supported_categories =
  [ "coding"; "writing"; "analysis"; "translation"; "long_doc"; "general" ]
