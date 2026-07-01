## Laminar is installed 🎉

**First sign-in**

- Open the app and create your account. With **Cloudron SSO (OIDC)** enabled, sign in with your Cloudron
  account. With SSO disabled, sign-in is **passwordless local-email** — anyone who can reach the app can
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

Project homepage: https://www.lmnr.ai — Docs: https://docs.lmnr.ai
