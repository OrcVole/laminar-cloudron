# syntax=docker/dockerfile:1
#
# Laminar (lmnr) for Cloudron — upstream LITE profile, four supervised processes on cloudron/base.
# Architecture + rationale: AGENTS.md and docs/decisions/. Pin everything by digest; one ARG = the
# single source of the upstream version. CMD, never ENTRYPOINT.
#
# Build shapes (ADR 0003):
#   - app-server (Rust, edition 2024): SOURCE-BUILT on cloudron/base. The prebuilt upstream image is
#     debian:trixie-slim (glibc 2.41) and would NOT have linked on the old 5.x base (glibc 2.39; base 6 has 2.43), so we compile here
#     with cargo default features (NOT `signals` — it needs lmnr-private and won't build in OSS).
#   - frontend (Next.js standalone): MUSL-IN-PLACE. The upstream image is node:26-alpine (musl); we run
#     its musl Node + standalone tree UNCHANGED on the glibc base via an isolated musl loader pointed at
#     /opt/musl/lib only. No Prisma here (Laminar uses Drizzle) — the one Langfuse complication we skip.
#     The frontend's only native addon is `sharp` (musl), self-contained in node_modules; musl-in-place
#     keeps it on its native runtime.
#   - clickhouse + quickwit: bundled binaries copied from pinned upstream images, bound to localhost.

ARG LAMINAR_VERSION=0.3.2
# Rust: the version upstream's 0.3.2 app-server/Dockerfile builds on (rust:1.96-slim-trixie).
ARG RUST_VERSION=1.96.0

# ----- pinned upstream sources (digests resolved 2026-09-14; frontend and quickwit 2026-10-22) -------------------------------------
FROM ghcr.io/lmnr-ai/frontend:v0.3.2@sha256:b2e3f7875f28b9794f755a373d80d784dd2044b9f9666a3d8e6ccc8765bf7960                            AS frontend
# 25.12 (not 25.3): Laminar's CH migrations need dateTimeToUUIDv7 (absent in 25.3); still pre-26.3, which
# upstream warns breaks the spans_v0 view. 25.12 is the version the upstream CLAUDE.md targets.
FROM docker.io/clickhouse/clickhouse-server:25.12@sha256:8a790dd3468db22b1d4e7b18a176f378ff5ff6053b9c48dd4ea1fa71a24c5ba6              AS clickhouse
FROM docker.io/quickwit/quickwit:v0.9.1@sha256:3e0f079eb57dd5563f36a457e9a7a2963ff882316d6c77e3180ac3c59767a68f                        AS quickwit

# =================================================================================================
# app-server builder — compile the Rust binary on cloudron/base so it links the base's glibc 2.43.
# =================================================================================================
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee AS app-server-builder
ARG LAMINAR_VERSION
ARG RUST_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config libssl-dev protobuf-compiler libfontconfig1-dev libclang-dev \
      git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Rust via rustup (the base ships no Rust). Pin the toolchain to the upstream version.
ENV RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo PATH=/opt/rust/cargo/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain ${RUST_VERSION} --profile minimal
# Pinned source at the release tag.
RUN git clone --depth 1 --branch v${LAMINAR_VERSION} https://github.com/lmnr-ai/lmnr.git /src
WORKDIR /src/app-server
# Release build, cargo default features. Cache the registry/git/target across rebuilds (BuildKit).
RUN --mount=type=cache,target=/opt/rust/cargo/registry \
    --mount=type=cache,target=/opt/rust/cargo/git \
    --mount=type=cache,target=/src/app-server/target \
    cargo build --release --all \
 && mkdir -p /out \
 && cp target/release/app-server /out/app-server \
 && cp -a data /out/data
# Gate: the freshly built binary resolves on the base.
RUN ldd /out/app-server | grep -qi 'not found' && { echo 'FATAL: app-server unresolved libs'; exit 1; } || true

# =================================================================================================
# Final image
# =================================================================================================
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee
ARG LAMINAR_VERSION
ENV LAMINAR_VERSION=${LAMINAR_VERSION}

# Runtime libs for the bundled glibc binaries (app-server: reqwest native-tls -> libssl3; fontconfig for
# the name/avatar generator. quickwit/clickhouse link libssl3 too). base already ships curl + ca-certificates.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libssl3 libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

# -------------------------------------------------------------------------------------------------
# 1. Isolated musl userland for the frontend. node-musl is the ONLY musl binary in the image; its ELF
#    interpreter is /lib/ld-musl-x86_64.so.1 and the musl loader searches ONLY /opt/musl/lib, so the musl
#    and glibc worlds never collide. All copied from the pinned frontend image (auto version-matched).
# -------------------------------------------------------------------------------------------------
COPY --from=frontend /lib/ld-musl-x86_64.so.1 /lib/ld-musl-x86_64.so.1
RUN mkdir -p /opt/musl/lib
COPY --from=frontend /usr/lib/libstdc++.so.6 /opt/musl/lib/libstdc++.so.6
COPY --from=frontend /usr/lib/libgcc_s.so.1  /opt/musl/lib/libgcc_s.so.1
# libatomic: node 26 in the 0.3.x frontend image needs it (0.2.5 did not); found by the node-musl build gate.
COPY --from=frontend /usr/lib/libatomic.so.1 /opt/musl/lib/libatomic.so.1
RUN printf '/opt/musl/lib\n' > /etc/ld-musl-x86_64.path
COPY --from=frontend /usr/local/bin/node /usr/local/bin/node-musl

