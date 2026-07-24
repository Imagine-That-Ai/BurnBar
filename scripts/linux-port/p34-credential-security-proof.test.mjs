import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { captureP34CredentialSecurityProof } from './capture-p34-credential-security-proof.mjs';
import { main as finalizeProductFeatureProofClosure } from './finalize-product-feature-proof-closure.mjs';
import {
  P34_BACKEND_IDS,
  P34_CASE_IDS,
  P34_PROOF_FILENAME,
  P34_PROOF_ROLE,
  parseProofSnapshot,
  validateP34CredentialSecurityProof
} from './lib/p34-credential-security-proof.mjs';
import { validateProductRequirement } from './product-validators/P-34.mjs';

const HEAD = 'a'.repeat(40);
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-x86_64';
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;

function tempInput() {
  const root = fs.mkdtempSync(path.join(process.cwd(), '.linux-p34-proof-test-'));
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-34', ENVIRONMENT);
  fs.mkdirSync(inputRoot, { recursive: true });
  return { root, inputRoot };
}

function fixtureHost() {
  return {
    platform: 'linux',
    architecture: 'x86_64',
    desktop: 'GNOME',
    session: 'x11',
    sessionBusPresent: false,
    os: { id: 'ubuntu', versionId: '24.04' },
    executables: { 'gnome-secret-service': null, 'kde-kwallet': null },
    credentialDirectoryPresent: false,
    credentialDirectoryPathObserved: false
  };
}

function capture() {
  const subject = tempInput();
  try {
    const result = captureP34CredentialSecurityProof({
      inputRoot: subject.inputRoot,
      environmentId: ENVIRONMENT,
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      repoRoot: process.cwd(),
      hostProbe: fixtureHost,
      gitHead: () => HEAD
    });
    return { ...subject, result };
  } catch (error) {
    cleanup(subject);
    throw error;
  }
}

function proof(subject) {
  const proofPath = path.join(subject.inputRoot, 'feature-artifacts', P34_PROOF_FILENAME);
  const bytes = fs.readFileSync(proofPath);
  return {
    path: proofPath,
    bytes,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length
  };
}

function cleanup(subject) {
  fs.rmSync(subject.root, { recursive: true, force: true });
}

test('P-34 capture emits candidate-bound metadata-only custody evidence and registration', () => {
  const subject = capture();
  try {
    assert.equal(subject.result.document.requirementId, 'P-34');
    assert.equal(subject.result.document.capture.mode, 'fixture');
    assert.equal(subject.result.document.capture.credentialsCreated, false);
    assert.equal(subject.result.document.capture.productionSecretsObserved, false);
    assert.deepEqual(subject.result.document.backends.map((row) => row.backendId), P34_BACKEND_IDS);
    assert.deepEqual(Object.keys(subject.result.document.backends[0].cases), P34_CASE_IDS);
    for (const backend of subject.result.document.backends) {
      assert.equal(backend.evidenceOrigin, 'contract-fixture');
      assert.equal(backend.cases.missing.passed, true);
      assert.equal(backend.cases.locked.fallback, 'none');
      assert.equal(backend.cases.rotation.oldAccepted, false);
      assert.equal(backend.cases.recovery.retryWithoutRestart, true);
      assert.equal(backend.cases.redaction.rendererRedacted, true);
    }
    const registration = JSON.parse(fs.readFileSync(subject.result.registration, 'utf8'));
    assert.deepEqual(registration.artifacts, [{ role: P34_PROOF_ROLE, path: `feature-artifacts/${P34_PROOF_FILENAME}` }]);
    validateP34CredentialSecurityProof({
      repoRoot: process.cwd(),
      snapshot: proof(subject),
      targetHead: HEAD,
      environmentId: ENVIRONMENT,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    });
  } finally {
    cleanup(subject);
  }
});

