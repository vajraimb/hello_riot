open Std
open Std.Collections

(** Setup: a built-in catalog of providers and agents, detection of what
    this machine already has (API keys in the environment or
    [~/.oasis/secrets.env], agent CLIs, a local Ollama), live verification
    of each candidate, and a merge of the user's choices into [oasis.toml]
    that keeps everything else in the file (comments, tuned values, hand
    written entries) as it was. *)

module Json = Std.Data.Json
module Toml = Std.Data.Toml

(* ---------- catalog ---------- *)

type model_spec = {
  id: string;
  tier: int;
  strengths: string list;
  weaknesses: string list;
  context_window: int;
  max_output: int;
  latency: string;
}

type endpoint = {
  base_url: string;
  protocol: string;
  note: string;
}

type provider = {
  pid: string;
  label: string;
  env_name: string;
  keywords: string list;
  endpoints: endpoint list;
  models: model_spec list;
  prefer: string list;
  key_url: string;
}

let m = fun id tier strengths ?(weaknesses = []) context_window max_output latency ->
  { id; tier; strengths; weaknesses; context_window; max_output; latency }

let ep = fun ?(protocol = "openai") ?(note = "") base_url -> { base_url; protocol; note }

(* Models are the ones known to work; verification intersects them with
   the provider's live /models list, and [prefer] picks from that list
   when none of them is offered any more. *)
let providers = [
  {
    pid = "deepseek";
    label = "DeepSeek";
    env_name = "DEEPSEEK_API_KEY";
    keywords = [ "deepseek" ];
    endpoints = [ ep "https://api.deepseek.com" ];
    models =
      [
        m "deepseek-v4-pro" 5 [ "coding"; "analysis"; "general"; "writing" ] 1000000 64000 "medium";
        m "deepseek-flash" 3 [ "coding"; "general" ] ~weaknesses:[ "writing"; "long_doc" ] 128000 16384 "fast";
        m "deepseek-chat" 4 [ "coding"; "analysis"; "general" ] 128000 8192 "medium";
      ];
    prefer = [ "deepseek-v"; "deepseek-chat"; "deepseek-reasoner" ];
    key_url = "https://platform.deepseek.com/api_keys";
  };
  {
    pid = "kimi";
    label = "Kimi (Moonshot)";
    env_name = "MOONSHOT_API_KEY";
    keywords = [ "kimi"; "moonshot" ];
    endpoints =
      [
        ep ~note:"Kimi Coding" "https://agent-gw.kimi.com/coding/v1";
        ep ~note:"Moonshot (CN)" "https://api.moonshot.cn/v1";
        ep ~note:"Moonshot (global)" "https://api.moonshot.ai/v1";
      ];
    models = [ m "k3-agent" 5 [ "analysis"; "general"; "long_doc"; "writing" ] 1000000 128000 "slow" ];
    prefer = [ "kimi-k"; "k3"; "kimi-latest"; "moonshot-v1-128k" ];
    key_url = "https://platform.moonshot.cn/console/api-keys";
  };
  {
    pid = "glm";
    label = "GLM (Z.ai / Zhipu)";
    env_name = "ZAI_API_KEY";
    keywords = [ "glm"; "zai"; "zhipu"; "bigmodel" ];
    endpoints =
      [
        ep ~protocol:"anthropic" ~note:"Z.ai" "https://api.z.ai/api/anthropic";
        ep ~note:"Z.ai" "https://api.z.ai/api/paas/v4";
        ep ~note:"Zhipu (CN)" "https://open.bigmodel.cn/api/paas/v4";
      ];
    models = [ m "glm-5.3" 5 [ "general"; "writing"; "analysis"; "coding" ] 200000 32768 "medium" ];
    prefer = [ "glm-5"; "glm-4.6"; "glm-4.5" ];
    key_url = "https://z.ai/manage-apikey/apikey-list";
  };
  {
    pid = "openrouter";
    label = "OpenRouter";
    env_name = "OPENROUTER_API_KEY";
    keywords = [ "openrouter" ];
    endpoints = [ ep "https://openrouter.ai/api/v1" ];
    models =
      [
        m "qwen/qwen3.8-max-prime" 5 [ "coding"; "analysis"; "general"; "writing" ] 128000 16384 "medium";
        m "deepseek/deepseek-v4.1-flash" 3 [ "coding"; "general" ] 128000 16384 "fast";
      ];
    prefer = [ "qwen/"; "deepseek/"; "moonshotai/"; "z-ai/" ];
    key_url = "https://openrouter.ai/settings/keys";
  };
  {
    pid = "perplexity";
    label = "Perplexity";
    env_name = "PERPLEXITY_API_KEY";
    keywords = [ "perplexity"; "pplx" ];
    endpoints = [ ep "https://api.perplexity.ai/" ];
    models =
      [
        m "sonar-pro" 5 [ "research"; "analysis"; "general" ] ~weaknesses:[ "coding" ] 200000 8192 "medium";
        m "sonar" 3 [ "research"; "general" ] ~weaknesses:[ "coding"; "long_doc" ] 128000 8192 "fast";
      ];
    prefer = [];
    key_url = "https://www.perplexity.ai/account/api/keys";
  };
  {
    pid = "dashscope";
    label = "Qwen (DashScope)";
    env_name = "DASHSCOPE_API_KEY";
    keywords = [ "dashscope"; "qwen"; "bailian" ];
    endpoints =
      [
        ep ~note:"Coding Plan" "https://coding.dashscope.aliyuncs.com/v1";
        ep ~note:"CN" "https://dashscope.aliyuncs.com/compatible-mode/v1";
        ep ~note:"intl" "https://dashscope-intl.aliyuncs.com/compatible-mode/v1";
      ];
    models = [ m "qwen3.7-plus" 5 [ "coding"; "general"; "analysis" ] 1000000 65536 "medium" ];
    prefer = [ "qwen3"; "qwen-max"; "qwen-plus" ];
    key_url = "https://bailian.console.aliyun.com/";
  };
  {
    pid = "openai";
    label = "OpenAI";
    env_name = "OPENAI_API_KEY";
    keywords = [ "openai" ];
    endpoints = [ ep "https://api.openai.com/v1" ];
    models = [];
    prefer = [ "gpt-5"; "gpt-4.1"; "gpt-4o"; "o4"; "o3" ];
    key_url = "https://platform.openai.com/api-keys";
  };
  {
    pid = "anthropic";
    label = "Anthropic";
    env_name = "ANTHROPIC_API_KEY";
    keywords = [ "anthropic" ];
    endpoints = [ ep ~protocol:"anthropic" "https://api.anthropic.com/" ];
    models =
      [
        m "claude-opus-4-6" 5 [ "coding"; "analysis"; "writing"; "general" ] 200000 32000 "slow";
        m "claude-sonnet-4-6" 5 [ "coding"; "analysis"; "writing"; "general" ] 200000 64000 "medium";
      ];
    prefer = [];
    key_url = "https://console.anthropic.com/settings/keys";
  };
  {
    pid = "gemini";
    label = "Google Gemini";
    env_name = "GEMINI_API_KEY";
    keywords = [ "gemini"; "google" ];
    endpoints = [ ep "https://generativelanguage.googleapis.com/v1beta/openai/" ];
    models =
      [
        m "gemini-3.1-pro" 5 [ "analysis"; "coding"; "general"; "long_doc" ] 1000000 65536 "medium";
        m "gemini-3-pro" 5 [ "analysis"; "coding"; "general"; "long_doc" ] 1000000 65536 "medium";
        m "gemini-2.5-pro" 4 [ "analysis"; "coding"; "general"; "long_doc" ] 1000000 65536 "medium";
        m "gemini-3-flash" 4 [ "general"; "coding"; "long_doc" ] 1000000 65536 "fast";
        m "gemini-2.5-flash" 3 [ "general"; "long_doc" ] 1000000 65536 "fast";
      ];
    prefer = [ "gemini-3.1-pro"; "gemini-3-pro"; "gemini-2.5-pro"; "gemini-3-flash"; "gemini-2.5-flash" ];
    key_url = "https://aistudio.google.com/apikey";
  };
  {
    pid = "xai";
    label = "xAI Grok";
    env_name = "XAI_API_KEY";
    keywords = [ "xai"; "grok" ];
    endpoints = [ ep "https://api.x.ai/v1" ];
    models = [];
    prefer = [ "grok-4"; "grok-3" ];
    key_url = "https://console.x.ai/";
  };
  {
    pid = "groq";
    label = "Groq";
    env_name = "GROQ_API_KEY";
    keywords = [ "groq" ];
    endpoints = [ ep "https://api.groq.com/openai/v1" ];
    models = [];
    prefer = [ "llama-4"; "llama-3.3-70b"; "qwen" ];
    key_url = "https://console.groq.com/keys";
  };
  {
    pid = "mistral";
    label = "Mistral";
    env_name = "MISTRAL_API_KEY";
    keywords = [ "mistral" ];
    endpoints = [ ep "https://api.mistral.ai/v1" ];
    models = [];
    prefer = [ "mistral-large"; "mistral-medium"; "codestral" ];
    key_url = "https://console.mistral.ai/api-keys";
  };
  {
    pid = "siliconflow";
    label = "SiliconFlow";
    env_name = "SILICONFLOW_API_KEY";
    keywords = [ "siliconflow" ];
    endpoints = [ ep "https://api.siliconflow.cn/v1" ];
    models = [];
    prefer = [ "deepseek-ai/DeepSeek-V"; "Qwen/Qwen3"; "moonshotai/" ];
    key_url = "https://cloud.siliconflow.cn/account/ak";
  };
]

