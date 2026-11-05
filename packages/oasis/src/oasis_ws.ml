open Std
open Std.Collections

(** Dashboard WebSocket fan-out and raw client-stream writes. *)

module Trail = Oasis_net.Trail
module Json = Std.Data.Json

open Oasis_state

let broadcast_json = fun (state : state) (payload : Json.t) ->
  let text = Json.to_string payload in
  let dead = ref [] in
  ConcurrentHashMap.for_each
    state.ws_clients
    ~fn:(fun conn_id stream ->
      match Oasis_net.Trail.Ws.send_text stream text with
      | Ok () -> ()
      | Error _ -> dead := conn_id :: !dead);
  List.for_each !dead ~fn:(fun conn_id ->
    let _ = ConcurrentHashMap.remove state.ws_clients ~key:conn_id in
    ())

(** Keeps the conversation store in step with the task feed. *)
let track_thread = fun (state : state) ~type_ ~request_id (data : Json.t) ->
  let thread_of_task () =
    match Oasis_feed.find state.feed request_id with
    | Some t when not (String.is_empty t.Oasis_feed.thread) -> Some t
    | _ -> None
  in
  let str k = Json.get_field k data |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:"" in
  let save () = Oasis_thread.save state.threads ~path:(threads_file state) in
  match type_ with
  | "task_started" when not (String.is_empty (str "thread")) ->
      (* the turn exists from the start, so a gateway restart can mark it
         interrupted instead of losing it *)
      Oasis_thread.ensure state.threads ~id:(str "thread") ~title:(str "title");
      Oasis_thread.append_turn state.threads ~id:(str "thread")
        {
          Oasis_thread.request_id;
          prompt = str "prompt";
          answer = "";
          executor = "";
          mode = str "mode";
          status = "running";
          finished_ms = 0;
        };
      save ()
  | "task_done" -> (
      match thread_of_task () with
      | None -> ()
      | Some t ->
          Oasis_thread.append_turn state.threads ~id:t.Oasis_feed.thread
            {
              Oasis_thread.request_id;
              prompt = t.Oasis_feed.prompt;
              answer = t.Oasis_feed.answer;
              executor = t.Oasis_feed.executor;
              mode = t.Oasis_feed.mode;
              status = t.Oasis_feed.status;
              finished_ms = t.Oasis_feed.finished_ms;
            };
          save ())
  | "attempt_started" -> (
      (* who is running it, so a follow-up after an interruption goes back
         to the same agent *)
      match thread_of_task () with
      | Some t ->
          Oasis_thread.update_turn state.threads ~id:t.Oasis_feed.thread ~request_id ~fn:(fun x ->
            { x with Oasis_thread.executor = str "account"; mode = t.Oasis_feed.mode });
          save ()
      | None -> ())
  | "agent_session" -> (
      match thread_of_task () with
      | Some t when not (String.is_empty (str "session")) ->
          Oasis_thread.set_session state.threads ~id:t.Oasis_feed.thread ~agent:(str "agent") ~session:(str "session");
          save ()
      | _ -> ())
  | "workspace" -> (
      match thread_of_task () with
      | Some t when not (String.is_empty (str "id")) ->
          Oasis_thread.set_workspace state.threads ~id:t.Oasis_feed.thread ~workspace:(str "id");
          save ()
      | _ -> ())
  | "committee_started" -> (
      match thread_of_task () with
      | Some t ->
          let members =
            Json.get_field "members" data |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
            |> List.filter_map ~fn:Json.get_string
          in
          Oasis_thread.set_members state.threads ~id:t.Oasis_feed.thread ~members
      | None -> ())
  | _ -> ()

let broadcast_event = fun (state : state) ~(type_ : string) ~(request_id : string) ~(data : Json.t) ->
  Oasis_feed.apply state.feed ~type_ ~request_id data;
  track_thread state ~type_ ~request_id data;
  if String.equal type_ "task_done" then
    Oasis_signals.save_latency state.signals ~path:(data_path state "latency.json");
  broadcast_json
    state
    (Json.obj
      [
        ("type", Json.string "event");
        ("event", Json.string type_);
        ("request_id", Json.string request_id);
        ("data", data);
      ])

