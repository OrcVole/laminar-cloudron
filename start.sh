#!/bin/bash
# start.sh — Laminar Cloudron entrypoint. Runs as root for setup, then exec's supervisord, which drops
# each of the four services (clickhouse, quickwit, app-server, frontend) to the unprivileged cloudron user.
set -euo pipefail

CODE=/app/code
DATA=/app/data
VERSION="${LAMINAR_VERSION:-unknown}"
log() { echo "==> [start] $*"; }
log "laminar ${VERSION} booting"

# ------------------------------------------------------------------------------------------------
# 1. Layout + ownership. A restore can reset owner/mode across /app/data, so re-assert every boot.
#    NOTE (ADR 0007): the clickhouse data path moves to a persistentDir in Phase 7 — keep it one var.
# ------------------------------------------------------------------------------------------------
# ClickHouse + Quickwit stores each live on their own persistentDir (ADR 0007 + 0011: out of the backed-up
# rsync walk so they can't race the syncer #46). backupCommand snapshots BOTH (Quickwit first, then CH) into
# /app/data/{quickwit,clickhouse}-backup, which ride the backup near-atomically (Quickwit captured before CH
# so its residual lag is the benign direction: search <= ch_spans).
CH_STORE=/var/lib/clickhouse
QW_STORE=/var/lib/quickwit
mkdir -p \
  "${CH_STORE}/logs" "${CH_STORE}/tmp" "${CH_STORE}/access" \
  "${CH_STORE}/user_files" "${CH_STORE}/format_schemas" \
  "${QW_STORE}" \
  "${DATA}/clickhouse-backup" "${DATA}/quickwit-backup" "${DATA}/.secrets" \
  /run/laminar /run/laminar/frontend-cache
chown -R cloudron:cloudron "${DATA}" /run/laminar
# Re-assert persistentDir ownership: full -R only when it drifted (e.g. restoreCommand ran as root),
# else a cheap top-level chown — avoids a slow -R over a large store on every boot.
if [ "$(stat -c %U "${CH_STORE}" 2>/dev/null || echo x)" != cloudron ]; then
  chown -R cloudron:cloudron "${CH_STORE}"
else
  chown cloudron:cloudron "${CH_STORE}" "${CH_STORE}"/{logs,tmp,access,user_files,format_schemas}
fi
if [ "$(stat -c %U "${QW_STORE}" 2>/dev/null || echo x)" != cloudron ]; then
  chown -R cloudron:cloudron "${QW_STORE}"
else
  chown cloudron:cloudron "${QW_STORE}"
fi
# ------------------------------------------------------------------------------------------------
# 1b. Quickwit restore safeguard (field guide #327; ADR 0013). Quickwit 0.9 migrates the data directory in
#     place on first start and 0.8 can never open it again, and Cloudron leaves persistentDirs alone on an
#     in-place restore, so a restored version could be started on a directory it cannot read. The
#     restoreCommand (restore-clickhouse.sh) therefore drops a flag into the directory when it finds it
#     populated at restore time. Seeing the flag, move everything aside into a dated quarantine inside the
#     same mount (never deleted, kept 30 days) and let Quickwit start EMPTY. Search history from before the
#     restore is lost: the index is derived but cannot be rebuilt from ClickHouse (ADR 0011). Traces are in
#     ClickHouse and are untouched. A clone restores into an empty directory and writes no flag.
# ------------------------------------------------------------------------------------------------
QW_FLAG="${QW_STORE}/.restore-pending"
if [ -f "${QW_FLAG}" ]; then
  rm -f "${QW_FLAG}"
  if [ -n "$(find "${QW_STORE}" -mindepth 1 -maxdepth 1 ! -name 'quarantine-*' -print -quit)" ]; then
    QW_Q="${QW_STORE}/quarantine-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "${QW_Q}"
    find "${QW_STORE}" -mindepth 1 -maxdepth 1 ! -name 'quarantine-*' -exec mv -t "${QW_Q}" {} +
    log "RESTORE: a backup was restored over this app. The live Quickwit directory was moved to ${QW_Q}"
    log "RESTORE: (kept 30 days) and Quickwit starts empty. Search history from before the restore is not"
    log "RESTORE: searchable; traces in ClickHouse are not affected. See POSTINSTALL."
  else
    log "RESTORE: flag found but the Quickwit directory is already empty; nothing to move"
  fi
fi
find "${QW_STORE}" -mindepth 1 -maxdepth 1 -type d -name 'quarantine-*' -mtime +30 -exec rm -rf {} + 2>/dev/null || true

# Drop any stale pre-persistentDir stores under /app/data (else they are backed up + race the syncer).
rm -rf "${DATA}/clickhouse" "${DATA}/quickwit"
chmod 0700 "${DATA}/.secrets"

# ------------------------------------------------------------------------------------------------
# 2. Secrets: first-run-only + idempotent. AEAD_SECRET_KEY is DATA-LOSS-CRITICAL — generate ONCE,
#    never reseed. Re-assert mode/owner every boot (restore drifts them).
# ------------------------------------------------------------------------------------------------
SECRETS="${DATA}/.secrets/secrets.env"
if [[ ! -f "${SECRETS}" ]]; then
  log "first run: generating secrets"
  ( umask 077
    {
      echo "AEAD_SECRET_KEY=$(openssl rand -hex 32)"        # EXACTLY 64 hex chars — data-loss-critical
      echo "NEXTAUTH_SECRET=$(openssl rand -hex 32)"
      echo "SHARED_SECRET_TOKEN=$(openssl rand -hex 32)"
      echo "CLICKHOUSE_PASSWORD=$(openssl rand -hex 24)"
      echo "CLICKHOUSE_RO_PASSWORD=$(openssl rand -hex 24)"
    } > "${SECRETS}" )
