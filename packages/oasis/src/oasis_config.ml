open Std

(** Oasis configuration: accounts, model KB, and routing policy, loaded from
    TOML. Money is represented in integer nano-dollars throughout. *)

type account = {
  name: string;
  provider: string;
  protocol: string;
  thinking: string;
  base_url: string;
  api_key_env: string option;
  models: string list;
  enabled: bool;
  rpm: int;
  tpm: int;
  daily_limit: int;
  monthly_budget_nano: int;
  supports_prefill: bool;
  quota_error_codes: string list;
  quota_reset: string;
  stream_usage: bool;
  connect_ip: string;
}

type route = {
  category: string;
  accounts: string list;
}

type policy = {
  goal: string;
  routes: route list;
  agent_categories: string list;
  max_fallback: int;
  max_handoffs: int;
  handoff_notice: bool;
  session_ttl_s: int;
  explore_every: int;  (** 0 = never explore *)
  judge: string;  (** "account" or "account:model"; "" = no sampled reviews *)
  judge_every: int;
}

(** Oasis's own directory: [$OASIS_HOME], else [~/.oasis]. Holds the
    config ([oasis.toml]), runtime data ([data/]), agent workspaces
    ([workspaces/]) and logs ([logs/]); the source tree is not involved. *)
let user_home = fun () -> Env.var Env.String ~name:"HOME" |> Option.unwrap_or ~default:"."

let home = fun () ->
  match Env.var Env.String ~name:"OASIS_HOME" with
  | Some h when not (String.is_empty h) -> h
  | _ -> user_home () ^ "/.oasis"

let default_config_path = fun () -> home () ^ "/oasis.toml"

