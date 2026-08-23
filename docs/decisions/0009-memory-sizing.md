# 9. Memory sizing: 4 GiB memoryLimit, coupled to the 2 GiB ClickHouse cap

Date: 2026-06-30

## Status

Accepted (measured on a throwaway Cloudron test instance).

## Context

Four processes share ONE container memory budget (the manifest `memoryLimit`): bundled ClickHouse +
Quickwit, the Rust app-server, and the Next.js frontend. In LITE there is no Redis/RabbitMQ addon — the
ingestion queue + cache are IN-PROCESS (TokioMpsc + Moka in app-server), so a heavy ingestion burst buffers
in app-server RSS until it drains to ClickHouse.

## Measurements (cgroup v2, 16 GiB test ceiling)

- Boot + 48 ClickHouse migrations + Quickwit index init: **peak 1.76 GiB** (`memory.peak` 1887576064).
- After a 2400-span OTLP burst + `OPTIMIZE TABLE … FINAL` on `spans`/`traces_replacing`: peak **unchanged
  at 1.76 GiB**, current 1.66 GiB. The migration boot is the heaviest moment for a small install; light
  ingestion + merges did not exceed it.
- Per-process RSS under load: ClickHouse ~1.01 GiB, frontend ~0.28 GiB, ClickHouseWatch ~0.11 GiB,
  app-server ~0.10 GiB, Quickwit ~0.09 GiB.

## Decision

- **`memoryLimit` = 4 GiB (`4294967296`)** — top of the measured-vs-bounded range. The worst-case bound is
  CH's **2 GiB cap** + the non-CH working set (~1.3 GiB observed) + a heavy in-process ingestion-queue spike
  - headroom ≈ 3.5 GiB; 4 GiB clears it. (Down from the 6 GiB Phase-0 placeholder.)
- **ClickHouse `<max_server_memory_usage>` = 2 GiB** (absolute, in `conf/clickhouse/config.d/cloudron.xml`)
  — NOT a ratio (unverified whether the bundled CH reads the cgroup limit or host RAM; a ratio against
  misread host RAM could OOM the container).

## COUPLING — do not regress

`memoryLimit` and the ClickHouse cap are **coupled**. `memoryLimit` must always exceed `CH_cap` + the
non-CH working set (~1.5 GiB) + headroom. **If `memoryLimit` is ever lowered, lower
`<max_server_memory_usage>` in the same change** (e.g. 3 GiB limit → 1.5 GiB CH cap). Never lower the
manifest limit without re-checking the CH cap, or ClickHouse alone can approach the limit and OOM-kill the
whole container (taking the DB down with the app — there is no separate addon budget).

## Consequences

- Good for personal / small-team installs. **Heavy-volume** installs (sustained high-rate ingestion) may
  need a higher `memoryLimit`, because the in-process TokioMpsc queue buffers in app-server RSS — the point
  at which the FULL profile (a RabbitMQ broker) would earn its keep (future option).
- Re-measure the warmup peak whenever the upstream version (migration set) or the bundled-store versions
  change.
