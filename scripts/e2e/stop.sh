#!/usr/bin/env bash
# Stops what scripts/e2e/start.sh started. Data stays in $HV_E2E_DIR unless --purge.
#
#   scripts/e2e/stop.sh [--purge]

set -uo pipefail
DIR="${HV_E2E_DIR:-/tmp/hv-e2e}"
PG_PORT="${HV_E2E_PG_PORT:-54329}"

stop_pid() {
  local file="$DIR/pids/$1.pid"
  [ -f "$file" ] || return 0
  local pid; pid="$(cat "$file")"
  if kill -0 "$pid" 2>/dev/null; then
    # next dev starts child processes; stop the whole group where there is one.
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$file"
}

stop_pid web
stop_pid fakes
stop_pid stack

if [ -d "$DIR/pg" ]; then
  PG_BIN="${PG_BIN:-}"
  if [ -z "$PG_BIN" ]; then for c in "$(pg_config --bindir 2>/dev/null || true)" /usr/lib/postgresql/*/bin; do [ -x "$c/pg_ctl" ] && PG_BIN="$c" && break; done; fi
  if [ -n "$PG_BIN" ]; then
    if [ "$(id -u)" = 0 ]; then runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$DIR/pg" -m fast stop >/dev/null 2>&1; else "$PG_BIN/pg_ctl" -D "$DIR/pg" -m fast stop >/dev/null 2>&1; fi
  fi
fi

if [ "${1:-}" = "--purge" ]; then rm -rf "$DIR"; echo "removed $DIR"; fi
echo "stopped"
