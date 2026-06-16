#!/usr/bin/env bash
# Static policy gate: production deploy workflows must NOT reference long-lived
# service account JSON keys or FIREBASE_TOKEN fallbacks (codex-gpt-5 FINDING-007).
set -euo pipefail
cd "$(dirname "$0")/../.."

WORKFLOWS=(
  ".github/workflows/deploy-production.yml"
  ".github/workflows/deploy-hosting.yml"
  ".github/workflows/deploy-firestore.yml"
)
FAIL=0

for workflow in "${WORKFLOWS[@]}"; do
  if grep -E 'GCP_SA_KEY|GOOGLE_PLAY_SERVICE_ACCOUNT_JSON|FIREBASE_TOKEN|credentials_json' "$workflow" >/dev/null; then
    echo "FAIL: $workflow still references legacy long-lived deploy secrets or credentials_json."
    echo "  Remove GCP_SA_KEY, GOOGLE_PLAY_SERVICE_ACCOUNT_JSON, FIREBASE_TOKEN,"
    echo "  and credentials_json fallbacks; use WIF/OIDC with"
    echo "  GCP_WORKLOAD_IDENTITY_PROVIDER + GCP_DEPLOY_SERVICE_ACCOUNT only."
    FAIL=1
  else
    echo "PASS: $workflow uses WIF/OIDC only (no legacy deploy secrets)."
  fi

  for required in \
    "id-token: write" \
    "workload_identity_provider" \
    "GCP_WORKLOAD_IDENTITY_PROVIDER" \
    "GCP_DEPLOY_SERVICE_ACCOUNT" \
    "GOOGLE_APPLICATION_CREDENTIALS"
  do
    if ! grep -q "$required" "$workflow"; then
      echo "FAIL: $workflow does not contain required WIF marker: $required"
      FAIL=1
    fi
  done
done

exit "$FAIL"