let find_provider = fun pid -> List.find providers ~fn:(fun p -> String.equal p.pid pid)

let ollama_base = "http://127.0.0.1:11434/v1"

type agent_spec = {
  aid: string;
  alabel: string;
  command: string;
  args: string list;
  capabilities: string list;
  atier: int;
  astrengths: string list;
  acontext: int;
  alatency: string;
  env_passthrough: string list;
  login_hint: string;
  install_hint: string;
}

(* Arguments run each CLI headless: no approval prompts and no questions
   back to the user, since nobody is at the terminal. *)
let agent_specs = [
  {
    aid = "claude_code";
    alabel = "Claude Code";
    command = "claude";
    args = [ "-p"; "--output-format"; "stream-json"; "--verbose"; "--dangerously-skip-permissions"; "--disallowedTools=AskUserQuestion"; "{prompt}" ];
    capabilities = [ "terminal"; "files"; "web" ];
    atier = 5;
    astrengths = [ "coding"; "analysis"; "general" ];
    acontext = 200000;
    alatency = "slow";
    env_passthrough = [];
    login_hint = "claude";
    install_hint = "npm install -g @anthropic-ai/claude-code";
  };
  {
    aid = "cursor_agent";
    alabel = "Cursor Agent";
    command = "cursor-agent";
    args = [ "-p"; "--output-format"; "stream-json"; "--force"; "--trust"; "{prompt}" ];
    capabilities = [ "terminal"; "files"; "web" ];
    atier = 5;
    astrengths = [ "coding"; "analysis"; "general" ];
    acontext = 200000;
    alatency = "slow";
    env_passthrough = [];
    login_hint = "cursor-agent login";
    install_hint = "curl https://cursor.com/install -fsS | bash";
  };
  {
    aid = "gemini_cli";
    alabel = "Gemini CLI";
    command = "gemini";
    args = [ "--skip-trust"; "--approval-mode"; "yolo"; "-o"; "stream-json"; "-p"; "{prompt}" ];
    capabilities = [ "terminal"; "files"; "web" ];
    atier = 4;
    astrengths = [ "general"; "writing" ];
    acontext = 1000000;
    alatency = "medium";
    env_passthrough = [ "GEMINI_API_KEY" ];
    login_hint = "gemini";
    install_hint = "npm install -g @google/gemini-cli";
  };
  {
    aid = "kimi_cli";
    alabel = "Kimi CLI";
    command = "kimi";
    args = [ "--print"; "--output-format"; "stream-json"; "--yolo"; "-p"; "{prompt}" ];
    capabilities = [ "terminal"; "files"; "web" ];
    atier = 4;
    astrengths = [ "coding"; "general"; "long_doc" ];
    acontext = 256000;
    alatency = "slow";
    env_passthrough = [];
    login_hint = "kimi login";
    install_hint = "uv tool install kimi-cli";
  };
  {
    aid = "grok_cli";
    alabel = "Grok CLI";
    command = "grok";
    args = [ "--always-approve"; "--output-format"; "streaming-json"; "-p"; "{prompt}" ];
    capabilities = [ "terminal"; "files"; "web" ];
    atier = 4;
    astrengths = [ "coding"; "general" ];
    acontext = 256000;
    alatency = "slow";
    env_passthrough = [];
    login_hint = "grok";
    install_hint = "https://x.ai/cli";
  };
  {
    aid = "opencode";
    alabel = "opencode";
    command = "opencode";
    args = [ "run"; "{prompt}" ];
    capabilities = [ "terminal"; "files" ];
    atier = 4;
    astrengths = [ "coding" ];
    acontext = 200000;
    alatency = "slow";
    env_passthrough = [];
    login_hint = "opencode auth login";
    install_hint = "curl -fsSL https://opencode.ai/install | bash";
  };
]

