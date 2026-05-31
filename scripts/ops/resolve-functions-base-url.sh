#!/usr/bin/env bash
# Resolve Cloud Functions HTTP base URL and health endpoint URLs for probes.
# Source: source scripts/ops/resolve-functions-base-url.sh
set -euo pipefail

PROJECT="${FIREBASE_PROJECT:-${OPENBURNBAR_FIREBASE_PROJECT:-burnbar}}"
REGION="${FUNCTIONS_REGION:-us-central1}"
DEFAULT_BASE="https://${REGION}-${PROJECT}.cloudfunctions.net"

lookup_uri() {
  local fn_id="$1"
  local list_json="${FUNCTIONS_LIST_JSON:-}"
  if [[ -z "$list_json" ]] && command -v firebase >/dev/null 2>&1; then
    list_json="$(firebase functions:list --project "$PROJECT" --json 2>/dev/null || echo '{}')"
  fi
  python3 -c "
import json, sys
target = sys.argv[1].lower()
data = json.loads(sys.argv[2] or '{}')
for entry in data.get('result', []):
    if str(entry.get('id', '')).lower() == target:
        print(entry.get('uri') or '')
        break
" "$fn_id" "$list_json"
}

uri_to_base() {
  local uri="$1"
  python3 -c "
from urllib.parse import urlparse
import sys
parsed = urlparse(sys.argv[1])
print(f'{parsed.scheme}://{parsed.netloc}')
" "$uri"
}

if command -v firebase >/dev/null 2>&1; then
  FUNCTIONS_LIST_JSON="$(firebase functions:list --project "$PROJECT" --json 2>/dev/null || echo '{}')"
  export FUNCTIONS_LIST_JSON
fi

HEALTH_LIVE_URL="${FUNCTIONS_HEALTH_LIVE_URL:-$(lookup_uri healthLive)}"
HEALTH_READY_URL="${FUNCTIONS_HEALTH_READY_URL:-$(lookup_uri healthReady)}"

if [[ -n "${FUNCTIONS_BASE_URL:-}" ]]; then
  BASE_URL="$FUNCTIONS_BASE_URL"
elif [[ -n "$HEALTH_LIVE_URL" ]]; then
  BASE_URL="$(uri_to_base "$HEALTH_LIVE_URL")"
else
  sample_uri="$(lookup_uri healthCheck)"
  if [[ -z "$sample_uri" ]]; then
    sample_uri="$(lookup_uri appStoreServerNotificationsV2)"
  fi
  if [[ -n "$sample_uri" ]]; then
    BASE_URL="$(uri_to_base "$sample_uri")"
  else
    BASE_URL="$DEFAULT_BASE"
  fi
fi

export FUNCTIONS_BASE_URL="$BASE_URL"
export FUNCTIONS_HEALTH_LIVE_URL="${HEALTH_LIVE_URL:-${BASE_URL}/healthLive}"
export FUNCTIONS_HEALTH_READY_URL="${HEALTH_READY_URL:-${BASE_URL}/healthReady}"
export FIREBASE_PROJECT="$PROJECT"
export FUNCTIONS_REGION="$REGION"

if [[ -z "$HEALTH_LIVE_URL" ]]; then
  echo "WARN: healthLive is not deployed in project ${PROJECT} — run scripts/ops/deploy-health-functions.sh" >&2
fi

echo "FUNCTIONS_BASE_URL=${FUNCTIONS_BASE_URL}"
echo "FUNCTIONS_HEALTH_LIVE_URL=${FUNCTIONS_HEALTH_LIVE_URL}"
echo "FUNCTIONS_HEALTH_READY_URL=${FUNCTIONS_HEALTH_READY_URL}"
