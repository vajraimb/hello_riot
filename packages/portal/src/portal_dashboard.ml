(** Embedded dashboard page (HTML/JS, no logic). *)

let index_html =
  {|<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Oasis Console</title>
<style>
:root{
  --bg:#0a0c10;--panel:#0f1217;--panel2:#13171e;--line:#1e232c;--line2:#2a303b;
  --text:#d6dbe3;--muted:#7a8391;--dim:#525a66;--accent:#5b8cff;--accent2:#7aa2ff;
  --ok:#3fb950;--warn:#d29922;--err:#f85149;--violet:#a371f7;--cyan:#39c5cf;
  --mono:"SF Mono",ui-monospace,Menlo,Consolas,monospace;
}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--text);font:13px/1.5 -apple-system,BlinkMacSystemFont,"PingFang SC","Segoe UI",sans-serif;display:flex;flex-direction:column;overflow:hidden}
button,select,textarea,input{font:inherit;color:inherit}
.mono{font-family:var(--mono)}
.muted{color:var(--muted)}
.dim{color:var(--dim)}

/* top bar */
.top{display:flex;align-items:center;gap:18px;height:44px;padding:0 16px;border-bottom:1px solid var(--line);background:var(--panel);flex:none}
.brand{display:flex;align-items:center;gap:8px;font-weight:600;letter-spacing:.2px}
.brand i{width:10px;height:10px;border-radius:2px;background:linear-gradient(135deg,var(--accent),var(--cyan));display:inline-block}
.tabs{display:flex;gap:2px}
.tab{padding:5px 11px;border-radius:5px;color:var(--muted);cursor:pointer;border:0;background:none}
.tab:hover{color:var(--text);background:var(--panel2)}
.tab.on{color:var(--text);background:var(--line)}
.health{margin-left:auto;display:flex;gap:14px;align-items:center;font-size:12px;color:var(--muted)}
.health b{color:var(--text);font-weight:600}
.dot{width:7px;height:7px;border-radius:50%;display:inline-block;background:var(--dim);vertical-align:middle;margin-right:5px}
.dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}.dot.err{background:var(--err)}
.dot.live{background:var(--ok);box-shadow:0 0 0 3px rgba(63,185,80,.15)}

