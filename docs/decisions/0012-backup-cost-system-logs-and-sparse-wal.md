# 12. Backup cost: bound the ClickHouse system logs, keep the Quickwit WAL sparse

Date: 2026-08-01

## Status

**Accepted + implemented + verified in production (ships in v0.1.5).** Two independent defects found by
profiling a production nightly backup. Both are in this package, not upstream. Supersedes nothing; refines
the backup path established by [ADR 0007](0007-clickhouse-backup-persistentdirs-triplet.md) and
[ADR 0011](0011-quickwit-backup-persistentdir-benign-skew.md), neither of whose decisions change.

Measured on the production instance, before and after:

| | Before | After |
|---|---|---|
| `backupCommand` total | ~1526 s (25m26s) | **9 s** |
| ClickHouse store rsync | 1091 s | **0 s** |
| `clickhouse local` dump | 33 s | 3 s |
| Quickwit snapshot | 4 s (257 MB written) | 5 s (292 KiB written) |
| ClickHouse store on disk | 14 GiB, 49,050 files | **166 MiB, 890 files** |
| `/app/data` (what is uploaded) | 259 MB, 120 files | **672 KiB, 117 files** |
| ClickHouse container CPU, steady state | ~330 % (3.3 cores) | **~45 %** |

The CPU figure was not an anticipated benefit. The self-telemetry was not merely archived nightly, it was
being written and merged continuously: `trace_log` gained ~24 parts a minute, each requiring merges, for
data nothing reads. Bounding it returned roughly 2.9 cores to the host.

**Proven by restore, not merely by a faster backup.** `restoreCommand` was run against a copy of the real
post-fix production backup, into empty persistentDirs, in the shipped image:

- `default` restored to **43 tables / 15.62 KiB**, matching production exactly; `spans`, `traces_v0`,
  `evaluation_datapoints`, `events` and `llm_messages` all present and queryable.
- Quickwit restored to 257 MiB apparent / **292 KiB allocated**, so the WAL stays sparse across the full
  backup-and-restore round trip, not just on the backup side.
- The only `system` MergeTree table recreated was `query_log`: the retention config holds on a fresh
  restore, so a restored install does not reacquire the problem.

## Context

On a production install (one month of uptime, moderate ingestion) the `backupCommand` took **25 minutes 26
seconds**. Cloudron's own file walk and the offsite upload accounted for about one minute of that; the rest
was inside our script. The output it produced was 259 MB across 120 files, which made the run look
inexplicably slow for its size.

The output is the wrong thing to measure. What the script *traverses* is the two persistentDirs, and they
looked nothing like the output:

| Store | Real data on disk | What the script processed |
|---|---|---|
| `/var/lib/quickwit` | 292 KiB, 36 files | 257 MB written |
| `/var/lib/clickhouse` | under 2 MiB of `default` | **14 GiB, 49,050 files** |

### Defect 1 — ClickHouse system logs were unbounded

This package never configured the `system.*_log` tables, so upstream defaults applied: every table on,
retained forever. Measured after one month, every one of the seven largest directories in the store was a
system log table:

```text
11 GiB   system.trace_log                  (3,141 files)
706 MiB  system.text_log
665 MiB  system.part_log
643 MiB  system.metric_log
451 MiB  system.asynchronous_metric_log
 51 MiB  system.background_schedule_pool_log
 46 MiB  system.error_log
205 MiB  logs/  (clickhouse-server.log, .err.log, 6 rotations)
```

`backupCommand` rsyncs the whole store into a transient snapshot so `clickhouse local` can attach it without
fighting the live server's `status` flock (ADR 0007), then runs `BACKUP DATABASE default`. Only `default` is
dumped: **376 KB**. So roughly 99.99 per cent of the traversal was ClickHouse's own self-telemetry, dumped by
nothing and restored by nothing, and it set the cost of the backup. It also grew without bound, so the
backup got slower every night.

This is not a cold-start artefact. `trace_log` reached 11 GiB in a single month of ordinary operation.

### Defect 2 — rsync materialised Quickwit's sparse WAL

Quickwit pre-allocates two 128 MiB write-ahead log files as sparse files:

```text
wal/wal-00000000000000000000      apparent 128 MiB, allocated 0
queues/wal-00000000000000000000   apparent 128 MiB, allocated 4 KiB
```

`rsync -a` does not preserve holes without `--sparse`. The snapshot therefore wrote all 256 MiB out in full,
which is the entire "257 MB" of the Quickwit backup: a 292 KiB store archived as a quarter-gigabyte of
zeroes, pushed offsite nightly. The `restoreCommand` had the same flag omission, so a restore also
re-inflated the WAL into the fresh persistentDir.

Worth recording because it is the near miss: the transient `indexing/` and `delete_task_service/` ULID
directories were the obvious suspect and are not the problem. They are a few kilobytes.

## Decision

**1. Bound the system logs at the source, in `config.d/cloudron.xml`.** Disable the profiling and metric
tables outright (`remove="1"`), and cap the two an operator actually reads with a 3-day TTL:

- Disabled: `trace_log`, `text_log`, `part_log`, `metric_log`, `asynchronous_metric_log`,
  `background_schedule_pool_log`, `query_metric_log`, `processors_profile_log`, `asynchronous_insert_log`.
  These exist to tune a cluster. This is a single embedded node serving one application, and the operator
  debugs it from the stdout server log that Cloudron already captures.
