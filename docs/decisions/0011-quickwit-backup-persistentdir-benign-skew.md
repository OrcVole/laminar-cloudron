# 11. Quickwit backup: persistentDir + benign-skew capture ordering

Date: 2026-06-30

## Status
**Accepted + implemented (ships in v0.1.4 / image 0.2.0-7).** The cross-store skew was caught by the Phase 7
under-load gate (the idle clone masked it, same as Code 48/76); the persistentDir + ordering fix is
implemented and **validated 2× under load** — clones of mid-flush backups at 26k and 116k spans both showed
`quickwit ≤ ch ≤ pg` (qw lags ch ~700, ch lags pg ~3–5k), all 8 criteria pass, file-walk excludes
`/var/lib/quickwit` and the backup never aborts while splits flush.

## Context
Quickwit is a **derived** full-text index over the ClickHouse spans. Two options for its backup:
- **Rebuilt-from-CH** — don't back it up, reindex from CH on restore. **Infeasible**: Laminar's indexer only
  indexes spans as the app-server *publishes* them at ingestion; there is no batch "reindex from ClickHouse"
  path, so a restore couldn't repopulate the index.
- **Backed-up** — the index rides the backup. This is the only viable model.

But Quickwit's data started raw under `/app/data/quickwit`, i.e. in Cloudron's live **file-walk** — captured
at a *different instant* than the ClickHouse dump (`backupCommand`). The CH dump, the Postgres addon-dump, and
the Quickwit file-walk are **three non-atomic captures**, and under write load they diverge.

## The finding (under-load gate, measured — not assumed)
A real `cloudron clone` of an under-load backup, counts read from the restored clone (synthetic data is
1 span = 1 trace, so the counts are directly comparable):
```
clone_ch_spans   = 111050   ← OLDEST  (backupCommand)
clone_pg_traces  = 111912   ← +862    (PG addon-dump, ~3.5 s after CH)
clone_qw_search  = 129450   ← +18400  (Quickwit file-walk, ~74 s after CH)
```
So the **empirical capture order on this box/Cloudron is `CH < PG < Quickwit`**. Quickwit, captured ~74 s
after the CH dump, ended up **18.4k spans AHEAD of CH** → search returns hits whose traces aren't in the
restored CH (user-visible: a search result with no backing trace). The Quickwit copy itself wasn't *corrupt*
(it booted clean) — the defect is the **timing skew**.

## Decision — bias the residual skew to the BENIGN direction
The captures cannot be made atomic (no live pre-backup hook to quiesce ingestion). So instead of chasing
zero skew, **bias which way the residual points**:
- **Quickwit (search index) must LAG ClickHouse (trace store)**, never lead — `quickwit_search ≤ ch_spans`.
  A lag means "indexed slightly behind CH" (benign — those traces exist in CH, just not yet searchable; a real
  reindex/continued ingestion catches up). A lead means "search hit with no trace" (the bug above).
- Achieve it by capturing **Quickwit FIRST, ClickHouse SECOND**, both inside `backupCommand`:
  - **persistentDir `/var/lib/quickwit`** — moves Quickwit's data out of the file-walk (so it is NOT captured
    late by the walk; also removes the #46 abort risk on its live split files).
  - `backup-clickhouse.sh`: rsync-snapshot Quickwit → `/app/data/quickwit-backup` **first**, then snapshot +
    `clickhouse local` dump ClickHouse. CH finishes last → CH is fresher → Quickwit lags it.
  - `restore-clickhouse.sh`: rsync the Quickwit snapshot back into its persistentDir (Quickwit boots from a
    file copy — no server needed), plus the transient-server CH restore (ADR 0007).
- **Postgres needs no fix.** It is the addon-dump, which Cloudron runs *after* `backupCommand` (verified:
  `pg_traces 111912 ≥ ch_spans 111050`), so PG is fresher than CH → every restored CH span has its PG trace
  row (+ a few harmless empty traces). Net oldest→newest: **Quickwit ≤ ClickHouse ≤ Postgres**, every residual
  benign.

## Generalizable principle
For any package bundling multiple stores backed up by **different mechanisms** (backupCommand vs addon-dump vs
file-walk), the captures are non-atomic. **Measure the actual order on the actual box** (clone + compare each
store's restored cut) — do NOT infer it from manifest field order or docs — then order the controllable
captures (those inside `backupCommand`) so the residual skew points benign relative to the foreign-key
direction (derived/child store should lag its source/parent, never lead).

## Acceptance gate (Phase 7; under load, 2–3×)
- `quickwit_search ≤ ch_spans` — search never ahead of the trace store (`==` ideal, `<` benign lag OK,
  `>` = FAIL).
- `ch_spans ≤ pg_traces` — no CH span without a PG trace row.
- Quickwit starts clean (no corrupt/half-written split, no failed boot) and search returns.
- The whole-app backup does **not** abort while Quickwit flushes splits (confirms `/var/lib/quickwit` is
  excluded from the file-walk, #46).

## Port-back
Langfuse (ClickHouse only, no Quickwit) does not need the Quickwit triplet. What ports is the **principle**:
when a package has >1 store on different backup mechanisms, measure the capture order under load and bias the
residual benign. Greenfield for Laminar (the first published version carries both persistentDirs; no in-place
migration needed — cf. ADR 0010).