let find_agent_spec = fun aid -> List.find agent_specs ~fn:(fun a -> String.equal a.aid aid)

let basename = fun p ->
  match String.split ~by:"/" p |> List.rev with
  | b :: _ -> b
  | [] -> p

(* ---------- secrets.env ---------- *)

let secrets_path = fun () -> Oasis_config.home () ^ "/secrets.env"
let pending_path = fun () -> Oasis_config.home () ^ "/.setup-pending"

(** Variable names whose value came from secrets.env. *)
let from_secrets = ref ([] : string list)

let valid_env_name = fun name ->
  (not (String.is_empty name))
  && String.for_all name ~fn:(fun c ->
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || Char.equal c '_')
  && not (String.get_unchecked name ~at:0 >= '0' && String.get_unchecked name ~at:0 <= '9')

let unquote = fun v ->
  let n = String.length v in
  if n >= 2
     && ((Char.equal (String.get_unchecked v ~at:0) '"' && Char.equal (String.get_unchecked v ~at:(n - 1)) '"')
        || (Char.equal (String.get_unchecked v ~at:0) '\'' && Char.equal (String.get_unchecked v ~at:(n - 1)) '\''))
  then String.sub v ~offset:1 ~len:(n - 2)
  else v

let parse_secrets = fun content ->
  String.split ~by:"\n" content
  |> List.filter_map ~fn:(fun line ->
    let line = String.trim line in
    let line =
      if String.starts_with ~prefix:"export " line then String.trim (String.sub line ~offset:7 ~len:(String.length line - 7))
      else line
    in
    if String.is_empty line || String.starts_with ~prefix:"#" line then None
    else
      match String.index_of line ~char:'=' with
      | None -> None
      | Some i ->
          let k = String.trim (String.sub line ~offset:0 ~len:i) in
          let v = unquote (String.trim (String.sub line ~offset:(i + 1) ~len:(String.length line - i - 1))) in
          if valid_env_name k && not (String.is_empty v) then Some (k, v) else None)

let read_secrets = fun () ->
  match Path.from_string (secrets_path ()) with
  | Error _ -> []
  | Ok p -> (match Fs.read_to_string p with Ok c -> parse_secrets c | Error _ -> [])

(** secrets.env is Oasis's own key store, written by the setup wizard, so
    its values take precedence over the inherited environment. *)
let load_secrets = fun () ->
  let pairs = read_secrets () in
  List.for_each pairs ~fn:(fun (k, v) -> ignore (Env.set ~var:k ~value:v));
  from_secrets := List.map pairs ~fn:(fun (k, _) -> k);
  List.length pairs

let write_private = fun ~path content ->
  match Path.from_string path, Path.from_string (path ^ ".tmp") with
  | Ok dst, Ok tmp -> (
      match Fs.write content tmp with
      | Error e -> Error (IO.error_message e)
      | Ok () ->
          let _ = Fs.set_permissions tmp (Fs.Permissions.from_mode 0o600) in
          (match Fs.rename ~src:tmp ~dst with Ok () -> Ok () | Error e -> Error (IO.error_message e))
    )
  | _ -> Error ("bad path " ^ path)

let save_secrets = fun (pairs : (string * string) list) ->
  if List.is_empty pairs then Ok ()
  else
    let existing = read_secrets () |> List.filter ~fn:(fun (k, _) -> not (List.any pairs ~fn:(fun (k2, _) -> String.equal k k2))) in
    let all = existing @ pairs in
    let content =
      "# API keys saved by the Oasis setup wizard. Owner-only (0600); never commit this file.\n"
      ^ String.concat "" (List.map all ~fn:(fun (k, v) -> k ^ "=" ^ v ^ "\n"))
    in
    let _ = Fs.create_dir_all (Path.from_string (Oasis_config.home ()) |> Result.unwrap) in
    match write_private ~path:(secrets_path ()) content with
    | Error e -> Error e
    | Ok () ->
        List.for_each pairs ~fn:(fun (k, v) -> ignore (Env.set ~var:k ~value:v));
        from_secrets := List.unique (!from_secrets @ List.map pairs ~fn:(fun (k, _) -> k)) ~compare:String.compare;
        Ok ()

let key_source = fun name ->
  match Env.var Env.String ~name with
  | Some v when not (String.is_empty (String.trim v)) ->
      if List.any !from_secrets ~fn:(String.equal name) then "secrets" else "env"
  | _ -> ""

(* ---------- detection ---------- *)

let name_tokens = fun name ->
  String.lowercase_ascii name |> String.split ~by:"_" |> List.filter ~fn:(fun t -> not (String.is_empty t))

let looks_like_key_var = fun name ->
  List.any (name_tokens name) ~fn:(fun t ->
    String.equal t "key" || String.equal t "apikey" || String.equal t "token" || String.equal t "secret")

(** Environment variables that plausibly hold [p]'s key: the canonical
    name first, then any *_KEY / *_TOKEN variable naming the provider. *)
