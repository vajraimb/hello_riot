open Std
open Std.Collections
open Std.Data

(**
   AegisOTP — Industrial OTP Showcase Application
   Combining:
   - Multi-tier OTP Supervision Tree (ShardSupervisor OneForOne + Atacama & Nomad pools)
   - ETS-style lock-free ConcurrentHashMap state recovery + Stateful Shard Actors
   - Multi-core WorkerPool parallel SHA-256 compute engine
   - Std.Telemetry event bus + real-time RFC 6455 WebSocket broadcast hub
   - Atacama TCP Server (port 9100) + Nomad/Trail HTTP & WebSocket Server (port 8080)
*)

type Telemetry.event +=
  | OtpEvent of {
      kind: string;
      source: string;
      detail: string;
    }

type risk_result = {
  account: string;
  shard_id: int;
  shard_pid: string;
  shard_epoch: int;
  tx_count: int;
  total_amount: int;
  risk_score: int;
  verdict: string;
}

type shard_snapshot = {
  shard_id: int;
  pid: string;
  epoch: int;
  keys_count: int;
  ops_count: int;
  risk_alerts: int;
}

type Message.t +=
  | Shard_kv_set of {
      key: string;
      value: string;
      reply_to: Pid.t;
    }
  | Shard_kv_set_reply of {
      shard_id: int;
      pid: string;
      epoch: int;
    }
  | Shard_kv_get of {
      key: string;
      reply_to: Pid.t;
    }
  | Shard_kv_get_reply of {
      shard_id: int;
      pid: string;
      epoch: int;
      value: string option;
    }
  | Shard_eval_risk of {
      account: string;
      amount: int;
      reply_to: Pid.t;
    }
  | Shard_eval_risk_reply of risk_result
  | Shard_get_stats of {
      reply_to: Pid.t;
    }
  | Shard_get_stats_reply of shard_snapshot
  | Shard_inject_crash of {
      reason: string;
    }

type account_stat = {
  tx_count: int;
  total_amount: int;
}

type cluster = {
  num_shards: int;
  shard_pids: (int, Pid.t) ConcurrentHashMap.t;
  shard_epochs: (int, int) ConcurrentHashMap.t;
  shard_ops: (int, int) ConcurrentHashMap.t;
  shard_alerts: (int, int) ConcurrentHashMap.t;
  ets_kv: (string, string) ConcurrentHashMap.t;
  ets_accounts: (string, account_stat) ConcurrentHashMap.t;
  ws_clients: (int, Net.TcpStream.t) ConcurrentHashMap.t;
  recent_events: string list Agent.t;
  shard_sup: Supervisor.t;
  tcp_pool: Atacama.pool;
  http_pool: Atacama.pool;
}

let shard_for_key = fun ~num_shards key ->
  let h = Crypto.Digest.to_int (Crypto.hash_string key) in
  let pos = abs h in
  pos mod num_shards

let broadcast_ws_json = fun ws_clients payload_json ->
  let text = Json.to_string payload_json in
  let dead_ids = ref [] in
  ConcurrentHashMap.for_each
    ws_clients
    ~fn:(fun conn_id stream ->
      match Trail.Ws.send_text stream text with
      | Ok () -> ()
      | Error _ -> dead_ids := conn_id :: !dead_ids);
  List.for_each
    !dead_ids
    ~fn:(fun conn_id ->
      let _ = ConcurrentHashMap.remove ws_clients ~key:conn_id in
      ())

let emit_otp_event = fun ~kind ~source ~detail ->
  Telemetry.emit (OtpEvent { kind; source; detail })

let bump_counter = fun table key delta ->
  let prev = ConcurrentHashMap.get table ~key |> Option.unwrap_or ~default:0 in
  let next = prev + delta in
  let _ = ConcurrentHashMap.insert table ~key ~value:next in
  next

