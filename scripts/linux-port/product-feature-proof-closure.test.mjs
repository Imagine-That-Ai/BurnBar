import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  MAX_FEATURE_PROOF_ARTIFACT_BYTES,
  MAX_FEATURE_PROOF_CONTRACT_BYTES,
  MAX_FEATURE_PROOF_ROLES_PER_REQUIREMENT,
  finalizeProductFeatureProofClosure,
  validateProductFeatureProofClosure
} from './lib/product-feature-proof.mjs';
import { validateAggregateDocument } from './lib/product-proof-closure.mjs';

const HEAD = 'a'.repeat(40);
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-x86_64';
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;

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

function record(root, file) {
  return {
    path: path.relative(root, file).split(path.sep).join('/'),
    sha256: sha256(file),
    size: fs.statSync(file).size
  };
}

function fixture({ registered = true, maxBytes = 4096 } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-feature-proof-'));
  for (const relative of [
    'docs/linux-port/product-parity-requirements.json',
    'schemas/linux-product-feature-proof-registry.schema.json',
    'schemas/linux-product-feature-proof-registration.schema.json',
    'schemas/linux-product-feature-proof-closure.schema.json'
  ]) {
    fs.mkdirSync(path.dirname(path.join(root, relative)), { recursive: true });
    fs.copyFileSync(path.resolve(relative), path.join(root, relative));
  }
  const inputRoot = path.join(
    root,
    'docs/linux-port/evidence/product-parity-inputs/P-02',
    ENVIRONMENT
  );
  const releaseRoot = path.join(inputRoot, '.linux-release');
  const registryFile = writeJson(path.join(releaseRoot, 'sidecars/product-feature-proof-registry.json'), {
    schemaVersion: 1,
    id: 'openburnbar-linux-product-feature-proof-registry-v1',
    requirements: registered ? [{
      requirementId: 'P-02',
      artifacts: [
        { role: 'feature.parity-report', mediaType: 'application/json', maxBytes },
        { role: 'feature.visual-capture', mediaType: 'image/png', maxBytes }
      ]
    }] : []
  });
  const architectures = ['aarch64', 'x86_64'];
  const releaseArtifacts = ['appimage', 'daemon', 'deb', 'rpm'].flatMap((type) =>
    architectures.map((architecture) => ({
      type,
      architecture,
      artifact: { path: `${type}-${architecture}`, sha256: 'c'.repeat(64) },
      detachedSignature: { path: `${type}-${architecture}.sig`, sha256: 'd'.repeat(64) },
      sigstore: { path: `${type}-${architecture}.sigstore`, sha256: 'e'.repeat(64) }
    }))
  );
  const packages = ['deb', 'rpm'].flatMap((format) => architectures.map((architecture) => ({
    format,
    architecture,
    artifact: { path: `${format}-${architecture}`, sha256: 'c'.repeat(64) },
    installedManifest: { path: `${format}-${architecture}.json`, sha256: 'd'.repeat(64) },
    installedManifestSignature: { path: `${format}-${architecture}.json.sig`, sha256: 'e'.repeat(64) }
  })));
  const aggregate = {
    schemaVersion: 2,
    generatedAt: new Date(0).toISOString(),
    targetHead: HEAD,
    sourceCommit: HEAD,
    status: 'passed',
    stage: 'candidate',
    git: { commit: HEAD, dirty: false },
    version: '1.2.3',
    architectures,
    supportEnvironments: [
      'ubuntu-24.04-gnome-x11-x86_64',
      'ubuntu-24.04-gnome-x11-aarch64',
      'ubuntu-24.04-gnome-wayland-x86_64',
      'ubuntu-24.04-gnome-wayland-aarch64',
      'fedora-kde-wayland-x86_64',
      'fedora-kde-wayland-aarch64',
      'arch-sway-wayland-x86_64'
    ],
    releaseArtifacts,
    packages,
    featureProofRegistry: record(releaseRoot, registryFile),
    proofs: [{ role: 'release-placeholder' }],
    blockers: []
  };
  const aggregateFile = writeJson(path.join(releaseRoot, 'product-proof-closure.json'), aggregate);
  return { root, inputRoot, releaseRoot, registryFile, aggregate, aggregateFile };
}

