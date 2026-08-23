# 8. HTTP-only OTLP ingestion (drop OTLP/gRPC)

Date: 2026-06-30

## Status

Accepted (operator-confirmed). The shipping topology.

## Context

Laminar's app-server exposes OTLP ingestion over both HTTP/protobuf (`:8000`, behind the manifest
`httpPorts` ingest subdomain) and gRPC (`:8001`). Publishing gRPC on Cloudron requires a `tcpPorts` block
(Cloudron does not terminate TLS for raw TCP) **plus** a DNS-only (grey-cloud) record on the ingest host —
a proxied (orange-cloud) Cloudflare record will not pass raw gRPC (field-guide gotcha #27).

OTLP/HTTP ingestion was proven on the box: `POST https://<ingest-subdomain>/v1/traces` (project
key, OTLP/HTTP+JSON) → HTTP 200 → span in ClickHouse → read back via the public SQL API.

## Decision

**Ship HTTP-only.** The manifest exposes ONLY the `httpPorts` ingest subdomain (app-server `:8000`); it
carries **no `tcpPorts` block** and gRPC `:8001` is never published. The Phase-7 backup/restore gate
therefore certifies the FINAL shipping topology, not a gRPC superset.

## Rationale

- Both real consumers are HTTP: the **Laminar SDK** self-host default is HTTP, and the operator's
  **agentgateway → Laminar** route is OTLP/HTTP+protobuf over TLS (the integration headline — gotcha #38).
  gRPC has **zero proven consumer** here.
- gRPC would add a `tcpPorts` raw-TCP exposure, an operator-managed grey-cloud DNS record, and gotcha #27
  fragility — for no benefit.

## Consequences

- No `tcpPorts`, no grey-cloud DNS record. Simpler, smaller attack surface.
- If a future consumer genuinely needs OTLP/gRPC: re-add `tcpPorts: { containerPort: 8001 }` with a
  DNS-only record (the Qdrant pattern) and re-run the backup/restore gate. Until then the supported path is
  OTLP/HTTP to the ingest subdomain (documented in POSTINSTALL + the announcement).
