## Laminar is installed 🎉

**First sign-in**

- Open the app and create your account. With **Cloudron SSO (OIDC)** enabled, sign in with your Cloudron
  account: **the button is labelled "Keycloak"**. That is Laminar's name for its generic OpenID Connect
  slot, which this package points at Cloudron; it is the Cloudron sign-in, not a second identity system. With SSO disabled, sign-in is **passwordless local-email** — anyone who can reach the app can
  sign in, so keep SSO on (or otherwise restrict access) for a private instance.

**Sending traces**

- Your trace-ingestion endpoint is the **ingestion subdomain** (a separate subdomain from the dashboard,
  chosen at install). Point your Laminar SDK or OTLP/HTTP exporter `baseUrl` there.
- Create a project in the UI to obtain a **project API key**, and send it as the ingestion credential.
- Ingestion is **OTLP/HTTP** for **traces** (`POST /v1/traces`). From an OpenTelemetry collector or an LLM
  gateway, use the **HTTP/protobuf** exporter (not gRPC) and make sure it negotiates **TLS** to the `https`
  endpoint. Metrics/logs exporters aren't accepted (a `/v1/metrics` POST just 404s harmlessly).
- The endpoint is **HTTPS-only — your exporter must actually speak TLS.** Some OTLP exporters and LLM
  gateways have a "plaintext HTTP" export mode that sends **cleartext even to an `https://` URL**; those get a
  proxy **`400 — plain HTTP request was sent to HTTPS port`** and never reach the app. If your client can't do
  real TLS to the endpoint, put a local **OTLP collector** in front as a TLS relay (exporter → collector in
  plaintext → collector → `https` to the ingest endpoint with your API key).

**Data & backups**

- All state — PostgreSQL (addon), the bundled ClickHouse and Quickwit stores, and the encryption key — is
  captured by Cloudron's automatic backups. The data-encryption key is generated once on first boot and
  preserved across updates and restores, so existing encrypted values (stored API keys, provider secrets)
  keep working. Do not reinstall fresh if you want to keep existing data.
- Each backup leaves a per-phase timing line in `/app/data/backup-timing.log` (last 30 runs). Cloudron runs
  the backup container with logging disabled, so this file is the only record of how long a backup took and
  which phase spent the time.

**Upgrading from 0.1.4 or earlier: reclaim the diagnostic-table space**

- From 0.1.5, ClickHouse's internal diagnostic tables (`system.trace_log` and friends) are switched off or
  capped, so they no longer grow without bound. Switching them off stops new writes but does **not** remove
  what is already on disk, which on a months-old install can be many gigabytes.
- **Run it promptly after the update, not days later.** The update stops new writes, but it also makes
  ClickHouse re-open the existing backlog and merge it. On a large store that merge activity can be heavy
  enough to slow the app until the tables are gone. Treat the update and this command as one operation.
- To reclaim it, once, after the update has been applied:

  ```bash
  cloudron exec --app <your-app> -- clickhouse-client --multiquery --query "
    DROP TABLE IF EXISTS system.trace_log SYNC;
    DROP TABLE IF EXISTS system.text_log SYNC;
    DROP TABLE IF EXISTS system.part_log SYNC;
    DROP TABLE IF EXISTS system.metric_log SYNC;
    DROP TABLE IF EXISTS system.asynchronous_metric_log SYNC;
    DROP TABLE IF EXISTS system.background_schedule_pool_log SYNC;
    DROP TABLE IF EXISTS system.query_metric_log SYNC;
    DROP TABLE IF EXISTS system.processors_profile_log SYNC;
    DROP TABLE IF EXISTS system.asynchronous_insert_log SYNC;
    DROP TABLE IF EXISTS system.query_log_0 SYNC;
    DROP TABLE IF EXISTS system.error_log_0 SYNC;"
  ```

- This touches only ClickHouse's own telemetry about itself. No trace, span, evaluation or dataset data
  lives in the `system` database, and the tables are not recreated once the update is in place.
- `system.query_log` and `system.error_log` are kept and capped at 3 days. The `_0` entries in the list are
  your pre-update history: applying the cap is a structure change, so ClickHouse renames the old table aside
  and starts a fresh one. The cap applies going forward; the renamed copies are what the last two lines
  remove.

Project homepage: <https://www.lmnr.ai> — Docs: <https://docs.lmnr.ai>
