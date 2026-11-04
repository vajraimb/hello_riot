open Std
open Std.Collections

module Json = Std.Data.Json

open Portal_state

(** "Needs your attention" list for the dashboard: actionable problems
    with the configured accounts and agents, each with a copyable fix. *)

type alert = {
  severity: string;  (* error | warn *)
  target: string;
  title: string;
  detail: string;
  fix: string;
}

let alert_json = fun (a : alert) ->
  Json.obj
    [
      ("severity", Json.string a.severity);
      ("target", Json.string a.target);
      ("title", Json.string a.title);
      ("detail", Json.string a.detail);
      ("fix", Json.string a.fix);
    ]

let host_of = fun (url : string) ->
  let rest =
    match String.split ~by:"://" url with
    | [ _; r ] -> r
    | _ -> url
  in
  match String.split ~by:"/" rest |> List.head with
  | Some h -> (match String.split ~by:":" h |> List.head with Some h -> h | None -> h)
  | None -> rest

let login_command = fun command ->
  match Portal_steps.basename command with
  | "claude" -> "claude /login"
  | "cursor-agent" -> "cursor-agent login"
  | "gemini" -> "gemini   # 交互式完成登录后退出"
  | "kimi" -> "kimi login"
  | "grok" -> "grok login"
  | "opencode" -> "opencode auth login"
  | c -> c ^ " login"

let fix_for_error = fun ~(err : string) ~(key_env : string option) ~(host : string) ->
  let e = String.lowercase_ascii err in
  let has s = String.contains e s in
  if has "401" || has "403" || has "auth" || has "unauthorized" || has "invalid_api_key" then
    match key_env with
    | Some env -> "export " ^ env ^ "=<新 key>   # 写进 ~/.zshrc，然后重启网关"
    | None -> "重新登录或更新凭据后重启网关"
  else if has "dns" || has "resolve" || has "connect" || has "refused" || has "unreachable" then
    "dig +short " ^ host ^ " @1.1.1.1   # 拿到真实 IP 后写进 /etc/hosts，或在账户上配置 connect_ip"
  else if has "429" || has "quota" || has "insufficient" || has "balance" then
    "额度恢复前网关会自动绕开它；需要时到服务商控制台充值或调整套餐"
  else ""

let account_alerts = fun (state : state) (a : Portal_config.account) ->
  if not a.Portal_config.enabled then []
  else
    let name = a.Portal_config.name in
    let host = host_of a.Portal_config.base_url in
    let key_env = a.Portal_config.api_key_env in
    let s = Portal_signals.get state.signals name in
    let now = Portal_signals.now_ms () in
    let missing_key =
      match key_env with
      | Some env when not (String.is_empty env) -> (
          match Env.var Env.String ~name:env with
          | Some v when not (String.is_empty v) -> []
          | _ ->
              [
                {
                  severity = "error";
                  target = name;
                  title = "缺少 API key";
                  detail = "网关进程里没有环境变量 " ^ env ^ "，这个账户的请求都会失败。";
                  fix = "export " ^ env ^ "=<key>   # 写进 ~/.zshrc，然后重启网关";
                };
              ]
        )
      | _ -> []
    in
    let last_error = s.Portal_signals.last_error |> Option.unwrap_or ~default:"" in
    let auth =
      if s.Portal_signals.auth_invalid then
        [
          {
            severity = "error";
            target = name;
            title = "key 被拒绝";
            detail = "服务商返回认证失败，key 可能过期或被吊销。" ^ (if String.is_empty last_error then "" else " 最近错误：" ^ Portal_steps.clip last_error 200);
            fix =
              (match key_env with
               | Some env -> "export " ^ env ^ "=<新 key>   # 写进 ~/.zshrc，然后重启网关"
               | None -> "更新凭据后重启网关");
          };
        ]
      else []
    in
    let parked =
      if Portal_signals.is_parked s now then
        let mins = (s.Portal_signals.parked_until_ms - now) / 60000 in
        [
          {
            severity = "warn";
            target = name;
            title = "额度用完，已暂停";
            detail = "约 " ^ Int.to_string (max 1 mins) ^ " 分钟后自动恢复；期间请求会自动走其它账户。";
            fix = "";
          };
        ]
      else []
    in
    let breaker =
      match s.Portal_signals.breaker with
      | Portal_signals.Open_until _ when not s.Portal_signals.auth_invalid ->
          [
            {
              severity = "warn";
              target = name;
              title = "连续失败，已熔断";
              detail =
                "连续失败 " ^ Int.to_string s.Portal_signals.consecutive_failures ^ " 次："
                ^ Portal_feed.error_text last_error;
              fix = fix_for_error ~err:last_error ~key_env ~host;
            };
          ]
      | _ -> []
    in
    missing_key @ auth @ parked @ breaker

let agent_alerts = fun (state : state) ~(discovered : Portal_discover.agent_status list) (a : Portal_agent.agent) ->
  if not a.Portal_agent.enabled then []
  else
    let name = a.Portal_agent.name in
    let cmd = Portal_steps.basename a.Portal_agent.command in
    let status =
      List.find discovered ~fn:(fun d -> String.equal d.Portal_discover.command cmd)
    in
    let presence =
      match status with
      | Some d when not d.Portal_discover.installed ->
          [
            {
              severity = "error";
              target = name;
              title = "CLI 未安装";
              detail = "找不到命令 " ^ cmd ^ "，这个 agent 无法启动。";
              fix = "";
            };
          ]
      | Some d when not d.Portal_discover.logged_in ->
          [
            {
              severity = "error";
              target = name;
              title = "CLI 未登录";
              detail = cmd ^ " 没有登录凭据，任务会直接失败。";
              fix = login_command cmd;
            };
          ]
      | _ -> []
    in
    let s = Portal_signals.get state.signals name in
    let last_error = s.Portal_signals.last_error |> Option.unwrap_or ~default:"" in
    let failing =
      if List.is_empty presence && s.Portal_signals.consecutive_failures >= 2 then
        [
          {
            severity = "warn";
            target = name;
            title = "最近连续失败";
            detail =
              "连续失败 " ^ Int.to_string s.Portal_signals.consecutive_failures ^ " 次："
              ^ Portal_feed.error_text last_error;
            fix = "在终端里手动跑一次确认：" ^ login_command cmd;
          };
        ]
      else []
    in
    presence @ failing

let collect = fun (state : state) ~(home : string) ->
  let config = Sync.Atomic.get state.config in
  let discovered = Portal_discover.scan ~home in
  let all =
    List.flat_map config.Portal_config.accounts ~fn:(account_alerts state)
    @ List.flat_map config.Portal_config.agents ~fn:(agent_alerts state ~discovered)
  in
  List.filter all ~fn:(fun a -> String.equal a.severity "error")
  @ List.filter all ~fn:(fun a -> not (String.equal a.severity "error"))
