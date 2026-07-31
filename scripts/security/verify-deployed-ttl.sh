#!/usr/bin/env bash
#
# verify-deployed-ttl.sh — Programmatically verify deployed Firestore TTL policies.
#
# This script inspects the live Firestore project configuration via gcloud and
# asserts that the required TTL policies are deployed and ACTIVE.
#
# Usage:
#   ./scripts/security/verify-deployed-ttl.sh [project_id]
#

set -euo pipefail

# 1. Resolve Project ID
PROJECT_ID="${1:-}"
if [ -z "$PROJECT_ID" ]; then
    # Fallback to .firebaserc default project
    DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    if [ -f "$DIR/.firebaserc" ]; then
        PROJECT_ID=$(python3 -c "import json; print(json.load(open('$DIR/.firebaserc'))['projects']['default'])" 2>/dev/null || true)
    fi
fi

if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID="burnbar"
fi

echo "======================================================================"
echo "Firestore TTL Deployment Verification — Project: $PROJECT_ID"
echo "======================================================================"

# 2. Check for gcloud CLI
if ! command -v gcloud &>/dev/null; then
    echo "::error::gcloud CLI is not installed. Cannot verify live deployed TTL status."
    echo "Install Google Cloud SDK and log in first:"
    echo "  brew install --cask google-cloud-sdk"
    echo "  gcloud auth login"
    exit 1
fi

# 3. Query deployed TTL configurations
echo "Querying Google Cloud Firestore field configurations..."
RAW_TTL_JSON=$(gcloud firestore fields ttls list --project="$PROJECT_ID" --format="json" 2>/dev/null || true)

if [ -z "$RAW_TTL_JSON" ] || [ "$RAW_TTL_JSON" == "[]" ]; then
    echo "::error::No deployed TTL configurations found or project is inaccessible."
    echo "Make sure you are logged in and have permissions on the project: $PROJECT_ID"
    echo "  gcloud auth login"
    exit 1
fi

# 4. Define required collection fields that must have ACTIVE TTL
REQUIRED_TTLS=(
    "voip_outbound/fields/expireAt"
    "fcm_outbound/fields/expireAt"
    "agent_notification_events/fields/expireAt"
    "google_play_rtdn_events/fields/expireAt"
)

FAILED_CHECKS=0
echo ""
echo "Verifying TTL States:"
echo "----------------------------------------------------------------------"

for target in "${REQUIRED_TTLS[@]}"; do
    # Extract state using inline python to avoid jq dependency on CI/dev machines
    STATE=$(python3 -c "
import sys, json
data = json.load(sys.stdin)
target = sys.argv[1]
found = [x for x in data if target in x.get('name', '')]
if found:
    print(found[0].get('state', 'UNKNOWN'))
else:
    print('MISSING')
" "$target" <<< "$RAW_TTL_JSON")

    if [ "$STATE" == "ACTIVE" ]; then
        echo "  [PASS] $target: $STATE"
    else
        echo "  [FAIL] $target: $STATE (Expected: ACTIVE)"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
done

echo "----------------------------------------------------------------------"
if [ "$FAILED_CHECKS" -eq 0 ]; then
    echo "SUCCESS: All required Firestore TTL policies are deployed and ACTIVE."
    exit 0
else
    echo "FAILURE: $FAILED_CHECKS critical TTL policies are missing or not active."
    echo "To deploy the indexes and TTL overrides, run:"
    echo "  firebase deploy --only firestore:indexes"
    exit 1
fi
