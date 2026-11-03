# Oasis — AI 账户 + Agent 门户

> 规格与初衷（Spec & Rationale）
> 版本 0.2 · 2026-11-03 · 与代码同源，随 `docs/ai-portal-plan.md` 战报演进

---

## 1. 初衷（为什么做这个）

### 1.1 起点：个人 AI 账户太多，用不过来

一个人同时拥有多个 AI 账户：DeepSeek、Kimi、GLM、OpenRouter、Claude Code、
ZCode…… 每个账户的**模型特点、余额、限额、速度**各不相同，而任务千差万别。
手工选择"这个任务该用哪个账户"既低效又容易出错——**quota 用完时任务中断、
费用花在错误的模型上、简单任务烧掉了旗舰模型**。

Oasis 要解决的四件事：

1. **懂模型**：每个账户/模型有什么强项（知识库 KB + tier + strengths）
2. **懂任务**：任务属于什么类别、要什么目标（最佳质量 / 均衡 / 最省 / 最快）
3. **懂成本**：每个账户的价格与预算（nano-dollar 记账，日/月限额）
4. **会调度**：综合以上 + 实时信号（时延/熔断/并发/余额错误），自动选最合适的账户

**最硬的要求**：任务执行中途 quota 耗尽（或账户故障），必须**实时切换到另一个
模型/账户继续完成，且用户端无感**——"无缝切换"是本项目的招牌能力。

### 1.2 演进：从"账户门户"到"Agent 门户"

纯 API 账户没有工具（不能上网、不能写文件），很多任务天然做不了。而本机
有一批真正的 **agent**（Claude Code、Codex、opencode、gemini CLI……）——
它们有 terminal/files/web 能力。于是 Oasis 扩展为**双门户**：

- 纯对话/推理任务 → API 账户池
- 需要工具的任务（coding 等类别）→ **本地 agent 池**（子进程驱动，带看门狗与回退链）

调度原则：**provider 的主打模型优先；只放实测可用的模型；坏 agent 自动隔离**。

### 1.3 借鉴与差异化

