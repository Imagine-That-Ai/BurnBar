#!/usr/bin/env bash
# Injects the Sentry Android DSN into the build environment.
#
# The Sentry DSN is an ingest endpoint (not a secret in the traditional sense,
# but kept out of git to allow rotating it without a code change).
#
# Usage:
#   Called by CI before running the Android build:
#     bash scripts/ci/inject-sentry-config-android.sh
#
# Required environment variable:
#   ANDROID_SENTRY_DSN   — Sentry ingest DSN for the openburnbar-android project
#                          (set as a GitHub Actions secret)
#
# What this does:
#   Exports OPENBURNBAR_ANDROID_SENTRY_DSN so Gradle's manifestPlaceholders
#   picks it up from defaultConfig in app/build.gradle.kts.
#   When the variable is absent or empty, Sentry is disabled (no-op DSN).
set -euo pipefail
cd "$(dirname "$0")/../.."

DSN="${ANDROID_SENTRY_DSN:-}"

if [[ -z "$DSN" ]]; then
  echo "::notice::ANDROID_SENTRY_DSN not set — Android Sentry will be disabled in this build."
  export OPENBURNBAR_ANDROID_SENTRY_DSN=""
else
  DSN="$(ANDROID_SENTRY_DSN="$DSN" python3 scripts/ci/sentry_dsn.py validate ANDROID_SENTRY_DSN)"
  echo "::notice::Sentry DSN configured for Android build."
  export OPENBURNBAR_ANDROID_SENTRY_DSN="$DSN"
fi

# Write to GITHUB_ENV so subsequent workflow steps inherit the variable.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  if [[ -z "$OPENBURNBAR_ANDROID_SENTRY_DSN" ]]; then
    printf 'OPENBURNBAR_ANDROID_SENTRY_DSN=\n' >> "$GITHUB_ENV"
  else
    delimiter="OPENBURNBAR_ANDROID_SENTRY_DSN_$(python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
)"
    {
      printf 'OPENBURNBAR_ANDROID_SENTRY_DSN<<%s\n' "$delimiter"
      printf '%s\n' "$OPENBURNBAR_ANDROID_SENTRY_DSN"
      printf '%s\n' "$delimiter"
    } >> "$GITHUB_ENV"
  fi
fi