/* command bar */
.cmd{flex:none;border-bottom:1px solid var(--line);background:var(--panel);padding:10px 16px;display:flex;gap:12px;align-items:flex-start}
.cmd textarea{flex:1;min-height:38px;max-height:180px;resize:vertical;background:var(--bg);border:1px solid var(--line2);border-radius:6px;padding:9px 11px;outline:none;line-height:1.45}
.cmd textarea:focus{border-color:var(--accent)}
.opts{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.seg{display:flex;border:1px solid var(--line2);border-radius:6px;overflow:hidden}
.seg button{background:none;border:0;padding:6px 10px;color:var(--muted);cursor:pointer;border-right:1px solid var(--line2)}
.seg button:last-child{border-right:0}
.seg button.on{background:var(--line);color:var(--text)}
select{background:var(--bg);border:1px solid var(--line2);border-radius:6px;padding:6px 8px;outline:none}
.run{background:var(--accent);border:0;color:#fff;border-radius:6px;padding:7px 14px;font-weight:600;cursor:pointer;white-space:nowrap}
.run:hover{background:var(--accent2)}
.run:disabled{opacity:.5;cursor:default}
kbd{font-family:var(--mono);font-size:10.5px;color:var(--muted);border:1px solid var(--line2);border-bottom-width:2px;border-radius:4px;padding:0 4px;margin-left:6px}

/* workspace */
.work{--lw:320px;--rw:340px;flex:1;display:grid;grid-template-columns:var(--lw) minmax(0,1fr) var(--rw);min-height:0}
.work > .col.list{grid-column:1;position:relative}
.work > #detail{grid-column:2}
.work > .col.rail{grid-column:3}
.work.list-off{grid-template-columns:0 minmax(0,1fr) var(--rw)}
.work.list-off > .col.list{display:none}
.work.list-off.rail-off{grid-template-columns:0 minmax(0,1fr) 0}
.lresize{position:absolute;top:0;bottom:0;right:-3px;width:6px;cursor:col-resize;z-index:3}
.lresize:hover,.lresize.drag{background:var(--accent);opacity:.45}
body.resizing{cursor:col-resize;user-select:none}
.msel{position:relative}
.msel > button{background:var(--bg);border:1px solid var(--line2);border-radius:6px;padding:6px 10px;color:var(--text);cursor:pointer;font:inherit}
.pop{display:none;position:absolute;top:calc(100% + 4px);left:0;z-index:20;background:var(--panel2);border:1px solid var(--line2);border-radius:6px;padding:4px 0;min-width:280px;box-shadow:0 8px 24px rgba(0,0,0,.45)}
.pop.on{display:block}
.pop label{display:flex;gap:8px;align-items:center;padding:5px 10px;cursor:pointer;font-size:12px}
.pop label:hover{background:var(--line)}
.pop label.off{opacity:.45}
.col{display:flex;flex-direction:column;min-height:0;border-right:1px solid var(--line)}
.col:last-child{border-right:0}
.work.rail-off{grid-template-columns:var(--lw) minmax(0,1fr) 0}
.work.rail-off > .col.rail{display:none}
.railbtn{background:none;border:1px solid var(--line2);border-radius:5px;color:var(--muted);cursor:pointer;padding:2px 8px;font-size:12px}
.railbtn:hover{color:var(--text);border-color:var(--accent)}
.railbtn.on{color:var(--text);background:var(--line)}
#h-alerts{cursor:pointer}
.colhead{flex:none;display:flex;align-items:center;gap:8px;height:38px;padding:0 14px;border-bottom:1px solid var(--line);font-size:11.5px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted);font-weight:600}
.colhead .r{margin-left:auto;text-transform:none;letter-spacing:0;font-weight:400}
.scroll{flex:1;overflow-y:auto;min-height:0}
.scroll::-webkit-scrollbar{width:8px}.scroll::-webkit-scrollbar-thumb{background:var(--line2);border-radius:4px}

/* task list */
.filters{display:flex;gap:2px}
.filters button{background:none;border:0;color:var(--dim);cursor:pointer;padding:2px 6px;border-radius:4px;font-size:11.5px}
.filters button.on{color:var(--text);background:var(--line)}
.task{padding:9px 14px;border-bottom:1px solid var(--line);cursor:pointer;display:grid;grid-template-columns:16px 1fr;gap:4px 8px}
.task:hover{background:var(--panel2)}
.task.sel{background:#151b26;box-shadow:inset 2px 0 0 var(--accent)}
.task .t{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.task .m{grid-column:2;font-size:11.5px;color:var(--muted);display:flex;gap:8px;white-space:nowrap;overflow:hidden}
.st{font-family:var(--mono);font-size:12px;line-height:20px;text-align:center}
.st.ok{color:var(--ok)}.st.failed{color:var(--err)}.st.running{color:var(--accent)}.st.cancelled{color:var(--muted)}
.spin{display:inline-block;width:10px;height:10px;border:1.5px solid var(--accent);border-right-color:transparent;border-radius:50%;animation:sp .8s linear infinite;vertical-align:-1px}
@keyframes sp{to{transform:rotate(360deg)}}
.tag{font-size:10.5px;padding:0 5px;border-radius:3px;border:1px solid var(--line2);color:var(--muted);line-height:16px}
.tag.agent{color:var(--violet);border-color:rgba(163,113,247,.35)}
.tag.chat{color:var(--cyan);border-color:rgba(57,197,207,.35)}
.empty{padding:40px 20px;text-align:center;color:var(--dim)}

/* detail */
.dhead{flex:none;padding:14px 18px 12px;border-bottom:1px solid var(--line)}
.dtitle{font-size:15px;font-weight:600;line-height:1.4;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.chips{display:flex;flex-wrap:wrap;gap:6px 14px;margin-top:8px;font-size:12px;color:var(--muted)}
.chips b{color:var(--text);font-weight:500}
.rate{display:inline-flex;gap:4px;align-items:center}
.rate button{background:none;border:1px solid var(--line);border-radius:4px;color:var(--muted);padding:0 7px;line-height:20px;cursor:pointer;font-size:12px}
.rate button:hover{border-color:var(--muted);color:var(--text)}
.rate button.on{border-color:var(--accent);color:var(--text);background:rgba(88,166,255,.12)}
.pill{font-size:11px;font-weight:600;padding:1px 7px;border-radius:10px}
.pill.ok{background:rgba(63,185,80,.14);color:var(--ok)}
.pill.failed{background:rgba(248,81,73,.14);color:var(--err)}
.pill.cancelled{background:rgba(139,148,158,.14);color:var(--muted)}
.stopbtn{background:none;border:1px solid rgba(248,81,73,.5);border-radius:4px;color:var(--err);padding:0 8px;line-height:20px;cursor:pointer;font-size:12px}
.stopbtn:hover{background:rgba(248,81,73,.12)}
.pill.running{background:rgba(91,140,255,.15);color:var(--accent2)}
.route{margin-top:10px;padding:8px 10px;border:1px solid var(--line);border-radius:6px;background:var(--panel);font-size:12.5px;display:flex;gap:8px}
.route .k{color:var(--muted);flex:none}
.route .k.tog{cursor:pointer;user-select:none}
.route .k.tog:hover{color:var(--text)}
.route.fold{padding:5px 10px}
.route.fold .rs{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--dim)}
.route.fold details{display:none}
.route details{margin-top:6px}
.route summary{cursor:pointer;color:var(--dim);font-size:11.5px}
.ctable{width:100%;border-collapse:collapse;margin-top:6px;font-size:12px}
.ctable td{padding:3px 6px;border-top:1px solid var(--line)}
.bar{height:4px;background:var(--line);border-radius:2px;overflow:hidden;width:90px}
.bar i{display:block;height:100%;background:var(--accent)}
.dtabs{flex:none;display:flex;gap:2px;padding:0 14px;border-bottom:1px solid var(--line);height:36px;align-items:flex-end}
.dtab{background:none;border:0;padding:7px 10px;color:var(--muted);cursor:pointer;border-bottom:2px solid transparent}
.dtab.on{color:var(--text);border-bottom-color:var(--accent)}

/* conversation */
#detail .dbody{flex:1;display:flex;flex-direction:column;min-height:0}
.follow{flex:none;border-top:1px solid var(--line);background:var(--panel);padding:10px 14px;display:none;gap:10px;align-items:flex-end}
.follow.on{display:flex}
.follow textarea{flex:1;min-height:40px;max-height:200px;resize:vertical;background:var(--bg);border:1px solid var(--line2);border-radius:6px;padding:8px 10px;outline:none;line-height:1.45}
.follow textarea:focus{border-color:var(--accent)}
.follow .fh{font-size:11.5px;color:var(--dim);margin-bottom:5px}
.follow .fw{flex:1;display:flex;flex-direction:column;min-width:0}
.turns{display:flex;flex-wrap:wrap;gap:4px;margin-top:9px;align-items:center;font-size:11.5px;color:var(--dim)}
.turns button{background:none;border:1px solid var(--line);border-radius:4px;color:var(--muted);padding:0 7px;line-height:19px;cursor:pointer;font-size:11.5px;font-family:var(--mono)}
.turns button.on{border-color:var(--accent);color:var(--text);background:rgba(88,166,255,.12)}
.turns button.failed{border-color:rgba(248,81,73,.5)}
.turns button.running{border-color:rgba(91,140,255,.6)}
.nturn{font-size:10.5px;color:var(--accent2);border:1px solid rgba(91,140,255,.35);border-radius:3px;padding:0 4px;line-height:16px}
.turnblk{border-bottom:1px solid var(--line);padding:14px 20px}
.turnblk .meta{font-size:12px;color:var(--muted);display:flex;gap:10px;align-items:center}
.turnblk .q{background:var(--panel);border:1px solid var(--line);border-left:3px solid var(--accent);border-radius:6px;padding:8px 11px;white-space:pre-wrap;word-break:break-word;margin:8px 0 10px;font-size:13px}
.turnblk .a{white-space:pre-wrap;word-break:break-word;line-height:1.65;font-size:13.5px}
.turnblk .a pre{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:10px;font-family:var(--mono);font-size:12px;white-space:pre-wrap;line-height:1.5}
.turnblk .a code{font-family:var(--mono);font-size:12px;background:var(--panel2);padding:0 4px;border-radius:3px}

/* timeline */
.tl{padding:10px 18px 30px}
.ev{display:grid;grid-template-columns:62px 18px 1fr;gap:0 8px;padding:4px 0;align-items:start}
.ev .ts{font-family:var(--mono);font-size:11px;color:var(--dim);text-align:right;line-height:20px}
.ev .ic{font-family:var(--mono);font-size:12px;line-height:20px;text-align:center;color:var(--muted)}
.ev .bd{min-width:0;line-height:20px}
.ev.route .ic{color:var(--accent)}
.ev.att .ic{color:var(--accent2)}
.ev.ok .ic{color:var(--ok)}
.ev.bad .ic,.ev.bad .bd>.hl{color:var(--err)}
.ev.ho .ic,.ev.ho .bd{color:var(--warn)}
.ev.think .bd{color:var(--muted);font-style:italic}
.lbl{font-size:10.5px;text-transform:uppercase;letter-spacing:.5px;color:var(--dim);margin-right:6px;font-style:normal}
.clamp{display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden;white-space:pre-wrap;word-break:break-word}
.clamp.open{display:block}
.more{color:var(--accent);cursor:pointer;font-size:11.5px;font-style:normal}
.tool{border:1px solid var(--line);border-radius:6px;background:var(--panel);overflow:hidden}
.tool .h{display:flex;gap:8px;align-items:center;padding:4px 9px;cursor:pointer}
.tool .n{font-family:var(--mono);font-size:12px;color:var(--cyan);flex:none}
.tool .in{font-family:var(--mono);font-size:12px;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1}
.tool .s{flex:none;font-family:var(--mono);font-size:11.5px}
.tool .out{display:none;border-top:1px solid var(--line);background:var(--bg);margin:0;padding:7px 10px;font-family:var(--mono);font-size:11.5px;color:var(--muted);white-space:pre-wrap;word-break:break-word;max-height:260px;overflow:auto}
.tool.open .out{display:block}
.err-raw{font-family:var(--mono);font-size:11px;color:var(--dim);word-break:break-all}
.answer{padding:16px 20px 40px;white-space:pre-wrap;word-break:break-word;line-height:1.65;font-size:13.5px}
.answer pre{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:10px;font-family:var(--mono);font-size:12px;white-space:pre-wrap;line-height:1.5}
.answer code{font-family:var(--mono);font-size:12px;background:var(--panel2);padding:0 4px;border-radius:3px}

/* right rail */
.alert{margin:10px 12px 0;border:1px solid var(--line);border-left:3px solid var(--warn);border-radius:6px;background:var(--panel);padding:9px 11px}
.alert.error{border-left-color:var(--err)}
.alert .at{display:flex;gap:6px;align-items:baseline}
.alert .at b{font-weight:600}
.alert .tg{font-family:var(--mono);font-size:11px;color:var(--muted);margin-left:auto}
.alert .dt{color:var(--muted);font-size:12px;margin-top:3px}
.fix{margin-top:7px;display:flex;align-items:stretch;border:1px solid var(--line2);border-radius:5px;overflow:hidden}
.fix code{flex:1;font-family:var(--mono);font-size:11.5px;padding:5px 8px;background:var(--bg);white-space:pre-wrap;word-break:break-all}
.fix button{flex:none;background:var(--panel2);border:0;border-left:1px solid var(--line2);color:var(--muted);cursor:pointer;padding:0 9px;font-size:11.5px}
.fix button:hover{color:var(--text)}
.allok{margin:12px;padding:12px;border:1px dashed var(--line2);border-radius:6px;color:var(--muted);font-size:12px}
.res{width:100%;border-collapse:collapse;font-size:12px}
.res td{padding:5px 8px;border-bottom:1px solid var(--line);white-space:nowrap}
.res td.n{max-width:130px;overflow:hidden;text-overflow:ellipsis}
.res tr.sec td{color:var(--dim);font-size:10.5px;text-transform:uppercase;letter-spacing:.6px;padding-top:12px;border-bottom:0}
.num{font-family:var(--mono);text-align:right;color:var(--muted)}

/* diagnostics */
.diag{flex:1;overflow-y:auto;padding:16px;display:none}
.diag.on{display:block}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:12px;margin-bottom:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px}
.card h3{margin:0 0 8px;font-size:11.5px;text-transform:uppercase;letter-spacing:.6px;color:var(--muted);display:flex;align-items:center}
.card h3 span{margin-left:auto;text-transform:none;letter-spacing:0;font-weight:400}
.dt-table{width:100%;border-collapse:collapse;font-size:12px}
.dt-table th,.dt-table td{text-align:left;padding:5px 6px;border-bottom:1px solid var(--line);vertical-align:top}
.dt-table th{color:var(--dim);font-weight:500}
#log{height:260px;overflow-y:auto;font-family:var(--mono);font-size:11.5px;line-height:1.6}
.handoff{color:var(--warn)}
.sbtn{background:var(--panel2);border:1px solid var(--line2);border-radius:5px;padding:3px 9px;cursor:pointer;font-size:12px}
.sbtn:hover{border-color:var(--accent)}
.diag input{background:var(--bg);border:1px solid var(--line2);border-radius:5px;padding:5px 8px}

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
.gnode.failed { animation: node-fail .3s ease-in-out 2; }
.gedge { stroke-dasharray: 300; animation: edge-grow .5s ease-out both; }
.gedge.fallback { stroke-dasharray: 6 5; stroke: var(--warn); }
.gedge.handoff { stroke-dasharray: none; stroke-width: 2.5; }
#graph-box { background:var(--bg); border:1px solid var(--line); border-radius:6px; overflow-x:auto; min-height:200px; }
#graph-box svg { min-width: 760px; }
.toast{position:fixed;bottom:16px;left:50%;transform:translateX(-50%);background:var(--line);border:1px solid var(--line2);padding:6px 12px;border-radius:6px;font-size:12px;opacity:0;transition:opacity .2s;pointer-events:none}
.toast.on{opacity:1}
</style>
</head>
<body>
<header class="top">
  <div class="brand"><i></i>Oasis</div>
  <nav class="tabs">
    <button class="tab on" data-view="work">工作台</button>
    <button class="tab" data-view="diag">诊断</button>
  </nav>
  <div class="health">
    <span id="h-acc"><span class="dot"></span>账户 <b>–</b></span>
    <span id="h-agt"><span class="dot"></span>Agent <b>–</b></span>
    <span id="h-today">API 今日 <b>–</b> 次</span>
    <span id="h-alerts"></span>
    <span id="h-ws"><span class="dot"></span>连接中</span>
    <button class="railbtn" id="list-toggle" title="显示 / 隐藏任务栏（快捷键 [）">任务栏</button>
    <button class="railbtn" id="rail-toggle" title="显示 / 隐藏右栏（快捷键 \）">侧栏</button>
  </div>
</header>

<section id="view-work" style="flex:1;display:flex;flex-direction:column;min-height:0">
  <div class="cmd">
    <textarea id="prompt" rows="1" placeholder="描述任务，⌘↵ 运行。Agent 模式会在本机调用 Claude Code / Cursor / Gemini 等执行。"></textarea>
    <div class="opts">
      <div class="seg" id="mode">
        <button data-v="" class="on" title="按类别自动决定">自动</button>
        <button data-v="chat" title="走 API 账户直接回答">问答</button>
        <button data-v="agent" title="交给本机 agent 执行（可读写文件、跑命令）">Agent</button>
      </div>
      <select id="category" title="任务类别（自动识别会按问题内容判断，例如天气、新闻走联网检索）">
        <option value="" selected>自动识别</option>
        <option value="general">通用</option>
        <option value="coding">编程</option>
        <option value="research">联网检索</option>
        <option value="writing">写作</option>
        <option value="analysis">分析</option>
        <option value="pick" hidden>自选</option>
        <option value="committee" hidden>委员会</option>
      </select>
      <span id="picker" style="display:contents"></span>
      <select id="goal" title="路由目标">
        <option value="balanced">均衡</option>
        <option value="fastest">最快</option>
        <option value="best">质量优先</option>
        <option value="cheapest">最省钱</option>
      </select>
      <button class="run" id="run">运行<kbd style="color:#dbe4ff;border-color:rgba(255,255,255,.3)">⌘↵</kbd></button>
    </div>
  </div>
  <div class="work" id="work">
    <div class="col list">
      <div class="colhead">任务
        <div class="r filters" id="filters">
          <button data-f="all" class="on">全部</button>
          <button data-f="running">进行中</button>
          <button data-f="failed">失败</button>
          <button class="railbtn" id="list-hide" title="收起任务栏（[）" style="margin-left:6px">‹</button>
        </div>
      </div>
      <div class="lresize" id="lresize" title="拖动调整宽度，双击恢复默认"></div>
      <div class="scroll" id="tasks"><div class="empty">还没有任务</div></div>
    </div>
    <div class="col" id="detail">
      <div class="dbody" id="dbody"><div class="empty" style="margin:auto">选择左侧任务查看路由说明和执行过程<br><span class="dim" style="font-size:12px">快捷键：<kbd>/</kbd> 输入 · <kbd>j</kbd><kbd>k</kbd> 切换任务 · <kbd>[</kbd> 任务栏 · <kbd>\</kbd> 侧栏 · <kbd>g</kbd> 路由说明</span></div></div>
      <div class="follow" id="followbar">
        <div class="fw"><div class="fh" id="follow-hint"></div>
          <textarea id="follow-in" rows="2" placeholder="继续这个对话：追问、补充要求，或让它接着把任务做完（⌘↵ 发送）"></textarea></div>
        <button class="run" id="follow-go">继续<kbd style="color:#dbe4ff;border-color:rgba(255,255,255,.3)">⌘↵</kbd></button>
      </div>
    </div>
    <div class="col rail">
      <div class="colhead">需要你处理 <span class="r" id="alerts-count"></span><button class="railbtn" id="rail-hide" title="隐藏右栏（\）" style="margin-left:8px">收起 ›</button></div>
      <div id="alerts" style="flex:none;max-height:55%;overflow-y:auto;padding-bottom:10px"></div>
      <div class="colhead" style="border-top:1px solid var(--line)">资源 <span class="r dim">延迟 · 次数</span></div>
      <div class="scroll"><table class="res" id="resources"></table></div>
    </div>
  </div>
</section>

<section class="diag" id="view-diag">
  <div class="grid">
    <div class="card"><h3>账户明细</h3><div style="overflow-x:auto"><table class="dt-table" id="acc-table"></table></div></div>
    <div class="card"><h3>原始路由决策 <span class="dim">最近 20 条 + 实时</span></h3><div id="log"></div></div>
  </div>
  <div class="card" style="margin-bottom:12px"><h3>过程图 <span id="graph-summary" class="muted"></span></h3><div id="graph-box"></div></div>
  <div class="grid">
    <div class="card"><h3>本机 Agent 盘点 <span><button class="sbtn" onclick="refreshAgentsDiag()">刷新</button></span></h3><div id="agents-box" style="font-size:12px;line-height:1.9"></div></div>
    <div class="card"><h3>Agent 会话活动 <span><button class="sbtn" onclick="refreshActivity()">刷新</button></span></h3><div id="activity-box" style="font-size:12px;line-height:1.7;max-height:280px;overflow-y:auto"></div></div>
    <div class="card"><h3>消息总线 <span><button class="sbtn" onclick="refreshInbox()">刷新</button></span></h3>
      <div id="inbox-box" style="font-size:12px;line-height:1.9"></div>
      <div style="display:flex;gap:6px;margin-top:8px">
        <input id="reply-to" placeholder="agent，如 claude_code" style="flex:1" />
        <input id="reply-text" placeholder="回复内容" style="flex:2" />
        <button class="sbtn" onclick="sendReply()">回复</button>
      </div>
    </div>
  </div>
</section>
<div class="toast" id="toast"></div>

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
const $ = id => document.getElementById(id);
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const CAT = { general: '通用', coding: '编程', research: '联网检索', writing: '写作', analysis: '分析', reasoning: '推理' };
const SRC = { api: 'API', mcp: 'MCP', dashboard: '控制台' };
function fmtDur(ms) {
  if (ms == null) return '';
  if (ms < 1000) return ms + 'ms';
  if (ms < 60000) return (ms / 1000).toFixed(ms < 10000 ? 1 : 0) + 's';
  return Math.floor(ms / 60000) + 'm' + String(Math.floor(ms / 1000) % 60).padStart(2, '0') + 's';
}
function ago(ms) {
  const s = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (s < 60) return s + 's 前';
  if (s < 3600) return Math.floor(s / 60) + 'm 前';
  if (s < 86400) return Math.floor(s / 3600) + 'h 前';
  return new Date(ms).toLocaleDateString();
}
function toast(msg) { const t = $('toast'); t.textContent = msg; t.classList.add('on'); clearTimeout(t._h); t._h = setTimeout(() => t.classList.remove('on'), 1400); }
function copy(text) { navigator.clipboard.writeText(text).then(() => toast('已复制'), () => toast('复制失败')); }

/* ---------- views ---------- */
document.querySelectorAll('.tab').forEach(b => b.onclick = () => {
  document.querySelectorAll('.tab').forEach(x => x.classList.toggle('on', x === b));
  const diag = b.dataset.view === 'diag';
  $('view-work').style.display = diag ? 'none' : 'flex';
  $('view-diag').classList.toggle('on', diag);
  if (diag) refreshDiag();
});

/* ---------- state ---------- */
const S = { routeFold: localStorage.getItem('oasis_route_fold') === '1', tasks: [], sel: null, detail: null, filter: 'all', dirtyList: true, dirtyDetail: false,
            localAnswers: {}, refs: {}, pendingRef: null, detailTab: 'trace', openTools: new Set(), openText: new Set(),
            threads: [], selKey: null, selThread: null, thread: null };

/* ---------- command bar ---------- */
let mode = '';
document.querySelectorAll('#mode button').forEach(b => b.onclick = () => {
  mode = b.dataset.v;
  document.querySelectorAll('#mode button').forEach(x => x.classList.toggle('on', x === b));
  syncCategory();
});
let committee = JSON.parse(localStorage.getItem('oasis_committee') || '[]');
function syncCategory() {
  const sel = $('category');
  [...sel.options].forEach(o => {
    if (o.value === 'pick') o.hidden = mode !== 'agent';
    if (o.value === 'committee') o.hidden = mode !== 'chat';
  });
  if (sel.selectedOptions[0] && sel.selectedOptions[0].hidden) sel.value = '';
  renderPicker();
}
function renderPicker() {
  const v = $('category').value, box = $('picker');
  if (v === 'pick') {
    const ags = agtCache.filter(a => a.enabled);
    const cur = localStorage.getItem('oasis_pick') || '';
    box.innerHTML = ags.length
      ? '<select id="agent-pick" title="指定由哪个 agent 执行">' + ags.map(a => '<option value="' + esc(a.name) + '"' + (a.name === cur ? ' selected' : '') + '>' + esc(a.name) + (agtHealth(a) === 'ok' ? '' : '（异常）') + '</option>').join('') + '</select>'
      : '<span class="dim">加载 agent…</span>';
    if ($('agent-pick')) $('agent-pick').onchange = e => localStorage.setItem('oasis_pick', e.target.value);
  } else if (v === 'committee') {
    const accs = accCache.filter(a => a.enabled);
    if (accs.length) committee = committee.filter(n => accs.some(a => a.name === n));
    box.innerHTML = '<div class="msel"><button id="cm-btn" type="button" title="选 2–3 个账户，汇总模型由路由器自动挑">成员 ' + committee.length + '/3 ▾</button><div class="pop" id="cm-pop">' +
      (accs.length ? accs.map(a => '<label class="' + (accHealth(a) === 'ok' ? '' : 'off') + '"><input type="checkbox" value="' + esc(a.name) + '"' + (committee.includes(a.name) ? ' checked' : '') + '><span class="mono">' + esc(a.name) + '</span><span class="dim">' + esc((a.models || [])[0] || '') + '</span></label>').join('') : '<div class="dim" style="padding:6px 10px">加载账户…</div>') +
      '<div class="dim" style="padding:6px 10px;border-top:1px solid var(--line);margin-top:4px">选 2–3 个；各家并行作答，再由路由器选一个模型汇总</div></div></div>';
    $('cm-btn').onclick = e => { e.stopPropagation(); $('cm-pop').classList.toggle('on'); };
    $('cm-pop').onclick = e => e.stopPropagation();
    $('cm-pop').querySelectorAll('input').forEach(cb => cb.onchange = () => {
      if (cb.checked && committee.length >= 3) { cb.checked = false; toast('最多选 3 个'); return; }
      committee = cb.checked ? committee.concat(cb.value) : committee.filter(n => n !== cb.value);
      localStorage.setItem('oasis_committee', JSON.stringify(committee));
      $('cm-btn').textContent = '成员 ' + committee.length + '/3 ▾';
    });
  } else box.innerHTML = '';
}
$('category').onchange = renderPicker;
document.addEventListener('click', () => { const p = $('cm-pop'); if (p) p.classList.remove('on'); });
const promptEl = $('prompt');
promptEl.addEventListener('input', () => { promptEl.style.height = 'auto'; promptEl.style.height = Math.min(180, promptEl.scrollHeight + 2) + 'px'; });
promptEl.addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); run(); } });
$('run').onclick = run;