function registerEvidence(subject, artifacts = [
  { role: 'feature.parity-report', path: 'feature-artifacts/parity-report.json' },
  { role: 'feature.visual-capture', path: 'feature-artifacts/capture.png' }
]) {
  writeJson(path.join(subject.inputRoot, 'feature-artifacts/parity-report.json'), { observed: true });
  write(path.join(subject.inputRoot, 'feature-artifacts/capture.png'), Buffer.from('png evidence'));
  writeJson(path.join(subject.inputRoot, 'feature-proof-registration.json'), {
    schemaVersion: 1,
    requirementId: 'P-02',
    environmentId: ENVIRONMENT,
    artifacts
  });
}

function replaceRegistryArtifacts(subject, artifacts) {
  writeJson(subject.registryFile, {
    schemaVersion: 1,
    id: 'openburnbar-linux-product-feature-proof-registry-v1',
    requirements: [{ requirementId: 'P-02', artifacts }]
  });
  subject.aggregate.featureProofRegistry = record(subject.releaseRoot, subject.registryFile);
  writeJson(subject.aggregateFile, subject.aggregate);
}

function finalize(subject, overrides = {}) {
  return finalizeProductFeatureProofClosure({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    requirementId: 'P-02',
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    ...overrides
  });
}

test('feature closure binds the exact registry, candidate, product, environment, roles, and bytes', (t) => {
  const subject = fixture();
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  registerEvidence(subject);
  const result = finalize(subject);
  assert.equal(result.registered, true);
  assert.equal(result.closure.status, 'collected');
  assert.equal(Object.hasOwn(result.closure, 'passed'), false);
  assert.deepEqual(result.closure.candidate, {
    runId: RUN_ID,
    artifactDigest: DIGEST,
    productProofClosureSha256: sha256(subject.aggregateFile)
  });
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [
    'feature.parity-report',
    'feature.visual-capture'
  ]);
  const aggregateSnapshot = {
    path: 'product-proof-closure.json',
    absolute: subject.aggregateFile,
    bytes: fs.readFileSync(subject.aggregateFile),
    sha256: sha256(subject.aggregateFile),
    size: fs.statSync(subject.aggregateFile).size
  };
  const validated = validateProductFeatureProofClosure({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    aggregate: validateAggregateDocument(subject.aggregate),
    aggregateSnapshot,
    requirementId: 'P-02',
    environmentId: ENVIRONMENT,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST
  });
  assert.equal(validated.proofs.length, 2);
});

test('feature closure finalization rejects missing, extra, duplicate, symlinked, and oversized artifacts', async (t) => {
  const cases = [
    ['missing role', (subject) => registerEvidence(subject, [
      { role: 'feature.parity-report', path: 'feature-artifacts/parity-report.json' }
    ]), /must contain exactly 2 artifacts/u],
    ['extra role', (subject) => registerEvidence(subject, [
      { role: 'feature.parity-report', path: 'feature-artifacts/parity-report.json' },
      { role: 'feature.visual-capture', path: 'feature-artifacts/capture.png' },
      { role: 'feature.unregistered', path: 'feature-artifacts/capture.png' }
    ]), /must contain exactly 2 artifacts/u],
    ['duplicate role', (subject) => registerEvidence(subject, [
      { role: 'feature.parity-report', path: 'feature-artifacts/parity-report.json' },
      { role: 'feature.parity-report', path: 'feature-artifacts/capture.png' }
    ]), /roles must be exactly/u],
    ['symlink', (subject) => {
      registerEvidence(subject);
      fs.rmSync(path.join(subject.inputRoot, 'feature-artifacts/capture.png'));
      fs.symlinkSync('/etc/hosts', path.join(subject.inputRoot, 'feature-artifacts/capture.png'));
    }, /traverses a symlink/u],
    ['oversized', (subject) => {
      registerEvidence(subject);
      write(path.join(subject.inputRoot, 'feature-artifacts/capture.png'), Buffer.alloc(5000));
    }, /exceeds its 4096-byte limit/u],
    ['empty', (subject) => {
      registerEvidence(subject);
      write(path.join(subject.inputRoot, 'feature-artifacts/capture.png'), Buffer.alloc(0));
    }, /must not be empty/u],
    ['reused bytes', (subject) => {
      registerEvidence(subject);
      fs.copyFileSync(
        path.join(subject.inputRoot, 'feature-artifacts/parity-report.json'),
        path.join(subject.inputRoot, 'feature-artifacts/capture.png')
      );
    }, /reuses bytes/u]
  ];
  for (const [name, mutate, pattern] of cases) {
    await t.test(name, () => {
      const subject = fixture();
      t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
      writeJson(path.join(subject.inputRoot, 'feature-proof-closure.json'), { stale: true });
      mutate(subject);
      assert.throws(() => finalize(subject), pattern);
      assert.equal(fs.existsSync(path.join(subject.inputRoot, 'feature-proof-closure.json')), false);
    });
  }
});

