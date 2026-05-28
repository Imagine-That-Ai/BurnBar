#!/usr/bin/env bash
# Verify Firebase App Check enforcement for Firestore on internal CI runs.
# Requires injected GoogleService-Info.plist (FIREBASE_PLIST_BASE64) and gcloud auth.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if [[ "${INTERNAL_RUN:-}" != "true" ]]; then
  echo "Skipping App Check smoke — not an internal CI run."
  exit 0
fi

if [[ ! -f AgentLens/Resources/GoogleService-Info.plist ]]; then
  echo "Skipping App Check smoke — no injected Firebase plist."
  exit 0
fi

PROJECT="${OPENBURNBAR_FIREBASE_PROJECT:-}"
if [[ -z "$PROJECT" ]]; then
  PROJECT="$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' AgentLens/Resources/GoogleService-Info.plist 2>/dev/null || true)"
fi
if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Could not resolve Firebase project id from OPENBURNBAR_FIREBASE_PROJECT or injected plist." >&2
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: gcloud is required for App Check ENFORCED verification on internal runs." >&2
  exit 1
fi

project_number="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
if [[ -z "$project_number" ]]; then
  echo "ERROR: Could not resolve Firebase project number for ${PROJECT}." >&2
  exit 1
fi

access_token="$(gcloud auth print-access-token 2>/dev/null || true)"
if [[ -z "$access_token" ]]; then
  echo "ERROR: gcloud auth print-access-token failed; App Check probe requires credentials." >&2
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

if [[ "$enforcement_mode" != "ENFORCED" ]]; then
  echo "ERROR: Firestore App Check enforcementMode=${enforcement_mode:-<unset>} (expected ENFORCED)." >&2
  echo "Configure enforcement in Firebase Console → App Check → Firestore before shipping." >&2
  exit 1
fi

echo "App Check smoke: Firestore enforcementMode=ENFORCED for project ${PROJECT}."
