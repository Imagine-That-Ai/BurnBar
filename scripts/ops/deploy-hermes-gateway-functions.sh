#!/usr/bin/env bash
# Deploy the Hermes Gateway functions with source-provenance metadata.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROJECT="${FIREBASE_PROJECT:-burnbar}"
REGION="${GCLOUD_REGION:-us-central1}"
SOURCE_COMMIT="${OPENBURNBAR_SOURCE_COMMIT:-$(git rev-parse HEAD)}"
SOURCE_URL="${OPENBURNBAR_CORRESPONDING_SOURCE_URL:-https://burnbar.ai/legal/source}"
FUNCTION_VERSION="${FUNCTION_VERSION:-v$(date -u +%Y.%m.%d.%H%M)}"
ENV_FILE="${FUNCTIONS_ENV_FILE:-functions/.env.burnbar}"

upsert_env_var() {
  local key="$1"
  local value="$2"
  touch "$ENV_FILE"
  grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
  printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
}

validate_metadata() {
  if [[ ! "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: OPENBURNBAR_SOURCE_COMMIT must be the 40-character commit being deployed." >&2
    exit 1
  fi
  if [[ ! "$SOURCE_URL" =~ ^(https://|git@) ]]; then
    echo "ERROR: OPENBURNBAR_CORRESPONDING_SOURCE_URL must be an https:// or git@ source URL." >&2
    exit 1
  fi
}

write_env() {
  upsert_env_var "FUNCTION_VERSION" "$FUNCTION_VERSION"
  upsert_env_var "OPENBURNBAR_SOURCE_COMMIT" "$SOURCE_COMMIT"
  upsert_env_var "OPENBURNBAR_CORRESPONDING_SOURCE_URL" "$SOURCE_URL"
  upsert_env_var "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED" "true"
  upsert_env_var "SIGNAL_ENVELOPE_V4_DISABLED" "0"
}

hydrate_env_from_live_revision() {
  local service="burnbarhermesgateway"
  local revision
  revision="$(gcloud run services describe "$service" --project "$PROJECT" --region "$REGION" --format='value(status.latestReadyRevisionName)')"
  if [[ -z "$revision" ]]; then
    echo "ERROR: could not resolve latest ready revision for $service." >&2
    exit 1
  fi
  local tmp_json
  tmp_json="$(mktemp)"
  trap 'rm -f "$tmp_json"' RETURN
  gcloud run revisions describe "$revision" \
    --project "$PROJECT" \
    --region "$REGION" \
    --format='json(spec.containers[0].env)' > "$tmp_json"
  ENV_FILE="$ENV_FILE" python3 - "$tmp_json" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

env_file = Path(os.environ["ENV_FILE"])
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
entries = data.get("spec", {}).get("containers", [{}])[0].get("env", [])
excluded = {
    "EVENTARC_CLOUD_EVENT_SOURCE",
    "FIREBASE_CONFIG",
    "FUNCTION_TARGET",
    "GCLOUD_PROJECT",
    "LOG_EXECUTION_ID",
}
managed = {
    "FUNCTION_VERSION",
    "OPENBURNBAR_SOURCE_COMMIT",
    "OPENBURNBAR_CORRESPONDING_SOURCE_URL",
    "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED",
    "SIGNAL_ENVELOPE_V4_DISABLED",
}
existing = {}
lines = []
if env_file.exists():
    for line in env_file.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
        if match:
            existing[match.group(1)] = line
        else:
            lines.append(line)
for entry in entries:
    name = entry.get("name")
    value = entry.get("value")
    if not name or value is None or name in excluded or name in managed:
        continue
    existing.setdefault(name, f"{name}={value}")
ordered = lines + [existing[name] for name in sorted(existing)]
env_file.parent.mkdir(parents=True, exist_ok=True)
env_file.write_text("\n".join(line for line in ordered if line) + "\n", encoding="utf-8")
PY
}

run_self_test() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  ENV_FILE="$tmpdir/.env.burnbar"
  SOURCE_COMMIT="0123456789abcdef0123456789abcdef01234567"
  SOURCE_URL="https://burnbar.ai/legal/source"
  FUNCTION_VERSION="v2026.06.08.test"
  {
    echo "FUNCTION_VERSION=stale"
    echo "OPENBURNBAR_SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "OPENBURNBAR_CORRESPONDING_SOURCE_URL=https://stale.example/source"
    echo "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=false"
    echo "SIGNAL_ENVELOPE_V4_DISABLED=1"
  } > "$ENV_FILE"
  validate_metadata
  write_env
  grep -q '^FUNCTION_VERSION=v2026.06.08.test$' "$ENV_FILE"
  grep -q '^OPENBURNBAR_SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567$' "$ENV_FILE"
  grep -q '^OPENBURNBAR_CORRESPONDING_SOURCE_URL=https://burnbar.ai/legal/source$' "$ENV_FILE"
  grep -q '^OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true$' "$ENV_FILE"
  grep -q '^SIGNAL_ENVELOPE_V4_DISABLED=0$' "$ENV_FILE"
  [[ "$(grep -c '^OPENBURNBAR_SOURCE_COMMIT=' "$ENV_FILE")" == "1" ]]
  echo "PASS: deploy-hermes-gateway-functions metadata self-test"
}

if [[ "${DEPLOY_HERMES_GATEWAY_FUNCTIONS_SELF_TEST:-}" == "1" ]]; then
  run_self_test
  exit $?
fi

if [[ "$(git rev-parse HEAD)" != "$SOURCE_COMMIT" ]]; then
  echo "ERROR: OPENBURNBAR_SOURCE_COMMIT must match the checked-out HEAD for this deploy." >&2
  exit 1
fi
if ! git diff --quiet --ignore-submodules -- || ! git diff --cached --quiet --ignore-submodules --; then
  echo "ERROR: working tree is dirty; commit before deploying Hermes Gateway functions." >&2
  exit 1
fi

validate_metadata
hydrate_env_from_live_revision
write_env

export FUNCTION_VERSION
export OPENBURNBAR_SOURCE_COMMIT="$SOURCE_COMMIT"
export OPENBURNBAR_CORRESPONDING_SOURCE_URL="$SOURCE_URL"
export OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true
export SIGNAL_ENVELOPE_V4_DISABLED=0

npm run build --prefix functions
firebase deploy \
  --only functions:burnBarHermesGateway,functions:enqueueHermesGatewayEvent \
  --project "$PROJECT" \
  --non-interactive

node scripts/ci/rollout_hermes_gateway_signal_required.js \
  enable-hermes-gateway-signal-required \
  --project-id "$PROJECT" \
  --region "$REGION" \
  --deployed-commit "$SOURCE_COMMIT" \
  --source-location "$SOURCE_URL"
