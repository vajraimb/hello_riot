open Std
open Std.Collections

(** Setup wizard endpoints: [GET /api/setup/scan], [POST /api/setup/verify],
    [POST /api/setup/apply]. *)

module Trail = Oasis_net.Trail
module Json = Std.Data.Json
module S = Oasis_setup

open Oasis_state

let str_field = fun j k -> Json.get_field k j |> Option.and_then ~fn:Json.get_string
let str_list_field = fun j k ->
  Json.get_field k j |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
  |> List.filter_map ~fn:Json.get_string
let bool_map_field = fun j k ->
  Json.get_field k j |> Option.and_then ~fn:Json.get_object |> Option.unwrap_or ~default:[]
  |> List.filter_map ~fn:(fun (n, v) -> Json.get_bool v |> Option.map ~fn:(fun b -> (n, b)))

let bad_request = fun ctx msg ->
  Trail.json ~status:Net.Http.Status.BadRequest ctx (Json.obj [ ("error", Json.string msg) ])

let account_key = fun (a : Oasis_config.account) ->
  match Oasis_config.api_key_of a with Some k when not (String.is_empty (String.trim k)) -> Some k | _ -> None

let usable_account = fun (a : Oasis_config.account) ->
  a.Oasis_config.enabled && (S.is_ollama_account a || Option.is_some (account_key a))

let needs_setup = fun (config : Oasis_config.t) ~home ->
  let pending = match Path.from_string (S.pending_path ()) with Ok p -> (match Fs.exists p with Ok b -> b | Error _ -> false) | Error _ -> false in
  let agents_ok =
    List.any config.Oasis_config.agents ~fn:(fun a ->
      a.Oasis_agent.enabled
      && (String.contains a.Oasis_agent.command "/" || Oasis_discover.find_command ~home a.Oasis_agent.command))
  in
  pending || not (List.any config.Oasis_config.accounts ~fn:usable_account || agents_ok)

let handle_scan = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let home = Oasis_api.discover_home state in
  let ollama =
    match S.run_parallel ~timeout_s:3 [ ("ollama", fun () -> match S.ollama_models () with Some ms -> Json.array (List.map ms ~fn:Json.string) | None -> Json.null) ] with
    | [ (_, Some (Json.Array ms)) ] -> Some (List.filter_map ms ~fn:Json.get_string)
    | _ -> None
  in
  let accounts =
    List.map config.Oasis_config.accounts ~fn:(fun (a : Oasis_config.account) ->
      let env = a.Oasis_config.api_key_env |> Option.unwrap_or ~default:"" in
      Json.obj
        [
          ("name", Json.string a.Oasis_config.name);
          ("provider", Json.string (if S.is_ollama_account a then "ollama" else S.provider_of_account a |> Option.unwrap_or ~default:a.Oasis_config.provider));
          ("base_url", Json.string a.Oasis_config.base_url);
          ("models", Json.array (List.map a.Oasis_config.models ~fn:Json.string));
          ("enabled", Json.bool a.Oasis_config.enabled);
          ("key_env", Json.string env);
          ("key_source", Json.string (if String.is_empty env then "" else S.key_source env));
          ("local", Json.bool (S.is_ollama_account a));
        ])
  in
  let providers =
    List.map S.providers ~fn:(fun (p : S.provider) ->
      let configured =
        List.filter_map config.Oasis_config.accounts ~fn:(fun a ->
          if (not (S.is_ollama_account a)) && Option.equal (S.provider_of_account a) (Some p.S.pid) ~fn:String.equal then Some a.Oasis_config.name else None)
      in
      Json.obj
        [
          ("pid", Json.string p.S.pid);
          ("label", Json.string p.S.label);
          ("env_name", Json.string p.S.env_name);
          ("key_url", Json.string p.S.key_url);
          ("candidates", Json.array (List.map (S.env_candidates p) ~fn:(fun k -> Json.obj [ ("env", Json.string k); ("source", Json.string (S.key_source k)) ])));
          ("configured", Json.array (List.map configured ~fn:Json.string));
        ])
  in
  let discovered = Oasis_discover.scan ~home in
  let agents =
    List.map S.agent_specs ~fn:(fun (a : S.agent_spec) ->
      let path = Oasis_discover.locate_command ~home a.S.command in
      let configured =
        List.find config.Oasis_config.agents ~fn:(fun (c : Oasis_agent.agent) ->
          String.equal c.Oasis_agent.name a.S.aid || String.equal (S.basename c.Oasis_agent.command) a.S.command)
      in
      let logged_in = List.find discovered ~fn:(fun d -> String.equal d.Oasis_discover.name a.S.aid) |> Option.map ~fn:(fun d -> d.Oasis_discover.logged_in) |> Option.unwrap_or ~default:false in
      Json.obj
        [
          ("aid", Json.string a.S.aid);
          ("label", Json.string a.S.alabel);
          ("installed", Json.bool (Option.is_some path));
          ("path", match path with Some p -> Json.string p | None -> Json.null);
          ("logged_in", Json.bool logged_in);
          ("configured", match configured with Some c -> Json.string c.Oasis_agent.name | None -> Json.null);
          ("enabled", Json.bool (match configured with Some c -> c.Oasis_agent.enabled | None -> false));
          ("login_hint", Json.string a.S.login_hint);
          ("install_hint", Json.string a.S.install_hint);
        ])
  in
  let other_agents =
    List.filter_map config.Oasis_config.agents ~fn:(fun (c : Oasis_agent.agent) ->
      if List.any S.agent_specs ~fn:(fun a -> String.equal c.Oasis_agent.name a.S.aid || String.equal (S.basename c.Oasis_agent.command) a.S.command) then None
      else Some (Json.obj [ ("name", Json.string c.Oasis_agent.name); ("command", Json.string c.Oasis_agent.command); ("enabled", Json.bool c.Oasis_agent.enabled) ]))
  in
  Trail.json ctx
    (Json.obj
      [
        ("config_path", Json.string (state.config_path |> Option.unwrap_or ~default:""));
        ("secrets_path", Json.string (S.secrets_path ()));
        ("needs_setup", Json.bool (needs_setup config ~home));
        ("goal", Json.string config.Oasis_config.policy.Oasis_config.goal);
        ("accounts", Json.array accounts);
        ("providers", Json.array providers);
        ("ollama", Json.obj [ ("running", Json.bool (Option.is_some ollama)); ("models", Json.array (List.map (Option.unwrap_or ollama ~default:[]) ~fn:Json.string)); ("base_url", Json.string S.ollama_base) ]);
        ("agents", Json.array agents);
        ("other_agents", Json.array other_agents);
      ])

