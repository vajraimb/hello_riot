open Std

module Json = Std.Data.Json

(** Anthropic Messages protocol adapter: converts OpenAI-format requests to
    the Anthropic Messages API and converts responses (streaming and
    non-streaming) back to OpenAI format, so an Anthropic-style upstream can
    sit behind Oasis' OpenAI-compatible front. *)

(* ---------- request conversion ---------- *)

(** [to_request ~model ~messages ~max_tokens ~stream] converts an OpenAI
    messages array (a Json array) into an Anthropic Messages body. System
    messages are hoisted into the top-level [system] field. *)
let to_request = fun ?(thinking = "disabled") ~model ~messages ~max_tokens ~stream ->
  let system_parts = ref [] in
  let anthropic_msgs =
    match Json.get_array messages with
    | None -> []
    | Some msgs ->
        List.filter_map
          msgs
          ~fn:(fun m ->
            let role =
              Json.get_field "role" m |> Option.and_then ~fn:Json.get_string
              |> Option.unwrap_or ~default:""
            in
            let content =
              Json.get_field "content" m |> Option.and_then ~fn:Json.get_string
              |> Option.unwrap_or ~default:""
            in
            if String.equal role "system" then (
              system_parts := content :: !system_parts;
              None
            ) else if String.equal role "assistant" || String.equal role "user" then
              Some
                (Json.obj
                  [
                    ("role", Json.string role);
                    ("content", Json.string content);
                  ])
            else
              None)
  in
  let system_field =
    if List.is_empty !system_parts then
      []
    else
      [
        (
          "system",
          Json.string (List.rev !system_parts |> String.concat "\n\n")
        );
      ]
  in
  let thinking_field =
    if String.equal thinking "disabled" then
      [ ("thinking", Json.obj [ ("type", Json.string "disabled") ]) ]
    else
      []
  in
  Json.obj
    ([
       ("model", Json.string model);
       ("messages", Json.array anthropic_msgs);
       ("max_tokens", Json.int max_tokens);
       ("stream", Json.bool stream);
     ]
    @ system_field
    @ thinking_field)
  |> Json.to_string

(* ---------- non-streaming response conversion ---------- *)

(** [from_response body] converts an Anthropic Messages response body into an
    OpenAI-format chat completion object. Thinking blocks are skipped. *)
let from_response = fun (body : string) ->
  match Json.from_string body with
  | Error _ -> Json.obj [ ("content", Json.string body) ]
  | Ok j ->
      let blocks =
        Json.get_field "content" j |> Option.and_then ~fn:Json.get_array
        |> Option.unwrap_or ~default:[]
      in
      let block_text = fun ofs block ->
        Json.get_field ofs block |> Option.and_then ~fn:Json.get_string
      in
      let text =
        List.filter_map blocks ~fn:(fun block ->
          match Json.get_field "type" block |> Option.and_then ~fn:Json.get_string with
          | Some "text" -> block_text "text" block
          | _ -> None)
        |> String.concat ""
      in
      (* reasoning models (glm-4.6) may spend the whole budget on thinking
         and leave no text blocks — fall back to the thinking content *)
      let text =
        if String.is_empty text then
          List.filter_map blocks ~fn:(fun block ->
            match Json.get_field "type" block |> Option.and_then ~fn:Json.get_string with
            | Some "thinking" -> block_text "thinking" block
            | _ -> None)
          |> String.concat ""
        else
          text
      in
      let model =
        Json.get_field "model" j |> Option.and_then ~fn:Json.get_string
        |> Option.unwrap_or ~default:""
      in
      let (in_t, out_t, cache_t) =
        match Json.get_field "usage" j with
        | None -> (0, 0, 0)
        | Some usage ->
            let in_t =
              Json.get_field "input_tokens" usage |> Option.and_then ~fn:Json.get_int
              |> Option.unwrap_or ~default:0
            in
            let out_t =
              Json.get_field "output_tokens" usage |> Option.and_then ~fn:Json.get_int
              |> Option.unwrap_or ~default:0
            in
            let cache_t =
              Json.get_field "cache_read_input_tokens" usage
              |> Option.and_then ~fn:Json.get_int
              |> Option.unwrap_or ~default:0
            in
            (in_t, out_t, cache_t)
      in
      Json.obj
        [
          ("id", Json.string ("chatcmpl-anthropic-" ^ model));
          ("object", Json.string "chat.completion");
          ("model", Json.string model);
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
                ("prompt_tokens", Json.int in_t);
                ("completion_tokens", Json.int out_t);
                ("cached_tokens", Json.int cache_t);
                ("total_tokens", Json.int (in_t + out_t));
              ]
          );
        ]

(* ---------- streaming event parsing ---------- *)

(** [extract_delta_text data] parses one Anthropic SSE [data:] payload and
    returns the text delta if it is a [content_block_delta] of type
    [text_delta]. *)
let extract_delta_text = fun (data : string) ->
  match Json.from_string data with
  | Error _ -> None
  | Ok j -> (
      match Json.get_field "type" j |> Option.and_then ~fn:Json.get_string with
      | Some "content_block_delta" -> (
          match Json.get_field "delta" j with
          | None -> None
          | Some delta -> (
              match
                Json.get_field "type" delta |> Option.and_then ~fn:Json.get_string
              with
              | Some "text_delta" ->
                  Json.get_field "text" delta |> Option.and_then ~fn:Json.get_string
              | _ -> None
            )
        )
      | _ -> None
    )

(** [is_stream_end data] is true on a [message_stop] event. *)
let is_stream_end = fun (data : string) ->
  match Json.from_string data with
  | Error _ -> false
  | Ok j -> (
      match Json.get_field "type" j |> Option.and_then ~fn:Json.get_string with
      | Some "message_stop" -> true
      | _ -> false
    )