let run_shard_actor = fun
  ~shard_id
  ~num_shards
  ~shard_pids
  ~shard_epochs
  ~shard_ops
  ~shard_alerts
  ~ets_kv
  ~ets_accounts
  () ->
  let my_pid = self () in
  let my_pid_str = Pid.to_string my_pid in
  let _ = ConcurrentHashMap.insert shard_pids ~key:shard_id ~value:my_pid in
  let epoch = bump_counter shard_epochs shard_id 1 in
  let source = "shard_" ^ Int.to_string shard_id in
  if epoch > 1 then
    emit_otp_event
      ~kind:"supervisor_restart"
      ~source
      ~detail:("Restarted by ShardSupervisor (OneForOne) as " ^ my_pid_str ^ " [epoch=" ^ Int.to_string epoch ^ "]")
  else
    emit_otp_event
      ~kind:"shard_started"
      ~source
      ~detail:("Initialized shard actor " ^ my_pid_str ^ " [epoch=1]");
  let rec loop () =
    let selector msg =
      match msg with
      | Shard_kv_set _ -> Select msg
      | Shard_kv_get _ -> Select msg
      | Shard_eval_risk _ -> Select msg
      | Shard_get_stats _ -> Select msg
      | Shard_inject_crash _ -> Select msg
      | _ -> Skip
    in
    match receive ~selector () with
    | Shard_kv_set { key; value; reply_to } ->
        let _ = ConcurrentHashMap.insert ets_kv ~key ~value in
        let _ = bump_counter shard_ops shard_id 1 in
        emit_otp_event
          ~kind:"kv_set"
          ~source
          ~detail:("SET " ^ key ^ "=" ^ value ^ " (pid=" ^ my_pid_str ^ ")");
        send reply_to (Shard_kv_set_reply { shard_id; pid = my_pid_str; epoch });
        loop ()
    | Shard_kv_get { key; reply_to } ->
        let value = ConcurrentHashMap.get ets_kv ~key in
        let _ = bump_counter shard_ops shard_id 1 in
        send reply_to (Shard_kv_get_reply { shard_id; pid = my_pid_str; epoch; value });
        loop ()
    | Shard_eval_risk { account; amount; reply_to } ->
        let _ = bump_counter shard_ops shard_id 1 in
        let prev =
          ConcurrentHashMap.get ets_accounts ~key:account
          |> Option.unwrap_or ~default:{ tx_count = 0; total_amount = 0 }
        in
        let tx_count = prev.tx_count + 1 in
        let total_amount = prev.total_amount + amount in
        let _ =
          ConcurrentHashMap.insert
            ets_accounts
            ~key:account
            ~value:{ tx_count; total_amount }
        in
        let amount_score = min 60 (amount / 200) in
        let velocity_score = min 40 (tx_count * 8) in
        let risk_score = min 100 (amount_score + velocity_score) in
        let verdict =
          if risk_score >= 75 then (
            let _ = bump_counter shard_alerts shard_id 1 in
            emit_otp_event
              ~kind:"risk_alert"
              ~source
              ~detail:("HIGH_RISK account=" ^ account ^ " score=" ^ Int.to_string risk_score);
            "HIGH_RISK_BLOCKED"
          ) else if risk_score >= 45 then
            "ELEVATED_REVIEW"
          else
            "APPROVED"
        in
        send
          reply_to
          (
            Shard_eval_risk_reply {
              account;
              shard_id;
              shard_pid = my_pid_str;
              shard_epoch = epoch;
              tx_count;
              total_amount;
              risk_score;
              verdict;
            }
          );
        loop ()
    | Shard_get_stats { reply_to } ->
        let keys_count =
          ConcurrentHashMap.fold_left
            ets_kv
            ~init:0
            ~fn:(fun acc k _v ->
              if shard_for_key ~num_shards k = shard_id then
                acc + 1
              else
                acc)
        in
        let ops_count =
          ConcurrentHashMap.get shard_ops ~key:shard_id |> Option.unwrap_or ~default:0
        in
        let risk_alerts =
          ConcurrentHashMap.get shard_alerts ~key:shard_id |> Option.unwrap_or ~default:0
        in
        send
          reply_to
          (
            Shard_get_stats_reply {
              shard_id;
              pid = my_pid_str;
              epoch;
              keys_count;
              ops_count;
              risk_alerts;
            }
          );
        loop ()
    | Shard_inject_crash { reason } ->
        emit_otp_event
          ~kind:"chaos_crash"
          ~source
          ~detail:("Actor " ^ my_pid_str ^ " crashing: " ^ reason);
        Error (Failure ("Chaos fault injected in " ^ source ^ ": " ^ reason))
    | _ -> loop ()
  in
  loop ()

let get_shard_pid = fun cluster shard_id ->
  let idx = abs shard_id mod cluster.num_shards in
  ConcurrentHashMap.get cluster.shard_pids ~key:idx

let kv_set = fun cluster ~key ~value ->
  let shard_id = shard_for_key ~num_shards:cluster.num_shards key in
  match get_shard_pid cluster shard_id with
  | None -> Error "shard actor not available"
  | Some pid -> (
      send pid (Shard_kv_set { key; value; reply_to = self () });
      let selector msg =
        match msg with
        | Shard_kv_set_reply { shard_id = sid; pid = spid; epoch } ->
            Select (sid, spid, epoch)
        | _ -> Skip
      in
      try
        let reply = receive ~selector ~timeout:(Time.Duration.from_secs 2) () in
        Ok reply
      with
      | Receive_timeout -> Error "timeout waiting for shard SET"
    )

let kv_get = fun cluster ~key ->
  let shard_id = shard_for_key ~num_shards:cluster.num_shards key in
  match get_shard_pid cluster shard_id with
  | None -> Error "shard actor not available"
  | Some pid -> (
      send pid (Shard_kv_get { key; reply_to = self () });
      let selector msg =
        match msg with
        | Shard_kv_get_reply { shard_id = sid; pid = spid; epoch; value } ->
            Select (sid, spid, epoch, value)
        | _ -> Skip
      in
      try
        let reply = receive ~selector ~timeout:(Time.Duration.from_secs 2) () in
        Ok reply
      with
      | Receive_timeout -> Error "timeout waiting for shard GET"
    )

let eval_risk = fun cluster ~account ~amount ->
  let shard_id = shard_for_key ~num_shards:cluster.num_shards account in
  match get_shard_pid cluster shard_id with
  | None -> Error "shard actor not available"
  | Some pid -> (
      send pid (Shard_eval_risk { account; amount; reply_to = self () });
      let selector msg =
        match msg with
        | Shard_eval_risk_reply r -> Select r
        | _ -> Skip
      in
      try Ok (receive ~selector ~timeout:(Time.Duration.from_secs 2) ()) with
      | Receive_timeout -> Error "timeout waiting for shard RISK evaluation"
    )

let query_shard_stats = fun cluster shard_id ->
  let fallback () =
    let pid_str =
      get_shard_pid cluster shard_id
      |> Option.map ~fn:Pid.to_string
      |> Option.unwrap_or ~default:"restarting"
    in
    let epoch =
      ConcurrentHashMap.get cluster.shard_epochs ~key:shard_id
      |> Option.unwrap_or ~default:1
    in
    let ops_count =
      ConcurrentHashMap.get cluster.shard_ops ~key:shard_id
      |> Option.unwrap_or ~default:0
    in
    let risk_alerts =
      ConcurrentHashMap.get cluster.shard_alerts ~key:shard_id
      |> Option.unwrap_or ~default:0
    in
    {
      shard_id;
      pid = pid_str;
      epoch;
      keys_count = 0;
      ops_count;
      risk_alerts;
    }
  in
  match get_shard_pid cluster shard_id with
  | None -> fallback ()
  | Some pid -> (
      send pid (Shard_get_stats { reply_to = self () });
      let selector msg =
        match msg with
        | Shard_get_stats_reply r when r.shard_id = shard_id -> Select r
        | _ -> Skip
      in
      try receive ~selector ~timeout:(Time.Duration.from_millis 250) () with
      | Receive_timeout -> fallback ()
    )

