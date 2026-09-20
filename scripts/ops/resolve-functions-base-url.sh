#!/usr/bin/env bash
# Resolve Cloud Functions HTTP base URL and health endpoint URLs for probes.
# Source: source scripts/ops/resolve-functions-base-url.sh
# Pass --print-json to print the resolved deployment topology without probing
# Firebase. The JSON mode is intended for CI and documentation tooling.
set -euo pipefail

PRINT_JSON=false
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print-json) PRINT_JSON=true; shift ;;
      -h|--help)
        echo "Usage: $0 [--print-json]"
        exit 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        echo "Usage: $0 [--print-json]" >&2
        exit 1
        ;;
    esac
  done
fi

FIREBASE_RC="${FIREBASE_RC:-.firebaserc}"
read_firebase_project() {
  local key="$1"
  if [[ ! -f "$FIREBASE_RC" ]]; then
    return 0
  fi
  python3 - "$FIREBASE_RC" "$key" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
    print(data.get("projects", {}).get(sys.argv[2], ""))
except (OSError, TypeError, ValueError):
    print("")
PY
}

PROJECT="${FIREBASE_PROJECT:-${OPENBURNBAR_FIREBASE_PROJECT:-}}"
if [[ -z "$PROJECT" ]]; then
  PROJECT="$(read_firebase_project default)"
fi
PROJECT="${PROJECT:-burnbar}"
STAGING_PROJECT="${FIREBASE_STAGING_PROJECT:-$(read_firebase_project staging)}"
STAGING_PROJECT="${STAGING_PROJECT:-burnbar-staging}"
REGION="${FUNCTIONS_REGION:-us-central1}"
DEFAULT_BASE="https://${REGION}-${PROJECT}.cloudfunctions.net"

# These are isolated emulator projects, not deploy targets. Keep this list
# closed: the topology lint has the same exact allowlist.
EMULATOR_PROJECT_IDS=("openburnbar-dev" "openburnbar-rules-test" "openburnbar-demo")

lookup_uri() {
  local fn_id="$1"
  local list_json="${FUNCTIONS_LIST_JSON:-}"
  if [[ -z "$list_json" ]] && command -v firebase >/dev/null 2>&1; then
    list_json="$(firebase functions:list --project "$PROJECT" --json 2>/dev/null || echo '{}')"
  fi
  python3 -c "
import json, sys
target = sys.argv[1].lower()
payload = sys.stdin.read()
data, _ = json.JSONDecoder().raw_decode(payload.strip() or '{}')
for entry in data.get('result', []):
    if str(entry.get('id', '')).lower() == target:
        print(entry.get('uri') or '')
        break
" "$fn_id" <<< "${list_json:-{}}"
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

# The topology output must stay usable without credentials. Preserve an
# explicitly supplied FUNCTIONS_LIST_JSON fixture, but do not turn --print-json
# into a network probe when no fixture was supplied.
if [[ "$PRINT_JSON" == "true" && -z "${FUNCTIONS_LIST_JSON:-}" ]]; then
  FUNCTIONS_LIST_JSON='{}'
  export FUNCTIONS_LIST_JSON
fi

if [[ -z "${FUNCTIONS_LIST_JSON:-}" ]] && command -v firebase >/dev/null 2>&1; then
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

if [[ "$PRINT_JSON" == "true" ]]; then
  python3 - "$PROJECT" "$STAGING_PROJECT" "$REGION" "$BASE_URL" "${EMULATOR_PROJECT_IDS[@]}" <<'PY'
import json
import sys

project, staging_project, region, base_url, *emulator_project_ids = sys.argv[1:]
print(json.dumps({
    "project": project,
    "stagingProject": staging_project,
    "region": region,
    "baseUrl": base_url,
    "emulatorProjectIds": emulator_project_ids,
}, indent=2))
PY
  exit 0
fi

if [[ -z "$HEALTH_LIVE_URL" ]]; then
  echo "WARN: healthLive is not deployed in project ${PROJECT} — run scripts/ops/deploy-health-functions.sh" >&2
fi

echo "FUNCTIONS_BASE_URL=${FUNCTIONS_BASE_URL}"
echo "FUNCTIONS_HEALTH_LIVE_URL=${FUNCTIONS_HEALTH_LIVE_URL}"
echo "FUNCTIONS_HEALTH_READY_URL=${FUNCTIONS_HEALTH_READY_URL}"