async function run() {
  const text = promptEl.value.trim();
  if (!text) { promptEl.focus(); return; }
  const cat = $('category').value;
  const pick = cat === 'pick' ? ($('agent-pick') && $('agent-pick').value) : '';
  if (cat === 'pick' && !pick) { toast('没有可选的 agent'); return; }
  if (cat === 'committee' && committee.length < 2) { toast('委员会至少选 2 个账户'); $('cm-pop') && $('cm-pop').classList.add('on'); return; }
  const stream = cat !== 'committee';
  const headers = {};
  if (mode) headers['X-Oasis-Mode'] = mode;
  if (cat === 'pick') { headers['X-Oasis-Mode'] = 'agent'; headers['X-Oasis-Agent'] = pick; }
  else if (cat === 'committee') headers['X-Oasis-Committee'] = committee.join(',');
  else if (cat) headers['X-Oasis-Category'] = cat;
  $('run').disabled = true;
  setTimeout(() => { $('run').disabled = false; }, 600);
  promptEl.value = ''; promptEl.style.height = 'auto';
  await send(text, headers, stream);
}
function threadRow(id) { return rowsAll().find(r => r.thread === id); }
async function followUp() {
  const box = $('follow-in');
  const text = box.value.trim();
  const id = S.selThread;
  if (!text || !id) { box.focus(); return; }
  const row = threadRow(id);
  if (row && row.status === 'running') { toast('上一轮还在进行，完成或停止后再继续'); return; }
  box.value = '';
  await send(text, { 'X-Oasis-Thread': id }, !(row && row.mode === 'committee'));
}
$('follow-go').onclick = followUp;
$('follow-in').addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); followUp(); } });
async function send(text, extra, stream) {
  const ref = 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
  S.pendingRef = ref;
  S.localAnswers[ref] = '';
  const headers = Object.assign({
    'Content-Type': 'application/json',
    'X-Oasis-Goal': $('goal').value,
    'X-Oasis-Source': 'dashboard',
    'X-Oasis-Client-Ref': ref
  }, extra);
  try {
    const res = await fetch('/v1/chat/completions', { method: 'POST', headers, body: JSON.stringify({ model: null, messages: [{ role: 'user', content: text }], stream }) });
    if (!res.ok || !res.body) {
      let msg = 'HTTP ' + res.status;
      try { const j = await res.json(); msg += ' ' + (j.error || JSON.stringify(j)); } catch (e) {}
      S.localAnswers[ref] = msg;
      toast('请求失败：' + msg);
      return;
    }
    if (!stream) { await res.text(); S.dirtyList = true; if (S.sel && S.refs[S.sel] === ref) S.dirtyDetail = true; return; }
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
        if (!line.startsWith('data: ')) continue;
        const payload = line.slice(6);
        if (payload === '[DONE]') continue;
        try {
          const c = JSON.parse(payload).choices?.[0]?.delta?.content || '';
          if (c) { S.localAnswers[ref] += c; if (S.sel && S.refs[S.sel] === ref) S.dirtyDetail = true; }
        } catch (e) {}
      }
    }
  } catch (e) { toast('连接中断：' + e.message); }
  S.dirtyList = true;
  if (S.sel && S.refs[S.sel] === ref) S.dirtyDetail = true;
}

