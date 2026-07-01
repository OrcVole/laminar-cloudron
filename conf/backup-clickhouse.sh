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
log() { echo "==> [backup] $*"; }

# ---- 1. Quickwit FIRST (so it is the OLDER capture; ADR 0011 benign-skew bias) ------------------
if [ -d "${QW_STORE}" ] && [ -n "$(ls -A "${QW_STORE}" 2>/dev/null)" ]; then
  log "snapshotting Quickwit ${QW_STORE} -> ${QDUMP}"
  rm -rf "${QDUMP}.new" "${QDUMP}.old"
  qrc=0
  rsync -a --delete "${QW_STORE}/" "${QDUMP}.new/" || qrc=$?
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

# ---- 2. ClickHouse SECOND (so it is the FRESHER capture) ----------------------------------------
if [ ! -d "${CH_STORE}/store" ] && [ ! -d "${CH_STORE}/metadata" ]; then
  log "ClickHouse persistentDir empty/absent — nothing to dump"; exit 0
fi
log "snapshotting committed ClickHouse store ${CH_STORE} -> ${SNAP} (excl /status, /tmp, /shadow, tmp_*)"
rm -rf "${SNAP}" "${DUMP}.new" "${DUMP}.old"
mkdir -p "${SNAP}"
rc=0
rsync -a \
  --exclude='/status' --exclude='/tmp/' --exclude='/shadow/' --exclude='tmp_*' \
  "${CH_STORE}/" "${SNAP}/" || rc=$?
if [ "${rc}" -ne 0 ] && [ "${rc}" -ne 24 ]; then
  log "FATAL: ClickHouse snapshot rsync failed (rc=${rc})"; rm -rf "${SNAP}"; exit "${rc}"
fi
log "dumping ClickHouse 'default' DB from the snapshot ($(du -sh "${SNAP}" 2>/dev/null | cut -f1))"
clickhouse local --path="${SNAP}" --config-file="${CONF}" \
  --query="BACKUP DATABASE default TO File('clickhouse-backup.new')"
rm -rf "${SNAP}"
[ -e "${DUMP}" ] && mv "${DUMP}" "${DUMP}.old"
mv "${DUMP}.new" "${DUMP}"
rm -rf "${DUMP}.old"
log "ClickHouse dump published: ${DUMP} ($(du -sh "${DUMP}" 2>/dev/null | cut -f1))"
