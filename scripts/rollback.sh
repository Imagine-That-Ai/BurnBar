#!/usr/bin/env bash
# OpenBurnBar rollback script
#
# Rolls back Cloud Functions to a specific git tag or the previous release.
# Rollback is performed by checking out the tag and redeploying.
#
# Usage:
#   ./scripts/rollback.sh                    # Roll back to the previous release tag
#   ./scripts/rollback.sh v0.1.2-beta.11     # Roll back to a specific tag
#   ./scripts/rollback.sh --dry-run          # Preview what would be rolled back
#
# Prerequisites:
#   - firebase CLI installed and authenticated
#   - FIREBASE_PROJECT environment variable set (or uses .firebaserc default)
#   - Git tags fetched: git fetch --tags

set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=false
TARGET_TAG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    v*) TARGET_TAG="$arg" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── Resolve target tag ────────────────────────────────────────────────────

git fetch --tags --quiet

CURRENT_TAG=$(git describe --tags --exact-match HEAD 2>/dev/null || git describe --tags HEAD 2>/dev/null || echo "HEAD")
echo "Current: ${CURRENT_TAG}"

if [[ -z "$TARGET_TAG" ]]; then
  # Find the most recent release tag before the current one
  ALL_TAGS=$(git tag --list "v*" --sort=-version:refname)
  PREVIOUS_TAG=""
  FOUND_CURRENT=false
  while IFS= read -r tag; do
    if [[ "$FOUND_CURRENT" == "true" ]]; then
      PREVIOUS_TAG="$tag"
      break
    fi
    if git describe --tags --exact-match HEAD 2>/dev/null | grep -q "^${tag}$" || [[ "$CURRENT_TAG" == "$tag" ]]; then
      FOUND_CURRENT=true
    fi
  done <<< "$ALL_TAGS"

  if [[ -z "$PREVIOUS_TAG" ]]; then
    # Fall back to the most recent non-current tag
    PREVIOUS_TAG=$(git tag --list "v*" --sort=-version:refname | grep -v "^${CURRENT_TAG}$" | head -1 || true)
  fi

  if [[ -z "$PREVIOUS_TAG" ]]; then
    echo "ERROR: Could not determine previous tag. Specify a target tag explicitly." >&2
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

# ── Show what will change ─────────────────────────────────────────────────

echo ""
echo "=== Rollback Plan ==="
echo "  From: ${CURRENT_TAG}"
echo "  To:   ${TARGET_TAG}"
echo ""

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

read -r -p "Proceed with rollback to ${TARGET_TAG}? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Rollback cancelled."
  exit 0
fi

# ── Execute rollback ─────────────────────────────────────────────────────

ROLLBACK_BRANCH="rollback/${TARGET_TAG}-$(date +%Y%m%d%H%M%S)"
echo "==> Creating rollback branch: ${ROLLBACK_BRANCH}"
git checkout -b "$ROLLBACK_BRANCH" "refs/tags/${TARGET_TAG}"

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