/* ---------- task list ---------- */
document.querySelectorAll('#filters button').forEach(b => b.onclick = () => {
  S.filter = b.dataset.f;
  document.querySelectorAll('#filters button').forEach(x => x.classList.toggle('on', x === b));
  renderList();
});
async function loadList() {
  try {
    const [j, th] = await Promise.all([fetch('/api/feed?limit=150').then(r => r.json()), fetch('/api/threads?limit=80').then(r => r.json())]);
    S.tasks = j.tasks || [];
    S.threads = th.threads || [];
    renderList();
  } catch (e) {}
}
/* one row per conversation: live turns from the feed, older conversations from the thread store */
function rowsAll() {
  const by = new Map();
  S.tasks.forEach(t => { const k = t.thread || t.id; if (!by.has(k)) by.set(k, []); by.get(k).push(t); });
  const store = new Map(S.threads.map(t => [t.id, t]));
  const rows = [];
  by.forEach((ts, k) => {
    ts.sort((a, b) => (a.turn || 0) - (b.turn || 0) || a.started_ms - b.started_ms);
    const last = ts[ts.length - 1], th = store.get(k);
    rows.push({ key: k, thread: last.thread || '', last, tasks: ts, title: (th && th.title) || ts[0].title, n: Math.max(ts.length, last.turn || 0, th ? th.turns : 0),
      status: last.status, mode: last.mode, executor: last.executor, at: last.started_ms, dur: last.duration_ms, source: last.source });
  });
  S.threads.forEach(th => { if (!by.has(th.id)) rows.push({ key: th.id, thread: th.id, last: null, tasks: [], title: th.title, n: th.turns,
    status: th.status, mode: th.mode, executor: th.executor, at: th.updated_ms, dur: null, source: '', hist: true }); });
  rows.sort((a, b) => b.at - a.at);
  return rows;
}
function statusGlyph(st) {
  if (st === 'running') return '<span class="spin"></span>';
  return st === 'ok' ? '✓' : st === 'cancelled' ? '■' : '✗';
}
function visibleTasks() {
  return rowsAll().filter(r => S.filter === 'all' || r.status === S.filter);
}
function renderList() {
  const box = $('tasks');
  const list = visibleTasks();
  if (!list.length) { box.innerHTML = '<div class="empty">' + (S.tasks.length || S.threads.length ? '没有符合条件的任务' : '还没有任务<br><span style="font-size:12px">从上方输入，或通过 API / MCP 调用网关</span>') + '</div>'; return; }
  box.innerHTML = list.map(r => {
    const m = r.mode === 'agent' ? '<span class="tag agent">Agent</span>' : r.mode === 'committee' ? '<span class="tag chat">委员会</span>' : (r.mode ? '<span class="tag chat">问答</span>' : '');
    return '<div class="task' + (r.key === S.selKey ? ' sel' : '') + '" data-k="' + esc(r.key) + '">' +
      '<div class="st ' + r.status + '">' + statusGlyph(r.status) + '</div>' +
      '<div class="t">' + (esc(r.title) || '<span class="dim">（无标题）</span>') + '</div>' +
      '<div class="m">' + m + (r.n > 1 ? '<span class="nturn">' + r.n + ' 轮</span>' : '') + '<span>' + esc(r.executor || (r.status === 'running' ? '路由中' : '无执行者')) + '</span><span>' + fmtDur(r.dur) + '</span>' +
      '<span>' + (r.hist ? '历史' : esc(SRC[r.source] || r.source)) + '</span><span style="margin-left:auto">' + ago(r.at) + '</span></div></div>';
  }).join('');
  box.querySelectorAll('.task').forEach(el => el.onclick = () => select(el.dataset.k));
  syncFollow();
}
function select(key) {
  const r = rowsAll().find(x => x.key === key);
  if (!r) return;
  if (S.selKey !== key) { S.openTools.clear(); S.openText.clear(); S.thread = null; }
  S.selKey = key;
  S.selThread = r.thread || null;
  S.sel = r.last ? r.last.id : null;
  S.detail = null;
  if (!r.last) S.detailTab = 'conv';
  else if (S.detailTab === 'conv' && r.n < 2) S.detailTab = 'trace';
  renderList();
  loadThread();
  if (S.sel) loadDetail(true); else renderDetail(true);
}
function selectTurn(id) {
  if (S.sel === id) return;
  S.openTools.clear(); S.openText.clear();
  S.sel = id;
  if (S.detailTab === 'conv') S.detailTab = 'trace';
  loadDetail(true);
}
async function loadThread() {
  if (!S.selThread) { S.thread = null; return; }
  try {
    const r = await fetch('/api/thread?id=' + encodeURIComponent(S.selThread));
    S.thread = r.ok ? await r.json() : null;
    if (S.detailTab === 'conv' || !S.detail) renderDetail(false); else syncFollow();
  } catch (e) {}
}

