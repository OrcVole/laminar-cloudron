# AGENTS.md — Laminar Cloudron package working contract

The settled-decisions record ("golden rules") for packaging **Laminar** (`lmnr`, open-source, Apache-2.0)
as a Cloudron community app. Read this before changing anything. Do **not** relitigate these without a
concrete reason found on a running box. **The box is the authority, not the docs.**

## What this package is

A single Cloudron app running the OSS **Laminar v0.2.0** LLM/agent-observability stack (the upstream
**LITE** profile) as a self-contained system. Topology — **four processes under Supervisor**, each
logging to stdout:

| Process | Role | Port(s) (localhost unless noted) |
|---------|------|----------------------------------|
| `clickhouse-server` | OLAP store for spans/traces (**required**) | 8123 HTTP / 9000 native |
| `quickwit` | Full-text span search (**optional** upstream — bundled for search) | 7280 REST / 7281 OTLP-gRPC ingest |
| `app-server` (Rust) | Ingestion (OTLP) + REST API + realtime SSE | 8000 REST/OTLP-HTTP, 8001 gRPC, **8002 SSE** |
| `frontend` (Next.js) | Dashboard UI + Better Auth login; runs Drizzle (PG) **and** ClickHouse migrations on boot | **5667 — the manifest `httpPort`** |

Postgres comes from the **Cloudron `postgresql` addon**. **No Redis, no RabbitMQ, no object store** — in
LITE upstream falls back to in-process Moka (cache), TokioMpsc (queue), and MockStorage (S3). This is
**one bundled store fewer than Langfuse** (no MinIO) and **no `redis` addon**.

## Golden rules

1. **Conformance to the Cloudron contract first.** Adapt Laminar's *runtime environment* only; never
   patch Laminar itself.
2. **Pin EVERYTHING by digest** (base, both lmnr images / source tag, clickhouse, quickwit). Exactly
   **one ARG per upstream version** (`LAMINAR_VERSION=0.2.0`); the manifest mirrors it in `upstreamVersion`.
3. **Persisted state ONLY in `/app/data`.** Re-assert ownership and mode on **every** boot (restore drifts
   them). Keep the ClickHouse data path in ONE place — ADR 0007 repoints it to a `persistentDir` in Phase 7.
4. **Fail loud.** Never silently regenerate `AEAD_SECRET_KEY` or clobber operator config.
5. **Code and docs ship together.** ADRs in `docs/decisions/`; verified-vs-assumed log in
   `phase-notes/` (local) and `docs/PACKAGING-NOTES.md` (anonymized, newest first).
6. **`CMD`, never `ENTRYPOINT`** (ENTRYPOINT breaks Cloudron debug mode). `.dockerignore` as well as
   `.gitignore`.
7. **OSS only (Apache-2.0).** Build with **cargo default features** (NOT `signals` — it needs
   `lmnr-private` and won't compile in OSS). Never enable enterprise features (Signals, clustering,
   trace-chat agent, enterprise PII). `pii-redactor` is NOT bundled (optional ONNX service; future ADR).
8. **Anonymize before every push.** No test-box/private-mirror hostnames, no real emails, no tokens, no
   internal URLs in any **tracked** file. `example.com` placeholders in public docs. `test/secret-scan.sh`
   is the release gate. Box-specific notes stay gitignored (`phase-notes/`, the foundation doc).
9. **Git hygiene.** No AI co-authorship / tool-attribution trailers. Commit as the maintainer identity,
   set **repo-local**: `OrcVole <Most+github@OrcadianVole.com>` (the machine global is a placeholder —
   never use it).

## Locked decisions (Phase 0, operator-confirmed 2026-06-30)

- **Manifest id:** `io.github.orcvole.laminar` (holds the `io.github.orcvole.*` line; the repo's
  `-cloudron` suffix does not enter the id). `author`/`packagerName` = `OrcVole`,
  `contactEmail` = `Most+github@OrcadianVole.com`.
- **Registry:** GHCR `ghcr.io/orcvole/laminar-cloudron` (the `<app>-cloudron` convention, matching the
  repo + `langfuse-cloudron`), pushed **public** (box pulls without creds). Tag scheme
  `:<LAMINAR_VERSION>-<pkg-rev>` — first build `:0.2.0-1`.
- **Repos:** GitHub `OrcVole/laminar-cloudron` (canonical public repo). A private Forgejo mirror also
  exists; its URL is maintainer-local and intentionally not recorded in tracked files.
- **memoryLimit:** **measure, don't guess** (gotcha #41). Manifest carries a placeholder (6 GiB); install
  the testing instance with a *generous* `--memory-limit` (e.g. 16G) so OOM never masks behaviour, measure
  warmup-peak + steady-state-under-trace-load (`memory.current`/cgroup), then set the shipped floor.
  Bundled stores get **absolute** memory caps (not ratios — unverified whether bundled CH reads cgroup vs
  host RAM): ClickHouse `<max_server_memory_usage>` in `config.d/cloudron.xml`; bound Quickwit similarly.