let no_key = fun ~base_url -> S.check_json { S.status = "no_key"; message = ""; base_url; protocol = "openai"; note = ""; models = [] }

let run_check = fun job ->
  match S.run_parallel ~timeout_s:30 [ ("verify", job) ] with
  | [ (_, Some j) ] -> j
  | _ -> S.check_json { S.status = "unreachable"; message = "timeout"; base_url = ""; protocol = "openai"; note = ""; models = [] }

let handle_verify = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let body = parse_json_body ctx in
  let pasted = str_field body "key" |> Option.map ~fn:String.trim |> Option.and_then ~fn:(fun k -> if String.is_empty k then None else Some k) in
  let from_env = fun name -> match Env.var Env.String ~name with Some v when not (String.is_empty (String.trim v)) -> Some (String.trim v) | _ -> None in
  match (str_field body "account", str_field body "provider") with
  | (Some name, _) -> (
      match Oasis_config.find_account config name with
      | None -> bad_request ctx ("unknown account " ^ name)
      | Some a ->
          let key = match pasted with Some k -> Some k | None -> account_key a in
          if S.is_ollama_account a then Trail.json ctx (run_check (fun () -> S.check_json (S.verify_account a "")))
          else (
            match key with
            | None -> Trail.json ctx (no_key ~base_url:a.Oasis_config.base_url)
            | Some k -> Trail.json ctx (run_check (fun () -> S.check_json (S.verify_account a k)))
          )
    )
  | (None, Some "ollama") ->
      let models = match S.run_parallel ~timeout_s:3 [ ("tags", fun () -> match S.ollama_models () with Some ms -> Json.array (List.map ms ~fn:Json.string) | None -> Json.null) ] with
        | [ (_, Some (Json.Array ms)) ] -> Some (List.filter_map ms ~fn:Json.get_string)
        | _ -> None
      in
      (match models with
       | None -> Trail.json ctx (S.check_json { S.status = "unreachable"; message = "Ollama is not running"; base_url = S.ollama_base; protocol = "openai"; note = ""; models = [] })
       | Some ms ->
           let (local, cloud) = S.ollama_chat_models ms in
           let cloud = S.working_cloud_models cloud in
           Trail.json ctx
             (Json.obj
               [
                 ("status", Json.string (if List.is_empty local && List.is_empty cloud then "model_error" else "ok"));
                 ("base_url", Json.string S.ollama_base);
                 ("local", Json.array (List.map local ~fn:Json.string));
                 ("cloud", Json.array (List.map cloud ~fn:Json.string));
               ]))
  | (None, Some pid) -> (
      match S.find_provider pid with
      | None -> bad_request ctx ("unknown provider " ^ pid)
      | Some p ->
          let key =
            match pasted with
            | Some k -> Some k
            | None -> (
                match str_field body "env" with
                | Some e -> from_env e
                | None -> List.head (S.env_candidates p) |> Option.and_then ~fn:from_env
              )
          in
          (match key with
           | None -> Trail.json ctx (no_key ~base_url:"")
           | Some k -> Trail.json ctx (run_check (fun () -> S.check_json (S.verify_provider p k))))
    )
  | _ -> bad_request ctx "account or provider required"

