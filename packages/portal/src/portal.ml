open Std

(** Oasis — personal AI account portal (Riot/OCaml).

    Layers:
    - transport: [Client] (outbound HTTP/1.1 plain/TLS), [Chunked], [Sse]
    - handoff: [Handoff] (seamless mid-stream continuation splice)
    - brain: [Kb] (model knowledge base), [Config] (TOML config),
      [Ledger] (cost accounting), [Router] (scheduling + decisions)
    - front: [Gateway] (OpenAI-compatible HTTP server), built from
      Portal_state / Portal_ws / Portal_upstream / Portal_decisions /
      Portal_conductor / Portal_exec_account / Portal_exec_agent / Portal_api /
      Portal_mcp_tools / Portal_dashboard / Portal_http
    - test harness: [Mock] (programmable mock OpenAI server) *)

module Chunked = Portal_chunked
module Client = Portal_client
module Sse = Portal_sse
module Handoff = Portal_handoff
module Mock = Portal_mock
module Kb = Portal_kb
module Config = Portal_config
module Ledger = Portal_ledger
module Router = Portal_router
module Signals = Portal_signals
module Session = Portal_session
module Anthropic = Portal_anthropic
module Agent = Portal_agent
module Steps = Portal_steps
module Feed = Portal_feed
module Classify = Portal_classify
module Upstream = Portal_upstream
module Quality = Portal_quality
module Judge = Portal_judge
module Thread = Portal_thread
module Committee = Portal_committee
module Mcp = Portal_mcp
module Task = Portal_task
module Inbox = Portal_inbox
module Discover = Portal_discover
module Activity = Portal_activity
module AgentWorker = Portal_agent_worker
module Conductor = Portal_conductor
module Http = Portal_http
module Gateway = Portal_gateway