let crash_shard_and_await_recovery = fun cluster ~shard_id ~reason ->
  let target_id = abs shard_id mod cluster.num_shards in
  let old_pid_str =
    get_shard_pid cluster target_id
    |> Option.map ~fn:Pid.to_string
    |> Option.unwrap_or ~default:"none"
  in
  let old_epoch =
    ConcurrentHashMap.get cluster.shard_epochs ~key:target_id
    |> Option.unwrap_or ~default:1
  in
  (
    match get_shard_pid cluster target_id with
    | Some pid -> send pid (Shard_inject_crash { reason })
    | None -> ()
  );
  (* Poll briefly until ShardSupervisor (OneForOne) spawns the replacement actor *)
  let rec wait_new attempts =
    if attempts <= 0 then
      let cur_pid =
        get_shard_pid cluster target_id
        |> Option.map ~fn:Pid.to_string
        |> Option.unwrap_or ~default:"unknown"
      in
      let cur_epoch =
        ConcurrentHashMap.get cluster.shard_epochs ~key:target_id
        |> Option.unwrap_or ~default:old_epoch
      in
      (old_pid_str, cur_pid, old_epoch, cur_epoch)
    else
      let cur_epoch =
        ConcurrentHashMap.get cluster.shard_epochs ~key:target_id
        |> Option.unwrap_or ~default:old_epoch
      in
      if cur_epoch > old_epoch then
        let cur_pid =
          get_shard_pid cluster target_id
          |> Option.map ~fn:Pid.to_string
          |> Option.unwrap_or ~default:"unknown"
        in
        (old_pid_str, cur_pid, old_epoch, cur_epoch)
      else (
        sleep (Time.Duration.from_millis 15);
        wait_new (attempts - 1)
      )
  in
  wait_new 25

let run_workpool_batch = fun ~tasks_count ~iterations ->
  let safe_tasks = max 1 (min 32 tasks_count) in
  let safe_iters = max 10 (min 20000 iterations) in
  let start_time = Time.Instant.now () in
  let inputs = List.init ~count:safe_tasks ~fn:(fun i -> i) in
  let results =
    WorkerPool.SimpleWorkerPool.run
      ~concurrency:4
      ~tasks:inputs
      ~fn:(fun task_idx ->
        let seed = "aegis-otp-task-" ^ Int.to_string task_idx in
        let rec hash_loop step acc =
          if step >= safe_iters then
            acc
          else
            let next =
              Crypto.Sha256.hash_string (acc ^ ":" ^ Int.to_string step)
              |> Crypto.Digest.hex
            in
            hash_loop (step + 1) next
        in
        let digest = hash_loop 0 seed in
        String.sub digest ~offset:0 ~len:16)
      ()
  in
  let elapsed_us = Time.Duration.to_micros (Time.Instant.elapsed start_time) in
  emit_otp_event
    ~kind:"worker_pool"
    ~source:"compute_pool"
    ~detail:("Completed " ^ Int.to_string safe_tasks ^ " parallel SHA-256 chains in " ^ Int.to_string elapsed_us ^ " us");
  (elapsed_us, results)

let pool_to_json = fun (pool : Atacama.pool) ->
  let m = Atacama.get_metrics pool in
  let acceptor_children = Supervisor.which_children pool.acceptor_sup in
  let dyn_count = Supervisor.Dynamic.count_children pool.conn_sup in
  Json.obj
    [
      ("name", Json.string pool.name);
      ("listen", Json.string (pool.host ^ ":" ^ Int.to_string pool.port));
      ("acceptor_supervisor_pid", Json.string (Pid.to_string (Supervisor.to_pid pool.acceptor_sup)));
      ("connection_supervisor_pid", Json.string (Pid.to_string (Supervisor.Dynamic.to_pid pool.conn_sup)));
      ("acceptor_count", Json.int pool.acceptor_count);
      ("max_connections", Json.int pool.max_connections);
      ("active_connections", Json.int m.active_connections);
      ("dynamic_supervised_workers", Json.int dyn_count.active);
      ("accepted_total", Json.int m.accepted_total);
      ("rejected_max_conn", Json.int m.rejected_max_conn);
      ("acceptor_restarts", Json.int m.acceptor_restarts);
      ("handler_crashes", Json.int m.handler_crashes);
      ("bytes_in", Json.int m.bytes_in);
      ("bytes_out", Json.int m.bytes_out);
      (
        "acceptors",
        Json.array
          (List.map
            acceptor_children
            ~fn:(fun (c : Supervisor.child_info) ->
              Json.obj
                [
                  ("id", Json.string c.id);
                  (
                    "pid",
                    Json.string
                      (Option.map c.pid ~fn:Pid.to_string
                      |> Option.unwrap_or ~default:"stopped")
                  );
                ]))
      );
    ]

let cluster_tree_json = fun cluster ->
  let shard_children = Supervisor.which_children cluster.shard_sup in
  let shard_counts = Supervisor.count_children cluster.shard_sup in
  let shards_json =
    List.init
      ~count:cluster.num_shards
      ~fn:(fun idx ->
        let st = query_shard_stats cluster idx in
        Json.obj
          [
            ("shard_id", Json.int st.shard_id);
            ("pid", Json.string st.pid);
            ("epoch", Json.int st.epoch);
            ("restarts", Json.int (max 0 (st.epoch - 1)));
            ("keys_count", Json.int st.keys_count);
            ("ops_count", Json.int st.ops_count);
            ("risk_alerts", Json.int st.risk_alerts);
          ])
  in
  let trace = Runtime.trace_counters () in
  let recent = Agent.get cluster.recent_events ~fn:(fun evs -> List.take evs ~len:15) in
  Json.obj
    [
      ("application", Json.string "AegisOTP Industrial Stack (Atacama + Nomad + Trail)");
      ("riot_version", Json.string "0.0.43");
      (
        "runtime",
        Json.obj
          [
            ("available_parallelism", Json.int Thread.available_parallelism);
            ("work_steals", Json.int trace.steals);
            ("remote_wakeups", Json.int trace.remote_wakeups);
            ("total_kv_keys", Json.int (ConcurrentHashMap.length cluster.ets_kv));
            ("active_ws_subscribers", Json.int (ConcurrentHashMap.length cluster.ws_clients));
          ]
      );
      (
        "shard_supervisor",
        Json.obj
          [
            ("supervisor_pid", Json.string (Pid.to_string (Supervisor.to_pid cluster.shard_sup)));
            ("strategy", Json.string "OneForOne");
            ("specs", Json.int shard_counts.specs);
            ("active", Json.int shard_counts.active);
            (
              "children",
              Json.array
                (List.map
                  shard_children
                  ~fn:(fun (c : Supervisor.child_info) ->
                    Json.obj
                      [
                        ("id", Json.string c.id);
                        (
                          "pid",
                          Json.string
                            (Option.map c.pid ~fn:Pid.to_string
                            |> Option.unwrap_or ~default:"stopped")
                        );
                      ]))
            );
            ("shards", Json.array shards_json);
          ]
      );
      ("atacama_tcp_pool", pool_to_json cluster.tcp_pool);
      ("nomad_http_pool", pool_to_json cluster.http_pool);
      ("recent_telemetry", Json.array (List.map recent ~fn:Json.string));
    ]

