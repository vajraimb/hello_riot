open Std
open Std.Collections

module Json = Std.Data.Json

(** Task feed for the dashboard: every WS event is folded into one record
    per request (title, executor, status, human-readable routing, timeline
    of attempts / handoffs / agent work steps). In-memory, newest [keep]
    tasks only; history persistence is a separate concern. *)

let keep = 200

let max_timeline = 600

type task = {
  id: string;
  started_ms: int;
  updated_ms: int;
  finished_ms: int;
  title: string;
  source: string;
  mode: string;
  category: string;
  goal: string;
  stream: bool;
  status: string;
  executor: string;
  route_summary: string;
  category_note: string;
  route: Json.t;
  timeline: Json.t list;
  answer: string;
  error: string;
}

type t = (string, task) ConcurrentHashMap.t

let create = fun () : t -> ConcurrentHashMap.with_capacity ~size:256

let now_ms = Portal_signals.now_ms

let str = Portal_steps.str

let int_field = Portal_steps.int_field

let empty_task = fun id ->
  let t = now_ms () in
  {
    id;
    started_ms = t;
    updated_ms = t;
    finished_ms = 0;
    title = "";
    source = "api";
    mode = "";
    category = "";
    goal = "";
    stream = false;
    status = "running";
    executor = "";
    route_summary = "";
    category_note = "";
    route = Json.null;
    timeline = [];
    answer = "";
    error = "";
  }

(** One-line task title: the prompt with whitespace collapsed. *)
let title_of_text = fun (s : string) ->
  let out = StringBuilder.create ~size:(min 256 (String.length s)) in
  let pending_space = ref false in
  String.trim s
  |> String.for_each ~fn:(fun c ->
    match c with
    | ' ' | '\n' | '\t' | '\r' -> pending_space := true
    | c ->
        if !pending_space then StringBuilder.add_char out ' ';
        pending_space := false;
        StringBuilder.add_char out c);
  Portal_steps.clip (StringBuilder.contents out) 160

let last_user_text = fun (body : Json.t) ->
  let messages = Json.get_field "messages" body |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[] in
  List.rev messages
  |> List.find ~fn:(fun m -> String.equal (str m "role" |> Option.unwrap_or ~default:"") "user")
  |> Option.map ~fn:(fun m ->
    Json.get_field "content" m |> Option.map ~fn:Portal_steps.content_text |> Option.unwrap_or ~default:"")
  |> Option.unwrap_or ~default:""

(** Title of a chat request: its last user message. *)
let title_of_body = fun (body : Json.t) -> title_of_text (last_user_text body)

(* ---------- human-readable wording ---------- *)

let reason_text = fun reason ->
  match reason with
  | "unknown_account" -> "未在配置中"
  | "disabled" -> "已停用"
  | "model_not_served" -> "不提供所需模型"
  | "context_too_small" -> "上下文窗口不够"
  | "budget_exhausted" -> "本月预算已用完"
  | "daily_limit_reached" -> "今日次数已用完"
  | "quota_parked" -> "额度暂停中"
  | "circuit_open" -> "连续失败，熔断中"
  | "rpm_exhausted" -> "每分钟限额已满"
  | "concurrency_limit" -> "并发已满"
  | r -> r

let goal_text = fun goal ->
  match goal with
  | "cheapest" -> "最省钱"
  | "fastest" -> "最快"
  | "best" -> "质量最好"
  | "balanced" -> "均衡"
  | g -> g

let category_text = fun c ->
  match c with
  | "coding" -> "编程"
  | "general" -> "通用"
  | "research" -> "联网检索"
  | "reasoning" -> "推理"
  | "writing" -> "写作"
  | "" -> "通用"
  | c -> c

(** Plain-language reading of a raw failure string. *)
let error_text = fun (err : string) ->
  let e = String.lowercase_ascii err in
  let has s = String.contains e s in
  if has "empty_answer_reasoning_exhausted" then
    "思考用完了 max_tokens 仍没给出回答（推理模型常见），已换下一个候选"
  else if has "empty_answer" then "正常结束但没有输出任何回答，已换下一个候选"
  else if has "exited with code" then
    "进程异常退出（" ^ err ^ "）——多半是 CLI 未登录、参数不兼容或自身报错"
  else if has "timeout" then "超时未完成"
  else if has "401" || has "403" || has "auth" || has "invalid_api_key" || has "unauthorized" then
    "认证失败：key 失效或需要重新登录"
  else if has "429" || has "rate" || has "quota" || has "insufficient" then "被限流或额度不足"
  else if has "dns" || has "connect" || has "resolve" || has "refused" || has "unreachable" then
    "连接失败：网络或 DNS 问题"
  else if has "ended_early" || has "ended early" then "输出流中途断开"
  else if has "spawn" then "无法启动进程（命令不存在或不可执行）"
  else if has "unknown_agent" then "配置中找不到该 agent"
  else err

