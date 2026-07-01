#!/bin/bash
# secret-scan.sh — pre-publish secret + anonymity release gate for io.github.orcvole.laminar.
#
# Scans TWO surfaces and exits non-zero on ANY hit:
#   1. the publishable repo file set — what a `git push` would expose (tracked ∪ untracked-non-ignored), and
#   2. the built container image filesystem — the artifact already public on GHCR.
# Run before every publish, and before flipping any image to public.
#
# Why two surfaces: the .dockerignore should keep secrets out of the build context, but "should" is a
# claim; scanning the actual image is the proof. The image is what the world pulls.
#
# Box-/identity-/session-specific strings live in the GITIGNORED .anonymize-list, so this published
# script never itself leaks them (the mistake the naive "patterns inline in the tracked script" approach
# makes). Only generic credential SHAPES are inlined here. Exact infra tokens are read at runtime from
# ../Passing (outside the repo) into a scratch file and never written into the repo tree.
#
# Usage: test/secret-scan.sh [IMAGE]
#   IMAGE defaults to $LAMINAR_SCAN_IMAGE, else the dockerImage in CloudronManifest.json, else repo-only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO="$PWD"
SELF="test/secret-scan.sh"

IMAGE="${1:-${LAMINAR_SCAN_IMAGE:-}}"
if [[ -z "$IMAGE" ]]; then
  IMAGE="$(grep -oE '"dockerImage"[[:space:]]*:[[:space:]]*"[^"]+"' CloudronManifest.json 2>/dev/null \
           | grep -oE '"[^"]+"$' | tr -d '"')"
fi
CRI="$(command -v podman || command -v docker || true)"   # build host is rootless podman; docker fallback

SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
ANON="$SCRATCH/anon.ere"     # box/identity/session ERE patterns (from .anonymize-list)
SHAPE="$SCRATCH/shape.ere"   # generic credential-shape ERE patterns (inlined below)
FIXED="$SCRATCH/fixed.txt"   # exact infra-token strings pulled from ../Passing (fixed-string match)

# --- generic credential shapes (safe to publish: contain no box-specifics) ---
cat > "$SHAPE" <<'ERE'
ghp_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
gho_[A-Za-z0-9]{20,}
ghs_[A-Za-z0-9]{20,}
ghr_[A-Za-z0-9]{20,}
glpat-[A-Za-z0-9_-]{20,}
xox[baprs]-[A-Za-z0-9-]{10,}
AKIA[0-9A-Z]{16}
ASIA[0-9A-Z]{16}
AIza[0-9A-Za-z_-]{35}
sk-ant-[A-Za-z0-9_-]{20,}
sk-proj-[A-Za-z0-9_-]{20,}
-----BEGIN [A-Z ]*PRIVATE KEY-----
ERE

# --- box/identity/session patterns from the gitignored denylist ---
if [[ -f .anonymize-list ]]; then
  grep -vE '^[[:space:]]*(#|$)' .anonymize-list > "$ANON"
else
  : > "$ANON"
  echo "WARN: .anonymize-list absent — box/identity/session strings NOT scanned (shapes only)."
fi

# --- exact infra tokens (live OUTSIDE the repo); extracted to scratch, never committed ---
PASSING="$REPO/../Passing"
if [[ -d "$PASSING" ]]; then
  grep -rhoE '[A-Za-z0-9_+./=-]{24,}' "$PASSING" 2>/dev/null | sort -u > "$FIXED" || true
else
  : > "$FIXED"
fi
sed -i '/^[[:space:]]*$/d' "$ANON" "$SHAPE" "$FIXED" 2>/dev/null   # no blank lines (would match everything)

echo "patterns: $(wc -l < "$ANON") box/identity/session · $(wc -l < "$SHAPE") shapes · $(wc -l < "$FIXED") infra-tokens"

fail=0
emit() {  # $1=tag  $2=grep-output
  [[ -z "${2:-}" ]] && return 0
  printf '%s\n' "$2" | sed "s/^/  [$1] /"
  fail=1
}

