open Std

module Json = Std.Data.Json

(** MCP (Model Context Protocol) server layer for Oasis: pure JSON-RPC
    parsing/serialization plus the tool catalog. Tool EXECUTION lives in the
    gateway (it needs live state); this module has no gateway dependency. *)

let protocol_version = "2025-03-26"

type rpc = {
  id: Json.t option;
  method_: string;
  params: Json.t;
}

(** Parse a JSON-RPC 2.0 request. [id] may be a number, string, or absent
    (notification). *)
let parse = fun (body : string) ->
  match Json.from_string body with
  | Error _ -> Error "invalid json"
  | Ok j ->
      let method_ =
        Json.get_field "method" j |> Option.and_then ~fn:Json.get_string
      in
      (
        match method_ with
        | None -> Error "missing method"
        | Some m ->
            let id = Json.get_field "id" j in
            let params =
              Json.get_field "params" j
              |> Option.unwrap_or ~default:(Json.obj [])
            in
            Ok { id; method_ = m; params }
      )

let is_notification = fun (r : rpc) -> Option.is_none r.id

let result_payload = fun ~(id : Json.t) ~(result : Json.t) ->
  Json.to_string
    (Json.obj
      [
        ("jsonrpc", Json.string "2.0");
        ("id", id);
        ("result", result);
      ])

let error_payload = fun ~(id : Json.t) ~code ~message ->
  Json.to_string
    (Json.obj
      [
        ("jsonrpc", Json.string "2.0");
        ("id", id);
        (
          "error",
          Json.obj [ ("code", Json.int code); ("message", Json.string message) ]
        );
      ])

let initialize_result = fun () ->
  Json.obj
    [
      ("protocolVersion", Json.string protocol_version);
      (
        "capabilities",
        Json.obj [ ("tools", Json.obj [ ("listChanged", Json.bool false) ]) ]
      );
      (
        "serverInfo",
        Json.obj
          [
            ("name", Json.string "oasis");
            ("version", Json.string "0.1.0");
          ]
      );
    ]

let tool = fun ~name ~description ~(input_schema : Json.t) ->
  Json.obj
    [
      ("name", Json.string name);
      ("description", Json.string description);
      ("inputSchema", input_schema);
    ]

let str_prop = fun ~required ~description ->
  Json.obj
    [
      ("type", Json.string "string");
      ("description", Json.string description);
    ]

let int_prop = fun ~description ->
  Json.obj
    [
      ("type", Json.string "integer");
      ("description", Json.string description);
    ]

