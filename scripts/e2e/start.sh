#!/usr/bin/env bash
# Brings up a complete local HyperVault: PostgreSQL, a Supabase stand-in (fake
# auth + PostgREST layer), and the real web app, then writes env.sh with the
# variables the Kit's local end-to-end tests read.
#
#   HYPERVAULT_WEB=/path/to/web scripts/e2e/start.sh [--reset] [--no-web] [--build] [--no-warm]
#
# Everything lives under $HV_E2E_DIR (default /tmp/hv-e2e). Nothing leaves this
# machine: no request goes anywhere but 127.0.0.1, every key is generated here.
# Stop with scripts/e2e/stop.sh.
#
# Settings (environment):
#   HYPERVAULT_WEB   the web repo checkout (required, never modified)
#   HV_E2E_DIR       data and logs (default /tmp/hv-e2e)
#   HV_E2E_PG_PORT   PostgreSQL port (54329)      HV_E2E_STACK_PORT  stand-in (54321)
#   HV_E2E_WEB_PORT  web app (3100)
#   PG_BIN           directory with initdb, pg_ctl, psql (found automatically)
#   NODE             node 20+ (found automatically; /opt/node22/bin/node is preferred)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB="${HYPERVAULT_WEB:-}"
DIR="${HV_E2E_DIR:-/tmp/hv-e2e}"
PG_PORT="${HV_E2E_PG_PORT:-54329}"
STACK_PORT="${HV_E2E_STACK_PORT:-54321}"
WEB_PORT="${HV_E2E_WEB_PORT:-3100}"
DB="hv"

RESET=0; START_WEB=1; BUILD=0; WARM=1
for arg in "$@"; do
  case "$arg" in
    --reset) RESET=1 ;;
    --no-web) START_WEB=0 ;;
    --build) BUILD=1 ;;
    --no-warm) WARM=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

if [ "$START_WEB" = 1 ] && { [ -z "$WEB" ] || [ ! -f "$WEB/package.json" ]; }; then
  echo "Set HYPERVAULT_WEB to a checkout of the web repo (a folder with package.json)." >&2
  exit 2
fi

if [ -z "${NODE:-}" ]; then
  if [ -x /opt/node22/bin/node ]; then NODE=/opt/node22/bin/node; else NODE="$(command -v node || true)"; fi
fi
[ -x "${NODE:-}" ] || { echo "node was not found; set NODE" >&2; exit 2; }

if [ -z "${PG_BIN:-}" ]; then
  for candidate in "$(pg_config --bindir 2>/dev/null || true)" /usr/lib/postgresql/*/bin /usr/local/pgsql/bin /opt/homebrew/opt/postgresql*/bin /usr/local/opt/postgresql*/bin; do
    if [ -n "$candidate" ] && [ -x "$candidate/initdb" ]; then PG_BIN="$candidate"; break; fi
  done
fi
[ -x "${PG_BIN:-}/initdb" ] || { echo "PostgreSQL (initdb) was not found; set PG_BIN" >&2; exit 2; }

# PostgreSQL refuses to run as root; then use the postgres account.
as_pg() { if [ "$(id -u)" = 0 ]; then runuser -u postgres -- "$@"; else "$@"; fi; }

if [ "$RESET" = 1 ]; then "$HERE/stop.sh" >/dev/null 2>&1 || true; rm -rf "$DIR"; fi
mkdir -p "$DIR"/{logs,pids,sock,storage}
if [ "$(id -u)" = 0 ]; then chown -R postgres "$DIR/sock"; chmod 755 "$DIR"; fi
PSQL=("$PG_BIN/psql" -h "$DIR/sock" -p "$PG_PORT" -U postgres -v ON_ERROR_STOP=1 -q)

# ── secrets, generated once per data directory ──────────────────────────────
[ -f "$DIR/jwt-secret" ] || { head -c 36 /dev/urandom | base64 | tr -d '/+=\n' > "$DIR/jwt-secret"; chmod 600 "$DIR/jwt-secret"; }
[ -f "$DIR/key-secret" ] || { head -c 36 /dev/urandom | base64 | tr -d '/+=\n' > "$DIR/key-secret"; chmod 600 "$DIR/key-secret"; }
JWT_SECRET="$(cat "$DIR/jwt-secret")"
KEY_SECRET="$(cat "$DIR/key-secret")"

started=$(date +%s)
say() { echo "[$(( $(date +%s) - started ))s] $*"; }

# ── PostgreSQL ──────────────────────────────────────────────────────────────
if [ ! -d "$DIR/pg" ]; then
  say "creating the database cluster"
  if [ "$(id -u)" = 0 ]; then install -d -o postgres "$DIR/pg"; fi
  as_pg "$PG_BIN/initdb" -D "$DIR/pg" -A trust -U postgres --locale=C.UTF-8 -E UTF8 >/dev/null 2>&1
fi
if ! as_pg "$PG_BIN/pg_ctl" -D "$DIR/pg" status >/dev/null 2>&1; then
  say "starting PostgreSQL on port $PG_PORT"
  as_pg "$PG_BIN/pg_ctl" -D "$DIR/pg" -w -l "$DIR/sock/postgres.log" \
    -o "-p $PG_PORT -k $DIR/sock -c listen_addresses='' -c fsync=off -c synchronous_commit=off -c full_page_writes=off -c max_connections=100" start >/dev/null
fi
"${PSQL[@]}" -d postgres -Atc "select 1 from pg_database where datname='$DB'" | grep -q 1 || "${PSQL[@]}" -d postgres -c "create database $DB"

