#!/bin/bash
# restore-clickhouse.sh — Cloudron restoreCommand (ADR 0007 + 0011). Runs in a TEMP container BEFORE the app
# starts, after Cloudron restored /app/data (incl. both snapshots). Repopulates BOTH empty persistentDirs:
# Quickwit (plain rsync of its snapshot) and ClickHouse (via a transient clickhouse-server). Idempotent +
# fail-loud: each restore runs ONLY into its own absent/empty persistentDir (a normal restart keeps the
# persistentDirs, so this must no-op there).
#
# ClickHouse CRITICAL (ADR 0007): the dump MUST be restored by a real clickhouse-SERVER, not `clickhouse
# local` (whose output the real server can't start on — Code 48). We bring up a transient server on the empty
# persistentDir and RESTORE through it (allow_different_{table,database}_def absorb the normalized UUID-less
# defs). Quickwit needs no server — it boots from the file copy directly.
set -euo pipefail
CH_STORE=/var/lib/clickhouse
QW_STORE=/var/lib/quickwit
DUMP=/app/data/clickhouse-backup
QDUMP=/app/data/quickwit-backup
SECRETS=/app/data/.secrets/secrets.env
log() { echo "==> [restore] $*"; }

# ---- Quickwit: plain rsync of the snapshot into its empty persistentDir (ADR 0011) -------------
if [ -d "${QDUMP}" ] && [ -n "$(ls -A "${QDUMP}" 2>/dev/null)" ]; then
  if [ -n "$(ls -A "${QW_STORE}" 2>/dev/null)" ]; then
    log "Quickwit persistentDir already populated — refusing to clobber (no-op)"
  else
    log "restoring Quickwit ${QDUMP} -> ${QW_STORE}"
    mkdir -p "${QW_STORE}"
    # -S mirrors the backup side (ADR 0012): keep Quickwit's pre-allocated 128 MiB WAL files sparse rather
    # than writing 256 MiB of zeroes into the fresh persistentDir. Restores from a pre-0.1.5 backup, whose
    # WAL was archived fully materialised, are re-sparsified by this.
    rsync -aS "${QDUMP}/" "${QW_STORE}/"
    chown -R cloudron:cloudron "${QW_STORE}"
    log "Quickwit restore complete ($(du -sh "${QW_STORE}" 2>/dev/null | cut -f1))"
  fi
else
  log "no Quickwit snapshot at ${QDUMP} — skipping"
fi

# ---- ClickHouse: transient-server RESTORE (ADR 0007) -------------------------------------------
if [ ! -d "${DUMP}" ]; then log "no ClickHouse dump at ${DUMP} (fresh install) — nothing to restore"; exit 0; fi
if [ -d "${CH_STORE}/store" ] || [ -d "${CH_STORE}/metadata" ]; then
  log "ClickHouse persistentDir already populated — refusing to clobber (no-op)"; exit 0
fi
if [ ! -f "${SECRETS}" ]; then log "FATAL: ${SECRETS} missing — cannot start CH for restore"; exit 1; fi

log "restoring ClickHouse 'default' from ${DUMP} via a transient clickhouse-server"
mkdir -p "${CH_STORE}"/{tmp,logs,access,user_files,format_schemas}
chown -R cloudron:cloudron "${CH_STORE}"
# CH user passwords come from env (users.d: <password from_env=...>); export them so the transient server can
# authenticate the laminar user. `su` (no dash) preserves this exported env into the child process.
set -a; . "${SECRETS}"; set +a
su -s /bin/bash cloudron -c "exec clickhouse-server --config-file=/etc/clickhouse-server/config.xml" \
  > /tmp/restore-ch.log 2>&1 &
SVPID=$!
cleanup() { kill -TERM "$SVPID" 2>/dev/null || true; wait "$SVPID" 2>/dev/null || true; }
trap cleanup EXIT

i=0
until curl -sf http://localhost:8123/ping >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -ge 90 ] && { log "FATAL: transient CH not ready after 90s"; tail -20 /tmp/restore-ch.log; exit 1; }
  sleep 1
done
log "transient CH up — running RESTORE"

if ! clickhouse-client --user laminar --password "${CLICKHOUSE_PASSWORD}" \
       --query "RESTORE DATABASE default FROM File('clickhouse-backup') SETTINGS allow_different_table_def=1, allow_different_database_def=1" 2>&1 | grep -q RESTORED; then
  log "FATAL: RESTORE failed"; tail -20 /tmp/restore-ch.log; exit 1
fi

log "RESTORE ok — stopping transient CH cleanly"
cleanup; trap - EXIT
chown -R cloudron:cloudron "${CH_STORE}"
log "ClickHouse restore complete: $(du -sh "${CH_STORE}" 2>/dev/null | cut -f1)"
