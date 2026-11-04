open Std
open Std.Collections

module Json = Std.Data.Json

(** Structured agent work steps parsed from each agent CLI's json event
    stream (docs §2.4). Every step is a json object with a [kind]:

    - [thinking]    {text, delta}
    - [text]        {text, delta}          — narration / answer text
    - [tool]        {id, name, input}      — tool call started
    - [tool_result] {id, ok, output}
    - [usage]       {turns, duration_ms, output_tokens, tool_calls}

    [delta = true] marks a token fragment that continues the previous step
    of the same kind. *)

(** Byte-clip that never splits a UTF-8 sequence (WS text frames must be
    valid UTF-8). *)
let clip = fun (s : string) n ->
  if String.length s <= n then s
  else
    let i = ref n in
    while !i > 0 && Char.code (String.get_unchecked s ~at:!i) land 0xC0 = 0x80 do
      i := !i - 1
    done;
    String.sub s ~offset:0 ~len:!i ^ "…"

let str = fun j key -> Json.get_field key j |> Option.and_then ~fn:Json.get_string

let int_field = fun j key -> Json.get_field key j |> Option.and_then ~fn:Json.get_int

let step = fun kind fields -> Json.obj (("kind", Json.string kind) :: fields)

let thinking = fun ?(delta = false) text ->
  step "thinking" [ ("text", Json.string (clip text 4000)); ("delta", Json.bool delta) ]

let narration = fun ?(delta = false) text ->
  step "text" [ ("text", Json.string (clip text 20000)); ("delta", Json.bool delta) ]

let summary_keys =
  [
    "command"; "file_path"; "filePath"; "target_file"; "targetFile"; "path";
    "pattern"; "query"; "url"; "globPattern"; "prompt"; "description";
  ]

(** One-line human summary of a tool input (command, path, pattern…). *)
let input_summary = fun (input : Json.t) ->
  let input =
    match input with
    | Json.String s -> (
        match Json.from_string s with
        | Ok (Json.Object _ as j) -> j
        | _ -> input
      )
    | j -> j
  in
  match input with
  | Json.Null -> ""
  | Json.String s -> clip s 300
  | Json.Object _ -> (
      let picked =
        List.filter_map summary_keys ~fn:(fun k ->
          match Json.get_field k input with
          | Some (Json.String s) when not (String.is_empty (String.trim s)) -> Some s
          | _ -> None)
        |> List.head
      in
      match picked with
      | Some s -> clip s 300
      | None -> clip (Json.to_string input) 300
    )
  | j -> clip (Json.to_string j) 300

let tool = fun ~id ~name ~input ->
  step
    "tool"
    [
      ("id", Json.string id);
      ("name", Json.string name);
      ("input", Json.string (input_summary input));
    ]

let tool_result = fun ~id ~ok ~output ->
  step
    "tool_result"
    [
      ("id", Json.string id);
      ("ok", Json.bool ok);
      ("output", Json.string (clip (String.trim output) 1200));
    ]

let usage = fun ?(turns = 0) ?(duration_ms = 0) ?(output_tokens = 0) ?(tool_calls = 0) () ->
  step
    "usage"
    [
      ("turns", Json.int turns);
      ("duration_ms", Json.int duration_ms);
      ("output_tokens", Json.int output_tokens);
      ("tool_calls", Json.int tool_calls);
    ]

(** Text of a tool-result payload: a string, or an array of text blocks. *)
let content_text = fun (c : Json.t) ->
  match c with
  | Json.String s -> s
  | Json.Array blocks ->
      List.filter_map blocks ~fn:(fun b ->
        match b with
        | Json.String s -> Some s
        | _ -> str b "text")
      |> String.concat "\n"
  | Json.Null -> ""
  | j -> Json.to_string j

let message_blocks = fun j ->
  match Json.get_field "message" j with
  | None -> []
  | Some m -> Json.get_field "content" m |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]

(* ---------- per-agent parsers ---------- *)

