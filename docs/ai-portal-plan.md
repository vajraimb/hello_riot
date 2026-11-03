# 个人 AI 账户门户 — 规划文档 v0.2

> 代号：**Oasis**（绿洲，延续 Atacama / Nomad / Trail 的荒漠主题）
> 包名 `portal`，二进制 `oasis`，数据目录 `~/.oasis/`
> 技术栈：Riot 0.0.43 + OCaml，复用现有 Atacama / Nomad / Trail / OTP 监督树模式。

---

## 1. 定位与四大支柱

本质是**个人 LLM 网关**，但目标是"懂"而不是"转发"。四大支柱：

1. **模型知识库（Model KB）**：熟悉各 AI 厂商及其模型的特点（强项/弱项/上下文/时延画像/价格/怪癖），出厂自带默认档案，用户可改
2. **任务画像（Task Profiler）**：熟悉用户任务的目标和要求（类别、质量底线、成本上限、时延 SLO、流式与否、交互还是批量）
3. **成本账本（Ledger）**：每个账户的成本与额度，实时、精确、可预算
4. **实时调度 + 无缝切换（Scheduler & Seamless Handoff）**：综合前三者选出最合适的模型；**配额中途耗尽或账户故障时，流不中断地换模型接力**，客户端无感

**非目标（v1 不做）**：多用户 SaaS、计费/售卖、移动端、图像/语音/嵌入端点（架构预留）。

---

## 2. 核心概念模型

```
Provider → Account (一个 API Key)
  ├─ models / pricing / caps (RPM·TPM·日限·月预算) / base_url·proxy
  └─ 实时状态: 健康(时延EMA/错误率/熔断) + 用量 + 在途数 + 令牌桶

ModelKB (静态档案, TOML, 出厂默认 + 用户覆盖)
  { name, tier(1-5), strengths[], weaknesses[], context_window, max_output,
    latency_profile, supports[chat/stream/json/tools], pricing, notes }

TaskProfile (请求时即时构建)
  { category, est_in_tokens, est_out_tokens, stream, interactive,
    goal(cheapest|fastest|best|balanced|自定义权重), max_cost, deadline }

Policy (用户的预设条件, 热加载)
  routing_table / virtual_models / goals / 否定规则("写作绝不用X")

Decision (每次路由的产物, 可解释, 含切换事件)
  { task, chosen, score_breakdown, rejected+原因, fallback_order, handoffs[] }
```

---

## 3. 需求清单（重排后）

### M1 静态网关 + 知识库
- 账户注册（TOML + 管理 API）；OpenAI 兼容 `POST /v1/chat/completions`（非流式）+ `GET /v1/models`
- Provider 适配层：OpenAI 兼容系（OpenAI/DeepSeek/Kimi/GLM/Grok/OpenRouter/OpenCode/Perplexity）
- **Model KB** 档案 + 类别×模型适配度矩阵
- 静态路由（routing_table + fallback 链）+ 可解释决策日志
- 成本累加 + 月度预算硬上限；热加载配置

### M2 流式 + 实时调度 + 无缝切换（核心战役）
- SSE 流式透传（`stream: true`），chunked 解码 + JsonStream 增量解析
- 实时信号：429/限流头 → 令牌桶；错误率 → 熔断器；时延 EMA；在途并发
- 评分调度：fit(知识库) × cost(账本) × latency(EMA) × load，权重来自 goal
- **Seamless Handoff**：流式中途配额耗尽/账户故障 → 无缝切换模型续写（第 8 节）
- 粘性会话 + 优先级队列；JSONL 账本持久化 + 重启恢复；混沌注入测试

### M3 体验
- Web 仪表盘（复用 AegisOTP 深色 UI + WS 推送）：账户卡片、实时决策流、成本曲线、切换事件高亮
- CLI：`oasis ask` / `oasis budget` / `oasis status` / `oasis models`
- 提示词缓存定价、单二进制打包、基准与文档

### M4+（只列不承诺）
任务自动分类（规则 + 便宜小模型元调度）、嵌入/图像端点、多用户、报表导出。

---

## 4. 总体架构（Riot/OTP 映射）

### 4.1 监督树

```
OasisRoot (Supervisor, OneForOne)
├─ ConfigActor          # TOML + ModelKB 加载/热重载/分发快照
├─ LedgerActor          # 用量/成本账本 (JSONL 追加 + 快照; ETS 式状态在 actor 外)
├─ TelemetryHub         # 事件总线 → WS 广播 (决策/切换/告警)
├─ QueueActor           # 优先级队列
├─ SchedulerActor       # 调度大脑: 硬约束 → 评分 → 派单 → 编排回退链
├─ ProviderSupervisor (OneForOne)          ← 每账户一个子 actor
│   ├─ AccountActor:deepseek_pro  (Permanent)
│   └─ AccountActor:opencode_free (Permanent)
└─ Gateway (Nomad+Trail)  # OpenAI 兼容 API + 仪表盘 + WS
   └─ 每请求一个 RequestConductor actor (流式期存活, Temporary)
```

### 4.2 请求链路（含切换）

```
客户端 → Gateway → SchedulerActor
  → 硬约束过滤 (熔断开/限流满/预算尽/模型不匹配/并发满 → 排除+记录原因)
  → 评分: score = w_fit·fit + w_cost·cost + w_lat·lat + w_load·load
  → 选定账户 → 派单给 AccountActor → 起 RequestConductor (流式)
  → AccountActor 在 spawn_blocked 阻塞道做 HTTPS I/O (TlsStream)
      ├─ 正常: chunks → Conductor → 客户端; usage → Ledger; 时延 EMA 更新
      ├─ 429/402/5xx/断流/配额尽 (首 token 前): 回退链重试下一账户
      └─ 配额尽/故障 (首 token 后): → 无缝切换 (第 8 节)
  → Decision (含 handoff 明细) 进日志 → WS 推送仪表盘
```

---

## 5. 调度引擎

### 5.1 硬约束（一票否决）
enabled ∧ 熔断未开 ∧ 令牌桶有余 ∧ 预算剩余 > 预估成本 ∧ 上下文足够 ∧ 支持 stream ∧ 在途 < 并发上限 ∧ 日限未用尽

### 5.2 评分（权重来自 goal 预设，任务级可覆盖）
- **fit_score**：类别×模型适配度矩阵（来自 ModelKB strengths/weaknesses + 用户 tier 修正）——"懂模型"的体现
- **cost_score**：该账户模型单价（输入/输出/缓存）归一化——"懂成本"
- **latency_score**：时延 EMA 分位——"懂实时情况"
- **load_score**：在途任务少的优先
- 加分：粘性会话命中、缓存命中概率、限流窗口即将重置

