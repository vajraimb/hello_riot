<div align="center">

# Oasis

**One local endpoint for every AI account and coding agent you already pay for.**

Oasis picks the right model or agent for each request, and when an account runs out of quota halfway through an answer, it hands the stream to another one. Your client never notices.

**English** · [简体中文](README.zh-CN.md)

</div>

![Oasis running a coding task with Claude Code: the routing explanation, live tool calls, and the result](docs/images/agent-task.png)

## Why Oasis

You probably have more AI than you can use: a DeepSeek key, a Kimi plan, GLM, OpenRouter credits, Perplexity, a local Ollama, plus Claude Code, Cursor and Gemini CLI on your laptop. Each one is good at different things, priced differently and rate-limited differently. So you choose by hand every time, burn a flagship model on a trivial question, and still hit a quota wall in the middle of a long answer.

Oasis sits in front of all of them and makes that choice for you, per request.

## What you get

- **Set up by clicking, not by editing.** On first start Oasis finds the API keys already in your environment, tests each one against the provider, lists your local Ollama models, and detects which agent CLIs are installed and logged in. A setup page then shows what works, what is out of quota and what was rejected. Tick what you want and save. Missing a provider? Paste its key into the same page.
- **Drop-in OpenAI-compatible API.** Point any client, SDK or chat app at `http://127.0.0.1:9899/v1`, set `model` to `auto`, and keep working. Streaming and non-streaming both work.
- **Routing that explains itself.** Oasis classifies each task (coding, research, writing, analysis, general). It then scores every eligible account on model strengths, price, remaining budget, live latency, health, and the quality it has learned from your past results. You choose the goal: `balanced`, `fastest`, `best` or `cheapest`. Every decision, and every rejected candidate, is shown in the dashboard.
- **Seamless handoff in the middle of a stream.** If an account hits its quota or drops the connection while streaming, Oasis continues on the next account from exactly where the text stopped, with no repeated words. Your client receives one continuous answer. This is the feature Oasis was built around, and the self-test proves it in under a second.
- **Your local agents become workers.** Tasks that need tools, such as writing code, running commands or browsing, go to Claude Code, Cursor Agent, Gemini CLI, Kimi CLI, Grok CLI or opencode on your machine. You watch their thinking, tool calls and output live. Each conversation gets its own working directory, and follow-ups resume the agent's own session, so it remembers what it already did.
- **Committee mode.** Send one question to up to three accounts at once and get a merged answer that shows where they agree and where they differ.
- **A real dashboard** at `http://127.0.0.1:9899/` lists your tasks with their routing explanations, live progress and produced files. You can follow up, stop or delete from there.
- **MCP server** at `POST /mcp`, so other agents can ask models, hand tasks to your local agents, and message each other through Oasis.
- **Small and private.** Oasis is a single binary under 10 MB. Routing takes about 2 µs per request. All state lives in `~/.oasis` on your machine. API keys never go into the config file: they stay in your environment, or in an owner-only `~/.oasis/secrets.env` if you paste them into the setup page, and agents are started without them.

![Committee mode: three accounts answer and one model writes the consensus](docs/images/committee.png)

## How it works

```mermaid
flowchart LR
    C["Your apps<br/>OpenAI SDK · chat clients · scripts"] -->|"/v1/chat/completions"| O
    U["Dashboard"] --> O
    M["Other agents<br/>(MCP)"] --> O
    O{{"Oasis<br/>classify → score → route"}}
    O --> A["API accounts<br/>DeepSeek · Kimi · GLM · OpenRouter<br/>Perplexity · Ollama · any OpenAI-compatible"]
    O --> G["Local agents<br/>Claude Code · Cursor · Gemini CLI<br/>Kimi CLI · Grok CLI · opencode"]
    A -. "quota / failure mid-stream:<br/>continue on the next account" .-> O
```

## Quick start

Paste this to your coding agent (Cursor, Claude Code, Codex, or any agent that can run commands):

> Clone https://github.com/vajraimb/oasis and follow docs/agent-setup.md until the Oasis console is open in my browser. Stop there.

The agent installs the toolchain, builds, starts Oasis, and opens the console. A setup page lists what it found; you tick what you want and press Save. You do not edit a config file, and you do not paste API keys into the chat.

