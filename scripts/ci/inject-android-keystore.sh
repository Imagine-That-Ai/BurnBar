#!/bin/sh
# Injects the Android release upload keystore from a base64-encoded GitHub secret.
# Expects OPENBURNBAR_ANDROID_KEYSTORE_BASE64 in the environment.
set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
keystore_dir="$repo_root/.secrets/android"
keystore_path="$keystore_dir/upload-keystore.jks"
marker_path="$keystore_dir/.keystore-ci-injected"
export KEYSTORE_PATH="$keystore_path"
export MARKER_PATH="$marker_path"

if [ -z "${OPENBURNBAR_ANDROID_KEYSTORE_BASE64:-}" ]; then
    echo "::error::OPENBURNBAR_ANDROID_KEYSTORE_BASE64 is required."
    exit 1
fi

umask 077

python3 - <<'PY'
import base64
import os
from pathlib import Path

keystore_path = Path(os.environ["KEYSTORE_PATH"])
encoded = os.environ["OPENBURNBAR_ANDROID_KEYSTORE_BASE64"]

try:
    decoded = base64.b64decode(encoded, validate=True)
except Exception as exc:
    raise SystemExit(f"::error::Unable to decode OPENBURNBAR_ANDROID_KEYSTORE_BASE64: {exc}")

# Minimal validation: keystore files start with a magic sequence
if decoded[:4] != b"\xFE\xED\xFE\xED":
    raise SystemExit("::error::Decoded keystore does not appear to be a valid JKS file.")

keystore_path.parent.mkdir(parents=True, exist_ok=True)
keystore_path.write_bytes(decoded)
Path(os.environ["MARKER_PATH"]).write_text("ci\n", encoding="utf-8")
PY

echo "Android release keystore injected at $keystore_path"