echo "=== REPO scan — publishable file set ==="
mapfile -t FILES < <( { git ls-files; git status --short --untracked-files=all 2>/dev/null | sed -n 's/^?? //p'; } \
                      | sort -u | grep -vx "$SELF" )
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "  (no publishable files found)"
else
  echo "  ${#FILES[@]} files"
  [[ -s "$ANON"  ]] && emit anon  "$(grep -IEnHf "$ANON"  "${FILES[@]}" 2>/dev/null)"
  [[ -s "$SHAPE" ]] && emit shape "$(grep -IEnHf "$SHAPE" "${FILES[@]}" 2>/dev/null)"
  [[ -s "$FIXED" ]] && emit token "$(grep -IFnHf "$FIXED" "${FILES[@]}" 2>/dev/null)"
fi

echo "=== IMAGE scan — ${IMAGE:-<none>} ==="
if   [[ -z "$IMAGE" ]]; then echo "  (no image specified; skipped — pass one as \$1 or set LAMINAR_SCAN_IMAGE)"
elif [[ -z "$CRI"   ]]; then echo "  (no podman/docker found; skipped)"
elif ! "$CRI" image exists "$IMAGE" 2>/dev/null && ! "$CRI" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "  ($IMAGE not present locally; skipped — pull it to scan)"
else
  # grep INSIDE the image; patterns arrive on stdin (-f -). node_modules/.git pruned (upstream npm noise).
  img() {  # $1=E|F  $2=patternfile  $3..=dirs
    local mode="$1" pf="$2"; shift 2
    [[ -s "$pf" ]] || return 0
    "$CRI" run --rm -i --user 0 --entrypoint /bin/bash "$IMAGE" \
      -c "grep -rIn${mode}H --exclude-dir=node_modules --exclude-dir=.git -f - $* 2>/dev/null" < "$pf"
  }
  CRIT_DIRS="/app /etc /root /home /usr/local /opt"   # scan broadly
  emit anon  "$(img E "$ANON"  $CRIT_DIRS)"
  emit token "$(img F "$FIXED" $CRIT_DIRS)"
  # Generic credential shapes across the same surface.
  shp="$(img E "$SHAPE" $CRIT_DIRS)"
  # cloudron/base:5.0.0 ships 3 inert SSH host keys (no sshd runs in the app; the Dockerfile never touches
  # ssh). Allow ONLY those exact files, PINNED BY PATH + sha256 — NOT a glob. A new key type, an extra key,
  # or any byte-change fails loudly as an unpinned finding (a `ssh_host_*_key` glob would silently pass a
  # real future leak). Hashes are cloudron/base:5.0.0's, verified byte-identical in image 0.2.0-7.
  declare -A PINNED_SSH=(
    [/etc/ssh/ssh_host_ecdsa_key]=677458f83d985da3fd7cdd208e90e4eac09da5be205425a5f96a6242dc985c33
    [/etc/ssh/ssh_host_ed25519_key]=0c575ce8d9ba487b05cc473fad4b0650fb950181028e6ac19796f86f56f22a7a
    [/etc/ssh/ssh_host_rsa_key]=ae0ea8087e90baf138d277ca52b6cf47b5010adc0e5bd84236713eee1b85de85
  )
  ssh_listing="$("$CRI" run --rm --user 0 --entrypoint /bin/bash "$IMAGE" \
                  -c 'for f in /etc/ssh/ssh_host_*_key; do [ -e "$f" ] && sha256sum "$f"; done' 2>/dev/null)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    h="${line%% *}"; f="${line##* }"
    if [[ "${PINNED_SSH[$f]:-}" == "$h" ]]; then
      echo "  (pinned-ok: $f == cloudron/base:5.0.0 inert host key)"
      shp="$(printf '%s\n' "$shp" | grep -vF "$f:" || true)"   # drop ONLY this verified exact path
    else
      emit ssh-key "$f sha256=$h is NOT a pinned cloudron/base host key (unexpected/changed → treat as a leak)"
    fi
  done <<< "$ssh_listing"
  emit shape "$shp"
fi

echo "==================================================="
if [[ $fail -ne 0 ]]; then
  echo "secret-scan FAILED — anonymize / rebuild before publish (see hits above)."
  exit 1
fi
echo "secret-scan OK — no box-specifics, identities, session-secrets, or credential shapes found."