let dashboard_html =
  {|<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <title>AegisOTP — Riot 工业级 OTP 控制台 (Atacama + Nomad + Trail)</title>
  <style>
    :root { --bg: #0b1020; --card: #141c33; --border: #263354; --accent: #38bdf8; --green: #22c55e; --red: #ef4444; --amber: #f59e0b; --text: #e2e8f0; }
    * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace; }
    body { margin: 0; padding: 20px; background: var(--bg); color: var(--text); }
    h1 { margin: 0 0 6px 0; font-size: 22px; color: var(--accent); }
    .sub { color: #94a3b8; font-size: 13px; margin-bottom: 18px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 16px; margin-bottom: 16px; }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 16px; }
    .card h2 { margin: 0 0 12px 0; font-size: 15px; color: #cbd5e1; border-bottom: 1px solid var(--border); padding-bottom: 8px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { text-align: left; padding: 7px 6px; border-bottom: 1px solid #1e293b; }
    th { color: #94a3b8; }
    .badge { padding: 2px 7px; border-radius: 4px; font-size: 11px; font-weight: 600; }
    .ok { background: rgba(34,197,94,0.18); color: var(--green); }
    .warn { background: rgba(245,158,11,0.2); color: var(--amber); }
    button { background: #1e293b; color: var(--text); border: 1px solid var(--accent); border-radius: 6px; padding: 6px 11px; cursor: pointer; font-size: 12px; }
    button:hover { background: var(--accent); color: #0b1020; font-weight: 600; }
    button.danger { border-color: var(--red); color: #fca5a5; }
    button.danger:hover { background: var(--red); color: #fff; }
    input { background: #0f172a; border: 1px solid var(--border); color: var(--text); padding: 6px 8px; border-radius: 5px; font-size: 12px; }
    .row { display: flex; gap: 8px; margin-bottom: 8px; align-items: center; flex-wrap: wrap; }
    #log { height: 220px; overflow-y: auto; background: #070b16; border: 1px solid var(--border); border-radius: 6px; padding: 10px; font-size: 12px; line-height: 1.5; }
  </style>
</head>
<body>
  <h1>AegisOTP — Riot 工业级 OTP 实时风控与流式遥测网关</h1>
  <div class="sub">架构：Atacama (Acceptor 监督树 + Dynamic 连接池) + Nomad (HTTP/1.1 &amp; RFC6455 WebSocket) + Trail (Composable Pipeline) + OneForOne 分片自愈</div>
  <div class="grid">
    <div class="card">
      <h2>ShardSupervisor (OneForOne 分片 Actor 监督树 &amp; 故障注入)</h2>
      <table id="shards-table">
        <thead><tr><th>分片</th><th>Actor PID</th><th>Epoch (重启代次)</th><th>KV数</th><th>操作数</th><th>混沌实验</th></tr></thead>
        <tbody></tbody>
      </table>
    </div>
    <div class="card">
      <h2>Atacama 连接池 &amp; Nomad 网关指标</h2>
      <div id="pools-box" style="font-size:13px;line-height:1.7;">加载中...</div>
    </div>
  </div>
  <div class="grid">
    <div class="card">
      <h2>交互测试：分布式 KV / 实时风控评分 / 多核 WorkerPool</h2>
      <div class="row">
        <input id="kv-key" value="merchant:shanghai:01" placeholder="Key" />
        <input id="kv-val" value="active_tier_A" placeholder="Value" />
        <button onclick="setKv()">写入分片 KV</button>
      </div>
      <div class="row">
        <input id="risk-acct" value="acct_vip_88" placeholder="Account" />
        <input id="risk-amt" type="number" value="9600" placeholder="Amount" style="width:90px;" />
        <button onclick="evalRisk()">风控评估</button>
        <button onclick="runPool()">触发多核 WorkerPool (SHA-256x8)</button>
      </div>
      <pre id="action-out" style="background:#070b16;padding:8px;border-radius:6px;font-size:12px;margin:6px 0 0 0;overflow-x:auto;">就绪</pre>
    </div>
    <div class="card">
      <h2>Nomad WebSocket (/ws) 实时 Telemetry 事件流 <span id="ws-status" class="badge warn">连接中</span></h2>
      <div id="log"></div>
    </div>
  </div>
  <script>
    const logBox = document.getElementById('log');
    function addLog(msg) {
      const div = document.createElement('div');
      div.textContent = '[' + new Date().toLocaleTimeString() + '] ' + msg;
      logBox.prepend(div);
    }
    async function refreshTree() {
      const res = await fetch('/api/otp/tree');
      const data = await res.json();
      const tbody = document.querySelector('#shards-table tbody');
      tbody.innerHTML = '';
      data.shard_supervisor.shards.forEach(s => {
        const tr = document.createElement('tr');
        tr.innerHTML = `<td><b>shard_${s.shard_id}</b></td>
          <td><span class="badge ok">${s.pid}</span></td>
          <td>Epoch #${s.epoch} (重启 ${s.restarts} 次)</td>
          <td>${s.keys_count}</td><td>${s.ops_count}</td>
          <td><button class="danger" onclick="crashShard(${s.shard_id})">注入崩溃 (Kill)</button></td>`;
        tbody.appendChild(tr);
      });
      const tcp = data.atacama_tcp_pool;
      const http = data.nomad_http_pool;
      document.getElementById('pools-box').innerHTML = `
        <div><b>Atacama Raw TCP Pool (${tcp.listen})</b> — Acceptors: ${tcp.acceptor_count} (${tcp.acceptor_supervisor_pid}) | 活跃连接: ${tcp.active_connections}/${tcp.max_connections} | 累计受理: ${tcp.accepted_total} | 流量: ${tcp.bytes_in}B in / ${tcp.bytes_out}B out</div>
        <div><b>Nomad HTTP+WS Pool (${http.listen})</b> — Acceptors: ${http.acceptor_count} (${http.acceptor_supervisor_pid}) | 活跃连接: ${http.active_connections}/${http.max_connections} | WS订阅: ${data.runtime.active_ws_subscribers} | 累计受理: ${http.accepted_total}</div>
        <div><b>Riot 多核调度器</b> — 并行度: ${data.runtime.available_parallelism} 核 | Work Steals: ${data.runtime.work_steals} | Remote Wakeups: ${data.runtime.remote_wakeups}</div>`;
    }
    async function crashShard(id) {
      const res = await fetch('/api/chaos/crash', {method:'POST', body:JSON.stringify({shard:id})});
      const out = await res.json();
      document.getElementById('action-out').textContent = JSON.stringify(out, null, 2);
      refreshTree();
    }
    async function setKv() {
      const key = document.getElementById('kv-key').value;
      const value = document.getElementById('kv-val').value;
      const res = await fetch('/api/kv', {method:'POST', body:JSON.stringify({key, value})});
      document.getElementById('action-out').textContent = JSON.stringify(await res.json(), null, 2);
      refreshTree();
    }
    async function evalRisk() {
      const account = document.getElementById('risk-acct').value;
      const amount = parseInt(document.getElementById('risk-amt').value || '1000', 10);
      const res = await fetch('/api/risk', {method:'POST', body:JSON.stringify({account, amount})});
      document.getElementById('action-out').textContent = JSON.stringify(await res.json(), null, 2);
      refreshTree();
    }
    async function runPool() {
      const res = await fetch('/api/workpool', {method:'POST', body:JSON.stringify({tasks:8, iterations:1500})});
      document.getElementById('action-out').textContent = JSON.stringify(await res.json(), null, 2);
      refreshTree();
    }
    const ws = new WebSocket('ws://' + location.host + '/ws');
    ws.onopen = () => {
      const st = document.getElementById('ws-status');
      st.textContent = '已连接 (RFC6455)';
      st.className = 'badge ok';
      ws.send(JSON.stringify({cmd:'ping'}));
    };
    ws.onmessage = (ev) => { addLog(ev.data); refreshTree(); };
    refreshTree();
    setInterval(refreshTree, 3000);
  </script>
</body>
</html>|}

let handle_tcp_line = fun cluster (ctx : Atacama.conn_context) pool tx_count line ->
  let trimmed = String.trim line in
  if String.is_empty trimmed then
    Ok (Atacama.Continue, tx_count)
  else
    let next_tx = tx_count + 1 in
    let tokens =
      String.split ~by:" " trimmed
      |> List.filter ~fn:(fun s -> not (String.is_empty s))
    in
    let reply_and_continue msg =
      let _ = Atacama.write_all pool ctx.stream (msg ^ "\r\n") in
      Ok (Atacama.Continue, next_tx)
    in
    match tokens with
    | [ "PING" ]
    | [ "ping" ] ->
        reply_and_continue
          (
            "+PONG conn_id="
            ^ Int.to_string ctx.conn_id
            ^ " acceptor=acceptor_"
            ^ Int.to_string ctx.acceptor_id
            ^ " actor="
            ^ Pid.to_string (self ())
            ^ " tx="
            ^ Int.to_string next_tx
          )
    | [ "SESSION" ]
    | [ "session" ] ->
        reply_and_continue
          (
            "+SESSION conn_id="
            ^ Int.to_string ctx.conn_id
            ^ " peer="
            ^ Net.Addr.ip ctx.peer
            ^ ":"
            ^ Int.to_string (Net.Addr.port ctx.peer)
            ^ " acceptor=acceptor_"
            ^ Int.to_string ctx.acceptor_id
            ^ " pid="
            ^ Pid.to_string (self ())
            ^ " tx_count="
            ^ Int.to_string next_tx
          )
    | "SET" :: key :: rest_vals when not (List.is_empty rest_vals) -> (
        let value = String.concat " " rest_vals in
        match kv_set cluster ~key ~value with
        | Ok (shard_id, pid_str, epoch) ->
            reply_and_continue
              (
                "+OK shard=shard_"
                ^ Int.to_string shard_id
                ^ " pid="
                ^ pid_str
                ^ " epoch="
                ^ Int.to_string epoch
              )
        | Error err -> reply_and_continue ("-ERR " ^ err)
      )
    | [ "GET"; key ] -> (
        match kv_get cluster ~key with
        | Ok (shard_id, pid_str, epoch, Some value) ->
            reply_and_continue
              (
                "+VALUE "
                ^ value
                ^ " (shard=shard_"
                ^ Int.to_string shard_id
                ^ " pid="
                ^ pid_str
                ^ " epoch="
                ^ Int.to_string epoch
                ^ ")"
              )
        | Ok (shard_id, pid_str, epoch, None) ->
            reply_and_continue
              (
                "+NIL (shard=shard_"
                ^ Int.to_string shard_id
                ^ " pid="
                ^ pid_str
                ^ " epoch="
                ^ Int.to_string epoch
                ^ ")"
              )
        | Error err -> reply_and_continue ("-ERR " ^ err)
      )
    | [ "RISK"; account; amount_str ] -> (
        let amount = Int.from_string_opt amount_str |> Option.unwrap_or ~default:0 in
        match eval_risk cluster ~account ~amount with
        | Ok r ->
            reply_and_continue
              (
                "+RISK verdict="
                ^ r.verdict
                ^ " score="
                ^ Int.to_string r.risk_score
                ^ " shard=shard_"
                ^ Int.to_string r.shard_id
                ^ " pid="
                ^ r.shard_pid
                ^ " epoch="
                ^ Int.to_string r.shard_epoch
                ^ " tx_count="
                ^ Int.to_string r.tx_count
              )
        | Error err -> reply_and_continue ("-ERR " ^ err)
      )
    | [ "CRASH"; shard_str ] ->
        let shard_id = Int.from_string_opt shard_str |> Option.unwrap_or ~default:0 in
        let (old_pid, new_pid, old_epoch, new_epoch) =
          crash_shard_and_await_recovery
            cluster
            ~shard_id
            ~reason:"TCP CRASH command"
        in
        reply_and_continue
          (
            "+RECOVERED shard=shard_"
            ^ Int.to_string (abs shard_id mod cluster.num_shards)
            ^ " old_pid="
            ^ old_pid
            ^ " new_pid="
            ^ new_pid
            ^ " old_epoch="
            ^ Int.to_string old_epoch
            ^ " new_epoch="
            ^ Int.to_string new_epoch
          )
    | [ "WORKPOOL"; count_str ] ->
        let tasks_count = Int.from_string_opt count_str |> Option.unwrap_or ~default:4 in
        let (elapsed_us, digests) = run_workpool_batch ~tasks_count ~iterations:1000 in
        reply_and_continue
          (
            "+WORKPOOL tasks="
            ^ Int.to_string (List.length digests)
            ^ " elapsed_us="
            ^ Int.to_string elapsed_us
          )
    | [ "TREE" ]
    | [ "NODES" ] ->
        let json_str = Json.to_string (cluster_tree_json cluster) in
        reply_and_continue ("+TREE " ^ json_str)
    | [ "CRASH_CONN" ] ->
        (* Intentionally crash only this TCP connection handler to prove connection fault isolation *)
        Error "Simulated per-connection protocol panic"
    | [ "QUIT" ]
    | [ "quit" ] ->
        let _ = Atacama.write_all pool ctx.stream "+BYE\r\n" in
        Ok (Atacama.Close, next_tx)
    | _ ->
        reply_and_continue
          "-ERR Unknown command. Supported: PING | SESSION | SET <k> <v> | GET <k> | RISK <acct> <amt> | CRASH <shard> | WORKPOOL <n> | TREE | QUIT"

type tcp_session_state = {
  line_buf: string;
  tx_count: int;
}

let build_http_trail = fun cluster_ref ->
  let with_cluster handler (ctx : Trail.ctx) =
    match !cluster_ref with
    | None ->
        Trail.json
          ~status:Net.Http.Status.ServiceUnavailable
          ctx
          (Json.obj [ ("error", Json.string "cluster_initializing") ])
    | Some cluster -> handler cluster ctx
  in
  let parse_json_body (ctx : Trail.ctx) =
    match Net.Http.Request.body_string ctx.req with
    | None -> Json.obj []
    | Some s -> (
        match Json.from_string s with
        | Ok j -> j
        | Error _ -> Json.obj []
      )
  in
  Trail.pipeline
    [
      Trail.use_server_header "Nomad/0.0.43 (Riot-OTP; Atacama; Trail)";
      Trail.use_cors ();
      Trail.router
        [
          Trail.get "/" (fun ctx -> Trail.html ctx dashboard_html);
          Trail.get
            "/api/health"
            (with_cluster (fun cluster ctx ->
              let shard_counts = Supervisor.count_children cluster.shard_sup in
              Trail.json
                ctx
                (Json.obj
                  [
                    ("status", Json.string "ok");
                    ("engine", Json.string "AegisOTP");
                    ("active_shards", Json.int shard_counts.active);
                    ("tcp_port", Json.int cluster.tcp_pool.port);
                    ("http_port", Json.int cluster.http_pool.port);
                  ])));
          Trail.get
            "/api/otp/tree"
            (with_cluster (fun cluster ctx ->
              Trail.json ctx (cluster_tree_json cluster)));
          Trail.get
            "/api/kv"
            (with_cluster (fun cluster ctx ->
              let query_opt = Net.Uri.query (Net.Http.Request.uri ctx.req) in
              let key =
                match query_opt with
                | None -> ""
                | Some q ->
                    let params = Net.Uri.Query.parse q in
                    Net.Uri.Query.get params "key" |> Option.unwrap_or ~default:""
              in
              if String.is_empty key then
                Trail.json
                  ~status:Net.Http.Status.BadRequest
                  ctx
                  (Json.obj [ ("error", Json.string "missing_key_param") ])
              else
                match kv_get cluster ~key with
                | Ok (shard_id, pid_str, epoch, val_opt) ->
                    Trail.json
                      ctx
                      (Json.obj
                        [
                          ("key", Json.string key);
                          (
                            "value",
                            match val_opt with
                            | Some v -> Json.string v
                            | None -> Json.null
                          );
                          ("found", Json.bool (Option.is_some val_opt));
                          ("shard_id", Json.int shard_id);
                          ("shard_pid", Json.string pid_str);
                          ("shard_epoch", Json.int epoch);
                        ])
                | Error msg ->
                    Trail.json
                      ~status:Net.Http.Status.InternalServerError
                      ctx
                      (Json.obj [ ("error", Json.string msg) ])));
          Trail.post
            "/api/kv"
            (with_cluster (fun cluster ctx ->
              let body = parse_json_body ctx in
              let key =
                Json.get_field "key" body
                |> Option.and_then ~fn:Json.get_string
                |> Option.unwrap_or ~default:"default_key"
              in
              let value =
                Json.get_field "value" body
                |> Option.and_then ~fn:Json.get_string
                |> Option.unwrap_or ~default:""
              in
              match kv_set cluster ~key ~value with
              | Ok (shard_id, pid_str, epoch) ->
                  Trail.json
                    ~status:Net.Http.Status.Created
                    ctx
                    (Json.obj
                      [
                        ("status", Json.string "stored");
                        ("key", Json.string key);
                        ("value", Json.string value);
                        ("shard_id", Json.int shard_id);
                        ("shard_pid", Json.string pid_str);
                        ("shard_epoch", Json.int epoch);
                      ])
              | Error msg ->
                  Trail.json
                    ~status:Net.Http.Status.InternalServerError
                    ctx
                    (Json.obj [ ("error", Json.string msg) ])));
          Trail.post
            "/api/risk"
            (with_cluster (fun cluster ctx ->
              let body = parse_json_body ctx in
              let account =
                Json.get_field "account" body
                |> Option.and_then ~fn:Json.get_string
                |> Option.unwrap_or ~default:"anonymous"
              in
              let amount =
                Json.get_field "amount" body
                |> Option.and_then ~fn:Json.get_int
                |> Option.unwrap_or ~default:500
              in
              match eval_risk cluster ~account ~amount with
              | Ok r ->
                  Trail.json
                    ctx
                    (Json.obj
                      [
                        ("account", Json.string r.account);
                        ("amount", Json.int amount);
                        ("shard_id", Json.int r.shard_id);
                        ("shard_pid", Json.string r.shard_pid);
                        ("shard_epoch", Json.int r.shard_epoch);
                        ("tx_count", Json.int r.tx_count);
                        ("total_amount", Json.int r.total_amount);
                        ("risk_score", Json.int r.risk_score);
                        ("verdict", Json.string r.verdict);
                      ])
              | Error msg ->
                  Trail.json
                    ~status:Net.Http.Status.InternalServerError
                    ctx
                    (Json.obj [ ("error", Json.string msg) ])));
          Trail.post
            "/api/workpool"
            (with_cluster (fun _cluster ctx ->
              let body = parse_json_body ctx in
              let tasks_count =
                Json.get_field "tasks" body
                |> Option.and_then ~fn:Json.get_int
                |> Option.unwrap_or ~default:8
              in
              let iterations =
                Json.get_field "iterations" body
                |> Option.and_then ~fn:Json.get_int
                |> Option.unwrap_or ~default:1200
              in
              let (elapsed_us, digests) = run_workpool_batch ~tasks_count ~iterations in
              Trail.json
                ctx
                (Json.obj
                  [
                    ("status", Json.string "completed");
                    ("worker_pool_concurrency", Json.int 4);
                    ("tasks_executed", Json.int (List.length digests));
                    ("iterations_per_task", Json.int iterations);
                    ("elapsed_us", Json.int elapsed_us);
                    (
                      "sample_digests",
                      Json.array
                        (List.map digests ~fn:(fun (_idx, d) -> Json.string d))
                    );
                  ])));
          Trail.post
            "/api/chaos/crash"
            (with_cluster (fun cluster ctx ->
              let body = parse_json_body ctx in
              let shard_id =
                Json.get_field "shard" body
                |> Option.and_then ~fn:Json.get_int
                |> Option.unwrap_or ~default:0
              in
              let reason =
                Json.get_field "reason" body
                |> Option.and_then ~fn:Json.get_string
                |> Option.unwrap_or ~default:"HTTP Chaos API fault injection"
              in
              let (old_pid, new_pid, old_epoch, new_epoch) =
                crash_shard_and_await_recovery cluster ~shard_id ~reason
              in
              Trail.json
                ctx
                (Json.obj
                  [
                    ("status", Json.string "self_healed");
                    ("supervisor_strategy", Json.string "OneForOne");
                    ("shard_id", Json.int (abs shard_id mod cluster.num_shards));
                    ("old_pid", Json.string old_pid);
                    ("new_pid", Json.string new_pid);
                    ("old_epoch", Json.int old_epoch);
                    ("new_epoch", Json.int new_epoch);
                  ])));
          Trail.ws
            "/ws"
            (fun stream accept_key ->
              let welcome =
                Json.obj
                  [
                    ("event", Json.string "ws_connected");
                    ("protocol", Json.string "RFC6455");
                    ("accept_key", Json.string accept_key);
                    ("actor_pid", Json.string (Pid.to_string (self ())));
                  ]
              in
              let _ = Trail.Ws.send_text stream (Json.to_string welcome) in
              ());
        ];
    ]

let start = fun ?(host = "127.0.0.1") ?(tcp_port = 9100) ?(http_port = 8080) ?(num_shards = 4) () ->
  let _telemetry_pid = Telemetry.start () in
  let shard_pids = ConcurrentHashMap.with_capacity ~size:16 in
  let shard_epochs = ConcurrentHashMap.with_capacity ~size:16 in
  let shard_ops = ConcurrentHashMap.with_capacity ~size:16 in
  let shard_alerts = ConcurrentHashMap.with_capacity ~size:16 in
  let ets_kv = ConcurrentHashMap.with_capacity ~size:256 in
  let ets_accounts = ConcurrentHashMap.with_capacity ~size:256 in
  let ws_clients = ConcurrentHashMap.with_capacity ~size:64 in
  let recent_events = Agent.start ~fn:(fun () -> []) in
  Telemetry.attach
    "aegis-telemetry-hub"
    (fun ev ->
      match ev with
      | OtpEvent { kind; source; detail } ->
          let line = "[" ^ kind ^ "] (" ^ source ^ ") " ^ detail in
          Agent.cast
            recent_events
            ~fn:(fun prev -> List.take (line :: prev) ~len:40);
          let payload =
            Json.obj
              [
                ("type", Json.string "telemetry");
                ("kind", Json.string kind);
                ("source", Json.string source);
                ("detail", Json.string detail);
              ]
          in
          broadcast_ws_json ws_clients payload
      | _ -> ());
  let shard_specs =
    List.init
      ~count:num_shards
      ~fn:(fun idx ->
        Supervisor.child_spec
          ~id:("shard_" ^ Int.to_string idx)
          ~restart:Supervisor.Permanent
          ~start:(fun () ->
            spawn
              (run_shard_actor
                ~shard_id:idx
                ~num_shards
                ~shard_pids
                ~shard_epochs
                ~shard_ops
                ~shard_alerts
                ~ets_kv
                ~ets_accounts))
          ())
  in
  let shard_sup =
    Supervisor.start_link
      ~strategy:Supervisor.OneForOne
      ~intensity:{
        max_restarts = 50;
        window = Time.Duration.from_secs 10;
      }
      ~children:shard_specs
      ()
  in
  (* Wait briefly for all shard actors to register their initial PIDs *)
  sleep (Time.Duration.from_millis 15);
  let cluster_ref : cluster option Sync.Cell.t = ref None in
  let tcp_pool_ref : Atacama.pool option Sync.Cell.t = ref None in
  let module TcpHandler : Atacama.Handler = struct
    type state = tcp_session_state

    let init = fun (_ctx : Atacama.conn_context) ->
      { line_buf = ""; tx_count = 0 }

    let handle_connection = fun (ctx : Atacama.conn_context) state ->
      let banner =
        "+AEGIS_OTP_READY riot=0.0.43 conn_id="
        ^ Int.to_string ctx.conn_id
        ^ " acceptor=acceptor_"
        ^ Int.to_string ctx.acceptor_id
        ^ " pid="
        ^ Pid.to_string (self ())
        ^ "\r\n"
      in
      (
        match !tcp_pool_ref with
        | Some pool ->
            let _ = Atacama.write_all pool ctx.stream banner in
            ()
        | None -> ()
      );
      Ok (Atacama.Continue, state)

    let rec process_lines = fun (ctx : Atacama.conn_context) buf tx_count ->
      match String.index_of buf ~char:'\n' with
      | None -> Ok (Atacama.Continue, { line_buf = buf; tx_count })
      | Some idx -> (
          let raw_line = String.sub buf ~offset:0 ~len:idx in
          let rest =
            String.sub
              buf
              ~offset:(idx + 1)
              ~len:(String.length buf - idx - 1)
          in
          match (!cluster_ref, !tcp_pool_ref) with
          | (Some cluster, Some pool) -> (
              match handle_tcp_line cluster ctx pool tx_count raw_line with
              | Error e -> Error e
              | Ok (Atacama.Close, next_tx) ->
                  Ok (Atacama.Close, { line_buf = rest; tx_count = next_tx })
              | Ok (Atacama.Continue, next_tx) ->
                  process_lines ctx rest next_tx
            )
          | _ -> Ok (Atacama.Continue, { line_buf = rest; tx_count })
        )

    let handle_data = fun (ctx : Atacama.conn_context) chunk state ->
      process_lines ctx (state.line_buf ^ chunk) state.tx_count

    let handle_close = fun (_ctx : Atacama.conn_context) _state -> ()
  end in
  match Atacama.start_link
    ~name:"aegis_tcp"
    ~host
    ~port:tcp_port
    ~acceptor_count:4
    ~max_connections:128
    (module TcpHandler)
    () with
  | Error e -> Error e
  | Ok tcp_pool -> (
      tcp_pool_ref := Some tcp_pool;
      let trail = build_http_trail cluster_ref in
      let ws_callbacks : Nomad.ws_callbacks =
        {
          on_open =
            (fun stream conn_id ->
              let _ = ConcurrentHashMap.insert ws_clients ~key:conn_id ~value:stream in
              ());
          on_frame =
            (fun stream conn_id frame ->
              match frame with
              | Trail.Ws.Text txt -> (
                  let trimmed = String.trim txt in
                  if String.contains trimmed "crash" then (
                    match !cluster_ref with
                    | Some cluster ->
                        let (old_pid, new_pid, old_e, new_e) =
                          crash_shard_and_await_recovery
                            cluster
                            ~shard_id:0
                            ~reason:"WebSocket chaos command"
                        in
                        let reply =
                          Json.obj
                            [
                              ("type", Json.string "ws_chaos_result");
                              ("old_pid", Json.string old_pid);
                              ("new_pid", Json.string new_pid);
                              ("old_epoch", Json.int old_e);
                              ("new_epoch", Json.int new_e);
                            ]
                        in
                        let _ = Trail.Ws.send_text stream (Json.to_string reply) in
                        Atacama.Continue
                    | None -> Atacama.Continue
                  ) else if String.contains trimmed "tree" then (
                    match !cluster_ref with
                    | Some cluster ->
                        let _ =
                          Trail.Ws.send_text
                            stream
                            (Json.to_string (cluster_tree_json cluster))
                        in
                        Atacama.Continue
                    | None -> Atacama.Continue
                  ) else (
                    let pong_reply =
                      Json.obj
                        [
                          ("type", Json.string "ws_reply");
                          ("conn_id", Json.int conn_id);
                          ("actor_pid", Json.string (Pid.to_string (self ())));
                          ("echo", Json.string trimmed);
                        ]
                    in
                    let _ = Trail.Ws.send_text stream (Json.to_string pong_reply) in
                    Atacama.Continue
                  )
                )
              | _ -> Atacama.Continue);
          on_close =
            (fun conn_id ->
              let _ = ConcurrentHashMap.remove ws_clients ~key:conn_id in
              ());
        }
      in
      match Nomad.start_link
        ~name:"aegis_http"
        ~host
        ~port:http_port
        ~acceptor_count:4
        ~max_connections:256
        ~trail
        ~ws_callbacks
        () with
      | Error e ->
          Atacama.stop tcp_pool;
          Error e
      | Ok http_pool ->
          let cluster =
            {
              num_shards;
              shard_pids;
              shard_epochs;
              shard_ops;
              shard_alerts;
              ets_kv;
              ets_accounts;
              ws_clients;
              recent_events;
              shard_sup;
              tcp_pool;
              http_pool;
            }
          in
          cluster_ref := Some cluster;
          (* Seed initial demo data across shards *)
          let _ = kv_set cluster ~key:"cluster:mode" ~value:"industrial_otp_active" in
          let _ = kv_set cluster ~key:"gateway:stack" ~value:"atacama+nomad+trail" in
          Ok cluster
    )

let stop = fun cluster ->
  Atacama.stop cluster.http_pool;
  Atacama.stop cluster.tcp_pool;
  Supervisor.stop cluster.shard_sup;
  Agent.stop cluster.recent_events;
  Telemetry.stop ()
