# 7. ClickHouse backup: persistentDir + snapshot + `clickhouse local` logical-dump triplet

Date: 2026-06-30

## Status

**Accepted + implemented (ships in v0.1.4 / image 0.2.0-7). Validated 2× under write load.** The real
`cloudron backup → clone` round-trip passes all 8 criteria on the automated path (26k + 116k spans). Three
fatal bugs were caught here that lenient idle checks had masked: the backup `status`-flock (Code 76), the
restore's not-server-startable store (Code 48 — fixed by a **transient clickhouse-server**, NOT `clickhouse
local`), and the Quickwit cross-store skew (ADR 0011). This ADR is the reference to port back to Langfuse's
ADR 0006 — note BOTH the **snapshot** (backup) and **transient-server** (restore) steps a naive port misses.

## Context

The bundled ClickHouse store as raw files under `/app/data` is captured by Cloudron's live rsync syncer.
ClickHouse merge temp dirs (`tmp_merge_*`) that vanish mid-walk make the syncer's `readTree` return `null`,
and a `.sort()` on that null throws — aborting the **whole-server** backup, not just this app's (field
guide #46). Quiesce is impossible: there is no live pre/post-backup hook, `backupCommand` runs in a
*separate temporary container* that cannot signal the live ClickHouse, and Cloudron will not back up a
*stopped* app (#47). The constraint that matters is not "keep raw files in `/app/data`" — it is that the CH
data stay **inside Cloudron's backup/restore surface**. A logical dump preserves that.

## Decision — the 9.1 triplet (persistentDir + snapshot-dump + restore)

- **`persistentDirs: ["/var/lib/clickhouse"]`** — the CH store lives here, **excluded from the rsync walk**,
  so the `tmp_merge_*` transients are no longer in the walked tree → the race is **structurally gone**,
  independent of any upstream syncer patch. (`conf/clickhouse/config.d/cloudron.xml` repoints
  `path`/`tmp_path`/`user_files_path`/`format_schema_path`/access to it; `start.sh` mkdirs/chowns it and
  drops any stale pre-move `/app/data/clickhouse`.)
- **`backupCommand` = `conf/backup-clickhouse.sh`** — in the temp container, **snapshot the committed store
  to an unlocked copy, then dump from the copy** (see "the lock", below) into `/app/data/clickhouse-backup`
  (which IS backed up). Atomic `.new`→rename.
- **`restoreCommand` = `conf/restore-clickhouse.sh`** — repopulate the empty persistentDir from the dump
  before the app starts, via a **transient `clickhouse-server`** (NOT `clickhouse local` — see "the restore",
  below). Idempotent + fail-loud: restore only into an absent/empty store, never clobber. (Restore needs no
  *snapshot* — no live lock at restore time — but it does need a real server to build a startable store.)
- `minBoxVersion: 9.1.0` (box is on 9.2.0). Note: a persistentDirs change is itself a deployment + portability
  hazard — see **ADR 0010**.

## The lock — why you cannot `clickhouse local` the live persistentDir directly

The first design pointed `clickhouse local --path=/var/lib/clickhouse` straight at the store in the temp
container. **It fails — at idle, not only under load** (verified on-box):

```text
Code: 76. DB::Exception: Cannot lock file /var/lib/clickhouse/status.
           Another server instance in same directory is already running. (CANNOT_OPEN_FILE)
```

The live server holds an flock on `<store>/status`, and that **inode is shared across the bind mount** into
the temp container, so `clickhouse local` (which takes the same lock) collides. There is no lock-skip /
readonly flag (`clickhouse local --help` confirms). The fix is to dump from a **copy** that carries no live
`status`. (The `store/metadata` guard in `backup-clickhouse.sh` *passed* before this error — proving the
temp container does bind-mount the persistentDir; the mount was never the problem, the lock was.)

## The restore — why a transient server, not `clickhouse local`

Symmetry would suggest restoring with `clickhouse local` too. **It doesn't work** (caught by a real `cloudron
clone`): `clickhouse local` RESTORE omits the implicit `default` database definition and lays out Atomic
tables in a way the real `clickhouse-server` cannot start on —

```text
Code: 48. DB::Exception: Data directory for default database exists, but metadata file does not.
```

The store is still fine for *another* `clickhouse local` read (lenient) — which is exactly why an idle gate
that only restored via `clickhouse local` **masked this**; the crash surfaces only when the real server boots
on the restored store. Fix: `restore-clickhouse.sh` brings up a **transient `clickhouse-server`** on the empty
persistentDir and runs the RESTORE through it, so the server builds a self-consistent, server-startable store.
It runs in the background (NOT `--daemon`, which conflicts with the console logger) as `cloudron`, with
`backups.allowed_path` supplied via `config.d/cloudron.xml`; passwords come from the restored `.secrets` (the
users.d `from_env`).

## The proven recipe (snapshot→dump→restore validated on-box, idle — 43 tables / 15 views clean)

- Binary: the bundled multicall `clickhouse` as **`clickhouse local`** (Dockerfile symlinks
  `/usr/bin/clickhouse-local`). `rsync` is present in the app image too.
- **Snapshot:** `rsync -a --exclude='/status' --exclude='/tmp/' --exclude='/shadow/' --exclude='tmp_*'
  /var/lib/clickhouse/ /app/data/.clickhouse-snapshot/`. Excludes the live lock, the active merge/insert
  transients (`tmp_*` at any depth — the same dirs that race #46), and FREEZE output. MergeTree parts are
  immutable and merged-away parts linger `old_parts_lifetime` (~8 min), so a copy finishing inside that
  window sees a coherent set; rsync tolerates a transient vanishing (exit 24, treated as success). The
  snapshot is built + removed inside `backupCommand`, so it is **never archived**.
- Backup: `clickhouse local --path=<snapshot> --config-file=backups.xml --query="BACKUP DATABASE default TO
  File('…')"`. **`BACKUP DATABASE default`, NOT `BACKUP ALL`** — `ALL` trips on `system.users` access
  entities (`ACCESS_STORAGE_DOESNT_ALLOW_BACKUP`); the user accounts come from `users.d` config at boot.