test('feature registry rejects role-count and byte-budget exhaustion before reading proof payloads', async (t) => {
  const cases = [
    ['role count', Array.from({ length: MAX_FEATURE_PROOF_ROLES_PER_REQUIREMENT + 1 }, (_, index) => ({
      role: `feature.proof-${String(index).padStart(2, '0')}`,
      mediaType: 'application/json',
      maxBytes: 1
    })), /must NOT have more than 16 items/u],
    ['per-artifact bytes', [
      {
        role: 'feature.proof-00',
        mediaType: 'application/json',
        maxBytes: MAX_FEATURE_PROOF_ARTIFACT_BYTES + 1
      }
    ], new RegExp(`must be <= ${MAX_FEATURE_PROOF_ARTIFACT_BYTES}`)],
    ['aggregate bytes', [
      { role: 'feature.proof-00', mediaType: 'application/json', maxBytes: MAX_FEATURE_PROOF_ARTIFACT_BYTES },
      { role: 'feature.proof-01', mediaType: 'application/json', maxBytes: MAX_FEATURE_PROOF_ARTIFACT_BYTES },
      { role: 'feature.proof-02', mediaType: 'application/json', maxBytes: 1 }
    ], new RegExp(`exceeds the ${MAX_FEATURE_PROOF_CONTRACT_BYTES}-byte aggregate feature proof budget`)]
  ];
  for (const [name, artifacts, pattern] of cases) {
    await t.test(name, () => {
      const subject = fixture();
      t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
      replaceRegistryArtifacts(subject, artifacts);
      assert.equal(fs.existsSync(path.join(subject.inputRoot, 'feature-proof-registration.json')), false);
      assert.throws(() => finalize(subject), pattern);
      assert.equal(fs.existsSync(path.join(subject.inputRoot, 'feature-proof-closure.json')), false);
    });
  }
});

test('feature closure validation rejects post-finalization mutation and candidate substitution', () => {
  const subject = fixture();
  registerEvidence(subject);
  finalize(subject);
  const aggregateSnapshot = {
    path: 'product-proof-closure.json',
    absolute: subject.aggregateFile,
    bytes: fs.readFileSync(subject.aggregateFile),
    sha256: sha256(subject.aggregateFile),
    size: fs.statSync(subject.aggregateFile).size
  };
  writeJson(path.join(subject.inputRoot, 'feature-artifacts/parity-report.json'), { observed: false });
  assert.throws(() => validateProductFeatureProofClosure({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    aggregate: validateAggregateDocument(subject.aggregate),
    aggregateSnapshot,
    requirementId: 'P-02',
    environmentId: ENVIRONMENT,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST
  }), /SHA-256 does not match/u);
  assert.throws(() => validateProductFeatureProofClosure({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    aggregate: validateAggregateDocument(subject.aggregate),
    aggregateSnapshot,
    requirementId: 'P-02',
    environmentId: ENVIRONMENT,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: `sha256:${'f'.repeat(64)}`
  }), /not bound to the exact candidate/u);
  assert.throws(() => validateProductFeatureProofClosure({
    repoRoot: subject.root,
    inputRoot: subject.inputRoot,
    aggregate: validateAggregateDocument(subject.aggregate),
    aggregateSnapshot,
    requirementId: 'P-02',
    environmentId: 'ubuntu-24.04-gnome-wayland-x86_64',
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST
  }), /not bound to the exact candidate, product, and environment/u);
  fs.rmSync(subject.root, { recursive: true, force: true });
});

