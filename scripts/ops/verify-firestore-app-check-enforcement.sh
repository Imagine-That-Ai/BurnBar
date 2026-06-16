#!/usr/bin/env bash
# Verify Firebase App Check enforcement for Cloud Firestore in the production
# project. Fails closed when the state is off or cannot be determined.
#
# Requires gcloud auth (or GOOGLE_APPLICATION_CREDENTIALS) and either
# GCLOUD_PROJECT / GOOGLE_CLOUD_PROJECT / OPENBURNBAR_FIREBASE_PROJECT.
#
# Closes codex-gpt-5 FINDING-004 / kimi FINDING-005.
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="${GCLOUD_PROJECT:-${GOOGLE_CLOUD_PROJECT:-${OPENBURNBAR_FIREBASE_PROJECT:-}}}"
if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Set GCLOUD_PROJECT, GOOGLE_CLOUD_PROJECT, or OPENBURNBAR_FIREBASE_PROJECT." >&2
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: gcloud is required for App Check enforcement verification." >&2
  exit 1
fi

project_number="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
if [[ -z "$project_number" ]]; then
  echo "ERROR: Could not resolve project number for ${PROJECT}." >&2
  exit 1
fi

access_token="$(gcloud auth print-access-token 2>/dev/null || true)"
if [[ -z "$access_token" ]]; then
  echo "ERROR: gcloud auth print-access-token failed." >&2
  exit 1
fi

service_name="projects/${project_number}/services/firestore.googleapis.com"
response="$(curl -fsS \
  -H "Authorization: Bearer ${access_token}" \
  -H "x-goog-user-project: ${PROJECT}" \
  "https://firebaseappcheck.googleapis.com/v1beta/${service_name}" 2>/dev/null || true)"

if [[ -z "$response" ]]; then
  echo "ERROR: Firebase App Check API request failed for ${service_name}." >&2
  exit 1
fi

enforcement_mode="$(python3 - <<'PY' "$response"
import json, sys
payload = json.loads(sys.argv[1])
print(payload.get("enforcementMode") or "")
PY
)"

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "{\"project\":\"${PROJECT}\",\"service\":\"firestore.googleapis.com\",\"enforcementMode\":\"${enforcement_mode:-<unset>}\",\"verifiedAt\":\"${timestamp}\"}"

if [[ "$enforcement_mode" != "ENFORCED" ]]; then
  echo "ERROR: Firestore App Check enforcementMode=${enforcement_mode:-<unset>} (expected ENFORCED)." >&2
  echo "Configure enforcement in Firebase Console → App Check → Firestore before shipping." >&2
  exit 1
fi

echo "PASS: Firestore App Check enforcementMode=ENFORCED for project ${PROJECT}."
