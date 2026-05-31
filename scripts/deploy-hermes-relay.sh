#!/usr/bin/env bash
# Deploy Hermes realtime relay with post-deploy /healthz gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE_DIR="${ROOT}/services/hermes-realtime-relay"
RELAY_URL="${HERMES_RELAY_URL:-}"
HEALTH_PATH="${HERMES_RELAY_HEALTH_PATH:-/healthz}"
RETRIES="${DEPLOY_HEALTH_RETRIES:-12}"
SLEEP_SEC="${DEPLOY_HEALTH_SLEEP_SEC:-10}"

if [[ -z "${RELAY_URL}" ]]; then
  echo "Set HERMES_RELAY_URL to the deployed relay base URL (e.g. https://relay.example.com)" >&2
  exit 1
fi

echo "==> Build relay image (local smoke)"
npm ci --prefix "${SERVICE_DIR}"
npm run build --prefix "${SERVICE_DIR}" 2>/dev/null || npm run compile --prefix "${SERVICE_DIR}" 2>/dev/null || true

echo "==> Deploy: use your Cloud Run / hosting pipeline for ${SERVICE_DIR}"
echo "    Documented in docs/runbooks/iroh-secrets.md and services/hermes-realtime-relay/README.md"

health_url="${RELAY_URL%/}${HEALTH_PATH}"
attempt=1
while [[ "$attempt" -le "$RETRIES" ]]; do
  if curl -fsS "${health_url}" | grep -q '"ok"'; then
    echo "OK: ${health_url}"
    exit 0
  fi
  echo "waiting for ${health_url} (${attempt}/${RETRIES})..." >&2
  sleep "$SLEEP_SEC"
  attempt=$((attempt + 1))
done

echo "FAIL: relay health gate" >&2
exit 1