let env_candidates = fun (p : provider) ->
  let vars = Env.vars () in
  let has_value = fun k -> match Env.var Env.String ~name:k with Some v -> not (String.is_empty (String.trim v)) | None -> false in
  let canonical = if has_value p.env_name then [ p.env_name ] else [] in
  let others =
    List.filter_map vars ~fn:(fun (k, v) ->
      if String.equal k p.env_name || String.is_empty (String.trim v) || not (looks_like_key_var k) then None
      else if List.any (name_tokens k) ~fn:(fun t -> List.any p.keywords ~fn:(String.equal t)) then Some k
      else None)
    |> List.sort ~compare:String.compare
  in
  canonical @ others

let url_host = fun url ->
  let (_, host, port, _) = Oasis_upstream.parse_base_url url in
  host ^ ":" ^ Int.to_string (Option.unwrap_or port ~default:0)

(** Provider an existing account belongs to, by its [provider] field or
    its endpoint host. *)
let provider_of_account = fun (a : Oasis_config.account) ->
  match find_provider a.Oasis_config.provider with
  | Some p -> Some p.pid
  | None ->
      let h = url_host a.Oasis_config.base_url in
      List.find providers ~fn:(fun p -> List.any p.endpoints ~fn:(fun e -> String.equal (url_host e.base_url) h))
      |> Option.map ~fn:(fun p -> p.pid)

let is_ollama_account = fun (a : Oasis_config.account) ->
  String.equal a.Oasis_config.provider "ollama" || String.equal (url_host a.Oasis_config.base_url) (url_host ollama_base)

(* ---------- live checks ---------- *)

type check = {
  status: string;  (** ok · rate_limited · no_balance · invalid_key · model_error · unreachable · no_key *)
  message: string;
  base_url: string;
  protocol: string;
  note: string;
  models: string list;
}

let check_rank = fun s ->
  match s with
  | "ok" -> 0
  | "rate_limited" -> 1
  | "no_balance" -> 2
  | "invalid_key" -> 3
  | "model_error" -> 4
  | "unreachable" -> 5
  | _ -> 6

let check_json = fun (c : check) ->
  Json.obj
    [
      ("status", Json.string c.status);
      ("message", Json.string c.message);
      ("base_url", Json.string c.base_url);
      ("protocol", Json.string c.protocol);
      ("note", Json.string c.note);
      ("models", Json.array (List.map c.models ~fn:Json.string));
    ]

let http = fun ?(method_ = "GET") ?(headers = []) ?(body = "") url ->
  let (scheme, host, port, path) = Oasis_upstream.parse_base_url url in
  let port = Option.unwrap_or port ~default:443 in
  let path = if String.is_empty path then "/" else path in
  Oasis_upstream.upstream_call ~method_ ~scheme ~host ~port ~path
    ~headers:(("Host", host) :: ("Connection", "close") :: headers)
    ~body ()

let auth_headers = fun ~protocol key ->
  if String.equal protocol "anthropic" then [ ("x-api-key", key); ("anthropic-version", "2023-06-01") ]
  else [ ("Authorization", "Bearer " ^ key) ]

let trim_slash = fun u -> if String.ends_with ~suffix:"/" u then String.sub u ~offset:0 ~len:(String.length u - 1) else u

let list_models = fun (e : endpoint) key ->
  if String.equal e.protocol "anthropic" then `Unknown
  else
    match http ~headers:(auth_headers ~protocol:e.protocol key) (trim_slash e.base_url ^ "/models") with
    | Error _ -> `Unknown
    | Ok (status, body, _) ->
        if status = 401 || status = 403 then `Denied body
        else if not (status = 200) then `Unknown
        else
          let ids =
            Json.from_string body |> Result.to_option
            |> Option.and_then ~fn:(Json.get_field "data")
            |> Option.and_then ~fn:Json.get_array
            |> Option.unwrap_or ~default:[]
            |> List.filter_map ~fn:(fun j -> Json.get_field "id" j |> Option.and_then ~fn:Json.get_string)
          in
          if List.is_empty ids then `Unknown else `Ids ids

let chat_model_id = fun id ->
  if String.starts_with ~prefix:"models/" id then String.sub id ~offset:7 ~len:(String.length id - 7) else id

let not_chat = [ "embed"; "whisper"; "tts"; "audio"; "image"; "dall-e"; "moderation"; "rerank"; "transcribe"; "realtime"; "search-preview"; "ocr"; "vision" ]