- **gRPC ingest:** **test BOTH** OTLP/HTTP (`httpPorts` → app-server :8000) and OTLP/gRPC (`tcpPorts` →
  :8001, grey-cloud DNS) in dev (Phase 6), then decide whether HTTP-only is the cleaner ship. v0.1.0 first
  install ships HTTP-only; gRPC `tcpPorts` is added as a Phase-6 manifest variant.
- **Health:** `healthCheckPath = /sign-in` (frontend has no health route; `/` 302→`/sign-in`, `/sign-in`
  is 200 unauth and not in the middleware matcher). Fallback if it proves flaky on first-boot migration:
  the nginx immediate-health shim (field-guide gotchas #39–40).

## Pinned upstream (to verify by `skopeo inspect` / source tag in Phase 2)

- `cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c`
- Laminar source **git tag `v0.2.0`** (commit `f9f4954`) — Apache-2.0.
  - app-server: Rust **edition 2024**, upstream builds on `rust:1.95-slim-trixie` (glibc 2.41) →
    **source-build on `cloudron/base`** (glibc 2.39) so the binary links the base. cargo-chef caching.
  - frontend: `node:26-alpine` (musl), `next build` standalone, **only native addon = `sharp` (musl)**.
- ClickHouse **25.12** (`@sha256:8a790dd3468db22b1d4e7b18a176f378ff5ff6053b9c48dd4ea1fa71a24c5ba6`).
  **NOT 25.3** — 25.3 lacks `dateTimeToUUIDv7`, so CH migration `7_versioned-datasets.sql` fails on first
  boot (confirmed in the boot smoke). 25.12 is still **pre-26.3** (upstream warns 26.3 breaks `spans_v0`)
  and is the version the upstream CLAUDE.md targets.
- Quickwit **v0.8.2** (`quickwit/quickwit:v0.8.2`), pin by digest. Spans index `spans_v2`.

## Build shapes (HYPOTHESIS — prove on the box; ADR 0003)

- **app-server (Rust):** builder stage on `cloudron/base` installs Rust 1.95 (rustup), deps
  `build-essential pkg-config libssl-dev protobuf-compiler libfontconfig1-dev libclang-dev`, `cargo-chef`,
  `cargo build --release --all` (default features). Runtime stage copies the `app-server` binary **+ its
  `data/` dir** (`adjectives.txt`/`nouns.txt`/`logo.png` — name generation, cwd-relative `./data`) onto the
  base; runtime libs `libssl3 libfontconfig1 ca-certificates`. WORKDIR-equivalent: run from
  `/app/code/app-server` so `./data` resolves.
- **frontend (Next.js, musl-in-place):** copy the upstream `ghcr.io/lmnr-ai/frontend` standalone tree
  (`server.js`, `.next/standalone`→`/app/code/frontend`, `.next/static`, `public`, **`lib/db/migrations`
  - `lib/clickhouse/migrations`**) AND the upstream **musl Node 26** + loader + lib closure (incl. whatever
  `sharp`'s musl `.node` links — resolve with `ldd` at build) into `/opt/musl/lib` (registered in
  `/etc/ld-musl-x86_64.path`), installed as `node-musl`. Run `node-musl server.js` from
  `/app/code/frontend`. **No Prisma** here — that's the one Langfuse complication Laminar skips.
  Build gates: `node-musl --version`; `app-server --help`/`--version`; `ldd` clean on each.

## Secrets (first-run-only, idempotent, `/app/data/.secrets`, mode 0600, re-assert every boot)

- **`AEAD_SECRET_KEY`** — **DATA-LOSS-CRITICAL.** Exactly **64 hex chars** (`openssl rand -hex 32`),
  consumed as `Buffer.from(hex,'hex')` → XChaCha20-Poly1305 (libsodium) to encrypt stored API keys +
  provider secrets. Shared by app-server ingest crypto (`data_plane/crypto.rs`) and frontend
  (`lib/crypto.ts`). Generate **once**, never reseed, guard `^[0-9a-f]{64}$` → FATAL; prove
  **byte-identical (sha256)** across update **and** restore.
- Seed-once (stable, not data-loss-critical): `NEXTAUTH_SECRET` (= `BETTER_AUTH_SECRET`),
  `SHARED_SECRET_TOKEN` (frontend↔app-server; app-server v0.2.0 doesn't read it but the frontend may —
  set on both), `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_RO_PASSWORD`.

## Env mapping (translate on EVERY boot; verified against upstream compose + source)

| Laminar env | Source / value | Notes |
|---|---|---|
| `ENVIRONMENT` | `LITE` (forced) | **mandatory** — app-server panics if unset; enables auto-migrate + email-auth fallback |
| `DATABASE_URL` | `CLOUDRON_POSTGRESQL_URL` | both processes |
| `AUTH_KEYCLOAK_ISSUER` | `CLOUDRON_OIDC_ISSUER` | OIDC discovery base; Better Auth appends `/.well-known/openid-configuration` |
| `AUTH_KEYCLOAK_ID` | `CLOUDRON_OIDC_CLIENT_ID` | provider id `keycloak` |
| `AUTH_KEYCLOAK_SECRET` | `CLOUDRON_OIDC_CLIENT_SECRET` | (all three needed to enable Keycloak) |
| `NEXTAUTH_URL`,`BETTER_AUTH_URL`,`NEXT_PUBLIC_URL` | `CLOUDRON_APP_ORIGIN` | external https origin; AUTH_URL drives redirect host |
| `NEXTAUTH_SECRET` (=`BETTER_AUTH_SECRET`) | seeded once | session signing |
| `AEAD_SECRET_KEY` | seeded once, **64-hex** | **data-loss-critical**; byte-identical across update+restore |
| `SHARED_SECRET_TOKEN` | seeded once | set on both processes |
| `CLICKHOUSE_URL` | `http://localhost:8123` | bundled |
| `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD` | `laminar` / seeded | rw user (access_management) |
| `CLICKHOUSE_RO_USER` / `CLICKHOUSE_RO_PASSWORD` | `laminar_ro` / seeded | **set BOTH** or the SQL/AI read path silently disables |
| `QUICKWIT_SEARCH_URL` / `QUICKWIT_INGEST_URL` | `http://localhost:7280` / `:7281` | bundled |
| `QUICKWIT_SPANS_INDEX_ID` | `spans_v2` | per upstream |
| `BACKEND_URL` / `BACKEND_RT_URL` | `http://localhost:8000` / `:8002` | frontend → app-server (server-side ⇒ 8002 stays internal) |
| `PORT` (frontend) | `5667`; `HOSTNAME=0.0.0.0` | gotcha #4 |
| `PORT` / `GRPC_PORT` / `CONSUMER_PORT` (app-server) | `8000` / `8001` / `8002` | |
| `FORCE_RUN_MIGRATIONS` | `true` | belt-and-braces (LITE already auto-migrates) |
| `LAMINAR_TELEMETRY_DISABLED` / `NEXT_TELEMETRY_DISABLED` | `true` / `1` | no phone-home |
| `LLM_PROVIDER`/`LLM_API_KEY`/`OPENAI_API_KEY`/`AWS_*` | operator-optional | chat-with-trace / SQL-with-AI only; never required |

## Auth topology (the departure from the usual proxyAuth pattern)

Laminar owns its own login (**Better Auth**, genericOAuth). **No `proxyAuth` in front of anything.** Use
`optionalSso: true` + the **`oidc`** addon wired to the `keycloak` generic provider (`AUTH_KEYCLOAK_*`).
With no IdP configured, a **passwordless local-email** provider auto-enables (`Feature.EMAIL_AUTH` =
`!any(provider)` in LITE) — i.e. the instance is **open** unless SSO restricts it (document in POSTINSTALL).
**Ingestion (`POST /v1/traces`, public API) stays open at the network layer** on the ingest subdomain,
protected by per-project API keys — SDKs/collectors can't do interactive login.

## Health

`healthCheckPath: /sign-in` (liveness, 200 without auth). The frontend binds its port only after on-boot
migrations complete, so first-boot grace matters (gotcha #39); if a slow CH migration trips it, front 5667
with the nginx immediate-health shim.

## ClickHouse backup (ADR 0007 — Phase 7, BEFORE first publish)

Raw CH files under `/app/data` + Cloudron's live rsync backup can **abort the whole-server backup** (a
`tmp_merge_*` vanishing mid-walk). Quiesce is impossible (`backupCommand` runs in a temp container, no live
CH). Fix = the **9.1 triplet**: `persistentDirs` (move the store out of the file-walk → race structurally
gone) + `backupCommand` (logical dump into `/app/data`) + `restoreCommand`. **Settle two box-authority
unknowns first** (is the temp container quiesced? can `clickhouse-local`/server run in it?) and **study
Plausible's Cloudron package** + watch `OrcVole/langfuse-cloudron` for its triplet commits. Because Laminar
hasn't shipped yet, the triplet lands in **Phase 7 before Phase 9/10** — the first public release has it.
Apply the same scrutiny to **Quickwit** (index may be rebuildable/optional ⇒ candidate for a non-backed-up
`persistentDir`).

## Future-compat

One `LAMINAR_VERSION` ARG is the only bump point; point releases auto-migrate on boot. FULL/RabbitMQ is a
future option if write volume ever demands a broker (no Cloudron addon → would bundle LavinMQ). pii-redactor
and Signals are enterprise/optional — out of scope, leave ADR stubs.
