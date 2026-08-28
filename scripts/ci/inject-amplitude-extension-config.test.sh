#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

TARGET="$TMPDIR/config.ts"
cat > "$TARGET" <<'TS'
const INJECTED_API_KEY = '__AMPLITUDE_API_KEY__';
function isPlaceholderUnreplaced(value: string): boolean {
  return value === ['__AMPLITUDE', 'API', 'KEY__'].join('_');
}
TS

BURNBAR_EXTENSION_AMPLITUDE_TARGET="$TARGET" \
BURNBAR_EXTENSION_AMPLITUDE_API_KEY="test-amplitude-key-012345" \
  bash "$ROOT/scripts/ci/inject-amplitude-extension-config.sh" >/dev/null

node - "$TARGET" <<'NODE'
const fs = require("node:fs");
const source = fs.readFileSync(process.argv[2], "utf8");
if (source.includes("'__AMPLITUDE_API_KEY__'")) {
  throw new Error("placeholder was not replaced");
}
if (!source.includes('"test-amplitude-key-012345"')) {
  throw new Error(`serialized key missing from output:\n${source}`);
}
if (!source.includes("['__AMPLITUDE', 'API', 'KEY__'].join('_')")) {
  throw new Error("reconstructed placeholder check was rewritten");
}
NODE

if BURNBAR_EXTENSION_AMPLITUDE_TARGET="$TARGET" \
  BURNBAR_EXTENSION_AMPLITUDE_API_KEY="short" \
  bash "$ROOT/scripts/ci/inject-amplitude-extension-config.sh" >/dev/null 2>&1; then
  echo "expected short key to be rejected" >&2
  exit 1
fi

if BURNBAR_EXTENSION_AMPLITUDE_TARGET="$TARGET" \
  BURNBAR_EXTENSION_AMPLITUDE_API_KEY="has whitespace-key-0123" \
  bash "$ROOT/scripts/ci/inject-amplitude-extension-config.sh" >/dev/null 2>&1; then
  echo "expected whitespace key to be rejected" >&2
  exit 1
fi

BURNBAR_EXTENSION_AMPLITUDE_TARGET="$TARGET" \
BURNBAR_EXTENSION_AMPLITUDE_API_KEY="" \
  bash "$ROOT/scripts/ci/inject-amplitude-extension-config.sh" >/dev/null

echo "inject-amplitude-extension-config tests passed"