let pick_models = fun (p : provider) listing ->
  match listing with
  | `Ids ids ->
      let ids = List.map ids ~fn:chat_model_id in
      let known = List.filter p.models ~fn:(fun s -> List.any ids ~fn:(String.equal s.id)) |> List.map ~fn:(fun s -> s.id) in
      if not (List.is_empty known) then List.take known ~len:2
      else
        let chat = List.filter ids ~fn:(fun id -> let l = String.lowercase_ascii id in not (List.any not_chat ~fn:(fun w -> String.contains l w))) in
        let preferred =
          List.map p.prefer ~fn:(fun pre ->
            List.filter chat ~fn:(fun id -> String.starts_with ~prefix:(chat_model_id pre) id))
          |> List.concat
          |> List.unique ~compare:String.compare
        in
        let ordered =
          List.filter_map p.prefer ~fn:(fun pre -> List.find chat ~fn:(fun id -> String.starts_with ~prefix:(chat_model_id pre) id))
        in
        let first = if List.is_empty ordered then (if List.is_empty preferred then chat else preferred) else ordered in
        List.take first ~len:1
  | _ -> List.map p.models ~fn:(fun s -> s.id) |> List.take ~len:2

let lower_contains_any = fun body words ->
  let l = String.lowercase_ascii body in
  List.any words ~fn:(fun w -> String.contains l w)

let snippet = fun body ->
  let one = String.split ~by:"\n" body |> String.concat " " in
  if String.length one > 160 then String.sub one ~offset:0 ~len:160 else one

let chat_once = fun (e : endpoint) key model ->
  let path_url =
    let (scheme, host, port, prefix) = Oasis_upstream.parse_base_url e.base_url in
    let port_s = match port with Some 443 when String.equal scheme "https" -> "" | Some 80 when String.equal scheme "http" -> "" | Some n -> ":" ^ Int.to_string n | None -> "" in
    scheme ^ "://" ^ host ^ port_s ^ Oasis_upstream.chat_path_of ~protocol:e.protocol prefix
  in
  let body =
    Json.to_string
      (Json.obj
        [
          ("model", Json.string model);
          ("max_tokens", Json.int 16);
          ("messages", Json.array [ Json.obj [ ("role", Json.string "user"); ("content", Json.string "ping") ] ]);
        ])
  in
  http ~method_:"POST" ~headers:(("Content-Type", "application/json") :: auth_headers ~protocol:e.protocol key) ~body path_url

let classify = fun ~status ~body ->
  if status >= 200 && status < 300 then "ok"
  else if status = 401 || status = 403 then
    if lower_contains_any body [ "balance"; "insufficient"; "余额"; "credit"; "quota"; "billing" ] then "no_balance" else "invalid_key"
  else if status = 402 then "no_balance"
  else if lower_contains_any body [ "insufficient"; "余额"; "balance"; "arrears"; "credit"; "billing"; "exceeded your current quota" ] then "no_balance"
  else if status = 429 then "rate_limited"
  else if status = 404 || (status = 400 && lower_contains_any body [ "model" ]) then "model_error"
  else "unreachable"

(** Tries [p]'s endpoints in order with [key] and returns the best outcome:
    the first endpoint and model that answer, or the most informative
    failure. Blocking: run it on a blocking lane. *)
let verify_provider = fun (p : provider) key ->
  let try_endpoint (e : endpoint) =
    let base = { status = "unreachable"; message = ""; base_url = e.base_url; protocol = e.protocol; note = e.note; models = [] } in
    match list_models e key with
    | `Denied body -> { base with status = classify ~status:401 ~body; message = snippet body }
    | listing ->
        let models = pick_models p listing in
        let rec attempt = function
          | [] -> { base with status = "model_error"; message = "no usable model" }
          | model :: rest -> (
              match chat_once e key model with
              | Error err -> { base with status = "unreachable"; message = err }
              | Ok (status, body, _) ->
                  let s = classify ~status ~body in
                  if String.equal s "model_error" && not (List.is_empty rest) then attempt rest
                  else if String.equal s "ok" || String.equal s "rate_limited" then
                    { base with status = s; models = model :: List.filter rest ~fn:(fun x -> not (String.equal x model)) }
                  else { base with status = s; message = snippet body; models }
            )
        in
        attempt models
  in
  let rec go best = function
    | [] -> best
    | e :: rest ->
        let c = try_endpoint e in
        if String.equal c.status "ok" then Some c
        else
          let best = match best with Some b when check_rank b.status <= check_rank c.status -> Some b | _ -> Some c in
          go best rest
  in
  match go None p.endpoints with
  | Some c -> c
  | None -> { status = "unreachable"; message = "no endpoint"; base_url = ""; protocol = "openai"; note = ""; models = [] }

(** Checks an already-configured account with its own endpoint and first model. *)
let verify_account = fun (a : Oasis_config.account) key ->
  let e = { base_url = a.Oasis_config.base_url; protocol = a.Oasis_config.protocol; note = "" } in
  let model = List.head a.Oasis_config.models |> Option.unwrap_or ~default:"" in
  let base = { status = "unreachable"; message = ""; base_url = e.base_url; protocol = e.protocol; note = ""; models = a.Oasis_config.models } in
  match chat_once e key model with
  | Error err -> { base with message = err }
  | Ok (status, body, _) ->
      let s = classify ~status ~body in
      { base with status = s; message = (if String.equal s "ok" then "" else snippet body) }

let ollama_models = fun () ->
  match http "http://127.0.0.1:11434/api/tags" with
  | Ok (200, body, _) ->
      Some
        (Json.from_string body |> Result.to_option
        |> Option.and_then ~fn:(Json.get_field "models")
        |> Option.and_then ~fn:Json.get_array
        |> Option.unwrap_or ~default:[]
        |> List.filter_map ~fn:(fun j -> Json.get_field "name" j |> Option.and_then ~fn:Json.get_string))
  | _ -> None

let is_cloud_model = fun id -> String.ends_with ~suffix:":cloud" id || String.ends_with ~suffix:"-cloud" id

(** Pulled models that can chat, split into (local, cloud). *)
let ollama_chat_models = fun models ->
  let chat = List.filter models ~fn:(fun id -> let l = String.lowercase_ascii id in not (List.any not_chat ~fn:(fun w -> String.contains l w))) in
  (List.filter chat ~fn:(fun id -> not (is_cloud_model id)), List.filter chat ~fn:is_cloud_model)

(** Cloud models stay listed locally after Ollama retires them, so each
    one is asked once; local ones are not, since that loads them into memory. *)
let ollama_model_answers = fun id ->
  match chat_once { base_url = ollama_base; protocol = "openai"; note = "" } "" id with
  | Ok (status, _, _) -> status >= 200 && status < 300
  | Error _ -> false

type Message.t += Setup_done of string * Json.t

(** Runs blocking jobs on their own lanes and collects whatever finishes
    within [timeout_s]; unfinished jobs are reported as [None]. *)
let run_parallel = fun ~timeout_s (jobs : (string * (unit -> Json.t)) list) ->
  let me = self () in
  List.for_each jobs ~fn:(fun (id, job) ->
    ignore (Runtime.spawn_blocked (fun () -> send me (Setup_done (id, job ())); Ok ())));
  let t0 = Time.Instant.now () in
  let results = ref [] in
  let rec loop pending =
    if pending = 0 then ()
    else
      let left = timeout_s * 1000 - Time.Duration.to_millis (Time.Instant.elapsed t0) in
      if left <= 0 then ()
      else
        match
          receive
            ~selector:(function Setup_done (id, j) when List.any jobs ~fn:(fun (k, _) -> String.equal k id) -> Select (id, j) | _ -> Skip)
            ~timeout:(Time.Duration.from_millis left) ()
        with
        | r ->
            results := r :: !results;
            loop (pending - 1)
        | exception Receive_timeout -> ()
  in
  loop (List.length jobs);
  List.map jobs ~fn:(fun (id, _) -> (id, List.find !results ~fn:(fun (k, _) -> String.equal k id) |> Option.map ~fn:(fun (_, j) -> j)))

