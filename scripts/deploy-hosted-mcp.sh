#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

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

npm ci --prefix services/hosted-mcp
npm --prefix services/hosted-mcp run build
npm --prefix services/hosted-mcp test

gcloud builds submit services/hosted-mcp --tag "$IMAGE" --project "$GOOGLE_CLOUD_PROJECT"
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