let parse_claude = fun j ->
  match str j "type" with
  | Some "assistant" ->
      List.filter_map (message_blocks j) ~fn:(fun b ->
        match str b "type" with
        | Some "thinking" -> (
            match str b "thinking" with
            | Some t when not (String.is_empty (String.trim t)) -> Some (thinking t)
            | _ -> None
          )
        | Some "text" -> str b "text" |> Option.map ~fn:(fun t -> narration t)
        | Some "tool_use" ->
            Some
              (tool
                ~id:(str b "id" |> Option.unwrap_or ~default:"")
                ~name:(str b "name" |> Option.unwrap_or ~default:"tool")
                ~input:(Json.get_field "input" b |> Option.unwrap_or ~default:Json.null))
        | _ -> None)
  | Some "user" ->
      List.filter_map (message_blocks j) ~fn:(fun b ->
        match str b "type" with
        | Some "tool_result" ->
            Some
              (tool_result
                ~id:(str b "tool_use_id" |> Option.unwrap_or ~default:"")
                ~ok:(not (Json.get_field "is_error" b |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false))
                ~output:(Json.get_field "content" b |> Option.map ~fn:content_text |> Option.unwrap_or ~default:""))
        | _ -> None)
  | Some "result" ->
      let out_tokens =
        Json.get_field "usage" j |> Option.and_then ~fn:(fun u -> int_field u "output_tokens")
      in
      [
        usage
          ~turns:(int_field j "num_turns" |> Option.unwrap_or ~default:0)
          ~duration_ms:(int_field j "duration_ms" |> Option.unwrap_or ~default:0)
          ~output_tokens:(out_tokens |> Option.unwrap_or ~default:0)
          ();
      ]
  | _ -> []

(** Cursor tool calls are wrapped as [{"shellToolCall": {args, result}}]. *)
let cursor_tool_body = fun j ->
  match Json.get_field "tool_call" j |> Option.and_then ~fn:Json.get_object with
  | Some ((key, body) :: _) ->
      let name =
        let suffix = "ToolCall" in
        let kl = String.length key and sl = String.length suffix in
        if kl > sl && String.ends_with key ~suffix then String.sub key ~offset:0 ~len:(kl - sl) else key
      in
      Some (name, body)
  | _ -> None

let cursor_result_output = fun (r : Json.t) ->
  let fields = [ "stdout"; "interleavedOutput"; "content"; "output"; "message"; "error"; "stderr" ] in
  match
    List.filter_map fields ~fn:(fun k ->
      match Json.get_field k r with
      | Some (Json.String s) when not (String.is_empty (String.trim s)) -> Some s
      | _ -> None)
    |> List.head
  with
  | Some s -> s
  | None -> Json.to_string r

let parse_cursor = fun j ->
  match str j "type" with
  | Some "thinking" -> (
      match str j "subtype", str j "text" with
      | Some "delta", Some t when not (String.is_empty t) -> [ thinking ~delta:true t ]
      | _ -> []
    )
  | Some "assistant" ->
      List.filter_map (message_blocks j) ~fn:(fun b ->
        match str b "type" with
        | Some "text" -> str b "text" |> Option.map ~fn:(fun t -> narration t)
        | _ -> None)
  | Some "tool_call" -> (
      let id = str j "call_id" |> Option.unwrap_or ~default:"" in
      match str j "subtype", cursor_tool_body j with
      | Some "started", Some (name, body) ->
          [ tool ~id ~name ~input:(Json.get_field "args" body |> Option.unwrap_or ~default:Json.null) ]
      | Some "completed", Some (_, body) -> (
          match Json.get_field "result" body with
          | Some r -> (
              match Json.get_field "success" r with
              | Some s -> [ tool_result ~id ~ok:true ~output:(cursor_result_output s) ]
              | None ->
                  let err =
                    match Json.get_field "error" r, Json.get_field "failure" r with
                    | Some e, _ | None, Some e -> e
                    | None, None -> r
                  in
                  [ tool_result ~id ~ok:false ~output:(cursor_result_output err) ]
            )
          | None -> [ tool_result ~id ~ok:true ~output:"" ]
        )
      | _ -> []
    )
  | Some "result" ->
      let out_tokens =
        Json.get_field "usage" j |> Option.and_then ~fn:(fun u -> int_field u "outputTokens")
      in
      [
        usage
          ~duration_ms:(int_field j "duration_ms" |> Option.unwrap_or ~default:0)
          ~output_tokens:(out_tokens |> Option.unwrap_or ~default:0)
          ();
      ]
  | _ -> []