let working_cloud_models = fun models ->
  run_parallel ~timeout_s:30
    (List.map models ~fn:(fun id -> (id, fun () -> Json.bool (ollama_model_answers id))))
  |> List.filter_map ~fn:(fun (id, r) -> match r with Some (Json.Bool true) -> Some id | _ -> None)

let check_of_json = fun j ->
  let s k = Json.get_field k j |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:"" in
  {
    status = s "status";
    message = s "message";
    base_url = s "base_url";
    protocol = (match s "protocol" with "" -> "openai" | p -> p);
    note = s "note";
    models = Json.get_field "models" j |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[] |> List.filter_map ~fn:Json.get_string;
  }

(* ---------- model specs for new accounts ---------- *)

let name_tokens = fun id ->
  String.fold_left (String.lowercase_ascii id) ~init:"" ~fn:(fun acc c ->
    acc ^ (if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then String.from_char c else " "))
  |> String.split ~by:" "
  |> List.filter ~fn:(fun t -> not (String.is_empty t))

(** Catalog entry for [id]: exact, else the longest catalog id that [id]
    extends ("gemini-3.1-pro-preview" is "gemini-3.1-pro"). *)
let catalog_spec = fun id ->
  let all = List.concat (List.map providers ~fn:(fun p -> p.models)) in
  match List.find all ~fn:(fun s -> String.equal s.id id) with
  | Some s -> Some s
  | None ->
      List.filter all ~fn:(fun s -> String.starts_with ~prefix:(s.id ^ "-") id)
      |> List.fold_left ~init:None ~fn:(fun best s ->
        match best with
        | Some b when String.length b.id >= String.length s.id -> best
        | _ -> Some s)
      |> Option.map ~fn:(fun s -> { s with id })

let spec_for = fun ~pid id ->
  match catalog_spec id with
  | Some s -> s
  | None ->
      if String.equal pid "ollama" then
        if String.ends_with ~suffix:":cloud" id || String.contains id "-cloud" then m id 4 [ "general"; "coding" ] 131072 16384 "medium"
        else m id 2 [ "general" ] ~weaknesses:[ "coding"; "long_doc" ] 4096 2048 "medium"
      else
        let tokens = name_tokens id in
        let fast = List.any [ "mini"; "flash"; "lite"; "nano"; "small"; "haiku"; "turbo" ] ~fn:(fun w -> List.any tokens ~fn:(String.equal w)) in
        let research = String.equal pid "perplexity" in
        if research then m id 4 [ "research"; "general" ] ~weaknesses:[ "coding" ] 128000 8192 "medium"
        else if fast then m id 3 [ "general"; "coding" ] 128000 8192 "fast"
        else m id 4 [ "general"; "coding"; "analysis"; "writing" ] 128000 8192 "medium"

(* ---------- TOML text editing ---------- *)

type block = {
  header: string;  (** "" before the first table; "accounts" for [[accounts]], "policy" for [policy] *)
  lines: string list;
}

let header_of = fun line ->
  let t = String.trim line in
  if String.starts_with ~prefix:"[[" t then
    match String.index_of t ~char:']' with
    | Some i when i > 2 -> Some (String.trim (String.sub t ~offset:2 ~len:(i - 2)))
    | _ -> None
  else if String.starts_with ~prefix:"[" t then
    match String.index_of t ~char:']' with
    | Some i when i > 1 -> Some (String.trim (String.sub t ~offset:1 ~len:(i - 1)))
    | _ -> None
  else None

let split_blocks = fun text ->
  let lines = String.split ~by:"\n" text in
  let rec go cur_header cur acc = function
    | [] -> List.rev ({ header = cur_header; lines = List.rev cur } :: acc)
    | l :: rest -> (
        match header_of l with
        | Some h -> go h [ l ] ({ header = cur_header; lines = List.rev cur } :: acc) rest
        | None -> go cur_header (l :: cur) acc rest
      )
  in
  go "" [] [] lines
  |> List.filter ~fn:(fun b -> not (String.is_empty b.header && List.is_empty b.lines))

let join_blocks = fun blocks -> String.concat "\n" (List.concat (List.map blocks ~fn:(fun b -> b.lines)))

let key_of_line = fun line ->
  let t = String.trim line in
  if String.is_empty t || String.starts_with ~prefix:"#" t then None
  else match String.index_of t ~char:'=' with
    | None -> None
    | Some i -> Some (String.trim (String.sub t ~offset:0 ~len:i))

let bracket_balance = fun s ->
  String.fold_left s ~init:0 ~fn:(fun n c -> if Char.equal c '[' then n + 1 else if Char.equal c ']' then n - 1 else n)

(** [(key, first, last)] line spans of the block's assignments; a value
    such as a multi-line array runs until its brackets close. *)
let assignments = fun lines ->
  let spans = ref ([] : (string * int * int) list) in
  let open_key = ref (None : (string * int) option) in
  let depth = ref 0 in
  List.for_each (List.enumerate lines) ~fn:(fun (i, l) ->
    match !open_key with
    | Some (k, first) ->
        depth := !depth + bracket_balance l;
        if !depth <= 0 then (
          spans := (k, first, i) :: !spans;
          open_key := None)
    | None -> (
        match key_of_line l with
        | Some k when Option.is_none (header_of l) ->
            let d = bracket_balance l in
            if d > 0 then (
              depth := d;
              open_key := Some (k, i))
            else spans := (k, i, i) :: !spans
        | _ -> ()));
  (match !open_key with Some (k, first) -> spans := (k, first, List.length lines - 1) :: !spans | None -> ());
  List.rev !spans

let lines_between = fun lines ~first ~last ->
  List.enumerate lines |> List.filter_map ~fn:(fun (i, l) -> if i >= first && i <= last then Some l else None)

let block_value = fun b key ->
  List.find (assignments b.lines) ~fn:(fun (k, _, _) -> String.equal k key)
  |> Option.and_then ~fn:(fun (_, first, last) ->
    match Toml.parse (String.concat "\n" (lines_between b.lines ~first ~last)) with
    | Ok root -> Toml.get_table root |> Option.and_then ~fn:(fun t -> List.find t ~fn:(fun (k, _) -> String.equal k key)) |> Option.map ~fn:(fun (_, v) -> v)
    | Error _ -> None)

