# Oasis

个人 AI 网关（Riot / OCaml）：把手上的 API 账户（DeepSeek、GLM、Kimi、Perplexity、OpenRouter、Ollama…）
和本机的 coding agent（Claude Code、Cursor、Gemini CLI、Kimi CLI、Grok CLI…）放在一个入口后面。
任务发给 Oasis，它按内容判断类别，结合模型知识库、成本、实时时延与健康度、历史质量评分挑执行者；
失败自动回退，流式中途断了无缝接到下一个账户续写，客户端只看到一条连续、不重复的流。

- **OpenAI 兼容端点** `POST /v1/chat/completions`（流式 / 非流式），第三方客户端直接指向 Oasis 即可
- **Agent 模式**：编程、联网检索等任务交给本机 CLI agent 执行，过程（思考、工具调用、输出）实时可见
- **连续对话**：`X-Oasis-Thread` 续接上一轮；agent 续接自己的 CLI 会话，在同一个工作目录里接着做
- **委员会**：最多三个账户并行作答，由路由器挑一个模型汇总
- **控制台** `http://127.0.0.1:9899/`：任务列表、路由说明、执行过程、产出文件、续接、停止、删除
- **MCP** `POST /mcp`：让别的 agent 通过 Oasis 调模型、派任务、互发消息

## 快速开始

```bash
riot build
scripts/oasis.sh start          # 首次运行生成 ~/.oasis/oasis.toml，编辑后 restart
open http://127.0.0.1:9899/     # 控制台
scripts/oasis.sh logs           # 看日志；stop / restart / status
```

API key 只放环境变量（配置里写 `api_key_env = "DEEPSEEK_API_KEY"`），从导出了这些变量的 shell 启动。
`oasis --example-config` 打印一份带注释的配置示例。

```bash
curl -N http://127.0.0.1:9899/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'X-Oasis-Goal: fastest' \
  -d '{"messages":[{"role":"user","content":"hi"}],"stream":true}'
```

| 请求头 | 作用 |
|---|---|
| `X-Oasis-Mode` | `chat` / `agent`；不给按内容自动判断 |
| `X-Oasis-Category` | 任务类别（coding / research / writing / analysis / general），不给按内容判断 |
| `X-Oasis-Goal` | 调度目标：balanced / fastest / best / cheapest |
| `X-Oasis-Agent` | 指定 agent（自选） |
| `X-Oasis-Committee` | 委员会成员，逗号分隔 |
| `X-Oasis-Thread` | 续接对话（响应头回传本轮所属的对话 id） |
| `X-Oasis-Timeout` | 调用方给的时限（秒）；不给就一直执行到完成或被停止 |

## 目录

```
~/.oasis/                 运行时（OASIS_HOME 可改）
├── oasis.toml            配置
├── data/                 对话、路由决策、账本、质量与时延记录
├── workspaces/<对话 id>/  agent 的工作目录：每个对话一个，产出都在这里
└── logs/oasis.log

packages/
├── net/                  oasis_net：Atacama（TCP 连接池）· Nomad（HTTP/1.1 + WebSocket）· Trail（中间件与路由）
└── oasis/                网关本体
    ├── src/              oasis_*.ml：路由、上游、agent、对话、控制台、MCP…
    ├── bin/main.ml       oasis 可执行文件（服务端 + CLI 客户端）
    ├── examples/         oasis-mock（可编程的假上游）、oasis-probe
    ├── tests/ bench/
config/oasis-demo.toml    无 key 演示配置（账户指向本机 mock）
docs/oasis-spec.md        规格：调度、无缝切换、对话、工作目录、接口、安全边界
scripts/                  oasis.sh（启停）、build-release.sh、patch-riot.sh
patches/riot/             Riot kernel/std 补丁（CI 与本地构建都会打）
```

## 无 key 演示（含流式中途无缝切换）

```bash
oasis-mock --port 9911 --sse "你好，我是" --cut 134
oasis-mock --port 9912 --sse "你好，我是 Oasis——无缝切换演示成功！"
oasis --config config/oasis-demo.toml
oasis ask "你是谁" --stream
```

## 开发

```bash
riot build
riot test -p oasis        # 网关测试（含端到端：路由、回退、无缝切换、agent、对话、工作目录）
riot test -p oasis_net
riot bench -p oasis
oasis --self-test         # 一条命令跑完整链路自检
bash scripts/build-release.sh
```

规格与设计记录见 [docs/oasis-spec.md](docs/oasis-spec.md)。
