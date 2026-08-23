# 10. Deploying changes to a manually-installed app — `update --image` doesn't redeploy; reinstall does

Date: 2026-06-30

## Status

Accepted. Learned deploying ADR 0007's triplet + the snapshot-backup fix to the throwaway. The headline
finding (update --image is inert here) was **verified, not assumed** — including a *refuted* version-bump
hypothesis. Two hazards: a deployment hazard (a–d) and a portability hazard (e). Both matter for the Langfuse
port.

## Context

The app is installed by explicit image — `cloudron install --image ghcr.io/orcvole/laminar-cloudron@sha256:…`
(a "manually-specified" image; cloudron labels it `(built local)` on both install and update — benign, ruled
out as a cause). The manifest is **not embedded in the image** (the Dockerfile never `COPY`s
`CloudronManifest.json`); cloudron reads it from the local package dir at install time and stores it.

## (a) `cloudron update --image` does NOT redeploy the image (verified)

`cloudron update --app <app> --image <new digest>` printed `App is updated` (exit 0) but the running
container **kept the previous image's filesystem** — proven by hashing `/app/code/conf/backup-clickhouse.sh`
*inside* the running container before/after: the hash did not change (stayed old `4b8209fb…`, never became
the new `76a0bc14…`). No `Downloading image` line appeared, so the box never fetched/swapped the new image.

## (b) A version bump does NOT fix it (refuted), and the cause is the missing pull — not yet isolated

The tempting theory — "update --image no-ops because the manifest `version` is unchanged" — was tested and
**refuted**: bumping the local manifest `version` 0.1.0 → 0.1.1 and re-running `update --image <new digest>`
*still* didn't swap the script, *still* emitted no `Downloading image`, and the app's reported version even
stayed `@0.1.0`. So the **manifest version is not the trigger** — do not record "bump the version and
update --image will work" (it doesn't), nor "an identical manifest version short-circuits the update" (also
unsupported by the evidence). The one thing the evidence pins down: `update --image` **did not trigger a
box-side registry pull** (no `Downloading image`), so the box kept the **cached** image — independent of
manifest/version. **Why** the pull didn't fire is **not yet isolated** — image-ref resolution or a box-side
tag/digest cache are the suspects. Recorded as **open, not settled**: one confidently-wrong entry already had
to be corrected this turn, and a second guess dressed as a root cause is exactly what to avoid. What *is*
settled is the mechanism: reinstall-by-digest forces a real pull (§c) and is the reliable path.

## (c) `cloudron install` DOES deploy the exact image — reinstall is the reliable path

A fresh `cloudron install --image <digest>` prints `Downloading image` and deploys exactly that image
(verified: the baseline install got the old script; the reinstall got the new `76a0bc14…` and version
`@0.1.1`). Since `cloudron install --location <existing>` 409s on an in-use location, deploying a new image
to an existing app means **uninstall + reinstall** — which **wipes the Postgres addon DB and the
persistentDir** (so an AEAD reseed too; capture the baseline fresh after every reinstall). For this app,
*every* image change — even an image-only script edit — needs a reinstall, not `update --image`.

## (d) The publish channel is version-keyed regardless

Published packages update via the **versions-url channel** (`CloudronVersions.json`), which IS keyed on the
manifest `version`. So an image-only fix that does not bump the package `version` ships **nothing** to
published users. The snapshot-backup fix therefore ships as **0.1.1**, not under 0.1.0 (which would have
denoted the broken script). Bumping the package `version` on every shipped change is mandatory.

## (e) Portability: greenfield-safe here, but a published package needs a migration

Introducing `/var/lib/clickhouse` (ADR 0007) is safe for **Laminar** because it is **greenfield** — the
first published version already carries the persistentDir, so no installed instance ever had ClickHouse under
the old `/app/data` path. Nothing to migrate. (`start.sh` still defensively drops any stale
`/app/data/clickhouse`.)

Any **already-published** package that ports this triplet (Langfuse) MUST NOT simply add the persistentDir.
On update, Cloudron provisions a fresh empty `/var/lib/clickhouse`, the old store stays under `/app/data`
(still in the file-walk, still racing #46), and the app reads the **empty** persistentDir — so existing
users' ClickHouse data is **orphaned and effectively lost**. The port MUST add a **guarded, one-time,
in-place migration** in `start.sh`: detect CH data at the old `/app/data` path **and** an empty new
persistentDir → move it on first boot of the new version, then proceed.

```bash
# Langfuse port-back sketch (NOT needed in greenfield Laminar):
OLD=/app/data/clickhouse NEW=/var/lib/clickhouse
if [ -d "${OLD}/store" ] && [ ! -d "${NEW}/store" ] && [ ! -d "${NEW}/metadata" ]; then
  log "migrating ClickHouse store ${OLD} -> persistentDir ${NEW} (one-time)"
  mkdir -p "${NEW}"; mv "${OLD}"/* "${NEW}"/ && rmdir "${OLD}" 2>/dev/null || true
fi
```

## Decision

- Deploy image changes to the throwaway by **uninstall + reinstall by digest** (`update --image` is inert
  here); accept the DB/persistentDir wipe + AEAD reseed, and re-capture the AEAD baseline each time.
- **Bump the package `version` on every shipped change** (publish is version-keyed; the fix ships as 0.1.1).
- The **dump/restore recipe (ADR 0007) ports verbatim; the persistentDirs move does NOT** — it needs the
  one-time in-place migration above on any package with installed users.

## Consequences

The dev loop is reinstall-based (slower, wipes data — relevant when staging the under-load gate). The
Langfuse port-back (ADR 0006) gets an explicit migration sub-task. Field-guide entries: (1) "`update --image`
does not redeploy a manually-installed (`--image`) app — not even with a version bump; reinstall by digest";
(2) "package `version` must bump for the versions-url channel to ship it"; (3) "persistentDirs is a manifest
change → reinstall/versions-url, and data-loss-prone to introduce on an installed app without an in-place
migration."
