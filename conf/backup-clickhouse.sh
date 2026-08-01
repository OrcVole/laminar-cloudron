#!/bin/bash
# backup-clickhouse.sh — Cloudron backupCommand (ADR 0007 + 0011). Snapshots BOTH bundled stores (Quickwit
# AND ClickHouse) from their persistentDirs into /app/data, where Cloudron's filesystem backup picks them up.
#
# ORDER MATTERS (ADR 0011): snapshot QUICKWIT FIRST, ClickHouse SECOND. The two snapshots are not atomic, so
# under write load one store is captured slightly fresher than the other. We bias the residual to the BENIGN
# direction: ClickHouse (the trace store) is captured LAST/freshest, so the search index (Quickwit) can only
# LAG it — search <= ch_spans, never over (which would be a search hit with no backing trace). Postgres is
# dumped by Cloudron in the snapshot phase, AFTER this backupCommand, so it is fresher still
# (pg_traces >= ch_spans, also benign). Net oldest->newest: Quickwit <= ClickHouse <= Postgres.
#
# ClickHouse: snapshot the committed store to an unlocked copy then `clickhouse local` dump it (the live
# server's <store>/status flock makes a direct dump impossible — Code 76). Quickwit: a plain rsync of its
# data dir (splits + metastore); Quickwit boots cleanly from a file copy (verified). Both publish atomically
# via .new -> rename.
set -euo pipefail
CH_STORE=/var/lib/clickhouse
QW_STORE=/var/lib/quickwit
DUMP=/app/data/clickhouse-backup
QDUMP=/app/data/quickwit-backup
SNAP=/app/data/.clickhouse-snapshot      # transient: built + removed within this command (never archived)
CONF=/etc/clickhouse-server/backups.xml
TIMING=/app/data/backup-timing.log
log() { echo "==> [backup] $*"; }

# Cloudron runs this container with --log-driver=none, so everything log() writes to stdout is DISCARDED.
# Keep a per-phase timing line under /app/data (writable, and the only thing that survives the run) so a
# slow backup can be attributed without reproducing it by hand. Emitted from an EXIT trap, so a failed or
# early-exiting run still records how far it got. ADR 0012.
RUN_START=$(date +%s); PHASE_START=${RUN_START}; TIMINGS=""
mark() { local now; now=$(date +%s); TIMINGS="${TIMINGS}${1}=$((now - PHASE_START))s "; PHASE_START=${now}; }
emit_timing() {
  local line; line="$(date -u +%Y-%m-%dT%H:%M:%SZ) total=$(($(date +%s) - RUN_START))s ${TIMINGS}"
  log "timings: ${line}"
  { [ -f "${TIMING}" ] && tail -n 29 "${TIMING}"; echo "${line}"; } > "${TIMING}.new" 2>/dev/null \
    && mv "${TIMING}.new" "${TIMING}" || true
}
trap emit_timing EXIT

# ---- 1. Quickwit FIRST (so it is the OLDER capture; ADR 0011 benign-skew bias) ------------------
if [ -d "${QW_STORE}" ] && [ -n "$(ls -A "${QW_STORE}" 2>/dev/null)" ]; then
  log "snapshotting Quickwit ${QW_STORE} -> ${QDUMP}"
  rm -rf "${QDUMP}.new" "${QDUMP}.old"
  qrc=0
  # -S (--sparse) is LOAD-BEARING, not a tidiness flag (ADR 0012). Quickwit pre-allocates two 128 MiB WAL
  # files (wal/ and queues/) that are almost entirely holes: 256 MiB apparent, ~4 KiB actually allocated.
  # Plain `rsync -a` materialises those holes, turning a 292 KiB store into a 257 MiB snapshot of zeroes
  # that Cloudron then uploads offsite every night. Keep the WAL (it holds spans not yet indexed into a
  # split, so excluding it would lose data); just do not inflate it.
  rsync -aS --delete "${QW_STORE}/" "${QDUMP}.new/" || qrc=$?
  if [ "${qrc}" -ne 0 ] && [ "${qrc}" -ne 24 ]; then
    log "FATAL: Quickwit snapshot rsync failed (rc=${qrc})"; rm -rf "${QDUMP}.new"; exit "${qrc}"
  fi
  [ -e "${QDUMP}" ] && mv "${QDUMP}" "${QDUMP}.old"
  mv "${QDUMP}.new" "${QDUMP}"
  rm -rf "${QDUMP}.old"
  log "Quickwit snapshot published ($(du -sh "${QDUMP}" 2>/dev/null | cut -f1))"
else
  log "Quickwit store empty/absent — skipping its snapshot"
fi
mark quickwit

# ---- 2. ClickHouse SECOND (so it is the FRESHER capture) ----------------------------------------
if [ ! -d "${CH_STORE}/store" ] && [ ! -d "${CH_STORE}/metadata" ]; then
  log "ClickHouse persistentDir empty/absent — nothing to dump"; exit 0
fi
log "snapshotting committed ClickHouse store ${CH_STORE} -> ${SNAP} (excl /status, /tmp, /shadow, /logs, tmp_*)"
rm -rf "${SNAP}" "${DUMP}.new" "${DUMP}.old"
mkdir -p "${SNAP}"
rc=0
# /logs is the server's own text log (up to 6 x 100 MiB rotations under our <logger> config). It is not a
# table, `clickhouse local` does not read it, and restore-clickhouse.sh recreates the dir empty — so copying
# it only ever cost time. The system.*_log TABLES cannot be excluded here (they live under store/ addressed
# by UUID, and dropping them from the snapshot would break the attach); they are bounded at the source
# instead, by the retention config in config.d/cloudron.xml. ADR 0012.
rsync -a \
  --exclude='/status' --exclude='/tmp/' --exclude='/shadow/' --exclude='/logs/' --exclude='tmp_*' \
  "${CH_STORE}/" "${SNAP}/" || rc=$?
if [ "${rc}" -ne 0 ] && [ "${rc}" -ne 24 ]; then
  log "FATAL: ClickHouse snapshot rsync failed (rc=${rc})"; rm -rf "${SNAP}"; exit "${rc}"
fi
mark ch_rsync
log "dumping ClickHouse 'default' DB from the snapshot ($(du -sh "${SNAP}" 2>/dev/null | cut -f1))"
clickhouse local --path="${SNAP}" --config-file="${CONF}" \
  --query="BACKUP DATABASE default TO File('clickhouse-backup.new')"
mark ch_dump
rm -rf "${SNAP}"
[ -e "${DUMP}" ] && mv "${DUMP}" "${DUMP}.old"
mv "${DUMP}.new" "${DUMP}"
rm -rf "${DUMP}.old"
log "ClickHouse dump published: ${DUMP} ($(du -sh "${DUMP}" 2>/dev/null | cut -f1))"
