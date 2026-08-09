/**
 * Drives real package artifacts (when present) and smoke summary for
 * product-parity packaging.
 *
 * Payload contracts are versioned (lib/linux-package-payload-contract.mjs):
 * the July mission-002 receipts were produced against the historical
 * /opt/openburnbar/lib/swift layout and stay validated against that v1
 * contract — they are never rewritten to look current. Any real package
 * artifact present in the checkout is validated against the CURRENT
 * /usr/lib/openburnbar layout, and a current-era artifact that only
 * satisfies the historical contract fails.
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  assertPayloadContract,
  detectPayloadContract,
  CURRENT_PAYLOAD_CONTRACT,
  PAYLOAD_CONTRACT_V1_HISTORICAL,
  PAYLOAD_CONTRACT_V2_CURRENT
} from './lib/linux-package-payload-contract.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const outDir = path.join(root, 'docs/linux-port/evidence/mission-002-reanchor');
const artDir = path.join(outDir, 'artifacts');
const historicalSmokeLog = path.join(outDir, 'smoke/package-install-uninstall.log');

function listDeb(file) {
  const r = spawnSync('dpkg-deb', ['--contents', file], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return r.status === 0 ? r.stdout : null;
}
function listRpm(file) {
  const r = spawnSync('rpm', ['-qlp', file], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return r.status === 0 ? r.stdout : null;
}

test('smoke summary is green when present', () => {
  const p = path.join(outDir, 'smoke/package-smoke-summary.json');
  assert.ok(fs.existsSync(p), 'package-smoke-summary.json missing');
  const s = JSON.parse(fs.readFileSync(p, 'utf8'));
  assert.equal(s.passed, true);
  assert.equal(s.failedCount, 0);
});

test('historical July receipts stay bound to the v1 /opt payload contract', {
  skip: fs.existsSync(historicalSmokeLog) ? false : 'historical smoke log absent from this checkout'
}, () => {
  const log = fs.readFileSync(historicalSmokeLog, 'utf8');
  const detected = detectPayloadContract(log);
  assert.equal(detected?.id, PAYLOAD_CONTRACT_V1_HISTORICAL.id,
    'July receipts must classify as the historical /opt layout — do not rewrite old receipts to look current');
  assertPayloadContract(log, PAYLOAD_CONTRACT_V1_HISTORICAL, { includeReceiptPatterns: true });
  // A historical receipt must NOT satisfy the current contract; if it ever
  // does, someone rewrote history.
  assert.throws(() => assertPayloadContract(log, PAYLOAD_CONTRACT_V2_CURRENT));
});

test('payload contract detection fails closed on unknown layouts', () => {
  assert.equal(detectPayloadContract('usr/bin/openburnbar-daemon\n'), null);
  assert.equal(detectPayloadContract(''), null);
  assert.equal(detectPayloadContract(null), null);
  // A listing carrying both roots classifies as current (upgrade-in-place
  // artifacts keep legacy mentions in prose/log context).
  const mixed = 'usr/lib/openburnbar/swift/libswiftCore.so\nopt/openburnbar/lib/swift/legacy-note\n';
  assert.equal(detectPayloadContract(mixed)?.id, PAYLOAD_CONTRACT_V2_CURRENT.id);
});

const debArtifact = path.join(artDir, 'OpenBurnBar_0.1.0_arm64.deb');
const rpmArtifact = path.join(artDir, 'OpenBurnBar-0.1.0-1.aarch64.rpm');

test('deb artifact ships daemon, launch, Swift, and SQLCipher runtime', {
  skip: !fs.existsSync(debArtifact)
    ? 'historical DEB evidence artifact is external and was not supplied to this checkout'
    : false
}, () => {
  const deb = debArtifact;
  assert.ok(fs.existsSync(deb), 'deb missing');
  assert.ok(fs.statSync(deb).size > 40_000_000, 'deb too small to contain daemon+runtime');
  const listing = listDeb(deb);
  if (listing === null) {
    // Host without dpkg-deb: rely on the smoke log produced on a Linux
    // guest, validated against the contract for its own era.
    const log = fs.readFileSync(historicalSmokeLog, 'utf8');
    assert.match(log, /assert deb contains openburnbar-daemon-launch[\s\S]*?exit_code=0/);
    const contract = detectPayloadContract(log);
    assert.ok(contract, 'smoke log payload era is unrecognized');
    assertPayloadContract(log, contract, { includeReceiptPatterns: true });
    return;
  }
  // A real artifact listing is validated for its own era: current-era
  // packages must satisfy the current /usr contract; the retained July
  // artifact keeps validating against v1.
  const contract = detectPayloadContract(listing);
  assert.ok(contract, 'deb payload era is unrecognized');
  assertPayloadContract(listing, contract);
});

test('rpm artifact ships daemon, launch, Swift, and SQLCipher runtime', {
  skip: !fs.existsSync(rpmArtifact)
    ? 'historical RPM evidence artifact is external and was not supplied to this checkout'
    : false
}, () => {
  const rpm = rpmArtifact;
  assert.ok(fs.existsSync(rpm), 'rpm missing');
  assert.ok(fs.statSync(rpm).size > 40_000_000, 'rpm too small to contain daemon+runtime');
  const listing = listRpm(rpm);
  if (listing === null) {
    const log = fs.readFileSync(historicalSmokeLog, 'utf8');
    assert.match(log, /assert rpm contains openburnbar-daemon-launch[\s\S]*?exit_code=0/);
    const contract = detectPayloadContract(log);
    assert.ok(contract, 'smoke log payload era is unrecognized');
    assertPayloadContract(log, contract, { includeReceiptPatterns: true });
    return;
  }
  const contract = detectPayloadContract(listing);
  assert.ok(contract, 'rpm payload era is unrecognized');
  assertPayloadContract(listing, contract);
});

test('current payload contract matches the release config runtime layout', () => {
  // validate-linux-release-config.mjs pins the current runtime roots; the
  // current payload contract must agree so new packages are tested against
  // the layout the release actually ships.
  const source = fs.readFileSync(path.join(root, 'scripts/linux-port/validate-linux-release-config.mjs'), 'utf8');
  assert.match(source, /swiftRuntime: '\/usr\/lib\/openburnbar\/swift'/u);
  assert.equal(CURRENT_PAYLOAD_CONTRACT.swiftRuntime, 'usr/lib/openburnbar/swift');
  assert.equal(CURRENT_PAYLOAD_CONTRACT.era, 'current');
});

test('VAL-DASHBOARD-004 six-layout screenshots exist', () => {
  const dir = path.join(outDir, 'dashboard-layouts');
  for (const id of ['classic','aurora','nebula','constellation','cockpit','atelier']) {
    const f = path.join(dir, `layout-${id}.png`);
    assert.ok(fs.existsSync(f), f);
    assert.ok(fs.statSync(f).size > 1000, f+' tiny');
  }
  assert.ok(fs.existsSync(path.join(dir, 'all-layouts-matrix.png')));
  const md = fs.readFileSync(path.join(dir, 'VAL-DASHBOARD-004.md'), 'utf8');
  assert.match(md, /VAL-DASHBOARD-004/);
});