- Kept with `<ttl>event_date + INTERVAL 3 DAY DELETE</ttl>`: `query_log`, `error_log`. These are what you
  read when this instance misbehaves; 3 days comfortably outlives the nightly cycle that would surface a
  fault, and the cap means they cannot become this problem again.
- **Adding a TTL to an existing table does not retrofit it.** Measured on the production upgrade: ClickHouse
  treats the changed engine definition as a structure change, renames the existing table to `<name>_0`, and
  creates a fresh table carrying the TTL. So the TTL governs new rows only, and the pre-upgrade history
  survives in `query_log_0` / `error_log_0` until dropped. An earlier draft of this ADR claimed the TTL
  drained existing history on restart; the box refuted that, and the one-off cleanup below covers it.
- Laminar itself queries no `system.*_log` table (checked across the upstream tree), so nothing in the
  application depends on them.

Verified in the shipped image (ClickHouse 25.12): the server starts with no config error, all nine disabled
tables are absent from `system.tables`, and both survivors report
`TTL event_date + toIntervalDay(3)` in `engine_full`.

**2. Do not try to filter the system tables out at backup time.** They live under `store/` addressed by
UUID, so there is no stable rsync pattern for them, and removing a database's data from the snapshot while
leaving its metadata would break `clickhouse local`'s attach and fail the whole backup. Bounding the store
is the correct layer. The one static exclusion that *is* safe has been added: `--exclude='/logs/'`, the
server's own text log, which is not a table, is not read by `clickhouse local`, and is recreated empty by
`restoreCommand`.

**3. `rsync -aS` on both sides of the Quickwit copy.** The WAL is kept, not excluded: it holds spans that
have been ingested but not yet flushed into a split, so dropping it would lose data and would violate the
`quickwit ≤ ch` ordering guarantee of ADR 0011. It simply must not be inflated. Adding `-S` to the restore
side also re-sparsifies a WAL restored from a pre-0.1.5 backup.

**4. Make the diagnostics survive the run.** Cloudron launches the backup container with
`--log-driver=none`, so every `log()` line this script writes to stdout is discarded. Twenty-five minutes of
usable phase-by-phase diagnostics were thrown away nightly, which is why the slow step had to be found by
inspecting the box rather than by reading a log. The script now writes a per-phase timing line to
`/app/data/backup-timing.log` (writable, rides the backup, last 30 runs retained), emitted from an `EXIT`
trap so a failed run still records how far it got.

## Consequences

- The ClickHouse store stops growing without bound, which helps the running app and its disk footprint, not
  only the backup.
- **Existing installs need a one-off drop.** Disabling a system log stops new writes; it does not remove
  data already on disk, and adding a TTL renames rather than retrofits (above). An install upgrading to
  0.1.5 keeps its accumulated `trace_log`, and its pre-upgrade `query_log`/`error_log` history, until the
  tables and the `_0` renames are dropped explicitly. See POSTINSTALL.
- **Restarting into the new config before dropping causes a merge storm, so do both together.** Measured on
  the production upgrade: the restart stopped new writes but made ClickHouse re-open the 13.4 GiB backlog,
  which put `system.metric_log` into 6 concurrent merges holding 1.2 GiB of the 2 GiB `max_server_memory_usage`
  cap. The app stayed up but `/sign-in` took 26 s, so Cloudron's health check failed it. The DROP cleared it
  immediately: 0 active merges, `/sign-in` back to 0.03 s. Do not deploy this config to a large existing
  store and leave the cleanup for later.
- The `<logger>` `size`/`count` caps (100 MiB x 3) still bound `logs/` on disk; it is now simply not copied.
- Backup cost is now a function of actual Laminar data, which is the property we wanted and did not have.
- The residual risk is that some future ClickHouse version adds another on-by-default log table. The timing
  line in `/app/data/backup-timing.log` is what makes that visible early rather than a year later.

## Reported upstream

Defect 1 is not only ours. Every upstream compose file (`docker-compose.yml`, `-full`, `-local-build`,
`-local-dev`, `-local-dev-full`) mounts a ClickHouse config into `users.d` only, setting a single profile
option, so no `config.d` server-level bound is ever applied and every self-hoster inherits the same
unbounded system logs. Filed as **[lmnr-ai/lmnr#2176](https://github.com/lmnr-ai/lmnr/issues/2176)** with
the configuration block, the measurements, and both traps above. Defect 2 is ours alone: upstream does not
snapshot Quickwit with rsync.

## Alternatives rejected

- **Exclude the `system` database from the snapshot.** No stable path expression, and a partial store breaks
  the attach. Rejected in favour of bounding the store.
- **Exclude Quickwit's `wal/` and `queues/`.** Would have fixed the 257 MB just as effectively and lost
  un-indexed spans doing it, breaking ADR 0011's benign-skew guarantee.
- **Disable `query_log` and `error_log` too.** Cheapest option, and it removes the only in-database record
  of what went wrong on an instance you cannot easily reach. The 3-day TTL costs little and keeps it.
- **Accept the cost and document it.** Defensible when the cost is fixed. This one grew nightly.
