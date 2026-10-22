# 13. Quickwit 0.9 migration and the restore quarantine

Date: 2026-10-22

## Status

Accepted. Ships in package 0.4.0 (Laminar 0.3.2, Quickwit 0.9.1).

## Context

Laminar 0.3.x runs on Quickwit 0.9. On first start Quickwit migrates its data directory in place; 0.8.x cannot
open it afterwards. `/var/lib/quickwit` is a `persistentDir` (ADR 0010, 0011), which Cloudron leaves alone on an
in-place restore (field guide #327). A restore could therefore put a version next to a directory it cannot read.
The index is derived but cannot be rebuilt from ClickHouse (ADR 0011).

## Decision

1. Accept the one-way migration; say so in CHANGELOG and POSTINSTALL; rely on the Cloudron backup before update.
2. The restoreCommand flags an in-place restore (`/var/lib/quickwit/.restore-pending`, written only when the
   directory is populated). `start.sh` moves everything aside to `/var/lib/quickwit/quarantine-<UTC time>`
   (never deleted, removed after 30 days) and Quickwit starts empty. Clone restores load the snapshot as before.
   Search history before the restore is lost; traces are not. The backup excludes `quarantine-*`.
3. `QUICKWIT_FORCE_COMMIT=false`, `QUICKWIT_SPANS_V2_COMMIT_TIMEOUT_SECS=30` (field guide #329): fewer splits and files.
4. A rollback of the package image to 0.3.0 cannot be guarded from 0.4.0 code. Documented as unsupported.

## Consequences

An in-place restore always empties search, even when the backup came from the same version. That is the price of
never starting a version on a directory it cannot read, and it matches how every other store here is handled.