say "applying the bootstrap and migrations"
"$NODE" "$HERE/apply-migrations.mjs" --web "${WEB:-/nonexistent}" --socket "$DIR/sock" --port "$PG_PORT" --db "$DB" | tail -n 3

# ── the Supabase stand-in ───────────────────────────────────────────────────
if [ -f "$DIR/pids/stack.pid" ] && kill -0 "$(cat "$DIR/pids/stack.pid")" 2>/dev/null; then
  kill "$(cat "$DIR/pids/stack.pid")" 2>/dev/null || true; sleep 0.5
fi
say "starting the Supabase stand-in on port $STACK_PORT"
nohup "$NODE" "$HERE/stack.mjs" --port "$STACK_PORT" --socket "$DIR/sock" --pgport "$PG_PORT" --db "$DB" \
  --secret "$JWT_SECRET" --storage "$DIR/storage" >"$DIR/logs/stack.log" 2>&1 &
echo $! > "$DIR/pids/stack.pid"
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$STACK_PORT/health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -fs "http://127.0.0.1:$STACK_PORT/health" >/dev/null || { echo "the stand-in did not start; see $DIR/logs/stack.log" >&2; exit 1; }

say "creating the test people and minting their tokens"
"$NODE" "$HERE/seed.mjs" --socket "$DIR/sock" --pgport "$PG_PORT" --db "$DB" --secret "$JWT_SECRET" \
  --url "http://127.0.0.1:$STACK_PORT" --out "$DIR/tokens.env"

# env.sh: what the Kit's tests read (source it: `. $DIR/env.sh`).
{
  echo "# generated by scripts/e2e/start.sh; throwaway local values only"
  echo "export HV_E2E_LOCAL_SERVER=http://127.0.0.1:$WEB_PORT"
  sed 's/^/export /' "$DIR/tokens.env"
} > "$DIR/env.sh"
chmod 600 "$DIR/env.sh"

if [ "$START_WEB" = 0 ]; then
  say "stand-in only; source $DIR/env.sh"
  exit 0
fi

# ── the web app ─────────────────────────────────────────────────────────────
set -a
# shellcheck disable=SC1091
. "$DIR/tokens.env"
set +a
export NEXT_PUBLIC_SUPABASE_URL="http://127.0.0.1:$STACK_PORT"
export NEXT_PUBLIC_SUPABASE_ANON_KEY="$HV_E2E_ANON_KEY"
export SUPABASE_SERVICE_ROLE_KEY="$HV_E2E_SERVICE_KEY"
export HYPERVAULT_KEY_SECRET="$KEY_SECRET"
export NEXT_PUBLIC_APP_URL="http://127.0.0.1:$WEB_PORT"
export HYPERVAULT_ADMIN_EMAILS="admin@e2e.test"
export HYPERVAULT_PAIRING=1
export HYPERVAULT_SHARE_ROLES=1
export HYPERVAULT_GUEST_KEEP=1
export CRON_SECRET="$KEY_SECRET-cron"
export NEXT_TELEMETRY_DISABLED=1
export NODE_OPTIONS="--max-old-space-size=6144"
unset RESEND_API_KEY GITHUB_TOKEN ANTHROPIC_API_KEY STENOGRAPHER_URL HYPERVAULT_API_KEY

if [ -f "$DIR/pids/web.pid" ] && kill -0 "$(cat "$DIR/pids/web.pid")" 2>/dev/null; then kill "$(cat "$DIR/pids/web.pid")" 2>/dev/null || true; sleep 1; fi
NEXT="$WEB/node_modules/next/dist/bin/next"
[ -f "$NEXT" ] || { echo "$WEB has no node_modules/next; install the web repo's dependencies first" >&2; exit 2; }
cd "$WEB"
if [ "$BUILD" = 1 ]; then
  say "building the web app (next build)"
  "$NODE" "$NEXT" build >"$DIR/logs/web-build.log" 2>&1 || { echo "next build failed; see $DIR/logs/web-build.log" >&2; exit 1; }
  say "starting the web app (next start) on port $WEB_PORT"
  nohup "$NODE" "$NEXT" start -p "$WEB_PORT" -H 127.0.0.1 >"$DIR/logs/web.log" 2>&1 &
else
  say "starting the web app (next dev) on port $WEB_PORT"
  nohup "$NODE" "$NEXT" dev -p "$WEB_PORT" -H 127.0.0.1 >"$DIR/logs/web.log" 2>&1 &
fi
echo $! > "$DIR/pids/web.pid"

for _ in $(seq 1 240); do
  if curl -fs -m 120 "http://127.0.0.1:$WEB_PORT/api/capabilities" >/dev/null 2>&1; then break; fi
  kill -0 "$(cat "$DIR/pids/web.pid")" 2>/dev/null || { echo "the web app exited; see $DIR/logs/web.log" >&2; exit 1; }
  sleep 1
done
curl -fs -m 120 "http://127.0.0.1:$WEB_PORT/api/capabilities" >/dev/null || { echo "the web app did not answer /api/capabilities; see $DIR/logs/web.log" >&2; exit 1; }
say "web app answers /api/capabilities"

if [ "$WARM" = 1 ] && [ "$BUILD" = 0 ]; then
  say "compiling routes ahead of the tests (next dev compiles on first use)"
  HV_E2E_ENV="$DIR/env.sh" "$NODE" "$HERE/warm.mjs" "$WEB" || true
  say "routes warm"
fi

say "ready. Run the Kit tests with:  . $DIR/env.sh && (cd Packages/HyperVaultKit && swift test --filter LocalServerE2ETests)"