(** [~/x] in config paths means the user's home. *)
let expand = fun (p : string) ->
  if String.equal p "~" then user_home ()
  else if String.starts_with ~prefix:"~/" p then user_home () ^ String.sub p ~offset:1 ~len:(String.length p - 1)
  else p

type t = {
  server_host: string;
  server_port: int;
  data_dir: string;
  workspace_dir: string;  (** per-task agent workdirs; "" = <data_dir>/workspaces *)
  auth_token_env: string option;
  accounts: account list;
  agents: Oasis_agent.agent list;
  kb: Oasis_kb.model_kb list;
  policy: policy;
}

let find_account = fun (cfg : t) name ->
  List.find cfg.accounts ~fn:(fun a -> String.equal a.name name)

let route_for = fun (cfg : t) category ->
  List.find cfg.policy.routes ~fn:(fun r -> String.equal r.category category)

let api_key_of = fun (account : account) ->
  match account.api_key_env with
  | None -> None
  | Some var -> Env.var Env.String ~name:var

let auth_token = fun (cfg : t) ->
  match cfg.auth_token_env with
  | None -> None
  | Some var -> (
      match Env.var Env.String ~name:var with
      | Some v when not (String.is_empty (String.trim v)) -> Some (String.trim v)
      | _ -> None
    )

let is_loopback_host = fun host ->
  String.equal host "localhost"
  || String.starts_with ~prefix:"127." host
  || String.equal host "::1"
  || String.starts_with ~prefix:"::ffff:127." host

(* ---------- TOML parsing ---------- *)

module Toml = Std.Data.Toml

let field = fun table name ->
  List.find table ~fn:(fun (k, _) -> String.equal k name)
  |> Option.map ~fn:(fun (_, v) -> v)

let get_bool_like = fun v ->
  match v with
  | Toml.Bool b -> Some b
  | _ -> (
      match Toml.get_string v with
      | Some "true" -> Some true
      | Some "false" -> Some false
      | _ -> (
          match Toml.get_int v with
          | Some 1 -> Some true
          | Some 0 -> Some false
          | _ -> None
        )
    )

let str_list = fun v ->
  Toml.get_array v
  |> Option.map ~fn:(List.filter_map ~fn:Toml.get_string)

let parse_account = fun fields ->
  match field fields "name" |> Option.and_then ~fn:Toml.get_string with
  | None -> Error "account missing name"
  | Some name ->
      let base_url =
        field fields "base_url" |> Option.and_then ~fn:Toml.get_string
        |> Option.unwrap_or ~default:"https://api.openai.com/v1"
      in
      let api_key_env =
        field fields "api_key_env" |> Option.and_then ~fn:Toml.get_string
      in
      let models =
        field fields "models" |> Option.and_then ~fn:str_list
        |> Option.unwrap_or ~default:[]
      in
      let enabled =
        field fields "enabled" |> Option.and_then ~fn:get_bool_like
        |> Option.unwrap_or ~default:true
      in
      let protocol =
        field fields "protocol" |> Option.and_then ~fn:Toml.get_string
        |> Option.unwrap_or ~default:"openai"
      in
      Ok
        {
          name;
          provider =
            field fields "provider" |> Option.and_then ~fn:Toml.get_string
            |> Option.unwrap_or ~default:"openai";
          protocol;
          thinking =
            field fields "thinking" |> Option.and_then ~fn:Toml.get_string
            |> Option.unwrap_or ~default:"disabled";
          base_url;
          api_key_env;
          models;
          enabled;
          rpm = field fields "rpm" |> Option.and_then ~fn:Toml.get_int |> Option.unwrap_or ~default:0;
          tpm = field fields "tpm" |> Option.and_then ~fn:Toml.get_int |> Option.unwrap_or ~default:0;
          daily_limit =
            field fields "daily_limit" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:0;
          monthly_budget_nano =
            field fields "monthly_budget_nano" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:0;
          supports_prefill =
            field fields "supports_prefill" |> Option.and_then ~fn:get_bool_like
            |> Option.unwrap_or ~default:(String.equal protocol "anthropic");
          quota_error_codes =
            field fields "quota_error_codes" |> Option.and_then ~fn:str_list
            |> Option.unwrap_or ~default:[];
          quota_reset =
            field fields "quota_reset" |> Option.and_then ~fn:Toml.get_string
            |> Option.unwrap_or ~default:"daily";
          stream_usage =
            field fields "stream_usage" |> Option.and_then ~fn:get_bool_like
            |> Option.unwrap_or ~default:true;
          connect_ip =
            field fields "connect_ip" |> Option.and_then ~fn:Toml.get_string
            |> Option.unwrap_or ~default:"";
        }

let parse_kb_model = fun fields ->
  match field fields "name" |> Option.and_then ~fn:Toml.get_string with
  | None -> Error "model missing name"
  | Some name ->
      Ok
        {
          Oasis_kb.name;
          tier = field fields "tier" |> Option.and_then ~fn:Toml.get_int |> Option.unwrap_or ~default:3;
          strengths = field fields "strengths" |> Option.and_then ~fn:str_list |> Option.unwrap_or ~default:[];
          weaknesses = field fields "weaknesses" |> Option.and_then ~fn:str_list |> Option.unwrap_or ~default:[];
          context_window =
            field fields "context_window" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:128000;
          max_output =
            field fields "max_output" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:8192;
          latency =
            field fields "latency" |> Option.and_then ~fn:Toml.get_string
            |> Option.unwrap_or ~default:"medium"
            |> Oasis_kb.latency_of_string;
          in_price_nano =
            field fields "in_price_nano" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:0;
          out_price_nano =
            field fields "out_price_nano" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:0;
          cache_hit_price_nano =
            field fields "cache_hit_price_nano" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:0;
        }

let parse_agent = fun fields ->
  match field fields "name" |> Option.and_then ~fn:Toml.get_string with
  | None -> Error "agent missing name"
  | Some name ->
      Ok
        {
          Oasis_agent.name;
          command =
            field fields "command" |> Option.and_then ~fn:Toml.get_string
            |> Option.unwrap_or ~default:name;
          args_template =
            field fields "args" |> Option.and_then ~fn:str_list
            |> Option.unwrap_or ~default:[ "{prompt}" ];
          home =
            field fields "home" |> Option.and_then ~fn:Toml.get_string
            |> Option.unwrap_or ~default:"";
          models =
            field fields "models" |> Option.and_then ~fn:str_list
            |> Option.unwrap_or ~default:[];
          workdir =
            field fields "workdir" |> Option.and_then ~fn:Toml.get_string
            |> Option.map ~fn:expand |> Option.unwrap_or ~default:"";
          timeout_s =
            field fields "timeout_s" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:0;
          capabilities =
            field fields "capabilities" |> Option.and_then ~fn:str_list
            |> Option.unwrap_or ~default:[];
          tier =
            field fields "tier" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:4;
          strengths =
            field fields "strengths" |> Option.and_then ~fn:str_list
            |> Option.unwrap_or ~default:[];
          weaknesses =
            field fields "weaknesses" |> Option.and_then ~fn:str_list
            |> Option.unwrap_or ~default:[];
          context_window =
            field fields "context_window" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:200000;
          max_output =
            field fields "max_output" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:32768;
          latency =
            field fields "latency" |> Option.and_then ~fn:Toml.get_string
            |> Option.unwrap_or ~default:"slow";
          enabled =
            field fields "enabled" |> Option.and_then ~fn:get_bool_like
            |> Option.unwrap_or ~default:true;
          concurrency_limit =
            field fields "concurrency_limit" |> Option.and_then ~fn:Toml.get_int
            |> Option.unwrap_or ~default:2;
          allowed_workdirs =
            field fields "allowed_workdirs" |> Option.and_then ~fn:str_list
            |> Option.unwrap_or ~default:[];
          env_passthrough =
            field fields "env_passthrough" |> Option.and_then ~fn:str_list
            |> Option.unwrap_or ~default:[];
          resume_args =
            field fields "resume_args" |> Option.and_then ~fn:str_list
            |> Option.unwrap_or ~default:[];
        }

let parse_route = fun fields ->
  match field fields "category" |> Option.and_then ~fn:Toml.get_string with
  | None -> Error "route missing category"
  | Some category ->
      let accounts =
        field fields "accounts" |> Option.and_then ~fn:str_list
        |> Option.unwrap_or ~default:[]
      in
      Ok { category; accounts }

let load = fun path ->
  let path_t = Path.from_string path |> Result.unwrap in
  match Fs.read_to_string path_t with
  | Error e -> Error ("cannot read config: " ^ IO.error_message e)
  | Ok source -> (
      match Toml.parse source with
      | Error e -> Error ("config parse error: " ^ Toml.error_to_string e)
      | Ok root -> (
          match Toml.get_table root with
          | None -> Error "config root is not a table"
          | Some fields ->
              let server_fields =
                field fields "server" |> Option.and_then ~fn:Toml.get_table
                |> Option.unwrap_or ~default:[]
              in
              let server_host =
                field server_fields "host" |> Option.and_then ~fn:Toml.get_string
                |> Option.unwrap_or ~default:"127.0.0.1"
              in
              let server_port =
                field server_fields "port" |> Option.and_then ~fn:Toml.get_int
                |> Option.unwrap_or ~default:8787
              in
              let data_dir_set = field server_fields "data_dir" |> Option.and_then ~fn:Toml.get_string in
              let data_dir = data_dir_set |> Option.map ~fn:expand |> Option.unwrap_or ~default:(home () ^ "/data") in
              (* with the default layout workspaces sit beside data/; a custom
                 data_dir keeps them inside it unless workspace_dir says otherwise *)
              let workspace_dir =
                match field server_fields "workspace_dir" |> Option.and_then ~fn:Toml.get_string with
                | Some w -> expand w
                | None -> if Option.is_none data_dir_set then home () ^ "/workspaces" else ""
              in
              let auth_token_env =
                field server_fields "auth_token_env" |> Option.and_then ~fn:Toml.get_string
              in
              let account_parses =
                field fields "accounts" |> Option.and_then ~fn:Toml.get_array
                |> Option.unwrap_or ~default:[]
                |> List.filter_map ~fn:(fun v ->
                  match Toml.get_table v with
                  | None -> Some (Error "account entry is not a table")
                  | Some t -> Some (parse_account t))
              in
              let accounts =
                List.filter_map
                  account_parses
                  ~fn:(function Ok a -> Some a | Error _ -> None)
              in
              let account_errors =
                List.filter_map
                  account_parses
                  ~fn:(function Error e -> Some e | Ok _ -> None)
              in
              let kb_parses =
                field fields "models" |> Option.and_then ~fn:Toml.get_array
                |> Option.unwrap_or ~default:[]
                |> List.filter_map ~fn:(fun v ->
                  match Toml.get_table v with
                  | None -> Some (Error "model entry is not a table")
                  | Some t -> Some (parse_kb_model t))
              in
              let kb =
                List.filter_map kb_parses ~fn:(function Ok m -> Some m | Error _ -> None)
              in
              let kb_errors =
                List.filter_map kb_parses ~fn:(function Error e -> Some e | Ok _ -> None)
              in
              let route_parses =
                field fields "routes" |> Option.and_then ~fn:Toml.get_array
                |> Option.unwrap_or ~default:[]
                |> List.filter_map ~fn:(fun v ->
                  match Toml.get_table v with
                  | None -> Some (Error "route entry is not a table")
                  | Some t -> Some (parse_route t))
              in
              let routes =
                List.filter_map route_parses ~fn:(function Ok r -> Some r | Error _ -> None)
              in
              let route_errors =
                List.filter_map route_parses ~fn:(function Error e -> Some e | Ok _ -> None)
              in
              let policy_fields =
                field fields "policy" |> Option.and_then ~fn:Toml.get_table
                |> Option.unwrap_or ~default:[]
              in
              let agent_parses =
                field fields "agents" |> Option.and_then ~fn:Toml.get_array
                |> Option.unwrap_or ~default:[]
                |> List.filter_map ~fn:(fun v ->
                  match Toml.get_table v with
                  | None -> Some (Error "agent entry is not a table")
                  | Some t -> Some (parse_agent t))
              in
              let agents =
                List.filter_map agent_parses ~fn:(function Ok a -> Some a | Error _ -> None)
              in
              let agent_errors =
                List.filter_map agent_parses ~fn:(function Error e -> Some e | Ok _ -> None)
              in
              let policy =
                {
                  goal =
                    field policy_fields "goal" |> Option.and_then ~fn:Toml.get_string
                    |> Option.unwrap_or ~default:"balanced";
                  routes;
                  agent_categories =
                    field policy_fields "agent_categories"
                    |> Option.and_then ~fn:str_list
                    |> Option.unwrap_or ~default:[ "coding" ];
                  max_fallback =
                    field policy_fields "max_fallback" |> Option.and_then ~fn:Toml.get_int
                    |> Option.unwrap_or ~default:2;
                  max_handoffs =
                    field policy_fields "max_handoffs" |> Option.and_then ~fn:Toml.get_int
                    |> Option.unwrap_or ~default:2;
                  handoff_notice =
                    field policy_fields "handoff_notice" |> Option.and_then ~fn:get_bool_like
                    |> Option.unwrap_or ~default:true;
                  session_ttl_s =
                    field policy_fields "session_ttl_s" |> Option.and_then ~fn:Toml.get_int
                    |> Option.unwrap_or ~default:600;
                  explore_every =
                    field policy_fields "explore_every" |> Option.and_then ~fn:Toml.get_int
                    |> Option.unwrap_or ~default:10;
                  judge = field policy_fields "judge" |> Option.and_then ~fn:Toml.get_string |> Option.unwrap_or ~default:"";
                  judge_every =
                    field policy_fields "judge_every" |> Option.and_then ~fn:Toml.get_int
                    |> Option.unwrap_or ~default:10;
                }
              in
              let errors = account_errors @ kb_errors @ route_errors @ agent_errors in
              if List.is_empty errors then
                Ok { server_host; server_port; data_dir; workspace_dir; auth_token_env; accounts; agents; kb; policy }
              else
                Error ("config errors: " ^ String.concat "; " errors)
        )
    )