/* ---------- detail ---------- */
async function stopTask(id) {
  try {
    const r = await fetch('/api/feed/cancel', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id }) });
    const j = await r.json();
    toast(r.ok ? '已发出停止' : (j.error || '停止失败'));
    loadDetail(false);
  } catch (e) { toast('停止失败'); }
}
async function rate(id, rating) {
  try {
    const r = await fetch('/api/feed/rate', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, rating }) });
    const j = await r.json();
    if (!r.ok) { toast(j.error || '评价失败'); return; }
    toast(rating ? '已记录：' + j.executor + ' 在这类任务上共 ' + j.rated + ' 次评价，均分 ' + j.mean : '已撤销评价');
    loadDetail(false);
  } catch (e) { toast('评价失败'); }
}
async function loadDetail(scrollEnd) {
  if (!S.sel) { renderDetail(scrollEnd); return; }
  try {
    const r = await fetch('/api/feed/task?id=' + encodeURIComponent(S.sel));
    if (!r.ok) return;
    S.detail = await r.json();
    renderDetail(scrollEnd);
  } catch (e) {}
}
function partsText(p) {
  if (!p) return '';
  const lat = p.samples ? '均 ' + fmtDur(p.latency_ema_ms) + ' / ' + p.samples + ' 次' : '无耗时记录';
  const fit = p.rated ? p.fit + '（配置 ' + p.fit_static + '，' + p.rated + ' 次评价均 ' + p.rating + '）' : p.fit;
  return '适配 ' + fit + ' · 速度 ' + p.speed + ' · 成本 ' + p.cost + ' · 负载 ' + p.load + ' · ' + lat;
}
function scoreTable(route) {
  const cands = (route && route.candidates) || [];
  const rej = (route && route.rejected) || [];
  if (!cands.length && !rej.length) return '';
  const max = Math.max(1, ...cands.map(c => c.score || 0));
  const rows = cands.map(c => '<tr><td class="mono">' + esc(c.name) + (c.name === route.chosen ? ' <span class="pill ok">选中</span>' : '') +
    '</td><td><div class="bar"><i style="width:' + Math.round(100 * (c.score || 0) / max) + '%"></i></div></td><td class="num">' + c.score + '</td><td class="dim">' + partsText(c.parts) + '</td></tr>').join('') +
    rej.map(r => '<tr><td class="mono dim">' + esc(r.name) + '</td><td colspan="3" class="dim">' + esc(REASON[r.reason] || r.reason) + '</td></tr>').join('');
  return '<details><summary>候选与评分（' + cands.length + ' 个候选，' + rej.length + ' 个排除）</summary><table class="ctable">' + rows + '</table></details>';
}
const REASON = { unknown_account: '未在配置中', disabled: '已停用', model_not_served: '不提供所需模型', context_too_small: '上下文不够', budget_exhausted: '预算用完', daily_limit_reached: '今日次数用完', quota_parked: '额度暂停中', circuit_open: '熔断中', rpm_exhausted: '每分钟限额满', concurrency_limit: '并发已满' };

