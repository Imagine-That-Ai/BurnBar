#!/bin/sh
# Mirror of inject-firebase-config.sh for the Android google-services.json.
# Expects GOOGLE_SERVICES_JSON_BASE64 in the environment (a GitHub secret).
set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
json_path="$repo_root/android/app/google-services.json"
marker_path="$repo_root/android/app/.firebase-ci-injected"
export JSON_PATH="$json_path"
export MARKER_PATH="$marker_path"

if [ -z "${GOOGLE_SERVICES_JSON_BASE64:-}" ]; then
    echo "::error::GOOGLE_SERVICES_JSON_BASE64 is required."
    exit 1
fi

umask 077

python3 - <<'PY'
import base64
import json
import os
from pathlib import Path

json_path = Path(os.environ["JSON_PATH"])
encoded = os.environ["GOOGLE_SERVICES_JSON_BASE64"]

try:
    decoded = base64.b64decode(encoded, validate=True)
except Exception as exc:
    raise SystemExit(f"::error::Unable to decode GOOGLE_SERVICES_JSON_BASE64: {exc}")

try:
    payload = json.loads(decoded)
except Exception as exc:
    raise SystemExit(f"::error::Decoded google-services.json is invalid: {exc}")

# Validate critical keys
client = payload.get("client", [{}])[0]
project_info = payload.get("project_info", {})
proj_id = str(project_info.get("project_id", "")).strip()
app_id  = str(client.get("client_info", {}).get("mobilesdk_app_id", "")).strip()
api_key = str((client.get("api_key", [{}]) or [{}])[0].get("current_key", "")).strip()

placeholder_prefixes = ("YOUR_", "REPLACE_", "EXAMPLE_", "PLACEHOLDER")
missing = []

if not proj_id or any(proj_id.startswith(p) for p in placeholder_prefixes):
    missing.append("project_id")
if not app_id or any(app_id.startswith(p) for p in placeholder_prefixes):
    missing.append("mobilesdk_app_id")
if not api_key or any(api_key.startswith(p) for p in placeholder_prefixes):
    missing.append("api_key")

if missing:
    raise SystemExit(
        "::error::google-services.json is missing required non-placeholder keys: "
        + ", ".join(missing)
    )

json_path.parent.mkdir(parents=True, exist_ok=True)
json_path.write_bytes(decoded)
Path(os.environ["MARKER_PATH"]).write_text("ci\n", encoding="utf-8")
PY

echo "Firebase Android config injected at $json_path"
echo "Validated keys: project_id, mobilesdk_app_id, api_key"