let parse_gemini = fun j ->
  match str j "type" with
  | Some "message" -> (
      match str j "role", str j "content" with
      | Some "assistant", Some t ->
          let delta = Json.get_field "delta" j |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false in
          [ narration ~delta t ]
      | _ -> []
    )
  | Some "tool_use" ->
      [
        tool
          ~id:(str j "tool_id" |> Option.unwrap_or ~default:"")
          ~name:(str j "tool_name" |> Option.unwrap_or ~default:"tool")
          ~input:(Json.get_field "parameters" j |> Option.unwrap_or ~default:Json.null);
      ]
  | Some "tool_result" ->
      let ok = String.equal (str j "status" |> Option.unwrap_or ~default:"") "success" in
      let output =
        match Json.get_field "output" j with
        | Some o -> content_text o
        | None -> (
            match Json.get_field "error" j with
            | Some e -> str e "message" |> Option.unwrap_or ~default:(Json.to_string e)
            | None -> ""
          )
      in
      [ tool_result ~id:(str j "tool_id" |> Option.unwrap_or ~default:"") ~ok ~output ]
  | Some "result" -> (
      match Json.get_field "stats" j with
      | Some s ->
          [
            usage
              ~duration_ms:(int_field s "duration_ms" |> Option.unwrap_or ~default:0)
              ~output_tokens:(int_field s "output_tokens" |> Option.unwrap_or ~default:0)
              ~tool_calls:(int_field s "tool_calls" |> Option.unwrap_or ~default:0)
              ();
          ]
      | None -> []
    )
  | _ -> []

let parse_kimi = fun j ->
  let blocks = Json.get_field "content" j |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[] in
  match str j "role" with
  | Some "assistant" ->
      let content =
        List.filter_map blocks ~fn:(fun b ->
          match str b "type" with
          | Some "think" -> (
              match str b "think" with
              | Some t when not (String.is_empty (String.trim t)) -> Some (thinking t)
              | _ -> None
            )
          | Some "text" -> str b "text" |> Option.map ~fn:(fun t -> narration t)
          | _ -> None)
      in
      let calls =
        Json.get_field "tool_calls" j |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
        |> List.map ~fn:(fun c ->
          let fn = Json.get_field "function" c |> Option.unwrap_or ~default:Json.null in
          tool
            ~id:(str c "id" |> Option.unwrap_or ~default:"")
            ~name:(str fn "name" |> Option.unwrap_or ~default:"tool")
            ~input:(Json.get_field "arguments" fn |> Option.unwrap_or ~default:Json.null))
      in
      content @ calls
  | Some "tool" ->
      let texts = List.filter_map blocks ~fn:(fun b -> str b "text") in
      let is_system t = String.starts_with t ~prefix:"<system>" in
      let failed =
        List.any texts ~fn:(fun t ->
          is_system t
          && (String.contains (String.lowercase_ascii t) "error"
             || String.contains (String.lowercase_ascii t) "fail"))
      in
      let body = List.filter texts ~fn:(fun t -> not (is_system t)) |> String.concat "\n" in
      [ tool_result ~id:(str j "tool_call_id" |> Option.unwrap_or ~default:"") ~ok:(not failed) ~output:body ]
  | _ -> []

