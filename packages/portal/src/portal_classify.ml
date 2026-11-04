open Std
open Std.Collections

(** Task category from the prompt text, for requests that do not name one.
    Keyword heuristics only: cheap, explainable (the matched words go into
    the routing explanation), and biased towards "research" for anything
    that needs live information a model cannot know. *)

let research_topics =
  [
    "天气"; "气温"; "下雨"; "降雨"; "台风"; "空气质量"; "新闻"; "热搜"; "股价"; "股票"; "汇率"; "币价";
    "比特币"; "油价"; "金价"; "比分"; "赛程"; "赛果"; "票房"; "航班"; "路况"; "限行"; "发布会"; "开盘"; "收盘";
    "最新版本"; "latest version"; "latest release"; "release notes"; "weather"; "forecast"; "news"; "stock price"; "exchange rate"; "bitcoin"; "score of";
  ]

let research_actions =
  [ "搜一下"; "搜索"; "查一下"; "查查"; "帮我查"; "联网"; "上网查"; "search the web"; "look up"; "google"; "http://"; "https://" ]

let time_words =
  [
    "今天"; "今日"; "明天"; "后天"; "昨天"; "前天"; "本周"; "这周"; "下周"; "上周"; "本月"; "下个月"; "今年";
    "最近"; "最新"; "目前"; "现在"; "当前"; "实时"; "刚刚"; "today"; "tomorrow"; "yesterday"; "latest"; "right now"; "currently";
  ]

let question_cues = [ "如何"; "怎么样"; "多少"; "吗"; "是什么"; "有哪些"; "几点"; "什么时候"; "?"; "？"; "what"; "how"; "when"; "who" ]

let coding_words =
  [
    "函数"; "代码"; "报错"; "编译"; "bug"; "debug"; "traceback"; "stack trace"; "exception"; "segfault"; "正则"; "sql";
    "重构"; "单元测试"; "typescript"; "python"; "ocaml"; "rust"; "javascript"; "golang"; "c++"; "git "; "npm "; "pip ";
    "docker"; "kubernetes"; ".py"; ".ts"; ".ml"; ".rs"; ".go"; ".js";
  ]

let writing_words =
  [ "写一篇"; "写一段"; "润色"; "改写"; "文案"; "邮件"; "翻译"; "作文"; "演讲稿"; "标题"; "帖子"; "proofread"; "rewrite"; "draft an" ]

let hits = fun (text : string) words -> List.filter words ~fn:(fun w -> String.contains text w)

(** [classify text] = [(category, matched words)]. *)
let classify = fun (raw : string) ->
  let text = String.lowercase_ascii raw in
  let take l = List.take l ~len:3 in
  if String.contains text "```" then ("coding", [ "代码块" ])
  else
    let topics = hits text research_topics in
    let actions = hits text research_actions in
    let times = hits text time_words in
    let code = hits text coding_words in
    let asks = not (List.is_empty (hits text question_cues)) in
    if not (List.is_empty topics && List.is_empty actions) then ("research", take (topics @ actions @ times))
    else if (not (List.is_empty times)) && asks && List.is_empty code then ("research", take times)
    else if not (List.is_empty code) then ("coding", take code)
    else
      match hits text writing_words with
      | [] -> ("general", [])
      | w -> ("writing", take w)