- Restore (via the transient server, above): `RESTORE DATABASE default FROM File('…') SETTINGS
  allow_different_table_def=1, allow_different_database_def=1`. **Both** are required:
  `allow_different_table_def` for the `_v0` views' dict refs CH re-normalizes to `default.`-qualified
  (`CANNOT_RESTORE_TABLE` otherwise); `allow_different_database_def` for the db-level UUID mismatch restoring
  into the server's auto-created `default` (`CANNOT_RESTORE_DATABASE`, Code 607).
- `backups.allowed_path = /app/data` (`conf/clickhouse/backups.xml`) — File backups are sandboxed to that
  base; the File path is relative to it.

## Operational cost

The snapshot is a **full cross-volume copy** (persistentDir → `/app/data`), so `/app/data` must have free
space ≥ the ClickHouse store size during a backup, plus store-size extra I/O per backup. Acceptable at
LITE scale; a future optimization (online `BACKUP` driven by the live server over a `/app/data` file-flag
handshake, or `FREEZE` hardlinks) could avoid the copy. Prove the simpler path first.

## Box-authority unknowns (resolved on-box)

- **Not quiesced** — the live app + its ClickHouse keep running during `backupCommand` (separate temp
  container; Cloudron won't back up a stopped app). This is exactly *why* the lock bites and the snapshot is
  required.
- **`clickhouse local` and `rsync` are both in the image** (confirmed present in the `cloudron/base`-derived
  app image).
- **The temp container DOES bind-mount the persistentDir** (the `store/metadata` guard passed).

## Residual risk + fallback

With the snapshot the lock is gone. The remaining risk is **copy consistency under heavy write load**: a
committed part deleted by a merge mid-copy. Bounded by `old_parts_lifetime` (~8 min) for stores that copy
inside that window; **the under-load gate must prove it for this workload.** Fallback if it proves
inconsistent under load: have the live server drive an online `BACKUP` (consistent) via a `/app/data`
file-flag handshake, or `ALTER TABLE … FREEZE` then copy the shadow hardlinks — but prove the snapshot path
first.

## Acceptance gate (Phase 7; non-negotiable)

A real Cloudron backup → restore round-trip, **with ingestion actively running**, repeated 2–3×, proving:

- **AEAD key byte-identical** to the install's own pre-backup `AEAD_SECRET_KEY` sha256. **Per-install** — the
  key reseeds on uninstall+reinstall, so capture the baseline fresh each time; do **NOT** hardcode a value.
  (Earlier hard-coded baselines all died with reinstalls — do not name one here; capture it fresh each run.)
- a **provider key stored fresh** (via the UI, post-SSO) still **decrypts** post-restore.
- the **`_v0` analytics views return correct aggregates via real dashboard queries** — not just
  `SELECT count()` on a base table (`allow_different_table_def` normalized the dict refs; a wrong ref gives
  wrong aggregates while the base count still looks fine).
- **Quickwit search** works post-restore.
- **`/var/lib/clickhouse` is excluded from the file-walk** — a whole-server backup under load does NOT abort
  (if it does, exclusion failed and #46 is not escaped).
- **restore→boot→user-seeding→query order** holds: restored data is queryable by the freshly-seeded RO user.
- seeded-secret **ownership/mode re-asserted** (`0600 cloudron`, #12).

## Port-back discipline

Once the gate passes, this recipe updates **Langfuse ADR 0006** (Langfuse v0.2.0 implements *this* — crucially
the **snapshot** (backup) + **transient-server** (restore) steps a naive port would miss) and sharpens the
field-guide entry to: "BACKUP — snapshot the committed store to an unlocked copy then `clickhouse local` dump
(the live `status` flock makes a direct dump impossible, Code 76); RESTORE — via a transient `clickhouse-server`,
NOT `clickhouse local` (whose output the real server can't start on, Code 48), with
`allow_different_{table,database}_def`." The **dump/restore recipe ports verbatim; the persistentDirs move
does NOT** — see ADR 0010 for the one-time in-place migration an already-published package needs.
