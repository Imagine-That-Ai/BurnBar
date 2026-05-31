#!/usr/bin/env bash
# Deploy public health probes required for post-deploy-health-gate.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROJECT="${FIREBASE_PROJECT:-burnbar}"
TAG="${FUNCTION_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "")}"
ENV_FILE="functions/.env.burnbar"

if [[ -n "$TAG" ]]; then
  touch "$ENV_FILE"
  { grep -v '^FUNCTION_VERSION=' "$ENV_FILE" || true; echo "FUNCTION_VERSION=${TAG}"; } > "${ENV_FILE}.tmp"
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
  export FUNCTION_VERSION="$TAG"
fi

npm run build --prefix functions
firebase deploy \
  --only functions:healthLive,functions:healthReady,functions:healthCheck \
  --project "$PROJECT" \
  --non-interactive

source scripts/ops/resolve-functions-base-url.sh
HEALTH_GATE_RETRIES=6 HEALTH_GATE_SLEEP_SEC=10 bash scripts/ci/post-deploy-health-gate.sh
