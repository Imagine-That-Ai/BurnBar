#!/bin/sh

set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
plist_path="$repo_root/AgentLens/Resources/GoogleService-Info.plist"
marker_path="$repo_root/AgentLens/Resources/.firebase-ci-injected"
export PLIST_PATH="$plist_path"
export MARKER_PATH="$marker_path"

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

plist_path = Path(os.environ["PLIST_PATH"])
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

plist_path.parent.mkdir(parents=True, exist_ok=True)
plist_path.write_bytes(decoded)
Path(os.environ["MARKER_PATH"]).write_text("ci\n", encoding="utf-8")
PY

/usr/libexec/PlistBuddy -c "Delete :FirebaseAppCheckDebugToken" "$plist_path" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :FirebaseAppCheckDebugToken string $FIREBASE_APP_CHECK_DEBUG_TOKEN" "$plist_path"

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "FIRAAppCheckDebugToken=$FIREBASE_APP_CHECK_DEBUG_TOKEN"
        echo "FIREBASE_APP_CHECK_DEBUG_TOKEN=$FIREBASE_APP_CHECK_DEBUG_TOKEN"
    } >> "$GITHUB_ENV"
fi

echo "Firebase config injected at AgentLens/Resources/GoogleService-Info.plist"
echo "Validated keys: GOOGLE_APP_ID, PROJECT_ID, REVERSED_CLIENT_ID"
echo "App Check debug token configured for CI runtime"
