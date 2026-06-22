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

TARGET="${BURNBAR_EXTENSION_SENTRY_TARGET:-extensions/openburnbar/src/telemetry/sentry.ts}"
DSN="${BURNBAR_EXTENSION_SENTRY_DSN:-}"

if [[ -z "$DSN" ]]; then
  echo "::notice::BURNBAR_EXTENSION_SENTRY_DSN not set — extension Sentry DSN will not be baked in."
  exit 0
fi

# Validate and serialize through URL + JSON parsers before writing TypeScript.
# This keeps the DSN as data even if it contains quote-like or replacement-special
# characters, and avoids sed replacement parsing entirely.
DSN_LITERAL="$(
  node <<'NODE'
const dsn = process.env.BURNBAR_EXTENSION_SENTRY_DSN ?? "";
let parsed;
try {
  parsed = new URL(dsn);
} catch {
  console.error("::error::BURNBAR_EXTENSION_SENTRY_DSN is not a valid URL.");
  process.exit(1);
}

if (parsed.protocol !== "https:") {
  console.error("::error::BURNBAR_EXTENSION_SENTRY_DSN must use https.");
  process.exit(1);
}
const pathSegments = parsed.pathname.split("/").filter(Boolean);
const projectId = pathSegments[pathSegments.length - 1];
if (!parsed.username || !parsed.hostname || !projectId || !/^[0-9]+$/.test(projectId)) {
  console.error("::error::BURNBAR_EXTENSION_SENTRY_DSN does not match the expected Sentry DSN shape.");
  process.exit(1);
}
if (parsed.password) {
  console.error("::error::BURNBAR_EXTENSION_SENTRY_DSN must not include a password component.");
  process.exit(1);
}

process.stdout.write(JSON.stringify(parsed.toString()));
NODE
)"

export BURNBAR_EXTENSION_SENTRY_TARGET="$TARGET"
export BURNBAR_EXTENSION_SENTRY_DSN_LITERAL="$DSN_LITERAL"
node <<'NODE'
const fs = require("node:fs");

const target = process.env.BURNBAR_EXTENSION_SENTRY_TARGET;
const literal = process.env.BURNBAR_EXTENSION_SENTRY_DSN_LITERAL;
if (!target || !literal) {
  console.error("::error::Missing Sentry injection target or DSN literal.");
  process.exit(1);
}

const source = fs.readFileSync(target, "utf8");
const next = source.split("'__SENTRY_DSN__'").join(literal);
if (next === source) {
  console.error(`::error::Sentry DSN placeholder not found in ${target}.`);
  process.exit(1);
}
fs.writeFileSync(target, next);
NODE

echo "::notice::Extension Sentry DSN injected into ${TARGET}."
