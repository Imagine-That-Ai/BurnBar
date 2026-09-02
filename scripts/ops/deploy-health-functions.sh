#!/usr/bin/env bash
# Deploy public health probes required for post-deploy-health-gate.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROJECT="${FIREBASE_PROJECT:-burnbar}"
TAG="${FUNCTION_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "")}"
SOURCE_COMMIT="${OPENBURNBAR_SOURCE_COMMIT:-$(git rev-parse HEAD)}"
SOURCE_REPOSITORY="${OPENBURNBAR_SOURCE_REPOSITORY:-https://github.com/Imagine-That-Ai/BurnBar}"
CORRESPONDING_SOURCE_URL="${OPENBURNBAR_CORRESPONDING_SOURCE_URL:-https://burnbar.ai/legal/source}"
ENV_FILE="functions/.env.burnbar"
PROD_CONFIG="functions/.env.burnbar.production"

if [[ ! -f "$PROD_CONFIG" ]]; then
  echo "ERROR: Missing $PROD_CONFIG — refusing to deploy health functions with empty production runtime config." >&2
  exit 1
fi

if [[ "${HEALTH_GATE_REQUIRE_SENTRY:-0}" == "1" && -z "${SENTRY_DSN:-}" ]]; then
  echo "ERROR: HEALTH_GATE_REQUIRE_SENTRY=1 but SENTRY_DSN is unset." >&2
  echo "       Provide the production functions DSN or use the full deploy-production workflow." >&2
  exit 1
fi

touch "$ENV_FILE"
{
  cat "$PROD_CONFIG"
  echo ""
  if [[ -n "$TAG" ]]; then
    echo "FUNCTION_VERSION=${TAG}"
  fi
  echo "OPENBURNBAR_SOURCE_COMMIT=${SOURCE_COMMIT}"
  echo "OPENBURNBAR_SOURCE_REPOSITORY=${SOURCE_REPOSITORY}"
  echo "OPENBURNBAR_CORRESPONDING_SOURCE_URL=${CORRESPONDING_SOURCE_URL}"
  if [[ -n "${SENTRY_DSN:-}" ]]; then
    echo "SENTRY_DSN=${SENTRY_DSN}"
    echo "SENTRY_ENVIRONMENT=${SENTRY_ENVIRONMENT:-production}"
  fi
} > "$ENV_FILE"

export FUNCTION_VERSION="$TAG"
export OPENBURNBAR_SOURCE_COMMIT="$SOURCE_COMMIT"
export OPENBURNBAR_SOURCE_REPOSITORY="$SOURCE_REPOSITORY"
export OPENBURNBAR_CORRESPONDING_SOURCE_URL="$CORRESPONDING_SOURCE_URL"

npm run build --prefix functions
# Scoped production deploys are PROHIBITED outside the deploy-production lane:
# they replace one function's source identity while healthLive keeps reporting
# the fleet's, so the deploy ancestor guard (scripts/ci/check-deploy-ancestor-guard.sh)
# could later prove ancestry for a lineage one function no longer has and roll
# that function back silently. Acknowledge explicitly, then re-anchor with a
# full stamped deploy (docs/runbooks/functions-break-glass.md).
if [[ "${PROJECT}" == "burnbar" && "${OPENBURNBAR_ACKNOWLEDGE_SCOPED_PROD_DEPLOY:-0}" != "1" ]]; then
  echo "ERROR: scoped deploy to the production project is prohibited (it desynchronizes the fleet lineage the deploy ancestor guard proves)." >&2
  echo "       Use the deploy-production lane, or set OPENBURNBAR_ACKNOWLEDGE_SCOPED_PROD_DEPLOY=1 and re-anchor with a full stamped deploy afterwards." >&2
  exit 1
fi
firebase deploy \
  --only functions:healthLive,functions:healthReady,functions:healthCheck \
  --project "$PROJECT" \
  --non-interactive

source scripts/ops/resolve-functions-base-url.sh
HEALTH_GATE_RETRIES=6 HEALTH_GATE_SLEEP_SEC=10 bash scripts/ci/post-deploy-health-gate.sh
