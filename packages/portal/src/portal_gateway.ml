open Std
open Std.Collections

(** Oasis gateway: OpenAI-compatible HTTP front (Nomad/Trail) with real-time
    scored routing (KB fit × cost × latency EMA × load, weights from the
    goal), explainable decisions, cost ledger, SSE streaming, and seamless
    mid-stream handoff to a fallback account when the upstream dies or runs
    out of quota. Outbound I/O runs on dedicated blocking lanes
    (Runtime.spawn_blocked). *)

module Trail = Hello_riot.Trail
module Json = Std.Data.Json

type Message.t +=
  | Upstream_result of (int * string * int, string) result
  | Upstream_chunk of int * string
  | Upstream_failed of int * string
  | Upstream_head of int * int * string
  | Upstream_ended of int
  | Conductor_done of (unit, string) result

type state = {
  config_path: string option;
  config: Portal_config.t Sync.Atomic.t;
  ledger: Portal_ledger.t;
  decisions: Portal_router.decision list Agent.t;
  signals: Portal_signals.t;
  sessions: Portal_session.t;
  tasks: Portal_task.t;
  inbox: Portal_inbox.t;
  ws_clients: (int, Net.TcpStream.t) ConcurrentHashMap.t;
}

(* ---------- helpers ---------- *)

let data_path = fun (state : state) name ->
  (Sync.Atomic.get state.config).Portal_config.data_dir ^ "/" ^ name

let parked_file = fun (state : state) -> data_path state "parked.json"

let parse_json_body = fun (ctx : Trail.ctx) ->
  match Net.Http.Request.body_string ctx.req with
  | None -> Json.obj []
  | Some s -> (
      match Json.from_string s with
      | Ok j -> j
      | Error _ -> Json.obj []
    )

let get_header = fun (ctx : Trail.ctx) name ->
  Net.Http.Request.get_header ctx.req name

let est_input_tokens = fun (body : Json.t) ->
  match Json.get_field "messages" body |> Option.and_then ~fn:Json.get_array with
  | None -> 0
  | Some msgs ->
      let total_chars =
        List.fold_left
          msgs
          ~init:0
          ~fn:(fun acc m ->
            let content =
              Json.get_field "content" m |> Option.and_then ~fn:Json.get_string
              |> Option.unwrap_or ~default:""
            in
            let role =
              Json.get_field "role" m |> Option.and_then ~fn:Json.get_string
              |> Option.unwrap_or ~default:""
            in
            acc + String.length content + String.length role)
      in
      max 1 (total_chars / 4)

(* scheme, host, port, path-prefix. The base_url is the OpenAI-compatible
   root (e.g. "https://agent-gw.kimi.com/coding/v1" or
   "https://api.deepseek.com"); a path prefix is honored and the endpoint
   path is "<prefix>/chat/completions" (or "/v1/chat/completions" when the
   base_url has no path). *)
let parse_base_url = fun (base_url : string) ->
  match String.split ~by:"://" base_url with
  | [ scheme; rest ] ->
      let (host_port, path) =
        match String.index_of rest ~char:'/' with
        | None -> (rest, "")
        | Some i ->
            ( String.sub rest ~offset:0 ~len:i,
              String.sub rest ~offset:i ~len:(String.length rest - i) )
      in
      let (host, port) =
        match String.index_of host_port ~char:':' with
        | Some idx ->
            let port_str =
              String.sub
                host_port
                ~offset:(idx + 1)
                ~len:(String.length host_port - idx - 1)
            in
            ( String.sub host_port ~offset:0 ~len:idx,
              Int.from_string_opt port_str )
        | None ->
            if String.equal scheme "https" then (host_port, Some 443)
            else (host_port, Some 80)
      in
      (scheme, host, port, path)
  | _ -> ("http", base_url, Some 80, "")

let chat_path_of = fun ~protocol path_prefix ->
  let prefix =
    if String.is_empty path_prefix then
      "/v1"
    else if String.ends_with ~suffix:"/" path_prefix then
      String.sub path_prefix ~offset:0 ~len:(String.length path_prefix - 1)
    else
      path_prefix
  in
  if String.equal protocol "anthropic" then
    (* Anthropic-style root, e.g. /api/anthropic -> /v1/messages *)
    prefix ^ "/v1/messages"
  else
    (* OpenAI-style root -> /chat/completions *)
    prefix ^ "/chat/completions"

let connect_upstream = fun ~scheme ~host ~port ->
  let addr = Net.Addr.from_host_and_port ~host ~port in
  match addr with
  | Error _ -> Error ("bad upstream address: " ^ host ^ ":" ^ Int.to_string port)
  | Ok addr -> (
      let res =
        if String.equal scheme "https" then
          Portal_client.connect_tls ~hostname:host addr
        else
          Portal_client.connect_plain addr
      in
      match res with
      | Error e -> Error (Portal_client.error_to_string e)
      | Ok conn -> Ok conn
    )

let upstream_call = fun ~scheme ~host ~port ~path ~headers ~body ->
  match connect_upstream ~scheme ~host ~port with
  | Error e -> Error e
  | Ok conn ->
      let req =
        Portal_client.make_request
          ~method_:"POST"
          ~path
          ~headers
          ~body
          ()
      in
      let t0 = Time.Instant.now () in
      let res = Portal_client.request_string conn req in
      let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed t0) in
      Portal_client.close conn;
      (
        match res with
        | Error e -> Error (Portal_client.error_to_string e)
        | Ok (resp, body_str) -> Ok (resp.Portal_client.status, body_str, latency_ms)
      )

(** Run an outbound request on a dedicated blocking lane; wait up to 60s. *)
let blocking_call = fun ~scheme ~host ~port ~path ~headers ~body ->
  let reply_to = self () in
  let _ =
    Runtime.spawn_blocked (fun () ->
      let res = upstream_call ~scheme ~host ~port ~path ~headers ~body in
      send reply_to (Upstream_result res);
      Ok ())
  in
  let selector msg =
    match msg with
    | Upstream_result r -> Select r
    | _ -> Skip
  in
  try receive ~selector ~timeout:(Time.Duration.from_secs 60) ()
  with Receive_timeout -> Error "upstream timeout (60s)"

(** Outbound streaming request on a blocking lane: body chunks and failures
    are reported to [to_pid] as messages. *)
let stream_upstream = fun ~leg_id ~scheme ~host ~port ~path ~headers ~body ~to_pid ->
  match connect_upstream ~scheme ~host ~port with
  | Error e ->
      send to_pid (Upstream_failed (leg_id, e));
      send to_pid (Upstream_ended leg_id);
      Ok ()
  | Ok conn ->
      let req =
        Portal_client.make_request
          ~method_:"POST"
          ~path
          ~headers
          ~body
          ()
      in
      (
        match Portal_client.request conn req with
        | Error e ->
            Portal_client.close conn;
            send to_pid (Upstream_failed (leg_id, Portal_client.error_to_string e));
            send to_pid (Upstream_ended leg_id);
            Ok ()
        | Ok (resp, body_reader) ->
            if resp.Portal_client.status = 200 then (
              let rec loop () =
                match body_reader.Portal_client.read_some () with
                | Error e ->
                    Portal_client.close conn;
                    send to_pid (Upstream_failed (leg_id, Portal_client.error_to_string e));
                    send to_pid (Upstream_ended leg_id)
                | Ok "" ->
                    (* clean end: signal it; the conductor waits for this
                       before closing the client stream, so the blocking lane
                       is always done before the test tears things down *)
                    Portal_client.close conn;
                    send to_pid (Upstream_ended leg_id)
                | Ok chunk ->
                    send to_pid (Upstream_chunk (leg_id, chunk));
                    loop ()
              in
              loop ()
            ) else (
              (* capture the upstream error body for diagnostics *)
              let err_body =
                match Portal_client.make_body_reader conn resp "" with
                | Error _ -> ""
                | Ok br -> (
                    match br.Portal_client.read_all () with
                    | Error _ -> ""
                    | Ok s ->
                        String.sub s ~offset:0 ~len:(min 300 (String.length s))
                  )
              in
              Portal_client.close conn;
              send to_pid (Upstream_head (leg_id, resp.Portal_client.status, err_body));
              send to_pid (Upstream_ended leg_id)
            );
            Ok ()
      )

let extract_usage = fun (body_str : string) ->
  match Json.from_string body_str with
  | Error _ -> (0, 0, 0)
  | Ok j -> (
      match Json.get_field "usage" j with
      | None -> (0, 0, 0)
      | Some usage ->
          let in_t =
            Json.get_field "prompt_tokens" usage |> Option.and_then ~fn:Json.get_int
            |> Option.unwrap_or ~default:0
          in
          let out_t =
            Json.get_field "completion_tokens" usage
            |> Option.and_then ~fn:Json.get_int
            |> Option.unwrap_or ~default:0
          in
          let cache_t =
            Json.get_field "cached_tokens" usage
            |> Option.and_then ~fn:Json.get_int
            |> Option.unwrap_or ~default:0
          in
          (in_t, out_t, cache_t)
    )

let cost_of = fun (config : Portal_config.t) account_name model in_t out_t cache_t ->
  match Portal_kb.find config.Portal_config.kb model with
  | None -> 0
  | Some kb_entry ->
      Portal_kb.est_cost_nano
        kb_entry
        ~cache_tokens:cache_t
        ~in_tokens:in_t
        ~out_tokens:out_t

let broadcast_json = fun (state : state) (payload : Json.t) ->
  let text = Json.to_string payload in
  let dead = ref [] in
  ConcurrentHashMap.for_each
    state.ws_clients
    ~fn:(fun conn_id stream ->
      match Hello_riot.Trail.Ws.send_text stream text with
      | Ok () -> ()
      | Error _ -> dead := conn_id :: !dead);
  List.for_each !dead ~fn:(fun conn_id ->
    let _ = ConcurrentHashMap.remove state.ws_clients ~key:conn_id in
    ())

let broadcast_event = fun (state : state) ~(type_ : string) ~(request_id : string) ~(data : Json.t) ->
  broadcast_json
    state
    (Json.obj
      [
        ("type", Json.string "event");
        ("event", Json.string type_);
        ("request_id", Json.string request_id);
        ("data", data);
      ])

let new_request_id = fun () ->
  let pick bound =
    match Random.int bound with
    | Ok v -> v
    | Error _ -> 0
  in
  "req-" ^ Int.to_string (pick 1000000000)

let record_decision = fun (state : state) (d : Portal_router.decision) ->
  let d =
    {
      d with
      Portal_router.attempts =
        List.map d.Portal_router.attempts ~fn:(fun (a : Portal_router.attempt) ->
          { a with Portal_router.error = Option.map a.Portal_router.error ~fn:Portal_signals.redact_secrets });
    }
  in
  let _ = Agent.get_and_update state.decisions ~fn:(fun ds -> ((), List.take (d :: ds) ~len:200)) in
  broadcast_json
    state
    (Json.obj
      [
        ("type", Json.string "decision");
        ("decision", Portal_router.decision_json d);
      ]);
  ()

let recent_decisions = fun (state : state) ->
  Agent.get state.decisions ~fn:(fun ds -> ds)

let snapshot_of = fun (state : state) account ->
  let s = Portal_signals.get state.signals account in
  let now = Portal_signals.now_ms () in
  {
    Portal_router.latency_ema_ms = s.Portal_signals.latency_ema_ms;
    in_flight = s.Portal_signals.in_flight;
    breaker_open =
      (match s.Portal_signals.breaker with
       | Portal_signals.Open_until deadline -> now < deadline
       | _ -> false);
    requests_in_window = s.Portal_signals.requests_in_window;
    parked = Portal_signals.is_parked s now;
  }

let write_stream = fun stream payload ->
  let buf = IO.Bytes.from_string payload in
  let total = IO.Bytes.length buf in
  let rec loop pos =
    if pos >= total then
      Ok ()
    else
      match Net.TcpStream.write stream buf ~pos ~len:(total - pos) () with
      | Ok 0 -> Error "client closed connection"
      | Ok n -> loop (pos + n)
      | Error _ -> Error "client write failed"
  in
  loop 0

let delta_chunk_json = fun text ->
  Json.obj
    [
      ("object", Json.string "chat.completion.chunk");
      (
        "choices",
        Json.array
          [
            Json.obj
              [
                ("index", Json.int 0);
                ("delta", Json.obj [ ("content", Json.string text) ]);
                ("finish_reason", Json.null);
              ]
          ]
      );
    ]

let extract_delta_content = fun (data : string) ->
  match Json.from_string data with
  | Error _ -> data
  | Ok j -> (
      match
        Json.get_field "choices" j
        |> Option.and_then ~fn:Json.get_array
        |> Option.and_then ~fn:List.head
        |> Option.and_then ~fn:(fun c -> Json.get_field "delta" c)
      with
      | None -> ""
      | Some delta ->
          let content =
            Json.get_field "content" delta |> Option.and_then ~fn:Json.get_string
            |> Option.unwrap_or ~default:""
          in
          if not (String.is_empty content) then
            content
          else
            (* reasoning models stream their thinking in [reasoning_content]
               with empty [content]: skip the thinking entirely so clients
               only ever see the answer (non-stream responses still get the
               reasoning fallback via normalize_openai_response) *)
            ""
    )

(* ---------- streaming conductor ---------- *)

type conductor_ctx = {
  c_state: state;
  client_stream: Net.TcpStream.t;
  config: Portal_config.t;
  task: Portal_router.task;
  decision: Portal_router.decision;
  messages: Json.t;
  max_tokens: int;
  session: string option;
  request_id: string;
  handoff_allowed: bool;
}

type conductor_state = {
  cc: conductor_ctx;
  mutable candidates: string list;
  mutable attempts: Portal_router.attempt list;
  mutable sent_text: string;
  mutable handoff: Portal_handoff.t option;
  mutable sse_state: Portal_sse.t;
  mutable tokens_out: int;
  mutable usage_in: int option;
  mutable usage_out: int option;
  mutable handoff_count: int;
  mutable handoff_from: (string * string) option;
  mutable open_handoff: Portal_router.handoff option;
  mutable handoffs: Portal_router.handoff list;
  mutable restart_on_content: string option;
  mutable current_account: string;
  mutable current_model: string;
  mutable current_protocol: string;
  mutable leg_start: Time.Instant.t;
  mutable leg_id: int;
  mutable awaiting_leg_end: bool;
  mutable finished: bool;
}

let upstream_headers = fun (account : Portal_config.account) host ->
  let auth_headers =
    match Portal_config.api_key_of account with
    | Some k -> [ ("Authorization", "Bearer " ^ k) ]
    | None -> []
  in
  (* per-request connections: ask the upstream to close after the response
     so the blocking lane sees EOF promptly (otherwise keep-alive streams
     never end and the conductor times out) *)
  ("Content-Type", "application/json")
  :: ("Host", host)
  :: ("Connection", "close")
  :: auth_headers

let upstream_body = fun ?(stream_usage = false) ~model ~messages ~max_tokens ~stream () ->
  Json.obj
    ([
       ("model", Json.string model);
       ("messages", messages);
       ("max_tokens", Json.int max_tokens);
       ("stream", Json.bool stream);
     ]
    @
    if stream && stream_usage then
      [ ("stream_options", Json.obj [ ("include_usage", Json.bool true) ]) ]
    else
      [])
  |> Json.to_string