let handoff_text = fun ~from_ ~to_ ~level ~reason ->
  let how =
    match level with
    | "G1" -> "从断点无缝续写"
    | "G2" -> "续写并去掉重复部分"
    | "G3" -> "重新生成（与已输出内容可能不一致）"
    | "G0" -> "续写也失败了"
    | _ -> "接手继续"
  in
  from_ ^ " 中途失败（" ^ error_text reason ^ "），切换到 " ^ to_ ^ "：" ^ how

let names_of = fun items -> List.filter_map items ~fn:(fun c -> str c "name")

let duration_text = fun ms ->
  if ms < 1000 then Int.to_string ms ^ "ms"
  else if ms < 60_000 then Int.to_string (ms / 1000) ^ "." ^ Int.to_string (ms mod 1000 / 100) ^ "s"
  else Int.to_string (ms / 60_000) ^ "m" ^ Int.to_string (ms mod 60_000 / 1000) ^ "s"

(** "91 = 适配 100×60% + 速度 50×20% + …；历史平均耗时 3m30s（4 次）" *)
let parts_text = fun ~score (parts : Json.t) ->
  let g k = int_field parts k |> Option.unwrap_or ~default:0 in
  let w =
    Json.get_field "weights" parts |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
    |> List.filter_map ~fn:Json.get_int
  in
  match w with
  | [ wf; wc; wl; wd ] ->
      let term label v wt = label ^ " " ^ Int.to_string v ^ "×" ^ Int.to_string wt ^ "%" in
      let n = g "samples" in
      let lat =
        if n = 0 then "还没有耗时记录，速度按中性 50 分计"
        else "历史平均耗时 " ^ duration_text (g "latency_ema_ms") ^ "（" ^ Int.to_string n ^ " 次）"
      in
      Int.to_string score ^ " = "
      ^ String.concat " + " [ term "适配" (g "fit") wf; term "速度" (g "speed") wl; term "成本" (g "cost") wc; term "负载" (g "load") wd ]
      ^ "；" ^ lat
  | _ -> Int.to_string score

let route_summary_of = fun ~goal ~category (data : Json.t) ->
  let mode = str data "mode" |> Option.unwrap_or ~default:"chat" in
  let chosen = str data "chosen" in
  let candidates =
    Json.get_field "candidates" data |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
  in
  let rejected =
    Json.get_field "rejected" data |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
    |> List.filter ~fn:(fun r -> not (String.equal (str r "reason" |> Option.unwrap_or ~default:"") "disabled"))
  in
  let score_of name =
    List.find candidates ~fn:(fun c -> String.equal (str c "name" |> Option.unwrap_or ~default:"") name)
    |> Option.and_then ~fn:(fun c -> int_field c "score")
  in
  let backups =
    match chosen with
    | Some c -> List.filter (names_of candidates) ~fn:(fun n -> not (String.equal n c))
    | None -> names_of candidates
  in
  let backup_txt =
    match List.take backups ~len:3 with
    | [] -> "没有备选"
    | bs -> "备选 " ^ String.concat "、" bs
  in
  let reject_txt =
    match rejected with
    | [] -> ""
    | rs ->
        "；排除 "
        ^ (List.take rs ~len:4
          |> List.map ~fn:(fun r ->
            (str r "name" |> Option.unwrap_or ~default:"?") ^ "（" ^ reason_text (str r "reason" |> Option.unwrap_or ~default:"") ^ "）")
          |> String.concat "、")
        ^ (if List.length rs > 4 then " 等 " ^ Int.to_string (List.length rs) ^ " 个" else "")
  in
  match chosen with
  | None -> "没有可用的执行者" ^ reject_txt
  | Some c ->
      let why =
        if String.equal mode "agent" then
          category_text category ^ "任务里这个 agent 的适配分最高"
        else "按「" ^ goal_text goal ^ "」目标综合评分最高"
      in
      let parts =
        List.find candidates ~fn:(fun x -> String.equal (str x "name" |> Option.unwrap_or ~default:"") c)
        |> Option.and_then ~fn:(fun x -> Json.get_field "parts" x)
      in
      let score =
        match (score_of c, parts) with
        | (Some s, Some p) -> "（" ^ parts_text ~score:s p ^ "）"
        | (Some s, None) -> "（" ^ Int.to_string s ^ "）"
        | _ -> ""
      in
      (if String.equal mode "agent" then "交给 agent " else "选用账户 ") ^ c ^ "：" ^ why ^ score ^ "；" ^ backup_txt ^ reject_txt

