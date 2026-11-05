open Std
open Std.Collections

(** HTTP front: auth middleware (spec §5.1), CORS and the Trail route table. *)

module Trail = Oasis_net.Trail
module Json = Std.Data.Json

open Oasis_state
open Oasis_ws
open Oasis_upstream
open Oasis_decisions
open Oasis_conductor
open Oasis_exec_agent
open Oasis_exec_account
open Oasis_api
open Oasis_mcp_tools

(* ---------- auth (spec §5.1) ---------- *)

let bearer_of = fun header ->
  let h = String.trim header in
  if String.starts_with ~prefix:"Bearer " h then
    Some (String.trim (String.sub h ~offset:7 ~len:(String.length h - 7)))
  else None

let host_of_authority = fun authority ->
  if String.starts_with ~prefix:"[" authority then
    match String.split ~by:"]" authority with
    | h :: _ -> String.sub h ~offset:1 ~len:(String.length h - 1)
    | [] -> authority
  else
    match String.split ~by:":" authority with
    | h :: _ -> h
    | [] -> authority

(** With a token configured, everything except the dashboard page needs
    [Authorization: Bearer] ([?token=] for the WebSocket, which browsers can't
    send headers on). Without one only loopback peers get through, and a
    browser [Origin] must name a loopback host so other web pages (or DNS
    rebinding) can't drive the agents via the permissive CORS headers. *)
let use_auth = fun (state : state) (ctx : Trail.ctx) ->
  let path = Net.Uri.path (Net.Http.Request.uri ctx.req) in
  let deny status reason =
    Trail.json ~status ctx (Json.obj [ ("error", Json.obj [ ("message", Json.string reason); ("type", Json.string "oasis_auth") ]) ])
  in
  if Net.Http.Method.equal (Net.Http.Request.method_ ctx.req) Net.Http.Method.Options then ctx
  else if String.equal path "/" then ctx
  else
    match Oasis_config.auth_token (Sync.Atomic.get state.config) with
    | Some token -> (
        let presented =
          match get_header ctx "authorization" |> Option.and_then ~fn:bearer_of with
          | Some t -> Some t
          | None -> if String.equal path "/ws" then query_param ctx "token" else None
        in
        match presented with
        | Some t when constant_time_equal t token -> ctx
        | Some _ -> deny Net.Http.Status.Unauthorized "invalid token"
        | None -> deny Net.Http.Status.Unauthorized "missing bearer token"
      )
    | None ->
        if not (Oasis_config.is_loopback_host (Net.Addr.ip ctx.peer)) then
          deny Net.Http.Status.Forbidden "non-loopback peer and no server.auth_token_env configured"
        else (
          match get_header ctx "origin" with
          | None -> ctx
          | Some origin ->
              let authority =
                match String.split ~by:"://" origin with
                | [ _; rest ] -> rest
                | _ -> origin
              in
              if Oasis_config.is_loopback_host (host_of_authority authority) then ctx
              else deny Net.Http.Status.Forbidden ("cross-origin request from " ^ origin)
        )

let use_cors_with_auth = fun ctx ->
  ctx
  |> Trail.put_resp_header ~name:"Access-Control-Allow-Origin" ~value:"*"
  |> Trail.put_resp_header ~name:"Access-Control-Allow-Methods" ~value:"GET, POST, OPTIONS"
  |> Trail.put_resp_header
    ~name:"Access-Control-Allow-Headers"
    ~value:"Content-Type, Authorization, X-Oasis-Category, X-Oasis-Goal, X-Oasis-Mode, X-Oasis-Session"

let build_trail = fun (state : state) ->
  Trail.pipeline
    [
      Trail.use_server_header "Oasis/0.2 (Riot; Nomad; Trail)";
      use_cors_with_auth;
      use_auth state;
      Trail.router
        [
          Trail.get "/" (fun ctx -> Trail.html ctx Oasis_dashboard.index_html);
          Trail.get "/v1/models" (handle_list_models state);
          Trail.post "/v1/chat/completions" (handle_chat state);
          Trail.post "/mcp" (handle_mcp state);
          Trail.get "/mcp" (fun ctx ->
            Trail.json
              ~status:Net.Http.Status.MethodNotAllowed
              ctx
              (Json.obj
                [
                  ("error", Json.string "MCP uses POST (Streamable HTTP)");
                ]));
          Trail.get "/api/accounts" (handle_list_accounts state);
          Trail.get "/api/decisions" (handle_list_decisions state);
          Trail.get "/api/ledger" (handle_list_ledger state);
          Trail.post "/api/reload" (handle_reload state);
          Trail.get "/api/reload" (fun ctx ->
            Trail.json
              ~status:Net.Http.Status.MethodNotAllowed
              ctx
              (Json.obj [ ("error", Json.string "use POST /api/reload") ]));
          Trail.get "/api/inbox" (handle_list_inbox state);
          Trail.get "/api/agents" (handle_list_agents state);
          Trail.get "/api/activity" (handle_list_activity state);
          Trail.get "/api/requests" (handle_list_requests state);
          Trail.get "/api/feed" (handle_list_feed state);
          Trail.get "/api/feed/task" (handle_feed_task state);
          Trail.post "/api/feed/rate" (handle_rate_task state);
          Trail.post "/api/feed/cancel" (handle_cancel_task state);
          Trail.get "/api/threads" (handle_list_threads state);
          Trail.get "/api/thread" (handle_get_thread state);
          Trail.get "/api/workspace" (handle_workspace state);
          Trail.post "/api/thread/delete" (handle_delete state);
          Trail.get "/api/workspace/file" (handle_workspace_file state);
          Trail.get "/api/alerts" (handle_list_alerts state);
          Trail.post "/api/inbox/reply" (handle_inbox_reply state);
          Trail.get "/api/app-usage" (fun ctx -> Trail.json ctx (Oasis_observe.status_json ()));
          Trail.get "/api/setup/scan" (Oasis_setup_api.handle_scan state);
          Trail.post "/api/setup/verify" (Oasis_setup_api.handle_verify state);
          Trail.post "/api/setup/apply" (Oasis_setup_api.handle_apply state);
          Trail.ws
            "/ws"
            (fun stream accept_key ->
              let welcome =
                Json.obj
                  [
                    ("type", Json.string "ws_connected");
                    ("protocol", Json.string "RFC6455");
                  ]
              in
              let _ = Oasis_net.Trail.Ws.send_text stream (Json.to_string welcome) in
              ());
        ];
    ]
