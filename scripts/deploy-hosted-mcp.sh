#!/usr/bin/env bash
set -euo pipefail
cd "${GITHUB_WORKSPACE:-$(dirname "$0")/..}"

: "${GOOGLE_CLOUD_PROJECT:?GOOGLE_CLOUD_PROJECT is required}"

REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-openburnbar-hosted-mcp}"
SECRET_NAME="${REMOTE_MCP_TOKEN_HMAC_SECRET_NAME:-REMOTE_MCP_TOKEN_HMAC_SECRET}"
ED25519_PRIVATE_SECRET_NAME="${REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_SECRET_NAME:-REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64}"
ED25519_PUBLIC_SECRET_NAME="${MCP_TOKEN_ED25519_PUBLIC_KEY_SECRET_NAME:-MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64}"
IMAGE="gcr.io/${GOOGLE_CLOUD_PROJECT}/${SERVICE}:$(git rev-parse --short HEAD)"
OPENBURNBAR_SOURCE_COMMIT="${OPENBURNBAR_SOURCE_COMMIT:-$(git rev-parse HEAD)}"
OPENBURNBAR_CORRESPONDING_SOURCE_URL="${OPENBURNBAR_CORRESPONDING_SOURCE_URL:-https://burnbar.ai/legal/source}"
ENV_VARS="MCP_RESOURCE=https://mcp.burnbar.ai/mcp,MCP_AUTH_ISSUER=https://mcp.burnbar.ai,OPENBURNBAR_SOURCE_COMMIT=${OPENBURNBAR_SOURCE_COMMIT},OPENBURNBAR_CORRESPONDING_SOURCE_URL=${OPENBURNBAR_CORRESPONDING_SOURCE_URL}"
SECRET_BINDINGS=()

upsert_secret() {
  local secret_name="$1"
  local secret_value="$2"
  if ! gcloud secrets describe "$secret_name" --project "$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
    gcloud secrets create "$secret_name" \
      --replication-policy=automatic \
      --project "$GOOGLE_CLOUD_PROJECT"
  fi
  printf '%s' "$secret_value" | gcloud secrets versions add "$secret_name" \
    --data-file=- \
    --project "$GOOGLE_CLOUD_PROJECT" >/dev/null
}

if [[ -n "${OPENBURNBAR_STORAGE_BUCKET:-}" ]]; then
  ENV_VARS="${ENV_VARS},OPENBURNBAR_STORAGE_BUCKET=${OPENBURNBAR_STORAGE_BUCKET}"
fi

if [[ -n "${REMOTE_MCP_TOKEN_HMAC_SECRET:-}" ]]; then
  upsert_secret "$SECRET_NAME" "$REMOTE_MCP_TOKEN_HMAC_SECRET"
fi

if gcloud secrets describe "$SECRET_NAME" --project "$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
  SECRET_BINDINGS+=("MCP_TOKEN_HMAC_SECRET=${SECRET_NAME}:latest")
fi

if [[ -n "${REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64:-}" ]]; then
  upsert_secret "$ED25519_PRIVATE_SECRET_NAME" "$REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64"
fi

if [[ -n "${MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64:-}" ]]; then
  upsert_secret "$ED25519_PUBLIC_SECRET_NAME" "$MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64"
fi

if gcloud secrets describe "$ED25519_PRIVATE_SECRET_NAME" --project "$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
  SECRET_BINDINGS+=("MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64=${ED25519_PRIVATE_SECRET_NAME}:latest")
fi

if gcloud secrets describe "$ED25519_PUBLIC_SECRET_NAME" --project "$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
  SECRET_BINDINGS+=("MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64=${ED25519_PUBLIC_SECRET_NAME}:latest")
  ENV_VARS="${ENV_VARS},MCP_ALLOW_LEGACY_HMAC_TOKENS=${MCP_ALLOW_LEGACY_HMAC_TOKENS:-false}"
fi

if [[ "${#SECRET_BINDINGS[@]}" -eq 0 ]]; then
  echo "At least one hosted MCP token signer must be configured: Ed25519 private/public secrets or legacy HMAC." >&2
  exit 1
fi

if [[ "${SECRET_BINDINGS[*]}" == *"MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64="* && "${SECRET_BINDINGS[*]}" != *"MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64="* ]]; then
  echo "Ed25519 private key is configured but MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64 is missing." >&2
  exit 1
