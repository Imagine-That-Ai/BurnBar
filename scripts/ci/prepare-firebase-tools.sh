#!/usr/bin/env bash
# Install the repository-pinned Firebase CLI before any production Google auth.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" || -n "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]]; then
  echo "::error::prepare-firebase-tools.sh must run before Google/Firebase credentials are present." >&2
  exit 1
fi

npm ci --prefix functions --ignore-scripts

FIREBASE_TOOLS_BIN="$PWD/functions/node_modules/.bin/firebase"
if [[ ! -x "$FIREBASE_TOOLS_BIN" ]]; then
  echo "::error::Pinned Firebase CLI was not installed at $FIREBASE_TOOLS_BIN" >&2
  exit 1
fi

node scripts/ci/verify-firebase-tools-runtime.mjs \
  "$PWD/functions/node_modules/firebase-tools/package.json"

FIREBASE_TOOLS_VERSION="$("$FIREBASE_TOOLS_BIN" --version)"
if [[ -z "$FIREBASE_TOOLS_VERSION" ]]; then
  echo "::error::Pinned Firebase CLI did not report a version." >&2
  exit 1
fi

echo "FIREBASE_TOOLS_BIN=$FIREBASE_TOOLS_BIN"
echo "FIREBASE_TOOLS_VERSION=$FIREBASE_TOOLS_VERSION"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "FIREBASE_TOOLS_BIN=$FIREBASE_TOOLS_BIN"
    echo "FIREBASE_TOOLS_VERSION=$FIREBASE_TOOLS_VERSION"
  } >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "firebase_tools_bin=$FIREBASE_TOOLS_BIN"
    echo "firebase_tools_version=$FIREBASE_TOOLS_VERSION"
  } >> "$GITHUB_OUTPUT"
fi
