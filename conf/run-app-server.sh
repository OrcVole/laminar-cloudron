#!/bin/bash
# run-app-server.sh — supervised app-server (Rust). Waits for ClickHouse (required) + Postgres, then exec's.
# ClickHouse is the hard dependency (app-server reads/writes spans); Quickwit is optional (search degrades
# gracefully) so we do NOT block on it.
set -euo pipefail
log() { echo "==> [app-server] $*"; }

wait_for() { # <name> <cmd...>
  local name="$1"; shift; local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1)); [ $((i % 10)) -eq 1 ] && log "waiting for ${name} ..."
    [ "$i" -ge 150 ] && { log "FATAL: ${name} not ready after 300s"; exit 1; }
    sleep 2
  done
  log "${name} ready"
}

cd /app/code/app-server          # ./data is cwd-relative (name generation: adjectives/nouns)
export PORT=8000 GRPC_PORT=8001 CONSUMER_PORT=8002

wait_for "clickhouse" curl -sf "http://localhost:8123/ping"
wait_for "postgres"   pg_isready -h "${DATABASE_HOST}" -p "${DATABASE_PORT}"

# Quickwit is a SOFT dependency with a hard edge: the app-server spawns its spans-indexer workers ONLY if its
# Quickwit client connects AT STARTUP — otherwise it logs "Quickwit not available - skipping spans indexer
# workers" and search NEVER indexes for this process's lifetime (0 splits). Without this gate it's a startup
# race (app-server vs Quickwit cold start). So wait for Quickwit readiness — but bounded, and PROCEED degraded
# rather than block forever, so a genuinely broken Quickwit can't wedge the whole app.
qw=0
until curl -sf "http://localhost:7280/health/readyz" >/dev/null 2>&1; do
  qw=$((qw + 1))
  [ "$qw" -ge 60 ] && { log "WARN: Quickwit not ready after 60s — starting WITHOUT span indexing (search degraded)"; break; }
  [ $((qw % 10)) -eq 1 ] && log "waiting for quickwit ..."
  sleep 1
done
[ "$qw" -lt 60 ] && log "quickwit ready"

log "dependencies ready — starting app-server (rest :${PORT} grpc :${GRPC_PORT} sse :${CONSUMER_PORT})"
exec ./app-server
