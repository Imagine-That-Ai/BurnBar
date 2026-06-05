#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing required file: $1"
}

require_file LICENSE
require_file NOTICE
require_file THIRD_PARTY_NOTICES.md
require_file LICENSES/MIT-legacy.txt
require_file docs/legal/agpl-compliance.md
require_file REUSE.toml
require_file third_party/libsignal/manifest.json
require_file third_party/libsignal/runtime-readiness.json
require_file scripts/require-agpl-store-legal-review.sh
require_file scripts/ci/verify-libsignal-runtime-readiness.sh

grep -q "GNU AFFERO GENERAL PUBLIC LICENSE" LICENSE || fail "root LICENSE is not AGPLv3 text"
grep -q "MIT License" LICENSES/MIT-legacy.txt || fail "legacy MIT notice is missing"
grep -q "AGPL-3.0-only" NOTICE || fail "NOTICE does not identify AGPL-3.0-only"
grep -q "46d867c986f66201e34e7ae20ce423eec742bf3f" third_party/libsignal/manifest.json || fail "libsignal commit pin drifted"
grep -q "v0.94.4" THIRD_PARTY_NOTICES.md || fail "third-party notices do not record the libsignal tag"

node <<'NODE'
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');

const files = execFileSync('git', [
  'ls-files',
  '--cached',
  '--others',
  '--exclude-standard',
  '*package.json',
  ':!:**/node_modules/**',
  ':!:**/package-lock.json',
], { encoding: 'utf8' })
  .trim()
  .split('\n')
  .filter(Boolean);
const failures = [];
for (const file of files) {
  const json = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (json.license !== 'AGPL-3.0-only') {
    failures.push(`${file}: expected license AGPL-3.0-only, got ${json.license ?? '<missing>'}`);
  }
}
if (failures.length) {
  console.error(failures.join('\n'));
  process.exit(1);
}

const manifest = JSON.parse(fs.readFileSync('third_party/libsignal/manifest.json', 'utf8'));
if (manifest.license !== 'AGPL-3.0-only') throw new Error('libsignal manifest license drifted');
if (manifest.pinnedTag !== 'v0.94.4') throw new Error('libsignal manifest tag drifted');
if (manifest.pinnedTagObject !== '03c449017b57eccbda715b8b018dce5dff603ac6') throw new Error('libsignal manifest tag object drifted');
if (manifest.pinnedCommit !== '46d867c986f66201e34e7ae20ce423eec742bf3f') throw new Error('libsignal manifest commit drifted');
if (manifest.artifacts?.node?.package !== '@signalapp/libsignal-client') throw new Error('libsignal node artifact missing');

const runtime = JSON.parse(fs.readFileSync('third_party/libsignal/runtime-readiness.json', 'utf8'));
if (!['ready', 'not_ready'].includes(runtime.status)) throw new Error('invalid libsignal runtime readiness status');
if (runtime.officialLibsignalPin?.tag !== manifest.pinnedTag) throw new Error('libsignal runtime readiness tag drifted');
if (runtime.officialLibsignalPin?.tagObject !== manifest.pinnedTagObject) throw new Error('libsignal runtime readiness tag object drifted');
if (runtime.officialLibsignalPin?.commit !== manifest.pinnedCommit) throw new Error('libsignal runtime readiness commit drifted');
if (runtime.status === 'ready') {
  const incomplete = (runtime.requiredGates ?? []).filter((gate) => gate.status !== 'complete');
  if (incomplete.length > 0) throw new Error('libsignal runtime manifest says ready with incomplete gates');
} else if (!runtime.blockingReason || !(runtime.requiredGates ?? []).some((gate) => gate.status !== 'complete')) {
  throw new Error('libsignal runtime manifest must explain not_ready status with incomplete gates');
}
if (!(runtime.completedEvidence ?? []).some((evidence) => evidence.id === 'node_protocol_harness')) {
  throw new Error('libsignal runtime manifest must record the Node protocol harness evidence');
}
NODE

if rg -n 'MIT-licensed|License \*\*MIT|Licensed under the MIT License|license:\s*"MIT"' \
  README.md website docs/OSS_LAUNCH_CHECKLIST.md docs/RELEASE_MACOS.md docs/IOS_APP_STORE_RELEASE_RUNBOOK.md \
  --glob '!docs/pricing/gpt-pro-brief/operational-attachments/**' \
  --glob '!website/package-lock.json' \
  --glob '!**/node_modules/**'; then
  fail "found stale first-party MIT marketing or metadata copy"
fi

if rg -n 'license = "Apache-2\.0 OR MIT"' crates --glob 'Cargo.toml'; then
  fail "found stale Rust package license metadata"
fi

grep -q 'AGPL-3.0-only' website/src/data/site.ts || fail "website SITE.license is not AGPL"
grep -q 'sourceMetadata' functions/src/health.ts || fail "Functions health endpoint does not expose source metadata"
grep -q 'sourceMetadata' services/hosted-mcp/src/server.ts || fail "hosted MCP health endpoint does not expose source metadata"
grep -q 'sourceMetadata' services/hermes-realtime-relay/src/server.ts || fail "Hermes relay health endpoint does not expose source metadata"
grep -q 'legal/source' website/src/pages/health.ts || fail "website health endpoint does not expose corresponding source URL"
grep -q 'legal/source' website/src/pages/legal/source.astro || fail "website source-offer page missing source URL"
grep -q 'runtime-readiness' website/src/pages/legal/source.astro || fail "website source-offer page missing libsignal runtime readiness notice"

bash -n scripts/create-corresponding-source.sh
bash -n scripts/require-agpl-store-legal-review.sh
bash -n scripts/ci/verify-libsignal-runtime-readiness.sh
bash -n scripts/build-macos-website-release.sh
bash -n scripts/upload-macos-downloads-r2.sh

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
OPENBURNBAR_ALLOW_DIRTY_SOURCE=1 scripts/create-corresponding-source.sh \
  --version compliance-test \
  --output "$tmpdir/OpenBurnBar-compliance-test-corresponding-source.tar.gz" >/dev/null

tar -tzf "$tmpdir/OpenBurnBar-compliance-test-corresponding-source.tar.gz" | grep -q 'CORRESPONDING_SOURCE_MANIFEST.json' \
  || fail "corresponding source archive missing manifest"
tar -tzf "$tmpdir/OpenBurnBar-compliance-test-corresponding-source.tar.gz" | grep -q 'docs/legal/agpl-compliance.md' \
  || fail "corresponding source archive missing AGPL compliance doc"

echo "PASS: AGPL compliance gate"