# -------------------------------------------------------------------------------------------------
# 2. The frontend standalone tree (server.js + .next + public + node_modules incl. the musl `sharp` +
#    lib/db/migrations + lib/clickhouse/migrations). Keep the upstream /app layout so the on-boot
#    migrators resolve their cwd-relative folders. Redirect Next's writable .next/cache to ephemeral
#    /run (the rootfs is read-only at runtime).
# -------------------------------------------------------------------------------------------------
COPY --from=frontend /app /app/code/frontend
RUN rm -rf /app/code/frontend/.next/cache \
 && ln -sfn /run/laminar/frontend-cache /app/code/frontend/.next/cache

# -------------------------------------------------------------------------------------------------
# 3. The app-server binary + its runtime data/ dir (adjectives/nouns/logo — cwd-relative ./data).
# -------------------------------------------------------------------------------------------------
COPY --from=app-server-builder /out/app-server /app/code/app-server/app-server
COPY --from=app-server-builder /out/data       /app/code/app-server/data

# Quickwit index configs: upstream's frontend image has shipped lib/quickwit/indexes itself since 0.3.1
# (PR #2537), so the COPY the package carried for 0.2.x and 0.3.0 is gone. The build gate in section 5
# fails the build if a future upstream image loses them (spans_v2 would then never exist: no search).

# -------------------------------------------------------------------------------------------------
# 4. Bundled ClickHouse (one multicall binary + its /etc tree) and Quickwit (single binary + config).
#    Strip the upstream config that binds 0.0.0.0/:: — we bind localhost (config.d/cloudron.xml).
# -------------------------------------------------------------------------------------------------
COPY --from=clickhouse /usr/bin/clickhouse    /usr/bin/clickhouse
COPY --from=clickhouse /etc/clickhouse-server /etc/clickhouse-server
RUN rm -f /etc/clickhouse-server/config.d/docker_related_config.xml \
 && ln -sf /usr/bin/clickhouse /usr/bin/clickhouse-server \
 && ln -sf /usr/bin/clickhouse /usr/bin/clickhouse-client \
 && ln -sf /usr/bin/clickhouse /usr/bin/clickhouse-local
COPY conf/clickhouse/config.d/cloudron.xml      /etc/clickhouse-server/config.d/cloudron.xml
COPY conf/clickhouse/users.d/cloudron-user.xml  /etc/clickhouse-server/users.d/cloudron-user.xml
COPY conf/clickhouse/users.d/lmnr-profiles.xml  /etc/clickhouse-server/users.d/lmnr-profiles.xml
COPY conf/clickhouse/backups.xml                /etc/clickhouse-server/backups.xml

# Quickwit: entrypoint is a bare `quickwit` on PATH -> /usr/local/bin/quickwit. QW_CONFIG points at the
# bundled default config (data dir + localhost bind are forced via env in start.sh). [VERIFY path on build]
COPY --from=quickwit /usr/local/bin/quickwit /usr/bin/quickwit
COPY --from=quickwit /quickwit/config        /quickwit/config

# -------------------------------------------------------------------------------------------------
# 5. Build gates — prove the assembled shape before shipping (deeper proofs run in the runtime smoke).
# -------------------------------------------------------------------------------------------------
RUN echo "== gate: musl node ==" && /usr/local/bin/node-musl --version
# app-server has no no-op flag (any invocation boots the full server, which needs CLICKHOUSE_URL/ENVIRONMENT/
# DATABASE_URL), so the BUILD gate is linkage-only; that it actually runs is proven in the runtime smoke.
RUN echo "== gate: app-server (linkage) ==" \
 && ldd /app/code/app-server/app-server 2>&1 | grep -qi 'not found' && { echo 'FATAL: app-server unresolved libs'; exit 1; } || echo 'app-server: ldd clean'
RUN echo "== gate: clickhouse ==" && /usr/bin/clickhouse --version \
 && { ldd /usr/bin/clickhouse 2>&1 | grep -qi 'not found' && { echo 'clickhouse unresolved libs'; exit 1; } || true; }
RUN echo "== gate: quickwit index definitions ==" \
 && for f in spans_v2 events signal_events; do test -s /app/code/frontend/lib/quickwit/indexes/$f.yaml || { echo "FATAL: $f.yaml missing from the upstream frontend image"; exit 1; }; done
RUN echo "== gate: quickwit ==" && /usr/bin/quickwit --version \
 && { ldd /usr/bin/quickwit 2>&1 | grep -qi 'not found' && { echo 'quickwit unresolved libs'; exit 1; } || true; }

# -------------------------------------------------------------------------------------------------
# 6. Packaging runtime: configs + supervisor + entrypoint.
# -------------------------------------------------------------------------------------------------
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 LAMINAR_TELEMETRY_DISABLED=true
COPY conf/             /app/code/conf/
COPY supervisor/       /etc/supervisor/
COPY start.sh          /app/code/start.sh
RUN chmod 0755 /app/code/start.sh /app/code/conf/*.sh

LABEL org.opencontainers.image.title="Laminar for Cloudron" \
      org.opencontainers.image.description="Open-source Laminar (LLM/agent observability) packaged for Cloudron" \
      org.opencontainers.image.source="https://github.com/OrcVole/laminar-cloudron" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="0.4.0"

CMD [ "/app/code/start.sh" ]