### 5.3 熔断器
窗口内错误率 ≥ 阈值 → 开环冷却 30s → 半开探测一个请求 → 成功闭环/失败重开。与 Supervisor 重启正交：熔断 = "暂时别用"，崩溃 = "杀掉重来"。

### 5.4 预算
硬上限拒绝路由（决策日志写明"因预算被排除"）+ 80% 软告警（WS 推仪表盘标黄）+ 任务级 `X-Oasis-Max-Cost` 头可豁免/收紧。

---

## 6. 模型知识库（Model KB）

出厂档案（用户可改，先给第一批）：

| 模型 | tier | 强项 | 上下文 | 画像 |
|---|---|---|---|---|
| deepseek-chat | 4 | coding/math/analysis | 64K | 便宜、强推理、时延中 |
| kimi (moonshot) | 4 | long_doc/中文 | 128K+ | 长文档利器 |
| glm-4-flash | 3 | 通用/便宜 | 128K | 免费档、性价比 |
| openrouter/* | 视模型 | 聚合 | 视模型 | 报告剩余积分 |
| opencode-free | 2-3 | 通用 | 视模型 | 免费但有日限 |
| claude-sonnet | 5 | coding/agent/tool | 200K | 贵、agent 首选 |
| gpt-4o | 5 | 通用/多模态 | 128K | 贵、均衡 |
| gemini-flash | 3-4 | long_doc/多模态 | 1M | 长上下文性价比 |

字段：`name/tier/strengths[]/weaknesses[]/context_window/max_output/latency_profile/supports[]/pricing/in+out+cache_hit/notes`。
适配度矩阵：`fit(category, model) = Σ strength权重 - Σ weakness权重`，用户 tier 覆盖出厂 tier。
后续可用便宜模型（glm-4-flash）自动生成档案初稿再人工校 —— M4 元调度。

---

## 7. 任务画像（Task Profiler）

请求时即时构建，信号来源（优先级从高到低）：
1. **显式要求**：门户自定义头 `X-Oasis-Goal` / `X-Oasis-Model` / `X-Oasis-Max-Cost` / `X-Oasis-Category`；CLI/仪表盘入口参数
2. **会话记忆**：session_id 的历史画像（粘性、偏好模型、历史成本）
3. **请求自证**：max_tokens、stream、工具调用、system prompt 关键词、会话长度、语言
4. **推断**（M1 规则版，M4 分类器）：关键词 + 文件类型 → category（coding/写作/翻译/分析/长文档/通用）

输出 TaskProfile 供硬约束与评分使用。**目标表达**：goal 预设 + 全局预算 + 任务级覆盖，三层。

---

## 8. 无缝切换引擎（Seamless Handoff）★核心

**为什么难**：第三方客户端（Claude Code / opencode / Chatbox）对门户只有一条 SSE 连接、一个请求；上游中途死了，客户端期望这条流"还活着"。门户要在**不重开连接、不重复 tokens**的前提下换模型续写。

### 8.1 触发时机
- **被动**：上游连接断 / 429 / 402（欠费）/ 5xx / 流异常终止 / 单账户 tokens 用尽（如 OpenRouter 积分耗尽返回的额度错误）
- **主动（预测性）**：派单前估算"预估成本 > 剩余额度" → 直接不用 A；流式中按已出 tokens 实时折算，距配额 < 安全边际 → **在句子边界提前切**（更平滑，客户端的停顿更短）
- **人工**：管理 API `POST /api/switch` 强制切换

### 8.2 接续语义
Conductor 始终缓冲"已发给客户端的完整 assistant 文本"。切换时向账户 B 发起：
```
原 messages + assistant 前缀 = 已生成文本 + 续写指令
```
B 从头生成续写，Conductor 对 B 的输出做**公共前缀裁剪**（去重），只把新增 tokens 接上原流。

### 8.3 拼接算法
- 对 B 流做流式前缀匹配：逐字符/逐 token 与已发文本尾部对齐，匹配则丢弃重复，出现分歧点立即转入增量转发
- 若 B 改写了表达方式导致分歧：在分歧点回退到最近的句读边界（。！？\n）裁剪少量 tokens，保证语义连贯
- 切换过程客户端只见一次短暂停顿（B 的握手 + 首 token 时延），连接不重开

### 8.4 双段计费
A 段按 A 实际 usage 计（含中断时的部分 usage），B 段按 B 计（注意：前缀续写会把已生成文本作为 B 的输入 tokens 计费——这是接力的真实成本，账本如实记）。Decision 记录 handoff 事件：`{from, to, trigger, a_usage, b_usage, splice_pos, stall_ms}`，WS 推送仪表盘高亮。

### 8.5 边界与降级
- 首 token 前失败 → 不算 handoff，是**纯重试**（换账户整体重放）
- B 拒绝续写或候补全不可用 → 正常收尾：`finish_reason="handoff_failed"` + 已生成内容，决策日志注明；CLI/仪表盘提示"已保存半成品，可稍后继续"
- 连续 2 次 handoff 失败 → 放弃（防抖），返回已生成部分
- 同一流最多切换 3 次（防乒乓）

---

## 9. 出站 HTTP 客户端（已核实，std 能力）

- `Net.TlsStream.from_tcp_client ~hostname`（OpenSSL，ALPN）→ HTTPS 可行
- `Runtime.spawn_blocked` 专用阻塞道 → 出站 I/O 不卡协作调度器（**铁律：所有 socket I/O 只在阻塞道**）
- `Data.JsonStream` 增量 JSON → 适配 SSE 流
- 自研：`Portal.Client`（请求序列化 + 响应解析 + chunked 解码 + SSE 聚合）、每 AccountActor 的连接池（keep-alive 复用）、三层超时（连接/首字节/整体）+ 取消
- Nomad/Trail 扩展：`Trail.RespondStream`（状态行+头后裸字节流式写出）

---

## 10. 数据与持久化

- 账本 `~/.oasis/ledger.jsonl`：`{ts, account, model, in/out/cache_tokens, cost, latency_ms, status, handoff_of}`，写一条 flush 一条；快照 + 增量重放恢复
- 配置 `~/.oasis/config.toml`（账户/额度/策略）+ `model_kb.toml`（知识库）；密钥 `secrets.toml`（0600）或环境变量
- 决策日志：内存环形缓冲（最近 500 条）+ JSONL 追加
- 不做 SQLite（v1 用不上）

---

## 11. API 表面

```
POST /v1/chat/completions    # 非流式(M1) / stream=true(M2, SSE, 无缝切换)
GET  /v1/models              # 聚合模型列表 (虚拟名 + 真实名 + KB 摘要)
GET/POST/DELETE /api/accounts /api/policies /api/kb
GET  /api/decisions          # 决策日志含切换事件
GET  /api/ledger
POST /api/switch             # 人工切换
POST /api/chaos/*            # 混沌: 杀账户/模拟429/熔断/配额尽
WS   /ws                      # 实时: 决策/切换/告警
TCP (Atacama)                 # STATUS/ACCOUNTS/DECISION/SWITCH
门户自定义头: X-Oasis-Goal | X-Oasis-Model | X-Oasis-Max-Cost | X-Oasis-Category
```

---

## 12. 安全
默认绑 127.0.0.1；开 0.0.0.0 需显式配置 + token；密钥脱敏；出站证书校验；每账户可配代理；单任务最大成本防误烧。

---

## 13. 里程碑（重排）

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **M0 spike** | TlsStream+spawn_blocked 打通 1 个真实 API；SSE/chunked 解析；**中途断流→续写的接续机制原型** | spike 能从真实 API 流式打印；本地 mock 断流后能续写 |
| **M1 静态网关+KB** | 多账户配置；非流式 API；ModelKB + 适配度矩阵；静态路由+回退；成本累加；热加载 | curl 路由到指定账户；改 TOML 热生效；decisions 可解释 |
| **M2 流式+调度+无缝切换** | SSE 透传；令牌桶/熔断/EMA/并发；评分调度；**Seamless Handoff**；预算硬限；持久化恢复；混沌测试 | 模拟 429/5xx/配额尽→自动切账户且客户端流不断、tokens 不重；kill 账户 actor→自愈且账本不丢 |
| **M3 体验** | 仪表盘+WS；CLI；粘性会话；优先级队列；缓存定价；打包+文档+基准 | 第三方工具指向门户全流程可用；`--self-test` 全绿 |

测试武器：单测（评分/令牌桶/熔断/SSE/拼接）+ **Nomad/Trail 假 OpenAI 服务器**（可编程 429/5xx/断流/配额尽）+ 混沌注入 + `riot bench`。

---

## 14. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| 拼接不干净（重复/断裂 tokens） | 高 | M0 先原型；公共前缀裁剪 + 句读边界回退；单测覆盖分歧场景 |
| B 拒绝续写半成品 | 中 | 降级策略 8.5；续写指令设计（"continue exactly"）打磨 |
| 双段计费把前缀重复计费 | 中 | 如实记账 + 决策日志明示；预测性切换减少发生 |
| 手写 HTTP 客户端边界情况 | 高 | M0 spike；喂真实抓包样本；JsonStream 复用成熟实现 |
| 阻塞道误用卡死调度器 | 高 | 铁律 + 代码评审 |
| 各家 429 语义不一 | 中 | 指数退避+抖动；用户额度兜底 |

---

## 15. 已核实事实（std 0.0.43 源码，2026-11-01）
TLS 客户端✅ `spawn_blocked`✅ TOML/JsonStream✅ WorkerPool/Agent/Supervisor/Telemetry/ConcurrentHashMap✅；无 HTTP 客户端⚠️（自研）；Nomad 无 chunked/SSE 输出⚠️（扩展 RespondStream）。

## 15.1 M0 战报（2026-11-01 完成）

- ✅ `packages/portal` 已建：`Client`（HTTP/1.1 客户端，plain/TLS、Content-Length/chunked/close-delimited）、`Chunked`（增量 chunked 解码）、`Sse`（SSE 增量解析）、`Handoff`（无缝续写拼接）、`Mock`（可编程假 OpenAI 服务器：429/断流/切点感知的中途死亡）
- ✅ 测试 **21/21 全绿**（portal 16 个：单测 + 三个集成测试；含"流中途配额耗尽 → 断流 → B 账户续写 → 拼接无缝"完整链路）
- ✅ 真实外网验证：`portal_probe` 对 api.deepseek.com 完成 TLS 握手 + HTTP 请求，解析 401 响应（无 key 预期行为）

## 15.3 M1 战报（2026-11-01 完成）

- ✅ `Kb`（模型知识库 + fit 评分 + 成本/上下文检查）、`Config`（TOML 账户/KB/路由/策略，热加载 API）、`Ledger`（nano-dollar 整数记账 + JSONL 持久化 + 日/月计数）、`Router`（硬约束过滤 + 回退链 + 可解释决策）、`Gateway`（OpenAI 兼容非流式 + spawn_blocked 阻塞道出站）、`oasis` 二进制
- ✅ 测试 **32/32 全绿**（portal 27：含 3 个网关集成测试——路由透传+账本、上游 429 自动回退、预算耗尽 402）
- ✅ **实弹验证**：`oasis` 起在 9899 端口，真实请求经路由 → TLS 出站到 api.deepseek.com → 401（无 key）→ 回退耗尽 → 502 附完整决策（attempts: status=401, latency=85ms）；ledger.jsonl 落盘
- 运行方式：`HOME="$PWD/.fakehome" riot run -p portal oasis -- --config oasis.toml`

## 15.5 M2 战报（2026-11-01 完成）

- ✅ `Signals`（每账户实时信号：RPM 窗口/时延 EMA/错误率/在途数/**熔断器**，纯函数可单测 + ConcurrentHashMap 状态，崩溃不丢）
- ✅ `Router.route_scored`（v2 评分调度：fit×cost×latency×load 加权，权重来自 goal——cheapest/fastest/best/balanced；同分按路由表顺序稳定决胜）
- ✅ **Trail/Nomad 流式扩展**：`Trail.stream` + `RespondStream`（200 头 + close-delimited 裸字节流，无 Content-Length）
- ✅ **Gateway 流式 + 无缝切换**：per-request 导体 actor；上游跑在阻塞道逐 chunk 转发；每条腿带 leg_id 防串扰；上游死亡/配额尽 → 换账户续写（assistant 前缀 + Handoff 拼接去重）；`[DONE]` 前等 `Upstream_ended` 保证干净收尾；决策记录双段尝试
- ✅ 测试 **28/28 全绿 × 10 连压零崩溃**；全工作区 33/33
- ✅ **实弹验证**：M2 oasis 直播在 9899，stream=true 请求经真实 DeepSeek TLS → 401 → SSE 收尾 `data: [DONE]`；/api/accounts 显示 latency_ema/breaker/in_flight；决策含 scores

## 15.6 本轮踩到的运行时深坑（重要，已修复/规避）

1. **std `&&`/`||` 不短路**（§15.2 已记）——本轮又抓到 3 处依赖短路的越界/死循环
2. **`Option.and_then`/`map` 需 `~fn:` 标签**；`?param` 自动包装；`Path.from_string` 返回 result；`List.sort` 用 `~compare` 返回 `LT/EQ/GT`
3. **socket 双重关闭**：mock 断流后手动 close + Atacama finalize 再 close → fd 复用后误杀无辜 socket → 随机 SIGSEGV。已修（只让 finalize 关一次）
4. **send 到已死 pid**：上游流结束后向已退出的导体发消息 → 偶发段错误。已改为 leg_id 标记 + 干净收尾不发
5. **Atacama.stop 顺序**：必须先停 acceptor 监督树再关 listener（关 fd 时不能有 actor 挂在 accept 上）
6. **测试进程内高频启停 Atacama 池**（每进程几十个池）触发运行时级竞态（挂起/段错误双模式）。**解法：集成测试合并为共享池子的端到端场景测试**（每套件池子数 40→7），连压 10 轮稳定。这是 Riot 0.0.43 运行时在极端 churn 下的已知弱点，生产场景（进程内常驻池）不受影响，已记录待上游修复

## 15.7 M3 战报（2026-11-01 完成）

- ✅ **仪表盘**（/，AegisOTP 风深色 UI）：账户卡片（熔断色标/时延EMA/在途/日用量/月度成本+预算）、快速提问（类别/goal/流式开关）、实时决策流（**切换事件高亮**）；**WS 实时推送**（/ws，决策广播 + 3s 轮询兜底）
- ✅ **CLI 客户端**（`oasis <命令>`）：`models` / `status` / `budget` / `decisions` / `reload` / `ask "..."`（--category/--goal/--stream，流式逐字打印）
- ✅ **粘性会话**（`X-Oasis-Session` 头）：会话钉在服务账户上（TTL 10 分钟），**回退成功后重钉**（非流式与流式都重钉——测试抓出了非流式漏重钉的 bug 并修复）
- ✅ **`oasis-mock`** 独立 mock 上游二进制（--port/--sse/--cut/--body/--status），无 key 也能完整演示
- ✅ 测试 **29/29 全绿 × 5 连压**（新增 session 单测 + 端到端场景扩展出 S5 粘性三连测）；全工作区 **34/34**
- ✅ **live 演示**：mock A 流式中途断流 → CLI `ask --stream` 输出"你好，我是 Oasis 门户——无缝切换演示成功！"零重复；决策日志 `general → mock_b [mock_a(err) → mock_b(200)]`；仪表盘+WS 就绪
- 演示命令：`oasis-mock --port 9911 --sse "你好，我是" --cut 134` + `oasis-mock --port 9912 --sse "你好，我是 Oasis 门户——无缝切换演示成功！"` + `oasis --config oasis-demo.toml` + `oasis ask "你是谁" --stream`

## 15.8 M3 遗留（下轮）

优先级队列（交互即时/批量后台）、提示词缓存定价、`riot bench` 基准、单二进制打包脚本、`--self-test` 全链路自检模式、`~/.oasis` 部署说明文档

## 15.9 M3 收尾战报（2026-11-01 完成，项目达成）

- ✅ **提示词缓存定价**：`usage.cached_tokens` 解析 + 缓存单价计费（`Kb.est_cost_nano ~cache_tokens`），单测覆盖
- ✅ **`oasis --self-test`**：一条命令跑完整全链路（非流式路由 → 429 回退 → SSE 流式 → **中途断流+无缝切换零重复**），release 二进制验证通过
- ✅ **`riot bench`**：7 个基准全绿——调度评分 ~33µs/决策、Handoff 拼接 ~26µs、chunked 解码 ~7µs、SSE ~7µs（个人规模绰绰有余）
- ✅ **打包**：`scripts/build-release.sh` → release 构建 + 拷贝到 `dist/`（oasis 9.4MB 单二进制）
- ✅ **文档**：`packages/portal/README.md`（快速开始/端点/自定义头/调度原理/配置要点/无 key 演示/架构）
- ✅ 终验：全工作区测试 **34/34**；portal **29/29 × 5 连压稳定**；基准 7/7；release 自检 4/4

## 16.1 最终状态：M0→M3 全部达成

| 里程碑 | 状态 |
|---|---|
| M0 spike（TLS/HTTP 客户端、chunked/SSE、接续原型） | ✅ |
| M1 静态网关 + Model KB + 账本 + 可解释决策 | ✅ |
| M2 流式 + 实时信号（EMA/熔断/RPM）+ 评分调度 + **无缝切换** | ✅ |
| M3 仪表盘 + WS + CLI + 粘性会话 + 缓存定价 + 自检 + 基准 + 打包 | ✅ |
| 有意推迟：优先级队列（个人场景价值低）；任务自动分类器（M4 元调度，规则版已够用） | 记录在案 |

核心能力实测证据：live 演示"你好，我是 →（mock A 断流）→ Oasis 门户——无缝切换演示成功！"零重复；决策日志 `general → mock_b [mock_a(err) → mock_b(200)]`；全测试绿 + 基准微秒级 + 发布二进制自检绿。

## 16.2 真实 API 验证战报（2026-11-02，DeepSeek 实测）

- ✅ **非流式**：`oasis ask "1+1等于几" --no-stream` → **"1+1等于2。"**（真实 deepseek 账户，账本记 8400 nano ≈ $0.0000084）
- ✅ **流式**：`oasis ask "用一句话说明什么是无缝切换" --stream` → 完整流式输出；时延 EMA 更新到 907ms；成本 $0.000012180
- 全程经门户调度：决策日志 status 200 + 真实 usage tokens + 成本回填账本

## 16.3 真实 API 逼出的两个真 bug（已修复）

1. **chunked 解码的"部分读"漏洞**（最隐蔽的一个）：TLS 读返回小片段（实测 5 字节 `"26d\r"`——一个 chunk-size 行被 TCP/TLS 拆成两半），feed 后没有完整 chunk 时 body_reader **直接返回空串** → 提前结束 → 空 body / 流挂起。mock 一次写大块所以从未暴露。修复：feed 后队列空且未结束则继续读。这是"本地全绿 ≠ 真实可用"的典型教训——真实网络的碎片化才是终极测试。
2. **上游 keep-alive 不关连接**：DeepSeek 流式响应结束后保持连接 → 阻塞道读不到 EOF → 导体 120s 超时。修复：上游请求加 `Connection: close`。
3. 顺带：riot 依赖分析器无法解析多行 doc 注释缩进行和 `Env.*` 位置调用（绕行）；测试 runner 500ms 小测试超时（真实网络测试标记 `Test.Large`）

## 16.5 Kimi Work 接入战报（2026-11-02）

从本机运行的 Kimi 桌面应用（Kimi Work / daimon agent 运行时）提取并接入了它的官方网关：

- **API**：`https://agent-gw.kimi.com/coding/v1`（OpenAI 兼容；另有 `.../coding` 为 Anthropic 风格端点）
- **凭证**：`~/Library/Application Support/kimi-desktop/daimon-share/daimon/config.json` → `credentials/kimiCode/apiKey`（sk-kimi-*，用户自己的应用密钥）；kimiWeb 另有一对 JWT access/refresh token（www.kimi.com 网页登录态，未使用）
- **模型**：`k3-agent`、`k2d8-preview`（1M 上下文、支持推理 + 图像/视频输入；k2p6-agent 走 Anthropic 端点）
- **自定义头**：User-Agent: Desktop Kimi Work / X-Msh-Version: 3.2.17（实测不强校验）
- ✅ 门户实弹：general → kimi_work（评分 92 > 88）、coding → deepseek_pro；**kimi 慢推理（3.9s）后时延 EMA 把它的分数打下去，调度器自动切向 deepseek**——实时信号在真实负载下按设计工作；回退链也在 kimi 地址解析 bug 期间真实兜底过一次
- 价格未知暂置 0（不参与成本比较），拿到真实价格后填 `oasis.toml`

**修掉的 bug**：`parse_base_url` 不支持带路径前缀的 base_url（`https://host/coding/v1` 被整体当成 host）——已支持路径前缀，chat 路径 = `<prefix>/chat/completions`。

## 16.6 GLM/ZCode 接入战报（2026-11-02）

从本机运行的 ZCode（智谱 AI IDE）提取配置（`~/.zcode/v2/config.json`）：

- **z.ai 密钥**：`provider/builtin:zai/options/apiKey`（49 位，有效）→ OpenAI 兼容端点 `https://api.z.ai/api/paas/v4`
- **bigmodel**（open.bigmodel.cn）与 zcode-plan 走 ZCode 登录态（进程内，磁盘无明文 key）→ 无法直接复用
- **实测**：z.ai 余额不足（HTTP 429 + code 1113）
- ✅ 已把 `glm_zai` 账户（模型 glm-4.6，tier 4，128K 上下文）配进门户作为 general 第三顺位；充值后即可投入使用
- ✅ **真实负载验证了"坏账户隔离"全链路**：指定 glm-4.6 → 唯一服务账户 429 → 其他账户 model_not_served 拒绝 → 可解释 502；**连续 5 次失败后熔断打开，第 6 次请求在路由阶段被 `circuit_open` 拒绝，不再浪费任何上游调用**

**修掉的 bug（真实负载暴露）**：熔断器原用 60 秒滚动窗口错误率——失败间隔超过窗口时（余额不足账户的典型模式）错误计数被滚动清零，永远不熔断。已加**连续失败计数**（时间无关，≥5 次即熔断，成功清零），单测覆盖跨窗口场景。

## 16.7 GLM 真通 + Anthropic 协议适配器战报（2026-11-02）

用户指出 ZCode 运行正常——追查发现 ZCode 实际调用的不是 OpenAI 端点而是 **`https://api.z.ai/api/anthropic`（Anthropic Messages 协议）**，同一个 key 在该端点上余额正常（OpenAI 端点上才报 1113）。于是给 Oasis 实现了 **Anthropic 协议适配器**（`Portal_anthropic`）：

- **请求转换**：OpenAI messages → Anthropic Messages（system 提升为顶层 system 字段）
- **响应转换**：Anthropic content 块 → OpenAI choices/message（跳过 thinking 块；**无 text 块时用 thinking 兜底**——glm-4.6 是推理模型，小 max_tokens 下正文全在 thinking 里）
- **流式事件**：content_block_delta/text_delta → OpenAI delta chunk；message_stop → [DONE]
- 账户配置加 `protocol = "anthropic"`（默认 openai）；端点路径按协议（`/v1/messages` vs `/chat/completions`）；认证头 x-api-key + anthropic-version
- ✅ **三账户全部真实在线**：DeepSeek（openai）、Kimi Work k3-agent（openai）、**GLM glm-4.6（anthropic 适配）**——glm 非流式返回"1+1=2"、流式逐字、usage 精确、EMA 1267ms
- ✅ **跨协议无缝切换测试**：anthropic 账户中途断流 → openai 账户续写，客户端零重复（Handoff 在文本层，协议无关）
- ✅ 测试 36/36（+4 适配器单测 + 2 个端到端）；hello_riot 5/5

已知事项：glm-4.6 的 thinking 会消耗大量输出 tokens（小 max_tokens 时正文被 thinking 吃光）——后续可加关闭 thinking 的参数（z.ai 支持 thinking 开关）。

## 16.8 OpenRouter 接入战报（2026-11-02）

- key 来自 `~/.zshrc` 的 `OPENROUTER_API_KEY`（环境变量名与配置一致，启动时 export 即可）
- 端点 `https://openrouter.ai/api/v1`（OpenAI 兼容），实测 **416 个模型**可用
- 精选 3 个进 KB：`openai/gpt-6.1-terra`（tier 5）、`deepseek/deepseek-v4.1-flash-1017`（tier 4）、`minimax/minimax-m3.1-flash`（tier 3），价格未知暂置 0
- 路由：general 与 coding 链的兜底位
- ✅ 实测：指定 `deepseek/deepseek-v4.1-flash-1017` → chosen=openrouter → 200/833ms → "你好，很高兴见到你！"；注意 OpenRouter 会自行选择上游 provider（本次是 Wafer），响应里带 provider 字段
- 至此门户 **4 账户在线**：DeepSeek（openai）/ Kimi Work（openai）/ GLM z.ai（anthropic 适配）/ OpenRouter（openai，416 模型）
- 后续可做：解析 OpenRouter 的 X-Credits 头做剩余额度跟踪（它在响应头里报告剩余积分）

## 16.9 主打模型精修战报（2026-11-02）

按"每家 provider 主打优先、必须真能完成任务、不堆数量"原则，用各家真实 API 摸底后重配：

| 账户 | 主打 | 便宜/快速档 | 实测 |
|---|---|---|---|
| deepseek_pro | **deepseek-v4-pro**（1M ctx 推理旗舰） | deepseek-flash | ✓ 双双通过 |
| kimi_work | **k3-agent**（1M ctx） | — | ✓ |
| glm_zai | **glm-5.3**（旗舰，thinking=disabled） | — | ✓ |
| openrouter | **qwen/qwen3.8-max-prime** | deepseek/deepseek-v4.1-flash | ✓ |

- 摸底发现：DeepSeek 账户真实主打是 v4-pro（不是 chat）；GLM 主打是 glm-5.3（4.6 已过气）；OpenRouter 的 gpt-6.1-terra-pro 和 gemini-3.8-flash 对该 key **403（地区合规）**——已剔除，只留实测可用的
- **thinking 控制**：账户级 `thinking = "disabled"`，实测 glm-5.3 同答案 132→9 tokens；适配器在请求中注入 `{"thinking":{"type":"disabled"}}`
- **reasoning 兜底**：deepseek-v4-pro 小 max_tokens 时正文在 reasoning_content——非流式透传前自动用 reasoning 填充空 content
- 模型列表从"堆数量"收敛为 7 个精选条目，全部矩阵实测通过

## 16.10 真实使用反馈修复战报（2026-11-02）

用户实测"这周上海天气汇总"发现两个问题，均已修复：

1. **流式输出一堆 JSON**：k3-agent（推理模型）流式 chunk 里 `delta.content` 为空、思考在 `delta.reasoning_content`——导体空 content 时把**整坨上游 chunk JSON** 当正文转发。修复：流式中 content 为空则跳过（思考不外泄、不吐 JSON），非流式保留 reasoning 兜底
2. **回答截断**（"建议你"后没了）：推理模型的思考消耗 max_tokens 预算，小预算（仪表盘 128/CLI 256）下正文发不出来。修复：默认 max_tokens 提到 2048
- ✅ 复测：同一问题流式输出 180 字符完整回复（无 JSON、无思考泄漏、有完整结尾）

## 16.11 AI Agent 门户扩展战报（2026-11-02）

按用户需求，Oasis 升级为 **AI 账户 + Agent 双门户**：需要 tools 的任务自动匹配本地无头 agent（Claude Code / opencode / gemini / codex），纯对话走 API 账户。

- **`Portal_agent`**：agent 注册（command/args 模板 `{prompt}` `{model}`/workdir/超时/能力清单/tier/强项）+ 子进程执行器（阻塞道 spawn、**poll 式 stdout 读取**、看门狗超时 SIGKILL、exit code 判定）+ 输出解析（Claude stream-json 提取 assistant 文本，其余纯文本）
- **路由**：`X-Oasis-Mode: agent|chat` 显式头 + policy `agent_categories`（默认 coding 自动走 agent）；同一套 Signals（熔断/EMA/并发上限）+ 回退链（agent 失败换下一个，可再续接部分输出）
- ✅ 测试 **41/41**（+5：args 模板、claude stream-json 解析、fit、agent 路由+回退、agent 流式——用假 agent 脚本全链路验证）
- ✅ **live 验证**：coding 任务 → agent 池（chosen=claude_code，4 个 agent 依次尝试后 502 可解释决策）；`X-Oasis-Mode: chat` 正确绕开 → deepseek-v4-pro 正常
- ⚠️ **本机 agent CLI 现状**（框架就绪，CLI 环境待修）：claude -p 静默/exit 1（需重新登录）；codex 未安装；opencode 报 FileSystem.open 错误（自身 bug）；gemini 挂起（网络待查）。**CLI 修好后门户零改动即用**——不可用的会被熔断自动隔离
- 踩坑记录：std `File.read_line` 对管道 EOF 会挂死（FFI bug）→ 改用 `File.read` 轮询 + 进程状态判定；阻塞道 actor 内不能 receive（双层 spawn_blocked 死锁）→ 执行器改同步 collect + 消息只发给调度器 actor

## 16.12 MCP 入口战报（2026-11-02）

借鉴 Reason Machines 的 MCP 模式，Oasis 暴露 **`/mcp`**（JSON-RPC 2.0 + Streamable HTTP 简化版，protocolVersion 2025-03-26）：

- 5 个工具：`oasis_ask`（聊天任务→智能调度）、`oasis_agent_task`（agent 池任务）、`oasis_status`（账户状态）、`oasis_decisions`（决策历史）、`oasis_models`（模型/agent 目录）
- 重构：非流式执行路径提取为 `execute_chat_sync`（HTTP 与 MCP 共用，成本/信号/账本/决策记录一致）
- ✅ 测试 42/42（MCP 解析单测 + 并入端到端场景 S6：initialize→tools/list→tools/call→未知方法 -32601；注意合并进共享池子测试以避免 churn 竞态 SIGSEGV）
- ✅ live 验证：真实握手 → `oasis_ask "1+1"` → chosen=kimi_work → "2"；`oasis_status` 四账户状态
- 接入方式（Claude Code）：`claude mcp add --transport http oasis http://127.0.0.1:9899/mcp`

## 16.13 Claude Code 真实接入闭环（2026-11-02）

用户在本机 Claude Code 执行 `claude mcp add --transport http oasis http://127.0.0.1:9899/mcp`（项目级配置）后**真实调用成功**：

- `oasis_status` → Claude 渲染四账户表格（熔断/EMA/在途/用量）
- `oasis_ask "1+1=?"` → 智能调度 → kimi_work/k3-agent → 200/1608ms
- 门户侧完整留痕：决策日志（chosen=kimi_work, attempts 记录）+ 账本（90 in / 27 out tokens）

MCP 协议细节按真实客户端补齐：Mcp-Session-Id 响应头、GET→405（纯 POST 声明）、JSON-RPC 完整包装、CORS。

**至此里程碑**：AI 账户门户 + Agent 门户 + MCP 入口全部真实闭环。Claude Code 等任何 MCP 客户端都能把任务送进门户调度。

## 16.14 Agent CLI 修复 + 首个真实 agent 任务战报（2026-11-02）

用户实测 `oasis_agent_task` 暴露的根因与修复：

1. **HOME 继承 bug**：agent 子进程继承门户的 `HOME=.fakehome` → claude/opencode/gemini 找不到配置。修复：agent 配置加 `home` 字段，spawn 时 env 注入真实 HOME（Process.spawn 的 ?env 是 setenv 增量覆盖）
2. **claude 参数**：`--output-format stream-json` 必须配 `--verbose`；无头模式权限批准无人响应 → 加 `--dangerously-skip-permissions`
3. **codex 二进制已不存在** → 配置禁用；opencode 自身 FileSystem.open bug / gemini 网络挂起 → 保持 enabled 由熔断隔离

✅ **里程碑：首个门户驱动的真实 agent 任务**——MCP `oasis_agent_task("在 /tmp 写文件")` → claude_code 子进程 → Claude Code 多策略执行（沙箱受阻→换 Write 工具）→ **文件真实落地**（`/tmp/oasis-claude-test.txt` = hello-from-oasis）

✅ 测试 43/43（+HOME env 注入单测）

## 16.15 异步任务句柄战报（2026-11-02）

用户反馈：agent 任务 51~125s > MCP 客户端超时（~60s），客户端拿不到结果。实现路线图上的**异步任务句柄**：

- 新模块 `Portal_task`（ConcurrentHashMap 任务注册表）+ `oasis_agent_task` 加 `mode`（**async 默认**，秒回 `task_id`；sync 保留）+ 新工具 `oasis_task_status`（running/done/failed 轮询）+ `timeout_s` 参数生效（record update 覆盖）
- ✅ 测试 44/44（+异步任务 e2e：提交→轮询→done，244ms 假 agent）
- ✅ live 验证：提交秒回 `task-951450199-427623` → 15s running → 45s done（Claude 最终报告）→ `/tmp/oasis-async-test.txt` 真实落地 "async-works"
- 澄清：agent 写 /tmp 能落地（非隔离环境）；之前 hello.txt 未更新是 Claude 自己的写入决策

**Claude Code 里的新工作流**：调 `oasis_agent_task` 拿 task_id → 几秒后调 `oasis_task_status` 取最终报告。

## 16.16 端到端实战：客户端自适应重试闭环（2026-11-02）

用户（Claude Code 作为 MCP 客户端）实测完整闭环：

1. `oasis_agent_task(agent=codex_cli)` → 门户 **9ms 快速失败**，错误信息清晰（"agent spawn failed: no such file or directory"）
2. Claude 理解错误 → 自动改用 `claude_code` 重试 → 成功（15s/22s，比首测 51~125s 大幅提速）
3. `/tmp/hello2.txt` 内容验证 = hello ✓

要点：**透明、可解释的失败信息让上层 agent 能自主决策**——这正是门户"可解释调度"设计的核心价值。codex_cli 已从配置移除（本机未安装）。

## 16.17 Agent 总线（借 Reason Network inbox 思想）战报（2026-11-02）

按用户定调的方向——**AIUsage 的 agent 管理 + Reason Network 的 agent 通信 + Riot/OCaml 底层优势**——落地第一块：**agent 消息总线**。

- 新模块 `Portal_inbox`：每 agent 一个收件箱（ConcurrentHashMap + JSONL 持久化到 data_dir/inbox，重启不丢）；deliver/check(取走即读)/pending_count/load
- 新 MCP 工具：`oasis_send_message`（to/text/from）、`oasis_check_inbox`（agent 取未读）、`oasis_ask_user`（问题进 user 队列）
- 新端点：`GET /api/inbox`（各 agent 未读数，dashboard 用）、`POST /api/inbox/reply`（用户回复 → agent 收件箱）
- ✅ 测试 46/46（+inbox 单测 + MCP 收发回环）
- ✅ live 验证：send→check 回环、ask_user 进 user 队列、用户 reply→agent inbox、JSONL 落盘

**协作流已经可以跑**：agent A 干不了的活 → send_message 给 agent B 的 inbox → B 下次 check_inbox 取到；agent 有疑问 → ask_user → 用户在 dashboard 回复 → 答案回 A 的 inbox。

下一块：agent 发现（扫描本机 agent + 登录态/状态）+ 活动聚合（借 AIUsage Session Center）。

## 16.18 Agent 发现战报（2026-11-02）

第二块：**agent 发现**（AIUsage inventory 思想）。

- 新模块 `Portal_discover`：扫描 6 个已知 agent 的**安装状态**（PATH 风格目录查找）、**登录态**（oauthAccount/auth.json/目录存在）、**活动**（~/.claude/projects/*/*.jsonl 最新 modified + 尾部解析 cwd → 最近项目 top3 + 600s 窗口活跃判定）
- 新端点 `GET /api/agents` + MCP 工具 `oasis_agents`
- ✅ 测试 47/47（假 home fixture 全链路）
- ✅ live 盘点（本机真实结果）：claude_code 已装已登录、最近项目 `/Users/vajra/air/ocagent`（真实会话解析）；opencode/gemini/kimi 已装已登录；codex 未装；cursor 已装
- 踩坑：`Fs.read_dir` 返回**裸文件名**（不是完整路径），嵌套读取必须手动拼接根目录——顺手修了 inbox.load 的同款隐患

