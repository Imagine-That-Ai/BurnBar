#!/usr/bin/env bash
# OpenBurnBar full SOURCE rollback (slow — rebuild + redeploy).
#
# Rolls back Cloud Functions to a specific git tag or the previous release by
# checking out the tag, rebuilding, and running `firebase deploy`. This is the
# FALLBACK path: it takes tens of minutes (MTTR).
#
# FAST PATH FIRST: for most incidents, pin traffic back to a previous-good
# Cloud Run revision in seconds (no rebuild) via:
#     scripts/ops/rollback-revision.sh <cloud-run-service> [target-revision]
# Use this source rollback only when no good revision exists (e.g. the bug is in
# committed source you must revert, or revisions were pruned).
#
# Usage:
#   ./scripts/rollback.sh                    # Roll back to the previous release tag
#   ./scripts/rollback.sh v1.0.1             # Roll back to a specific tag
#   ./scripts/rollback.sh --dry-run          # Preview what would be rolled back
#   ./scripts/rollback.sh --yes              # Non-interactive (skip confirmation)
#   ./scripts/rollback.sh --allow-stale      # Permit auto-targeting a tag older
#                                            # than the freshness window
#
# Prerequisites:
#   - firebase CLI installed and authenticated
#   - FIREBASE_PROJECT environment variable set (or uses .firebaserc default)
#   - Git tags fetched: git fetch --tags

set -euo pipefail
cd "$(dirname "$0")/.."

# SemVer release grammar this app ships under: vMAJOR.MINOR.PATCH with an
# optional -prerelease / +build suffix. Calver tags (v2026.6.5, v2026.06.03.x)
# must NEVER be auto-selected as the previous release — they are not part of
# the canonical v1.0.x line and `--sort=-version:refname` sorts them ABOVE it,
# which is exactly the bug that made an unguarded auto-rollback target a
# year-old beta (H14).
#
# NOTE on MAJOR: a bare vMAJOR.MINOR.PATCH regex still matches calver like
# v2026.6.5 (three dotted integers). We therefore cap MAJOR at three digits
# (0-999), which admits the canonical v0.x / v1.x SemVer line while rejecting
# year-shaped calver majors (v2026.*). H19 declares v1.0.x canonical.
SEMVER_TAG_RE='^v[0-9]{1,3}\.[0-9]+\.[0-9]+([-+].*)?$'

# Refuse to auto-target a release older than this many days without
# --allow-stale. A "previous release" that predates the freshness window is
# almost certainly the wrong target (a year-old calver, a stale beta), and
# rolling production back to it would convert a partial outage into a total one.
STALE_TAG_MAX_AGE_DAYS="${STALE_TAG_MAX_AGE_DAYS:-30}"

DRY_RUN=false
ASSUME_YES=false
ALLOW_STALE=false
TARGET_TAG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y) ASSUME_YES=true ;;
    --allow-stale) ALLOW_STALE=true ;;
    v*) TARGET_TAG="$arg" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── Resolve target tag ────────────────────────────────────────────────────

git fetch --tags --quiet

CURRENT_TAG=$(git describe --tags --exact-match HEAD 2>/dev/null || git describe --tags HEAD 2>/dev/null || echo "HEAD")
echo "Current: ${CURRENT_TAG}"

# Candidate releases: SemVer-grammar tags only, newest-first by tag creation
# date (creatordate), NOT by refname version sort. creatordate reflects when
# the tag was actually cut, so "previous release" means the release immediately
# before this one in real time — independent of any version-string ordering.
SEMVER_TAGS=$(git tag --list 'v[0-9]*' --sort=-creatordate | grep -E "$SEMVER_TAG_RE" || true)

AUTO_SELECTED=false
if [[ -z "$TARGET_TAG" ]]; then
  AUTO_SELECTED=true
  # Walk newest-first; the first SemVer tag that is not the current one is the
  # previous release.
  PREVIOUS_TAG=""
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    if [[ "$tag" == "$CURRENT_TAG" ]]; then
      continue
    fi
    PREVIOUS_TAG="$tag"
    break
  done <<< "$SEMVER_TAGS"

  if [[ -z "$PREVIOUS_TAG" ]]; then
    echo "ERROR: Could not determine a previous SemVer release tag (grammar ${SEMVER_TAG_RE})." >&2
    echo "       Specify a target tag explicitly, e.g. ./scripts/rollback.sh v1.0.1" >&2
    exit 1
  fi
  TARGET_TAG="$PREVIOUS_TAG"
fi

echo "Target: ${TARGET_TAG}"

# Verify tag exists
if ! git rev-parse "refs/tags/${TARGET_TAG}" &>/dev/null; then
  echo "ERROR: Tag '${TARGET_TAG}' not found. Run 'git fetch --tags' and retry." >&2
  exit 1
fi

