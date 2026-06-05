#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

manifest="third_party/libsignal/runtime-readiness.json"

if [[ ! -f "$manifest" ]]; then
  echo "ERROR: missing ${manifest}" >&2
  exit 1
fi

node <<'NODE'
const fs = require('node:fs');

const manifestPath = 'third_party/libsignal/runtime-readiness.json';
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

const requiredIds = [
  'rust_core_bridge',
  'swift_round_trips',
  'kotlin_round_trips',
  'node_contracts',
  'hermes_gateway_writes',
  'hermes_attachment_writes',
  'cloudvault_private_domains',
  'migration_telemetry',
  'store_and_counsel_approval',
];

if (manifest.officialLibsignalPin?.tag !== 'v0.94.4') {
  throw new Error('libsignal runtime manifest tag drifted');
}
if (manifest.officialLibsignalPin?.tagObject !== '03c449017b57eccbda715b8b018dce5dff603ac6') {
  throw new Error('libsignal runtime manifest tag object drifted');
}
if (manifest.officialLibsignalPin?.commit !== '46d867c986f66201e34e7ae20ce423eec742bf3f') {
  throw new Error('libsignal runtime manifest commit drifted');
}

const gates = new Map((manifest.requiredGates ?? []).map((gate) => [gate.id, gate]));
const missing = requiredIds.filter((id) => !gates.has(id));
if (missing.length > 0) {
  throw new Error(`missing libsignal runtime gates: ${missing.join(', ')}`);
}

const incomplete = requiredIds
  .map((id) => gates.get(id))
  .filter((gate) => gate.status !== 'complete');
const completedEvidence = manifest.completedEvidence ?? [];
const completedEvidenceIds = new Set(
  completedEvidence
    .filter((evidence) => evidence.status === 'complete')
    .map((evidence) => evidence.id),
);
const missingCompletedEvidence = requiredIds
  .map((id) => gates.get(id))
  .filter((gate) => gate.status === 'complete' && !completedEvidenceIds.has(gate.id))
  .map((gate) => gate.id);
if (missingCompletedEvidence.length > 0) {
  throw new Error(`complete gates missing completed evidence: ${missingCompletedEvidence.join(', ')}`);
}

if (manifest.status === 'ready') {
  if (incomplete.length > 0) {
    throw new Error(`manifest says ready but gates are incomplete: ${incomplete.map((gate) => gate.id).join(', ')}`);
  }
  console.log('PASS: libsignal runtime readiness gate');
  process.exit(0);
}

if (manifest.status !== 'not_ready') {
  throw new Error(`invalid libsignal runtime status: ${manifest.status}`);
}

console.error('HOLD: official libsignal is not yet the OpenBurnBar runtime crypto core.');
console.error(`Current runtime core: ${manifest.runtimeCryptoCore}`);
console.error(`Blocking reason: ${manifest.blockingReason}`);
if (completedEvidence.length > 0) {
  console.error('Completed evidence:');
  for (const evidence of completedEvidence) {
    console.error(`- ${evidence.id}: ${evidence.proof}`);
  }
}
console.error('Incomplete gates:');
for (const gate of incomplete) {
  console.error(`- ${gate.id}: ${gate.proof}`);
}
process.exit(1);
NODE
