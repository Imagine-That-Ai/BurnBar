#!/usr/bin/env bash
# Install the repository-pinned Firebase CLI before any production Google auth.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" || -n "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]]; then
  echo "::error::prepare-firebase-tools.sh must run before Google/Firebase credentials are present." >&2
  exit 1
fi

BRACE_EXPANSION_SOURCE="$PWD/functions/vendor/openburnbar/brace-expansion-cjs"
BRACE_EXPANSION_TARBALL="$PWD/functions/vendor/openburnbar/brace-expansion-cjs.tgz"
BRACE_EXPANSION_PACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-brace-expansion.XXXXXX")"
trap 'rm -rf "$BRACE_EXPANSION_PACK_DIR"' EXIT
npm pack "$BRACE_EXPANSION_SOURCE" \
  --ignore-scripts \
  --pack-destination "$BRACE_EXPANSION_PACK_DIR" >/dev/null
BRACE_EXPANSION_REBUILT="$(
  find "$BRACE_EXPANSION_PACK_DIR" \
    -maxdepth 1 \
    -type f \
    -name 'brace-expansion-*.tgz' \
    -print \
    -quit
)"
if [[ -z "$BRACE_EXPANSION_REBUILT" ]] ||
  ! cmp -s "$BRACE_EXPANSION_TARBALL" "$BRACE_EXPANSION_REBUILT"; then
  echo "::error::Vendored brace-expansion tarball is not reproducible from its checked-in source." >&2
  exit 1
fi

npm ci --prefix functions --ignore-scripts

# Fail before authentication if an override installed a runtime-compatible
# package whose dependency edge is nevertheless invalid according to npm.
npm ls --prefix functions \
  minimatch brace-expansion @isaacs/brace-expansion \
  --all >/dev/null

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
