`<upstream>0.2.5</upstream>

## Laminar

Laminar (`lmnr`) is an open-source observability platform for LLM applications and AI agents:
OpenTelemetry-native tracing, evaluations, datasets, labelling queues, full-text span search, and SQL
access to all of your trace data.

This package runs the self-hosted **open-source (Apache-2.0)** Laminar stack as a single Cloudron app — the
Next.js dashboard, the Rust ingestion/API server, and bundled ClickHouse (span analytics) and Quickwit
(full-text search) — with PostgreSQL provided by the Cloudron addon.

### What you get

- **OpenTelemetry-native trace ingestion** over OTLP/HTTP, plus the Laminar Python/TypeScript SDKs.
- **Trace & span explorer** with full-text search, a SQL editor, and dashboards.
- **Evaluations, datasets, and labelling queues** for building and grading eval pipelines.
- **Single sign-on** via the Cloudron OIDC addon (Better Auth), or passwordless local sign-in.
- All trace data stays on your own server; nothing is sent to a third party.

### Cloudron integration

Sign-in through Cloudron SSO (OIDC) when enabled; automatic backups of all state under `/app/data`;
one-click updates; per-project API keys for SDK and OpenTelemetry-collector ingestion on a dedicated
ingestion subdomain.