else
  log "existing secrets found (not reseeding)"
fi
chown cloudron:cloudron "${SECRETS}"; chmod 0600 "${SECRETS}"
set -a; . "${SECRETS}"; set +a

if [[ ! "${AEAD_SECRET_KEY:-}" =~ ^[0-9a-f]{64}$ ]]; then
  log "FATAL: AEAD_SECRET_KEY is not exactly 64 hex chars — refusing to start (data-loss guard)"; exit 1
fi

# ------------------------------------------------------------------------------------------------
# 3. Map CLOUDRON_* addon vars -> Laminar env (every boot; addon values can change on restart).
# ------------------------------------------------------------------------------------------------
export HOME="${DATA}"
export ENVIRONMENT="LITE"               # mandatory: app-server panics if unset; enables auto-migrate
export FORCE_RUN_MIGRATIONS="true"      # belt-and-braces (LITE already auto-migrates)

# Postgres — pass DISCRETE vars, NOT DATABASE_URL. The frontend (lib/db/drizzle.ts) parses DATABASE_URL
# with a strict regex that rejects the Cloudron addon URL; both app-server (env/database.rs) and frontend
# natively support DATABASE_USERNAME/PASSWORD/HOST/PORT/DATABASE when DATABASE_URL is unset, skipping URL
# parsing entirely (app-server uses sqlx, frontend uses postgres.js with raw values).
: "${CLOUDRON_POSTGRESQL_HOST:?postgresql addon required}"
export DATABASE_USERNAME="${CLOUDRON_POSTGRESQL_USERNAME}"
export DATABASE_PASSWORD="${CLOUDRON_POSTGRESQL_PASSWORD}"
export DATABASE_HOST="${CLOUDRON_POSTGRESQL_HOST}"
export DATABASE_PORT="${CLOUDRON_POSTGRESQL_PORT:-5432}"
export DATABASE_DATABASE="${CLOUDRON_POSTGRESQL_DATABASE}"

ORIGIN="${CLOUDRON_APP_ORIGIN:?app origin required}"
export NEXTAUTH_URL="${ORIGIN}" BETTER_AUTH_URL="${ORIGIN}" NEXT_PUBLIC_URL="${ORIGIN}"
export BETTER_AUTH_SECRET="${NEXTAUTH_SECRET}"

# bundled ClickHouse (localhost) — two users (rw + ro)
export CLICKHOUSE_URL="http://localhost:8123"
export CLICKHOUSE_USER="laminar"
export CLICKHOUSE_RO_USER="laminar_ro"
# CLICKHOUSE_PASSWORD / CLICKHOUSE_RO_PASSWORD come from the secrets file (exported above).

# bundled Quickwit (localhost). QW_CONFIG -> the bundled default config; data dir + localhost bind forced.
export QW_CONFIG="/quickwit/config/quickwit.yaml"
export QW_DATA_DIR="${QW_STORE}"          # persistentDir (ADR 0011) — out of the file-walk
export QW_LISTEN_ADDRESS="127.0.0.1"
export QUICKWIT_SEARCH_URL="http://localhost:7280"
export QUICKWIT_INGEST_URL="http://localhost:7281"
export QUICKWIT_SPANS_INDEX_ID="spans_v2"
# Force commit OFF (field guide #329): upstream 0.3.0 defaults QUICKWIT_FORCE_COMMIT to true, which makes
# a split per ingest batch and floods /var/lib/quickwit and its backup copy with files. With it off, spans
# become searchable when the commit timeout fires (30 s here; upstream default 60 s).
export QUICKWIT_FORCE_COMMIT="false"
export QUICKWIT_SPANS_V2_COMMIT_TIMEOUT_SECS="30"

# frontend -> app-server (server-side; 8002 SSE stays internal)
export BACKEND_URL="http://localhost:8000"
export BACKEND_RT_URL="http://localhost:8002"

# telemetry off (no phone-home)
export LAMINAR_TELEMETRY_DISABLED="true"
export NEXT_TELEMETRY_DISABLED="1"

# OIDC SSO — wire Better Auth's keycloak generic provider to the Cloudron oidc addon, only when present.
if [[ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]]; then
  export AUTH_KEYCLOAK_ID="${CLOUDRON_OIDC_CLIENT_ID}"
  export AUTH_KEYCLOAK_SECRET="${CLOUDRON_OIDC_CLIENT_SECRET:-}"
  export AUTH_KEYCLOAK_ISSUER="${CLOUDRON_OIDC_ISSUER:-}"
  log "OIDC SSO wired to the Cloudron oidc addon (keycloak provider)"
else
  log "no OIDC addon config — passwordless local-email sign-in auto-enables (OPEN instance; see POSTINSTALL)"
fi

# Surface the public ingestion base URL (httpPorts subdomain) for the operator / SDKs.
if [[ -n "${LAMINAR_INGEST_FQDN:-}" ]]; then
  log "trace ingestion endpoint -> https://${LAMINAR_INGEST_FQDN}  (Laminar SDK / OTLP baseUrl)"
fi

log "origin ${ORIGIN}  aead_key present  pg set  clickhouse localhost  quickwit localhost"

# ------------------------------------------------------------------------------------------------
# 4. Hand off to supervisor (clickhouse + quickwit start now; app-server/frontend wrappers gate on
#    readiness so the frontend's on-boot PG + ClickHouse migrations run against ready stores).
# ------------------------------------------------------------------------------------------------
exec supervisord -c /etc/supervisor/supervisord.conf
