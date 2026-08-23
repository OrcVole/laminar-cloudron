# Packaging notes (verified-vs-assumed log, newest first)

Anonymized. Box-specific detail lives in the maintainer's local notes, not here.

## Multi-app OTLP dogfooding — how wiring real clients improved this package

After the first production install, the ingest subdomain was wired to **real third-party OTLP producers**
(an AI-native LLM/MCP gateway, and a self-hosted LLM app platform) instead of only synthetic `curl` tests.
Pointing genuine exporters at the endpoint both **validated core packaging decisions** and **surfaced
concrete doc fixes** — the kind of feedback you only get from real clients.

**Validated (decisions that held up under real clients):**

- **Public, API-key-only ingest subdomain (no SSO).** SDKs and collectors cannot complete an interactive
  login, so the separate public ingest host protected by a per-project bearer key is *exactly* what let
  external apps send traces at all. Real-world confirmation of the auth topology.
- **HTTP-only OTLP (ADR 0008).** Every real producer used **OTLP/HTTP+protobuf**; not one needed gRPC.
  Dropping the `tcpPorts` gRPC exposure cost nothing and simplified the surface — confirmed, not assumed.
- **`Authorization: Bearer <project_api_key>`.** Accepted verbatim by both a Rust exporter and a Python
  exporter. The credential contract in POSTINSTALL is correct.
- **Ingest robustness through the platform proxy.** Verified on-box that the proxied `/v1/traces` correctly
  handles gzip request bodies (auto-decompressed), HTTP/2, raw protobuf, and JSON — replaying a real
  client's exact captured payload returned 200 and stored the span. The HTTP ingest path is solid.

**Surfaced (concrete improvement now in the package docs):**

- **"The endpoint is HTTPS-only; your exporter must speak TLS" guidance.** One gateway's OTLP export mode
  sends **plaintext HTTP to the `https` endpoint** (confirmed by capturing the bytes: no TLS handshake, the
  edge returns `400 — plain HTTP request was sent to HTTPS port`, and the request never reaches the app).
  That's *correct* edge behaviour — an HTTPS port must not accept cleartext — so there's no proxy change to
  make; POSTINSTALL now tells operators the exporter must do real TLS, and to use an **OTLP collector** as a
  TLS relay for plaintext-only clients. Learned only by trying a real client.
- **"Traces-only" clarification.** A producer that also exports metrics POSTs to `/v1/metrics`, which
  Laminar 404s. POSTINSTALL now states ingestion is traces-only and that stray metric POSTs are harmless.

**Edge exonerated (a debugging win for free):** the ingest edge was tested to accept, and route through to
the app-server, every standard shape — HTTP/1.1 and HTTP/2, protobuf and JSON, gzip-encoded, with correct,
port-bearing, or bogus SNI (all → a proper app-level response). No legitimate TLS exporter is dropped. The
one failing producer was **not** speaking TLS at all — a client-side limitation, isolated with certainty
rather than guessed. Dogfooding turned "does our ingest interoperate with real tools?" into a tested yes and
gave a clean, evidence-backed fault boundary for support questions.
