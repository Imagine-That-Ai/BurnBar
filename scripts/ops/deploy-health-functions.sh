#!/usr/bin/env bash
# Deploy public health probes required for post-deploy-health-gate.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROJECT="${FIREBASE_PROJECT:-burnbar}"
TAG="${FUNCTION_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "")}"
SOURCE_COMMIT="${OPENBURNBAR_SOURCE_COMMIT:-$(git rev-parse HEAD)}"
SOURCE_URL="${OPENBURNBAR_CORRESPONDING_SOURCE_URL:-https://burnbar.ai/legal/source}"
ENV_FILE="${FUNCTIONS_ENV_FILE:-functions/.env.burnbar}"

upsert_env_var() {
  local key="$1"
  local value="$2"
  touch "$ENV_FILE"
  grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
  printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
}

write_deploy_metadata_env() {
  [[ -n "$TAG" ]] && upsert_env_var "FUNCTION_VERSION" "$TAG"
  upsert_env_var "OPENBURNBAR_SOURCE_COMMIT" "$SOURCE_COMMIT"
  upsert_env_var "OPENBURNBAR_CORRESPONDING_SOURCE_URL" "$SOURCE_URL"
}

validate_deploy_metadata() {
  if [[ ! "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: OPENBURNBAR_SOURCE_COMMIT must be the 40-character git commit deployed to health functions." >&2
    exit 1
  fi
  if [[ ! "$SOURCE_URL" =~ ^(https://|git@) ]]; then
    echo "ERROR: OPENBURNBAR_CORRESPONDING_SOURCE_URL must be an https:// or git@ source URL." >&2
    exit 1
  fi
}

run_self_test() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  ENV_FILE="$tmpdir/.env.burnbar"
  TAG="v2026.06.08.test"
  SOURCE_COMMIT="0123456789abcdef0123456789abcdef01234567"
  SOURCE_URL="https://burnbar.ai/legal/source"
  {
    echo "FUNCTION_VERSION=stale"
    echo "OPENBURNBAR_SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    echo "OPENBURNBAR_CORRESPONDING_SOURCE_URL=https://stale.example/source"
  } > "$ENV_FILE"
  validate_deploy_metadata
  write_deploy_metadata_env
  grep -q '^FUNCTION_VERSION=v2026.06.08.test$' "$ENV_FILE"
  grep -q '^OPENBURNBAR_SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567$' "$ENV_FILE"
  grep -q '^OPENBURNBAR_CORRESPONDING_SOURCE_URL=https://burnbar.ai/legal/source$' "$ENV_FILE"
  [[ "$(grep -c '^FUNCTION_VERSION=' "$ENV_FILE")" == "1" ]]
  [[ "$(grep -c '^OPENBURNBAR_SOURCE_COMMIT=' "$ENV_FILE")" == "1" ]]
  [[ "$(grep -c '^OPENBURNBAR_CORRESPONDING_SOURCE_URL=' "$ENV_FILE")" == "1" ]]
  echo "PASS: deploy-health-functions source metadata self-test"
}

if [[ "${DEPLOY_HEALTH_FUNCTIONS_SELF_TEST:-}" == "1" ]]; then
  run_self_test
  exit $?
fi

if [[ -n "$TAG" || -n "$SOURCE_COMMIT" || -n "$SOURCE_URL" ]]; then
  validate_deploy_metadata
  touch "$ENV_FILE"
  write_deploy_metadata_env
  export FUNCTION_VERSION="$TAG"
  export OPENBURNBAR_SOURCE_COMMIT="$SOURCE_COMMIT"
  export OPENBURNBAR_CORRESPONDING_SOURCE_URL="$SOURCE_URL"
fi

npm run build --prefix functions
firebase deploy \
  --only functions:healthLive,functions:healthReady,functions:healthCheck \
  --project "$PROJECT" \
  --non-interactive

source scripts/ops/resolve-functions-base-url.sh
EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
OPENBURNBAR_CORRESPONDING_SOURCE_URL="$SOURCE_URL" \
HEALTH_GATE_RETRIES=6 \
HEALTH_GATE_SLEEP_SEC=10 \
bash scripts/ci/post-deploy-health-gate.sh