const ST = { running: '进行中', ok: '完成', failed: '失败', cancelled: '已停止' };
function syncFollow() {
  const id = S.selThread;
  $('followbar').classList.toggle('on', !!id);
  if (!id) return;
  const row = threadRow(id);
  const running = !!(row && row.status === 'running');
  $('follow-go').disabled = running;
  const who = row && row.executor ? row.executor : '';
  $('follow-hint').textContent = running ? '这一轮还在进行——完成或停止后可以继续' :
    row && row.mode === 'agent' ? '继续交给 agent ' + who + '：续接它自己的会话，它记得之前做过什么' :
    row && row.mode === 'committee' ? '继续由同一组委员会成员作答，带上前面的对话' :
    '继续对话：带上前面 ' + (row ? row.n : '') + ' 轮内容' + (who ? '，优先由 ' + who + ' 回答' : '');
}
function mdHtml(text) {
  const parts = String(text).split(/```[^\n]*\n?/);
  return parts.map((p, i) => i % 2 ? '<pre>' + esc(p) + '</pre>' : esc(p).replace(/`([^`\n]+)`/g, '<code>$1</code>').replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>')).join('');
}
function renderConversation(d) {
  const turns = S.thread ? S.thread.turns.map(x => Object.assign({}, x)) : [];
  const row = S.selThread ? threadRow(S.selThread) : null;
  (row ? row.tasks : []).forEach(t => {
    const hit = turns.find(x => x.request_id === t.id);
    if (hit) hit.inFeed = true;
    else turns.push({ request_id: t.id, prompt: (d && d.id === t.id) ? d.prompt : t.title, answer: '', executor: t.executor, status: t.status, live: true, inFeed: true });
  });
  if (!turns.length) return '<div class="empty">加载对话…</div>';
  return turns.map((x, i) => {
    let answer = x.answer;
    if (x.live) { const ref = S.refs[x.request_id]; answer = (ref && S.localAnswers[ref]) || (d && d.id === x.request_id ? d.answer : ''); }
    return '<div class="turnblk"><div class="meta"><b style="color:var(--text)">第 ' + (i + 1) + ' 轮</b><span class="pill ' + x.status + '">' + (ST[x.status] || x.status) + '</span>' +
      '<span class="mono">' + esc(x.executor || '–') + '</span>' +
      (x.inFeed ? '<span class="more" style="margin-left:auto" onclick="selectTurn(\'' + esc(x.request_id) + '\')">查看执行过程</span>' : '') + '</div>' +
      '<div class="q">' + esc(x.prompt || '') + '</div>' +
      '<div class="a">' + (answer ? mdHtml(answer) : '<span class="dim">' + (x.status === 'running' ? '进行中…' : '没有输出') + '</span>') + '</div></div>';
  }).join('');
}
function renderDetail(scrollEnd) {
  const d = S.detail;
  const box = $('dbody');
  syncFollow();
  if (!d) {
    if (!S.selThread) return;
    const th = S.thread;
    box.innerHTML = '<div class="dhead"><div class="dtitle">' + esc(th ? th.title : '加载…') + '</div><div class="chips"><span>历史对话（网关重启前的记录，执行过程未保存）</span>' +
      (th ? '<span><b>' + th.turns.length + '</b> 轮</span>' : '') + '<span class="mono dim">' + esc(S.selThread) + '</span></div></div>' +
      '<div class="scroll">' + renderConversation(null) + '</div>';
    const sc0 = box.querySelector('.scroll'); if (sc0 && scrollEnd) sc0.scrollTop = sc0.scrollHeight;
    return;
  }
  const prevScroll = box.querySelector('.scroll');
  const atBottom = prevScroll ? (prevScroll.scrollHeight - prevScroll.scrollTop - prevScroll.clientHeight < 40) : true;
  const keepTop = prevScroll ? prevScroll.scrollTop : 0;
  const stTxt = ST[d.status] || d.status;
  const tts = S.selThread ? ((threadRow(S.selThread) || { tasks: [] }).tasks) : [];
  const nTurns = Math.max(tts.length, S.thread ? S.thread.turns.length : 0);
  if (S.detailTab === 'conv' && nTurns < 2) S.detailTab = 'trace';
  const turnsHtml = tts.length > 1 ? '<div class="turns">轮次' + tts.map(t => '<button class="' + (t.id === d.id ? 'on ' : '') + t.status + '" title="' + esc(t.title) + '" onclick="selectTurn(\'' + esc(t.id) + '\')">' + (t.turn || '?') + '</button>').join('') + '</div>' : '';
  const ref = S.refs[d.id];
  const answer = (ref && S.localAnswers[ref]) || d.answer || '';
  const nSteps = (d.timeline || []).filter(e => e.kind === 'step' && (e.step === 'tool')).length;
  box.innerHTML =
    '<div class="dhead">' +
      '<div class="dtitle">' + (esc(d.title) || '<span class="dim">（无标题）</span>') + '</div>' +
      '<div class="chips"><span class="pill ' + d.status + '">' + stTxt + '</span>' +
        (d.turn > 1 ? '<span>第 <b>' + d.turn + '</b> 轮</span>' : '') +
        '<span>执行 <b class="mono">' + esc(d.executor || '–') + '</b></span>' +
        '<span>' + (d.mode === 'agent' ? 'Agent' : d.mode === 'committee' ? '委员会' : '问答') + ' · ' + esc(CAT[d.category] || d.category || '通用') + '</span>' +
        '<span>耗时 <b>' + fmtDur(d.duration_ms) + '</b></span>' +
        (nSteps ? '<span>工具 <b>' + nSteps + '</b> 次</span>' : '') +
        '<span>来源 ' + esc(SRC[d.source] || d.source) + '</span>' +
        '<span class="mono dim" style="cursor:pointer" title="复制 request id" onclick="copy(\'' + esc(d.id) + '\')">' + esc(d.id) + '</span>' +
        (d.review_score ? '<span title="' + esc((d.reviewer || '') + '：' + (d.review_reason || '')) + '">抽检 <b>' + d.review_score + '/5</b></span>' : '') +
        (d.status === 'running' ? '<button class="stopbtn" title="结束这个任务：杀掉 agent 进程 / 放弃等待上游，不换下一个候选，也不扣执行者的健康分" onclick="stopTask(\'' + esc(d.id) + '\')">■ 停止</button>' : '') +
        (d.status === 'ok' && d.executor ? '<span class="rate" title="你的评价会计入 ' + esc(d.executor) + ' 在这类任务上的质量分，影响以后的路由">' +
          '<button class="' + (d.user_rating > 0 ? 'on' : '') + '" onclick="rate(\'' + esc(d.id) + '\',' + (d.user_rating > 0 ? 0 : 1) + ')">👍</button>' +
          '<button class="' + (d.user_rating < 0 ? 'on' : '') + '" onclick="rate(\'' + esc(d.id) + '\',' + (d.user_rating < 0 ? 0 : -1) + ')">👎</button></span>' : '') +
        '</div>' +
      turnsHtml +
      (d.route_summary ? '<div class="route' + (S.routeFold ? ' fold' : '') + '"><span class="k tog" id="route-tog" title="' + (S.routeFold ? '展开' : '收起') + '路由说明（g）">' + (S.routeFold ? '▸' : '▾') + ' 路由</span><div class="rs" style="min-width:0">' + esc(d.route_summary) + scoreTable(d.route) + '</div></div>' : '') +
      (d.status === 'failed' && d.error ? '<div class="route" style="border-color:rgba(248,81,73,.4)"><span class="k" style="color:var(--err)">失败</span><div>' + esc(d.error) + '</div></div>' : '') +
    '</div>' +
    '<div class="dtabs"><button class="dtab' + (S.detailTab === 'trace' ? ' on' : '') + '" data-t="trace">执行过程</button>' +
      '<button class="dtab' + (S.detailTab === 'answer' ? ' on' : '') + '" data-t="answer">输出</button>' +
      (nTurns > 1 ? '<button class="dtab' + (S.detailTab === 'conv' ? ' on' : '') + '" data-t="conv">对话 · ' + nTurns + ' 轮</button>' : '') + '</div>' +
    '<div class="scroll">' + (S.detailTab === 'trace' ? renderTimeline(d) : S.detailTab === 'conv' ? renderConversation(d) : renderAnswer(answer, d)) + '</div>';
  if ($('route-tog')) $('route-tog').onclick = toggleRoute;
  box.querySelectorAll('.dtab').forEach(b => b.onclick = () => { S.detailTab = b.dataset.t; if (S.detailTab === 'conv') loadThread(); renderDetail(S.detailTab !== 'answer'); });
  box.querySelectorAll('.tool .h').forEach(h => h.onclick = () => {
    const el = h.parentElement; el.classList.toggle('open');
    if (el.classList.contains('open')) S.openTools.add(el.dataset.id); else S.openTools.delete(el.dataset.id);
  });
  box.querySelectorAll('.more').forEach(m => m.onclick = () => {
    const c = m.previousElementSibling; c.classList.toggle('open');
    if (c.classList.contains('open')) S.openText.add(m.dataset.k); else S.openText.delete(m.dataset.k);
    m.textContent = c.classList.contains('open') ? '收起' : '展开';
  });
  box.querySelectorAll('.clamp').forEach(c => {
    const m = c.nextElementSibling;
    if (m && m.classList.contains('more') && !c.classList.contains('open') && c.scrollHeight <= c.clientHeight + 2) m.remove();
  });
  const sc = box.querySelector('.scroll');
  if (sc) sc.scrollTop = (scrollEnd || (atBottom && d.status === 'running')) ? sc.scrollHeight : keepTop;
}
function toggleRoute() {
  S.routeFold = !S.routeFold;
  localStorage.setItem('oasis_route_fold', S.routeFold ? '1' : '0');
  renderDetail(false);
}
function renderAnswer(answer, d) {
  if (!answer) {
    return '<div class="empty">' + (d.status === 'running' ? '等待输出…' :
      '没有输出') + '</div>';
  }
  return '<div class="answer">' + mdHtml(answer) + '</div>';
}
function clampText(text, key) {
  const open = S.openText.has(key);
  return '<div class="clamp' + (open ? ' open' : '') + '">' + esc(text) + '</div><span class="more" data-k="' + esc(key) + '">' + (open ? '收起' : '展开') + '</span>';
}
function renderTimeline(d) {
  const tl = d.timeline || [];
  if (!tl.length) return '<div class="empty">等待事件…</div>';
  const results = {};
  tl.forEach(e => { if (e.kind === 'step' && e.step === 'tool_result' && e.id) results[e.id] = e; });
  const toolIds = new Set(tl.filter(e => e.kind === 'step' && e.step === 'tool').map(e => e.id));
  const t0 = d.started_ms;
  const rows = [];
  const row = (cls, e, icon, body) => rows.push('<div class="ev ' + cls + '"><div class="ts">+' + fmtDur(Math.max(0, e.at - t0)) + '</div><div class="ic">' + icon + '</div><div class="bd">' + body + '</div></div>');
  tl.forEach((e, i) => {
    switch (e.kind) {
      case 'route': row('route', e, '⇢', '<span class="lbl">路由</span>' + esc(e.text)); break;
      case 'attempt': row('att', e, '▸', '<span class="lbl">开始</span><span class="mono">' + esc(e.account) + '</span> 开始执行'); break;
      case 'attempt_end':
        if (e.ok) row('ok', e, '✓', '<span class="mono">' + esc(e.account) + '</span> 完成 <span class="muted">· ' + fmtDur(e.latency_ms) + '</span>');
        else row('bad', e, '✗', '<span class="hl"><span class="mono">' + esc(e.account) + '</span> 失败：' + esc(e.hint || e.error) + '</span>' +
          (e.error && e.error !== e.hint ? '<div class="err-raw">' + esc(e.error) + '</div>' : '') + ' <span class="muted">· ' + fmtDur(e.latency_ms) + '</span>');
        break;
      case 'handoff': row('ho', e, '⇄', '<span class="lbl" style="color:var(--warn)">切换 ' + esc(e.level) + '</span>' + esc(e.text)); break;
      case 'member':
        row(e.ok ? 'ok' : 'bad', e, '◆', '<span class="lbl">成员</span><span class="mono">' + esc(e.account) + '</span>' +
          (e.ok ? ' 作答 · ' + fmtDur(e.latency_ms) + clampText(e.text || '', d.id + ':m:' + e.account) : ' <span class="hl">未能作答：' + esc(e.hint || e.error || '') + '</span>'));
        break;
      case 'rating': row('ok', e, '★', '<span class="lbl">评价</span>' + esc(e.text)); break;
      case 'done': row(e.ok ? 'ok' : 'bad', e, '■', e.ok ? '任务完成' : d.status === 'cancelled' ? '<span class="hl">' + esc(e.error || '已停止') + '</span>' : '<span class="hl">任务失败' + (e.error ? '：' + esc(e.error) : '') + '</span>'); break;
      case 'step': {
        const ag = e.agent ? ' <span class="dim mono" style="font-size:11px">' + esc(e.agent) + '</span>' : '';
        if (e.step === 'thinking') row('think', e, '…', '<span class="lbl">思考</span>' + ag + clampText(e.text, d.id + ':' + i));
        else if (e.step === 'text') row('', e, '¶', '<span class="lbl">说明</span>' + ag + clampText(e.text, d.id + ':' + i));
        else if (e.step === 'tool') {
          const r = results[e.id];
          const st = !r ? (d.status === 'running' ? '<span class="spin"></span>' : '<span class="dim">?</span>') : (r.ok ? '<span style="color:var(--ok)">✓</span>' : '<span style="color:var(--err)">✗</span>');
          const open = S.openTools.has(e.id) ? ' open' : '';
          row('', e, '⚙', '<div class="tool' + open + '" data-id="' + esc(e.id) + '"><div class="h"><span class="n">' + esc(e.name) + '</span><span class="in" title="' + esc(e.input) + '">' + esc(e.input) + '</span><span class="s">' + st + '</span></div>' +
            '<pre class="out">' + (r ? esc(r.output || '（无输出）') : '执行中…') + '</pre></div>');
        } else if (e.step === 'tool_result') {
          if (!e.id || !toolIds.has(e.id)) row(e.ok ? '' : 'bad', e, '↳', '<span class="lbl">工具结果</span><div class="err-raw">' + esc(e.output) + '</div>');
        } else if (e.step === 'usage') {
          const bits = [];
          if (e.turns) bits.push(e.turns + ' 轮');
          if (e.tool_calls) bits.push(e.tool_calls + ' 次工具');
          if (e.output_tokens) bits.push(e.output_tokens + ' 输出 tokens');
          if (e.duration_ms) bits.push('agent 自报 ' + fmtDur(e.duration_ms));
          if (bits.length) row('', e, 'Σ', '<span class="lbl">统计</span><span class="muted">' + bits.join(' · ') + '</span>');
        }
        break;
      }
    }
  });
  return '<div class="tl">' + rows.join('') + '</div>';
}

/* ---------- right rail ---------- */
async function loadAlerts() {
  try {
    const j = await (await fetch('/api/alerts')).json();
    const al = j.alerts || [];
    const errs = al.filter(a => a.severity === 'error').length;
    $('alerts-count').innerHTML = al.length ? '<span style="color:' + (errs ? 'var(--err)' : 'var(--warn)') + '">' + al.length + ' 项</span>' : '';
    $('h-alerts').innerHTML = al.length ? '<span class="dot ' + (errs ? 'err' : 'warn') + '"></span><b>' + al.length + '</b> 项待处理' : '';
    $('alerts').innerHTML = al.length ? al.map((a, i) =>
      '<div class="alert ' + a.severity + '"><div class="at"><b>' + esc(a.title) + '</b><span class="tg">' + esc(a.target) + '</span></div>' +
      '<div class="dt">' + esc(a.detail) + '</div>' +
      (a.fix ? '<div class="fix"><code>' + esc(a.fix) + '</code><button data-i="' + i + '">复制</button></div>' : '') + '</div>').join('')
      : '<div class="allok">✓ 所有已启用的账户和 agent 都正常</div>';
    $('alerts').querySelectorAll('.fix button').forEach(b => b.onclick = () => copy(al[+b.dataset.i].fix.split('   #')[0].trim()));
  } catch (e) {}
}
let accCache = [], agtCache = [];
function accHealth(a) {
  if (!a.enabled) return 'off';
  if (a.auth_invalid || a.breaker === 'open') return 'err';
  if (a.parked_until_ms || a.breaker === 'half_open') return 'warn';
  return 'ok';
}
function agtHealth(a) {
  if (!a.enabled) return 'off';
  if (a.breaker === 'open') return 'err';
  if (a.consecutive_failures > 0 || a.breaker === 'half_open') return 'warn';
  return 'ok';
}
async function loadResources() {
  try {
    const [acc, agt] = await Promise.all([fetch('/api/accounts').then(r => r.json()), fetch('/api/agents').then(r => r.json())]);
    accCache = acc.accounts || []; agtCache = agt.configured || [];
    if (['pick', 'committee'].includes($('category').value) && /加载/.test($('picker').textContent)) renderPicker();
    const ea = accCache.filter(a => a.enabled), eg = agtCache.filter(a => a.enabled);
    const okA = ea.filter(a => accHealth(a) === 'ok').length, okG = eg.filter(a => agtHealth(a) === 'ok').length;
    $('h-acc').innerHTML = '<span class="dot ' + (okA === ea.length ? 'ok' : 'warn') + '"></span>账户 <b>' + okA + '/' + ea.length + '</b>';
    $('h-agt').innerHTML = '<span class="dot ' + (okG === eg.length ? 'ok' : 'warn') + '"></span>Agent <b>' + okG + '/' + eg.length + '</b>';
    $('h-today').innerHTML = 'API 今日 <b>' + accCache.reduce((s, a) => s + (a.day_requests || 0), 0) + '</b> 次';
    const lat = a => a.total_requests ? fmtDur(a.latency_ema_ms) : '<span class="dim">–</span>';
    const rowA = a => '<tr title="' + esc((a.models || []).join(', ') + (a.last_error ? '\n最近错误：' + a.last_error : '')) + '"><td><span class="dot ' + accHealth(a) + '"></span></td><td class="n mono">' + esc(a.name) + '</td><td class="num">' + lat(a) + '</td><td class="num">' + (a.day_requests || 0) + '</td></tr>';
    const rowG = a => '<tr title="' + esc((a.strengths || []).join(', ') + (a.last_error ? '\n最近错误：' + a.last_error : '')) + '"><td><span class="dot ' + agtHealth(a) + '"></span></td><td class="n mono">' + esc(a.name) + '</td><td class="num">' + lat(a) + '</td><td class="num">' + (a.in_flight ? '<span style="color:var(--accent)">运行 ' + a.in_flight + '</span>' : (a.total_requests || 0)) + '</td></tr>';
    $('resources').innerHTML = '<tr class="sec"><td colspan="4">Agent</td></tr>' + eg.map(rowG).join('') +
      '<tr class="sec"><td colspan="4">API 账户</td></tr>' + ea.map(rowA).join('') +
      (accCache.length + agtCache.length > ea.length + eg.length ? '<tr class="sec"><td colspan="4">已停用 ' + (accCache.length - ea.length + agtCache.length - eg.length) + ' 个 · 见诊断页</td></tr>' : '');
  } catch (e) {}
}

/* ---------- live events ---------- */
let ws, wsRetry = 0;
function connectWs() {
  ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws' + (oasisToken ? '?token=' + encodeURIComponent(oasisToken) : ''));
  ws.onopen = () => { wsRetry = 0; $('h-ws').innerHTML = '<span class="dot live"></span>实时'; S.dirtyList = true; };
  ws.onclose = () => {
    $('h-ws').innerHTML = '<span class="dot warn"></span>重连中';
    setTimeout(connectWs, Math.min(10000, 1000 * Math.pow(2, wsRetry++)));
  };
  ws.onmessage = m => {
    let j; try { j = JSON.parse(m.data); } catch (e) { return; }
    if (j.type === 'event') {
      if (j.event === 'task_started' && j.data && j.data.client_ref) {
        S.refs[j.request_id] = j.data.client_ref;
        if (j.data.client_ref === S.pendingRef) {
          S.pendingRef = null; S.sel = j.request_id; S.detailTab = S.detailTab === 'conv' && j.data.turn > 1 ? 'conv' : 'trace';
          S.selThread = j.data.thread || null; S.selKey = j.data.thread || j.request_id;
          S.openTools.clear(); S.openText.clear(); S.dirtyDetail = true;
        }
      }
      S.dirtyList = true;
      if (j.request_id === S.sel) S.dirtyDetail = true;
      if (j.event === 'task_done') {
        setTimeout(loadResources, 300); setTimeout(loadAlerts, 400);
        const t = S.tasks.find(x => x.id === j.request_id);
        if (t && t.thread && t.thread === S.selThread) setTimeout(loadThread, 250);
      }
      diagOnEvent(j);
    } else if (j.type === 'decision') {
      diagOnDecision(j.decision);
    }
  };
}
setInterval(() => {
  if (S.dirtyList) { S.dirtyList = false; loadList(); }
  if (S.dirtyDetail) { S.dirtyDetail = false; loadDetail(false); }
}, 300);
setInterval(() => {
  if (S.tasks.some(t => t.status === 'running')) { renderList(); if (S.detail && S.detail.status === 'running') S.dirtyDetail = true; }
}, 1000);

/* ---------- right rail ---------- */
function setRail(on) {
  $('work').classList.toggle('rail-off', !on);
  $('rail-toggle').classList.toggle('on', on);
  localStorage.setItem('oasis_rail', on ? '1' : '0');
}
$('rail-toggle').onclick = () => setRail($('work').classList.contains('rail-off'));
$('rail-hide').onclick = () => setRail(false);
$('h-alerts').onclick = () => setRail(true);
setRail(localStorage.getItem('oasis_rail') !== '0');

/* ---------- left list: collapse + resize ---------- */
function setList(on) {
  $('work').classList.toggle('list-off', !on);
  $('list-toggle').classList.toggle('on', on);
  localStorage.setItem('oasis_list', on ? '1' : '0');
}
$('list-toggle').onclick = () => setList($('work').classList.contains('list-off'));
$('list-hide').onclick = () => setList(false);
setList(localStorage.getItem('oasis_list') !== '0');
const savedLw = parseInt(localStorage.getItem('oasis_lw') || '0', 10);
if (savedLw) $('work').style.setProperty('--lw', savedLw + 'px');
$('lresize').onmousedown = e => {
  e.preventDefault();
  const r = $('lresize'), x0 = e.clientX, w0 = r.parentElement.getBoundingClientRect().width;
  let w = w0;
  r.classList.add('drag'); document.body.classList.add('resizing');
  const move = ev => { w = Math.max(220, Math.min(720, w0 + ev.clientX - x0)); $('work').style.setProperty('--lw', w + 'px'); };
  const up = () => {
    r.classList.remove('drag'); document.body.classList.remove('resizing');
    document.removeEventListener('mousemove', move); document.removeEventListener('mouseup', up);
    localStorage.setItem('oasis_lw', String(Math.round(w)));
  };
  document.addEventListener('mousemove', move); document.addEventListener('mouseup', up);
};
$('lresize').ondblclick = () => { $('work').style.removeProperty('--lw'); localStorage.removeItem('oasis_lw'); };

/* ---------- keyboard ---------- */
document.addEventListener('keydown', e => {
  const typing = ['TEXTAREA', 'INPUT', 'SELECT'].includes(document.activeElement.tagName);
  if (e.key === 'Escape' && typing) { document.activeElement.blur(); return; }
  if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.key === '/') { e.preventDefault(); promptEl.focus(); }
  else if (e.key === '\\') { setRail($('work').classList.contains('rail-off')); }
  else if (e.key === '[') { setList($('work').classList.contains('list-off')); }
  else if (e.key === 'j' || e.key === 'k') {
    const list = visibleTasks(); if (!list.length) return;
    const i = list.findIndex(r => r.key === S.selKey);
    const n = e.key === 'j' ? Math.min(list.length - 1, i + 1) : Math.max(0, i < 0 ? 0 : i - 1);
    select(list[n].key);
    const el = document.querySelector('.task.sel'); if (el) el.scrollIntoView({ block: 'nearest' });
  } else if (e.key === '1') { S.detailTab = 'trace'; renderDetail(true); }
  else if (e.key === '2') { S.detailTab = 'answer'; renderDetail(false); }
  else if (e.key === '3' && S.selThread) { S.detailTab = 'conv'; loadThread(); renderDetail(true); }
  else if (e.key === 'g') { toggleRoute(); }
  else if (e.key === 'r' && S.selThread) { e.preventDefault(); $('follow-in').focus(); }
});

/* ---------- diagnostics (raw views) ---------- */
const log = $('log');
function addLine(msg, cls) {
  const div = document.createElement('div');
  div.textContent = '[' + new Date().toLocaleTimeString() + '] ' + msg;
  if (cls) div.className = cls;
  log.prepend(div);
  while (log.children.length > 100) log.removeChild(log.lastChild);
}
function handoffLabel(h) { return h.level + ' · ' + h.matched_bytes + '/' + h.sent_bytes + 'B' + (h.diverged ? ' · 分叉' : ''); }
function handoffSummary(d) {
  const hs = d.handoffs || [];
  if (hs.length) return ' [handoff ' + hs.map(h => h.from + '→' + h.to + ' ' + handoffLabel(h)).join(', ') + ']';
  return (d.attempts || []).length > 1 ? ' [回退]' : '';
}
function decisionLine(d) {
  const attempts = (d.attempts || []).map(a => a.account + '(' + (a.status != null ? a.status : (a.error || '?')) + ':' + a.latency_ms + 'ms)').join(' → ');
  const rejected = (d.rejected || []).map(r => r.account + '✗' + r.reason).join(' ');
  const scores = (d.scores || []).map(s => s.account + ':' + s.score).join(' ');
  return d.task_category + ' → ' + (d.chosen || '无') + handoffSummary(d) + ' | attempts: ' + attempts + (rejected ? ' | 拒绝: ' + rejected : '') + (scores ? ' | scores: ' + scores : '');
}
function diagOnDecision(d) { addLine(decisionLine(d), handoffSummary(d) ? 'handoff' : null); }
async function refreshDecisions() {
  const data = await (await fetch('/api/decisions?limit=20')).json();
  log.innerHTML = '';
  for (const d of (data.decisions || []).slice(0, 20).reverse()) diagOnDecision(d);
}
function renderAccTable() {
  $('acc-table').innerHTML = '<tr><th></th><th>账户</th><th>服务商</th><th>熔断</th><th>延迟 EMA</th><th>在途</th><th>今日</th><th>本月</th><th>模型</th><th>最近错误</th></tr>' +
    accCache.map(a => '<tr><td><span class="dot ' + accHealth(a) + '"></span></td><td class="mono">' + esc(a.name) + '</td><td>' + esc(a.provider) + '</td><td>' + esc(a.breaker) +
      '</td><td class="num">' + a.latency_ema_ms + 'ms</td><td class="num">' + a.in_flight + '</td><td class="num">' + a.day_requests + '/' + (a.daily_limit || '∞') +
      '</td><td class="num">' + esc(a.month_spent_usd) + ' / ' + esc(a.month_budget_usd) + '</td><td class="muted">' + esc((a.models || []).join(', ')) + '</td><td class="err-raw">' + esc(a.last_error || '') + '</td></tr>').join('');
}
async function refreshAgentsDiag() {
  const data = await (await fetch('/api/agents')).json();
  $('agents-box').innerHTML = (data.agents || []).map(a =>
    '<div><span class="mono">' + esc(a.name) + '</span> ' + (a.installed ? '<span class="pill ok">已装</span>' : '<span class="pill failed">未装</span>') + ' ' +
    (a.logged_in ? '<span class="pill ok">已登录</span>' : '<span class="pill running">未登录</span>') + ' ' + (a.active ? '<span class="pill ok">活跃</span>' : '') +
    ' <span class="muted">' + esc((a.projects || []).slice(0, 2).join(', ')) + '</span></div>').join('');
}
async function refreshActivity() {
  const data = await (await fetch('/api/activity')).json();
  const rows = (data.sessions || []).map(s => '<div style="border-bottom:1px solid var(--line);padding:4px 0"><div>' + esc(s.project) +
    ' <span class="tag">' + s.turns + ' 轮</span>' + (s.tools ? ' <span class="tag">' + s.tools + ' 工具</span>' : '') + '</div><div class="muted">' + esc(s.last_excerpt || '') + '</div></div>');
  $('activity-box').innerHTML = rows.length ? rows.join('') : '<span class="dim">暂无活动记录</span>';
}
async function refreshInbox() {
  const data = await (await fetch('/api/inbox')).json();
  $('inbox-box').innerHTML = (data.inboxes || []).map(i => '<div><span class="mono">' + esc(i.agent) + '</span>: ' + (i.unread > 0 ? '<span class="pill ok">' + i.unread + ' 未读</span>' : '<span class="dim">0</span>') + '</div>').join('') || '<span class="dim">无</span>';
}
async function sendReply() {
  const to = $('reply-to').value.trim(), text = $('reply-text').value.trim();
  if (!to || !text) { toast('填写回复对象和内容'); return; }
  await fetch('/api/inbox/reply', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ to_agent: to, text }) });
  $('reply-text').value = '';
  refreshInbox();
  toast('已回复 ' + to);
}
function refreshDiag() { renderAccTable(); refreshDecisions(); refreshAgentsDiag(); refreshActivity(); refreshInbox(); }

