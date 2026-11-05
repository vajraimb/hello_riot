open Std
open Std.Collections

module Json = Std.Data.Json

(** Conversations: every request is one turn of a thread. A follow-up names
    its thread (X-Oasis-Thread) and Oasis supplies the earlier turns — as
    chat history for API accounts, as a native CLI session resume for the
    agent that ran before, or as a transcript for any other agent.
    Persisted to [threads.json] (newest [keep] threads). *)

let keep = 300

let max_answer = 20000

type turn = {
  request_id: string;
  prompt: string;
  answer: string;
  executor: string;
  mode: string;
  status: string;
  finished_ms: int;
}

type thread = {
  id: string;
  title: string;
  created_ms: int;
  updated_ms: int;
  turns: turn list;  (** oldest first *)
  sessions: (string * string) list;  (** agent name -> CLI session id *)
  members: string list;  (** committee members of the last committee turn *)
  workspace: string;  (** workspace id once an agent ran here; "" = none yet *)
}

type t = (string, thread) ConcurrentHashMap.t

let create = fun () : t -> ConcurrentHashMap.with_capacity ~size:64

let now_ms = Portal_signals.now_ms

let new_id = fun () ->
  let pick bound = match Random.int bound with Ok v -> v | Error _ -> 0 in
  "th-" ^ Int.to_string (pick 1000000000)

let get = fun (t : t) id -> ConcurrentHashMap.get t ~key:id

let update = fun (t : t) ~id ~fn ->
  ConcurrentHashMap.compute t ~key:id ~fn:(fun cur ->
    match cur with
    | None -> ConcurrentHashMap.Abort ()
    | Some th -> ConcurrentHashMap.Insert ({ (fn th) with updated_ms = now_ms () }, ()))

(** Creates the thread on its first turn; later turns keep the first title. *)
let ensure = fun (t : t) ~id ~title ->
  ConcurrentHashMap.compute t ~key:id ~fn:(fun cur ->
    match cur with
    | Some _ -> ConcurrentHashMap.Abort ()
    | None ->
        let now = now_ms () in
        ConcurrentHashMap.Insert
          ({ id; title; created_ms = now; updated_ms = now; turns = []; sessions = []; members = []; workspace = "" }, ()))

let append_turn = fun (t : t) ~id (turn : turn) ->
  let turn = { turn with answer = Portal_steps.clip turn.answer max_answer } in
  update t ~id ~fn:(fun th ->
    let others = List.filter th.turns ~fn:(fun x -> not (String.equal x.request_id turn.request_id)) in
    { th with turns = others @ [ turn ] })

let set_session = fun (t : t) ~id ~agent ~session ->
  update t ~id ~fn:(fun th ->
    { th with sessions = (agent, session) :: List.filter th.sessions ~fn:(fun (a, _) -> not (String.equal a agent)) })

let set_members = fun (t : t) ~id ~members -> update t ~id ~fn:(fun th -> { th with members })

let set_workspace = fun (t : t) ~id ~workspace -> update t ~id ~fn:(fun th -> { th with workspace })

(** Workspace for the next agent turn. Threads whose agents already ran
    before workspaces existed keep running where their CLI sessions live. *)
let workspace_for = fun (th : thread option) ~id ->
  match th with
  | Some th when String.is_empty th.workspace && not (List.is_empty th.sessions) -> None
  | Some th when not (String.is_empty th.workspace) -> Some th.workspace
  | _ -> Some id

let session_of = fun (th : thread) ~agent ->
  List.find th.sessions ~fn:(fun (a, _) -> String.equal a agent) |> Option.map ~fn:(fun (_, s) -> s)

let last_turn = fun (th : thread) -> List.head (List.rev th.turns)

(** Earlier turns that carry content, newest kept first when [max_chars]
    runs out; returned oldest first. *)
let history = fun ?(max_chars = 60000) (th : thread) ->
  let rec take acc used = function
    | [] -> acc
    | (x : turn) :: rest ->
        let size = String.length x.prompt + String.length x.answer in
        if used + size > max_chars && not (List.is_empty acc) then acc else take (x :: acc) (used + size) rest
  in
  List.rev th.turns
  |> List.filter ~fn:(fun (x : turn) -> not (String.is_empty (String.trim x.prompt)))
  |> take [] 0

(** OpenAI-style messages for the earlier turns. An unfinished turn keeps its
    partial answer, marked, so the model knows where it stopped. *)
