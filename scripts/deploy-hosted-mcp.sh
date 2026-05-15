#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GOOGLE_CLOUD_PROJECT:?GOOGLE_CLOUD_PROJECT is required}"

REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-openburnbar-hosted-mcp}"
SECRET_NAME="${REMOTE_MCP_TOKEN_HMAC_SECRET_NAME:-REMOTE_MCP_TOKEN_HMAC_SECRET}"
IMAGE="gcr.io/${GOOGLE_CLOUD_PROJECT}/${SERVICE}:$(git rev-parse --short HEAD)"

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
  --set-env-vars "MCP_RESOURCE=https://mcp.openburnbar.com/mcp,MCP_AUTH_ISSUER=https://openburnbar.com" \
  --set-secrets "MCP_TOKEN_HMAC_SECRET=${SECRET_NAME}:latest"

gcloud run services describe "$SERVICE" --region "$REGION" --project "$GOOGLE_CLOUD_PROJECT" --format='value(status.url)'
