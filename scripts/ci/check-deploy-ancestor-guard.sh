#!/usr/bin/env bash
# Deploy-lane ancestor guard (Wave 0 workstream W0-4; #2195 postmortem).
#
# Deploying main can REGRESS live production fixes whenever the LIVE deployed
# commit is not an ancestor of the release commit. The worst recorded instance:
# production was deployed from an uncommitted working tree with no source-commit
# stamp at all, so the live lineage is unrecorded and every later deploy
# silently rolled production back to the tag's lineage. This guard runs in
# `prepare-functions-deploy` BEFORE anything is deployed and fails CLOSED
# unless one of the following holds:
#
#   1. The live deployed `source.commit` (healthLive endpoint, served from the
#      existing `functions/src/sourceMetadata.ts` GIT_SHA metadata — no new
#      label mechanism) is an ANCESTOR of the release commit; or
#   2. A committed bootstrap receipt exists:
#      `config/deploy-regression-receipts/<date>.json` — a dated, signed,
#      EXPIRING acknowledgment that production is knowingly ahead of the
#      last stamped deploy. Expired or malformed receipts fail closed.
#
# THE FIRST TAG DEPLOY AFTER THIS LANDS WILL TRIP THE GUARD: production was
# deployed from an uncommitted working tree with no sha stamp. Land human
# queue item 11 (fresh stamped deploy re-anchors production) or keep the
# bootstrap receipt until then. Documented in
# docs/runbooks/functions-break-glass.md.
#
# Modes:
#   (default, CI)  Reads the live health endpoint and compares against
#                  $RELEASE_SHA (or --release-sha).
#   --live-sha <sha>   Inject the live commit (offline repro / self-tests).
#   --release-sha <sha>  Inject the release commit (overrides $RELEASE_SHA).
#   --receipts-dir <dir>  Override the receipts directory (self-tests).
#   --self-test    Offline positive+negative controls (temp git repo); exits 0/1.
#
# Env overrides: FUNCTIONS_HEALTH_LIVE_URL / FUNCTIONS_BASE_URL (same
# convention as scripts/ci/post-deploy-health-gate.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_DIR="${GUARD_REPO_DIR:-$ROOT}"
RECEIPTS_DIR="${GUARD_RECEIPTS_DIR:-$REPO_DIR/config/deploy-regression-receipts}"

# JSON probing without a hard node dependency (the prepare job has no
# setup-node): jq on the runner, python3 as the fallback.
json_get() {
  local file="$1" expr="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$expr" "$file" 2>/dev/null || echo ""
  else
    python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    data = data.get(key) if isinstance(data, dict) else None
    if data is None:
        break
print("" if data is None else data)
' "$file" "$expr" 2>/dev/null || echo ""
  fi
}