(** Why the category is what it is, when Oasis inferred it. *)
let category_note_of = fun (data : Json.t) ->
  match str data "category_source" with
  | Some "auto" ->
      let hits =
        Json.get_field "category_hits" data |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
        |> List.filter_map ~fn:Json.get_string
      in
      let cat = category_text (str data "category" |> Option.unwrap_or ~default:"general") in
      if List.is_empty hits then "未指定类别，按内容判定为「" ^ cat ^ "」"
      else "按内容判定为「" ^ cat ^ "」（命中：" ^ String.concat "、" hits ^ "）"
  | _ -> ""

(* ---------- folding events ---------- *)

let entry = fun kind fields -> Json.obj (("kind", Json.string kind) :: ("at", Json.int (now_ms ())) :: fields)

let push = fun (t : task) e ->
  let tl = e :: t.timeline in
  { t with timeline = (if List.length tl > max_timeline then List.take tl ~len:max_timeline else tl) }

(** Token deltas extend the previous step of the same kind and agent. *)
let push_step = fun (t : task) ~agent (step : Json.t) ->
  let kind = Portal_steps.kind step in
  let text = str step "text" |> Option.unwrap_or ~default:"" in
  let merged =
    if not (Portal_steps.is_delta step) then None
    else
      match t.timeline with
      | prev :: rest
        when String.equal (str prev "kind" |> Option.unwrap_or ~default:"") "step"
             && String.equal (str prev "step" |> Option.unwrap_or ~default:"") kind
             && String.equal (str prev "agent" |> Option.unwrap_or ~default:"") agent
             && Json.get_field "open" prev |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false ->
          let prev_text = str prev "text" |> Option.unwrap_or ~default:"" in
          let fields =
            Json.get_object prev |> Option.unwrap_or ~default:[]
            |> List.map ~fn:(fun (k, v) ->
              if String.equal k "text" then (k, Json.string (Portal_steps.clip (prev_text ^ text) 20000)) else (k, v))
          in
          Some ({ t with timeline = Json.obj fields :: rest })
      | _ -> None
  in
  match merged with
  | Some t -> t
  | None ->
      let fields =
        Json.get_object step |> Option.unwrap_or ~default:[]
        |> List.filter ~fn:(fun (k, _) -> not (String.equal k "kind" || String.equal k "delta"))
      in
      push
        t
        (entry
          "step"
          ((("step", Json.string kind) :: ("agent", Json.string agent) :: ("open", Json.bool (Portal_steps.is_delta step)) :: fields)))

