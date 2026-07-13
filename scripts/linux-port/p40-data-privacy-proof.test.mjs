import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { captureP40DataPrivacy } from './capture-p40-data-privacy.mjs';
import {
  P40_CASE_IDS,
  P40_DOMAIN_IDS,
  P40_PROOF_FILENAME,
  P40_PROOF_ROLE,
  canonicalCases,
  canonicalControls,
  parseP40Json,
  validateP40DataPrivacyProof
} from './lib/p40-data-privacy-proof.mjs';

const HEAD = 'a'.repeat(40);
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-x86_64';
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;

function tempInput() {
  const root = fs.mkdtempSync(path.join(process.cwd(), '.openburnbar-p40-proof-'));
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-40', ENVIRONMENT);
  fs.mkdirSync(inputRoot, { recursive: true });
  return { root, inputRoot };
}

function fixtureHost() {
  return {
    platform: 'linux',
    architecture: 'x86_64',
    desktop: 'GNOME fixture',
    session: 'x11',
    os: { id: 'ubuntu', versionId: '24.04' }
  };
}

function capture() {
  const subject = tempInput();
  try {
    const result = captureP40DataPrivacy({
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
  const proofPath = path.join(subject.inputRoot, 'feature-artifacts', P40_PROOF_FILENAME);
  const bytes = fs.readFileSync(proofPath);
  return {
    path: proofPath,
    bytes,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length
  };
}

function validate(subject, bytes = null, overrides = {}) {
  const snapshot = proof(subject);
  return validateP40DataPrivacyProof({
    repoRoot: process.cwd(),
    snapshot: bytes === null ? snapshot : { ...snapshot, bytes },
    targetHead: overrides.targetHead ?? HEAD,
    environmentId: overrides.environmentId ?? ENVIRONMENT,
    candidateRunId: overrides.candidateRunId ?? RUN_ID,
    candidateArtifactDigest: overrides.candidateArtifactDigest ?? DIGEST
  });
}

function cleanup(subject) {
  fs.rmSync(subject.root, { recursive: true, force: true });
}

test('P-40 capture emits a candidate-bound twelve-domain privacy contract', () => {
  const subject = capture();
  try {
    assert.equal(subject.result.document.requirementId, 'P-40');
    assert.equal(subject.result.document.capture.mode, 'fixture');
    assert.equal(subject.result.document.capture.evidenceOrigin, 'contract-fixture');
    assert.equal(subject.result.document.capture.piiObserved, false);
    assert.deepEqual(subject.result.document.inventory.domains.map((domain) => domain.id), P40_DOMAIN_IDS);
    assert.deepEqual(Object.keys(subject.result.document.cases), P40_CASE_IDS);
    assert.deepEqual(subject.result.document.controls, canonicalControls());
    assert.deepEqual(subject.result.document.cases, canonicalCases());
    const registration = JSON.parse(fs.readFileSync(subject.result.registration, 'utf8'));
    assert.deepEqual(registration.artifacts, [{ role: P40_PROOF_ROLE, path: `feature-artifacts/${P40_PROOF_FILENAME}` }]);
    validate(subject);
  } finally {
    cleanup(subject);
  }
});

test('P-40 capture rejects stale checkout heads and symlinked evidence roots', () => {
  const subject = tempInput();
  try {
    assert.throws(() => captureP40DataPrivacy({
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
    assert.throws(() => captureP40DataPrivacy({
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

test('P-40 validator rejects unsafe control, case, inventory, and environment substitutions', () => {
  const subject = capture();
  try {
    const snapshot = proof(subject);
    const document = parseP40Json(snapshot.bytes);
    const assertMutation = (name, mutate, pattern) => {
      const mutated = structuredClone(document);
      mutate(mutated);
      assert.throws(() => validate(subject, Buffer.from(`${JSON.stringify(mutated, null, 2)}\n`)), pattern, name);
    };
    assertMutation('export redaction', (value) => { value.controls.export.redacted = false; }, /export controls are incomplete/u);
    assertMutation('account deletion receipt', (value) => { value.controls.deletion.serverReceipt = false; }, /deletion controls are incomplete/u);
    assertMutation('telemetry default', (value) => { value.controls.consent.telemetryDefault = 'on'; }, /consent controls are incomplete/u);
    assertMutation('panic confirmation', (value) => { value.controls.panic.typedConfirmation = false; }, /panic controls are incomplete/u);
    assertMutation('case mutation', (value) => { value.cases['locked-keyring'].localPlaintextFallback = true; }, /unsafe or incomplete outcome/u);
    assertMutation('inventory substitution', (value) => { value.inventory.domains[0].id = 'other'; }, /does not match the macOS domain registry/u);
    assertMutation('environment substitution', (value) => { value.capture.desktop = 'KDE'; }, /host metadata does not match/u);
  } finally {
    cleanup(subject);
  }
});

test('P-40 validator rejects candidate substitution, source drift, and sensitive evidence', () => {
  const subject = capture();
  try {
    const snapshot = proof(subject);
    assert.throws(() => validate(subject, null, { candidateArtifactDigest: `sha256:${'f'.repeat(64)}` }), /candidate does not match/u);

    const document = parseP40Json(snapshot.bytes);
    const driftedSource = structuredClone(document);
    driftedSource.sourceEvidence[0].sha256 = 'f'.repeat(64);
    assert.throws(() => validate(subject, Buffer.from(`${JSON.stringify(driftedSource, null, 2)}\n`)), /hash changed/u);

    const sensitive = structuredClone(document);
    sensitive.cases['export-redaction'].leak = 'Bearer abcdefghijklmnop';
    assert.throws(() => validate(subject, Buffer.from(`${JSON.stringify(sensitive, null, 2)}\n`)), /fields must be exactly/u);
  } finally {
    cleanup(subject);
  }
});