let block_name = fun b -> block_value b "name" |> Option.and_then ~fn:Toml.get_string

let toml_str = fun s ->
  let body =
    String.fold_left s ~init:"" ~fn:(fun acc c ->
      acc
      ^ (match c with
         | '"' -> "\\\""
         | '\\' -> "\\\\"
         | '\n' -> "\\n"
         | c -> String.from_char c))
  in
  "\"" ^ body ^ "\""

let toml_list = fun xs -> "[" ^ String.concat ", " (List.map xs ~fn:toml_str) ^ "]"

(** Sets [key = value] in a block: replaces the existing assignment (a
    multi-line array included) or adds it after the last assignment. *)
let set_in_block = fun b ~key ~value ->
  let line = key ^ " = " ^ value in
  let spans = assignments b.lines in
  let indexed = List.enumerate b.lines in
  let lines =
    match List.find spans ~fn:(fun (k, _, _) -> String.equal k key) with
    | Some (_, first, last) ->
        List.filter_map indexed ~fn:(fun (i, l) -> if i = first then Some line else if i > first && i <= last then None else Some l)
    | None ->
        let after = List.fold_left spans ~init:0 ~fn:(fun _ (_, _, last) -> last) in
        List.map indexed ~fn:(fun (i, l) -> if i = after then [ l; line ] else [ l ]) |> List.concat
  in
  { b with lines }

let render_account = fun ~name ~provider ~base_url ~protocol ~env ~models ->
  [ "[[accounts]]"; "name = " ^ toml_str name; "provider = " ^ toml_str provider ]
  @ (if String.equal protocol "anthropic" then [ "protocol = \"anthropic\"" ] else [])
  @ [ "base_url = " ^ toml_str base_url ]
  @ (if String.is_empty env then [] else [ "api_key_env = " ^ toml_str env ])
  @ [ "models = " ^ toml_list models; "enabled = true"; "" ]

let render_model = fun (s : model_spec) ->
  [
    "[[models]]";
    "name = " ^ toml_str s.id;
    "tier = " ^ Int.to_string s.tier;
    "strengths = " ^ toml_list s.strengths;
    "weaknesses = " ^ toml_list s.weaknesses;
    "context_window = " ^ Int.to_string s.context_window;
    "max_output = " ^ Int.to_string s.max_output;
    "latency = " ^ toml_str s.latency;
    "in_price_nano = 0";
    "out_price_nano = 0";
    "cache_hit_price_nano = 0";
    "";
  ]

let render_agent = fun (a : agent_spec) ~command ->
  [
    "[[agents]]";
    "name = " ^ toml_str a.aid;
    "command = " ^ toml_str command;
    "args = " ^ toml_list a.args;
    "capabilities = " ^ toml_list a.capabilities;
    "tier = " ^ Int.to_string a.atier;
    "strengths = " ^ toml_list a.astrengths;
    "context_window = " ^ Int.to_string a.acontext;
    "latency = " ^ toml_str a.alatency;
  ]
  @ (if List.is_empty a.env_passthrough then [] else [ "env_passthrough = " ^ toml_list a.env_passthrough ])
  @ [ "enabled = true"; "" ]

(* ---------- applying choices ---------- *)

type new_account = {
  na_name: string;  (** "" = named after the provider *)
  na_provider: string;
  na_base_url: string;
  na_protocol: string;
  na_env: string;
  na_models: string list;
}

type choices = {
  enable_accounts: (string * bool) list;
  enable_agents: (string * bool) list;
  add_accounts: new_account list;
  add_agents: (string * string) list;  (** catalog id, absolute command *)
  goal: string option;
}

let routable_categories = [ "general"; "coding"; "research"; "writing"; "analysis" ]

let account_categories = fun (models : model_spec list) ->
  let strengths = List.concat (List.map models ~fn:(fun s -> s.strengths)) in
  let research_only = List.any strengths ~fn:(String.equal "research") && not (List.any strengths ~fn:(fun s -> String.equal s "coding" || String.equal s "writing")) in
  List.filter routable_categories ~fn:(fun c ->
    if String.equal c "general" then not research_only
    else List.any strengths ~fn:(String.equal c))

let unique_name = fun taken base ->
  if not (List.any taken ~fn:(String.equal base)) then base
  else
    let rec go n = let c = base ^ "_" ^ Int.to_string n in if List.any taken ~fn:(String.equal c) then go (n + 1) else c in
    go 2

let skeleton =
  {|# Oasis config, written by the setup wizard. Edit freely: running the
# wizard again only changes what you tick or untick there.
# API keys are not stored here. Accounts name an environment variable
# (api_key_env); keys pasted into the wizard live in ~/.oasis/secrets.env.

[server]
host = "127.0.0.1"
port = 9899

[policy]
goal = "balanced"
agent_categories = ["coding"]
max_fallback = 2
|}

(** Merges [choices] into the config text. Entries the user did not touch
    keep their lines byte for byte. *)
