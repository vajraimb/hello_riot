#!/bin/sh
# Start / stop the Oasis gateway in the background.
#   scripts/oasis.sh start|stop|restart|status|logs
#   scripts/oasis.sh <anything else>   runs the oasis binary with those args
# Runtime files live in $OASIS_HOME (default ~/.oasis): oasis.toml, data/,
# workspaces/, logs/oasis.log, oasis.pid. API keys come from the calling
# shell's environment, so run this from a shell that has them exported.
set -e

OASIS_HOME="${OASIS_HOME:-$HOME/.oasis}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PID_FILE="$OASIS_HOME/oasis.pid"
LOG="$OASIS_HOME/logs/oasis.log"

bin() {
  if [ -n "$OASIS_BIN" ]; then echo "$OASIS_BIN"; return; fi
  ls -t "$ROOT"/_build/*/*/out/oasis/oasis 2>/dev/null | head -1
}

running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start() {
  if running; then echo "Oasis 已在运行 (pid $(cat "$PID_FILE"))"; return; fi
  BIN="$(bin)"
  if [ -z "$BIN" ]; then echo "找不到 oasis 可执行文件，先运行 riot build" >&2; exit 1; fi
  mkdir -p "$OASIS_HOME/logs"
  # own process group, detached from this terminal
  nohup /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV' -- "$BIN" "$@" >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$PID_FILE"
  sleep 1
  if running; then echo "Oasis 已启动 (pid $(cat "$PID_FILE"))，日志 $LOG"; else echo "启动失败，见 $LOG" >&2; tail -20 "$LOG" >&2; exit 1; fi
}

stop() {
  if ! running; then echo "Oasis 没有在运行"; rm -f "$PID_FILE"; return; fi
  pid="$(cat "$PID_FILE")"
  kill "$pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid"
  rm -f "$PID_FILE"
  echo "Oasis 已停止"
}

cmd="${1:-status}"
[ $# -gt 0 ] && shift
case "$cmd" in
  start) start "$@" ;;
  stop) stop ;;
  restart) stop; start "$@" ;;
  status) if running; then echo "运行中 (pid $(cat "$PID_FILE"))"; else echo "未运行"; fi ;;
  logs) tail -f "$LOG" ;;
  help|-h|--help) echo "用法: $0 start|stop|restart|status|logs，其余参数原样交给 oasis（如 --self-test、ask \"你好\"、models）" ;;
  *)
    BIN="$(bin)"
    if [ -z "$BIN" ]; then echo "找不到 oasis 可执行文件，先运行 riot build" >&2; exit 1; fi
    exec "$BIN" "$cmd" "$@" ;;
esac
