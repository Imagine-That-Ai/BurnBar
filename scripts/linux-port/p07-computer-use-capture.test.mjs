import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { captureP07ComputerUseProof } from './capture-p07-computer-use-proof.mjs';
import {
  P07_PROOF_FILENAME,
  P07_PROOF_ROLE,
  P07_REJECTION_POLICY_FIELDS,
  P07_SESSION_ID,
  P07_TARGET_IDS
} from './lib/p07-computer-use-capture.mjs';

const HEAD = 'a'.repeat(40);
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-x86_64';
const CANDIDATE = Object.freeze({ runId: '98765', artifactDigest: `sha256:${'b'.repeat(64)}` });

function write(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  return file;
}

function writeJson(file, value) {
  return write(file, `${JSON.stringify(value, null, 2)}\n`);
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function fixture() {
  const repoRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p07-capture-'));
  const inputRoot = path.join(
    repoRoot,
    'docs/linux-port/evidence/product-parity-inputs/P-07',
    ENVIRONMENT
  );
  fs.mkdirSync(inputRoot, { recursive: true });
  const sourceEvidence = P07_TARGET_IDS.map((target) => {
    const absolute = writeJson(path.join(inputRoot, 'live-evidence', `${target}.json`), {
      target,
      candidate: { ...CANDIDATE },
      passed: true
    });
    return {
      path: path.relative(repoRoot, absolute).split(path.sep).join('/'),
      sha256: sha256(absolute),
      size: fs.statSync(absolute).size,
      captureMode: 'installed-native-live',
      targetIds: [target]
    };
  });
  const rejectionPolicy = Object.fromEntries(P07_REJECTION_POLICY_FIELDS.map((field) => [field, false]));
  const targets = Object.fromEntries(P07_TARGET_IDS.map((target) => [target, {
    target,
    status: 'pass',
    acceptedAsPass: true,
    notClaimedAsPass: false,
    evidenceClass: 'installed-native-live',
    prerequisite: target === 'VAL-CU-003' ? 'VAL-CU-002' : null,
    evidence: [sourceEvidence.find((record) => record.targetIds.includes(target)).path],
    failures: [],
    blockers: []
  }]));
  const session = {
    schemaVersion: 1,
    id: P07_SESSION_ID,
    requirementId: 'P-07',
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidate: { ...CANDIDATE },
    capture: {
      mode: 'installed-native-live',
      candidateExecuted: true,
      browserBackend: 'playwright-chromium',
      mobileController: 'physical-ipad',
      checkoutHead: HEAD,
      installedArtifactDigest: CANDIDATE.artifactDigest,
      startedAt: '2026-07-20T12:00:00.000Z',
      completedAt: '2026-07-20T12:05:00.000Z'
    },
    targetIds: [...P07_TARGET_IDS],
    rejectionPolicy,
    targets,
    failedTargets: [],
    sourceEvidence
  };
  const sessionReport = path.join(inputRoot, 'live-session', 'computer-use-session.json');
  writeJson(sessionReport, session);
  return { repoRoot, inputRoot, sessionReport, session, sourceEvidence };
}

function capture(current, overrides = {}) {
  return captureP07ComputerUseProof({
    repoRoot: current.repoRoot,
    inputRoot: current.inputRoot,
    sessionReport: current.sessionReport,
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: CANDIDATE.runId,
    candidateArtifactDigest: CANDIDATE.artifactDigest,
    resolveHead: () => HEAD,
    ...overrides
  });
}

function cleanup(current) {
  fs.rmSync(current.repoRoot, { recursive: true, force: true });
}

test('P-07 capture emits the exact candidate-bound feature registration', () => {
  const current = fixture();
  try {
    const result = capture(current);
    const proof = JSON.parse(fs.readFileSync(result.output, 'utf8'));
    const registration = JSON.parse(fs.readFileSync(result.registration, 'utf8'));
    assert.equal(proof.id, 'openburnbar-linux-computer-use-proof-v1');
    assert.deepEqual(proof.candidate, CANDIDATE);
    assert.equal(proof.capture.mobileController, 'physical-ipad');
    assert.deepEqual(proof.sourceEvidence, current.sourceEvidence);
    assert.deepEqual(registration, {
      schemaVersion: 1,
      requirementId: 'P-07',
      environmentId: ENVIRONMENT,
      artifacts: [{ role: P07_PROOF_ROLE, path: `feature-artifacts/${P07_PROOF_FILENAME}` }]
    });
  } finally {
    cleanup(current);
  }
});

test('P-07 capture rejects candidate, checkout, surface, policy, target, and source mutations', () => {
  for (const [name, mutate, pattern] of [
    ['candidate', (current) => { current.session.candidate.runId = '123'; }, /release candidate/u],
    ['surface', (current) => { current.session.capture.mode = 'fixture'; }, /installed candidate/u],
    ['mobile simulator', (current) => { current.session.capture.mobileController = 'ios-simulator'; }, /physical mobile/u],
    ['policy', (current) => { current.session.rejectionPolicy.staleTmpOnlyRowsAcceptedAsPass = true; }, /rejection policy/u],
    ['target result', (current) => { current.session.targets['VAL-CU-001'].acceptedAsPass = false; }, /accepted pass/u],
    ['source hash', (current) => { current.session.sourceEvidence[0].sha256 = 'f'.repeat(64); }, /source evidence changed/u]
  ]) {
    const current = fixture();
    try {
      mutate(current);
      writeJson(current.sessionReport, current.session);
      assert.throws(() => capture(current), pattern, name);
      assert.equal(fs.existsSync(path.join(current.inputRoot, 'feature-proof-registration.json')), false);
    } finally {
      cleanup(current);
    }
  }
});

test('P-07 capture rejects a different checkout and removes stale materializer outputs', () => {
  const current = fixture();
  try {
    const registration = write(path.join(current.inputRoot, 'feature-proof-registration.json'), 'stale\n');
    const proof = write(path.join(current.inputRoot, 'feature-artifacts', P07_PROOF_FILENAME), 'stale\n');
    assert.throws(() => capture(current, { resolveHead: () => 'c'.repeat(40) }), /requested target HEAD/u);
    assert.equal(fs.existsSync(registration), false);
    assert.equal(fs.existsSync(proof), false);
  } finally {
    cleanup(current);
  }
});

test('P-07 capture rejects evidence symlinks and paths outside the canonical input root', () => {
  const current = fixture();
  try {
    const source = current.sourceEvidence[0];
    const sourceAbsolute = path.join(current.repoRoot, source.path);
    fs.rmSync(sourceAbsolute);
    fs.symlinkSync(current.sessionReport, sourceAbsolute);
    assert.throws(() => capture(current), /traverses a symlink/u);
  } finally {
    cleanup(current);
  }

  const outside = fixture();
  try {
    const external = write(path.join(outside.repoRoot, 'outside.json'), 'outside\n');
    outside.session.sourceEvidence[0] = {
      ...outside.session.sourceEvidence[0],
      path: 'outside.json',
      sha256: sha256(external),
      size: fs.statSync(external).size
    };
    outside.session.targets['VAL-CU-001'].evidence = ['outside.json'];
    writeJson(outside.sessionReport, outside.session);
    assert.throws(() => capture(outside), /canonical installed-native record/u);
  } finally {
    cleanup(outside);
  }
});
