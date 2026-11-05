open Std

(** Oasis — personal AI gateway (Riot/OCaml).

    Layers:
    - transport: [Client] (outbound HTTP/1.1 plain/TLS), [Chunked], [Sse]
    - handoff: [Handoff] (seamless mid-stream continuation splice)
    - brain: [Kb] (model knowledge base), [Config] (TOML config),
      [Ledger] (cost accounting), [Router] (scheduling + decisions)
    - front: [Gateway] (OpenAI-compatible HTTP server), built from
      Oasis_state / Oasis_ws / Oasis_upstream / Oasis_decisions /
      Oasis_conductor / Oasis_exec_account / Oasis_exec_agent / Oasis_api /
      Oasis_mcp_tools / Oasis_dashboard / Oasis_http
    - test harness: [Mock] (programmable mock OpenAI server) *)

module Chunked = Oasis_chunked
module Client = Oasis_client
module Sse = Oasis_sse
module Handoff = Oasis_handoff
module Mock = Oasis_mock
module Kb = Oasis_kb
module Config = Oasis_config
module Ledger = Oasis_ledger
module Router = Oasis_router
module Signals = Oasis_signals
module Session = Oasis_session
module Anthropic = Oasis_anthropic
module Agent = Oasis_agent
module Steps = Oasis_steps
module Feed = Oasis_feed
module Classify = Oasis_classify
module Upstream = Oasis_upstream
module Quality = Oasis_quality
module Judge = Oasis_judge
module Thread = Oasis_thread
module Workspace = Oasis_workspace
module Committee = Oasis_committee
module Mcp = Oasis_mcp
module Task = Oasis_task
module Inbox = Oasis_inbox
module Discover = Oasis_discover
module Activity = Oasis_activity
module AgentWorker = Oasis_agent_worker
module Conductor = Oasis_conductor
module Http = Oasis_http
module Gateway = Oasis_gateway
