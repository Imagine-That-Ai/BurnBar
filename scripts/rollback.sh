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
#   ./scripts/rollback.sh --force            # Override the live-source ancestry guard
#   ./scripts/rollback.sh --allow-stale      # Permit auto-targeting a tag older
#                                            # than the freshness window
#
# Prerequisites:
#   - firebase CLI installed and authenticated
#   - gcloud CLI installed and authenticated for the live-source guard (or
#     human-verified --force)
#   - FIREBASE_PROJECT environment variable set (or uses .firebaserc default)
#   - SENTRY_DSN set to the production Functions Sentry ingest DSN
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
FORCE=false
TARGET_TAG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y) ASSUME_YES=true ;;
    --force) FORCE=true ;;
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
TARGET_COMMIT="$(git rev-parse "refs/tags/${TARGET_TAG}^{commit}")"

# #2195: a Functions deploy can come from an uncommitted or unpushed checkout,
# so rolling it back to an ancestor tag may silently discard fixes that are not
# present on any tag or remote branch. Prefer an operator-supplied readback when
# available; otherwise query the production Functions metadata. The guard is
# fail-closed when production metadata is unavailable or not represented in the
# local Git object database. `--force` is the explicit incident-owner override.
ROLLBACK_PROJECT="${FIREBASE_PROJECT:-${GCLOUD_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}}"
if [[ -z "$ROLLBACK_PROJECT" && -f "firebase.json" ]]; then
  ROLLBACK_PROJECT="$(node -e "try{const r=require('./firebase.json');console.log(r.projectId||r.default||'')}catch{}" 2>/dev/null || echo "")"
fi
if [[ -z "$ROLLBACK_PROJECT" && -f ".firebaserc" ]]; then
  ROLLBACK_PROJECT="$(python3 -c "
