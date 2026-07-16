import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { captureP39Differential } from './capture-p39-differential.mjs';
import {
  P39_PROOF_FILENAME,
  validateP39DifferentialProof
} from './lib/p39-differential-proof.mjs';
import { readRegularSnapshot } from './lib/product-proof-closure.mjs';

const HEAD = 'a'.repeat(40);
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-x86_64';
const VERSION = '1.2.3';
const RUN_ID = '12345';
const DIGEST = `sha256:${'e'.repeat(64)}`;

function artifact({ generatedAt, rows = ['openai'] } = {}) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-platform-evidence-v1',
    targetHead: HEAD,
    version: VERSION,
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    payload: { generatedAt, rows }
  };
}

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p39-proof-'));
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-39', ENVIRONMENT);
  fs.mkdirSync(inputRoot, { recursive: true });
  const macos = path.join(inputRoot, 'macos.json');
  const linux = path.join(inputRoot, 'linux.json');
  fs.writeFileSync(macos, `${JSON.stringify(artifact({ generatedAt: 'mac' }))}\n`, 'utf8');
  fs.writeFileSync(linux, `${JSON.stringify(artifact({ generatedAt: 'linux' }))}\n`, 'utf8');
  return { root, inputRoot, macos, linux };
}

function capture(subject, overrides = {}) {
  return captureP39Differential({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    macos: subject.macos,
    linux: subject.linux,
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    version: VERSION,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    ignoredPaths: ['$.payload.generatedAt'],
    resolveHead: () => HEAD,
    ...overrides
  });
}

test('P-39 capture emits a same-commit candidate-bound exact differential proof', () => {
  const subject = fixture();
  try {
    const result = capture(subject);
    assert.equal(result.document.status, 'passed');
    assert.equal(result.document.environmentId, ENVIRONMENT);
    assert.deepEqual(result.document.contract.ignoredPaths, ['$.payload.generatedAt']);
    assert.equal(fs.existsSync(result.output), true);
    assert.equal(fs.existsSync(result.report), true);
    const repository = fs.realpathSync(subject.root);
    const proof = readRegularSnapshot(repository, path.relative(repository, result.output), 'P-39 proof');
    assert.doesNotThrow(() => validateP39DifferentialProof({
      repoRoot: subject.root,
      snapshot: proof,
      targetHead: HEAD,
      environmentId: ENVIRONMENT,
      version: VERSION,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    }));
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('P-39 capture rejects a platform mutation and leaves no stale passed proof', () => {
  const subject = fixture();
  try {
    fs.writeFileSync(subject.linux, `${JSON.stringify(artifact({ generatedAt: 'linux', rows: ['different'] }))}\n`, 'utf8');
    assert.throws(() => capture(subject), /unapproved difference/u);
    assert.equal(fs.existsSync(path.join(subject.inputRoot, P39_PROOF_FILENAME)), false);
    assert.equal(fs.existsSync(path.join(subject.inputRoot, 'platform-differential/report.json')), false);
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('P-39 capture rejects stale head and candidate substitution before writing evidence', () => {
  const subject = fixture();
  try {
    assert.throws(() => capture(subject, { resolveHead: () => 'b'.repeat(40) }), /requested target HEAD/u);
    assert.equal(fs.existsSync(path.join(subject.inputRoot, P39_PROOF_FILENAME)), false);
    assert.throws(() => capture(subject, { candidateArtifactDigest: `sha256:${'f'.repeat(64)}` }), /candidate artifact digest/u);
    assert.equal(fs.existsSync(path.join(subject.inputRoot, P39_PROOF_FILENAME)), false);
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('P-39 proof validation rejects a substituted proof binding or source bytes', () => {
  const subject = fixture();
  try {
    const result = capture(subject);
    const proofPath = path.join(subject.inputRoot, P39_PROOF_FILENAME);
    const proof = JSON.parse(fs.readFileSync(proofPath, 'utf8'));
    proof.candidate.artifactDigest = `sha256:${'f'.repeat(64)}`;
    fs.writeFileSync(proofPath, `${JSON.stringify(proof)}\n`, 'utf8');
    const repository = fs.realpathSync(subject.root);
    const snapshot = readRegularSnapshot(repository, path.relative(repository, fs.realpathSync(proofPath)), 'P-39 proof');
    assert.throws(() => validateP39DifferentialProof({
      repoRoot: subject.root,
      snapshot,
      targetHead: HEAD,
      environmentId: ENVIRONMENT,
      version: VERSION,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    }), /candidate artifact digest/u);

    // Re-capture, then mutate the attested source bytes without updating its record.
    capture(subject);
    fs.appendFileSync(subject.macos, '\n');
    const fresh = readRegularSnapshot(repository, path.relative(repository, result.output), 'P-39 proof');
    assert.throws(() => validateP39DifferentialProof({
      repoRoot: subject.root,
      snapshot: fresh,
      targetHead: HEAD,
      environmentId: ENVIRONMENT,
      version: VERSION,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    }), /bytes changed/u);
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('P-39 proof validation rejects source records outside the selected environment root', () => {
  const subject = fixture();
  try {
    const result = capture(subject);
    const proofPath = path.join(subject.inputRoot, P39_PROOF_FILENAME);
    const proof = JSON.parse(fs.readFileSync(proofPath, 'utf8'));
    proof.macos.path = 'docs/linux-port/evidence/product-parity-inputs/P-38/foreign.json';
    fs.writeFileSync(proofPath, `${JSON.stringify(proof)}\n`, 'utf8');
    const repository = fs.realpathSync(subject.root);
    const snapshot = readRegularSnapshot(repository, path.relative(repository, fs.realpathSync(proofPath)), 'P-39 proof');
    assert.throws(() => validateP39DifferentialProof({
      repoRoot: subject.root,
      snapshot,
      targetHead: HEAD,
      environmentId: ENVIRONMENT,
      version: VERSION,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    }), /environment evidence root/u);
    assert.ok(result.document.status === 'passed');
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('P-39 validator module exposes only the required entrypoint', async () => {
  const module = await import('./product-validators/P-39.mjs');
  assert.deepEqual(Object.keys(module), ['validateProductRequirement']);
});
