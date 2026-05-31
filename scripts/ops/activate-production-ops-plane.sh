#!/usr/bin/env bash
# Idempotent activation of GCP log metrics + ops alert policies (production).
set -euo pipefail
cd "$(dirname "$0")/../.."

export GCLOUD_PROJECT="${GCLOUD_PROJECT:-${GOOGLE_CLOUD_PROJECT:-burnbar}}"
export GOOGLE_CLOUD_PROJECT="$GCLOUD_PROJECT"

if [[ -z "${OPS_ALERT_CHANNELS:-}" ]]; then
  echo "Set OPS_ALERT_CHANNELS to comma-separated Monitoring notification channel resource names." >&2
  exit 1
fi

echo "==> create-ops-log-metrics (project=${GCLOUD_PROJECT})"
node functions/scripts/create-ops-log-metrics.mjs

echo "==> apply-ops-alert-policies"
node functions/scripts/apply-ops-alert-policies.mjs

echo "==> verify policies present"
gcloud monitoring policies list --project="$GCLOUD_PROJECT" --format='table(displayName,enabled)'

echo "==> check-ops-alerts"
node scripts/ops/check-ops-alerts.mjs

echo "PASS: production ops plane activated"