is_iso_date() {
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

receipt_valid() {
  local file="$1"
  local date reason ack expires
  date="$(json_get "$file" ".date")"
  reason="$(json_get "$file" ".reason")"
  ack="$(json_get "$file" ".acknowledgedBy")"
  expires="$(json_get "$file" ".expiresOn")"
  is_iso_date "$date" || return 1
  [[ -n "$(echo "$reason" | tr -d '[:space:]')" ]] || return 1
  [[ -n "$(echo "$ack" | tr -d ' ')" ]] || return 1
  is_iso_date "$expires" || return 1
  # Expired receipts fail closed: the bootstrap window must be re-acknowledged.
  [[ "$(date -j -f "%Y-%m-%d" "$expires" "+%s" 2>/dev/null || date -d "$expires" "+%s" 2>/dev/null)" -ge "$(date "+%s")" ]]
}

guard_fail() {
  echo "::error::ancestor-guard: $1" >&2
  exit 1
}

# ---------------- self-test ----------------
if [[ "${1:-}" == "--self-test" ]]; then
  SELFTEST_TMP="$(mktemp -d)"
  trap 'rm -rf "$SELFTEST_TMP"' EXIT
  export GUARD_REPO_DIR="$SELFTEST_TMP/repo"
  export GUARD_RECEIPTS_DIR="$SELFTEST_TMP/receipts"
  git init -q "$GUARD_REPO_DIR"
  git -C "$GUARD_REPO_DIR" config user.email t@t && git -C "$GUARD_REPO_DIR" config user.name t
  mkdir -p "$GUARD_REPO_DIR/config" "$GUARD_RECEIPTS_DIR"
  echo base > "$GUARD_REPO_DIR/config/base"
  git -C "$GUARD_REPO_DIR" add -A && git -C "$GUARD_REPO_DIR" commit -qm base
  LIVE_SHA="$(git -C "$GUARD_REPO_DIR" rev-parse HEAD)"
  echo more >> "$GUARD_REPO_DIR/config/base"
  git -C "$GUARD_REPO_DIR" add -A && git -C "$GUARD_REPO_DIR" commit -qm release
  RELEASE_SHA="$(git -C "$GUARD_REPO_DIR" rev-parse HEAD)"
  git -C "$GUARD_REPO_DIR" checkout -qb diverged "$LIVE_SHA"
  echo diverged > "$GUARD_REPO_DIR/config/base"
  git -C "$GUARD_REPO_DIR" add -A && git -C "$GUARD_REPO_DIR" commit -qm diverged
  DIVERGED_SHA="$(git -C "$GUARD_REPO_DIR" rev-parse HEAD)"

  script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  expect() { # <label> <expected-exit> <args...>
    local label="$1" want="$2"; shift 2
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "$got" == "$want" ]]; then
      echo "  PASS $label (exit $got)"
    else
      echo "  FAIL $label: expected exit $want, got $got" >&2
      exit 1
    fi
  }

  echo "Self-test: check-deploy-ancestor-guard.sh"
  expect "live commit is an ancestor of the release commit" 0 \
    bash "$script" --live-sha "$LIVE_SHA" --release-sha "$RELEASE_SHA" --receipts-dir "$GUARD_RECEIPTS_DIR"
  expect "diverged lineage fails closed" 1 \
    bash "$script" --live-sha "$DIVERGED_SHA" --release-sha "$RELEASE_SHA" --receipts-dir "$GUARD_RECEIPTS_DIR"
  expect "unknown live sha fails closed (the unstamp condition)" 1 \
    bash "$script" --live-sha "" --release-sha "$RELEASE_SHA" --receipts-dir "$GUARD_RECEIPTS_DIR"
  expect "live sha unknown to the repo fails closed" 1 \
    bash "$script" --live-sha "0000000000000000000000000000000000000000" --release-sha "$RELEASE_SHA" --receipts-dir "$GUARD_RECEIPTS_DIR"

  cat > "$GUARD_RECEIPTS_DIR/2026-09-02.json" <<'RECEIPT'
{"date": "2026-09-02", "reason": "bootstrap window", "acknowledgedBy": "test", "expiresOn": "2099-01-01"}
RECEIPT
  expect "diverged lineage + valid receipt passes (loudly)" 0 \
    bash "$script" --live-sha "$DIVERGED_SHA" --release-sha "$RELEASE_SHA" --receipts-dir "$GUARD_RECEIPTS_DIR"

  cat > "$GUARD_RECEIPTS_DIR/2026-09-02.json" <<'RECEIPT'
{"date": "2026-09-02", "reason": "expired window", "acknowledgedBy": "test", "expiresOn": "2026-01-01"}
RECEIPT
  expect "expired receipt fails closed" 1 \
    bash "$script" --live-sha "$DIVERGED_SHA" --release-sha "$RELEASE_SHA" --receipts-dir "$GUARD_RECEIPTS_DIR"

  echo "{not json" > "$GUARD_RECEIPTS_DIR/2026-09-02.json"
  expect "malformed receipt fails closed" 1 \
    bash "$script" --live-sha "$DIVERGED_SHA" --release-sha "$RELEASE_SHA" --receipts-dir "$GUARD_RECEIPTS_DIR"

  echo "PASS: ancestor guard self-test."
  exit 0
fi