test('feature closure validation rejects missing closure, registry substitution, and duplicate subject reuse', async (t) => {
  await t.test('missing closure', () => {
    const subject = fixture();
    registerEvidence(subject);
    finalize(subject);
    fs.rmSync(path.join(subject.inputRoot, 'feature-proof-closure.json'));
    const aggregateSnapshot = {
      absolute: subject.aggregateFile,
      sha256: sha256(subject.aggregateFile),
      size: fs.statSync(subject.aggregateFile).size
    };
    assert.throws(() => validateProductFeatureProofClosure({
      repoRoot: subject.root,
      inputRoot: subject.inputRoot,
      aggregate: validateAggregateDocument(subject.aggregate),
      aggregateSnapshot,
      requirementId: 'P-02',
      environmentId: ENVIRONMENT,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    }), /product feature proof closure/u);
    fs.rmSync(subject.root, { recursive: true, force: true });
  });
  await t.test('registry substitution', () => {
    const subject = fixture();
    registerEvidence(subject);
    finalize(subject);
    const closurePath = path.join(subject.inputRoot, 'feature-proof-closure.json');
    const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
    const duplicateRegistry = write(
      path.join(subject.inputRoot, 'feature-artifacts/registry.json'),
      fs.readFileSync(subject.registryFile)
    );
    closure.registry = record(subject.root, duplicateRegistry);
    writeJson(closurePath, closure);
    const aggregateSnapshot = {
      absolute: subject.aggregateFile,
      sha256: sha256(subject.aggregateFile),
      size: fs.statSync(subject.aggregateFile).size
    };
    assert.throws(() => validateProductFeatureProofClosure({
      repoRoot: subject.root,
      inputRoot: subject.inputRoot,
      aggregate: validateAggregateDocument(subject.aggregate),
      aggregateSnapshot,
      requirementId: 'P-02',
      environmentId: ENVIRONMENT,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    }), /does not match the candidate registry/u);
    fs.rmSync(subject.root, { recursive: true, force: true });
  });
  await t.test('duplicate subject reuse', () => {
    const subject = fixture();
    registerEvidence(subject);
    finalize(subject);
    const closurePath = path.join(subject.inputRoot, 'feature-proof-closure.json');
    const closure = JSON.parse(fs.readFileSync(closurePath, 'utf8'));
    closure.proofs[1].path = closure.proofs[0].path;
    closure.proofs[1].sha256 = closure.proofs[0].sha256;
    closure.proofs[1].size = closure.proofs[0].size;
    writeJson(closurePath, closure);
    const aggregateSnapshot = {
      absolute: subject.aggregateFile,
      sha256: sha256(subject.aggregateFile),
      size: fs.statSync(subject.aggregateFile).size
    };
    assert.throws(() => validateProductFeatureProofClosure({
      repoRoot: subject.root,
      inputRoot: subject.inputRoot,
      aggregate: validateAggregateDocument(subject.aggregate),
      aggregateSnapshot,
      requirementId: 'P-02',
      environmentId: ENVIRONMENT,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    }), /repeats subject path/u);
    fs.rmSync(subject.root, { recursive: true, force: true });
  });
});

test('unregistered requirements cannot smuggle registrations or leave stale closures', () => {
  const subject = fixture({ registered: false });
  const stale = writeJson(path.join(subject.inputRoot, 'feature-proof-closure.json'), { stale: true });
  const empty = finalize(subject);
  assert.equal(empty.registered, false);
  assert.equal(fs.existsSync(stale), false);
  registerEvidence(subject);
  assert.throws(() => finalize(subject), /no feature proof contract is registered/u);
  fs.rmSync(subject.root, { recursive: true, force: true });
});
