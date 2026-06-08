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
