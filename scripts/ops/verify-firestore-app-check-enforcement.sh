#!/usr/bin/env bash
# Verify Firebase App Check enforcement for Cloud Firestore and Firebase Storage
# in the production project. Fails closed when any required service is off or
# cannot be determined.
#
# Requires gcloud auth (or GOOGLE_APPLICATION_CREDENTIALS) and either
# GCLOUD_PROJECT / GOOGLE_CLOUD_PROJECT / OPENBURNBAR_FIREBASE_PROJECT.
#
set -euo pipefail

cd "$(dirname "$0")/../.."

# shellcheck source=scripts/lib/curl-bearer.sh
source scripts/lib/curl-bearer.sh

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

DEFAULT_SERVICES="firestore.googleapis.com,firebasestorage.googleapis.com"
IFS=',' read -r -a requested_services <<< "${FIREBASE_APP_CHECK_SERVICES:-$DEFAULT_SERVICES}"
services=()
for raw_service in "${requested_services[@]}"; do
  # Strip leading/trailing whitespace via bash parameter expansion (no subprocess).
  service="${raw_service#"${raw_service%%[![:space:]]*}"}"
  service="${service%"${service##*[![:space:]]}"}"
  if [[ -n "$service" ]]; then
    services+=("$service")
  fi
done

if [[ "${#services[@]}" -eq 0 ]]; then
  echo "ERROR: No Firebase App Check services requested." >&2
  exit 1
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
failed=0

for service in "${services[@]}"; do
  service_name="projects/${project_number}/services/${service}"
  response="$(obb_curl_with_bearer_user_project \
    "${access_token}" \
    "${PROJECT}" \
    -fsS \
    "https://firebaseappcheck.googleapis.com/v1beta/${service_name}" 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    echo "ERROR: Firebase App Check API request failed for ${service_name}." >&2
    failed=1
    continue
  fi

  enforcement_mode="$(python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(payload.get("enforcementMode") or "")
' <<< "$response" 2>/dev/null || true)"

  printf '%s\0%s\0%s\0%s\0' "$PROJECT" "$service" "${enforcement_mode:-}" "$timestamp" \
    | python3 -c '
import json, sys
project, service, mode, ts = sys.stdin.read().split("\0")[:4]
print(json.dumps({
    "project": project,
    "service": service,
    "enforcementMode": mode or "<unset>",
    "verifiedAt": ts,
}, separators=(",", ":")))
'

  if [[ "$enforcement_mode" != "ENFORCED" ]]; then
    echo "ERROR: ${service} App Check enforcementMode=${enforcement_mode:-<unset>} (expected ENFORCED)." >&2
    echo "Configure enforcement in Firebase Console → App Check → APIs before shipping." >&2
    failed=1
  else
    echo "PASS: ${service} App Check enforcementMode=ENFORCED for project ${PROJECT}."
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
