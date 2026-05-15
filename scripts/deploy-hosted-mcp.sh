#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GOOGLE_CLOUD_PROJECT:?GOOGLE_CLOUD_PROJECT is required}"
: "${REMOTE_MCP_TOKEN_HMAC_SECRET:?REMOTE_MCP_TOKEN_HMAC_SECRET is required}"

REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-openburnbar-hosted-mcp}"
IMAGE="gcr.io/${GOOGLE_CLOUD_PROJECT}/${SERVICE}:$(git rev-parse --short HEAD)"

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
  --set-env-vars "MCP_RESOURCE=https://mcp.openburnbar.com/mcp,MCP_AUTH_ISSUER=https://openburnbar.com,MCP_TOKEN_HMAC_SECRET=${REMOTE_MCP_TOKEN_HMAC_SECRET}"

gcloud run services describe "$SERVICE" --region "$REGION" --project "$GOOGLE_CLOUD_PROJECT" --format='value(status.url)'