| 项目 | 借鉴了什么 | Oasis 的差异化 |
|---|---|---|
| [AIUsage](https://github.com/sylearn/AIUsage) | 账户管理、CLI 代理、会话聚合、活动盘点 | 它是手动切换；Oasis 是**自动评分调度 + 无缝切换** |
| [Reason Machines](https://effect.grok.me) | MCP 入口、agent inbox（消息总线）、Cortex 风格过程可视化（rank 布局/S 曲线/回退回环/发光节点） | 它是云 agent + P2P 网络；Oasis 是**本地单机调度中枢**，中心化 inbox 更简单 |
| Riot / OCaml 底层 | Actor、监督树、结构化并发 | 微秒级路由（33µs）、单二进制（9.4MB）、崩溃隔离 |

### 1.4 底层选型：为什么 Riot/OCaml

- **Actor 模型**：每个连接/任务/agent 子进程独立 actor，崩溃不传染
- **微秒级调度**：`route_scored` 33µs——评分调度可以**每个请求**都跑，不必缓存
- **流式管道**：SSE 事件流经 Actor 消息天然衔接，无缝切换的"阻塞道 + 导体"模式
  直接对应 Riot 的 `spawn_blocked` + mailbox
- **单二进制**：一个 `oasis` 文件跑完整门户（HTTP/WS/MCP/dashboard）

---

## 2. 架构规格

### 2.1 分层

```
┌─────────────────────────────────────────────────────┐
│  客户端层: OpenAI 兼容 API · MCP 客户端 · Dashboard  │
├─────────────────────────────────────────────────────┤
│  Oasis 网关 (portal_gateway.ml)                      │
│   ├─ HTTP 路由 (Trail)      ├─ MCP 端点 (/mcp)       │
│   ├─ 流式导体 (无缝切换)     ├─ WS 实时事件广播        │
│   ├─ 账户执行路径            ├─ Agent 执行路径        │
├─────────────────────────────────────────────────────┤
│  核心域模块 (22 个 portal_*.ml)                      │
│   Router(评分) Signals(熔断) KB(fit) Ledger(记账)    │
│   Session(粘性) Handoff(去重拼接) Inbox(总线)        │
│   Agent(子进程) Anthropic(协议适配) Task(异步句柄)   │
│   Discover(盘点) Activity(聚合) Mcp(协议层)          │
├─────────────────────────────────────────────────────┤
│  自研底层: Atacama(TCP池) · Nomad(HTTP/WS)           │
│            Trail(管线/路由/SSE) · AegisOTP(监督树)   │
└─────────────────────────────────────────────────────┘
```

### 2.2 核心概念

| 概念 | 定义 |
|---|---|
| **Account** | 一个 API 账户：base_url / api_key_env / models / protocol（openai\|anthropic）/ thinking / rpm / 日限额 / 月预算 |
| **Agent** | 一个本地 agent CLI：command / args 模板（`{prompt}` `{model}`）/ home / workdir / timeout_s / capabilities / tier |
| **Task profile** | 任务画像：category（general/coding/writing/analysis/long_doc）× goal（best/balanced/cheapest/fastest）× model（可选强制） |
| **decision** | 每次调度的完整可解释记录：chosen / fallback_order / rejected（含原因）/ attempts（含状态、时延、错误）/ scores |
| **signals** | 每账户/agent 实时信号：时延 EMA、熔断（错误率窗口 + **连续失败≥5 时间无关**）、in_flight、日请求计数 |
| **handoff** | 无缝切换：新账户以"已发文本"为 assistant 前缀续写，前缀去重后只转发新增文本 |

### 2.3 调度算法（route_scored）

```
分数 = fit(tier × strengths 匹配, 0..100)
     + 成本分（按 goal：cheapest 主导；价格未知为 0）
     + 时延分（100 - EMA/20，fastest 主导）
     - 负载分（in_flight/并发）
候选 = 账户(或 agent)满足硬约束：模型服务 / 熔断未开 / 并发未满 / 预算未超 / 日限额未达
选择 = 分数最高者；其余按分数排序为回退链
```

硬约束之外还有**粘性会话**（X-Oasis-Session 头的多轮对话钉在同一账户）与
**显式模式**（X-Oasis-Mode: agent\|chat 覆盖类别默认规则）。

### 2.4 执行与容错

- **非流式**：按回退链逐个尝试（blocking lane + 超时），全程记账/信号/决策记录
- **流式（账户）**：导体 actor 管理当前 leg；上游断流/错误 → 触发 handoff：
  新账户以"已发送文本"续写，`Portal_handoff` 前缀去重，客户端零重复
- **流式（agent）**：子进程 stdout 逐行 → 文本提取（claude stream-json 解析，
  思考不外泄）→ 客户端 delta；心跳保活（10s 空 chunk）；看门狗 SIGKILL 兜底
- **失败隔离**：HTTP 错误/余额不足（429 1113 等）→ 记入 signals；连续 5 次失败
  时间无关熔断 → 30s 冷却 → 半开探测
- **异步任务**（MCP agent 任务默认）：秒回 task_id → `oasis_task_status` 轮询
  running/done/failed——解决"MCP 客户端超时 < agent 执行时长"的矛盾

### 2.5 对外接口

| 接口 | 说明 |
|---|---|
| `POST /v1/chat/completions` | OpenAI 兼容（流式 SSE / 非流式）；头 `X-Oasis-Category` `X-Oasis-Goal` `X-Oasis-Mode` `X-Oasis-Session` |
| `GET /v1/models` | KB 模型列表 |
| `POST /mcp` | MCP（JSON-RPC 2.0 / Streamable HTTP 简化）11 工具：oasis_ask、oasis_agent_task、oasis_task_status、oasis_status、oasis_decisions、oasis_send_message、oasis_check_inbox、oasis_ask_user、oasis_activity、oasis_agents、oasis_models |
| `GET /api/*` | accounts（状态）、decisions（决策）、ledger（账本）、reload（热重载）、inbox（未读）、agents（盘点）、activity（时间线）、requests（审计） |
| `WS /ws` | 实时推送：decision + 事件流（task_started → routed → attempt_started → attempt_finished → task_done）驱动前端过程图 |
| `GET /` | Dashboard：ask 面板 + 账户状态 + 决策流 + **Cortex 风格过程图** + agent 盘点 + 活动时间线 + 收件箱 |

### 2.6 前端过程图（可视化规格）

- **事件驱动**：五种事件经 WS 驱动 SVG 图，从发问瞬间到任务完成逐步生长
- **布局**：rank 分层（任务→候选→尝试），每层均分宽度（借鉴 effect.grok.me Cortex）
- **边**：S 曲线 + 哈希抖动防重叠；**失败回退 = 向左外绕 110px 的回环虚线**
- **节点**：径向渐变 soma + `feGaussianBlur` 发光（执行中青色脉动；成功绿 ✓；
  失败红 ✗；候选灰蓝；被拒灰红）
- 纯 SVG/CSS，零外部依赖

### 2.7 配置（oasis.toml）

```toml
[server]          # host / port / data_dir
[[models]]        # KB：name/tier/strengths/weaknesses/context/max_output/latency/价格(nano)
[[accounts]]      # 见 2.2；protocol="anthropic" 走适配器；thinking="disabled" 关思考
[[agents]]        # 见 2.2；enabled=false 的 agent 不进候选池
[[routes]]        # category -> 账户链
[policy]          # goal / agent_categories（自动走 agent 池的类别）/ max_fallback
```

密钥只通过环境变量注入（`api_key_env`），**永不落盘到配置**。

---

## 3. 已知限制（诚实清单）

1. **本机 agent CLI 可用性**是环境问题：claude 需登录且 `-p` 需 `--verbose`
   + `--dangerously-skip-permissions`；opencode/gemini 在本机有自身 bug/网络问题
   （已通过 `enabled=false` 隔离，修好即可用）
2. **Riot 0.0.43 运行时限制**（docs §16.20 有完整证据链）：测试 actor 里 spawn
   挂起、跨 actor 共享 map 不可见、Supervisor.Dynamic.start_child 挂起——因此
   agent 执行采用 per-task blocking-lane + 看门狗，OTP 监督树集成留待运行时修复
3. **riot 工具链缓存坑**：lib 改动后 `riot test`/`riot run` 可能跑旧产物，
   **改 lib 后必须 `riot clean --force` 重建**；启动网关用
   `_build/.../out/portal/oasis` 正规产物
4. 价格字段目前大多为 0（各家真实价格待填）——填上后成本调度才精确
5. GLM 账户余额不足（z.ai 429/1113）时由熔断自动隔离；ZCode 的 bigmodel 登录态
   不落盘，无法直接复用（z.ai anthropic 端点是可用路径）

---

## 4. 演进路线（已完成 / 待做）

- [x] M0–M3：四层栈复用、评分调度、无缝切换、可解释决策
- [x] 真实账户接入：DeepSeek / Kimi Work / GLM z.ai（Anthropic 适配）/ OpenRouter
- [x] Agent 门户：本地 agent 池、回退链、异步任务句柄
- [x] MCP 入口（11 工具）+ 消息总线（inbox/ask_user）+ 发现 + 活动聚合
- [x] 事件流 + Cortex 风格过程图
- [ ] 真实价格填充（成本调度闭环）
- [ ] 监督树（待 Riot 运行时修复）
- [ ] 云端 agent 账户（异步任务模型已就绪）
