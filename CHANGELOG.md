[0.1.4]
* Hardened backups: the bundled ClickHouse and Quickwit stores now live on dedicated volumes and are captured
  by a consistent logical dump/restore, so automatic backups can't race live writes or abort mid-run.
* Right-sized memory: 4 GiB default with an internal ClickHouse cap, measured for small/personal installs.
* Trace ingestion is OTLP/HTTP only (protobuf or JSON) — simpler and a smaller attack surface than gRPC.
* Ingestion is traces-only; the endpoint requires TLS (send OTLP/HTTP over `https`, not cleartext).
* Added a pre-publish secret-scan release gate.

[0.1.0]
* Initial release: Laminar 0.2.0 (open-source LITE profile) packaged for Cloudron.
* Next.js dashboard (Better Auth) + Rust app-server (OTLP/HTTP + REST ingestion) + bundled ClickHouse and Quickwit; PostgreSQL via the Cloudron addon.
* App-native OIDC single sign-on through the Cloudron oidc addon; passwordless local-email sign-in when SSO is off.
* Trace ingestion on a dedicated subdomain, secured by per-project API keys.
* Data-loss-critical encryption key generated once and preserved across updates and restores.