let parse_grok = fun j ->
  match str j "type" with
  | Some "text" -> (
      match str j "data" with
      | Some t when not (String.is_empty t) -> [ narration ~delta:true t ]
      | _ -> []
    )
  | Some ("thinking" | "reasoning") -> (
      match str j "data" with
      | Some t when not (String.is_empty t) -> [ thinking ~delta:true t ]
      | _ -> []
    )
  | Some "tool_call" ->
      [
        tool
          ~id:(str j "toolCallId" |> Option.unwrap_or ~default:"")
          ~name:(match str j "toolName" with Some n -> n | None -> str j "title" |> Option.unwrap_or ~default:"tool")
          ~input:(Json.get_field "rawInput" j |> Option.unwrap_or ~default:Json.null);
      ]
  | Some "tool_call_update" -> (
      match str j "status" with
      | Some (("completed" | "failed") as status) ->
          let raw = Json.get_field "rawOutput" j |> Option.unwrap_or ~default:Json.null in
          let exit_ok = match int_field raw "exit_code" with Some c -> c = 0 | None -> true in
          let output =
            match str raw "output_for_prompt" with
            | Some s -> s
            | None -> (
                match Json.get_field "content" j |> Option.and_then ~fn:Json.get_array with
                | Some blocks ->
                    List.filter_map blocks ~fn:(fun b ->
                      Json.get_field "content" b |> Option.and_then ~fn:(fun c -> str c "text"))
                    |> String.concat "\n"
                | None -> ""
              )
          in
          [
            tool_result
              ~id:(str j "toolCallId" |> Option.unwrap_or ~default:"")
              ~ok:(String.equal status "completed" && exit_ok)
              ~output;
          ]
      | _ -> []
    )
  | Some "end" ->
      let out_tokens =
        Json.get_field "usage" j |> Option.and_then ~fn:(fun u -> int_field u "output_tokens")
      in
      [
        usage
          ~turns:(int_field j "num_turns" |> Option.unwrap_or ~default:0)
          ~output_tokens:(out_tokens |> Option.unwrap_or ~default:0)
          ();
      ]
  | _ -> []

let basename = fun command ->
  match String.split ~by:"/" command |> List.rev |> List.head with
  | Some b -> b
  | None -> command

(** [parse ~command line] = [Some steps] for a json event line of a known
    agent CLI ([[]] for bookkeeping events), [None] for a plain-text line. *)
let parse = fun ~command (line : string) ->
  let parser =
    match basename command with
    | "claude" -> Some parse_claude
    | "cursor-agent" -> Some parse_cursor
    | "gemini" -> Some parse_gemini
    | "kimi" -> Some parse_kimi
    | "grok" -> Some parse_grok
    | _ -> None
  in
  match parser with
  | None -> None
  | Some p ->
      let trimmed = String.trim line in
      if not (String.starts_with trimmed ~prefix:"{") then None
      else (
        match Json.from_string trimmed with
        | Ok (Json.Object _ as j) -> Some (p j)
        | _ -> None
      )

let kind = fun s -> str s "kind" |> Option.unwrap_or ~default:""

let is_delta = fun s -> Json.get_field "delta" s |> Option.and_then ~fn:Json.get_bool |> Option.unwrap_or ~default:false

(** Answer assembly across lines: whole messages and text that resumes after
    a tool call are separated by a blank line; token deltas are glued. *)
type joiner = {
  mutable started: bool;
  mutable broke: bool;
}

let joiner = fun () -> { started = false; broke = false }

let answer_piece = fun (jn : joiner) steps ->
  List.fold_left steps ~init:"" ~fn:(fun acc s ->
    match kind s with
    | "text" ->
        let t = str s "text" |> Option.unwrap_or ~default:"" in
        let whole = not (is_delta s) in
        let sep = if jn.started && (jn.broke || whole) then "\n\n" else "" in
        jn.started <- true;
        jn.broke <- whole;
        acc ^ sep ^ t
    | "tool" | "tool_result" ->
        jn.broke <- true;
        acc
    | _ -> acc)
