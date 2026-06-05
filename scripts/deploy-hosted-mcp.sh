#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GOOGLE_CLOUD_PROJECT:?GOOGLE_CLOUD_PROJECT is required}"

REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-openburnbar-hosted-mcp}"
SECRET_NAME="${REMOTE_MCP_TOKEN_HMAC_SECRET_NAME:-REMOTE_MCP_TOKEN_HMAC_SECRET}"
IMAGE="gcr.io/${GOOGLE_CLOUD_PROJECT}/${SERVICE}:$(git rev-parse --short HEAD)"
OPENBURNBAR_SOURCE_COMMIT="${OPENBURNBAR_SOURCE_COMMIT:-$(git rev-parse HEAD)}"
OPENBURNBAR_CORRESPONDING_SOURCE_URL="${OPENBURNBAR_CORRESPONDING_SOURCE_URL:-https://burnbar.ai/legal/source}"
ENV_VARS="MCP_RESOURCE=https://mcp.burnbar.ai/mcp,MCP_AUTH_ISSUER=https://openburnbar.com,OPENBURNBAR_SOURCE_COMMIT=${OPENBURNBAR_SOURCE_COMMIT},OPENBURNBAR_CORRESPONDING_SOURCE_URL=${OPENBURNBAR_CORRESPONDING_SOURCE_URL}"

if [[ -n "${OPENBURNBAR_STORAGE_BUCKET:-}" ]]; then
  ENV_VARS="${ENV_VARS},OPENBURNBAR_STORAGE_BUCKET=${OPENBURNBAR_STORAGE_BUCKET}"
fi

if [[ -n "${REMOTE_MCP_TOKEN_HMAC_SECRET:-}" ]]; then
  if ! gcloud secrets describe "$SECRET_NAME" --project "$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
    gcloud secrets create "$SECRET_NAME" \
      --replication-policy=automatic \
      --project "$GOOGLE_CLOUD_PROJECT"
  fi
  printf '%s' "$REMOTE_MCP_TOKEN_HMAC_SECRET" | gcloud secrets versions add "$SECRET_NAME" \
    --data-file=- \
    --project "$GOOGLE_CLOUD_PROJECT" >/dev/null
fi

gcloud secrets describe "$SECRET_NAME" --project "$GOOGLE_CLOUD_PROJECT" >/dev/null

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
  --set-secrets "MCP_TOKEN_HMAC_SECRET=${SECRET_NAME}:latest"

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
