#!/usr/bin/env bash
# Injects the Amplitude ingestion API key into the VS Code / Cursor extension
# before tsc compiles it. The placeholder '__AMPLITUDE_API_KEY__' in
# extensions/openburnbar/src/analytics/config.ts is replaced so the key is
# baked into the compiled bundle.
#
# Unset key exits 0 and leaves the placeholder: resolveAmplitudeApiKey()
# returns '' and the recorder stays dark. Official release.yml must call this
# before `npm run --prefix extensions/openburnbar build`.
#
# Usage:
#   BURNBAR_EXTENSION_AMPLITUDE_API_KEY=${{ secrets.BURNBAR_EXTENSION_AMPLITUDE_API_KEY }} \
#     bash scripts/ci/inject-amplitude-extension-config.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

TARGET="${BURNBAR_EXTENSION_AMPLITUDE_TARGET:-extensions/openburnbar/src/analytics/config.ts}"
KEY="${BURNBAR_EXTENSION_AMPLITUDE_API_KEY:-}"

if [[ -z "$KEY" ]]; then
  echo "::notice::BURNBAR_EXTENSION_AMPLITUDE_API_KEY not set — extension Amplitude key not baked in (analytics stays dark)."
  exit 0
fi

if [[ ! -f "$TARGET" ]]; then
  echo "::error::$TARGET not found — cannot inject extension Amplitude key."
  exit 1
fi

if [[ "$KEY" =~ [[:space:]] ]] || [[ ${#KEY} -lt 16 ]]; then
  echo "::error::BURNBAR_EXTENSION_AMPLITUDE_API_KEY does not look like a valid Amplitude key."
  exit 1
fi

export BURNBAR_EXTENSION_AMPLITUDE_TARGET="$TARGET"
export BURNBAR_EXTENSION_AMPLITUDE_API_KEY="$KEY"
node <<'NODE'
const fs = require("node:fs");

const target = process.env.BURNBAR_EXTENSION_AMPLITUDE_TARGET;
const key = process.env.BURNBAR_EXTENSION_AMPLITUDE_API_KEY;
if (!target || !key) {
  console.error("::error::Missing extension Amplitude injection target or key.");
  process.exit(1);
}

const source = fs.readFileSync(target, "utf8");
const placeholder = "'__AMPLITUDE_API_KEY__'";
if (!source.includes(placeholder)) {
  console.error(`::error::Amplitude key placeholder not found in ${target}.`);
  process.exit(1);
}
fs.writeFileSync(target, source.split(placeholder).join(JSON.stringify(key)));
NODE

echo "::notice::Extension Amplitude API key injected into ${TARGET}."
