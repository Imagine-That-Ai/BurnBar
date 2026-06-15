#!/bin/sh

set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
plist_paths="$repo_root/AgentLens/Resources/GoogleService-Info.plist:$repo_root/OpenBurnBarMobile/Resources/GoogleService-Info.plist"
marker_paths="$repo_root/AgentLens/Resources/.firebase-ci-injected:$repo_root/OpenBurnBarMobile/Resources/.firebase-ci-injected"
export PLIST_PATHS="$plist_paths"
export MARKER_PATHS="$marker_paths"

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

plist_paths = [Path(path) for path in os.environ["PLIST_PATHS"].split(":") if path]
marker_paths = [Path(path) for path in os.environ["MARKER_PATHS"].split(":") if path]
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

for plist_path in plist_paths:
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    plist_path.write_bytes(decoded)

for marker_path in marker_paths:
    marker_path.parent.mkdir(parents=True, exist_ok=True)
    marker_path.write_text("ci\n", encoding="utf-8")
PY

old_ifs="$IFS"
IFS=:
for plist_path in $plist_paths; do
    /usr/libexec/PlistBuddy -c "Delete :FirebaseAppCheckDebugToken" "$plist_path" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :FirebaseAppCheckDebugToken string $FIREBASE_APP_CHECK_DEBUG_TOKEN" "$plist_path"
    if [ -n "${OPENBURNBAR_SENTRY_DSN:-}" ]; then
        /usr/libexec/PlistBuddy -c "Delete :sentry.dsn" "$plist_path" >/dev/null 2>&1 || true
        /usr/libexec/PlistBuddy -c "Add :sentry.dsn string $OPENBURNBAR_SENTRY_DSN" "$plist_path"
    fi
done
IFS="$old_ifs"

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "FIRAAppCheckDebugToken=$FIREBASE_APP_CHECK_DEBUG_TOKEN"
        echo "FIREBASE_APP_CHECK_DEBUG_TOKEN=$FIREBASE_APP_CHECK_DEBUG_TOKEN"
    } >> "$GITHUB_ENV"
fi

echo "Firebase config injected at:"
echo "  AgentLens/Resources/GoogleService-Info.plist"
echo "  OpenBurnBarMobile/Resources/GoogleService-Info.plist"
echo "Validated keys: GOOGLE_APP_ID, PROJECT_ID, REVERSED_CLIENT_ID"
echo "App Check debug token configured for CI runtime"
if [ -n "${OPENBURNBAR_SENTRY_DSN:-}" ]; then
    echo "Sentry DSN configured for app runtime"
fi
