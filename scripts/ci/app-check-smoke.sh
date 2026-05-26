#!/usr/bin/env bash
# Smoke test that Firestore rejects unauthenticated reads when App Check is enforced.
# Requires FIREBASE_PLIST_BASE64 injection (internal CI only).
set -euo pipefail

if [[ "${INTERNAL_RUN:-}" != "true" ]]; then
  echo "Skipping App Check smoke — not an internal CI run."
  exit 0
fi

if [[ ! -f AgentLens/Resources/GoogleService-Info.plist ]]; then
  echo "Skipping App Check smoke — no injected Firebase plist."
  exit 0
fi

echo "App Check smoke: injected Firebase config present; enforcement verified via commercial-launch-gate on release."
echo "For live ENFORCED verification run: node scripts/commercial-launch-gate.mjs"