let apply_event = fun (t : task) ~type_ (data : Json.t) ->
  let t = { t with updated_ms = now_ms () } in
  match type_ with
  | "task_started" ->
      {
        t with
        category = str data "category" |> Option.unwrap_or ~default:t.category;
        goal = str data "goal" |> Option.unwrap_or ~default:t.goal;
        stream = Json.get_field "stream" data |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false;
        title = str data "title" |> Option.unwrap_or ~default:t.title;
        source = str data "source" |> Option.unwrap_or ~default:t.source;
        mode = str data "mode" |> Option.unwrap_or ~default:t.mode;
        category_note = category_note_of data;
      }
  | "routed" ->
      let summary = route_summary_of ~goal:t.goal ~category:t.category data in
      let summary = if String.is_empty t.category_note then summary else t.category_note ^ "，" ^ summary in
      push
        {
          t with
          mode = str data "mode" |> Option.unwrap_or ~default:t.mode;
          route = data;
          route_summary = summary;
        }
        (entry "route" [ ("text", Json.string summary) ])
  | "attempt_started" ->
      let acc = str data "account" |> Option.unwrap_or ~default:"" in
      push { t with executor = acc } (entry "attempt" [ ("account", Json.string acc) ])
  | "attempt_finished" ->
      let acc = str data "account" |> Option.unwrap_or ~default:"" in
      let err = str data "error" in
      let fields =
        [
          ("account", Json.string acc);
          ("ok", Json.bool (Option.is_none err));
          ("latency_ms", Json.int (int_field data "latency_ms" |> Option.unwrap_or ~default:0));
        ]
        @ (match err with
           | Some e -> [ ("error", Json.string e); ("hint", Json.string (error_text e)) ]
           | None -> [])
      in
      push t (entry "attempt_end" fields)
  | "handoff" ->
      let text =
        handoff_text
          ~from_:(str data "from" |> Option.unwrap_or ~default:"?")
          ~to_:(str data "to" |> Option.unwrap_or ~default:"?")
          ~level:(str data "level" |> Option.unwrap_or ~default:"?")
          ~reason:(str data "reason" |> Option.unwrap_or ~default:"")
      in
      push
        { t with executor = str data "to" |> Option.unwrap_or ~default:t.executor }
        (entry "handoff" [ ("text", Json.string text); ("level", Json.string (str data "level" |> Option.unwrap_or ~default:"")) ])
  | "agent_step" -> (
      let agent = str data "agent" |> Option.unwrap_or ~default:t.executor in
      match Json.get_field "step" data with
      | None -> t
      | Some step ->
          let t =
            if String.equal (Portal_steps.kind step) "text" then
              let piece = str step "text" |> Option.unwrap_or ~default:"" in
              let sep = if String.is_empty t.answer || Portal_steps.is_delta step then "" else "\n\n" in
              { t with answer = Portal_steps.clip (t.answer ^ sep ^ piece) 60000 }
            else t
          in
          push_step t ~agent step
    )
  | "task_done" ->
      let ok = Json.get_field "ok" data |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false in
      let chosen = str data "chosen" |> Option.unwrap_or ~default:t.executor in
      let error = str data "error" |> Option.unwrap_or ~default:(if ok then "" else "所有候选都失败了") in
      push
        {
          t with
          status = (if ok then "ok" else "failed");
          finished_ms = now_ms ();
          executor = (if String.equal chosen "none" then t.executor else chosen);
          error;
        }
        (entry "done" [ ("ok", Json.bool ok); ("error", Json.string error) ])
  | _ -> t

let evict = fun (feed : t) ->
  if ConcurrentHashMap.length feed > keep + 20 then (
    let sorted =
      ConcurrentHashMap.values feed
      |> List.sort ~compare:(fun a b -> Int.compare b.started_ms a.started_ms)
    in
    List.enumerate sorted
    |> List.for_each ~fn:(fun (i, task) -> if i >= keep then ignore (ConcurrentHashMap.remove feed ~key:task.id))
  )

let apply = fun (feed : t) ~type_ ~request_id (data : Json.t) ->
  if not (String.is_empty request_id) then (
    ConcurrentHashMap.compute feed ~key:request_id ~fn:(fun cur ->
      let base = match cur with Some t -> t | None -> empty_task request_id in
      ConcurrentHashMap.Insert (apply_event base ~type_ data, ()));
    if String.equal type_ "task_started" then evict feed
  )

(* ---------- json ---------- *)

let duration_ms = fun (t : task) ->
  (if t.finished_ms > 0 then t.finished_ms else now_ms ()) - t.started_ms

let summary_json = fun (t : task) ->
  Json.obj
    [
      ("id", Json.string t.id);
      ("title", Json.string t.title);
      ("source", Json.string t.source);
      ("mode", Json.string t.mode);
      ("category", Json.string t.category);
      ("goal", Json.string t.goal);
      ("status", Json.string t.status);
      ("executor", Json.string t.executor);
      ("started_ms", Json.int t.started_ms);
      ("updated_ms", Json.int t.updated_ms);
      ("duration_ms", Json.int (duration_ms t));
      ("route_summary", Json.string t.route_summary);
      ("error", Json.string t.error);
      ("steps", Json.int (List.length t.timeline));
    ]

let detail_json = fun (t : task) ->
  match summary_json t with
  | Json.Object fields ->
      Json.obj
        (fields
        @ [
            ("stream", Json.bool t.stream);
            ("route", t.route);
            ("timeline", Json.array (List.rev t.timeline));
            ("answer", Json.string t.answer);
          ])
  | j -> j

let recent = fun (feed : t) ~limit ->
  ConcurrentHashMap.values feed
  |> List.sort ~compare:(fun a b -> Int.compare b.started_ms a.started_ms)
  |> List.take ~len:limit

let find = fun (feed : t) id -> ConcurrentHashMap.get feed ~key:id
