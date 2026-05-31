#!/usr/bin/env bash
# Injects the Sentry DSN for the VS Code / Cursor extension into the source
# before tsc compiles it.  The placeholder '__SENTRY_DSN__' in sentry.ts is
# replaced with the real ingest URL so the DSN is baked into the compiled
# bundle (safe — Sentry DSNs are public ingest endpoints, not secrets).
#
# Usage:
#   Called by release.yml before "npm run build --prefix extensions/openburnbar"
#     BURNBAR_EXTENSION_SENTRY_DSN=${{ secrets.BURNBAR_EXTENSION_SENTRY_DSN }} \
#     bash scripts/ci/inject-sentry-config-extension.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

TARGET="extensions/openburnbar/src/telemetry/sentry.ts"
DSN="${BURNBAR_EXTENSION_SENTRY_DSN:-}"

if [[ -z "$DSN" ]]; then
  echo "::notice::BURNBAR_EXTENSION_SENTRY_DSN not set — extension Sentry DSN will not be baked in."
  exit 0
fi

# Validate it looks like a Sentry DSN.
if [[ "$DSN" != https://* ]]; then
  echo "::error::BURNBAR_EXTENSION_SENTRY_DSN does not look like a valid Sentry DSN (expected https://)."
  exit 1
fi

# Replace the placeholder.  Use a delimiter other than / to avoid escaping.
sed -i.bak "s|__SENTRY_DSN__|${DSN}|g" "$TARGET"
rm -f "${TARGET}.bak"

echo "::notice::Extension Sentry DSN injected into ${TARGET}."
