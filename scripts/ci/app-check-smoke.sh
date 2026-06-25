#!/usr/bin/env bash
# Verify Firebase App Check enforcement for Firestore and Storage on internal CI runs.
# Requires injected GoogleService-Info.plist (FIREBASE_PLIST_BASE64) and gcloud auth.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if [[ "${INTERNAL_RUN:-}" != "true" ]]; then
  echo "Skipping App Check smoke — not an internal CI run."
  exit 0
fi

PROJECT="${OPENBURNBAR_FIREBASE_PROJECT:-}"
if [[ -z "$PROJECT" && -f AgentLens/Resources/GoogleService-Info.plist ]]; then
  PROJECT="$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' AgentLens/Resources/GoogleService-Info.plist 2>/dev/null || true)"
fi
if [[ -z "$PROJECT" && ! -f AgentLens/Resources/GoogleService-Info.plist ]]; then
  echo "ERROR: App Check smoke is running as an internal CI gate, but no OPENBURNBAR_FIREBASE_PROJECT or injected Firebase plist is available." >&2
  exit 1
fi
if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Could not resolve Firebase project id from OPENBURNBAR_FIREBASE_PROJECT or injected plist." >&2
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: App Check smoke is running as an internal CI gate, but gcloud is unavailable." >&2
  echo "Install or configure gcloud so the live App Check enforcement probe can run fail-closed." >&2
  exit 1
fi

OPENBURNBAR_FIREBASE_PROJECT="$PROJECT" scripts/ops/verify-firestore-app-check-enforcement.sh
echo "App Check smoke: Firestore and Storage enforcementMode=ENFORCED for project ${PROJECT}."