Or do it yourself. You need macOS or Linux and the [Riot](https://github.com/leostera/riot) OCaml toolchain.

```bash
curl -sSL https://get.riot.ml | sh                 # install Riot
git clone https://github.com/vajraimb/oasis.git && cd oasis
riot plan > /dev/null && scripts/patch-riot.sh      # two runtime fixes for Riot 0.0.43
riot build
scripts/oasis.sh --self-test                        # no API keys needed
```

The self-test starts mock upstreams and runs four end-to-end checks: routing, falling back after a `429`, streaming, and a stream that is cut mid-answer and finished by another account with zero duplicated text.

Then start it for real:

```bash
scripts/oasis.sh start                              # first start detects your accounts and agents
open http://127.0.0.1:9899/                         # the setup page opens by itself
```

On the first start Oasis writes `~/.oasis/oasis.toml` from what it finds:

- API keys in your environment for 13 providers: DeepSeek, Kimi, GLM, OpenRouter, Perplexity, Qwen (DashScope), OpenAI, Anthropic, Gemini, xAI, Groq, Mistral and SiliconFlow. The standard names such as `DEEPSEEK_API_KEY` and `OPENROUTER_API_KEY` are found, and so are your own names like `glm_work_key`. Each key is tested live, and for providers with several endpoints (Kimi Coding vs. Moonshot, China vs. international) Oasis keeps the one that works;
- local and cloud models in a running Ollama;
- Claude Code, Cursor Agent, Gemini CLI, Kimi CLI, Grok CLI and opencode, if installed.

The setup page in the dashboard then shows each account's status: works, rate limited, out of quota, invalid key or unreachable. Untick anything you don't want, paste keys for providers you haven't set up yet, choose a routing goal and press **Save & start**. You can reopen it any time from the **Setup** button. It edits your existing config in place: hand-written entries, comments and tuned values stay as they are, and the previous version is kept as `oasis.toml.bak`. The page is in English or Chinese, following your browser.

Prefer a file? Copy [`config/oasis.example.toml`](config/oasis.example.toml) to `~/.oasis/oasis.toml` before the first start, and Oasis won't generate one.

`scripts/oasis.sh` also has `stop`, `restart`, `status` and `logs`. Any other arguments are passed to the `oasis` binary, so `scripts/oasis.sh ask "hello" --stream` and `scripts/oasis.sh models` work too.

## Use it from anything

**curl**

```bash
curl -N http://127.0.0.1:9899/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'X-Oasis-Goal: cheapest' \
  -d '{"model": "auto", "messages": [{"role": "user", "content": "Explain CRDTs in two sentences"}], "stream": true}'
```

**OpenAI SDK (Python)**

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:9899/v1", api_key="unused")
reply = client.chat.completions.create(
    model="auto",  # or a configured model name to pin it
    messages=[{"role": "user", "content": "Write a haiku about failover"}],
    extra_headers={"X-Oasis-Goal": "best"},
)
print(reply.choices[0].message.content)
```

**Hand a real task to a local agent**

```bash
curl -N http://127.0.0.1:9899/v1/chat/completions \
  -H 'Content-Type: application/json' -H 'X-Oasis-Mode: agent' \
  -d '{"model": "auto", "stream": true, "messages": [{"role": "user",
       "content": "Build a CLI that compares tomorrow'\''s forecast from three weather APIs"}]}'
```

The response carries an `X-Oasis-Thread` header. Send it back with your next message, and the same agent continues in the same working directory.

### Request headers

All headers are optional. Without them, Oasis decides from the content.

| Header | Effect |
|---|---|
| `X-Oasis-Mode` | `chat` or `agent` |
| `X-Oasis-Category` | `coding`, `research`, `writing`, `analysis` or `general` |
| `X-Oasis-Goal` | `balanced`, `fastest`, `best` or `cheapest` |
| `X-Oasis-Agent` | run on a specific agent |
| `X-Oasis-Committee` | comma-separated accounts that answer together |
| `X-Oasis-Thread` | continue a conversation |
| `X-Oasis-Timeout` | time limit in seconds; by default the task runs until it finishes or you stop it |

Setting `model` to `auto`, `oasis` or leaving it empty lets Oasis route. A model name from your config pins that model.

## Configuration

Everything lives in `~/.oasis/oasis.toml`. [`config/oasis.example.toml`](config/oasis.example.toml) is a commented starting point covering models, accounts and every supported agent. It declares three kinds of things:

- **models**: what each model is good at, its context window, latency and price;
- **accounts**: an endpoint, the environment variable holding its key, the models it serves, and its rate limits and budget;
- **agents**: a CLI command and the arguments that run it headless.

Routes then say which accounts may serve each category. The setup page writes all of this for you. If you edit the file by hand, `POST /api/reload` or restart.

Runtime files:

```
~/.oasis/                  (override with OASIS_HOME)
├── oasis.toml             config
├── secrets.env            keys pasted into the setup page (mode 0600, loaded at startup)
├── data/                  conversations, routing decisions, cost ledger, learned quality and latency
├── workspaces/<thread>/   one working directory per conversation; agent output lands here
└── logs/oasis.log
```

By default Oasis listens on `127.0.0.1` only. Before exposing it on a network, set `auth_token_env` so that every request needs a Bearer token; Oasis refuses to start on a non-loopback address without one. Agents run with the permissions of your user account, so only give them tasks you would run yourself.

## Status

Oasis is young and runs daily as a single-user, single-machine gateway. Things to know:

- The dashboard and the CLI output are currently in Chinese. The API is language-neutral.
- Running the test suite in parallel occasionally crashes inside the Riot runtime, so run it serially (see below).
- [docs/oasis-spec.md](docs/oasis-spec.md), written in Chinese, documents the scheduling algorithm, the handoff state machine, security boundaries, persistence semantics and known limitations in detail.

Issues and pull requests are welcome.

## License

[MIT](LICENSE). Use it, change it, ship it. The Riot kernel and standard library Oasis builds against are Apache-2.0.

## Development

```bash
riot build
riot test -p oasis -- --concurrency 1   # gateway tests, serially
riot test -p oasis_net
riot bench -p oasis
bash scripts/build-release.sh           # release binary in dist/
```

```
packages/
├── net/       oasis_net: TCP pool (Atacama), HTTP/1.1 + WebSocket (Nomad), middleware and router (Trail)
└── oasis/     the gateway: src/oasis_*.ml, tests/, bench/, examples/ (mock upstream, HTTPS probe)
config/        oasis.example.toml, oasis-demo.toml (keyless demo against local mocks)
scripts/       oasis.sh, build-release.sh, patch-riot.sh
docs/          agent-setup.md is the runbook a coding agent follows to install Oasis and open the console
patches/riot/  Riot kernel/std patches applied by CI and local builds
```
