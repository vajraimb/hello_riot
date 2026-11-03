# Oasis — 个人 AI 账户门户

基于 **Riot/OCaml** 的多 AI 账户统一门户：任务发给门户，调度器根据
**模型知识库（懂模型）× 任务画像（懂任务）× 成本账本（懂成本）× 实时信号（懂现状）**
选出最合适的账户执行；**流式中途配额耗尽或账户故障时无缝切换到下一个账户续写**，
客户端只见一条连续的流、零重复 tokens。

## 快速开始

```bash
# 1. 看配置示例
oasis --example-config > oasis.toml
# 编辑 oasis.toml：填账户 base_url / api_key_env / 模型 / 单价 / 额度 / 路由

# 2. 启动门户（仪表盘 http://127.0.0.1:9899/）
oasis --config oasis.toml

# 3. CLI
oasis models            # 模型知识库
oasis status            # 账户实时状态（熔断/时延/在途/成本）
oasis budget            # 月度花费
oasis decisions         # 路由决策（含切换事件）
oasis ask "帮我写个快排" --category coding --goal cheapest --stream
oasis reload            # 热加载配置
```

## OpenAI 兼容端点

```bash
curl -N http://127.0.0.1:9899/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'X-Oasis-Category: coding' \
  -H 'X-Oasis-Goal: fastest' \
  -H 'X-Oasis-Session: my-session' \
  -d '{"model":"deepseek-chat","messages":[{"role":"user","content":"hi"}],"stream":true}'
```

第三方工具（Chatbox 等）直接指向 `http://127.0.0.1:9899` 即可使用。

| 自定义头 | 作用 |
|---|---|
| `X-Oasis-Category` | 任务类别（coding/writing/analysis/translation/long_doc/general），驱动知识库适配度 |
| `X-Oasis-Goal` | 调度目标：cheapest / fastest / best / balanced |
| `X-Oasis-Session` | 粘性会话：多轮对话钉在同一账户（回退成功后自动重钉） |

## 调度原理

1. **硬约束一票否决**：禁用 / 熔断开 / RPM 窗口满 / 月度预算不足 / 日限到 /
   模型不服务 / 上下文不够
2. **加权评分**：`fit(知识库) × cost(账本) × latency(EMA) × load(在途)`，
   权重来自 goal；同分按路由表顺序稳定决胜
3. **回退链**：429/5xx/断流 → 换下一个账户（非流式重试、流式首 token 前重试）
4. **无缝切换**：流式中途死亡 → 把已生成文本作为 assistant 前缀发给下一账户
   续写 → 公共前缀裁剪去重 → 客户端零重复；决策日志记录双段尝试与原因
5. **实时信号**：时延 EMA、错误率熔断（闭→开 30s→半开探测）、RPM 窗口、
   在途并发——全部 ETS 式共享状态，actor 崩溃重启不丢

## 配置要点

- 金额一律 **nano-dollars 整数**（$0.15/1M tokens = `in_price_nano = 150`）
- 密钥走环境变量（`api_key_env`），不落配置
- 每账户可配代理 base_url；`oasis reload` / `POST /api/reload` 热加载
- 数据（账本 JSONL）默认 `./.oasis-data`，`[server] data_dir` 可改

## 无 key 演示（全链路含无缝切换）

```bash
oasis-mock --port 9911 --sse "你好，我是" --cut 134   # 上游 A：流一半配额死
oasis-mock --port 9912 --sse "你好，我是 Oasis 门户——无缝切换演示成功！"
oasis --config oasis-demo.toml                          # 账户指向两个 mock
oasis ask "你是谁" --stream                             # 观察零重复的接力输出
```

## 验证

```bash
riot test -p portal     # 29 个测试（含端到端场景：路由/回退/流式/无缝切换/粘性）
riot bench -p portal    # 7 个基准（调度评分 ~33µs/决策）
oasis --self-test       # 一条命令跑完整全链路自检
bash scripts/build-release.sh   # release 打包到 dist/
```

## 架构

```
OasisRoot (OneForOne)
├─ ConfigActor(快照) · LedgerActor(账本) · Signals(实时信号/熔断)
├─ SchedulerActor: 硬约束 → 加权评分 → 回退链
├─ ProviderSupervisor ─ 每账户 AccountActor (Permanent, 自愈)
└─ Gateway (Nomad+Trail): OpenAI 兼容 API + SSE 流 + 仪表盘 + WS
   └─ 每流式请求一个 Conductor actor: 上游在阻塞道(spawn_blocked)逐 chunk 转发
      · leg_id 防串扰 · Handoff 拼接去重 · [DONE] 前等腿结束保证干净收尾
```
