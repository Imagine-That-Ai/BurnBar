#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

TARGET="$TMPDIR/sentry.ts"
cat > "$TARGET" <<'TS'
const dsn =
  ('__SENTRY_DSN__'.startsWith('https://') ? '__SENTRY_DSN__' : undefined) ??
  process.env.BURNBAR_EXTENSION_SENTRY_DSN;
TS

BURNBAR_EXTENSION_SENTRY_TARGET="$TARGET" \
BURNBAR_EXTENSION_SENTRY_DSN="https://public@example.ingest.sentry.io/12345?note=quote%27and%5Cnnewline&marker=%24%7Bnot_code%7D" \
  bash "$ROOT/scripts/ci/inject-sentry-config-extension.sh" >/dev/null

node - "$TARGET" <<'NODE'
const fs = require("node:fs");
const target = process.argv[2];
const source = fs.readFileSync(target, "utf8");

if (source.includes("'__SENTRY_DSN__'")) {
  throw new Error("placeholder was not replaced");
}
if (source.includes("quote'and\\nnewline") || source.includes("${not_code}")) {
  throw new Error("raw DSN text was injected instead of serialized data");
}
if (!source.includes('"https://public@example.ingest.sentry.io/12345?note=quote%27and%5Cnnewline&marker=%24%7Bnot_code%7D"')) {
  throw new Error(`serialized DSN literal missing from output:\n${source}`);
}
new Function(`${source}\nreturn dsn;`);
NODE

if BURNBAR_EXTENSION_SENTRY_TARGET="$TARGET" \
  BURNBAR_EXTENSION_SENTRY_DSN="http://public@example.ingest.sentry.io/12345" \
  bash "$ROOT/scripts/ci/inject-sentry-config-extension.sh" >/dev/null 2>&1; then
  echo "expected non-https DSN to be rejected" >&2
  exit 1
fi

if BURNBAR_EXTENSION_SENTRY_TARGET="$TARGET" \
  BURNBAR_EXTENSION_SENTRY_DSN="https://public:password@example.ingest.sentry.io/12345" \
  bash "$ROOT/scripts/ci/inject-sentry-config-extension.sh" >/dev/null 2>&1; then
  echo "expected password-bearing DSN to be rejected" >&2
  exit 1
fi

echo "inject-sentry-config-extension tests passed"