# Freshness guard: an auto-selected target older than the window is refused
# unless --allow-stale is passed. An explicit tag argument is always honored.
if [[ "$AUTO_SELECTED" == "true" && "$ALLOW_STALE" != "true" ]]; then
  TAG_EPOCH=$(git log -1 --format=%ct "refs/tags/${TARGET_TAG}" 2>/dev/null || echo "0")
  NOW_EPOCH=$(date +%s)
  AGE_DAYS=$(( (NOW_EPOCH - TAG_EPOCH) / 86400 ))
  if [[ "$TAG_EPOCH" -gt 0 && "$AGE_DAYS" -gt "$STALE_TAG_MAX_AGE_DAYS" ]]; then
    echo "ERROR: Auto-selected target '${TARGET_TAG}' is ${AGE_DAYS} days old (> ${STALE_TAG_MAX_AGE_DAYS}-day freshness window)." >&2
    echo "       Rolling production back this far is almost certainly wrong. If you are sure," >&2
    echo "       re-run with an explicit tag (./scripts/rollback.sh ${TARGET_TAG}) or --allow-stale." >&2
    exit 1
  fi
fi

# ── Show what will change ─────────────────────────────────────────────────

echo ""
echo "=== Rollback Plan ==="
echo "  From:   ${CURRENT_TAG}"
echo "  To:     ${TARGET_TAG}"
echo "  Config: functions/.env.burnbar.production (committed, reviewed)"
echo ""

if [[ ! -f "functions/.env.burnbar.production" ]]; then
  echo "ERROR: Missing functions/.env.burnbar.production — refusing to roll back with empty runtime config." >&2
  exit 1
fi

DIFF_STAT=$(git diff --stat "refs/tags/${TARGET_TAG}"...HEAD -- functions/ || true)
if [[ -n "$DIFF_STAT" ]]; then
  echo "Files changed in functions/ since ${TARGET_TAG}:"
  echo "$DIFF_STAT"
else
  echo "No changes in functions/ since ${TARGET_TAG}."
fi
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN: No changes made."
  exit 0
fi

# ── Confirm rollback ──────────────────────────────────────────────────────

if [[ "$ASSUME_YES" != "true" ]]; then
  read -r -p "Proceed with rollback to ${TARGET_TAG}? [y/N] " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Rollback cancelled."
    exit 0
  fi
fi

# ── Execute rollback ─────────────────────────────────────────────────────

# H14: capture the committed, reviewed production runtime config from the
# CURRENT tree BEFORE checking out the (older) target tag. The old tag may
# predate this file, and a rollback must never ship with empty runtime config.
# Both this script and the production deploy lane source the SAME file
# (functions/.env.burnbar.production), so they can never disagree.
PROD_CONFIG="functions/.env.burnbar.production"
PROD_CONFIG_SNAPSHOT=""
if [[ -f "$PROD_CONFIG" ]]; then
  PROD_CONFIG_SNAPSHOT="$(mktemp)"
  cp "$PROD_CONFIG" "$PROD_CONFIG_SNAPSHOT"
else
  echo "ERROR: Missing $PROD_CONFIG — refusing to roll back with empty runtime config." >&2
  echo "       This file is the committed source of truth for production env." >&2
  exit 1
fi

ROLLBACK_BRANCH="rollback/${TARGET_TAG}-$(date +%Y%m%d%H%M%S)"
echo "==> Creating rollback branch: ${ROLLBACK_BRANCH}"
git checkout -b "$ROLLBACK_BRANCH" "refs/tags/${TARGET_TAG}"

# Materialize the current reviewed runtime config into the deploy env file so
# the rolled-back functions deploy with the same non-secret IDs/URLs the live
# deploy lane uses — never empty config from a year-old tree.
echo "==> Applying production runtime config (${PROD_CONFIG})..."
{
  cat "$PROD_CONFIG_SNAPSHOT"
  echo ""
  echo "FUNCTION_VERSION=${TARGET_TAG}"
} > "functions/.env.burnbar"
rm -f "$PROD_CONFIG_SNAPSHOT"

echo "==> Building functions for rollback..."
npm ci --prefix functions
npm run build --prefix functions

echo "==> Deploying functions rollback..."
FIREBASE_PROJECT=$(node -e "try{const r=require('./firebase.json');console.log(r.projectId||r.default||'')}catch{}" 2>/dev/null || cat .firebaserc | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('projects',{}).get('default',''))" 2>/dev/null || echo "")

if [[ -n "$FIREBASE_PROJECT" ]]; then
  firebase deploy --only functions --project "$FIREBASE_PROJECT"
else
  firebase deploy --only functions
fi

echo ""
echo "=== Rollback Complete ==="
echo "  Deployed: ${TARGET_TAG}"
echo "  Branch:   ${ROLLBACK_BRANCH}"
echo ""
echo "Next steps:"
echo "  1. Verify health: curl https://us-central1-\${PROJECT}.cloudfunctions.net/healthCheck"
echo "  2. Monitor for 10 minutes"
echo "  3. When stable, merge rollback branch: git checkout main && git merge ${ROLLBACK_BRANCH}"