(** Model for a leg: the one the client asked for when this account serves it,
    otherwise the account's primary model. *)
let model_for_account = fun (account : Portal_config.account) (requested : string option) ->
  match requested with
  | Some m when List.any account.Portal_config.models ~fn:(String.equal m) -> m
  | _ -> List.head account.Portal_config.models |> Option.unwrap_or ~default:""

let rtrim = fun s ->
  let rec go n =
    if n = 0 then 0
    else
      match String.get_unchecked s ~at:(n - 1) with
      | ' ' | '\n' | '\t' | '\r' -> go (n - 1)
      | _ -> n
  in
  String.sub s ~offset:0 ~len:(go (String.length s))

(** Messages for a prefill leg: the original conversation plus the text
    already delivered as a trailing assistant turn. Anthropic rejects a final
    assistant turn ending in whitespace; DeepSeek needs [prefix: true] (beta
    endpoint). *)
let with_assistant_prefix = fun (account : Portal_config.account) messages ~sent ->
  match Json.get_array messages with
  | None -> messages
  | Some msgs ->
      let anthropic = String.equal account.Portal_config.protocol "anthropic" in
      let content = if anthropic then rtrim sent else sent in
      let extra =
        if String.equal account.Portal_config.provider "deepseek" then [ ("prefix", Json.bool true) ]
        else []
      in
      Json.array
        (msgs
        @ [
            Json.obj
              ([ ("role", Json.string "assistant"); ("content", Json.string content) ] @ extra);
          ])

(** True when a request uses tools or structured output: a text prefix
    cannot be spliced into those, so handoff falls back to G3. *)
let handoff_applicable = fun (body : Json.t) ->
  let has k = Option.is_some (Json.get_field k body) in
  let json_format =
    match
      Json.get_field "response_format" body
      |> Option.and_then ~fn:(fun rf -> Json.get_field "type" rf)
      |> Option.and_then ~fn:Json.get_string
    with
    | Some t -> String.starts_with ~prefix:"json" t
    | None -> false
  in
  not (has "tools" || has "tool_choice" || has "functions" || json_format)

let restart_notice = fun ~account ->
  "\n\n[Oasis: 上游中断，已切换到 " ^ account ^ " 重新生成]\n\n"

(** Token usage carried by one streaming event: OpenAI's final usage chunk,
    Anthropic's message_start (input) and message_delta (output). *)
let stream_usage_of = fun ~anthropic (data : string) ->
  match Json.from_string data with
  | Error _ -> (None, None)
  | Ok j ->
      let int_at path =
        List.fold_left path ~init:(Some j) ~fn:(fun acc k ->
          Option.and_then acc ~fn:(fun v -> Json.get_field k v))
        |> Option.and_then ~fn:Json.get_int
      in
      if anthropic then
        match Json.get_field "type" j |> Option.and_then ~fn:Json.get_string with
        | Some "message_start" -> (int_at [ "message"; "usage"; "input_tokens" ], None)
        | Some "message_delta" -> (None, int_at [ "usage"; "output_tokens" ])
        | _ -> (None, None)
      else
        (int_at [ "usage"; "prompt_tokens" ], int_at [ "usage"; "completion_tokens" ])

(** Apply a failed upstream call to the account's signals according to its
    error class (spec §2.4.1). *)
let apply_failure = fun (state : state) (config : Portal_config.t) ~account ~status ~body ~err ->
  let quota_codes, reset =
    match Portal_config.find_account config account with
    | Some a -> (a.Portal_config.quota_error_codes, a.Portal_config.quota_reset)
    | None -> ([], "daily")
  in
  let cls = Portal_signals.classify_error ~status ~body ~quota_codes in
  let now = Portal_signals.now_ms () in
  let _ =
    Portal_signals.update state.signals account ~fn:(fun s ->
      match cls with
      | Portal_signals.Transient -> Portal_signals.record_failure s ~error:err now
      | Portal_signals.Quota ->
          Portal_signals.record_quota s ~error:err
            ~until_ms:(Portal_signals.quota_reset_at ~now_ms:now ~reset)
      | Portal_signals.Client { auth } -> Portal_signals.record_client_error s ~error:err ~auth)
  in
  (
    match cls with
    | Portal_signals.Quota -> Portal_signals.save_parked state.signals ~path:(parked_file state)
    | _ -> ()
  );
  cls

let run_conductor = fun (cc : conductor_ctx) ~(candidates : string list) ~(parent : Pid.t) () ->
  let me = self () in
  let policy = cc.config.Portal_config.policy in
  let cs =
    {
      cc;
      candidates;
      attempts = [];
      sent_text = "";
      handoff = None;
      sse_state = Portal_sse.init;
      tokens_out = 0;
      usage_in = None;
      usage_out = None;
      handoff_count = 0;
      handoff_from = None;
      open_handoff = None;
      handoffs = [];
      restart_on_content = None;
      current_account = "";
      current_model = "";
      current_protocol = "openai";
      leg_start = Time.Instant.now ();
      leg_id = 0;
      awaiting_leg_end = false;
      finished = false;
    }
  in
  let sync_open_handoff () =
    match (cs.open_handoff, cs.handoff) with
    | (Some h, Some splice) ->
        let level =
          match Portal_handoff.level splice with
          | Some l -> Portal_handoff.level_to_string l
          | None -> h.Portal_router.level
        in
        cs.open_handoff <-
          Some
            {
              h with
              Portal_router.matched_bytes = Portal_handoff.matched_bytes splice;
              diverged =
                (match Portal_handoff.diverged_at splice with
                 | Some k -> k < h.Portal_router.sent_bytes
                 | None -> false);
              level;
            }
    | _ -> ()
  in
  let close_open_handoff ~unresolved =
    match cs.open_handoff with
    | None -> ()
    | Some h ->
        let h = if String.equal h.Portal_router.level "?" then { h with Portal_router.level = unresolved } else h in
        cs.handoffs <- h :: cs.handoffs;
        cs.open_handoff <- None;
        broadcast_event
          cc.c_state
          ~type_:"handoff"
          ~request_id:cc.request_id
          ~data:(Portal_router.handoff_json h)
  in
  let set_open_level level =
    match cs.open_handoff with
    | Some h -> cs.open_handoff <- Some { h with Portal_router.level }
    | None -> ()
  in
  let decision_now () =
    {
      cc.decision with
      Portal_router.attempts = List.rev cs.attempts;
      handoffs = List.rev cs.handoffs;
    }
  in
  let record_attempt_ok ~cost ~latency_ms =
    {
      Portal_router.account = cs.current_account;
      model = cs.current_model;
      status = Some 200;
      error = None;
      latency_ms;
      cost_nano = cost;
    }
  in
  let finish_ok () =
    if not cs.finished then (
      cs.finished <- true;
      sync_open_handoff ();
      close_open_handoff ~unresolved:"G1";
      let latency_ms =
        Time.Duration.to_millis (Time.Instant.elapsed cs.leg_start)
      in
      let in_tokens = cs.usage_in |> Option.unwrap_or ~default:cc.task.Portal_router.est_in_tokens in
      let out_tokens = cs.usage_out |> Option.unwrap_or ~default:cs.tokens_out in
      let cost =
        cost_of
          cc.config
          cs.current_account
          cs.current_model
          in_tokens
          out_tokens
          0
      in
      let _ =
        Portal_signals.update
          cc.c_state.signals
          cs.current_account
          ~fn:(fun s ->
            Portal_signals.record_success
              s
              ~latency_ms
              ~tokens:out_tokens
              (Portal_signals.now_ms ()))
      in
      Portal_ledger.record
        cc.c_state.ledger
        ~account:cs.current_account
        ~model:cs.current_model
        ~in_tokens
        ~out_tokens
        ~cache_tokens:0
        ~cost_nano:cost
        ~latency_ms
        ~status:"ok"
        ();
      let decision =
        {
          (decision_now ()) with
          Portal_router.chosen = Some cs.current_account;
          Portal_router.attempts = List.rev (record_attempt_ok ~cost ~latency_ms :: cs.attempts);
        }
      in
      record_decision cc.c_state decision;
      (
        match cc.session with
        | Some sid ->
            Portal_session.pin
              cc.c_state.sessions
              ~session:sid
              ~account:cs.current_account
              ~now_ms:(Portal_signals.now_ms ())
        | None -> ()
      );
      let _ = write_stream cc.client_stream "data: [DONE]\n\n" in
      send parent (Conductor_done (Ok ()))
    )
  in
  let finish_failed ~reason =
    if not cs.finished then (
      cs.finished <- true;
      close_open_handoff ~unresolved:"G0";
      record_decision cc.c_state (decision_now ());
      let err =
        Json.obj
          [
            (
              "error",
              Json.obj
                [
                  ("message", Json.string reason);
                  ("type", Json.string "oasis_upstream_failed");
                ]
            );
          ]
      in
      let _ = write_stream cc.client_stream ("data: " ^ Json.to_string err ^ "\n\n") in
      let _ = write_stream cc.client_stream "data: [DONE]\n\n" in
      send parent (Conductor_done (Ok ()))
    )
  in
  let finish_error e =
    if not cs.finished then (
      cs.finished <- true;
      close_open_handoff ~unresolved:"G0";
      record_decision cc.c_state (decision_now ());
      send parent (Conductor_done (Error e))
    )
  in
  let rec start_next () =
    if cs.finished then
      ()
    else
      match cs.candidates with
      | [] ->
          finish_failed ~reason:"all upstream accounts failed"
      | name :: rest -> (
          cs.candidates <- rest;
          match Portal_config.find_account cc.config name with
          | None ->
              cs.attempts <-
                {
                  Portal_router.account = name;
                  model = "";
                  status = None;
                  error = Some "unknown_account";
                  latency_ms = 0;
                  cost_nano = 0;
                }
                :: cs.attempts;
              start_next ()
          | Some account ->
              let prev_model = cs.current_model in
              cs.current_account <- name;
              cs.leg_id <- cs.leg_id + 1;
              let this_leg = cs.leg_id in
              cs.current_model <- model_for_account account cc.task.Portal_router.model;
              cs.current_protocol <- account.Portal_config.protocol;
              cs.leg_start <- Time.Instant.now ();
              cs.usage_in <- None;
              cs.usage_out <- None;
              cs.tokens_out <- 0;
              let _ =
                Portal_signals.update
                  cc.c_state.signals
                  name
                  ~fn:Portal_signals.mark_in_flight
              in
              let prefill =
                match cs.handoff_from with
                | None -> false
                | Some (from, reason) ->
                    let prefill = account.Portal_config.supports_prefill && cc.handoff_allowed in
                    cs.handoff_from <- None;
                    cs.open_handoff <-
                      Some
                        {
                          Portal_router.from_account = from;
                          to_account = name;
                          reason;
                          sent_bytes = String.length cs.sent_text;
                          matched_bytes = 0;
                          diverged = false;
                          level = (if prefill then "?" else "G3");
                          model_changed = not (String.equal prev_model cs.current_model);
                          at_ms = Portal_signals.now_ms ();
                        };
                    if prefill then (
                      cs.handoff <- Some (Portal_handoff.init ~sent_so_far:cs.sent_text);
                      cs.restart_on_content <- None
                    ) else (
                      cs.handoff <- None;
                      cs.restart_on_content <-
                        Some (if policy.Portal_config.handoff_notice then restart_notice ~account:name else "")
                    );
                    prefill
              in
              let messages_up =
                if prefill then with_assistant_prefix account cc.messages ~sent:cs.sent_text
                else cc.messages
              in
              let (scheme, host, port_opt, path_prefix) =
                parse_base_url account.Portal_config.base_url
              in
              let port = port_opt |> Option.unwrap_or ~default:443 in
              let chat_path = chat_path_of ~protocol:cs.current_protocol path_prefix in
              let body =
                if String.equal cs.current_protocol "anthropic" then
                  Portal_anthropic.to_request
                    ~thinking:(if prefill then "disabled" else account.Portal_config.thinking)
                    ~model:cs.current_model
                    ~messages:messages_up
                    ~max_tokens:cc.max_tokens
                    ~stream:true
                else
                  upstream_body
                    ~stream_usage:account.Portal_config.stream_usage
                    ~model:cs.current_model
                    ~messages:messages_up
                    ~max_tokens:cc.max_tokens
                    ~stream:true
                    ()
              in
              let _ =
                Runtime.spawn_blocked (fun () ->
                  let res =
                    stream_upstream
                      ~leg_id:this_leg
                      ~scheme
                      ~host
                      ~port
                      ~path:chat_path
                      ~headers:(upstream_headers account host)
                      ~body
                      ~to_pid:me
                  in
                  (
                    match res with
                    | Ok () -> ()
                    | Error e -> send me (Upstream_failed (this_leg, e))
                  );
                  Ok ())
              in
              ()
        )
  in
  let forward_to_client text =
    if not (String.is_empty text) then (
      (
        match cs.restart_on_content with
        | None -> ()
        | Some notice ->
            cs.restart_on_content <- None;
            cs.sent_text <- "";
            if not (String.is_empty notice) then
              let _ =
                write_stream cc.client_stream ("data: " ^ Json.to_string (delta_chunk_json notice) ^ "\n\n")
              in
              ()
      );
      cs.sent_text <- cs.sent_text ^ text;
      cs.tokens_out <- cs.tokens_out + (String.length text / 4);
      match
        write_stream
          cc.client_stream
          ("data: " ^ Json.to_string (delta_chunk_json text) ^ "\n\n")
      with
      | Error e -> finish_error e
      | Ok () -> ()
    )
  in
  let apply_step = function
    | Portal_handoff.Forward text -> forward_to_client text
    | Portal_handoff.Restart_with text ->
        cs.handoff <- None;
        set_open_level "G3";
        cs.restart_on_content <-
          Some (if policy.Portal_config.handoff_notice then restart_notice ~account:cs.current_account else "");
        forward_to_client text
  in
  let handle_content content =
    match cs.handoff with
    | None -> forward_to_client content
    | Some h ->
        let (step, h') = Portal_handoff.step h content in
        cs.handoff <- Some h';
        sync_open_handoff ();
        apply_step step
  in
  let flush_handoff () =
    match cs.handoff with
    | None -> ()
    | Some h ->
        let (step, h') = Portal_handoff.finish h in
        cs.handoff <- Some h';
        sync_open_handoff ();
        apply_step step
  in
  let handle_chunk chunk =
    if not cs.finished then (
      let (events, sse') = Portal_sse.feed cs.sse_state chunk in
      cs.sse_state <- sse';
      List.for_each
        events
        ~fn:(fun ev ->
          if cs.finished || cs.awaiting_leg_end then
            ()
          else
            let anthropic = String.equal cs.current_protocol "anthropic" in
            let is_done =
              if anthropic then
                Portal_anthropic.is_stream_end ev.Portal_sse.data
              else
                ev.Portal_sse.done_sentinel
            in
            if is_done then (
              (* upstream finished cleanly: wait for the blocking lane to
                 signal [Upstream_ended] before closing the client stream *)
              flush_handoff ();
              cs.awaiting_leg_end <- true
            ) else (
              let (u_in, u_out) = stream_usage_of ~anthropic ev.Portal_sse.data in
              if Option.is_some u_in then cs.usage_in <- u_in;
              if Option.is_some u_out then cs.usage_out <- u_out;
              let content_opt =
                if anthropic then
                  Portal_anthropic.extract_delta_text ev.Portal_sse.data
                else
                  Some (extract_delta_content ev.Portal_sse.data)
              in
              match content_opt with
              | None -> ()
              | Some content -> handle_content content
            ))
    )
  in
  let handle_failure ~err ~status ~body =
    if not cs.finished then (
      let latency_ms =
        Time.Duration.to_millis (Time.Instant.elapsed cs.leg_start)
      in
      let _ =
        apply_failure cc.c_state cc.config ~account:cs.current_account ~status ~body ~err
      in
      Portal_ledger.record
        cc.c_state.ledger
        ~account:cs.current_account
        ~model:cs.current_model
        ~in_tokens:(cs.usage_in |> Option.unwrap_or ~default:cc.task.Portal_router.est_in_tokens)
        ~out_tokens:cs.tokens_out
        ~cache_tokens:0
        ~cost_nano:0
        ~latency_ms
        ~status:"stream_failed"
        ();
      let attempt =
        {
          Portal_router.account = cs.current_account;
          model = cs.current_model;
          status;
          error = Some err;
          latency_ms;
          cost_nano = 0;
        }
      in
      cs.attempts <- attempt :: cs.attempts;
      (* text held back for head classification was really generated:
         deliver it before failing over *)
      flush_handoff ();
      close_open_handoff ~unresolved:"G0";
      cs.handoff <- None;
      cs.sse_state <- Portal_sse.init;
      cs.awaiting_leg_end <- false;
      let delivered = not (String.is_empty cs.sent_text) in
      if not delivered then
        start_next ()
      else if cs.handoff_count >= policy.Portal_config.max_handoffs then
        finish_failed ~reason:("handoff limit reached after " ^ cs.current_account ^ " failed: " ^ err)
      else (
        cs.handoff_count <- cs.handoff_count + 1;
        cs.handoff_from <- Some (cs.current_account, err);
        start_next ()
      )
    )
  in
  let rec loop () =
    if not cs.finished then (
      let selector msg =
        match msg with
        | Upstream_chunk (leg, c) when leg = cs.leg_id -> Select (`Chunk c)
        | Upstream_failed (leg, e) when leg = cs.leg_id -> Select (`Failed e)
        | Upstream_head (leg, s, b) when leg = cs.leg_id -> Select (`Head (s, b))
        | Upstream_ended leg when leg = cs.leg_id -> Select `Leg_end
        | _ -> Skip
      in
      match receive ~selector ~timeout:(Time.Duration.from_secs 120) () with
      | `Chunk c ->
          handle_chunk c;
          loop ()
      | `Failed e ->
          handle_failure ~err:e ~status:None ~body:"";
          loop ()
      | `Head (s, body) ->
          let err =
            if String.is_empty body then
              "upstream_rejected_http_" ^ Int.to_string s
            else
              "upstream_http_" ^ Int.to_string s ^ ": " ^ body
          in
          handle_failure ~err ~status:(Some s) ~body;
          loop ()
      | `Leg_end ->
          if cs.awaiting_leg_end then
            finish_ok ()
          else (
            (* the upstream closed without a done event: treat as a cut *)
            handle_failure ~err:"upstream_stream_ended_early" ~status:None ~body:"";
            loop ()
          )
      | exception Receive_timeout ->
          handle_failure ~err:"upstream_stream_timeout" ~status:None ~body:"";
          loop ()
    )
  in
  start_next ();
  loop ();
  Ok ()

(* Reasoning models (deepseek-v4-pro etc.) may put everything in
   [reasoning_content] with an empty [content] for small max_tokens budgets;
   fill content from reasoning so clients still get a usable answer. *)
let normalize_openai_response = fun (j : Json.t) ->
  match
    Json.get_field "choices" j |> Option.and_then ~fn:Json.get_array
    |> Option.and_then ~fn:List.head
  with
  | None -> j
  | Some choice -> (
      match Json.get_field "message" choice with
      | None -> j
      | Some message ->
          let content =
            Json.get_field "content" message |> Option.and_then ~fn:Json.get_string
            |> Option.unwrap_or ~default:""
          in
          let reasoning =
            Json.get_field "reasoning_content" message
            |> Option.and_then ~fn:Json.get_string
            |> Option.unwrap_or ~default:""
          in
          if String.is_empty content && not (String.is_empty reasoning) then (
            (* rebuild message object with content filled *)
            match Json.get_object message with
            | None -> j
            | Some fields ->
                let fields' =
                  List.filter_map fields ~fn:(fun (k, v) ->
                    if String.equal k "content" then
                      Some (k, Json.string reasoning)
                    else
                      Some (k, v))
                in
                (* rebuild choice object *)
                match Json.get_object choice with
                | None -> j
                | Some choice_fields ->
                    let choice_fields' =
                      List.filter_map choice_fields ~fn:(fun (k, v) ->
                        if String.equal k "message" then
                          Some (k, Json.obj fields')
                        else
                          Some (k, v))
                    in
                    (* rebuild top-level object *)
                    match Json.get_object j with
                    | None -> j
                    | Some top_fields ->
                        let top_fields' =
                          List.filter_map top_fields ~fn:(fun (k, v) ->
                            if String.equal k "choices" then
                              Some (k, Json.array [ Json.obj choice_fields' ])
                            else
                              Some (k, v))
                        in
                        Json.obj top_fields'
          ) else
            j
    )

(* ---------- chat handler ---------- *)

let make_lookups = fun (state : state) ->
  {
    Portal_router.month_spent = (fun a -> Portal_ledger.month_spent state.ledger a);
    day_requests = (fun a -> Portal_ledger.day_requests state.ledger a);
    snapshot = (fun a -> snapshot_of state a);
  }


(* ---------- agent routing and execution ---------- *)

let agent_prompt_of_body = fun (body : Json.t) ->
  let messages =
    Json.get_field "messages" body |> Option.and_then ~fn:Json.get_array
    |> Option.unwrap_or ~default:[]
  in
  let systems =
    List.filter_map messages ~fn:(fun m ->
      match Json.get_field "role" m |> Option.and_then ~fn:Json.get_string with
      | Some "system" ->
          Json.get_field "content" m |> Option.and_then ~fn:Json.get_string
      | _ -> None)
  in
  let rest =
    List.filter_map messages ~fn:(fun m ->
      match Json.get_field "role" m |> Option.and_then ~fn:Json.get_string with
      | Some ("user" | "assistant") ->
          let role =
            Json.get_field "role" m |> Option.and_then ~fn:Json.get_string
            |> Option.unwrap_or ~default:"user"
          in
          let content =
            Json.get_field "content" m |> Option.and_then ~fn:Json.get_string
            |> Option.unwrap_or ~default:""
          in
          Some (role ^ ": " ^ content)
      | _ -> None)
  in
  let system_prefix =
    if List.is_empty systems then ""
    else String.concat "\n" systems ^ "\n\n"
  in
  system_prefix ^ String.concat "\n" rest

let route_agents = fun (state : state) (config : Portal_config.t) (category : string) (model : string option) ->
  let now = Portal_signals.now_ms () in
  let candidates =
    List.filter config.Portal_config.agents ~fn:(fun a -> a.Portal_agent.enabled)
  in
  let rejects = ref [] in
  let passing =
    List.filter_map candidates ~fn:(fun a ->
      let model_ok =
        match model with
        | None -> true
        | Some m -> List.any a.Portal_agent.models ~fn:(String.equal m)
      in
      let s = Portal_signals.get state.signals a.Portal_agent.name in
      let breaker_open =
        match s.Portal_signals.breaker with
        | Portal_signals.Open_until deadline -> now < deadline
        | _ -> false
      in
      let concurrency_ok = s.Portal_signals.in_flight < max 1 a.Portal_agent.concurrency_limit in
      if not model_ok then (
        rejects := { Portal_router.account = a.Portal_agent.name; reason = "model_not_served" } :: !rejects;
        None
      ) else if breaker_open then (
        rejects := { Portal_router.account = a.Portal_agent.name; reason = "circuit_open" } :: !rejects;
        None
      ) else if not concurrency_ok then (
        rejects := { Portal_router.account = a.Portal_agent.name; reason = "concurrency_limit" } :: !rejects;
        None
      ) else
        let fit = Portal_agent.fit a ~category in
        let lat = Portal_router.latency_score_agent ~ema_ms:s.Portal_signals.latency_ema_ms in
        Some (a, fit + lat)
    )
  in
  let sorted =
    List.sort passing ~compare:(fun (_, s1) (_, s2) ->
      if s1 > s2 then LT else if s1 < s2 then GT else EQ)
  in
  let chosen = List.head sorted |> Option.map ~fn:(fun (a, _) -> a.Portal_agent.name) in
  let fallback_order =
    match chosen with
    | None -> []
    | Some nm ->
        List.filter_map sorted ~fn:(fun (a, _) ->
          if String.equal a.Portal_agent.name nm then None else Some a.Portal_agent.name)
  in
  {
    Portal_router.task_category = category;
    chosen;
    fallback_order;
    rejected = List.rev !rejects;
    attempts = [];
    scores = List.map sorted ~fn:(fun (a, sc) -> (a.Portal_agent.name, sc));
    unpriced = [];
    handoffs = [];
  }

let find_agent = fun (config : Portal_config.t) name ->
  List.find config.Portal_config.agents ~fn:(fun a -> String.equal a.Portal_agent.name name)

type Message.t +=
  | Agent_call_result of (string, string) result

let blocking_agent_call = fun ~agent ~model ~prompt ->
  Portal_agent_worker.run_task
    ~name:agent.Portal_agent.name
    ~agent
    ~model
    ~prompt
    ~timeout_s:agent.Portal_agent.timeout_s
    ()

let agent_result_json = fun ~agent ~text ->
  Json.obj
    [
      ("id", Json.string ("agent-" ^ agent.Portal_agent.name));
      ("object", Json.string "chat.completion");
      ("model", Json.string agent.Portal_agent.name);
      (
        "choices",
        Json.array
          [
            Json.obj
              [
                ("index", Json.int 0);
                (
                  "message",
                  Json.obj
                    [
                      ("role", Json.string "assistant");
                      ("content", Json.string text);
                    ]
                );
                ("finish_reason", Json.string "stop");
              ]
          ]
      );
      (
        "usage",
        Json.obj
          [
            ("prompt_tokens", Json.int 0);
            ("completion_tokens", Json.int 0);
            ("total_tokens", Json.int 0);
          ]
      );
    ]

let audit_file = fun (state : state) ->
  let config = Sync.Atomic.get state.config in
  config.Portal_config.data_dir ^ "/requests.jsonl"

(** FNV-1a (32-bit) as 8 hex digits: lets the audit log correlate identical
    requests without storing their content. *)
let hash8 = fun s ->
  let h = ref 0x811c9dc5 in
  for i = 0 to String.length s - 1 do
    h := ((!h lxor Char.code (String.get_unchecked s ~at:i)) * 0x01000193) land 0xffffffff
  done;
  let hex = "0123456789abcdef" in
  String.concat ""
    (List.init ~count:8 ~fn:(fun k ->
      let nib = (!h lsr ((7 - k) * 4)) land 0xf in
      String.sub hex ~offset:nib ~len:1))

(** One line per request: metadata only, never prompt or completion text. *)
let audit_log = fun (state : state) ~path ~category ~goal ~stream_ ?(request_id = "") ?(body = "") () ->
  let line =
    Json.to_string
      (Json.obj
        [
          ("ts", Json.float (Time.SystemTime.now () |> Time.SystemTime.secs_float));
          ("path", Json.string path);
          ("category", Json.string category);
          ("goal", Json.string goal);
          ("stream", Json.bool stream_);
          ("request_id", Json.string request_id);
          ("body_len", Json.int (String.length body));
          ("body_hash8", Json.string (hash8 body));
        ])
    ^ "\n"
  in
  match Fs.File.open_append (Path.from_string (audit_file state) |> Result.unwrap) with
  | Ok file ->
      let _ = Fs.File.write_all file line in
      let _ = Fs.File.close file in
      ()
  | Error _ -> ()

let handle_list_requests = fun (state : state) (ctx : Trail.ctx) ->
  let path = audit_file state in
  match Fs.read_to_string (Path.from_string path |> Result.unwrap) with
  | Error _ -> Trail.json ctx (Json.obj [ ("requests", Json.array []) ])
  | Ok content ->
      let lines = String.split ~by:"\n" content in
      let items =
        List.filter_map lines ~fn:(fun l ->
          if String.is_empty l then None
          else Json.from_string l |> Result.to_option)
        |> List.rev |> List.take ~len:50
      in
      Trail.json ctx (Json.obj [ ("requests", Json.array items) ])



let handle_chat_agent = fun (state : state) (ctx : Trail.ctx) (body : Json.t) ~(category : string) ~(stream_requested : bool) ~(request_id : string) ->
  audit_log state ~path:"/agent-path-enter" ~category ~goal:"-" ~stream_:stream_requested ~request_id ();
  let config = Sync.Atomic.get state.config in
  let model =
    Json.get_field "model" body |> Option.and_then ~fn:Json.get_string
  in
  let decision = route_agents state config category model in
  broadcast_event
    state
    ~type_:"routed"
    ~request_id
    ~data:
      (Json.obj
        [
          ("mode", Json.string "agent");
          ("chosen", decision.Portal_router.chosen |> Option.map ~fn:Json.string |> Option.unwrap_or ~default:Json.null);
          (
            "candidates",
            Json.array
              (List.map decision.Portal_router.scores ~fn:(fun (nm, sc) ->
                Json.obj [ ("name", Json.string nm); ("score", Json.int sc) ]))
          );
          (
            "rejected",
            Json.array
              (List.map decision.Portal_router.rejected ~fn:(fun r ->
                Json.obj [ ("name", Json.string r.Portal_router.account); ("reason", Json.string r.Portal_router.reason) ]))
          );
        ]);
  audit_log
    state
    ~path:"/agent-path-routed"
    ~category:(decision.Portal_router.chosen |> Option.unwrap_or ~default:"none")
    ~goal:(Int.to_string (List.length decision.Portal_router.fallback_order))
    ~stream_:stream_requested
    ();
  let candidates =
    match decision.Portal_router.chosen with
    | Some nm -> nm :: decision.Portal_router.fallback_order
    | None -> []
  in
  if List.is_empty candidates then (
    record_decision state decision;
    Trail.json
      ~status:Net.Http.Status.PaymentRequired
      ctx
      (Json.obj
        [
          ("error", Json.string "no_agent_available");
          ("decision", Portal_router.decision_json decision);
        ])
  ) else
    let prompt0 = agent_prompt_of_body body in
    if stream_requested then (
      let sent = ref "" in
      let candidates_left = ref candidates in
      let attempts = ref [] in
      let current = ref "" in
      let t0 = ref (Time.Instant.now ()) in
      let rec start_agent () =
        match !candidates_left with
        | [] -> false
        | nm :: rest -> (
            candidates_left := rest;
            current := nm;
            t0 := Time.Instant.now ();
            match find_agent config nm with
            | None ->
                attempts :=
                  { Portal_router.account = nm; model = nm; status = None; error = Some "unknown_agent"; latency_ms = 0; cost_nano = 0 }
                  :: !attempts;
                start_agent ()
            | Some agent ->
                let _ =
                  Portal_signals.update state.signals nm ~fn:Portal_signals.mark_in_flight
                in
                broadcast_event
                  state
                  ~type_:"attempt_started"
                  ~request_id
                  ~data:(Json.obj [ ("account", Json.string nm) ]);
                let model_for =
                  match model with
                  | Some m -> m
                  | None -> List.head agent.Portal_agent.models |> Option.unwrap_or ~default:""
                in
                let prompt =
                  if String.is_empty !sent then prompt0
                  else
                    prompt0
                    ^ "\n\n[上一个 agent 的输出已部分完成，请直接继续并补全任务。之前输出:]\n"
                    ^ !sent
                in
                let agent = agent in
                (* spawn streaming runner on a blocking lane *)
                let me = self () in
                let leg = ref 1 in
                let runner_pid =
                  Runtime.spawn_blocked (fun () ->
                    let res =
                      Portal_agent.stream
                        ~leg:!leg
                        ~agent
                        ~model:model_for
                        ~prompt
                        ~to_pid:me
                        ()
                    in
                    (match res with Ok () -> () | Error _ -> ());
                    Ok ())
                in
                let _ = runner_pid in
                true
          )
      in
      Trail.stream ctx (fun client_stream ->
        let finished = ref false in
        let released = ref false in
        let release_slot () =
          if not !released then (
            released := true;
            let _ =
              Portal_signals.update state.signals !current ~fn:Portal_signals.release_in_flight
            in
            ()
          )
        in
        let finish_ok () =
          let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed !t0) in
          let _ =
            Portal_signals.update state.signals !current ~fn:(fun s ->
              Portal_signals.record_success s ~latency_ms ~tokens:(String.length !sent / 4) (Portal_signals.now_ms ()))
          in
          released := true;
          let decision' =
            {
              decision with
              Portal_router.chosen = Some !current;
              Portal_router.attempts =
                List.rev ({ Portal_router.account = !current; model = !current; status = Some 200; error = None; latency_ms; cost_nano = 0 } :: !attempts);
            }
          in
          record_decision state decision';
          broadcast_event
            state
            ~type_:"attempt_finished"
            ~request_id
            ~data:
              (Json.obj
                [
                  ("account", Json.string !current);
                  ("status", Json.int 200);
                  ("latency_ms", Json.int latency_ms);
                ]);
          broadcast_event
            state
            ~type_:"task_done"
            ~request_id
            ~data:
              (Json.obj
                [
                  ("chosen", Json.string !current);
                  ("attempts", Json.int (List.length !attempts));
                  ("ok", Json.bool true);
                ]);
          let _ = write_stream client_stream "data: [DONE]\n\n" in
          send (self ()) (Conductor_done (Ok ()))
        in
        let finish_fail reason =
          let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed !t0) in
          let _ =
            Portal_signals.update state.signals !current ~fn:(fun s ->
              Portal_signals.record_failure s ~error:reason (Portal_signals.now_ms ()))
          in
          released := true;
          attempts :=
            { Portal_router.account = !current; model = !current; status = None; error = Some reason; latency_ms; cost_nano = 0 }
            :: !attempts;
          broadcast_event
            state
            ~type_:"attempt_finished"
            ~request_id
            ~data:
              (Json.obj
                [
                  ("account", Json.string !current);
                  ("error", Json.string reason);
                  ("latency_ms", Json.int latency_ms);
                ]);
          if start_agent () then (
            (* continue streaming from the next agent: reset the finished
               flag and keep the loop running *)
            released := false;
            finished := false;
            true
          ) else (
            let decision' =
              { decision with Portal_router.attempts = List.rev !attempts }
            in
            record_decision state decision';
            broadcast_event
              state
              ~type_:"task_done"
              ~request_id
              ~data:
                (Json.obj
                  [
                    ("chosen", Json.string "none");
                    ("attempts", Json.int (List.length !attempts));
                    ("ok", Json.bool false);
                  ]);
            let _ = write_stream client_stream "data: [DONE]\n\n" in
            send (self ()) (Conductor_done (Ok ()));
            false
          )
        in
        let _ = start_agent () in
        let rec loop () =
          if not !finished then (
            let selector msg =
              match msg with
              | Portal_agent.Agent_line (_, line) -> Select (`Line line)
              | Portal_agent.Agent_done (_, code) -> Select (`Done code)
              | Portal_agent.Agent_timeout _ -> Select `Timeout
              | _ -> Skip
            in
            match receive ~selector ~timeout:(Time.Duration.from_secs 10) () with
            | `Line line -> (
                match
                  Portal_agent.extract_text
                    ~command:(match find_agent config !current with Some a -> a.Portal_agent.command | None -> "")
                    line
                with
                | None -> loop ()
                | Some text ->
                    sent := !sent ^ text;
                    (match
                      write_stream
                        client_stream
                        ("data: " ^ Json.to_string (delta_chunk_json text) ^ "\n\n")
                    with
                    | Error e ->
                        finished := true;
                        release_slot ();
                        send (self ()) (Conductor_done (Error e))
                    | Ok () -> loop ()
                )
              )
            | `Done 0 -> finished := true; finish_ok ()
            | `Done code ->
                finished := true;
                if finish_fail ("agent exited with code " ^ Int.to_string code) then loop ()
            | `Timeout ->
                finished := true;
                if
                  finish_fail
                    ("agent timeout (" ^ Int.to_string (match find_agent config !current with Some a -> a.Portal_agent.timeout_s | None -> 600) ^ "s)")
                then
                  loop ()
            | exception Receive_timeout ->
                (* heartbeat: agent may work silently for minutes (tool
                   runs); the watchdog kills the subprocess at
                   agent.timeout_s so we just keep the stream alive *)
                (match
                  write_stream
                    client_stream
                    "data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"},\"finish_reason\":null}]}\n\n"
                with
                | Error e ->
                    finished := true;
                    release_slot ();
                    send (self ()) (Conductor_done (Error e))
                | Ok () -> loop ()
                )
          )
        in
        loop ();
        (* client disconnected or stream ended without a finish event:
           release the in-flight slot (not the agent's fault) *)
        release_slot ();
        Ok ())
    ) else
      let rec try_agents acc = function
        | [] ->
            let decision' = { decision with Portal_router.attempts = List.rev acc } in
            record_decision state decision';
            Trail.json
              ~status:Net.Http.Status.BadGateway
              ctx
              (Json.obj
                [
                  ("error", Json.string "all_agents_failed");
                  ("decision", Portal_router.decision_json decision');
                ])
        | nm :: rest -> (
            match find_agent config nm with
            | None ->
                try_agents
                  ({ Portal_router.account = nm; model = nm; status = None; error = Some "unknown_agent"; latency_ms = 0; cost_nano = 0 } :: acc)
                  rest
            | Some agent ->
                let model_for =
                  match model with
                  | Some m -> m
                  | None -> List.head agent.Portal_agent.models |> Option.unwrap_or ~default:""
                in
                let _ =
                  Portal_signals.update state.signals nm ~fn:Portal_signals.mark_in_flight
                in
                let t0 = Time.Instant.now () in
                let result = blocking_agent_call ~agent ~model:model_for ~prompt:prompt0 in
                let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed t0) in
                (
                  match result with
                  | Ok text ->
                      let _ =
                        Portal_signals.update state.signals nm ~fn:(fun s ->
                          Portal_signals.record_success s ~latency_ms ~tokens:(String.length text / 4) (Portal_signals.now_ms ()))
                      in
                      let attempt =
                        { Portal_router.account = nm; model = nm; status = Some 200; error = None; latency_ms; cost_nano = 0 }
                      in
                      let decision' =
                        {
                          decision with
                          Portal_router.chosen = Some nm;
                          Portal_router.attempts = List.rev (attempt :: acc);
                        }
                      in
                      record_decision state decision';
                      Trail.json ctx (agent_result_json ~agent ~text)
                  | Error err ->
                      let _ =
                        Portal_signals.update state.signals nm ~fn:(fun s ->
                          Portal_signals.record_failure s ~error:err (Portal_signals.now_ms ()))
                      in
                      try_agents
                        ({ Portal_router.account = nm; model = nm; status = None; error = Some err; latency_ms; cost_nano = 0 } :: acc)
                        rest
                )
          )
      in
      try_agents [] candidates

(* ---------- shared synchronous chat execution (HTTP + MCP) ---------- *)

type chat_sync_result = {
  cst_status: int;
  cst_body: string;
  cst_decision: Portal_router.decision;
}

let execute_chat_sync = fun (state : state) (config : Portal_config.t) ~(decision : Portal_router.decision) ~(candidates : string list) ~(model : string option) ~(messages : Json.t) ~(max_tokens : int) ~(session : string option) ~(request_id : string) () ->
    let rec try_attempts acc = function
      | [] ->
          let decision' =
            { decision with Portal_router.attempts = List.rev acc }
          in
          record_decision state decision';
          broadcast_event
            state
            ~type_:"task_done"
            ~request_id
            ~data:
              (Json.obj
                [
                  ("chosen", Json.string "none");
                  ("attempts", Json.int (List.length acc));
                  ("ok", Json.bool false);
                ]);
          {
            cst_status = 502;
            cst_body =
              Json.to_string
                (Json.obj
                  [
                    ("error", Json.string "all_upstreams_failed");
                    ("decision", Portal_router.decision_json decision');
                  ]);
            cst_decision = decision';
          }
      | name :: rest -> (
          broadcast_event
            state
            ~type_:"attempt_started"
            ~request_id
            ~data:(Json.obj [ ("account", Json.string name) ]);
          match Portal_config.find_account config name with
          | None ->
              try_attempts
                ({
                   Portal_router.account = name;
                   model = "";
                   status = None;
                   error = Some "unknown_account";
                   latency_ms = 0;
                   cost_nano = 0;
                 }
                :: acc)
                rest
          | Some account ->
              let upstream_model =
                match model with
                | Some m -> m
                | None ->
                    List.head account.Portal_config.models
                    |> Option.unwrap_or ~default:""
              in
              let anthropic = String.equal account.Portal_config.protocol "anthropic" in
              let auth_headers =
                match Portal_config.api_key_of account with
                | Some k ->
                    if anthropic then
                      [
                        ("x-api-key", k);
                        ("anthropic-version", "2023-06-01");
                      ]
                    else
                      [ ("Authorization", "Bearer " ^ k) ]
                | None -> []
              in
              let upstream_body =
                if anthropic then
                  Portal_anthropic.to_request
                    ~thinking:account.Portal_config.thinking
                    ~model:upstream_model
                    ~messages:
                      (messages)
                    ~max_tokens
                    ~stream:false
                else
                  Json.obj
                    [
                      ("model", Json.string upstream_model);
                      ("messages", messages);
                      ("max_tokens", Json.int max_tokens);
                      ("stream", Json.bool false);
                    ]
                  |> Json.to_string
              in
              let (scheme, host, port_opt, path_prefix) =
                parse_base_url account.Portal_config.base_url
              in
              let port = port_opt |> Option.unwrap_or ~default:443 in
              let chat_path = chat_path_of ~protocol:account.Portal_config.protocol path_prefix in
              let headers =
                ("Content-Type", "application/json")
                :: ("Host", host)
                :: ("Connection", "close")
                :: auth_headers
              in
              let _ =
                Portal_signals.update
                  state.signals
                  name
                  ~fn:Portal_signals.mark_in_flight
              in
              let call_result =
                blocking_call
                  ~scheme
                  ~host
                  ~port
                  ~path:chat_path
                  ~headers
                  ~body:upstream_body
              in
              (
                match call_result with
                | Error err ->
                    let _ = apply_failure state config ~account:name ~status:None ~body:"" ~err in
                    try_attempts
                      ({
                         Portal_router.account = name;
                         model = upstream_model;
                         status = None;
                         error = Some err;
                         latency_ms = 0;
                         cost_nano = 0;
                       }
                      :: acc)
                      rest
                | Ok (status, resp_body, latency_ms) ->
                    broadcast_event
                      state
                      ~type_:"attempt_finished"
                      ~request_id
                      ~data:
                        (Json.obj
                          [
                            ("account", Json.string name);
                            ("status", Json.int status);
                            ("latency_ms", Json.int latency_ms);
                          ]);
                    if status = 200 then (
                      let resp_body_conv =
                        if anthropic then
                          Portal_anthropic.from_response resp_body
                          |> Json.to_string
                        else
                          resp_body
                      in
                      let (in_t, out_t, cache_t) = extract_usage resp_body_conv in
                      let cost = cost_of config name upstream_model in_t out_t cache_t in
                      let _ =
                        Portal_signals.update
                          state.signals
                          name
                          ~fn:(fun s ->
                            Portal_signals.record_success
                              s
                              ~latency_ms
                              ~tokens:(in_t + out_t)
                              (Portal_signals.now_ms ()))
                      in
                      Portal_ledger.record
                        state.ledger
                        ~account:name
                        ~model:upstream_model
                        ~in_tokens:in_t
                        ~out_tokens:out_t
                        ~cache_tokens:cache_t
                        ~cost_nano:cost
                        ~latency_ms
                        ~status:"ok"
                        ();
                      let attempt =
                        {
                          Portal_router.account = name;
                          model = upstream_model;
                          status = Some 200;
                          error = None;
                          latency_ms;
                          cost_nano = cost;
                        }
                      in
                      let decision' =
                        {
                          decision with
                          Portal_router.chosen = Some name;
                          Portal_router.attempts = List.rev (attempt :: acc);
                        }
                      in
                      record_decision state decision';
                      (* re-pin the session to the account that actually
                         served the request (fallback may have switched) *)
                      (
                        match session with
                        | Some sid ->
                            Portal_session.pin
                              state.sessions
                              ~session:sid
                              ~account:name
                              ~now_ms:(Portal_signals.now_ms ())
                        | None -> ()
                      );
                      let body_out =
                        match Json.from_string resp_body_conv with
                        | Ok j -> Json.to_string (normalize_openai_response j)
                        | Error _ ->
                            Json.to_string
                              (Json.obj [ ("content", Json.string resp_body_conv) ])
                      in
                      { cst_status = 200; cst_body = body_out; cst_decision = decision' }
                    ) else (
                      let err =
                        "upstream_http_" ^ Int.to_string status
                      in
                      let _ =
                        apply_failure state config ~account:name ~status:(Some status) ~body:resp_body ~err
                      in
                      Portal_ledger.record
                        state.ledger
                        ~account:name
                        ~model:upstream_model
                        ~in_tokens:0
                        ~out_tokens:0
                        ~cache_tokens:0
                        ~cost_nano:0
                        ~latency_ms
                        ~status:err
                        ();
                      try_attempts
                        ({
                           Portal_router.account = name;
                           model = upstream_model;
                           status = Some status;
                           error = None;
                           latency_ms;
                           cost_nano = 0;
                         }
                        :: acc)
                        rest
                    )
              )
        )
    in
    try_attempts [] candidates
let handle_chat = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let body = parse_json_body ctx in
  let stream_requested =
    Json.get_field "stream" body |> Option.and_then ~fn:Json.get_bool
    |> Option.unwrap_or ~default:false
  in
  let model =
    Json.get_field "model" body |> Option.and_then ~fn:Json.get_string
  in
  let max_tokens =
    Json.get_field "max_tokens" body |> Option.and_then ~fn:Json.get_int
    |> Option.unwrap_or ~default:1024
  in
  let est_in = est_input_tokens body in
  let category =
    get_header ctx "x-oasis-category" |> Option.unwrap_or ~default:"general"
  in
  let goal =
    get_header ctx "x-oasis-goal"
    |> Option.unwrap_or ~default:config.Portal_config.policy.Portal_config.goal
    |> Portal_router.goal_of_string
  in
  let goal_str =
    get_header ctx "x-oasis-goal"
    |> Option.unwrap_or ~default:config.Portal_config.policy.Portal_config.goal
  in
  let request_id = new_request_id () in
  audit_log
    state
    ~path:"/v1/chat/completions"
    ~category
    ~goal:goal_str
    ~stream_:stream_requested
    ~request_id
    ~body:(Net.Http.Request.body_string ctx.req |> Option.unwrap_or ~default:"")
    ();
  broadcast_event
    state
    ~type_:"task_started"
    ~request_id
    ~data:
      (Json.obj
        [
          ("category", Json.string category);
          ("goal", Json.string goal_str);
          (
            "stream",
            Json.bool (Json.get_field "stream" body |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false)
          );
        ]);
  let task =
    {
      Portal_router.category;
      model;
      est_in_tokens = est_in;
      est_out_tokens = max_tokens;
    }
  in
  let mode =
    match get_header ctx "x-oasis-mode" with
    | Some "agent" -> `Agent
    | Some "chat" -> `Chat
    | _ ->
        if
          List.any
            config.Portal_config.policy.Portal_config.agent_categories
            ~fn:(String.equal category)
        then
          `Agent
        else
          `Chat
  in
  let use_agent =
    (match mode with `Agent -> true | `Chat -> false)
    && not (List.is_empty config.Portal_config.agents)
  in
  if use_agent then
    handle_chat_agent state ctx body ~category ~stream_requested ~request_id
  else
  let decision =
    Portal_router.route_scored
      config
      (make_lookups state)
      ~goal
      task
  in
  (* sticky session: if the session is pinned to an account that still
     passes the hard constraints, prefer it (multi-turn context stays on
     one account) *)
  let session =
    get_header ctx "x-oasis-session"
  in
  let (decision, candidates) =
    match session with
    | None -> (decision, decision.Portal_router.chosen)
    | Some sid -> (
        match
          Portal_session.lookup
            state.sessions
            ~session:sid
            ~now_ms:(Portal_signals.now_ms ())
            ~ttl_ms:(config.Portal_config.policy.Portal_config.session_ttl_s * 1000)
        with
        | Some pinned
          when List.any
               ((match decision.Portal_router.chosen with
                 | Some c -> [ c ]
                 | None -> [])
               @ decision.Portal_router.fallback_order)
               ~fn:(String.equal pinned) ->
            let rest =
              List.filter
                ((match decision.Portal_router.chosen with
                  | Some c -> [ c ]
                  | None -> [])
                @ decision.Portal_router.fallback_order)
                ~fn:(fun a -> not (String.equal a pinned))
            in
            ({ decision with Portal_router.chosen = Some pinned; Portal_router.fallback_order = rest }, Some pinned)
        | _ -> (decision, decision.Portal_router.chosen)
      )
  in
  let candidates =
    match candidates with
    | Some c -> c :: decision.Portal_router.fallback_order
    | None -> []
  in
  (* pin at dispatch (updated again on successful handoff) *)
  (
    match (session, List.head candidates) with
    | (Some sid, Some acct) ->
        Portal_session.pin
          state.sessions
          ~session:sid
          ~account:acct
          ~now_ms:(Portal_signals.now_ms ())
    | _ -> ()
  );
  if List.is_empty candidates then (
    record_decision state decision;
    Trail.json
      ~status:Net.Http.Status.PaymentRequired
      ctx
      (Json.obj
        [
          ("error", Json.string "no_account_available");
          ("decision", Portal_router.decision_json decision);
        ])
  ) else if stream_requested then
    Trail.stream ctx (fun client_stream ->
      let cc =
        {
          c_state = state;
          client_stream;
          config;
          task;
          decision;
          messages =
            Json.get_field "messages" body
            |> Option.unwrap_or ~default:(Json.array []);
          max_tokens;
          session;
          request_id;
          handoff_allowed = handoff_applicable body;
        }
      in
      let _ =
        spawn
          (run_conductor cc ~candidates ~parent:(self ()))
      in
      let selector msg =
        match msg with
        | Conductor_done r -> Select r
        | _ -> Skip
      in
      try
        receive
          ~selector
          ~timeout:(Time.Duration.from_secs 300)
          ()
      with
      | Receive_timeout ->
          Error "stream total timeout (300s)")
  else
    let r =
      execute_chat_sync
        state
        config
        ~decision
        ~candidates
        ~model
        ~messages:(Json.get_field "messages" body |> Option.unwrap_or ~default:(Json.array []))
        ~max_tokens
        ~session
        ~request_id
        ()
    in
    match Json.from_string r.cst_body with
    | Ok j ->
        Trail.json ~status:(Net.Http.Status.from_int r.cst_status) ctx j
    | Error _ ->
        Trail.json
          ~status:(Net.Http.Status.from_int r.cst_status)
          ctx
          (Json.obj [ ("content", Json.string r.cst_body) ])

(* ---------- admin handlers ---------- *)

let handle_list_models = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let models =
    List.map
      config.Portal_config.kb
      ~fn:(fun m ->
        Json.obj
          [
            ("name", Json.string m.Portal_kb.name);
            ("tier", Json.int m.Portal_kb.tier);
            ("context_window", Json.int m.Portal_kb.context_window);
            ("max_output", Json.int m.Portal_kb.max_output);
            ("latency", Json.string (Portal_kb.latency_to_string m.Portal_kb.latency));
            (
              "strengths",
              Json.array (List.map m.Portal_kb.strengths ~fn:Json.string)
            );
            (
              "weaknesses",
              Json.array (List.map m.Portal_kb.weaknesses ~fn:Json.string)
            );
          ])
  in
  Trail.json ctx (Json.obj [ ("object", Json.string "list"); ("data", Json.array models) ])

let handle_list_accounts = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let accounts =
    List.map
      config.Portal_config.accounts
      ~fn:(fun a ->
        let spent = Portal_ledger.month_spent state.ledger a.Portal_config.name in
        let budget = a.Portal_config.monthly_budget_nano in
        let s = Portal_signals.get state.signals a.Portal_config.name in
        let breaker_str =
          match s.Portal_signals.breaker with
          | Portal_signals.Closed -> "closed"
          | Portal_signals.Half_open -> "half_open"
          | Portal_signals.Open_until _ -> "open"
        in
        Json.obj
          [
            ("name", Json.string a.Portal_config.name);
            ("provider", Json.string a.Portal_config.provider);
            ("base_url", Json.string a.Portal_config.base_url);
            (
              "models",
              Json.array (List.map a.Portal_config.models ~fn:Json.string)
            );
            ("enabled", Json.bool a.Portal_config.enabled);
            ("day_requests", Json.int (Portal_ledger.day_requests state.ledger a.Portal_config.name));
            ("daily_limit", Json.int a.Portal_config.daily_limit);
            ("month_spent_usd", Json.string (Portal_ledger.format_usd spent));
            (
              "month_budget_usd",
              if budget > 0 then
                Json.string (Portal_ledger.format_usd budget)
              else
                Json.string "unlimited"
            );
            ("latency_ema_ms", Json.int s.Portal_signals.latency_ema_ms);
            ("in_flight", Json.int s.Portal_signals.in_flight);
            ("breaker", Json.string breaker_str);
            ("requests_in_window", Json.int s.Portal_signals.requests_in_window);
            (
              "parked_until_ms",
              if Portal_signals.is_parked s (Portal_signals.now_ms ()) then Json.int s.Portal_signals.parked_until_ms
              else Json.null
            );
            ("auth_invalid", Json.bool s.Portal_signals.auth_invalid);
            ("supports_prefill", Json.bool a.Portal_config.supports_prefill);
            (
              "last_error",
              match s.Portal_signals.last_error with Some e -> Json.string e | None -> Json.null
            );
          ])
  in
  Trail.json
    ctx
    (Json.obj
      [
        ("accounts", Json.array accounts);
        ("cost_routing_effective", Json.bool (Portal_router.cost_routing_effective config));
      ])

let handle_list_decisions = fun (state : state) (ctx : Trail.ctx) ->
  let ds = recent_decisions state in
  Trail.json
    ctx
    (Json.obj
      [ ("decisions", Json.array (List.map ds ~fn:Portal_router.decision_json)) ])

let handle_list_ledger = fun (state : state) (ctx : Trail.ctx) ->
  let entries = Portal_ledger.recent state.ledger ~len:100 in
  Trail.json
    ctx
    (Json.obj
      [
        (
          "entries",
          Json.array
            (List.map
              entries
              ~fn:(fun u ->
                Json.obj
                  [
                    ("seq", Json.int u.Portal_ledger.seq);
                    ("account", Json.string u.Portal_ledger.account);
                    ("model", Json.string u.Portal_ledger.model);
                    ("in_tokens", Json.int u.Portal_ledger.in_tokens);
                    ("out_tokens", Json.int u.Portal_ledger.out_tokens);
                    ("cost_usd", Json.string (Portal_ledger.format_usd u.Portal_ledger.cost_nano));
                    ("latency_ms", Json.int u.Portal_ledger.latency_ms);
                    ("status", Json.string u.Portal_ledger.status);
                  ]))
        )
      ])

let discover_home = fun (state : state) ->
  let config = Sync.Atomic.get state.config in
  let from_agents =
    List.filter_map config.Portal_config.agents ~fn:(fun a ->
      if String.is_empty a.Portal_agent.home then None else Some a.Portal_agent.home)
    |> List.head
  in
  match from_agents with
  | Some h -> h
  | None -> (
      match Env.var Env.String ~name:"REAL_HOME" with
      | Some h -> h
      | None -> "/Users/vajra"
    )

let handle_list_agents = fun (state : state) (ctx : Trail.ctx) ->
  let home = discover_home state in
  let statuses = Portal_discover.scan ~home in
  Trail.json
    ctx
    (Json.obj
      [ ("agents", Json.array (List.map statuses ~fn:Portal_discover.status_json)) ])

let mcp_get_str = fun (params : Json.t) key ->
  Json.get_field key params |> Option.and_then ~fn:Json.get_string
let mcp_get_int = fun (params : Json.t) key ->
  Json.get_field key params |> Option.and_then ~fn:Json.get_int
let mcp_extract_text = fun (body : string) ->
  match Json.from_string body with
  | Error _ -> body
  | Ok j -> (
      let content =
        Json.get_field "choices" j
        |> Option.and_then ~fn:Json.get_array
        |> Option.and_then ~fn:List.head
        |> Option.and_then ~fn:(fun ch -> Json.get_field "message" ch)
        |> Option.and_then ~fn:(fun m -> Json.get_field "content" m)
        |> Option.and_then ~fn:Json.get_string
      in
      match content with
      | Some t when not (String.is_empty t) -> t
      | _ -> (
          match Json.get_field "error" j |> Option.and_then ~fn:Json.get_string with
          | Some e -> "error: " ^ e
          | None -> body
        )
    )
let mcp_tool_agents = fun (state : state) ->
  let home = discover_home state in
  let statuses = Portal_discover.scan ~home in
  let lines =
    List.map statuses ~fn:(fun s ->
      let activity =
        match s.Portal_discover.last_activity_s with
        | None -> "no activity"
        | Some t ->
            "last " ^ Int.to_string (int_of_float ((Time.SystemTime.now () |> Time.SystemTime.secs_float) -. t)) ^ "s ago"
      in
      let projects =
        if List.is_empty s.Portal_discover.projects then ""
        else " projects=[" ^ String.concat ", " s.Portal_discover.projects ^ "]"
      in
      s.Portal_discover.name
      ^ ": installed=" ^ (if s.Portal_discover.installed then "yes" else "no")
      ^ " logged_in=" ^ (if s.Portal_discover.logged_in then "yes" else "no")
      ^ " active=" ^ (if s.Portal_discover.active then "yes" else "no")
      ^ " " ^ activity ^ projects)
  in
  Ok (String.concat "\n" lines)

let portal_task_summaries = fun (state : state) ->
  (* agent tasks the portal itself dispatched (not in claude's local session
     files): surface them in the activity timeline too *)
  recent_decisions state
  |> List.take ~len:50
  |> List.filter ~fn:(fun d ->
    (not (List.is_empty d.Portal_router.attempts))
    && (match List.head d.Portal_router.attempts with
        | Some a -> Option.is_some a.Portal_router.status
        | None -> false))
  |> List.filter_map ~fn:(fun d ->
    match d.Portal_router.attempts with
    | attempt :: _ -> (
        match attempt.Portal_router.status with
        | Some 200 when not (String.is_empty attempt.Portal_router.model) ->
            Some
              {
                Portal_activity.project = "portal-agent-task";
                session_id = "portal-" ^ Int.to_string attempt.Portal_router.latency_ms;
                last_ts = 0.0;
                turns = 1;
                tools = 0;
                last_excerpt =
                  "agent " ^ attempt.Portal_router.account ^ " 完成任务 ("
                  ^ Int.to_string attempt.Portal_router.latency_ms ^ "ms)";
              }
        | _ -> None
      )
    | _ -> None
  )

let handle_list_activity = fun (state : state) (ctx : Trail.ctx) ->
  let home = discover_home state in
  let limit = 20 in
  let query = None in
  let summaries =
    Portal_activity.scan ~home ~limit @ portal_task_summaries state
  in
  let summaries =
    match query with
    | None -> summaries
    | Some q ->
        List.filter summaries ~fn:(fun s ->
          String.contains s.Portal_activity.last_excerpt q
          || String.contains s.Portal_activity.project q)
  in
  Trail.json
    ctx
    (Json.obj
      [ ("sessions", Json.array (List.map summaries ~fn:Portal_activity.summary_json)) ])
let mcp_tool_models = fun (state : state) ->
  let config = Sync.Atomic.get state.config in
  let model_lines =
    List.map config.Portal_config.kb ~fn:(fun m ->
      "model " ^ m.Portal_kb.name
      ^ ": tier=" ^ Int.to_string m.Portal_kb.tier
      ^ " ctx=" ^ Int.to_string m.Portal_kb.context_window
      ^ " out=" ^ Int.to_string m.Portal_kb.max_output
      ^ " latency="
      ^ (match m.Portal_kb.latency with
        | Portal_kb.Fast -> "fast"
        | Portal_kb.Medium -> "medium"
        | Portal_kb.Slow -> "slow")
      ^ " strengths=[" ^ String.concat "," m.Portal_kb.strengths ^ "]")
  in
  let agent_lines =
    List.map config.Portal_config.agents ~fn:(fun a ->
      "agent " ^ a.Portal_agent.name
      ^ ": tier=" ^ Int.to_string a.Portal_agent.tier
      ^ " capabilities=[" ^ String.concat "," a.Portal_agent.capabilities ^ "]"
      ^ " strengths=[" ^ String.concat "," a.Portal_agent.strengths ^ "]"
      ^ " timeout=" ^ Int.to_string a.Portal_agent.timeout_s ^ "s")
  in
  Ok (String.concat "\n" (model_lines @ agent_lines))
let mcp_tool_activity = fun (state : state) (params : Json.t) ->
  let home = discover_home state in
  let limit = mcp_get_int params "limit" |> Option.unwrap_or ~default:10 in
  let query = mcp_get_str params "query" in
  let summaries =
    Portal_activity.scan ~home ~limit:(max 1 limit) @ portal_task_summaries state
  in
  let summaries =
    match query with
    | None -> summaries
    | Some q ->
        List.filter summaries ~fn:(fun s ->
          String.contains s.Portal_activity.last_excerpt q
          || String.contains s.Portal_activity.project q)
  in
  if List.is_empty summaries then
    Ok "no recent agent activity found"
  else
    Ok
      (List.map summaries ~fn:(fun s ->
        "[" ^ s.Portal_activity.project ^ "] turns=" ^ Int.to_string s.Portal_activity.turns
        ^ " tools=" ^ Int.to_string s.Portal_activity.tools
        ^ "\n   最新: " ^ s.Portal_activity.last_excerpt)
      |> String.concat "\n")
let mcp_tool_ask = fun (state : state) (params : Json.t) ->
  match mcp_get_str params "prompt" with
  | None -> Error "missing required parameter: prompt"
  | Some prompt ->
      let config = Sync.Atomic.get state.config in
      let category =
        mcp_get_str params "category" |> Option.unwrap_or ~default:"general"
      in
      let goal =
        mcp_get_str params "goal"
        |> Option.unwrap_or ~default:config.Portal_config.policy.Portal_config.goal
      in
      let model = mcp_get_str params "model" in
      let max_tokens =
        mcp_get_int params "max_tokens" |> Option.unwrap_or ~default:2048
      in
      let task =
        { Portal_router.model; category; est_in_tokens = 0; est_out_tokens = max_tokens }
      in
      let decision =
        Portal_router.route_scored
          config
          (make_lookups state)
          ~goal:(Portal_router.goal_of_string goal)
          task
      in
      let candidates =
        match decision.Portal_router.chosen with
        | None -> []
        | Some c -> c :: decision.Portal_router.fallback_order
      in
      if List.is_empty candidates then (
        record_decision state decision;
        let rejs : Portal_router.rejected list = decision.Portal_router.rejected in
        Error
          ("no_account_available: "
          ^ (List.map rejs ~fn:(fun r -> r.Portal_router.account ^ "(" ^ r.Portal_router.reason ^ ")")
            |> String.concat ", "))
      ) else
        let messages =
          Json.array
            [
              Json.obj
                [ ("role", Json.string "user"); ("content", Json.string prompt) ]
            ]
        in
        let r =
          execute_chat_sync
            state
            config
            ~decision
            ~candidates
            ~model
            ~messages
            ~max_tokens
            ~session:None
            ~request_id:(new_request_id ())
            ()
        in
        let chosen =
          r.cst_decision.Portal_router.chosen |> Option.unwrap_or ~default:"?"
        in
        Ok
          (mcp_extract_text r.cst_body
          ^ "\n\n[routed via " ^ chosen ^ "]")
let mcp_tool_agent = fun (state : state) (params : Json.t) ->
  match mcp_get_str params "prompt" with
  | None -> Error "missing required parameter: prompt"
  | Some prompt ->
      let config = Sync.Atomic.get state.config in
      let category =
        mcp_get_str params "category" |> Option.unwrap_or ~default:"coding"
      in
      let mode = mcp_get_str params "mode" |> Option.unwrap_or ~default:"async" in
      let timeout_override = mcp_get_int params "timeout_s" in
      let requested_workdir = mcp_get_str params "workdir" in
      let with_overrides (agent : Portal_agent.agent) =
        match Portal_agent.resolve_workdir agent requested_workdir with
        | Error e -> Error e
        | Ok workdir ->
            let agent = { agent with Portal_agent.workdir } in
            Ok
              (match timeout_override with
               | Some t -> { agent with Portal_agent.timeout_s = t }
               | None -> agent)
      in
      let decision = route_agents state config category None in
      let forced = mcp_get_str params "agent" in
      let candidates =
        match forced with
        | Some a -> (
            match decision.Portal_router.chosen with
            | None -> [ a ]
            | Some c ->
                let rest =
                  List.filter (c :: decision.Portal_router.fallback_order)
                    ~fn:(fun n -> not (String.equal n a))
                in
                a :: rest
          )
        | None -> (
            match decision.Portal_router.chosen with
            | None -> []
            | Some c -> c :: decision.Portal_router.fallback_order
          )
      in
      if List.is_empty candidates then
        Error "no_agent_available"
      else
        let rec run_sync acc = function
          | [] ->
              let decision' =
                { decision with Portal_router.attempts = List.rev acc }
              in
              record_decision state decision';
              Error
                ("all_agents_failed: "
                ^ (List.rev acc
                  |> List.map ~fn:(fun a ->
                    a.Portal_router.account ^ ": "
                    ^ (a.Portal_router.error |> Option.unwrap_or ~default:"?"))
                  |> String.concat "; "))
          | nm :: rest -> (
              match find_agent config nm with
              | None ->
                  run_sync
                    ({
                       Portal_router.account = nm;
                       model = nm;
                       status = None;
                       error = Some "unknown_agent";
                       latency_ms = 0;
                       cost_nano = 0;
                     }
                    :: acc)
                    rest
              | Some agent0 -> (
                  match with_overrides agent0 with
                  | Error e ->
                      run_sync
                        ({
                           Portal_router.account = nm;
                           model = nm;
                           status = None;
                           error = Some e;
                           latency_ms = 0;
                           cost_nano = 0;
                         }
                        :: acc)
                        rest
                  | Ok agent ->
                  let model_for =
                    List.head agent.Portal_agent.models
                    |> Option.unwrap_or ~default:""
                  in
                  let _ =
                    Portal_signals.update state.signals nm ~fn:Portal_signals.mark_in_flight
                  in
                  let t0 = Time.Instant.now () in
                  let result = blocking_agent_call ~agent ~model:model_for ~prompt in
                  let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed t0) in
                  (
                    match result with
                    | Ok text ->
                        let _ =
                          Portal_signals.update state.signals nm ~fn:(fun s ->
                            Portal_signals.record_success
                              s
                              ~latency_ms
                              ~tokens:(String.length text / 4)
                              (Portal_signals.now_ms ()))
                        in
                        let attempt =
                          {
                            Portal_router.account = nm;
                            model = nm;
                            status = Some 200;
                            error = None;
                            latency_ms;
                            cost_nano = 0;
                          }
                        in
                        let decision' =
                          {
                            decision with
                            Portal_router.chosen = Some nm;
                            Portal_router.attempts = List.rev (attempt :: acc);
                          }
                        in
                        record_decision state decision';
                        Ok (text ^ "\n\n[agent: " ^ nm ^ "]")
                    | Error err ->
                        let _ =
                          Portal_signals.update state.signals nm ~fn:(fun s ->
                            Portal_signals.record_failure s ~error:err (Portal_signals.now_ms ()))
                        in
                        run_sync
                          ({
                             Portal_router.account = nm;
                             model = nm;
                             status = None;
                             error = Some err;
                             latency_ms;
                             cost_nano = 0;
                           }
                          :: acc)
                          rest
                  )
                )
            )
        in
        if String.equal mode "sync" then
          run_sync [] candidates
        else
          (* async: start the first candidate in the background and return a task_id *)
          let nm = List.head candidates |> Option.unwrap_or ~default:"" in
          (
            match find_agent config nm with
            | None -> Error "no_agent_available"
            | Some agent0 ->
                match with_overrides agent0 with
                | Error e -> Error e
                | Ok agent ->
                let task_id = Portal_task.new_id () in
                let _ = Portal_task.insert state.tasks ~task_id in
                let model_for =
                  List.head agent.Portal_agent.models
                  |> Option.unwrap_or ~default:""
                in
                let _ =
                  Portal_signals.update state.signals nm ~fn:Portal_signals.mark_in_flight
                in
                let _ =
                  Runtime.spawn_blocked (fun () ->
                    let t0 = Time.Instant.now () in
                    let result = Portal_agent.collect ~agent ~model:model_for ~prompt () in
                    let latency_ms = Time.Duration.to_millis (Time.Instant.elapsed t0) in
                    (
                      match result with
                      | Ok text ->
                          let _ =
                            Portal_signals.update state.signals nm ~fn:(fun s ->
                              Portal_signals.record_success
                                s
                                ~latency_ms
                                ~tokens:(String.length text / 4)
                                (Portal_signals.now_ms ()))
                          in
                          let attempt =
                            {
                              Portal_router.account = nm;
                              model = nm;
                              status = Some 200;
                              error = None;
                              latency_ms;
                              cost_nano = 0;
                            }
                          in
                          let decision' =
                            {
                              decision with
                              Portal_router.chosen = Some nm;
                              Portal_router.attempts = [ attempt ];
                            }
                          in
                          record_decision state decision';
                          Portal_task.set state.tasks ~task_id ~status:(Portal_task.Done (text ^ "\n\n[agent: " ^ nm ^ "]"))
                      | Error err ->
                          let _ =
                            Portal_signals.update state.signals nm ~fn:(fun s ->
                              Portal_signals.record_failure s ~error:err (Portal_signals.now_ms ()))
                          in
                          let attempt =
                            {
                              Portal_router.account = nm;
                              model = nm;
                              status = None;
                              error = Some err;
                              latency_ms;
                              cost_nano = 0;
                            }
                          in
                          let decision' =
                            { decision with Portal_router.attempts = [ attempt ] }
                          in
                          record_decision state decision';
                          Portal_task.set state.tasks ~task_id ~status:(Portal_task.Failed err)
                    );
                    Ok ())
                in
                Ok
                  ("task started: " ^ task_id
                  ^ " (agent: " ^ nm ^ "). Poll oasis_task_status with this task_id for the result.")
          )
let mcp_tool_task_status = fun (state : state) (params : Json.t) ->
  match mcp_get_str params "task_id" with
  | None -> Error "missing required parameter: task_id"
  | Some task_id -> (
      match Portal_task.get state.tasks ~task_id with
      | None -> Error ("unknown task_id: " ^ task_id)
      | Some (Portal_task.Running) ->
          Ok ("running (agent still working); poll again in a few seconds")
      | Some (Portal_task.Done text) -> Ok text
      | Some (Portal_task.Failed err) -> Ok ("failed: " ^ err)
    )
let mcp_tool_send_message = fun (state : state) (params : Json.t) ->
  match (mcp_get_str params "to", mcp_get_str params "text") with
  | (None, _) -> Error "missing required parameter: to"
  | (_, None) -> Error "missing required parameter: text"
  | (Some to_agent, Some text) ->
      let from =
        mcp_get_str params "from" |> Option.unwrap_or ~default:"mcp-client"
      in
      match Portal_inbox.deliver state.inbox ~from ~to_agent ~text with
      | Error e -> Error e
      | Ok id ->
          Ok
            ("delivered to " ^ to_agent ^ " (message id: " ^ id
            ^ "). The recipient reads it with oasis_check_inbox.")
let mcp_tool_check_inbox = fun (state : state) (params : Json.t) ->
  match mcp_get_str params "agent" with
  | None -> Error "missing required parameter: agent"
  | Some agent ->
      let msgs = Portal_inbox.check state.inbox ~agent in
      if List.is_empty msgs then
        Ok ("no unread messages for " ^ agent)
      else
        Ok
          (List.map msgs ~fn:Portal_inbox.render_for_agent |> String.concat "\n---\n")
let mcp_tool_ask_user = fun (state : state) (params : Json.t) ->
  match (mcp_get_str params "from_agent", mcp_get_str params "question") with
  | (None, _) -> Error "missing required parameter: from_agent"
  | (_, None) -> Error "missing required parameter: question"
  | (Some from_agent, Some question) ->
      (* answer channel: the user replies via /api/inbox/reply which delivers
         back to the asking agent's inbox *)
      match Portal_inbox.deliver state.inbox ~from:from_agent ~to_agent:"user" ~text:question with
      | Error e -> Error e
      | Ok _ ->
      Ok
        ("question delivered to the user (asked by " ^ from_agent
        ^ "). The answer will arrive in your inbox: check oasis_check_inbox with agent=" ^ from_agent ^ ".")
let mcp_tool_status = fun (state : state) ->
  let config = Sync.Atomic.get state.config in
  let lines =
    List.map config.Portal_config.accounts ~fn:(fun a ->
      let s = Portal_signals.get state.signals a.Portal_config.name in
      let breaker =
        match s.Portal_signals.breaker with
        | Portal_signals.Open_until _ -> "open"
        | Portal_signals.Half_open -> "half_open"
        | Portal_signals.Closed -> "closed"
      in
      let day =
        Portal_ledger.day_requests state.ledger a.Portal_config.name
      in
      a.Portal_config.name
      ^ ": breaker=" ^ breaker
      ^ " lat_ema=" ^ Int.to_string s.Portal_signals.latency_ema_ms ^ "ms"
      ^ " in_flight=" ^ Int.to_string s.Portal_signals.in_flight
      ^ " day=" ^ Int.to_string day ^ "/"
      ^ Int.to_string a.Portal_config.daily_limit
    )
  in
  Ok (String.concat "\n" lines)
let mcp_tool_decisions = fun (state : state) (params : Json.t) ->
  let limit = mcp_get_int params "limit" |> Option.unwrap_or ~default:10 in
  let ds = recent_decisions state |> List.take ~len:limit in
  Ok
    (ds
    |> List.map ~fn:(fun d ->
      Portal_router.decision_json d |> Json.to_string)
    |> String.concat "\n")


let handle_reload = fun (state : state) (ctx : Trail.ctx) ->
  match state.config_path with
  | None ->
      Trail.json
        ~status:Net.Http.Status.BadRequest
        ctx
        (Json.obj [ ("error", Json.string "no config path (in-memory config)") ])
  | Some p -> (
      match Portal_config.load p with
      | Error e ->
          Trail.json
            ~status:Net.Http.Status.BadRequest
            ctx
            (Json.obj [ ("error", Json.string e) ])
      | Ok config ->
          let _ = Sync.Atomic.set state.config config in
          Trail.json
            ctx
            (Json.obj
              [
                ("status", Json.string "reloaded");
                ("accounts", Json.int (List.length config.Portal_config.accounts));
              ])
    )

let handle_list_inbox = fun (state : state) (ctx : Trail.ctx) ->
  let config = Sync.Atomic.get state.config in
  let agent_names =
    List.map config.Portal_config.agents ~fn:(fun a -> a.Portal_agent.name)
    @ [ "user" ]
  in
  Trail.json
    ctx
    (Json.obj
      [
        (
          "inboxes",
          Json.array
            (List.map agent_names ~fn:(fun name ->
              Json.obj
                [
                  ("agent", Json.string name);
                  ("unread", Json.int (Portal_inbox.pending_count state.inbox ~agent:name));
                ]))
        );
      ])

let handle_inbox_reply = fun (state : state) (ctx : Trail.ctx) ->
  let body = parse_json_body ctx in
  match
    ( Json.get_field "to_agent" body |> Option.and_then ~fn:Json.get_string,
      Json.get_field "text" body |> Option.and_then ~fn:Json.get_string )
  with
  | (Some to_agent, Some text) ->
      (
        match Portal_inbox.deliver state.inbox ~from:"user" ~to_agent ~text with
        | Ok id -> Trail.json ctx (Json.obj [ ("delivered", Json.string id) ])
        | Error e -> Trail.json ~status:Net.Http.Status.BadRequest ctx (Json.obj [ ("error", Json.string e) ])
      )
  | _ ->
      Trail.json
        ~status:Net.Http.Status.BadRequest
        ctx
        (Json.obj [ ("error", Json.string "to_agent and text required") ])

let index_html =
  {|<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8" />
<title>Oasis — 个人 AI 账户门户</title>
<style>
:root{--bg:#0b1020;--card:#141c33;--border:#263354;--accent:#38bdf8;--green:#22c55e;--red:#ef4444;--amber:#f59e0b;--text:#e2e8f0}
*{box-sizing:border-box;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,monospace}
body{margin:0;padding:20px;background:var(--bg);color:var(--text)}
h1{margin:0 0 4px 0;font-size:20px;color:var(--accent)}
.sub{color:#94a3b8;font-size:12px;margin-bottom:16px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:14px;margin-bottom:14px}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:14px}
.card h2{margin:0 0 10px 0;font-size:14px;color:#cbd5e1;border-bottom:1px solid var(--border);padding-bottom:8px}
.badge{padding:2px 7px;border-radius:4px;font-size:11px;font-weight:600}
.ok{background:rgba(34,197,94,.18);color:var(--green)}
.warn{background:rgba(245,158,11,.2);color:var(--amber)}
.bad{background:rgba(239,68,68,.2);color:var(--red)}
table{width:100%;border-collapse:collapse;font-size:12px}
th,td{text-align:left;padding:6px 5px;border-bottom:1px solid #1e293b;vertical-align:top}
th{color:#94a3b8}
.row{display:flex;gap:8px;margin-bottom:8px;align-items:center;flex-wrap:wrap}
input,select,button{background:#0f172a;border:1px solid var(--border);color:var(--text);padding:6px 8px;border-radius:5px;font-size:12px}
button{background:#1e293b;border-color:var(--accent);cursor:pointer}
button:hover{background:var(--accent);color:#0b1020;font-weight:600}
button.danger{border-color:var(--red);color:#fca5a5}
button.danger:hover{background:var(--red);color:#fff}
pre{background:#070b16;padding:8px;border-radius:6px;font-size:12px;margin:6px 0 0 0;overflow-x:auto;white-space:pre-wrap;min-height:30px}
#log{height:240px;overflow-y:auto;background:#070b16;border:1px solid var(--border);border-radius:6px;padding:10px;font-size:12px;line-height:1.5}
.handoff{color:var(--amber);font-weight:600}

@keyframes node-pop { from { transform: scale(0); opacity: 0; } to { transform: scale(1); opacity: 1; } }
@keyframes node-pulse { 0% { r: 12; } 50% { r: 19; } 100% { r: 12; } }
@keyframes node-fail { 0%,100% { transform: translateX(0); } 25% { transform: translateX(-3px); } 75% { transform: translateX(3px); } }
@keyframes edge-grow { from { stroke-dashoffset: 300; } to { stroke-dashoffset: 0; } }
.gnode { transform-box: fill-box; transform-origin: center; animation: node-pop .35s ease-out both; }
.gnode.soma circle { fill: url(#soma-fill); }
.gnode.soma.cand circle { fill: url(#soma-cand); }
.gnode.soma.glow circle { filter: url(#soma-glow); }
.gnode.soma.ok circle { fill: url(#soma-ok); }
.gnode.soma.fail circle { fill: url(#soma-fail); }
.gnode.pulse circle { animation: node-pulse 1s ease-in-out infinite; }
.gnode.done circle { fill: var(--green); }
.gnode.failed { animation: node-fail .3s ease-in-out 2; }
.gnode.failed circle { fill: var(--red); }
.gedge { stroke-dasharray: 300; animation: edge-grow .5s ease-out both; }
.gedge.fallback { stroke-dasharray: 6 5; stroke: var(--amber); }
.gedge.chosen { stroke: #38bdf8; stroke-width: 2.5; }
.gedge.rejected { stroke: #7f1d1d; stroke-dasharray: 6 5; }
#graph-box { background:#070b16; border:1px solid var(--border); border-radius:8px; overflow-x:auto; min-height:200px; }
#graph-box svg { min-width: 760px; }
</style>
</head>
<body>
<h1>Oasis — 个人 AI 账户门户</h1>
<div class="sub">多账户实时调度 · 可解释路由 · 流式中途配额耗尽无缝切换（Atacama + Nomad + Trail · Riot/OCaml）</div>
<div class="grid">
  <div class="card">
    <h2>账户实时状态 <span id="ws-status" class="badge warn">WS 连接中</span></h2>
    <div id="accounts-box" style="font-size:12px;line-height:1.8;">加载中...</div>
  </div>
  <div class="card">
    <h2>快速提问（走门户调度）</h2>
    <div class="row">
      <input id="prompt" value="用一句话解释无缝切换" style="flex:1" />
    </div>
    <div class="row">
      <select id="category">
        <option value="coding">coding</option>
        <option value="writing">writing</option>
        <option value="analysis">analysis</option>
        <option value="general" selected>general</option>
      </select>
      <select id="goal">
        <option value="balanced" selected>balanced</option>
        <option value="cheapest">cheapest</option>
        <option value="fastest">fastest</option>
        <option value="best">best</option>
      </select>
      <label style="font-size:12px"><input type="checkbox" id="stream" checked /> 流式</label>
      <button onclick="ask()">发送</button>
    </div>
    <pre id="answer">就绪</pre>
  </div>
</div>
<div class="card">
  <h2>实时路由决策（含无缝切换事件）</h2>
  <div id="log"><div>等待决策...</div></div>
</div>


<div class="card" style="margin-bottom:14px">
  <h2>任务过程图（实时）<span id="graph-summary" style="color:#94a3b8;font-weight:400"></span></h2>
  <div id="graph-box"></div>
</div>
<div class="grid">
  <div class="card">
    <h2>本机 Agent 盘点 <button onclick="refreshAgents()" style="float:right">刷新</button></h2>
    <div id="agents-box" style="font-size:12px;line-height:1.9;">加载中...</div>
  </div>
  <div class="card">
    <h2>Agent 活动时间线 <button onclick="refreshActivity()" style="float:right">刷新</button></h2>
    <div id="activity-box" style="font-size:12px;line-height:1.9;max-height:260px;overflow-y:auto;">加载中...</div>
  </div>
  <div class="card">
    <h2>消息总线（收件箱） <button onclick="refreshInbox()" style="float:right">刷新</button></h2>
    <div id="inbox-box" style="font-size:12px;line-height:1.9;">加载中...</div>
    <div class="row" style="margin-top:8px">
      <input id="reply-to" placeholder="回复给 agent (如 claude_code)" style="flex:1" />
      <input id="reply-text" placeholder="回复内容" style="flex:2" />
      <button onclick="sendReply()">回复</button>
    </div>
  </div>
</div>
<script>
const oasisToken = (() => {
  const u = new URL(location.href);
  const t = u.searchParams.get('token');
  if (t) {
    localStorage.setItem('oasis_token', t);
    u.searchParams.delete('token');
    history.replaceState(null, '', u.pathname + u.search + u.hash);
  }
  return localStorage.getItem('oasis_token') || '';
})();
const rawFetch = window.fetch.bind(window);
window.fetch = async (url, opts = {}) => {
  const headers = new Headers(opts.headers || {});
  if (oasisToken) headers.set('Authorization', 'Bearer ' + oasisToken);
  const res = await rawFetch(url, { ...opts, headers });
  if (res.status === 401) {
    const t = prompt('Oasis 需要访问令牌（server.auth_token_env）');
    if (t) { localStorage.setItem('oasis_token', t.trim()); location.reload(); }
  }
  return res;
};
const log = document.getElementById('log');
function addLine(msg, cls) {
  const div = document.createElement('div');
  div.textContent = '[' + new Date().toLocaleTimeString() + '] ' + msg;
  if (cls) div.className = cls;
  log.prepend(div);
  while (log.children.length > 100) log.removeChild(log.lastChild);
}
async function refreshAccounts() {
  const res = await fetch('/api/accounts');
  const data = await res.json();
  const box = document.getElementById('accounts-box');
  box.innerHTML = '';
  for (const a of data.accounts) {
    const brk = a.breaker === 'closed'
      ? '<span class="badge ok">closed</span>'
      : '<span class="badge bad">' + a.breaker + '</span>';
    const line = document.createElement('div');
    line.innerHTML = '<b>' + a.name + '</b> (' + a.provider + ') ' + brk +
      ' | 时延EMA <b>' + a.latency_ema_ms + 'ms</b> | 在途 ' + a.in_flight +
      ' | 今日 ' + a.day_requests + '/' + (a.daily_limit || '∞') +
      ' | 本月 <b>' + a.month_spent_usd + '</b> / ' + a.month_budget_usd +
      ' | 模型: ' + (a.models || []).join(', ');
    box.appendChild(line);
  }
}
async function ask() {
  const out = document.getElementById('answer');
  out.textContent = '';
  gReset({ category: document.getElementById('category').value, goal: document.getElementById('goal').value });
  document.getElementById('graph-summary').textContent = '已发出，等待路由…';
  const body = JSON.stringify({
    model: null,
    messages: [{ role: 'user', content: document.getElementById('prompt').value }],
    max_tokens: 2048,
    stream: document.getElementById('stream').checked
  });
  const headers = {
    'Content-Type': 'application/json',
    'X-Oasis-Category': document.getElementById('category').value,
    'X-Oasis-Goal': document.getElementById('goal').value
  };
  if (document.getElementById('stream').checked) {
    const res = await fetch('/v1/chat/completions', { method: 'POST', headers, body });
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split('\n');
      buf = lines.pop();
      for (const line of lines) {
        if (line.startsWith('data: ')) {
          const payload = line.slice(6);
          if (payload === '[DONE]') { out.textContent += '\n— 完成 —'; continue; }
          try {
            const j = JSON.parse(payload);
            const c = j.choices?.[0]?.delta?.content || '';
            out.textContent += c;
          } catch (e) {}
        }
      }
    }
  } else {
    const res = await fetch('/v1/chat/completions', { method: 'POST', headers, body });
    const j = await res.json();
    out.textContent = j.choices?.[0]?.message?.content || JSON.stringify(j);
  }
  refreshAccounts();
}
async function refreshDecisions() {
  const res = await fetch('/api/decisions');
  const data = await res.json();
  const ds = data.decisions || [];
  log.innerHTML = '<div>等待决策...</div>';
  for (const d of ds.slice(0, 20).reverse()) {
    const attempts = (d.attempts || []).map(a =>
      a.account + '(' + (a.status != null ? a.status : (a.error || '?')) + ':' + a.latency_ms + 'ms)'
    ).join(' → ');
    const handoff = (d.attempts || []).length > 1 ? ' <span class="handoff">[切换]</span>' : '';
    const rejected = (d.rejected || []).map(r => r.account + '✗' + r.reason).join(' ');
    const scores = (d.scores || []).map(s => s.account + ':' + s.score).join(' ');
    addLine(d.task_category + ' → ' + (d.chosen || '无') + handoff +
      ' | attempts: ' + attempts +
      (rejected ? ' | 拒绝: ' + rejected : '') +
      ' | scores: ' + scores);
  }
}
const ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws' + (oasisToken ? '?token=' + encodeURIComponent(oasisToken) : ''));
ws.onopen = () => {
  const st = document.getElementById('ws-status');
  st.textContent = 'WS 已连接';
  st.className = 'badge ok';
};
const NS = 'http://www.w3.org/2000/svg';
const graphBox = document.getElementById('graph-box');
const GW = 900, GH = 400;
let graph = { req: null, candidates: [], attempts: [], svg: null };

function svgEl(tag, attrs, parent) {
  const e = document.createElementNS(NS, tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (parent) parent.appendChild(e);
  return e;
}
function shortName(s, n) { return s.length > n ? s.slice(0, n - 1) + '…' : s; }
function hashJitter(s) { let h = 0; for (const ch of s) h = h * 31 + ch.charCodeAt(0) | 0; return (h % 13 - 6) * 6; }
function gReset(req) {
  graph = { req, candidates: [], attempts: [], svg: null };
  graphBox.innerHTML = '';
  const svg = svgEl('svg', { width: '100%', height: '100%', viewBox: '0 0 ' + GW + ' ' + GH, style: 'min-height:400px' }, graphBox);
  graph.svg = svg;
  const defs = svgEl('defs', {}, svg);
  const glow = svgEl('filter', { id: 'soma-glow', x: '-50%', y: '-50%', width: '200%', height: '200%' }, defs);
  svgEl('feGaussianBlur', { stdDeviation: '3.2', result: 'b' }, glow);
  const mg = svgEl('feMerge', {}, glow);
  svgEl('feMergeNode', { in: 'b' }, mg);
  svgEl('feMergeNode', { in: 'SourceGraphic' }, mg);
  const mk = (id, c1, c2) => {
    const g = svgEl('radialGradient', { id, cx: '35%', cy: '30%' }, defs);
    svgEl('stop', { offset: '0%', 'stop-color': c1 }, g);
    svgEl('stop', { offset: '100%', 'stop-color': c2 }, g);
  };
  mk('soma-fill', '#67e8f9', '#0369a1');
  mk('soma-ok', '#86efac', '#15803d');
  mk('soma-fail', '#fca5a5', '#b91c1c');
  mk('soma-cand', '#cbd5e1', '#475569');
  // task node
  const g = svgEl('g', { class: 'gnode soma glow' }, svg);
  svgEl('circle', { cx: GW / 2, cy: 44, r: 16 }, g);
  svgEl('text', { x: GW / 2, y: 78, 'text-anchor': 'middle', fill: '#e2e8f0', 'font-size': 14 }, g)
    .textContent = '任务 · ' + (req.category || 'general');
  svgEl('text', { x: GW / 2, y: 96, 'text-anchor': 'middle', fill: '#94a3b8', 'font-size': 11 }, g)
    .textContent = 'goal=' + (req.goal || '-');
  graph.root = { name: 'task', x: GW / 2, y: 44 };
}
function gEdge(x1, y1, x2, y2, kind) {
  let d;
  if (kind === 'feedback') {
    const n = Math.min(x1, x2) - 110;
    d = 'M ' + x1 + ' ' + y1 + ' C ' + n + ' ' + y1 + ', ' + n + ' ' + y2 + ', ' + x2 + ' ' + y2;
  } else {
    const j = hashJitter(String(x2) + kind);
    const r = Math.max(28, Math.abs(y2 - y1) * 0.5);
    d = 'M ' + x1 + ' ' + y1 + ' C ' + (x1 + j) + ' ' + (y1 + r) + ', ' + (x2 - j) + ' ' + (y2 - r) + ', ' + x2 + ' ' + y2;
  }
  return svgEl('path', {
    d, fill: 'none', stroke: '#475569', 'stroke-width': 2,
    class: 'gedge' + (kind === 'feedback' ? ' fallback' : '')
  }, graph.svg);
}
function gNode(x, y, label, opts) {
  opts = opts || {};
  const svg = graph.svg;
  const g = svgEl('g', { class: 'gnode soma' + (opts.cls ? ' ' + opts.cls : '') }, svg);
  svgEl('circle', { cx: x, cy: y, r: 14, stroke: 'rgba(148,163,184,.35)', 'stroke-width': 1.5 }, g);
  svgEl('text', { x, y: y + 31, 'text-anchor': 'middle', fill: '#e2e8f0', 'font-size': 12 }, g)
    .textContent = shortName(label, 14);
  if (opts.sub) {
    svgEl('text', { x, y: y + 46, 'text-anchor': 'middle', fill: opts.subColor || '#94a3b8', 'font-size': 10 }, g)
      .textContent = opts.sub;
  }
  if (opts.mark) {
    svgEl('text', { x: x + 16, y: y - 12, 'text-anchor': 'middle', fill: opts.markColor || '#22c55e', 'font-size': 13, 'font-weight': 'bold' }, g)
      .textContent = opts.mark;
  }
  return g;
}
function gEdgeTo(e1, e2, kind) { gEdge(e1.x, e1.y, e2.x, e2.y, kind); }
function onEvent(ev) {
  if (!ev || !ev.data || !graph.svg) return;
  if (ev.event === 'task_started') {
    gReset({ category: ev.data.category, goal: ev.data.goal });
    document.getElementById('graph-summary').textContent = '路由中…';
  } else if (ev.event === 'routed') {
    const cands = (ev.data.candidates || []).slice(0, 6);
    const rejs = (ev.data.rejected || []).slice(0, 3);
    const total = cands.length + rejs.length;
    const y = 165;
    const xOf = i => 60 + (i + 0.5) * ((GW - 120) / Math.max(total, 1));
    cands.forEach((cd, i) => {
      const x = xOf(i);
      const chosen = cd.name === ev.data.chosen;
      const nd = gNode(x, y, cd.name, {
        cls: chosen ? 'glow' : 'cand',
        sub: 'score=' + cd.score
      });
      gEdgeTo(graph.root, { x, y }, 'cand');
      graph.candidates.push({ name: cd.name, g: nd, x, y });
    });
    rejs.forEach((r, j) => {
      const x = xOf(cands.length + j);
      gNode(x, y, r.name, { cls: 'fail', sub: r.reason, subColor: '#ef4444', mark: '✗', markColor: '#ef4444' });
      gEdgeTo(graph.root, { x, y }, 'rej');
    });
    if (ev.data.chosen) document.getElementById('graph-summary').textContent = '→ 选中 ' + ev.data.chosen;
  } else if (ev.event === 'attempt_started') {
    const i = graph.attempts.length;
    const y = 300;
    const x = 120 + i * 165;
    const nd = gNode(x, y, ev.data.account, { cls: 'glow', sub: '执行中…' });
    nd.setAttribute('data-account', ev.data.account);
    const from = graph.candidates.find(t => t.name === ev.data.account) || graph.root;
    if (i === 0) gEdgeTo(from, { x, y }, 'dep');
    else {
      const prev = graph.attempts[graph.attempts.length - 1];
      gEdgeTo({ x: prev.x, y: prev.y }, { x, y }, 'feedback');
    }
    graph.attempts.push({ name: ev.data.account, g: nd, x, y });
  } else if (ev.event === 'attempt_finished') {
    const open = graph.attempts.filter(t => t.name === ev.data.account && !t.finished);
    const t = open[open.length - 1];
    if (t) {
      t.finished = true;
      t.g.remove();
      if (ev.data.status === 200) {
        gNode(t.x, t.y, t.name, { cls: 'ok', sub: ev.data.latency_ms + 'ms', subColor: '#22c55e', mark: '✓', markColor: '#22c55e' });
      } else {
        gNode(t.x, t.y, t.name, { cls: 'fail', sub: ev.data.error || ('HTTP ' + ev.data.status), subColor: '#ef4444', mark: '✗', markColor: '#ef4444' });
      }
    }
  } else if (ev.event === 'task_done') {
    const ok = ev.data.ok;
    document.getElementById('graph-summary').textContent = ok
      ? '✓ 完成 — ' + ev.data.chosen + '（' + ev.data.attempts + ' 次尝试）'
      : '✗ 未完成 — 已尝试 ' + ev.data.attempts + ' 次';
  }
}

ws.onmessage = (ev) => {
  try {
    const j = JSON.parse(ev.data);
    if (j.type === 'event') {
      onEvent(j);
    }
    if (j.type === 'decision') {
      const d = j.decision;
      const attempts = (d.attempts || []).map(a =>
        a.account + '(' + (a.status != null ? a.status : (a.error || '?')) + ')'
      ).join(' → ');
      const handoff = (d.attempts || []).length > 1 ? ' [无缝切换]' : '';
      addLine(d.task_category + ' → ' + (d.chosen || '无') + handoff + ' | attempts: ' + attempts, handoff ? 'handoff' : null);
      refreshAccounts();
    }
  } catch (e) {}
};
ws.onclose = () => {
  const st = document.getElementById('ws-status');
  st.textContent = 'WS 断开(轮询兜底)';
  st.className = 'badge warn';
};
async function refreshAgents() {
  const res = await fetch('/api/agents');
  const data = await res.json();
  const box = document.getElementById('agents-box');
  const rows = (data.agents || []).map(a => {
    const i = a.installed ? '<span class="badge ok">已装</span>' : '<span class="badge bad">未装</span>';
    const l = a.logged_in ? '<span class="badge ok">已登录</span>' : '<span class="badge warn">未登录</span>';
    const act = a.active ? '<span class="badge ok">活跃</span>' : '';
    const projs = (a.projects || []).slice(0, 2).join(', ');
    return '<div>' + a.name + ' ' + i + ' ' + l + ' ' + act +
      (projs ? ' <span style="color:#94a3b8">' + projs + '</span>' : '') + '</div>';
  });
  box.innerHTML = rows.join('');
}
async function refreshActivity() {
  const res = await fetch('/api/activity');
  const data = await res.json();
  const box = document.getElementById('activity-box');
  const rows = (data.sessions || []).map(s =>
    '<div style="border-bottom:1px solid #1e293b;padding:4px 0"><div style="color:#cbd5e1">' + s.project +
    ' <span class="badge warn">' + s.turns + ' 轮</span>' +
    (s.tools ? ' <span class="badge ok">' + s.tools + ' 工具</span>' : '') + '</div>' +
    '<div style="color:#94a3b8">' + (s.last_excerpt || '') + '</div></div>'
  );
  box.innerHTML = rows.length ? rows.join('') : '暂无活动记录';
}
async function refreshInbox() {
  const res = await fetch('/api/inbox');
  const data = await res.json();
  const box = document.getElementById('inbox-box');
  const rows = (data.inboxes || []).map(i =>
    '<div>' + i.agent + ': ' + (i.unread > 0
      ? '<span class="badge ok">' + i.unread + ' 未读</span>'
      : '<span class="badge warn">0</span>') + '</div>'
  );
  box.innerHTML = rows.join('');
}
async function sendReply() {
  const to = document.getElementById('reply-to').value.trim();
  const text = document.getElementById('reply-text').value.trim();
  if (!to || !text) { alert('填写回复对象和内容'); return; }
  await fetch('/api/inbox/reply', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ to_agent: to, text })
  });
  document.getElementById('reply-text').value = '';
  refreshInbox();
  addLine('已回复 ' + to);
}
refreshAgents();
refreshActivity();
refreshInbox();
setInterval(refreshInbox, 5000);
setInterval(refreshAgents, 10000);
setInterval(refreshActivity, 10000);
refreshAccounts();
refreshDecisions();
setInterval(refreshAccounts, 3000);
</script>
</body>
</html>|}


(* ---------- MCP (Model Context Protocol) endpoint ---------- *)

let mcp_execute_tool = fun (state : state) (params : Json.t) ->
  match mcp_get_str params "name" with
  | None -> Error "missing tool name"
  | Some name ->
      let arguments =
        Json.get_field "arguments" params
        |> Option.unwrap_or ~default:(Json.obj [])
      in
      if String.equal name "oasis_ask" then
        mcp_tool_ask state arguments
      else if String.equal name "oasis_agent_task" then
        mcp_tool_agent state arguments
      else if String.equal name "oasis_task_status" then
        mcp_tool_task_status state arguments
      else if String.equal name "oasis_send_message" then
        mcp_tool_send_message state arguments
      else if String.equal name "oasis_check_inbox" then
        mcp_tool_check_inbox state arguments
      else if String.equal name "oasis_ask_user" then
        mcp_tool_ask_user state arguments
      else if String.equal name "oasis_status" then
        mcp_tool_status state
      else if String.equal name "oasis_decisions" then
        mcp_tool_decisions state arguments
      else if String.equal name "oasis_models" then
        mcp_tool_models state
      else if String.equal name "oasis_agents" then
        mcp_tool_agents state
      else if String.equal name "oasis_activity" then
        mcp_tool_activity state arguments
      else
        Error ("unknown tool: " ^ name)

let handle_mcp = fun (state : state) (ctx : Trail.ctx) ->
  match Net.Http.Request.body_string ctx.req with
  | None ->
      Trail.json
        ~status:Net.Http.Status.BadRequest
        ctx
        (Json.obj [ ("error", Json.string "empty body") ])
  | Some body -> (
      match Portal_mcp.parse body with
      | Error e ->
          Trail.json
            ~status:Net.Http.Status.BadRequest
            ctx
            (Json.obj [ ("error", Json.string e) ])
      | Ok rpc ->
          if Portal_mcp.is_notification rpc then
            (* notifications: no JSON-RPC response *)
            Trail.json
              ~status:Net.Http.Status.Accepted
              ctx
              (Json.obj [])
          else
            let id =
              match rpc.Portal_mcp.id with
              | Some i -> i
              | None -> Json.int 0
            in
            let wrap result =
              Portal_mcp.result_payload ~id ~result
              |> Json.from_string
              |> Result.unwrap_or ~default:(Json.obj [])
            in
            if String.equal rpc.Portal_mcp.method_ "initialize" then
              let ctx' =
                Trail.put_resp_header
                  ctx
                  ~name:"Mcp-Session-Id"
                  ~value:"oasis-session-1"
              in
              Trail.json ctx' (wrap (Portal_mcp.initialize_result ()))
            else if String.equal rpc.Portal_mcp.method_ "ping" then
              Trail.json ctx (wrap (Json.obj []))
            else if String.equal rpc.Portal_mcp.method_ "tools/list" then
              Trail.json
                ctx
                (wrap (Json.obj [ ("tools", Portal_mcp.tools_list ()) ]))
            else if String.equal rpc.Portal_mcp.method_ "tools/call" then (
              match mcp_execute_tool state rpc.Portal_mcp.params with
              | Ok text ->
                  Trail.json ctx (wrap (Portal_mcp.call_result ~text ~is_error:false))
              | Error err ->
                  Trail.json ctx (wrap (Portal_mcp.call_result ~text:err ~is_error:true))
            ) else
              let payload =
                Portal_mcp.error_payload
                  ~id
                  ~code:(-32601)
                  ~message:("method not found: " ^ rpc.Portal_mcp.method_)
                |> Json.from_string
                |> Result.unwrap_or ~default:(Json.obj [])
              in
              Trail.json ~status:Net.Http.Status.NotImplemented ctx payload
    )

(* ---------- auth (spec §5.1) ---------- *)

let constant_time_equal = fun a b ->
  if String.length a != String.length b then false
  else
    let diff = ref 0 in
    for i = 0 to String.length a - 1 do
      diff := !diff lor (Char.code (String.get_unchecked a ~at:i) lxor Char.code (String.get_unchecked b ~at:i))
    done;
    !diff = 0

let percent_decode = fun s ->
  let n = String.length s in
  let buf = StringBuilder.create ~size:n in
  let hex c =
    match c with
    | '0' .. '9' -> Some (Char.code c - 48)
    | 'a' .. 'f' -> Some (Char.code c - 87)
    | 'A' .. 'F' -> Some (Char.code c - 55)
    | _ -> None
  in
  let escaped i =
    if i + 2 < n then
      match (hex (String.get_unchecked s ~at:(i + 1)), hex (String.get_unchecked s ~at:(i + 2))) with
      | (Some a, Some b) -> Some (Char.from_int_unchecked ((a * 16) + b))
      | _ -> None
    else None
  in
  let rec go i =
    if i < n then
      match String.get_unchecked s ~at:i with
      | '%' -> (
          match escaped i with
          | Some c ->
              StringBuilder.add_char buf c;
              go (i + 3)
          | None ->
              StringBuilder.add_char buf '%';
              go (i + 1)
        )
      | c ->
          StringBuilder.add_char buf c;
          go (i + 1)
  in
  go 0;
  StringBuilder.contents buf

let query_param = fun (ctx : Trail.ctx) name ->
  match Net.Uri.query (Net.Http.Request.uri ctx.req) with
  | None -> None
  | Some q ->
      String.split ~by:"&" q
      |> List.filter_map ~fn:(fun kv ->
        match String.split ~by:"=" kv with
        | k :: rest when String.equal k name -> Some (percent_decode (String.concat "=" rest))
        | _ -> None)
      |> List.head

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
    match Portal_config.auth_token (Sync.Atomic.get state.config) with
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
        if not (Portal_config.is_loopback_host (Net.Addr.ip ctx.peer)) then
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
              if Portal_config.is_loopback_host (host_of_authority authority) then ctx
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
          Trail.get "/" (fun ctx -> Trail.html ctx index_html);
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
          Trail.get "/api/inbox" (handle_list_inbox state);
          Trail.get "/api/agents" (handle_list_agents state);
          Trail.get "/api/activity" (handle_list_activity state);
          Trail.get "/api/requests" (handle_list_requests state);
          Trail.post "/api/inbox/reply" (handle_inbox_reply state);
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
              let _ = Hello_riot.Trail.Ws.send_text stream (Json.to_string welcome) in
              ());
        ];
    ]

let start = fun ~config_path ?(config : Portal_config.t option) ~port () ->
  let config =
    match config with
    | Some c -> Ok c
    | None -> (
        match config_path with
        | None -> Error "no config"
        | Some p -> Portal_config.load p
      )
  in
  match config with
  | Error e -> Error e
  | Ok config
    when (not (Portal_config.is_loopback_host config.Portal_config.server_host))
         && Option.is_none (Portal_config.auth_token config) ->
      Error
        ("server.host = "
        ^ config.Portal_config.server_host
        ^ " is not loopback: set server.auth_token_env to an environment variable holding a token")
  | Ok config ->
      let state =
        {
          config_path;
          config = Sync.Atomic.make config;
          ledger =
            Portal_ledger.init
              ~data_dir:config.Portal_config.data_dir
              ();
          decisions = Agent.start ~fn:(fun () -> []);
          signals = Portal_signals.init ();
          sessions = Portal_session.init ();
          tasks = Portal_task.init ();
          inbox = Portal_inbox.init ~dir:(config.Portal_config.data_dir ^ "/inbox");
          ws_clients = ConcurrentHashMap.with_capacity ~size:64;
        }
      in
      let _ = Portal_inbox.load state.inbox in
      Portal_signals.load_parked state.signals ~path:(parked_file state);
      if
        String.equal config.Portal_config.policy.Portal_config.goal "cheapest"
        && not (Portal_router.cost_routing_effective config)
      then
        eprintln
          "[oasis] WARN: policy.goal = \"cheapest\" but fewer than two [[models]] have prices; cost routing is ineffective";
      let _ =
        Portal_agent_worker.start
          ~agents:config.Portal_config.agents
          ()
      in
      let ws_callbacks : Hello_riot.Nomad.ws_callbacks =
        {
          on_open =
            (fun stream conn_id ->
              let _ = ConcurrentHashMap.insert state.ws_clients ~key:conn_id ~value:stream in
              ());
          on_frame = (fun _stream _conn_id _frame -> Hello_riot.Atacama.Continue);
          on_close =
            (fun conn_id ->
              let _ = ConcurrentHashMap.remove state.ws_clients ~key:conn_id in
              ());
        }
      in
      Hello_riot.Nomad.start_link
        ~name:"oasis_gateway"
        ~host:config.Portal_config.server_host
        ~port
        ~acceptor_count:4
        ~max_connections:256
        ~trail:(build_trail state)
        ~ws_callbacks
        ()
