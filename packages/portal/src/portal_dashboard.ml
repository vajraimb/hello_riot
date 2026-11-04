(** Embedded dashboard page (HTML/JS, no logic). *)

let index_html =
  {|<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8" />
<title>Oasis — 个人 AI 账户门户</title>
<style>
:root{--bg:#0b1020;--card:#141c33;--border:#263354;--accent:#38bdf8;--green:#22c55e;--red:#ef4444;--amber:#f59e0b;--text:#e2e8f0}
*{box-sizing:border-box;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,monospace}
body{margin:0;padding:20px;background:var(--bg);color:var(--text)}
h1{margin:0 0 4px 0;font-size:20px;color:var(--accent)}
.sub{color:#94a3b8;font-size:12px;margin-bottom:16px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:14px;margin-bottom:14px}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:14px}
.card h2{margin:0 0 10px 0;font-size:14px;color:#cbd5e1;border-bottom:1px solid var(--border);padding-bottom:8px}
.badge{padding:2px 7px;border-radius:4px;font-size:11px;font-weight:600}
.ok{background:rgba(34,197,94,.18);color:var(--green)}
.warn{background:rgba(245,158,11,.2);color:var(--amber)}
.bad{background:rgba(239,68,68,.2);color:var(--red)}
table{width:100%;border-collapse:collapse;font-size:12px}
th,td{text-align:left;padding:6px 5px;border-bottom:1px solid #1e293b;vertical-align:top}
th{color:#94a3b8}
.row{display:flex;gap:8px;margin-bottom:8px;align-items:center;flex-wrap:wrap}
input,select,button{background:#0f172a;border:1px solid var(--border);color:var(--text);padding:6px 8px;border-radius:5px;font-size:12px}
button{background:#1e293b;border-color:var(--accent);cursor:pointer}
button:hover{background:var(--accent);color:#0b1020;font-weight:600}
button.danger{border-color:var(--red);color:#fca5a5}
button.danger:hover{background:var(--red);color:#fff}
pre{background:#070b16;padding:8px;border-radius:6px;font-size:12px;margin:6px 0 0 0;overflow-x:auto;white-space:pre-wrap;min-height:30px}
#log{height:240px;overflow-y:auto;background:#070b16;border:1px solid var(--border);border-radius:6px;padding:10px;font-size:12px;line-height:1.5}
.handoff{color:var(--amber);font-weight:600}

@keyframes node-pop { from { transform: scale(0); opacity: 0; } to { transform: scale(1); opacity: 1; } }
@keyframes node-pulse { 0% { r: 12; } 50% { r: 19; } 100% { r: 12; } }
@keyframes node-fail { 0%,100% { transform: translateX(0); } 25% { transform: translateX(-3px); } 75% { transform: translateX(3px); } }
@keyframes edge-grow { from { stroke-dashoffset: 300; } to { stroke-dashoffset: 0; } }
.gnode { transform-box: fill-box; transform-origin: center; animation: node-pop .35s ease-out both; }
.gnode.soma circle { fill: url(#soma-fill); }
.gnode.soma.cand circle { fill: url(#soma-cand); }
.gnode.soma.glow circle { filter: url(#soma-glow); }
.gnode.soma.ok circle { fill: url(#soma-ok); }
.gnode.soma.fail circle { fill: url(#soma-fail); }
.gnode.pulse circle { animation: node-pulse 1s ease-in-out infinite; }
.gnode.done circle { fill: var(--green); }
.gnode.failed { animation: node-fail .3s ease-in-out 2; }
.gnode.failed circle { fill: var(--red); }
.gedge { stroke-dasharray: 300; animation: edge-grow .5s ease-out both; }
.gedge.fallback { stroke-dasharray: 6 5; stroke: var(--amber); }
.gedge.chosen { stroke: #38bdf8; stroke-width: 2.5; }
.gedge.rejected { stroke: #7f1d1d; stroke-dasharray: 6 5; }
.gedge.handoff { stroke-dasharray: none; stroke-width: 2.5; }
#graph-box { background:#070b16; border:1px solid var(--border); border-radius:8px; overflow-x:auto; min-height:200px; }
#graph-box svg { min-width: 760px; }
</style>
</head>
<body>
<h1>Oasis — 个人 AI 账户门户</h1>
<div class="sub">多账户实时调度 · 可解释路由 · 流式中途配额耗尽无缝切换（Atacama + Nomad + Trail · Riot/OCaml）</div>
<div class="grid">
  <div class="card">
    <h2>账户实时状态 <span id="ws-status" class="badge warn">WS 连接中</span></h2>
    <div id="accounts-box" style="font-size:12px;line-height:1.8;">加载中...</div>
  </div>
  <div class="card">
    <h2>快速提问（走门户调度）</h2>
    <div class="row">
      <input id="prompt" value="用一句话解释无缝切换" style="flex:1" />
    </div>
    <div class="row">
      <select id="category">
        <option value="coding">coding</option>
        <option value="writing">writing</option>
        <option value="analysis">analysis</option>
        <option value="general" selected>general</option>
      </select>
      <select id="goal">
        <option value="balanced" selected>balanced</option>
        <option value="cheapest">cheapest</option>
        <option value="fastest">fastest</option>
        <option value="best">best</option>
      </select>
      <label style="font-size:12px"><input type="checkbox" id="stream" checked /> 流式</label>
      <button onclick="ask()">发送</button>
    </div>
    <pre id="answer">就绪</pre>
  </div>
</div>
<div class="card">
  <h2>实时路由决策（含无缝切换事件）</h2>
  <div id="log"><div>等待决策...</div></div>
</div>


<div class="card" style="margin-bottom:14px">
  <h2>任务过程图（实时）<span id="graph-summary" style="color:#94a3b8;font-weight:400"></span></h2>
  <div id="graph-box"></div>
</div>
<div class="grid">
  <div class="card">
    <h2>本机 Agent 盘点 <button onclick="refreshAgents()" style="float:right">刷新</button></h2>
    <div id="agents-box" style="font-size:12px;line-height:1.9;">加载中...</div>
  </div>
  <div class="card">
    <h2>Agent 活动时间线 <button onclick="refreshActivity()" style="float:right">刷新</button></h2>
    <div id="activity-box" style="font-size:12px;line-height:1.9;max-height:260px;overflow-y:auto;">加载中...</div>
  </div>
  <div class="card">
    <h2>消息总线（收件箱） <button onclick="refreshInbox()" style="float:right">刷新</button></h2>
    <div id="inbox-box" style="font-size:12px;line-height:1.9;">加载中...</div>
    <div class="row" style="margin-top:8px">
      <input id="reply-to" placeholder="回复给 agent (如 claude_code)" style="flex:1" />
      <input id="reply-text" placeholder="回复内容" style="flex:2" />
      <button onclick="sendReply()">回复</button>
    </div>
  </div>
</div>
<script>
const oasisToken = (() => {
  const u = new URL(location.href);
  const t = u.searchParams.get('token');
  if (t) {
    localStorage.setItem('oasis_token', t);
    u.searchParams.delete('token');
    history.replaceState(null, '', u.pathname + u.search + u.hash);
  }
  return localStorage.getItem('oasis_token') || '';
})();
const rawFetch = window.fetch.bind(window);
window.fetch = async (url, opts = {}) => {
  const headers = new Headers(opts.headers || {});
  if (oasisToken) headers.set('Authorization', 'Bearer ' + oasisToken);
  const res = await rawFetch(url, { ...opts, headers });
  if (res.status === 401) {
    const t = prompt('Oasis 需要访问令牌（server.auth_token_env）');
    if (t) { localStorage.setItem('oasis_token', t.trim()); location.reload(); }
  }
  return res;
};
const log = document.getElementById('log');
function addLine(msg, cls) {
  const div = document.createElement('div');
  div.textContent = '[' + new Date().toLocaleTimeString() + '] ' + msg;
  if (cls) div.className = cls;
  log.prepend(div);
  while (log.children.length > 100) log.removeChild(log.lastChild);
}
async function refreshAccounts() {
  const res = await fetch('/api/accounts');
  const data = await res.json();
  const box = document.getElementById('accounts-box');
  box.innerHTML = '';
  for (const a of data.accounts) {
    const brk = a.breaker === 'closed'
      ? '<span class="badge ok">closed</span>'
      : '<span class="badge bad">' + a.breaker + '</span>';
    const line = document.createElement('div');
    line.innerHTML = '<b>' + a.name + '</b> (' + a.provider + ') ' + brk +
      ' | 时延EMA <b>' + a.latency_ema_ms + 'ms</b> | 在途 ' + a.in_flight +
      ' | 今日 ' + a.day_requests + '/' + (a.daily_limit || '∞') +
      ' | 本月 <b>' + a.month_spent_usd + '</b> / ' + a.month_budget_usd +
      ' | 模型: ' + (a.models || []).join(', ');
    box.appendChild(line);
  }
}
async function ask() {
  const out = document.getElementById('answer');
  out.textContent = '';
  gReset({ category: document.getElementById('category').value, goal: document.getElementById('goal').value });
  document.getElementById('graph-summary').textContent = '已发出，等待路由…';
  const body = JSON.stringify({
    model: null,
    messages: [{ role: 'user', content: document.getElementById('prompt').value }],
    max_tokens: 2048,
    stream: document.getElementById('stream').checked
  });
  const headers = {
    'Content-Type': 'application/json',
    'X-Oasis-Category': document.getElementById('category').value,
    'X-Oasis-Goal': document.getElementById('goal').value
  };
  if (document.getElementById('stream').checked) {
    const res = await fetch('/v1/chat/completions', { method: 'POST', headers, body });
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split('\n');
      buf = lines.pop();
      for (const line of lines) {
        if (line.startsWith('data: ')) {
          const payload = line.slice(6);
          if (payload === '[DONE]') { out.textContent += '\n— 完成 —'; continue; }
          try {
            const j = JSON.parse(payload);
            const c = j.choices?.[0]?.delta?.content || '';
            out.textContent += c;
          } catch (e) {}
        }
      }
    }
  } else {
    const res = await fetch('/v1/chat/completions', { method: 'POST', headers, body });
    const j = await res.json();
    out.textContent = j.choices?.[0]?.message?.content || JSON.stringify(j);
  }
  refreshAccounts();
}
async function refreshDecisions() {
  const res = await fetch('/api/decisions');
  const data = await res.json();
  const ds = data.decisions || [];
  log.innerHTML = '<div>等待决策...</div>';
  for (const d of ds.slice(0, 20).reverse()) {
    const attempts = (d.attempts || []).map(a =>
      a.account + '(' + (a.status != null ? a.status : (a.error || '?')) + ':' + a.latency_ms + 'ms)'
    ).join(' → ');
    const handoff = handoffSummary(d);
    const rejected = (d.rejected || []).map(r => r.account + '✗' + r.reason).join(' ');
    const scores = (d.scores || []).map(s => s.account + ':' + s.score).join(' ');
    addLine(d.task_category + ' → ' + (d.chosen || '无') + handoff +
      ' | attempts: ' + attempts +
      (rejected ? ' | 拒绝: ' + rejected : '') +
      ' | scores: ' + scores, handoff ? 'handoff' : null);
  }
}
function handoffLabel(h) {
  return h.level + ' · ' + h.matched_bytes + '/' + h.sent_bytes + 'B' + (h.diverged ? ' · 分叉' : '');
}
function handoffSummary(d) {
  const hs = d.handoffs || [];
  if (hs.length) return ' [handoff ' + hs.map(h => h.from + '→' + h.to + ' ' + handoffLabel(h)).join(', ') + ']';
  return (d.attempts || []).length > 1 ? ' [回退]' : '';
}
const ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws' + (oasisToken ? '?token=' + encodeURIComponent(oasisToken) : ''));
ws.onopen = () => {
  const st = document.getElementById('ws-status');
  st.textContent = 'WS 已连接';
  st.className = 'badge ok';
};
const NS = 'http://www.w3.org/2000/svg';
const graphBox = document.getElementById('graph-box');
const GW = 900, GH = 400;
const HANDOFF_COLORS = { G1: '#22c55e', G2: '#f59e0b', G3: '#a78bfa', G0: '#ef4444' };
let graph = { req: null, candidates: [], attempts: [], svg: null };

function svgEl(tag, attrs, parent) {
  const e = document.createElementNS(NS, tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (parent) parent.appendChild(e);
  return e;
}
function shortName(s, n) { return s.length > n ? s.slice(0, n - 1) + '…' : s; }
function hashJitter(s) { let h = 0; for (const ch of s) h = h * 31 + ch.charCodeAt(0) | 0; return (h % 13 - 6) * 6; }
function gReset(req) {
  graph = { req, candidates: [], attempts: [], svg: null };
  graphBox.innerHTML = '';
  const svg = svgEl('svg', { width: '100%', height: '100%', viewBox: '0 0 ' + GW + ' ' + GH, style: 'min-height:400px' }, graphBox);
  graph.svg = svg;
  const defs = svgEl('defs', {}, svg);
  const glow = svgEl('filter', { id: 'soma-glow', x: '-50%', y: '-50%', width: '200%', height: '200%' }, defs);
  svgEl('feGaussianBlur', { stdDeviation: '3.2', result: 'b' }, glow);
  const mg = svgEl('feMerge', {}, glow);
  svgEl('feMergeNode', { in: 'b' }, mg);
  svgEl('feMergeNode', { in: 'SourceGraphic' }, mg);
  const mk = (id, c1, c2) => {
    const g = svgEl('radialGradient', { id, cx: '35%', cy: '30%' }, defs);
    svgEl('stop', { offset: '0%', 'stop-color': c1 }, g);
    svgEl('stop', { offset: '100%', 'stop-color': c2 }, g);
  };
  mk('soma-fill', '#67e8f9', '#0369a1');
  mk('soma-ok', '#86efac', '#15803d');
  mk('soma-fail', '#fca5a5', '#b91c1c');
  mk('soma-cand', '#cbd5e1', '#475569');
  for (const lv in HANDOFF_COLORS) {
    const m = svgEl('marker', { id: 'ho-' + lv, viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, defs);
    svgEl('path', { d: 'M 0 0 L 10 5 L 0 10 z', fill: HANDOFF_COLORS[lv] }, m);
  }
  // task node
  const g = svgEl('g', { class: 'gnode soma glow' }, svg);
  svgEl('circle', { cx: GW / 2, cy: 44, r: 16 }, g);
  svgEl('text', { x: GW / 2, y: 78, 'text-anchor': 'middle', fill: '#e2e8f0', 'font-size': 14 }, g)
    .textContent = '任务 · ' + (req.category || 'general');
  svgEl('text', { x: GW / 2, y: 96, 'text-anchor': 'middle', fill: '#94a3b8', 'font-size': 11 }, g)
    .textContent = 'goal=' + (req.goal || '-');
  graph.root = { name: 'task', x: GW / 2, y: 44 };
}
function gEdge(x1, y1, x2, y2, kind) {
  let d;
  if (kind === 'feedback') {
    const n = Math.min(x1, x2) - 110;
    d = 'M ' + x1 + ' ' + y1 + ' C ' + n + ' ' + y1 + ', ' + n + ' ' + y2 + ', ' + x2 + ' ' + y2;
  } else {
    const j = hashJitter(String(x2) + kind);
    const r = Math.max(28, Math.abs(y2 - y1) * 0.5);
    d = 'M ' + x1 + ' ' + y1 + ' C ' + (x1 + j) + ' ' + (y1 + r) + ', ' + (x2 - j) + ' ' + (y2 - r) + ', ' + x2 + ' ' + y2;
  }
  return svgEl('path', {
    d, fill: 'none', stroke: '#475569', 'stroke-width': 2,
    class: 'gedge' + (kind === 'feedback' ? ' fallback' : '')
  }, graph.svg);
}
function gNode(x, y, label, opts) {
  opts = opts || {};
  const svg = graph.svg;
  const g = svgEl('g', { class: 'gnode soma' + (opts.cls ? ' ' + opts.cls : '') }, svg);
  svgEl('circle', { cx: x, cy: y, r: 14, stroke: 'rgba(148,163,184,.35)', 'stroke-width': 1.5 }, g);
  svgEl('text', { x, y: y + 31, 'text-anchor': 'middle', fill: '#e2e8f0', 'font-size': 12 }, g)
    .textContent = shortName(label, 14);
  if (opts.sub) {
    svgEl('text', { x, y: y + 46, 'text-anchor': 'middle', fill: opts.subColor || '#94a3b8', 'font-size': 10 }, g)
      .textContent = opts.sub;
  }
  if (opts.mark) {
    svgEl('text', { x: x + 16, y: y - 12, 'text-anchor': 'middle', fill: opts.markColor || '#22c55e', 'font-size': 13, 'font-weight': 'bold' }, g)
      .textContent = opts.mark;
  }
  return g;
}
function gEdgeTo(e1, e2, kind) { gEdge(e1.x, e1.y, e2.x, e2.y, kind); }
function gHandoff(h) {
  const from = graph.attempts.filter(t => t.name === h.from && t.finished).pop();
  const to = graph.attempts.filter(t => t.name === h.to && t !== from).pop();
  if (!from || !to) return;
  const color = HANDOFF_COLORS[h.level] || HANDOFF_COLORS.G0;
  const lift = 70 + 12 * Math.abs(graph.attempts.indexOf(to) - graph.attempts.indexOf(from));
  const y1 = from.y - 16, y2 = to.y - 16;
  svgEl('path', {
    d: 'M ' + from.x + ' ' + y1 + ' C ' + from.x + ' ' + (y1 - lift) + ', ' + to.x + ' ' + (y2 - lift) + ', ' + to.x + ' ' + y2,
    fill: 'none', stroke: color, class: 'gedge handoff', 'marker-end': 'url(#ho-' + (HANDOFF_COLORS[h.level] ? h.level : 'G0') + ')'
  }, graph.svg);
  const mid = svgEl('text', { x: (from.x + to.x) / 2, y: Math.min(y1, y2) - lift * 0.75 - 4, 'text-anchor': 'middle', fill: color, 'font-size': 11, 'font-weight': 600 }, graph.svg);
  mid.textContent = 'handoff ' + h.level + (h.model_changed ? ' · 换模型' : '');
  const ann = svgEl('g', {}, graph.svg);
  svgEl('text', { x: to.x, y: to.y + 62, 'text-anchor': 'middle', fill: color, 'font-size': 10 }, ann)
    .textContent = '前缀 ' + h.matched_bytes + '/' + h.sent_bytes + 'B';
  svgEl('text', { x: to.x, y: to.y + 75, 'text-anchor': 'middle', fill: h.diverged ? '#f97316' : '#22c55e', 'font-size': 10 }, ann)
    .textContent = h.diverged ? '分叉（去重止于分叉点）' : '前缀一致';
}
function onEvent(ev) {
  if (!ev || !ev.data) return;
  if (ev.event === 'task_started') {
    gReset({ category: ev.data.category, goal: ev.data.goal });
    graph.requestId = ev.request_id;
    document.getElementById('graph-summary').textContent = '路由中…';
    return;
  }
  // concurrent requests interleave on the socket: the graph follows the latest task only
  if (!graph.svg || ev.request_id !== graph.requestId) return;
  if (ev.event === 'routed') {
    const cands = (ev.data.candidates || []).slice(0, 6);
    const rejs = (ev.data.rejected || []).slice(0, 3);
    const total = cands.length + rejs.length;
    const y = 165;
    const xOf = i => 60 + (i + 0.5) * ((GW - 120) / Math.max(total, 1));
    cands.forEach((cd, i) => {
      const x = xOf(i);
      const chosen = cd.name === ev.data.chosen;
      const nd = gNode(x, y, cd.name, {
        cls: chosen ? 'glow' : 'cand',
        sub: 'score=' + cd.score
      });
      gEdgeTo(graph.root, { x, y }, 'cand');
      graph.candidates.push({ name: cd.name, g: nd, x, y });
    });
    rejs.forEach((r, j) => {
      const x = xOf(cands.length + j);
      gNode(x, y, r.name, { cls: 'fail', sub: r.reason, subColor: '#ef4444', mark: '✗', markColor: '#ef4444' });
      gEdgeTo(graph.root, { x, y }, 'rej');
    });
    if (ev.data.chosen) document.getElementById('graph-summary').textContent = '→ 选中 ' + ev.data.chosen;
  } else if (ev.event === 'attempt_started') {
    const i = graph.attempts.length;
    const y = 300;
    const x = 120 + i * 165;
    const nd = gNode(x, y, ev.data.account, { cls: 'glow', sub: '执行中…' });
    nd.setAttribute('data-account', ev.data.account);
    const from = graph.candidates.find(t => t.name === ev.data.account) || graph.root;
    if (i === 0) gEdgeTo(from, { x, y }, 'dep');
    else {
      const prev = graph.attempts[graph.attempts.length - 1];
      gEdgeTo({ x: prev.x, y: prev.y }, { x, y }, 'feedback');
    }
    graph.attempts.push({ name: ev.data.account, g: nd, x, y });
  } else if (ev.event === 'attempt_finished') {
    const open = graph.attempts.filter(t => t.name === ev.data.account && !t.finished);
    const t = open[open.length - 1];
    if (t) {
      t.finished = true;
      t.g.remove();
      if (ev.data.status === 200) {
        gNode(t.x, t.y, t.name, { cls: 'ok', sub: ev.data.latency_ms + 'ms', subColor: '#22c55e', mark: '✓', markColor: '#22c55e' });
      } else {
        gNode(t.x, t.y, t.name, { cls: 'fail', sub: ev.data.error || ('HTTP ' + ev.data.status), subColor: '#ef4444', mark: '✗', markColor: '#ef4444' });
      }
    }
  } else if (ev.event === 'handoff') {
    gHandoff(ev.data);
    document.getElementById('graph-summary').textContent = 'handoff ' + ev.data.from + ' → ' + ev.data.to + '（' + handoffLabel(ev.data) + '）';
  } else if (ev.event === 'task_done') {
    const ok = ev.data.ok;
    document.getElementById('graph-summary').textContent = ok
      ? '✓ 完成 — ' + ev.data.chosen + '（' + ev.data.attempts + ' 次尝试）'
      : '✗ 未完成 — 已尝试 ' + ev.data.attempts + ' 次';
  }
}

ws.onmessage = (ev) => {
  try {
    const j = JSON.parse(ev.data);
    if (j.type === 'event') {
      onEvent(j);
    }
    if (j.type === 'decision') {
      const d = j.decision;
      const attempts = (d.attempts || []).map(a =>
        a.account + '(' + (a.status != null ? a.status : (a.error || '?')) + ')'
      ).join(' → ');
      const handoff = handoffSummary(d);
      addLine(d.task_category + ' → ' + (d.chosen || '无') + handoff + ' | attempts: ' + attempts, handoff ? 'handoff' : null);
      refreshAccounts();
    }
  } catch (e) {}
};
ws.onclose = () => {
  const st = document.getElementById('ws-status');
  st.textContent = 'WS 断开(轮询兜底)';
  st.className = 'badge warn';
};
async function refreshAgents() {
  const res = await fetch('/api/agents');
  const data = await res.json();
  const box = document.getElementById('agents-box');
  const rows = (data.agents || []).map(a => {
    const i = a.installed ? '<span class="badge ok">已装</span>' : '<span class="badge bad">未装</span>';
    const l = a.logged_in ? '<span class="badge ok">已登录</span>' : '<span class="badge warn">未登录</span>';
    const act = a.active ? '<span class="badge ok">活跃</span>' : '';
    const projs = (a.projects || []).slice(0, 2).join(', ');
    return '<div>' + a.name + ' ' + i + ' ' + l + ' ' + act +
      (projs ? ' <span style="color:#94a3b8">' + projs + '</span>' : '') + '</div>';
  });
  box.innerHTML = rows.join('');
}
async function refreshActivity() {
  const res = await fetch('/api/activity');
  const data = await res.json();
  const box = document.getElementById('activity-box');
  const rows = (data.sessions || []).map(s =>
    '<div style="border-bottom:1px solid #1e293b;padding:4px 0"><div style="color:#cbd5e1">' + s.project +
    ' <span class="badge warn">' + s.turns + ' 轮</span>' +
    (s.tools ? ' <span class="badge ok">' + s.tools + ' 工具</span>' : '') + '</div>' +
    '<div style="color:#94a3b8">' + (s.last_excerpt || '') + '</div></div>'
  );
  box.innerHTML = rows.length ? rows.join('') : '暂无活动记录';
}
async function refreshInbox() {
  const res = await fetch('/api/inbox');
  const data = await res.json();
  const box = document.getElementById('inbox-box');
  const rows = (data.inboxes || []).map(i =>
    '<div>' + i.agent + ': ' + (i.unread > 0
      ? '<span class="badge ok">' + i.unread + ' 未读</span>'
      : '<span class="badge warn">0</span>') + '</div>'
  );
  box.innerHTML = rows.join('');
}
async function sendReply() {
  const to = document.getElementById('reply-to').value.trim();
  const text = document.getElementById('reply-text').value.trim();
  if (!to || !text) { alert('填写回复对象和内容'); return; }
  await fetch('/api/inbox/reply', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ to_agent: to, text })
  });
  document.getElementById('reply-text').value = '';
  refreshInbox();
  addLine('已回复 ' + to);
}
refreshAgents();
refreshActivity();
refreshInbox();
setInterval(refreshInbox, 5000);
setInterval(refreshAgents, 10000);
setInterval(refreshActivity, 10000);
refreshAccounts();
refreshDecisions();
setInterval(refreshAccounts, 3000);
</script>
</body>
</html>|}