let emit_routed = fun ?(pinned = false) ?(continued = false) (state : state) ~(request_id : string) ~(mode : string) (d : Oasis_router.decision) ->
  broadcast_event
    state
    ~type_:"routed"
    ~request_id
    ~data:
      (Json.obj
        [
          ("mode", Json.string mode);
          ("explored", Json.bool d.Oasis_router.explored);
          ("pinned", Json.bool pinned);
          ("continued", Json.bool continued);
          ("chosen", d.Oasis_router.chosen |> Option.map ~fn:Json.string |> Option.unwrap_or ~default:Json.null);
          (
            "candidates",
            Json.array
              (List.map d.Oasis_router.scores ~fn:(fun (nm, sc) ->
                let parts =
                  List.find d.Oasis_router.parts ~fn:(fun (n, _) -> String.equal n nm)
                  |> Option.map ~fn:(fun (_, p) -> [ ("parts", p) ])
                  |> Option.unwrap_or ~default:[]
                in
                Json.obj ([ ("name", Json.string nm); ("score", Json.int sc) ] @ parts)))
          );
          (
            "rejected",
            Json.array
              (List.map d.Oasis_router.rejected ~fn:(fun r ->
                Json.obj [ ("name", Json.string r.Oasis_router.account); ("reason", Json.string r.Oasis_router.reason) ]))
          );
        ])

let emit_attempt_started = fun (state : state) ~(request_id : string) ~(account : string) ->
  broadcast_event state ~type_:"attempt_started" ~request_id ~data:(Json.obj [ ("account", Json.string account) ])

let emit_attempt_finished = fun (state : state) ~(request_id : string) ~(account : string) ~(status : int option) ~(latency_ms : int) ~(error : string option) ->
  broadcast_event
    state
    ~type_:"attempt_finished"
    ~request_id
    ~data:
      (Json.obj
        ([
           ("account", Json.string account);
           ("status", status |> Option.map ~fn:Json.int |> Option.unwrap_or ~default:Json.null);
           ("latency_ms", Json.int latency_ms);
         ]
        @ (match error with
           | Some e -> [ ("error", Json.string e) ]
           | None -> [])))

let emit_task_done = fun ?(cancelled = false) ?(error = "") ?(answer = "") (state : state) ~(request_id : string) ~(chosen : string option) ~(attempts : int) ~(ok : bool) ->
  broadcast_event
    state
    ~type_:"task_done"
    ~request_id
    ~data:
      (Json.obj
        ([
           ("chosen", Json.string (chosen |> Option.unwrap_or ~default:"none"));
           ("attempts", Json.int attempts);
           ("ok", Json.bool ok);
         ]
        @ (if cancelled then [ ("cancelled", Json.bool true) ] else [])
        @ (if String.is_empty error then [] else [ ("error", Json.string (Oasis_signals.redact_secrets error)) ])
        @ if String.is_empty answer then [] else [ ("answer", Json.string (Oasis_steps.clip answer 60000)) ]))

let redact_step = fun (step : Json.t) ->
  match step with
  | Json.Object fields ->
      Json.obj
        (List.map fields ~fn:(fun (k, v) ->
          match v with
          | Json.String s -> (k, Json.string (Oasis_signals.redact_secrets s))
          | _ -> (k, v)))
  | j -> j

let emit_agent_step = fun (state : state) ~(request_id : string) ~(agent : string) (step : Json.t) ->
  broadcast_event
    state
    ~type_:"agent_step"
    ~request_id
    ~data:(Json.obj [ ("agent", Json.string agent); ("step", redact_step step) ])

(** Raw-stdout-line observer that publishes the line's work steps. *)
let agent_step_observer = fun (state : state) ~(request_id : string) ~(agent : string) ~(command : string) ->
  fun (line : string) ->
    match Oasis_steps.parse ~command line with
    | Some steps -> List.for_each steps ~fn:(emit_agent_step state ~request_id ~agent)
    | None -> ()

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
