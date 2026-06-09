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
require_file LICENSES/Nous-hermes-agent-MIT.txt
require_file docs/legal/agpl-compliance.md
require_file REUSE.toml
require_file third_party/libsignal/manifest.json
require_file third_party/libsignal/runtime-readiness.json
require_file scripts/require-agpl-store-legal-review.sh
require_file scripts/generate-sbom.py
require_file scripts/supply-chain/generate-vex.py
require_file scripts/supply-chain/run-ecosystem-deny-checks.sh
require_file scripts/ci/verify-corresponding-source-archive.sh
require_file scripts/ci/verify-libsignal-pin.sh
require_file scripts/ci/verify-libsignal-runtime-readiness.sh

grep -q "GNU AFFERO GENERAL PUBLIC LICENSE" LICENSE || fail "root LICENSE is not AGPLv3 text"
grep -q "MIT License" LICENSES/MIT-legacy.txt || fail "legacy MIT notice is missing"
grep -q "Copyright (c) 2025 Nous Research" LICENSES/Nous-hermes-agent-MIT.txt || fail "Nous Hermes MIT notice is missing"
grep -q "NousResearch/hermes-agent" THIRD_PARTY_NOTICES.md || fail "third-party notices do not record the Nous Hermes origin"
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
const allowedPackageLicenses = new Map([
  // This policy package is deliberately kept MIT-compatible because it encodes
  // the Nous/Hermes upstream mode and must not pull AGPL/libsignal materials
  // into the upstream contribution lane.
  ['packages/e2ee-backend-policy/package.json', 'MIT'],
]);
for (const file of files) {
  const json = JSON.parse(fs.readFileSync(file, 'utf8'));
  const expectedLicense = allowedPackageLicenses.get(file) ?? 'AGPL-3.0-only';
  if (json.license !== expectedLicense) {
    failures.push(`${file}: expected license ${expectedLicense}, got ${json.license ?? '<missing>'}`);
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

if grep -RInE 'MIT-licensed|License \*\*MIT|Licensed under the MIT License|license:[[:space:]]*"MIT"' \
  --exclude='package-lock.json' \
  --exclude-dir='node_modules' \
  --exclude-dir='operational-attachments' \
  README.md website docs/OSS_LAUNCH_CHECKLIST.md docs/RELEASE_MACOS.md docs/IOS_APP_STORE_RELEASE_RUNBOOK.md; then
  fail "found stale first-party MIT marketing or metadata copy"
fi

stale_rust_license=0
while IFS= read -r -d '' cargo_toml; do
  if grep -nE 'license = "Apache-2\.0 OR MIT"' "$cargo_toml"; then
    stale_rust_license=1
  fi
done < <(find crates -name Cargo.toml -print0)
if [[ "$stale_rust_license" -ne 0 ]]; then
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
bash -n scripts/ci/verify-corresponding-source-archive.sh
bash -n scripts/ci/verify-libsignal-pin.sh
bash -n scripts/ci/verify-libsignal-runtime-readiness.sh
bash -n scripts/build-macos-website-release.sh
bash -n scripts/upload-macos-downloads-r2.sh
python3 -m py_compile scripts/generate-sbom.py scripts/supply-chain/generate-vex.py

bash scripts/ci/verify-libsignal-pin.sh
bash scripts/ci/verify-corresponding-source-archive.sh --version compliance-test

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
sbom="$tmpdir/openburnbar-compliance-test.spdx.json"
vex="$tmpdir/openburnbar-compliance-test.vex.json"
python3 scripts/generate-sbom.py --version compliance-test --repo-root . --output "$sbom" >/dev/null
python3 scripts/supply-chain/generate-vex.py --sbom "$sbom" --output "$vex" --product-version compliance-test >/dev/null
python3 - "$sbom" "$vex" <<'PY'
import json
import sys

sbom_path, vex_path = sys.argv[1:3]
sbom = json.load(open(sbom_path, encoding="utf-8"))
vex = json.load(open(vex_path, encoding="utf-8"))
refs = []
for package in sbom.get("packages", []):
    for ref in package.get("externalRefs") or []:
        locator = ref.get("referenceLocator") or ""
        if locator.startswith("pkg:"):
            refs.append(locator)
required = ("pkg:npm/", "pkg:swift/", "pkg:cargo/", "pkg:maven/")
missing = [prefix for prefix in required if not any(ref.startswith(prefix) for ref in refs)]
if missing:
    raise SystemExit(f"SBOM is missing dependency ecosystems: {', '.join(missing)}")
if not any("libsignal-client" in ref for ref in refs):
    raise SystemExit("SBOM is missing @signalapp/libsignal-client")
if vex.get("@context") is None or not vex.get("statements"):
    raise SystemExit("OpenVEX sidecar did not generate statements")
PY

echo "PASS: AGPL compliance gate"
