import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  REPORT_SCHEMA,
  RUNTIME_RECEIPT_SCHEMA,
  SOURCE_TEST_SCHEMA,
  buildEvidenceAvailabilityReport,
  main,
  parseArguments
} from './report-parity-evidence-availability.mjs';

const HEAD = 'a'.repeat(40);

function requirements() {
  return {
    minimumSupportMatrix: [{
      id: 'ubuntu-24.04-gnome-x11-aarch64',
      os: 'Ubuntu 24.04',
      desktop: 'GNOME',
      session: 'X11',
      architecture: 'aarch64'
    }]
  };
}

function ledger() {
  return {
    semantics: { productParityClaim: false },
    rows: [
      { id: 'P-03', area: 'installed-runtime', tier: 'A', status: 'blocked' },
      { id: 'P-13', area: 'onboarding', tier: 'A', status: 'blocked' }
    ],
    environmentCoverage: [{
      id: 'ubuntu-24.04-gnome-x11-aarch64',
      status: 'blocked'
    }]
  };
}

function runtimeReceipt(sourceCommit = HEAD, certificationScope = 'non-certifying installed runtime smoke receipt') {
  return {
    schema: RUNTIME_RECEIPT_SCHEMA,
    capturedAt: '2026-07-14T00:00:00Z',
    certificationScope,
    sourceCommit,
    environment: {
      os: 'Ubuntu 24.04.4 LTS',
      architecture: 'aarch64',
      desktop: 'GNOME',
      session: 'X11'
    },
    sha256: {
      gui: '1'.repeat(64),
      daemon: '2'.repeat(64),
      launcher: '3'.repeat(64)
    },
    checks: {
      guiLaunch: true,
      daemonSpawnedByTrustedLauncher: true,
      authenticatedDaemonReadiness: true,
      daemonHealthRequestsObserved: 2,
      normalTimeoutExit: true,
      daemonSIGTERMShutdown: true,
      temporaryRuntimeCleaned: true
    },
    limitations: ['not a signed release attestation']
  };
}

function sourceTests(sourceCommit = HEAD) {
  return {
    schema: SOURCE_TEST_SCHEMA,
    sourceCommit,
    status: 'passed',
    testCount: 12,
    failedCount: 0,
    coveredRequirementIds: ['P-03', 'P-13'],
    command: 'npm test --prefix apps/linux-desktop'
  };
}

test('diagnostic report refuses to promote stale non-certifying runtime evidence', () => {
  const report = buildEvidenceAvailabilityReport({
    ledger: ledger(),
    requirements: requirements(),
    runtimeReceipt: { path: 'receipt.json', sha256: 'f'.repeat(64), value: runtimeReceipt('b'.repeat(40)) },
    targetHead: HEAD,
    generatedAt: '2026-07-14T00:00:00.000Z'
  });

  assert.equal(report.schema, REPORT_SCHEMA);
  assert.equal(report.canonicalPromotion.status, 'blocked');
  assert.deepEqual(report.canonicalPromotion.eligibleProductRowIds, []);
  assert.equal(report.installedRuntime.status, 'stale-non-certifying');
  assert.equal(report.installedRuntime.environmentId, 'ubuntu-24.04-gnome-x11-aarch64');
  assert.deepEqual(report.observedRequirementIds, []);
  assert.equal(report.rows.every((row) => row.canGenerateCanonicalEvidence === false), true);
  assert.match(report.rows[0].blockers.join(' '), /current-head Tier A\/B attestation/u);
});

test('current passing source tests remain observations and do not become product attestations', () => {
  const report = buildEvidenceAvailabilityReport({
    ledger: ledger(),
    requirements: requirements(),
    runtimeReceipt: { path: 'receipt.json', sha256: 'f'.repeat(64), value: runtimeReceipt() },
    sourceTests: { path: 'tests.json', sha256: 'e'.repeat(64), value: sourceTests() },
    targetHead: HEAD,
    generatedAt: '2026-07-14T00:00:00.000Z'
  });

  assert.equal(report.sourceTests.status, 'current-passing');
  assert.equal(report.installedRuntime.status, 'observed-non-certifying');
  assert.deepEqual(report.canonicalPromotion.eligibleProductRowIds, []);
  assert.deepEqual(report.observedRequirementIds, ['P-03', 'P-13']);
  assert.equal(report.rows.find((row) => row.id === 'P-13').sourceTestCovered, true);
  assert.deepEqual(report.rows.find((row) => row.id === 'P-03').runtimeSignals, [
    'guiLaunch',
    'daemonSpawnedByTrustedLauncher',
    'authenticatedDaemonReadiness'
  ]);
});

test('CLI writes the report without rewriting the canonical ledger', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-evidence-availability-'));
  const writeJson = (relative, value) => {
    const file = path.join(root, relative);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  };
  try {
    execFileSync('git', ['init', '-q'], { cwd: root });
    execFileSync('git', ['config', 'user.name', 'OpenBurnBar Test'], { cwd: root });
    execFileSync('git', ['config', 'user.email', 'test@openburnbar.invalid'], { cwd: root });
    writeJson('ledger.json', ledger());
    writeJson('requirements.json', requirements());
    writeJson('receipt.json', runtimeReceipt());
    fs.writeFileSync(path.join(root, 'anchor.txt'), 'anchor\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    execFileSync('git', ['commit', '-qm', 'fixture'], { cwd: root });
    const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
    const output = 'report.json';
    const report = main([
      '--ledger', 'ledger.json',
      '--requirements', 'requirements.json',
      '--runtime-receipt', 'receipt.json',
      '--output', output
    ], root);
    assert.equal(report.targetHead, head);
    assert.equal(JSON.parse(fs.readFileSync(path.join(root, output), 'utf8')).schema, REPORT_SCHEMA);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(root, 'ledger.json'), 'utf8')), ledger());
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('argument parser rejects duplicate and unknown flags', () => {
  assert.throws(() => parseArguments(['--bogus', 'x']), /unknown argument/u);
  assert.throws(() => parseArguments(['--ledger', 'one.json', '--ledger', 'two.json']), /only once/u);
  assert.throws(() => parseArguments([
    '--runtime-receipt',
    'docs/linux-port/evidence/parity-audit-2026-07-10/utm-ubuntu-aarch64-installed-runtime-2026-07-14.json',
    '--runtime-receipt',
    'docs/linux-port/evidence/parity-audit-2026-07-10/utm-ubuntu-aarch64-installed-runtime-2026-07-14.json'
  ]), /only once/u);
  assert.throws(() => parseArguments(['--output']), /requires a value/u);
});
