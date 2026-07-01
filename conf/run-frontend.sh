#!/bin/bash
# run-frontend.sh — supervised frontend (Next.js standalone on the upstream musl Node). The frontend runs
# Drizzle (Postgres) AND ClickHouse migrations on boot (instrumentation.ts, gated by ENVIRONMENT=LITE), so
# wait for both stores to be ready before starting; PG + CH migration failures throw and block boot.
set -euo pipefail
log() { echo "==> [frontend] $*"; }

wait_for() { # <name> <cmd...>
  local name="$1"; shift; local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i + 1)); [ $((i % 10)) -eq 1 ] && log "waiting for ${name} ..."
    [ "$i" -ge 150 ] && { log "FATAL: ${name} not ready after 300s"; exit 1; }
    sleep 2
  done
  log "${name} ready"
}

cd /app/code/frontend
# Next standalone binds $HOSTNAME; Docker/Cloudron set it to the container id (gotcha 4) -> force 0.0.0.0.
export HOSTNAME="0.0.0.0"
export PORT="5667"

wait_for "clickhouse" curl -sf "http://localhost:8123/ping"
wait_for "postgres"   pg_isready -h "${DATABASE_HOST}" -p "${DATABASE_PORT}"

log "dependencies ready — starting frontend on 0.0.0.0:${PORT} (runs PG + ClickHouse migrations on boot)"
exec /usr/local/bin/node-musl server.js