import json, sys
try:
    with open('.firebaserc', encoding='utf-8') as f:
        d = json.load(f)
    print(d.get('projects', {}).get('default', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")"
fi

if [[ "$FORCE" != "true" ]]; then
  LIVE_SOURCE_COMMITS="${OPENBURNBAR_LIVE_SOURCE_COMMIT:-${OPENBURNBAR_SOURCE_COMMIT:-}}"
  if [[ -z "$LIVE_SOURCE_COMMITS" && -n "$ROLLBACK_PROJECT" ]]; then
    if ! command -v gcloud >/dev/null 2>&1; then
      echo "ERROR: cannot verify live OPENBURNBAR_SOURCE_COMMIT because gcloud is unavailable." >&2
      echo "       Verify the deployed source commit, then re-run with --force if this rollback is intentional." >&2
      exit 1
    fi
    LIVE_SOURCE_COMMITS="$(gcloud functions list \
      --gen2 \
      --project "$ROLLBACK_PROJECT" \
      --format='value(serviceConfig.environmentVariables.OPENBURNBAR_SOURCE_COMMIT)' \
      2>/dev/null || true)"
  fi

  if [[ -n "$LIVE_SOURCE_COMMITS" ]]; then
    while IFS= read -r live_commit; do
      [[ -z "$live_commit" ]] && continue
      if [[ ! "$live_commit" =~ ^[a-fA-F0-9]{40}$ ]]; then
        echo "ERROR: live OPENBURNBAR_SOURCE_COMMIT is missing or invalid; refusing rollback." >&2
        echo "       Verify the deployed source metadata, then re-run with --force if intentional." >&2
        exit 1
      fi
      live_commit="$(printf '%s' "$live_commit" | tr '[:upper:]' '[:lower:]')"
      if [[ "$live_commit" == "$TARGET_COMMIT" ]]; then
        continue
      fi
      if ! git cat-file -e "${live_commit}^{commit}" 2>/dev/null; then
        echo "ERROR: live source commit ${live_commit} is not present in this checkout; refusing rollback." >&2
        echo "       Fetch the deployed commit or re-run with --force after human verification." >&2
        exit 1
      fi
      # The #2195 hazard is a deploy built from an uncommitted or unpushed
      # checkout: it carries fixes that no tag or remote branch contains, and a
      # rollback to an ancestor tag would discard them silently. So the guard
      # is on the live commit's publication state, not on the rollback
      # relationship itself (a routine rollback target is always an ancestor).
      if [[ -z "$(git tag --contains "$live_commit" 2>/dev/null)" && \
            -z "$(git branch -r --contains "$live_commit" 2>/dev/null)" ]]; then
        echo "ERROR: live source commit ${live_commit} is not contained in any tag or remote branch; refusing rollback." >&2
        echo "       The live deploy may contain unpublished fixes. Re-run with --force only after verification." >&2
        exit 1
      fi
      # A target that is not behind the live commit is a sideways or forward
      # move, not a rollback of what is deployed; that needs an explicit override.
      if ! git merge-base --is-ancestor "$TARGET_COMMIT" "$live_commit"; then
        echo "ERROR: target ${TARGET_TAG} (${TARGET_COMMIT}) is not an ancestor of live source commit ${live_commit}." >&2
        echo "       This is not a rollback of the live deploy. Re-run with --force only after verification." >&2
        exit 1
      fi
    done <<< "$LIVE_SOURCE_COMMITS"
  elif [[ -n "$ROLLBACK_PROJECT" ]]; then
    echo "ERROR: live OPENBURNBAR_SOURCE_COMMIT could not be verified; refusing rollback." >&2
    echo "       Re-run with --force only after a human verifies the deployed source." >&2
    exit 1
  fi
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
echo "  Commit: ${TARGET_COMMIT}"
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

# Production deploys fail closed when Sentry is unavailable. Source rollback
# must preserve the same contract rather than silently shipping a dark runtime.
if [[ -z "${SENTRY_DSN:-}" ]]; then
  echo "ERROR: SENTRY_DSN is required for a production Functions rollback." >&2
  echo "       Export the production Functions DSN used by deploy-production.yml and retry." >&2
  exit 1
fi
if [[ "${SENTRY_ENVIRONMENT:-production}" != "production" ]]; then
  echo "ERROR: SENTRY_ENVIRONMENT must be 'production' for a production Functions rollback." >&2
  exit 1
fi
if [[ ! -f "scripts/ci/sentry_dsn.py" ]]; then
  echo "ERROR: Missing scripts/ci/sentry_dsn.py — refusing an unvalidated Sentry rollback config." >&2
  exit 1
fi
SENTRY_DSN="$(SENTRY_DSN="$SENTRY_DSN" python3 scripts/ci/sentry_dsn.py validate SENTRY_DSN)"
SENTRY_ENVIRONMENT="production"

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
if [[ "$(git rev-parse HEAD)" != "$TARGET_COMMIT" ]]; then
  echo "ERROR: Rollback checkout does not match the resolved target commit." >&2
  exit 1
fi

# Materialize the current reviewed runtime config into the deploy env file so
# the rolled-back functions deploy with the same non-secret IDs/URLs the live
# deploy lane uses — never empty config from a year-old tree. Dynamic release
# identity and Sentry values mirror deploy-production.yml exactly.
echo "==> Applying production runtime config (${PROD_CONFIG})..."
{
  cat "$PROD_CONFIG_SNAPSHOT"
  echo ""
  echo "FUNCTION_VERSION=${TARGET_TAG}"
  echo "OPENBURNBAR_SOURCE_COMMIT=${TARGET_COMMIT}"
  echo "SENTRY_DSN=${SENTRY_DSN}"
  echo "SENTRY_ENVIRONMENT=${SENTRY_ENVIRONMENT}"
} > "functions/.env.burnbar"
rm -f "$PROD_CONFIG_SNAPSHOT"
export FUNCTION_VERSION="$TARGET_TAG"
export OPENBURNBAR_SOURCE_COMMIT="$TARGET_COMMIT"
export SENTRY_ENVIRONMENT

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
