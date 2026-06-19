#!/usr/bin/env bash
# Injects the Amplitude ingestion API key into the macOS/iOS app source before
# Xcode compiles it. The placeholder '__AMPLITUDE_API_KEY__' in
# AgentLens/Services/Analytics/AnalyticsConfig.swift is replaced with the real
# key so it is baked into the compiled binary.
#
# Amplitude client-side keys are write-only ingestion identifiers (like a Sentry
# DSN), not secrets — but we still NEVER commit one. CI sets the env var per
# build configuration so dev/staging builds get the dev key and production builds
# get the production key (separate Amplitude projects).
#
# Usage (CI, before xcodebuild):
#   BURNBAR_AMPLITUDE_API_KEY=${{ secrets.BURNBAR_AMPLITUDE_API_KEY_PROD }} \
#     bash scripts/ci/inject-amplitude-config.sh
#
# If the env var is unset the placeholder is left in place: AnalyticsConfig
# returns nil and the wrapper never initializes the SDK (analytics stays dark),
# so unkeyed local/dev builds are safe.
set -euo pipefail
cd "$(dirname "$0")/../.."

TARGET="AgentLens/Services/Analytics/AnalyticsConfig.swift"
KEY="${BURNBAR_AMPLITUDE_API_KEY:-}"

if [[ -z "$KEY" ]]; then
  echo "::notice::BURNBAR_AMPLITUDE_API_KEY not set — Amplitude key not baked in (analytics stays dark)."
  exit 0
fi

if [[ ! -f "$TARGET" ]]; then
  echo "::error::$TARGET not found — cannot inject Amplitude key."
  exit 1
fi

# Reject obviously-wrong values (must look like an Amplitude key, no whitespace).
if [[ "$KEY" =~ [[:space:]] ]] || [[ ${#KEY} -lt 16 ]]; then
  echo "::error::BURNBAR_AMPLITUDE_API_KEY does not look like a valid Amplitude key."
  exit 1
fi

# Replace the placeholder. Use a delimiter other than / to avoid escaping.
sed -i.bak "s|__AMPLITUDE_API_KEY__|${KEY}|g" "$TARGET"
rm -f "${TARGET}.bak"

echo "::notice::Amplitude API key injected into ${TARGET}."
