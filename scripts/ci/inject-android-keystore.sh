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

# Android upload keystores may be JKS (legacy) or PKCS12 (JDK 9+ default).
# JKS starts with feedfeed; PKCS12 is DER encoded and starts as an ASN.1
# sequence. Password/alias validation below provides the stronger check when
# release signing env vars are present.
is_jks = decoded[:4] == b"\xFE\xED\xFE\xED"
is_pkcs12_candidate = decoded[:1] == b"\x30"
if not (is_jks or is_pkcs12_candidate):
    raise SystemExit("::error::Decoded keystore is neither JKS nor a PKCS12 candidate.")

keystore_path.parent.mkdir(parents=True, exist_ok=True)
keystore_path.write_bytes(decoded)
Path(os.environ["MARKER_PATH"]).write_text("ci\n", encoding="utf-8")
PY

if command -v keytool >/dev/null 2>&1 && [ -n "${OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD:-}" ]; then
    if ! keytool -list \
        -keystore "$keystore_path" \
        -storepass "$OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD" \
        >/dev/null 2>&1; then
        echo "::error::Decoded Android keystore could not be opened with OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD."
        rm -f "$keystore_path" "$marker_path"
        exit 1
    fi

    if [ -n "${OPENBURNBAR_ANDROID_KEY_ALIAS:-}" ] &&
       ! keytool -list \
        -keystore "$keystore_path" \
        -storepass "$OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD" \
        -alias "$OPENBURNBAR_ANDROID_KEY_ALIAS" \
        >/dev/null 2>&1; then
        echo "::error::Decoded Android keystore does not contain OPENBURNBAR_ANDROID_KEY_ALIAS."
        rm -f "$keystore_path" "$marker_path"
        exit 1
    fi

    echo "Validated Android release keystore with keytool."
fi

echo "Android release keystore injected at $keystore_path"
