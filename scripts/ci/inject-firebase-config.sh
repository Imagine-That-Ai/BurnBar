#!/bin/sh

set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
agent_plist_path="$repo_root/AgentLens/Resources/GoogleService-Info.plist"
agent_marker_path="$repo_root/AgentLens/Resources/.firebase-ci-injected"
mobile_plist_path="$repo_root/OpenBurnBarMobile/Resources/GoogleService-Info.plist"
mobile_marker_path="$repo_root/OpenBurnBarMobile/Resources/.firebase-ci-injected"
export AGENT_PLIST_PATH="$agent_plist_path"
export AGENT_MARKER_PATH="$agent_marker_path"
export MOBILE_PLIST_PATH="$mobile_plist_path"
export MOBILE_MARKER_PATH="$mobile_marker_path"

if [ -z "${FIREBASE_PLIST_BASE64:-}" ]; then
    echo "::error::FIREBASE_PLIST_BASE64 is required."
    exit 1
fi

if [ -z "${FIREBASE_APP_CHECK_DEBUG_TOKEN:-}" ]; then
    echo "::error::FIREBASE_APP_CHECK_DEBUG_TOKEN is required."
    exit 1
fi

umask 077

python3 - <<'PY'
import base64
import os
import plistlib
from pathlib import Path

agent_plist_path = Path(os.environ["AGENT_PLIST_PATH"])
agent_marker_path = Path(os.environ["AGENT_MARKER_PATH"])
mobile_plist_path = Path(os.environ["MOBILE_PLIST_PATH"])
mobile_marker_path = Path(os.environ["MOBILE_MARKER_PATH"])
encoded = os.environ["FIREBASE_PLIST_BASE64"]

try:
    decoded = base64.b64decode(encoded, validate=True)
except Exception as exc:  # pragma: no cover - defensive
    raise SystemExit(f"::error::Unable to decode FIREBASE_PLIST_BASE64: {exc}")

try:
    payload = plistlib.loads(decoded)
except Exception as exc:  # pragma: no cover - defensive
    raise SystemExit(f"::error::Decoded Firebase plist is invalid: {exc}")

required_keys = ("GOOGLE_APP_ID", "PROJECT_ID", "REVERSED_CLIENT_ID")
placeholder_prefixes = ("YOUR_", "REPLACE_", "EXAMPLE_")
missing = []

for key in required_keys:
    value = str(payload.get(key, "")).strip()
    if not value or any(value.startswith(prefix) for prefix in placeholder_prefixes):
        missing.append(key)

if missing:
    raise SystemExit(
        "::error::Firebase plist is missing required non-placeholder keys: "
        + ", ".join(missing)
    )

for plist_path, marker_path in (
    (agent_plist_path, agent_marker_path),
    (mobile_plist_path, mobile_marker_path),
):
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    plist_path.write_bytes(decoded)
    marker_path.write_text("ci\n", encoding="utf-8")
PY

for plist_path in "$agent_plist_path" "$mobile_plist_path"; do
    /usr/libexec/PlistBuddy -c "Delete :FirebaseAppCheckDebugToken" "$plist_path" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :FirebaseAppCheckDebugToken string $FIREBASE_APP_CHECK_DEBUG_TOKEN" "$plist_path"
done

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "FIRAAppCheckDebugToken=$FIREBASE_APP_CHECK_DEBUG_TOKEN"
        echo "FIREBASE_APP_CHECK_DEBUG_TOKEN=$FIREBASE_APP_CHECK_DEBUG_TOKEN"
    } >> "$GITHUB_ENV"
fi

echo "Firebase config injected at AgentLens/Resources/GoogleService-Info.plist"
echo "Firebase config injected at OpenBurnBarMobile/Resources/GoogleService-Info.plist"
echo "Validated keys: GOOGLE_APP_ID, PROJECT_ID, REVERSED_CLIENT_ID"
echo "App Check debug token configured for CI runtime"