const NS = 'http://www.w3.org/2000/svg';
const graphBox = $('graph-box');
const GW = 900, GH = 400;
const HANDOFF_COLORS = { G1: '#3fb950', G2: '#d29922', G3: '#a371f7', G0: '#f85149' };
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
  mk('soma-fill', '#7aa2ff', '#2f4fa8');
  mk('soma-ok', '#86efac', '#15803d');
  mk('soma-fail', '#fca5a5', '#b91c1c');
  mk('soma-cand', '#cbd5e1', '#475569');
  for (const lv in HANDOFF_COLORS) {
    const m = svgEl('marker', { id: 'ho-' + lv, viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, defs);
    svgEl('path', { d: 'M 0 0 L 10 5 L 0 10 z', fill: HANDOFF_COLORS[lv] }, m);
  }
  const g = svgEl('g', { class: 'gnode soma glow' }, svg);
  svgEl('circle', { cx: GW / 2, cy: 44, r: 16 }, g);
  svgEl('text', { x: GW / 2, y: 78, 'text-anchor': 'middle', fill: '#d6dbe3', 'font-size': 14 }, g).textContent = '任务 · ' + (req.category || 'general');
  svgEl('text', { x: GW / 2, y: 96, 'text-anchor': 'middle', fill: '#7a8391', 'font-size': 11 }, g).textContent = 'goal=' + (req.goal || '-');
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
  return svgEl('path', { d, fill: 'none', stroke: '#3a4250', 'stroke-width': 2, class: 'gedge' + (kind === 'feedback' ? ' fallback' : '') }, graph.svg);
}
function gNode(x, y, label, opts) {
  opts = opts || {};
  const g = svgEl('g', { class: 'gnode soma' + (opts.cls ? ' ' + opts.cls : '') }, graph.svg);
  svgEl('circle', { cx: x, cy: y, r: 14, stroke: 'rgba(148,163,184,.35)', 'stroke-width': 1.5 }, g);
  svgEl('text', { x, y: y + 31, 'text-anchor': 'middle', fill: '#d6dbe3', 'font-size': 12 }, g).textContent = shortName(label, 14);
  if (opts.sub) svgEl('text', { x, y: y + 46, 'text-anchor': 'middle', fill: opts.subColor || '#7a8391', 'font-size': 10 }, g).textContent = shortName(String(opts.sub), 26);
  if (opts.mark) svgEl('text', { x: x + 16, y: y - 12, 'text-anchor': 'middle', fill: opts.markColor || '#3fb950', 'font-size': 13, 'font-weight': 'bold' }, g).textContent = opts.mark;
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
  svgEl('path', { d: 'M ' + from.x + ' ' + y1 + ' C ' + from.x + ' ' + (y1 - lift) + ', ' + to.x + ' ' + (y2 - lift) + ', ' + to.x + ' ' + y2,
    fill: 'none', stroke: color, class: 'gedge handoff', 'marker-end': 'url(#ho-' + (HANDOFF_COLORS[h.level] ? h.level : 'G0') + ')' }, graph.svg);
  svgEl('text', { x: (from.x + to.x) / 2, y: Math.min(y1, y2) - lift * 0.75 - 4, 'text-anchor': 'middle', fill: color, 'font-size': 11, 'font-weight': 600 }, graph.svg)
    .textContent = 'handoff ' + h.level + (h.model_changed ? ' · 换模型' : '');
}
function diagOnEvent(ev) {
  if (!ev || !ev.data) return;
  const sum = $('graph-summary');
  if (ev.event === 'task_started') {
    gReset({ category: ev.data.category, goal: ev.data.goal });
    graph.requestId = ev.request_id;
    sum.textContent = '路由中…';
    return;
  }
  if (!graph.svg || ev.request_id !== graph.requestId) return;
  if (ev.event === 'routed') {
    const cands = (ev.data.candidates || []).slice(0, 6);
    const rejs = (ev.data.rejected || []).slice(0, 3);
    const total = cands.length + rejs.length;
    const y = 165;
    const xOf = i => 60 + (i + 0.5) * ((GW - 120) / Math.max(total, 1));
    cands.forEach((cd, i) => {
      const x = xOf(i);
      const nd = gNode(x, y, cd.name, { cls: cd.name === ev.data.chosen ? 'glow' : 'cand', sub: 'score=' + cd.score });
      gEdgeTo(graph.root, { x, y }, 'cand');
      graph.candidates.push({ name: cd.name, g: nd, x, y });
    });
    rejs.forEach((r, j) => {
      const x = xOf(cands.length + j);
      gNode(x, y, r.name, { cls: 'fail', sub: r.reason, subColor: '#f85149', mark: '✗', markColor: '#f85149' });
      gEdgeTo(graph.root, { x, y }, 'rej');
    });
    if (ev.data.chosen) sum.textContent = '→ 选中 ' + ev.data.chosen;
  } else if (ev.event === 'attempt_started') {
    const i = graph.attempts.length;
    const y = 300, x = 120 + i * 165;
    const nd = gNode(x, y, ev.data.account, { cls: 'glow', sub: '执行中…' });
    const from = graph.candidates.find(t => t.name === ev.data.account) || graph.root;
    if (i === 0) gEdgeTo(from, { x, y }, 'dep');
    else { const prev = graph.attempts[i - 1]; gEdgeTo({ x: prev.x, y: prev.y }, { x, y }, 'feedback'); }
    graph.attempts.push({ name: ev.data.account, g: nd, x, y });
  } else if (ev.event === 'attempt_finished') {
    const t = graph.attempts.filter(t => t.name === ev.data.account && !t.finished).pop();
    if (t) {
      t.finished = true;
      t.g.remove();
      if (ev.data.status === 200) gNode(t.x, t.y, t.name, { cls: 'ok', sub: ev.data.latency_ms + 'ms', subColor: '#3fb950', mark: '✓', markColor: '#3fb950' });
      else gNode(t.x, t.y, t.name, { cls: 'fail', sub: ev.data.error || ('HTTP ' + ev.data.status), subColor: '#f85149', mark: '✗', markColor: '#f85149' });
    }
  } else if (ev.event === 'handoff') {
    gHandoff(ev.data);
    sum.textContent = 'handoff ' + ev.data.from + ' → ' + ev.data.to + '（' + handoffLabel(ev.data) + '）';
  } else if (ev.event === 'task_done') {
    sum.textContent = ev.data.ok ? '✓ 完成 — ' + ev.data.chosen + '（' + ev.data.attempts + ' 次尝试）' : '✗ 未完成 — 已尝试 ' + ev.data.attempts + ' 次';
  }
}

/* ---------- boot ---------- */
connectWs();
loadList();
loadAlerts();
loadResources();
setInterval(loadResources, 5000);
setInterval(loadAlerts, 15000);
setInterval(() => { if ($('view-diag').classList.contains('on')) renderAccTable(); }, 5000);
</script>
</body>
</html>|}