test('P-34 rejects stale checkout heads and symlinked evidence roots', () => {
  const subject = tempInput();
  try {
    assert.throws(() => captureP34CredentialSecurityProof({
      inputRoot: subject.inputRoot,
      environmentId: ENVIRONMENT,
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      repoRoot: process.cwd(),
      hostProbe: fixtureHost,
      gitHead: () => 'c'.repeat(40)
    }), /does not match checkout HEAD/u);

    const symlink = path.join(subject.root, 'symlinked-input');
    fs.symlinkSync(subject.inputRoot, symlink, 'dir');
    assert.throws(() => captureP34CredentialSecurityProof({
      inputRoot: symlink,
      environmentId: ENVIRONMENT,
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      repoRoot: process.cwd(),
      hostProbe: fixtureHost,
      gitHead: () => HEAD
    }), /traverses a symlink/u);
  } finally {
    cleanup(subject);
  }
});

test('P-34 validator rejects missing, locked, rotated, recovery, and redaction mutations', async () => {
  await assert.rejects(
    () => validateProductRequirement({}),
    /requirement release closure is not passed and invocation-bound/u
  );
  const subject = capture();
  try {
    const snapshot = proof(subject);
    const document = parseProofSnapshot(snapshot);
    const validate = () => validateP34CredentialSecurityProof({
      repoRoot: process.cwd(),
      snapshot: { ...snapshot, bytes: Buffer.from(`${JSON.stringify(document, null, 2)}\n`) },
      targetHead: HEAD,
      environmentId: ENVIRONMENT,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    });
    for (const [name, mutate, pattern] of [
      ['missing backend', (value) => { value.backends.pop(); }, /must cover GNOME Secret Service/u],
      ['locked fallback', (value) => { value.backends[0].cases.locked.fallback = 'explicit-headless-only'; }, /does not fail closed/u],
      ['old value accepted', (value) => { value.backends[1].cases.rotation.oldAccepted = true; }, /does not invalidate/u],
      ['restart required', (value) => { value.backends[2].cases.recovery.retryWithoutRestart = false; }, /repairable recovery/u],
      ['renderer leak', (value) => { value.backends[0].cases.redaction.rendererRedacted = false; }, /exposes credential material/u],
      ['secret bytes', (value) => { value.redaction.secretBytesCaptured = true; }, /redaction contract failed/u],
      ['environment substitution', (value) => { value.capture.desktop = 'KDE'; }, /host metadata does not match/u]
    ]) {
      const mutated = structuredClone(document);
      mutate(mutated);
      assert.throws(() => validateP34CredentialSecurityProof({
        repoRoot: process.cwd(),
        snapshot: { ...snapshot, bytes: Buffer.from(`${JSON.stringify(mutated, null, 2)}\n`) },
        targetHead: HEAD,
        environmentId: ENVIRONMENT,
        candidateRunId: RUN_ID,
        candidateArtifactDigest: DIGEST
      }), pattern, name);
    }
  } finally {
    cleanup(subject);
  }
});

test('P-34 materializer selects the candidate-bound credential security proof', () => {
  assert.throws(() => finalizeProductFeatureProofClosure([]), /--requirement is required/u);
  const registry = JSON.parse(fs.readFileSync('docs/linux-port/product-feature-proof-registry.json', 'utf8'));
  assert.deepEqual(registry.requirements.find((row) => row.requirementId === 'P-34')?.artifacts, [{
    role: P34_PROOF_ROLE,
    mediaType: 'application/json',
    maxBytes: 1_048_576
  }]);
});

test('P-34 validator rejects candidate substitution and source-contract drift', () => {
  const subject = capture();
  try {
    const snapshot = proof(subject);
    const document = parseProofSnapshot(snapshot);
    assert.throws(() => validateP34CredentialSecurityProof({
      repoRoot: process.cwd(),
      snapshot,
      targetHead: HEAD,
      environmentId: ENVIRONMENT,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: `sha256:${'f'.repeat(64)}`
    }), /candidate does not match/u);

    const drifted = structuredClone(document);
    drifted.sourceEvidence[0].sha256 = 'f'.repeat(64);
    assert.throws(() => validateP34CredentialSecurityProof({
      repoRoot: process.cwd(),
      snapshot: { ...snapshot, bytes: Buffer.from(`${JSON.stringify(drifted, null, 2)}\n`) },
      targetHead: HEAD,
      environmentId: ENVIRONMENT,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    }), /hash changed/u);
  } finally {
    cleanup(subject);
  }
});
