[0.3.0]

- Base image cloudron/base 5.0.0 to 6.0.1 (Ubuntu 26.04): the operating system moves to Ubuntu 26.04, with current security updates including the removal of the compromised eMudhra emSign ECC Root CA - G3 from the trusted certificates. The Laminar server is rebuilt from source against the new system libraries (glibc 2.43, OpenSSL 3.5); Laminar itself is unchanged (still 0.2.5).
- Includes the 0.2.1 ClickHouse diagnostic-table tidy-up, which was never published separately.
- Fixes span search, which returned nothing in 0.2.0 and earlier: the search index (`spans_v2`) was never created, because the index definitions Laminar creates it from were missing from the image. The index is now created on the first start after updating (and is left alone on later starts); no ClickHouse data is touched. Spans received before this update are not in the search index and will not appear in search: Laminar offers no reindex or backfill for spans. They remain stored and visible in traces. Spans received after the update are searchable.
- Documentation: the post-install notes now give the exact steps for restoring a backup in place, including the manual ClickHouse step and the fact that search data (Quickwit) is not rolled back.

[0.2.1]

- ClickHouse now also switches off seven more of its internal diagnostic tables, so the package's list
  matches the configuration Laminar itself adopted upstream (following our report). These tables were
  already empty on this package, so this is tidying rather than a fix; nothing to do after updating.
- No change to Laminar (still 0.2.5), sign-in, ingest or backups.

[0.2.0]

- Upstream Laminar 0.2.3 to 0.2.5.
- Workspace LLM profiles for self-hosted signal runs: configure LLM provider credentials in the UI and assign them to signals.
- Signal versioning: new `version` column on signals and playgrounds, with a dedicated history table.
- Project API Signal CRUD operations added.
- CLI auth onboarding improvements (Approve as last step).
- Clusters visualisation feature in the Runs tab.
- Group-scoped content deduplication and signal events now appear on the traces table.
- Cache and reasoning token columns added to spans.
- Custom time ranges extended to 6 months.
- Various UI polish fixes.
- No packaging changes: auth topology, workspace layout and secrets handling unchanged.

[0.1.7]

- Update laminar 0.2.1 -> 0.2.3
- Security: per-project rate limiting on the SQL and ingestion endpoints prevents unbounded data access and pipeline flooding; a fix prevents cross-project data access via a spoofed projectId in the request body
- Breaking: traces_agg column types changed from bitmasks to enum arrays; new traces_static table introduced for static trace columns; all read paths migrated to the new tables; checkpoints pipeline now gated behind CHECKPOINTS_ENABLED env var (disabled by default); field renamed from p50_ms to avg_ms
- Routine features and fixes across the release
- No packaging changes: auth topology, workspace layout and secrets handling unchanged; base and built images digest-pinned

[0.1.6]

- Upstream Laminar 0.2.0 to 0.2.1. Sign-in and sign-up screens change upstream; Cloudron single
  sign-on wiring is unchanged (same OIDC callback path), but confirm a fresh sign-in after updating.
- Project API keys can now carry an expiry and an owning user. Existing keys are unaffected — the
  new columns are nullable and default to no expiry.
- Upstream drops the superseded Postgres `labeling_queue_items` table; the labelling queue has been
  served from ClickHouse since before this release, so queue data itself is not in that table.

[0.1.5]

- Much faster backups: ClickHouse's internal diagnostic tables are no longer kept forever, so a backup now
  costs what your trace data costs. On a one-month-old install those tables had grown to 13.4 GiB and were
  being re-read every night to produce a 376 KB dump.
- Backups no longer archive a quarter-gigabyte of empty space: Quickwit's pre-allocated write-ahead log is
  copied as the sparse file it is, instead of being written out in full on every backup and restore.
- Backups now leave a per-phase timing record in `/app/data/backup-timing.log`, so a slow backup can be
  diagnosed from the backup itself.
- Upgrading an existing install? See POSTINSTALL for the one-off command that reclaims the diagnostic-table
  space already on disk; new writes stop either way.

[0.1.4]

- Hardened backups: the bundled ClickHouse and Quickwit stores now live on dedicated volumes and are captured
  by a consistent logical dump/restore, so automatic backups can't race live writes or abort mid-run.
- Right-sized memory: 4 GiB default with an internal ClickHouse cap, measured for small/personal installs.
- Trace ingestion is OTLP/HTTP only (protobuf or JSON) — simpler and a smaller attack surface than gRPC.
- Ingestion is traces-only; the endpoint requires TLS (send OTLP/HTTP over `https`, not cleartext).
- Added a pre-publish secret-scan release gate.

[0.1.0]

- Initial release: Laminar 0.2.0 (open-source LITE profile) packaged for Cloudron.
- Next.js dashboard (Better Auth) + Rust app-server (OTLP/HTTP + REST ingestion) + bundled ClickHouse and Quickwit; PostgreSQL via the Cloudron addon.
- App-native OIDC single sign-on through the Cloudron oidc addon; passwordless local-email sign-in when SSO is off.
- Trace ingestion on a dedicated subdomain, secured by per-project API keys.
- Data-loss-critical encryption key generated once and preserved across updates and restores.
