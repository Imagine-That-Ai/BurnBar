#!/bin/sh
# Mirror of inject-firebase-config.sh for the Android google-services.json.
# Expects GOOGLE_SERVICES_JSON_BASE64 in the environment (a GitHub secret).
set -eu

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
json_path="$repo_root/android/app/google-services.json"
marker_path="$repo_root/android/app/.firebase-ci-injected"

if [ -z "${GOOGLE_SERVICES_JSON_BASE64:-}" ]; then
    echo "::error::GOOGLE_SERVICES_JSON_BASE64 is required."
    exit 1
fi

umask 077

strict_args=""
case "${OPENBURNBAR_ANDROID_FIREBASE_STRICT:-}" in
    1|true|TRUE|yes|YES)
        strict_args="--strict-release"
        ;;
esac

node "$repo_root/scripts/ci/verify-android-firebase-release-config.mjs" \
    --config "$json_path" \
    --write-from-base64-env GOOGLE_SERVICES_JSON_BASE64 \
    --marker "$marker_path" \
    $strict_args

echo "Firebase Android config injected at $json_path"
