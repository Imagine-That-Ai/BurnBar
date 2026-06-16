#!/usr/bin/env bash
# Static policy gate: production deploy workflows must NOT reference long-lived
# service account JSON keys or FIREBASE_TOKEN fallbacks (codex-gpt-5 FINDING-007).
set -euo pipefail
cd "$(dirname "$0")/../.."

WORKFLOW=".github/workflows/deploy-production.yml"
FAIL=0

if grep -E 'GCP_SA_KEY|GOOGLE_PLAY_SERVICE_ACCOUNT_JSON|FIREBASE_TOKEN' "$WORKFLOW" >/dev/null; then
  echo "✗ $WORKFLOW still references legacy long-lived deploy secrets."
  echo "  Remove GCP_SA_KEY, GOOGLE_PLAY_SERVICE_ACCOUNT_JSON, and FIREBASE_TOKEN"
  echo "  fallbacks; use WIF/OIDC with GCP_WORKLOAD_IDENTITY_PROVIDER +"
  echo "  GCP_DEPLOY_SERVICE_ACCOUNT only."
  FAIL=1
else
  echo "✓ $WORKFLOW uses WIF/OIDC only (no legacy deploy secrets)."
fi

if ! grep -q 'workload_identity_provider' "$WORKFLOW"; then
  echo "✗ $WORKFLOW does not configure workload_identity_provider."
  FAIL=1
fi

exit "$FAIL"
