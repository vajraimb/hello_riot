open Std
open Std.Collections

(** Outbound upstream calls (plain/TLS, blocking lanes), request building,
    prefill/handoff applicability and response normalization. *)

module Trail = Hello_riot.Trail
module Json = Std.Data.Json

open Portal_state
open Portal_ws

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

(** [connect_ip] (an account's [connect_ip], "" = resolve [host]) replaces
    DNS for the TCP connect only; TLS SNI and the Host header keep [host]. *)
let connect_upstream = fun ?(connect_ip = "") ~scheme ~host ~port () ->
  let dial_host = if String.is_empty connect_ip then host else connect_ip in
  let addr = Net.Addr.from_host_and_port ~host:dial_host ~port in
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

let upstream_call = fun ?connect_ip ~scheme ~host ~port ~path ~headers ~body () ->
  match connect_upstream ?connect_ip ~scheme ~host ~port () with
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
let blocking_call = fun ?connect_ip ~scheme ~host ~port ~path ~headers ~body () ->
  let reply_to = self () in
  let _ =
    Runtime.spawn_blocked (fun () ->
      let res = upstream_call ?connect_ip ~scheme ~host ~port ~path ~headers ~body () in
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
let stream_upstream = fun ?connect_ip ~leg_id ~scheme ~host ~port ~path ~headers ~body ~to_pid () ->
  match connect_upstream ?connect_ip ~scheme ~host ~port () with
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

(** For a 200 OpenAI-style response with no answer and no tool calls: the
    error code to fail over with. *)
let empty_answer_of = fun (body : string) ->
  match Json.from_string body with
  | Error _ -> None
  | Ok j -> (
      match
        Json.get_field "choices" j
        |> Option.and_then ~fn:Json.get_array
        |> Option.and_then ~fn:List.head
        |> Option.and_then ~fn:(fun c -> Json.get_field "message" c)
      with
      | None -> None
      | Some m ->
          let field k = Json.get_field k m |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:"" in
          let has_tools =
            Json.get_field "tool_calls" m |> Option.and_then ~fn:Json.get_array
            |> Option.map ~fn:(fun l -> not (List.is_empty l)) |> Option.unwrap_or ~default:false
          in
          if has_tools || not (String.is_empty (String.trim (field "content"))) then None
          else if String.is_empty (field "reasoning_content" ^ field "reasoning") then Some "empty_answer"
          else Some "empty_answer_reasoning_exhausted"
    )

(** Thinking text of an OpenAI-style stream event ([reasoning_content], or
    OpenRouter's [reasoning]); never part of the answer. *)
let extract_delta_reasoning = fun (data : string) ->
  match Json.from_string data with
  | Error _ -> ""
  | Ok j -> (
      match
        Json.get_field "choices" j
        |> Option.and_then ~fn:Json.get_array
        |> Option.and_then ~fn:List.head
        |> Option.and_then ~fn:(fun c -> Json.get_field "delta" c)
      with
      | None -> ""
      | Some delta ->
          let field k = Json.get_field k delta |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:"" in
          let r = field "reasoning_content" in
          if String.is_empty r then field "reasoning" else r
    )

(** True for an OpenAI stream event whose first choice has a non-null
    [finish_reason]. Some upstreams (Perplexity) end the stream with such an
    event and close without [data: [DONE]]. *)
let has_finish_reason = fun (data : string) ->
  match Json.from_string data with
  | Error _ -> false
  | Ok j -> (
      match
        Json.get_field "choices" j
        |> Option.and_then ~fn:Json.get_array
        |> Option.and_then ~fn:List.head
      with
      | None -> false
      | Some choice ->
          Json.get_field "finish_reason" choice
          |> Option.and_then ~fn:Json.get_string
          |> Option.is_some
    )

(** True for an OpenAI stream event that carries tool-call deltas or ends a
    tool-call turn; such events are relayed to the client verbatim. *)
let is_tool_call_event = fun (data : string) ->
  match Json.from_string data with
  | Error _ -> false
  | Ok j -> (
      match
        Json.get_field "choices" j
        |> Option.and_then ~fn:Json.get_array
        |> Option.and_then ~fn:List.head
      with
      | None -> false
      | Some choice ->
          let has_tool_delta =
            match Json.get_field "delta" choice with
            | None -> false
            | Some delta -> (
                let present k =
                  match Json.get_field k delta with
                  | None | Some Json.Null -> false
                  | Some _ -> true
                in
                present "tool_calls" || present "function_call"
              )
          in
          let tool_finish =
            match Json.get_field "finish_reason" choice |> Option.and_then ~fn:Json.get_string with
            | Some "tool_calls" | Some "function_call" -> true
            | _ -> false
          in
          has_tool_delta || tool_finish
    )

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

(** OpenAI request fields forwarded verbatim to OpenAI-protocol upstreams.
    [n] is deliberately absent: the conductor relays a single choice. *)
let passthrough_keys = [
  "tools";
  "tool_choice";
  "parallel_tool_calls";
  "functions";
  "function_call";
  "response_format";
  "temperature";
  "top_p";
  "stop";
  "seed";
  "presence_penalty";
  "frequency_penalty";
  "user";
]

let passthrough_fields = fun (body : Json.t) ->
  List.filter_map passthrough_keys ~fn:(fun k ->
    match Json.get_field k body with
    | Some v -> Some (k, v)
    | None -> None)

(** Tools and structured output have no Anthropic translation here, so such
    requests may only be served by OpenAI-protocol accounts. *)
let requires_openai_protocol = fun (body : Json.t) ->
  let has k = Option.is_some (Json.get_field k body) in
  has "tools" || has "tool_choice" || has "functions" || has "function_call" || has "response_format"

(** [max_tokens] is the client's own limit, forwarded only when given:
    output budgets are the caller's business, not the router's. *)
let upstream_body = fun ?(stream_usage = false) ?(extra = []) ~model ~messages ~(max_tokens : int option) ~stream () ->
  Json.obj
    ([ ("model", Json.string model); ("messages", messages) ]
    @ (match max_tokens with Some n -> [ ("max_tokens", Json.int n) ] | None -> [])
    @ [ ("stream", Json.bool stream) ]
    @ extra
    @
    if stream && stream_usage then
      [ ("stream_options", Json.obj [ ("include_usage", Json.bool true) ]) ]
    else
      [])
  |> Json.to_string

(** Anthropic requires max_tokens: without a client limit use the model's
    full output budget from the KB. *)
let anthropic_max_tokens = fun (config : Portal_config.t) ~model (max_tokens : int option) ->
  match max_tokens with
  | Some n -> n
  | None -> (
      match Portal_kb.find config.Portal_config.kb model with
      | Some kbe when kbe.Portal_kb.max_output > 0 -> kbe.Portal_kb.max_output
      | _ -> 32000)

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