## 16.19 活动聚合战报（2026-11-02）

第三块：**活动聚合**（AIUsage Session Center 思想）。

- 新模块 `Portal_activity`：只读解析 ~/.claude/projects/*/*.jsonl 尾部（128KB）→ session 摘要（项目 cwd/sessionId/turns/tool 调用数/最新消息摘录），按 mtime 排序时间线；支持关键词过滤
- 新端点 `GET /api/activity` + MCP 工具 `oasis_activity`（limit/query）
- ✅ 测试 48/48（fixture 全链路：cwd 解析/turns/文本块拼接/tool_use 计数）
- ✅ live 验证：解析出真实会话 `/Users/vajra/air/ocagent`（34 turns），最新消息正是用户上次的 agent 任务报告——**门户能回放"agent 最近干了什么"**
- 工程事故记录：MCP 区函数重排时误删了一段（handle_reload/inbox/execute_tool）——无 git，靠记忆重写恢复；教训：大规模移动前先备份

## 16.20 监督树调研战报（2026-11-02/03）

第四块"监督树"（Riot/OTP 特色）调研结论：**当前 Riot 版本 (0.0.43) 下不可靠，暂缓并回滚**。实测证据：

1. **测试 actor 里 spawn 挂起**：`spawn` 调用后调度器不返回调用者（纯 sleep 子进程也复现）；连接 actor 里 spawn 正常（run_conductor 先例）
2. **跨 actor 共享内存不可见**：worker actor `ConcurrentHashMap.insert` 后，调用方 actor 读不到（改走 `Agent` 进程消息传递才一致）
3. **改 Agent 注册表后测试进程 SIGSEGV (139)**——测试 harness 的 actor churn 竞态
4. **riot 缓存坑**：lib 源码改动后 `riot test` 仍跑旧测试二进制（test action 不随依赖失效）——改 lib 后必须 `riot clean --force` + 重建，否则"全绿/挂起"结论失真（本战报多轮排查被此坑放大）

**替代方案**（已落地并 48/48 验证）：per-task blocking-lane 执行 + 看门狗 SIGKILL + Signals 熔断/回退 + 自愈语义在调度层（连续失败隔离）。真正的 Supervisor 集成留待 Riot 运行时修复后（或换 kernel 版本）再做。

## 16.21 实际应用环境验收战报（2026-11-03）

按"在实际应用环境测试直到目标达成"完成全部验收（live 网关 + 真实 claude + MCP 客户端协议）：

1. **Dashboard 三新区块**：本机 Agent 盘点（安装/登录/活跃/项目）、Agent 活动时间线（会话+门户任务合并）、消息总线收件箱（未读数 + 用户回复框）
2. **MCP 11 工具全量就位**：oasis_ask/agent_task/task_status/status/decisions/send_message/check_inbox/ask_user/activity/agents/models
3. **消息总线**：用户→claude_code 投递 + 收件箱取读 + JSONL 持久化（跨重启保留历史）
4. **真实 agent 任务**：异步提交秒回 task_id → 15s 轮询拿到 claude 最终报告 → `/tmp/oasis-accept.txt`="验收通过" 文件真实落地
5. **时间线合并**：门户派发的任务（portal-agent-task，含耗时）与 claude 本地交互会话同屏
6. ✅ 测试 48/48（每次改 lib 后 clean --force 重建，避免 riot 缓存坑）

**当前门户全貌**：4 账户智能调度 + 无缝切换 + 熔断 + 11 MCP 工具 + 异步任务 + 消息总线 + agent 盘点/活动时间线 + dashboard 实时展示。

## 16.22 in_flight 泄漏修复战报（2026-11-03）

用户反馈"前端选 coding+fastest 没反应，general 正常"——根因链：

1. coding 类别走 agent 池；claude_code/gemini 被 `concurrency_limit` 拒绝（in_flight 卡在 ≥2），只剩坏掉的 opencode → 321ms 失败且无回退 → 客户端只见 [DONE] 无内容 = "没反应"
2. **泄漏点**：agent 流式请求在客户端中途断开 / write_stream 出错时，`mark_in_flight` 没有对称释放（finish_ok/finish_fail 之外的退出路径），一次断开永久占一个并发槽
3. 修复：`Portal_signals.release_in_flight`（只减 in_flight、**不影响熔断计数**——客户端断开不是 agent 的错）+ 流式 handler 的 released 标志与尾部兜底释放
4. ✅ 测试 49/49；live 验证：3s 断开客户端 → 12s 后 coding 任务正常（chosen=claude_code，rejected 空）

## 16.23 前端 coding 无反应根因战报（2026-11-03）

用户前端发 coding 任务无响应，逐层定位出**三个叠加 bug**（探针 + 请求审计 + 直接跑二进制）：

1. **`riot run` 缓存坑**：lib 改动后 `riot run` 会跑旧二进制（与 `riot test` 同款问题）——多轮"重启网关"实际都在跑旧代码。**从此启动必须用 `_build` 里最新产物的绝对路径**
2. **回退链 finished 标志 bug**：agent A 失败回退 B 后，`finished := true` 未复位——loop 立即退出、连接空响应、无决策记录。修复：finish_fail 返回续跑标志，成功回退后 `finished := false` 继续 loop
3. **坏 agent 被 EMA 反超**：claude 成功一次后 EMA 拉高，初始 EMA 的坏 opencode 分数反超被选中→失败回退（触发 bug 2）。修复：opencode/gemini 本机坏 → 配置 `enabled = false`（与 codex 同处理）
- 附带：**请求审计**（/api/requests，ts/category/goal/stream）——"没反应"可立即分辨请求是否到达
- ✅ 测试 49/49；live：连续 3 次 coding+best 流式全部正常（2/4/6）

## 16.25 前端可视化过程图战报（2026-11-03）

按用户要求实现"从发问开始每个节点都动起来"的过程图：

- **服务器事件流**：`broadcast_event` 五种实时事件走 WS——task_started（任务节点）/routed（候选+评分+拒绝原因）/attempt_started（执行节点脉动）/attempt_finished（成功绿/失败红+时延/错误）/task_done（汇总），request_id 贯穿账户路径（execute_chat_sync）与 agent 路径（handle_chat_agent）
- **前端 SVG 树状图**：根"任务"节点 → 候选节点横排（score 标注、被拒红✗）→ 尝试节点纵列（执行中脉冲动画）→ 成功/失败变色 + 回退虚线，全部 CSS/SVG 动画、零外部依赖
- ✅ 测试 50/50；WS 全事件实测（先连 WS 再发请求，5 种事件齐全）
- 附修：hello_riot 包移除废弃 concurrency_demo.ml（clean 重建暴露的 std 语法问题）；`get_bool_like` 支持 Toml.Bool（enabled=false 真正生效，§16.24 的根因）

## 16.4 维护提示

- 真实 API 手动测试：`printf '%s' "$deepseek_api_key" > .ds-key && chmod 600 .ds-key` 后跑 `riot test -p portal -f "real"`（无 .ds-key 自动跳过，套件保持封闭）
- 启动：`export deepseek_api_key=...; oasis --config oasis.toml`（key 从环境变量读取，不落配置）

## 15.4 设计实现中的小调整（与 v0.2 规划比）

- 金额全程整数 nano-dollar（std 无可靠 float TOML），`format_usd` 显示
- 数据目录默认 `./.oasis-data`（工作区内，沙箱限制），可配置
- 账本持久化为"整文件快照重写"（个人规模足够）；决策日志当前仅内存环
- 配置热加载先以 `POST /api/reload` 提供（文件监视 M3 加）

## 15.2 两个必须记住的坑（本轮实战发现）

1. **std 的 `&&` / `||` 不短路！**（`Kernel.(&&)` 是普通函数，两个操作数都会先求值。）任何依赖短路语义的代码（边界检查 `len > 0 && get ...`、递归 `a && f()`）都会越界/死循环。**铁律：控制流一律用显式 `if` 链**，`&&` 只用于两个操作数都安全（纯、无副作用、不越界）的表达式。
2. **沙箱下 riot 要写 `~/.riot` 注册表索引会失败**。解法：`HOME="$PWD/.fakehome" riot ...`（fakehome 内 `.riot/registry` 是工作区副本，`toolchains` 是符号链接）。所有 riot 命令都要带这个前缀。

---

## 16. 决策状态
- ✅ 已定：API-first；首批 OpenAI 兼容系；流式进 M2（因无缝切换依赖流式）；预算硬限+80%软告警+任务级覆盖；包名 `portal`/二进制 `oasis`/数据 `~/.oasis/`；hello_riot 网络栈先复用（抽包 M4 再议）；项目名 Oasis
- ⏳ 待定：M0 用哪家真实 API 验证（建议 DeepSeek，key 放环境变量）；Claude/Gemini 原生端点是否进 M3