let history_messages = fun ?max_chars (th : thread) ->
  history ?max_chars th
  |> List.flat_map ~fn:(fun (x : turn) ->
    let msg role content = Json.obj [ ("role", Json.string role); ("content", Json.string content) ] in
    let answer =
      if String.equal x.status "ok" then x.answer
      else if String.is_empty (String.trim x.answer) then "（上一轮未完成，没有输出）"
      else x.answer ^ "\n\n（上一轮未完成，到此中断）"
    in
    [ msg "user" x.prompt; msg "assistant" answer ])

(* ---------- json ---------- *)

let turn_json = fun (x : turn) ->
  Json.obj
    [
      ("request_id", Json.string x.request_id);
      ("prompt", Json.string x.prompt);
      ("answer", Json.string x.answer);
      ("executor", Json.string x.executor);
      ("mode", Json.string x.mode);
      ("status", Json.string x.status);
      ("finished_ms", Json.int x.finished_ms);
    ]

let to_json = fun (th : thread) ->
  Json.obj
    [
      ("id", Json.string th.id);
      ("title", Json.string th.title);
      ("created_ms", Json.int th.created_ms);
      ("updated_ms", Json.int th.updated_ms);
      ("turns", Json.array (List.map th.turns ~fn:turn_json));
      ("sessions", Json.obj (List.map th.sessions ~fn:(fun (a, s) -> (a, Json.string s))));
      ("members", Json.array (List.map th.members ~fn:Json.string));
      ("workspace", Json.string th.workspace);
    ]

let summary_json = fun (th : thread) ->
  let last = last_turn th in
  Json.obj
    [
      ("id", Json.string th.id);
      ("title", Json.string th.title);
      ("updated_ms", Json.int th.updated_ms);
      ("turns", Json.int (List.length th.turns));
      ("status", Json.string (match last with Some x -> x.status | None -> "running"));
      ("executor", Json.string (match last with Some x -> x.executor | None -> ""));
      ("mode", Json.string (match last with Some x -> x.mode | None -> ""));
      ("last_request_id", Json.string (match last with Some x -> x.request_id | None -> ""));
    ]

let recent = fun (t : t) ~limit ->
  ConcurrentHashMap.values t
  |> List.sort ~compare:(fun a b -> Int.compare b.updated_ms a.updated_ms)
  |> List.take ~len:limit

let s = fun j k -> Json.get_field k j |> Option.and_then ~fn:Json.get_string |> Option.unwrap_or ~default:""

let i = fun j k -> Json.get_field k j |> Option.and_then ~fn:Json.get_int |> Option.unwrap_or ~default:0

let of_json = fun (j : Json.t) ->
  let id = s j "id" in
  if String.is_empty id then None
  else
    Some
      {
        id;
        title = s j "title";
        created_ms = i j "created_ms";
        updated_ms = i j "updated_ms";
        turns =
          Json.get_field "turns" j |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
          |> List.map ~fn:(fun x ->
            {
              request_id = s x "request_id";
              prompt = s x "prompt";
              answer = s x "answer";
              executor = s x "executor";
              mode = s x "mode";
              status = s x "status";
              finished_ms = i x "finished_ms";
            });
        sessions =
          Json.get_field "sessions" j |> Option.and_then ~fn:Json.get_object |> Option.unwrap_or ~default:[]
          |> List.filter_map ~fn:(fun (a, v) -> Json.get_string v |> Option.map ~fn:(fun sid -> (a, sid)));
        members =
          Json.get_field "members" j |> Option.and_then ~fn:Json.get_array |> Option.unwrap_or ~default:[]
          |> List.filter_map ~fn:Json.get_string;
        workspace = s j "workspace";
      }

let save = fun (t : t) ~path ->
  let threads = recent t ~limit:keep in
  if ConcurrentHashMap.length t > keep + 20 then
    List.enumerate (ConcurrentHashMap.values t |> List.sort ~compare:(fun a b -> Int.compare b.updated_ms a.updated_ms))
    |> List.for_each ~fn:(fun (n, th) -> if n >= keep then ignore (ConcurrentHashMap.remove t ~key:th.id));
  match Path.from_string path with
  | Error _ -> ()
  | Ok p ->
      let _ = Fs.write (Json.to_string (Json.array (List.map threads ~fn:to_json))) p in
      ()

let load = fun (t : t) ~path ->
  match Path.from_string path with
  | Error _ -> ()
  | Ok p -> (
      match Fs.read_to_string p with
      | Error _ -> ()
      | Ok content -> (
          match Json.from_string content |> Result.to_option |> Option.and_then ~fn:Json.get_array with
          | None -> ()
          | Some items ->
              List.for_each items ~fn:(fun j ->
                match of_json j with
                | Some th -> ignore (ConcurrentHashMap.insert t ~key:th.id ~value:th)
                | None -> ())
        )
    )