fi

SET_SECRETS="$(IFS=,; echo "${SECRET_BINDINGS[*]}")"

submit_cloud_build() {
  local build_output build_id status deadline poll_interval

  build_output="$(gcloud builds submit . \
    --config services/hosted-mcp/cloudbuild.yaml \
    --substitutions "_IMAGE=${IMAGE}" \
    --suppress-logs \
    --async \
    --format=json \
    --project "$GOOGLE_CLOUD_PROJECT")"

  build_id="$(python3 -c '
import json
import re
import sys

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    data = {}

paths = (
    ("metadata", "build", "id"),
    ("metadata", "build", "name"),
    ("response", "id"),
    ("response", "name"),
    ("id",),
    ("name",),
)
for path in paths:
    node = data
    for key in path:
        if not isinstance(node, dict):
            node = None
            break
        node = node.get(key)
    if isinstance(node, str) and node:
        print(node.rsplit("/", 1)[-1])
        raise SystemExit(0)

match = re.search(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", raw)
if match:
    print(match.group(0))
' <<<"$build_output")"

  if [[ -z "$build_id" ]]; then
    echo "Unable to determine Cloud Build ID from gcloud output." >&2
    echo "$build_output" >&2
    exit 1
  fi

  echo "Cloud Build submitted: ${build_id}"
  echo "Cloud Build logs: https://console.cloud.google.com/cloud-build/builds/${build_id}?project=${GOOGLE_CLOUD_PROJECT}"

  poll_interval="${CLOUD_BUILD_POLL_INTERVAL_SECONDS:-10}"
  deadline=$((SECONDS + ${CLOUD_BUILD_TIMEOUT_SECONDS:-1800}))
  while true; do
    status="$(gcloud builds describe "$build_id" \
      --project "$GOOGLE_CLOUD_PROJECT" \
      --format='value(status)')"

    case "$status" in
      SUCCESS)
        echo "Cloud Build succeeded: ${build_id}"
        return 0
        ;;
      FAILURE|INTERNAL_ERROR|TIMEOUT|CANCELLED|EXPIRED)
        echo "Cloud Build failed with status ${status}: ${build_id}" >&2
        exit 1
        ;;
      QUEUED|WORKING|PENDING|"")
        if [[ "$SECONDS" -ge "$deadline" ]]; then
          echo "Cloud Build timed out waiting for ${build_id}; last status: ${status:-unknown}" >&2
          exit 1
        fi
        echo "Cloud Build ${build_id} status: ${status:-unknown}; waiting ${poll_interval}s..."
        sleep "$poll_interval"
        ;;
      *)
        echo "Cloud Build ${build_id} status: ${status}; waiting ${poll_interval}s..."
        sleep "$poll_interval"
        ;;
    esac
  done
}

npm ci --prefix services/hosted-mcp
npm --prefix services/hosted-mcp run build
npm --prefix services/hosted-mcp test

submit_cloud_build

gcloud run deploy "$SERVICE" \
  --image "$IMAGE" \
  --region "$REGION" \
  --project "$GOOGLE_CLOUD_PROJECT" \
  --platform managed \
  --allow-unauthenticated \
  --min-instances "${MIN_INSTANCES:-0}" \
  --max-instances "${MAX_INSTANCES:-20}" \
  --set-env-vars "$ENV_VARS" \
  --set-secrets "$SET_SECRETS"

SERVICE_URL="$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$GOOGLE_CLOUD_PROJECT" --format='value(status.url)')"
echo "$SERVICE_URL"

HEALTH_PATH="${MCP_HEALTH_PATH:-/healthz}"
HEALTH_URL="${SERVICE_URL%/}${HEALTH_PATH}"
RETRIES="${DEPLOY_HEALTH_RETRIES:-12}"
SLEEP_SEC="${DEPLOY_HEALTH_SLEEP_SEC:-10}"
attempt=1
while [[ "$attempt" -le "$RETRIES" ]]; do
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    echo "OK: ${HEALTH_URL}"
    exit 0
  fi
  echo "waiting for ${HEALTH_URL} (${attempt}/${RETRIES})..." >&2
  sleep "$SLEEP_SEC"
  attempt=$((attempt + 1))
done
echo "FAIL: ${HEALTH_URL} did not become healthy" >&2
exit 1