let merge = fun ~text (c : choices) ->
  let fresh = String.is_empty (String.trim text) in
  let blocks = split_blocks (if fresh then skeleton else text) in
  let toggle header pairs blocks =
    List.map blocks ~fn:(fun b ->
      if not (String.equal b.header header) then b
      else
        match block_name b with
        | None -> b
        | Some name -> (
            match List.find pairs ~fn:(fun (n, _) -> String.equal n name) with
            | Some (_, on) ->
                let current = block_value b "enabled" |> Option.and_then ~fn:Oasis_config.get_bool_like |> Option.unwrap_or ~default:true in
                if Bool.equal current on then b else set_in_block b ~key:"enabled" ~value:(if on then "true" else "false")
            | None -> b
          ))
  in
  let blocks = toggle "accounts" c.enable_accounts blocks |> toggle "agents" c.enable_agents in
  let names header = List.filter_map blocks ~fn:(fun b -> if String.equal b.header header then block_name b else None) in
  let model_names = ref (names "models") in
  let account_names = ref (names "accounts") in
  let agent_names = names "agents" in
  let added = ref [] in
  let new_lines = ref [] in
  List.for_each c.add_accounts ~fn:(fun na ->
    if not (List.is_empty na.na_models) then (
      let name = unique_name !account_names (if String.is_empty na.na_name then na.na_provider else na.na_name) in
      account_names := name :: !account_names;
      let specs = List.map na.na_models ~fn:(spec_for ~pid:na.na_provider) in
      List.for_each specs ~fn:(fun s ->
        if not (List.any !model_names ~fn:(String.equal s.id)) then (
          model_names := s.id :: !model_names;
          new_lines := !new_lines @ render_model s));
      new_lines := !new_lines @ render_account ~name ~provider:na.na_provider ~base_url:na.na_base_url ~protocol:na.na_protocol ~env:na.na_env ~models:na.na_models;
      added := (name, account_categories specs) :: !added));
  List.for_each c.add_agents ~fn:(fun (aid, command) ->
    match find_agent_spec aid with
    | Some a when not (List.any agent_names ~fn:(String.equal aid)) -> new_lines := !new_lines @ render_agent a ~command
    | _ -> ());
  let added = List.rev !added in
  let blocks =
    List.map blocks ~fn:(fun b ->
      if not (String.equal b.header "routes") then b
      else
        match block_value b "category" |> Option.and_then ~fn:Toml.get_string with
        | None -> b
        | Some cat ->
            let current = block_value b "accounts" |> Option.and_then ~fn:(fun v -> Toml.get_array v) |> Option.map ~fn:(List.filter_map ~fn:Toml.get_string) |> Option.unwrap_or ~default:[] in
            let extra = List.filter_map added ~fn:(fun (n, cats) -> if List.any cats ~fn:(String.equal cat) && not (List.any current ~fn:(String.equal n)) then Some n else None) in
            if List.is_empty extra then b else set_in_block b ~key:"accounts" ~value:(toml_list (current @ extra)))
  in
  let has_routes = List.any blocks ~fn:(fun b -> String.equal b.header "routes") in
  let route_lines =
    if has_routes || List.is_empty added then []
    else
      let in_cat cat = List.filter_map added ~fn:(fun (n, cats) -> if List.any cats ~fn:(String.equal cat) then Some n else None) in
      let general = in_cat "general" and research = in_cat "research" in
      (if List.is_empty general then [] else [ "[[routes]]"; "category = \"general\""; "accounts = " ^ toml_list general; "" ])
      @ (if List.is_empty research then [] else [ "[[routes]]"; "category = \"research\""; "accounts = " ^ toml_list research; "" ])
  in
  let blocks =
    match c.goal with
    | None -> blocks
    | Some g ->
        if List.any blocks ~fn:(fun b -> String.equal b.header "policy") then
          List.map blocks ~fn:(fun b -> if String.equal b.header "policy" then set_in_block b ~key:"goal" ~value:(toml_str g) else b)
        else blocks @ [ { header = "policy"; lines = [ ""; "[policy]"; "goal = " ^ toml_str g ] } ]
  in
  let body = join_blocks blocks in
  let tail = !new_lines @ route_lines in
  if List.is_empty tail then body
  else
    let body = if String.ends_with ~suffix:"\n" body then body else body ^ "\n" in
    let marker = "# ---- added by the Oasis setup wizard ----" in
    body ^ (if String.contains body marker then "\n" else "\n" ^ marker ^ "\n\n") ^ String.concat "\n" tail

(* ---------- first run ---------- *)

(** What a first start can set up without asking: every provider whose key
    is in the environment and answers, a running Ollama, and every agent
    CLI on this machine. *)
let first_run_choices = fun ~home ->
  (* [note] carries the variable that worked back to the account *)
  let jobs =
    List.filter_map providers ~fn:(fun p ->
      match env_candidates p with
      | [] -> None
      | envs ->
          Some
            ( p.pid,
              fun () ->
                let rec go last = function
                  | [] -> last
                  | env :: rest -> (
                      match Env.var Env.String ~name:env with
                      | None -> go last rest
                      | Some key ->
                          let c = { (verify_provider p (String.trim key)) with note = env } in
                          if String.equal c.status "ok" then c
                          else go (match last with l when check_rank l.status <= check_rank c.status -> l | _ -> c) rest
                    )
                in
                check_json (go { status = "no_key"; message = ""; base_url = ""; protocol = "openai"; note = ""; models = [] } envs) ))
  in
  let ollama_job = ("__ollama", fun () -> match ollama_models () with Some ms -> Json.array (List.map ms ~fn:Json.string) | None -> Json.null) in
  let results = run_parallel ~timeout_s:40 (ollama_job :: jobs) in
  let accounts =
    List.filter_map results ~fn:(fun (pid, r) ->
      if String.equal pid "__ollama" then None
      else
        match r with
        | None -> None
        | Some j ->
            let c = check_of_json j in
            if check_rank c.status <= check_rank "no_balance" && not (List.is_empty c.models) then
              Some { na_name = ""; na_provider = pid; na_base_url = c.base_url; na_protocol = c.protocol; na_env = c.note; na_models = c.models }
            else None)
  in
  let ollama =
    match List.find results ~fn:(fun (k, _) -> String.equal k "__ollama") with
    | Some (_, Some (Json.Array ms)) ->
        let (local, cloud) = ollama_chat_models (List.filter_map ms ~fn:Json.get_string) in
        let cloud = working_cloud_models cloud in
        let acc name models =
          if List.is_empty models then []
          else [ { na_name = name; na_provider = "ollama"; na_base_url = ollama_base; na_protocol = "openai"; na_env = ""; na_models = models } ]
        in
        acc "ollama_cloud" cloud @ acc "ollama_local" local
    | _ -> []
  in
  let agents =
    List.filter_map agent_specs ~fn:(fun a ->
      Oasis_discover.locate_command ~home a.command |> Option.map ~fn:(fun path -> (a.aid, path)))
  in
  { enable_accounts = []; enable_agents = []; add_accounts = accounts @ ollama; add_agents = agents; goal = None }

let mark_pending = fun () ->
  match Path.from_string (pending_path ()) with
  | Ok p -> ignore (Fs.write "written by the first start; the dashboard opens the setup wizard until it is saved\n" p)
  | Error _ -> ()