let tools_list = fun () ->
  Json.array
    [
      tool
        ~name:"oasis_ask"
        ~description:
          "Send a chat task to the Oasis portal: it picks the best model/account for your goal and returns the answer."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              (
                "properties",
                Json.obj
                  [
                    ("prompt", str_prop ~required:true ~description:"The task or question.");
                    ("category", str_prop ~required:false ~description:"Task category: general, coding, writing, analysis, long_doc.");
                    ("goal", str_prop ~required:false ~description:"Routing goal: best, balanced, cheapest, fastest.");
                    ("model", str_prop ~required:false ~description:"Force a specific model (optional).");
                    ("max_tokens", int_prop ~description:"Max output tokens; omit to use the model's own default.");
                  ]
              );
              ("required", Json.array [ Json.string "prompt" ]);
            ]);
      tool
        ~name:"oasis_agent_task"
        ~description:
          "Send a task to a local coding agent (Claude Code, opencode, gemini, codex) through the portal's agent pool. Use for tasks that need tools: editing files, running commands, browsing. Returns immediately with a task_id; poll oasis_task_status for the result (agents take minutes)."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              (
                "properties",
                Json.obj
                  [
                    ("prompt", str_prop ~required:true ~description:"The task for the agent.");
                    ("category", str_prop ~required:false ~description:"Task category used for agent fit scoring (default coding).");
                    ("agent", str_prop ~required:false ~description:"Force a specific agent by name (optional).");
                    ("mode", str_prop ~required:false ~description:"async (default, returns task_id immediately) or sync (waits, may exceed client timeouts).");
                    ("timeout_s", int_prop ~description:"Agent timeout in seconds (default from config).");
                    ("workdir", str_prop ~required:false ~description:"Absolute directory to run the agent in; must be inside the agent's allowed_workdirs (default: the agent's configured workdir).");
                  ]
              );
              ("required", Json.array [ Json.string "prompt" ]);
            ]);
      tool
        ~name:"oasis_task_status"
        ~description:
          "Poll the status and result of an async agent task started by oasis_agent_task. Returns running / done (with the agent's final report) / failed (with the error)."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              (
                "properties",
                Json.obj
                  [ ("task_id", str_prop ~required:true ~description:"The task_id returned by oasis_agent_task.") ]
              );
              ("required", Json.array [ Json.string "task_id" ]);
            ]);
      tool
        ~name:"oasis_status"
        ~description:
          "Account status: breaker state, latency EMA, in-flight requests, daily/monthly usage for every AI account."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              ("properties", Json.obj []);
            ]);
      tool
        ~name:"oasis_decisions"
        ~description:
          "Recent routing decisions made by the portal: what was chosen, what failed, and why."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              (
                "properties",
                Json.obj
                  [ ("limit", int_prop ~description:"Number of decisions (default 10).") ]
              );
            ]);
      tool
        ~name:"oasis_send_message"
        ~description:
          "Deliver a message to another agent's inbox (or to the user) through the portal's message bus. The recipient reads it with oasis_check_inbox."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              (
                "properties",
                Json.obj
                  [
                    ("to", str_prop ~required:true ~description:"Recipient: an agent name (e.g. claude_code) or \"user\".");
                    ("text", str_prop ~required:true ~description:"Message content.");
                  ]
              );
              ("required", Json.array [ Json.string "to"; Json.string "text" ]);
            ]);
      tool
        ~name:"oasis_check_inbox"
        ~description:
          "Read unread messages from an agent's inbox on the portal's message bus (messages sent to you via oasis_send_message, or questions from the user)."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              (
                "properties",
                Json.obj
                  [ ("agent", str_prop ~required:true ~description:"The agent name whose inbox to read.") ]
              );
              ("required", Json.array [ Json.string "agent" ]);
            ]);
      tool
        ~name:"oasis_ask_user"
        ~description:
          "Ask the user a question through the portal; the question lands in the user's queue (visible in the dashboard) and the answer comes back via oasis_check_inbox for the asking agent."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              (
                "properties",
                Json.obj
                  [
                    ("from_agent", str_prop ~required:true ~description:"The agent asking (its own name).");
                    ("question", str_prop ~required:true ~description:"The question for the user.");
                  ]
              );
              ("required", Json.array [ Json.string "from_agent"; Json.string "question" ]);
            ]);
      tool
        ~name:"oasis_activity"
        ~description:
          "Recent activity of local agents: which projects they worked on, how many turns/tool calls, and the latest message. Optional query filters by keyword."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              (
                "properties",
                Json.obj
                  [
                    ("limit", int_prop ~description:"Max sessions to return (default 10).");
                    ("query", str_prop ~required:false ~description:"Filter sessions whose project or last message contains this.");
                  ]
              );
            ]);
      tool
        ~name:"oasis_agents"
        ~description:
          "Inventory the local AI agents on this machine: which are installed, logged in, currently active, and what projects they have been working on."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              ("properties", Json.obj []);
            ]);
      tool
        ~name:"oasis_models"
        ~description:
          "List the models and local agents the portal can route to, with tiers and capabilities."
        ~input_schema:
          (Json.obj
            [
              ("type", Json.string "object");
              ("properties", Json.obj []);
            ]);
    ]

(** Build a tools/call result payload from plain text. *)
let call_result = fun ~text ~is_error ->
  Json.obj
    [
      (
        "content",
        Json.array
          [
            Json.obj
              [ ("type", Json.string "text"); ("text", Json.string text) ]
          ]
      );
      ("isError", Json.bool is_error);
    ]
