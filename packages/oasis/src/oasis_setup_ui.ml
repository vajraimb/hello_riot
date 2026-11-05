(** The setup wizard: an overlay on the dashboard that lists what this
    machine has (accounts, keys, Ollama, agent CLIs), verifies each one
    live, and saves the ticked choices through [/api/setup/apply]. Shown
    automatically until setup has been saved once. *)

let html =
  {|<div class="su-back" id="su-back" hidden>
<div class="su" role="dialog" aria-modal="true" aria-labelledby="su-title">
  <div class="su-head">
    <div><div class="su-title" id="su-title"></div><div class="su-sub" id="su-sub"></div></div>
    <button class="su-lang" id="su-lang"></button>
    <button class="su-x" id="su-x" aria-label="close">✕</button>
  </div>
  <div class="su-body" id="su-body"><div class="su-loading" id="su-loading"></div></div>
  <div class="su-foot">
    <div class="su-sum" id="su-sum"></div>
    <button class="run" id="su-save"></button>
  </div>
</div>
</div>
<style>
.su-back{position:fixed;inset:0;background:rgba(5,7,10,.72);display:flex;align-items:center;justify-content:center;z-index:50}
.su-back[hidden]{display:none}
.su{width:min(860px,94vw);max-height:90vh;display:flex;flex-direction:column;background:var(--panel);border:1px solid var(--line2);border-radius:10px;box-shadow:0 20px 60px rgba(0,0,0,.5)}
.su-head{display:flex;align-items:flex-start;gap:10px;padding:16px 18px 12px;border-bottom:1px solid var(--line)}
.su-head>div{flex:1}
.su-title{font-size:16px;font-weight:600}
.su-sub{color:var(--muted);font-size:12.5px;margin-top:3px}
.su-x,.su-lang{background:none;border:1px solid var(--line2);border-radius:5px;color:var(--muted);cursor:pointer;padding:2px 8px;font-size:12px}
.su-x:hover,.su-lang:hover{color:var(--text);border-color:var(--accent)}
.su-body{overflow-y:auto;padding:6px 18px 14px}
.su-loading{color:var(--muted);padding:30px 0;text-align:center}
.su-sec{margin-top:14px}
.su-sec h4{margin:0 0 6px;font-size:11.5px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted);font-weight:600;display:flex;align-items:center;gap:8px}
.su-sec h4 span{text-transform:none;letter-spacing:0;font-weight:400;color:var(--dim)}
.su-row{display:grid;grid-template-columns:22px 1fr auto;gap:4px 10px;align-items:center;padding:8px 10px;border:1px solid var(--line);border-radius:7px;margin-bottom:6px;background:var(--panel2)}
.su-row.off{opacity:.55}
.su-row input[type=checkbox]{width:15px;height:15px;accent-color:var(--accent);margin:0}
.su-name{font-weight:600}
.su-name small{font-weight:400;color:var(--muted);margin-left:6px;font-family:var(--mono);font-size:11px}
.su-meta{grid-column:2/4;color:var(--muted);font-size:11.5px;display:flex;flex-wrap:wrap;gap:4px 12px}
.su-meta code{font-family:var(--mono);font-size:11px}
.su-badge{font-size:11px;padding:1px 7px;border-radius:10px;white-space:nowrap;border:1px solid var(--line2);color:var(--muted)}
.su-badge.ok{color:var(--ok);border-color:rgba(63,185,80,.4);background:rgba(63,185,80,.08)}
.su-badge.warn{color:var(--warn,#d29922);border-color:rgba(210,153,34,.4);background:rgba(210,153,34,.08)}
.su-badge.err{color:var(--err);border-color:rgba(248,81,73,.4);background:rgba(248,81,73,.08)}
.su-badge.run{color:var(--accent2)}
.su-key{grid-column:2/4;display:flex;gap:6px;margin-top:2px}
.su-key input{flex:1;background:var(--bg);border:1px solid var(--line2);border-radius:5px;padding:5px 8px;font-family:var(--mono);font-size:12px;color:var(--text);outline:none}
.su-key input:focus{border-color:var(--accent)}
.su-key a{color:var(--accent2);font-size:12px;align-self:center;white-space:nowrap;text-decoration:none}
.su-hint{grid-column:2/4;font-size:11.5px;color:var(--muted)}
.su-hint code{font-family:var(--mono);background:var(--bg);padding:0 5px;border-radius:3px;color:var(--text);user-select:all}
.su-more{color:var(--accent2);cursor:pointer;font-size:12px;background:none;border:0;padding:4px 0}
.su-goal{display:flex;gap:6px;flex-wrap:wrap}
.su-goal button{background:var(--panel2);border:1px solid var(--line2);border-radius:6px;padding:6px 12px;color:var(--muted);cursor:pointer;font:inherit}
.su-goal button.on{border-color:var(--accent);color:var(--text);background:rgba(91,140,255,.12)}
.su-foot{display:flex;align-items:center;gap:12px;padding:12px 18px;border-top:1px solid var(--line)}
.su-sum{flex:1;color:var(--muted);font-size:12.5px}
.su-empty{color:var(--dim);font-size:12px;padding:4px 2px 8px}
</style>
<script>
(() => {
  const T = {
    zh: {
      title: '配置 Oasis', sub: '勾选要用的账户和 agent，保存后立即生效。Oasis 已经替你探测并实测了一遍。',
      lang: 'EN', loading: '正在探测本机…', accounts: 'API 账户', accountsHint: '已在配置里的账户与新发现的 key',
      found: '新发现', more: '添加其他服务商', less: '收起', agents: '本机 Agent', agentsHint: '需要工具的任务交给它们执行',
      goal: '调度目标', save: '保存并开始', saving: '保存中…', saved: '已保存，Oasis 已按新配置运行',
      none: '没有发现。', paste: '粘贴 API key', verify: '验证', getKey: '获取 key',
      st: { checking: '验证中…', ok: '可用', rate_limited: '可用（正在限流）', no_balance: '额度已用完', invalid_key: 'key 无效', model_error: '模型不可用', unreachable: '连不上', no_key: '缺少 key' },
      keyFrom: { env: '来自环境变量', secrets: '来自 secrets.env' }, newKey: '保存到 ~/.oasis/secrets.env',
      installed: '已安装', loggedIn: '已登录', notLoggedIn: '未登录，先运行', notInstalled: '未安装，安装命令', custom: '自定义',
      local: '本机模型', cloud: '云端模型', ollamaOff: 'Ollama 没有运行', models: '模型',
      goals: { balanced: '均衡', fastest: '最快', best: '质量优先', cheapest: '最省钱' },
      sum: (a, g) => `将启用 ${a} 个账户、${g} 个 agent`, nothing: '至少选一个账户或 agent', failed: '保存失败：',
      observeTitle: '读取应用里的用量',
      observeHint: '你打开 Cursor、Claude、Codex、Gemini、Kimi、Grok、ZCode、DeepSeek Harness、WorkBuddy、Perplexity 这些应用，并且画面上已经显示档位、用量、token 总数、剩余额度或重置时间时，允许 Oasis 记下来。大约每 15 分钟看一次，不会自己去点开它们，也只保存这几项，不保存聊天内容。',
      setup: '设置',
    },
    en: {
      title: 'Set up Oasis', sub: 'Tick the accounts and agents to use. Changes apply as soon as you save; Oasis has already detected and tested what it found.',
      lang: '中文', loading: 'Scanning this machine…', accounts: 'API accounts', accountsHint: 'configured accounts and newly found keys',
      found: 'found', more: 'Add another provider', less: 'Hide', agents: 'Local agents', agentsHint: 'they run tasks that need tools',
      goal: 'Routing goal', save: 'Save & start', saving: 'Saving…', saved: 'Saved. Oasis is running with the new setup',
      none: 'Nothing found.', paste: 'Paste API key', verify: 'Verify', getKey: 'Get a key',
      st: { checking: 'Checking…', ok: 'Works', rate_limited: 'Works (rate limited)', no_balance: 'Out of quota', invalid_key: 'Invalid key', model_error: 'Model unavailable', unreachable: 'Unreachable', no_key: 'No key' },
      keyFrom: { env: 'from environment', secrets: 'from secrets.env' }, newKey: 'saved to ~/.oasis/secrets.env',
      installed: 'installed', loggedIn: 'logged in', notLoggedIn: 'not logged in, run', notInstalled: 'not installed, install with', custom: 'custom',
      local: 'local models', cloud: 'cloud models', ollamaOff: 'Ollama is not running', models: 'models',
      goals: { balanced: 'Balanced', fastest: 'Fastest', best: 'Best quality', cheapest: 'Cheapest' },
      sum: (a, g) => `${a} account${a === 1 ? '' : 's'} and ${g} agent${g === 1 ? '' : 's'} will be on`, nothing: 'Pick at least one account or agent', failed: 'Save failed: ',
      observeTitle: 'Read usage shown in agent apps',
      observeHint: 'When Cursor, Claude, Codex, Gemini, Kimi, Grok, ZCode, DeepSeek Harness, WorkBuddy, or Perplexity is open and the screen already shows the plan, usage, a token total, a remaining credit balance, or a reset time, Oasis may record it. It looks about every 15 minutes, does not open those apps, and keeps only those figures, not the chat.',
      setup: 'Setup',
    },
  };
  let lang = localStorage.getItem('oasis_lang') || ((navigator.language || '').toLowerCase().startsWith('zh') ? 'zh' : 'en');
  const t = () => T[lang];
  const el = id => document.getElementById(id);
  const h = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const GOOD = ['ok', 'rate_limited', 'no_balance'];
  const badgeClass = s => s === 'ok' || s === 'rate_limited' ? 'ok' : s === 'no_balance' ? 'warn' : s === 'checking' ? 'run' : 'err';

  let scan = null, rows = [], goal = 'balanced', showMore = false, observe = false;

  const post = (url, body) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }).then(r => r.json());

  function buildRows() {
    rows = [];
    for (const a of scan.accounts) {
      rows.push({ kind: 'account', id: 'acc:' + a.name, a, on: a.enabled, status: a.local ? 'checking' : (a.key_env && !a.key_source ? 'no_key' : 'checking'), key: '' });
    }
    for (const p of scan.providers) {
      if (p.configured.length || !p.candidates.length) continue;
      rows.push({ kind: 'found', id: 'prov:' + p.pid, p, on: false, status: 'checking', env: p.candidates[0].env, key: '' });
    }
    const hasOllama = scan.accounts.some(a => a.local);
    if (scan.ollama.running && !hasOllama) rows.push({ kind: 'ollama', id: 'ollama', on: false, status: 'checking', local: [], cloud: [] });
    for (const p of scan.providers) {
      if (p.configured.length || p.candidates.length) continue;
      rows.push({ kind: 'extra', id: 'prov:' + p.pid, p, on: false, status: '', env: p.env_name, key: '' });
    }
    for (const g of scan.agents) {
      rows.push({ kind: 'agent', id: 'agt:' + g.aid, g, on: g.configured ? g.enabled : (g.installed), status: '' });
    }
    for (const o of scan.other_agents) rows.push({ kind: 'other', id: 'oth:' + o.name, o, on: o.enabled, status: '' });
  }

  const row = id => rows.find(r => r.id === id);

  async function verify(r) {
    r.status = 'checking'; render();
    let res;
    try {
      if (r.kind === 'account') res = await post('/api/setup/verify', r.key ? { account: r.a.name, key: r.key } : { account: r.a.name });
      else if (r.kind === 'ollama') res = await post('/api/setup/verify', { provider: 'ollama' });
      else if (r.key) res = await post('/api/setup/verify', { provider: r.p.pid, key: r.key });
      else {
        for (const c of r.p.candidates) {
          res = await post('/api/setup/verify', { provider: r.p.pid, env: c.env });
          r.env = c.env;
          if (res.status === 'ok') break;
        }
      }
    } catch (e) { res = { status: 'unreachable', message: String(e) }; }
    r.status = res.status || 'unreachable';
    r.message = res.message || '';
    if (r.kind === 'ollama') { r.local = res.local || []; r.cloud = res.cloud || []; }
    else if (res.base_url !== undefined && r.kind !== 'account') { r.base_url = res.base_url; r.protocol = res.protocol; r.models = res.models || []; r.note = res.note; }
    if (r.kind !== 'account' && GOOD.includes(r.status) && (r.kind === 'ollama' ? (r.local.length + r.cloud.length) : r.models.length)) r.on = true;
    if (r.kind === 'account' && r.key && GOOD.includes(r.status)) r.on = true;
    render();
  }

  function statusBadge(r) {
    if (!r.status) return '';
    const s = t().st[r.status] || r.status;
    return `<span class="su-badge ${badgeClass(r.status)}" title="${h(r.message || '')}">${h(s)}</span>`;
  }

  function keyBox(r) {
    const p = r.p || (scan.providers.find(x => x.pid === r.a?.provider));
    const link = p && p.key_url ? `<a href="${h(p.key_url)}" target="_blank" rel="noopener">${t().getKey} ↗</a>` : '';
    return `<div class="su-key"><input type="password" autocomplete="off" spellcheck="false" placeholder="${h(t().paste)}" data-key="${h(r.id)}" value="${h(r.key)}"/><button class="sbtn" data-verify="${h(r.id)}">${t().verify}</button>${link}</div>`;
  }

  function renderRow(r) {
    const cb = (disabled) => `<input type="checkbox" data-on="${h(r.id)}" ${r.on ? 'checked' : ''} ${disabled ? 'disabled' : ''}/>`;
    if (r.kind === 'account') {
      const a = r.a, needKey = !a.local && ['no_key', 'invalid_key'].includes(r.status);
      const src = a.key_source ? t().keyFrom[a.key_source] : '';
      return `<div class="su-row ${r.on ? '' : 'off'}">${cb(false)}<div class="su-name">${h(a.name)}<small>${h(a.provider)}</small></div>${statusBadge(r)}
        <div class="su-meta"><span>${t().models}: <code>${h(a.models.join(', '))}</code></span>${a.key_env ? `<span><code>${h(a.key_env)}</code> ${h(src)}</span>` : ''}</div>
        ${needKey ? keyBox(r) : ''}</div>`;
    }
    if (r.kind === 'found' || r.kind === 'extra') {
      const p = r.p;
      const models = (r.models || []).length ? `<span>${t().models}: <code>${h(r.models.join(', '))}</code></span>` : '';
      const where = r.note ? `<span>${h(r.note)}</span>` : '';
      const envInfo = r.kind === 'found' && !r.key ? `<span><code>${h(r.env)}</code> ${t().keyFrom[(p.candidates.find(c => c.env === r.env) || {}).source] || ''}</span>` : (r.key ? `<span>${t().newKey}</span>` : '');
      const canTick = GOOD.includes(r.status) && (r.models || []).length;
      const showKey = r.kind === 'extra' || ['invalid_key', 'no_key'].includes(r.status);
      return `<div class="su-row ${r.on ? '' : 'off'}">${cb(!canTick)}<div class="su-name">${h(p.label)}${r.kind === 'found' ? `<small>${t().found}</small>` : ''}</div>${statusBadge(r)}
        <div class="su-meta">${models}${where}${envInfo}</div>${showKey ? keyBox(r) : ''}</div>`;
    }
    if (r.kind === 'ollama') {
      const parts = [];
      if (r.local.length) parts.push(`<span>${t().local}: <code>${h(r.local.join(', '))}</code></span>`);
      if (r.cloud.length) parts.push(`<span>${t().cloud}: <code>${h(r.cloud.join(', '))}</code></span>`);
      return `<div class="su-row ${r.on ? '' : 'off'}">${cb(!GOOD.includes(r.status))}<div class="su-name">Ollama<small>${t().found}</small></div>${statusBadge(r)}<div class="su-meta">${parts.join('')}</div></div>`;
    }
    if (r.kind === 'agent') {
      const g = r.g;
      let hint = '';
      if (!g.installed) hint = `${t().notInstalled} <code>${h(g.install_hint)}</code>`;
      else if (!g.logged_in) hint = `${t().notLoggedIn} <code>${h(g.login_hint)}</code>`;
      const badge = g.installed ? `<span class="su-badge ${g.logged_in ? 'ok' : 'warn'}">${g.logged_in ? t().loggedIn : t().installed}</span>` : '';
      return `<div class="su-row ${r.on ? '' : 'off'}">${cb(!g.installed && !g.configured)}<div class="su-name">${h(g.label)}${g.path ? `<small>${h(g.path)}</small>` : ''}</div>${badge}
        ${hint ? `<div class="su-hint">${hint}</div>` : ''}</div>`;
    }
    const o = r.o;
    return `<div class="su-row ${r.on ? '' : 'off'}">${cb(false)}<div class="su-name">${h(o.name)}<small>${h(o.command)}</small></div><span class="su-badge">${t().custom}</span></div>`;
  }

  function counts() {
    const acc = rows.filter(r => r.on && ['account', 'found', 'extra'].includes(r.kind)).length + rows.filter(r => r.on && r.kind === 'ollama').reduce((n, r) => n + (r.local.length ? 1 : 0) + (r.cloud.length ? 1 : 0), 0);
    const agt = rows.filter(r => r.on && ['agent', 'other'].includes(r.kind)).length;
    return [acc, agt];
  }

  function render() {
    const L = t();
    el('su-title').textContent = L.title;
    el('su-sub').textContent = L.sub;
    el('su-lang').textContent = L.lang;
    el('su-save').textContent = L.save;
    if (!scan) { el('su-body').innerHTML = `<div class="su-loading">${L.loading}</div>`; el('su-sum').textContent = ''; return; }
    const focused = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.key : null;
    const sec = (title, hint, inner) => `<div class="su-sec"><h4>${title}${hint ? `<span>${hint}</span>` : ''}</h4>${inner}</div>`;
    const accRows = rows.filter(r => ['account', 'found', 'ollama'].includes(r.kind));
    const extra = rows.filter(r => r.kind === 'extra');
    const agentRows = rows.filter(r => ['agent', 'other'].includes(r.kind));
    const ollamaOff = !scan.ollama.running && !scan.accounts.some(a => a.local) ? `<div class="su-empty">${L.ollamaOff}</div>` : '';
    el('su-body').innerHTML =
      sec(L.accounts, L.accountsHint, (accRows.length ? accRows.map(renderRow).join('') : `<div class="su-empty">${L.none}</div>`) + ollamaOff
        + (extra.length ? `<button class="su-more" id="su-more">${showMore ? L.less : L.more + ` (${extra.length})`}</button>` + (showMore ? extra.map(renderRow).join('') : '') : ''))
      + sec(L.agents, L.agentsHint, agentRows.map(renderRow).join(''))
      + sec(L.goal, '', `<div class="su-goal">${['balanced', 'fastest', 'best', 'cheapest'].map(g => `<button data-goal="${g}" class="${goal === g ? 'on' : ''}">${L.goals[g]}</button>`).join('')}</div>`)
      + sec(L.observeTitle, '', `<div class="su-hint">${L.observeHint}</div><label class="su-row"><input type="checkbox" id="su-observe" ${observe ? 'checked' : ''}/><div class="su-name">${L.observeTitle}</div></label>`);
    const [a, g] = counts();
    el('su-sum').textContent = a + g ? L.sum(a, g) : L.nothing;
    el('su-save').disabled = !(a + g);
    if (focused) { const f = document.querySelector(`[data-key="${CSS.escape(focused)}"]`); if (f) { f.focus(); f.setSelectionRange(f.value.length, f.value.length); } }
  }

  el('su-body').addEventListener('change', e => {
    if (e.target.id === 'su-observe') { observe = e.target.checked; return; }
    const id = e.target.dataset.on;
    if (id) { const r = row(id); if (r) { r.on = e.target.checked; render(); } }
  });
  el('su-body').addEventListener('input', e => {
    const id = e.target.dataset.key;
    if (id) { const r = row(id); if (r) r.key = e.target.value.trim(); }
  });
  el('su-body').addEventListener('keydown', e => {
    if (e.key === 'Enter' && e.target.dataset.key) { const r = row(e.target.dataset.key); if (r && r.key) verify(r); }
  });
  el('su-body').addEventListener('click', e => {
    const v = e.target.dataset.verify;
    if (v) { const r = row(v); if (r && r.key) verify(r); return; }
    if (e.target.id === 'su-more') { showMore = !showMore; render(); return; }
    const g = e.target.dataset.goal;
    if (g) { goal = g; render(); }
  });

  async function save() {
    const L = t();
    const body = { enable_accounts: {}, enable_agents: {}, add_accounts: [], add_agents: [], keys: {}, goal, observe_apps: observe };
    for (const r of rows) {
      if (r.kind === 'account') {
        body.enable_accounts[r.a.name] = r.on;
        if (r.on && r.key && r.a.key_env) body.keys[r.a.key_env] = r.key;
      } else if ((r.kind === 'found' || r.kind === 'extra') && r.on && (r.models || []).length) {
        const env = r.key ? r.p.env_name : r.env;
        if (r.key) body.keys[env] = r.key;
        body.add_accounts.push({ provider: r.p.pid, base_url: r.base_url, protocol: r.protocol || 'openai', env, models: r.models });
      } else if (r.kind === 'ollama' && r.on) {
        if (r.cloud.length) body.add_accounts.push({ name: 'ollama_cloud', provider: 'ollama', base_url: scan.ollama.base_url, protocol: 'openai', env: '', models: r.cloud });
        if (r.local.length) body.add_accounts.push({ name: 'ollama_local', provider: 'ollama', base_url: scan.ollama.base_url, protocol: 'openai', env: '', models: r.local });
      } else if (r.kind === 'agent') {
        if (r.g.configured) body.enable_agents[r.g.configured] = r.on;
        else if (r.on) body.add_agents.push(r.g.aid);
      } else if (r.kind === 'other') body.enable_agents[r.o.name] = r.on;
    }
    const btn = el('su-save');
    btn.disabled = true; btn.textContent = L.saving;
    try {
      const res = await post('/api/setup/apply', body);
      if (!res.ok) throw new Error(res.error || 'error');
      close();
      const toast = document.getElementById('toast');
      if (toast) { toast.textContent = L.saved; toast.classList.add('on'); setTimeout(() => toast.classList.remove('on'), 2600); }
      setTimeout(() => location.reload(), 900);
    } catch (e) {
      btn.disabled = false; btn.textContent = L.save;
      el('su-sum').textContent = L.failed + e.message;
    }
  }

  function close() { el('su-back').hidden = true; }

  async function open() {
    el('su-back').hidden = false;
    scan = null; render();
    try { scan = await fetch('/api/setup/scan').then(r => r.json()); }
    catch (e) { el('su-body').innerHTML = `<div class="su-loading">${h(String(e))}</div>`; return; }
    goal = scan.goal || 'balanced';
    observe = !!scan.observe_apps;
    buildRows(); render();
    for (const r of rows) if (r.status === 'checking') verify(r);
  }

  el('su-x').onclick = close;
  el('su-back').addEventListener('click', e => { if (e.target.id === 'su-back') close(); });
  document.addEventListener('keydown', e => { if (e.key === 'Escape' && !el('su-back').hidden) close(); });
  el('su-save').onclick = save;
  el('su-lang').onclick = () => { lang = lang === 'zh' ? 'en' : 'zh'; localStorage.setItem('oasis_lang', lang); render(); };

  const entry = document.getElementById('setup-open');
  if (entry) { entry.textContent = T[lang].setup; entry.onclick = open; }
  window.openSetup = open;

  fetch('/api/setup/scan').then(r => r.json()).then(s => { if (s.needs_setup) open(); }).catch(() => {});
})();
</script>
|}