# ---------------- CI mode ----------------
RELEASE_SHA="${RELEASE_SHA:-}"
LIVE_SHA="${LIVE_SHA:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live-sha) LIVE_SHA="$2"; shift 2 ;;
    --release-sha) RELEASE_SHA="$2"; shift 2 ;;
    --receipts-dir) RECEIPTS_DIR="$2"; shift 2 ;;
    *) echo "usage: $0 [--live-sha <sha>] [--release-sha <sha>] [--receipts-dir <dir>]" >&2; exit 2 ;;
  esac
done

[[ -n "$RELEASE_SHA" ]] || guard_fail "release commit is unknown — prepare-functions-deploy must resolve the tag before this guard runs"
[[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]] || guard_fail "release commit '$RELEASE_SHA' is not a full 40-char SHA"

if [[ -z "$LIVE_SHA" ]]; then
  HEALTH_URL="${FUNCTIONS_HEALTH_LIVE_URL:-${FUNCTIONS_BASE_URL:+${FUNCTIONS_BASE_URL}/healthLive}}"
  HEALTH_URL="${HEALTH_URL:-https://us-central1-burnbar.cloudfunctions.net/healthLive}"
  live_body="$(curl -fsS --max-time 30 "$HEALTH_URL" 2>/dev/null)" \
    || guard_fail "could not read the live deploy state at ${HEALTH_URL} — refusing to guess (fail closed). If the live commit is unknowable, commit a config/deploy-regression-receipts/<date>.json bootstrap receipt"
  LIVE_SHA="$(printf '%s' "$live_body" | jq -r '.source.commit // empty' 2>/dev/null || printf '%s' "$live_body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("source",{}).get("commit",""))' 2>/dev/null || echo "")"
fi

if [[ -z "$LIVE_SHA" || "$LIVE_SHA" == "unknown" || "$LIVE_SHA" == "null" ]]; then
  guard_fail "the live deployed commit is UNRECORDED (no source-commit stamp on production — the #2195 postmortem condition). Deploying now would regress live production fixes blind. Land human queue item 11 (fresh stamped deploy) or commit config/deploy-regression-receipts/<date>.json (schema in docs/runbooks/functions-break-glass.md)"
fi

if git -C "$REPO_DIR" merge-base --is-ancestor "$LIVE_SHA" "$RELEASE_SHA" 2>/dev/null; then
  echo "ancestor-guard: live deployed commit ${LIVE_SHA:0:12} is an ancestor of release ${RELEASE_SHA:0:12} — no regression."
  exit 0
fi

if ! git -C "$REPO_DIR" cat-file -e "$LIVE_SHA" 2>/dev/null; then
  guard_fail "live deployed commit ${LIVE_SHA:0:12} is unknown to this checkout — cannot prove ancestry (fail closed). If this is the known bootstrap window, commit config/deploy-regression-receipts/<date>.json"
fi

echo "::warning::ancestor-guard: live deployed commit ${LIVE_SHA:0:12} is NOT an ancestor of release ${RELEASE_SHA:0:12} — deploying would regress live production fixes."
# Receipt escape hatch: a committed, dated, EXPIRING acknowledgment.
receipt_found=""
if [[ -d "$RECEIPTS_DIR" ]]; then
  for receipt in "$RECEIPTS_DIR"/*.json; do
    [[ -f "$receipt" ]] || continue
    if receipt_valid "$receipt"; then
      receipt_found="$receipt"
      break
    fi
    echo "::notice::ancestor-guard: receipt $(basename "$receipt") is present but expired or malformed — it does not authorize this deploy." >&2
  done
fi

if [[ -n "$receipt_found" ]]; then
  echo "::warning::ancestor-guard: proceeding under bootstrap receipt $(basename "$receipt_found") — production is knowingly ahead of the stamped lineage. Re-anchor with human queue item 11 before it expires."
  exit 0
fi

guard_fail "live deployed commit ${LIVE_SHA:0:12} is not an ancestor of release ${RELEASE_SHA:0:12} and no valid config/deploy-regression-receipts/<date>.json exists — deploy would regress live production fixes (#2195)"