let read_file = fun path ->
  match Path.from_string path with
  | Error _ -> None
  | Ok p -> (match Fs.read_to_string p with Ok s -> Some s | Error _ -> None)

let handle_apply = fun (state : state) (ctx : Trail.ctx) ->
  match state.config_path with
  | None -> bad_request ctx "no config path (in-memory config)"
  | Some path -> (
      let body = parse_json_body ctx in
      let home = Oasis_api.discover_home state in
      let keys =
        Json.get_field "keys" body |> Option.and_then ~fn:Json.get_object |> Option.unwrap_or ~default:[]
        |> List.filter_map ~fn:(fun (k, v) -> Json.get_string v |> Option.map ~fn:(fun s -> (k, String.trim s)))
        |> List.filter ~fn:(fun (_, v) -> not (String.is_empty v))
      in
      let bad_key = List.find keys ~fn:(fun (k, v) -> (not (S.valid_env_name k)) || String.contains v "\n") in
      match bad_key with
      | Some (k, _) -> bad_request ctx ("invalid key variable " ^ k)
      | None -> (
          let add_accounts =
            Json.get_field "add_accounts" body |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
            |> List.filter_map ~fn:(fun j ->
              match (str_field j "provider", str_field j "base_url") with
              | (Some provider, Some base_url) ->
                  Some
                    {
                      S.na_name = str_field j "name" |> Option.unwrap_or ~default:"";
                      na_provider = provider;
                      na_base_url = base_url;
                      na_protocol = str_field j "protocol" |> Option.unwrap_or ~default:"openai";
                      na_env = str_field j "env" |> Option.unwrap_or ~default:"";
                      na_models = str_list_field j "models";
                    }
              | _ -> None)
          in
          let add_agents =
            str_list_field body "add_agents"
            |> List.filter_map ~fn:(fun aid ->
              S.find_agent_spec aid
              |> Option.map ~fn:(fun (a : S.agent_spec) ->
                (aid, Oasis_discover.locate_command ~home a.S.command |> Option.unwrap_or ~default:a.S.command)))
          in
          let goal = str_field body "goal" |> Option.and_then ~fn:(fun g -> if List.any [ "balanced"; "fastest"; "best"; "cheapest" ] ~fn:(String.equal g) then Some g else None) in
          let choices =
            {
              S.enable_accounts = bool_map_field body "enable_accounts";
              enable_agents = bool_map_field body "enable_agents";
              add_accounts;
              add_agents;
              goal;
            }
          in
          let old_text = read_file path |> Option.unwrap_or ~default:"" in
          let new_text = S.merge ~text:old_text choices in
          match S.save_secrets keys with
          | Error e -> bad_request ctx ("cannot save secrets: " ^ e)
          | Ok () -> (
              let tmp = path ^ ".setup-check" in
              let write p s = match Path.from_string p with Ok pp -> Fs.write s pp |> Result.map_err ~fn:IO.error_message | Error _ -> Error ("bad path " ^ p) in
              let remove p = match Path.from_string p with Ok pp -> ignore (Fs.remove_file pp) | Error _ -> () in
              match write tmp new_text with
              | Error e -> bad_request ctx e
              | Ok () -> (
                  match Oasis_config.load tmp with
                  | Error e ->
                      remove tmp;
                      bad_request ctx ("merged config does not load: " ^ e)
                  | Ok config ->
                      remove tmp;
                      let backup = path ^ ".bak" in
                      let had_old = not (String.is_empty old_text) in
                      let _ = if had_old then write backup old_text else Ok () in
                      match write path new_text with
                      | Error e -> bad_request ctx e
                      | Ok () ->
                          let _ = Sync.Atomic.set state.config config in
                          remove (S.pending_path ());
                          Trail.json ctx
                            (Json.obj
                              [
                                ("ok", Json.bool true);
                                ("config_path", Json.string path);
                                ("backup", if had_old then Json.string backup else Json.null);
                                ("accounts", Json.int (List.length (List.filter config.Oasis_config.accounts ~fn:(fun a -> a.Oasis_config.enabled))));
                                ("agents", Json.int (List.length (List.filter config.Oasis_config.agents ~fn:(fun a -> a.Oasis_agent.enabled))));
                                ("keys_saved", Json.int (List.length keys));
                              ])
                )
            )
        )
    )
