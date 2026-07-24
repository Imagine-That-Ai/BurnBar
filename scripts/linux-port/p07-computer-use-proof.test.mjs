import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { validateProductRequirement } from './product-validators/P-07.mjs';

const HEAD = 'a'.repeat(40);
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-x86_64';
const CANDIDATE = { runId: '12345', artifactDigest: `sha256:${'b'.repeat(64)}` };
const TARGETS = [
  'VAL-CU-001',
  'VAL-CU-002',
  'VAL-CU-003',
  'VAL-MEDIA-001',
  'VAL-MOBILE-001',
  'VAL-SEC-003'
];
const ROOT_PREFIX = `docs/linux-port/evidence/product-parity-inputs/P-07/${ENVIRONMENT}`;

function write(root, relativePath, bytes) {
  const file = path.join(root, relativePath);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  return file;
}

function writeJson(root, relativePath, value) {
  return write(root, relativePath, `${JSON.stringify(value, null, 2)}\n`);
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function record(root, relativePath) {
  const file = path.join(root, relativePath);
  return { path: relativePath, sha256: sha256(file), size: fs.statSync(file).size };
}

function createFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p07-validator-'));
  const environment = {
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    architecture: 'x86_64',
    passed: true
  };
  const manifest = {
    packageVersion: '1.2.3',
    gitCommit: HEAD,
    packageArchitecture: 'x86_64',
    packageFormat: 'deb'
  };
  const runtime = { shellVersion: '1.2.3', daemonVersion: '1.2.3' };
  const files = {
    aggregate: `${ROOT_PREFIX}/aggregate.json`,
    manifest: `${ROOT_PREFIX}/installed-manifest.json`,
    signature: `${ROOT_PREFIX}/installed-manifest.sig`,
    package: `${ROOT_PREFIX}/installed-package.deb`,
    runtime: `${ROOT_PREFIX}/runtime.json`,
    environment: `${ROOT_PREFIX}/environment.json`,
    feature: `${ROOT_PREFIX}/release-subjects/00-feature-computer-use-proof.json`
  };
  write(root, files.aggregate, 'aggregate\n');
  writeJson(root, files.manifest, manifest);
  write(root, files.signature, 'signature\n');
  write(root, files.package, 'package\n');
  writeJson(root, files.runtime, runtime);
  writeJson(root, files.environment, environment);

  const sourceEvidence = TARGETS.map((target) => {
    const relativePath = `${ROOT_PREFIX}/source/${target}.json`;
    writeJson(root, relativePath, { target, passed: true });
    return record(root, relativePath);
  });
  const targetRows = Object.fromEntries(TARGETS.map((target) => [target, {
    target,
    status: 'pass',
    acceptedAsPass: true,
    notClaimedAsPass: false,
    prerequisite: target === 'VAL-CU-003' ? 'VAL-CU-002' : undefined,
    evidence: [sourceEvidence.find((row) => row.path.endsWith(`/${target}.json`)).path],
    failures: [],
    blockers: []
  }]));
  const proof = {
    schemaVersion: 1,
    id: 'openburnbar-linux-computer-use-proof-v1',
    requirementId: 'P-07',
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidate: CANDIDATE,
    targetIds: TARGETS,
    rejectionPolicy: {
      fixtureOnlyRowsAcceptedAsPass: false,
      staleTmpOnlyRowsAcceptedAsPass: false,
      panicSessionMediaSimulatorOnlyAcceptedAsPass: false,
      dockerHttpMobileRemoteOnlyAcceptedAsPass: false,
      x11OrXtestFallbackAcceptedAsPass: false,
      mediaSimulatorTimingOnlyAcceptedAsPass: false
    },
    targets: targetRows,
    failedTargets: [],
    sourceEvidence
  };
  writeJson(root, files.feature, proof);
  const closure = {
    schemaVersion: 3,
    targetHead: HEAD,
    sourceCommit: HEAD,
    status: 'passed',
    requirementId: 'P-07',
    environmentId: ENVIRONMENT,
    version: '1.2.3',
    architectures: ['aarch64', 'x86_64'],
    supportEnvironments: [
      'ubuntu-24.04-gnome-x11-x86_64',
      'ubuntu-24.04-gnome-x11-aarch64',
      'ubuntu-24.04-gnome-wayland-x86_64',
      'ubuntu-24.04-gnome-wayland-aarch64',
      'fedora-kde-wayland-x86_64',
      'fedora-kde-wayland-aarch64',
      'arch-sway-wayland-x86_64'
    ],
    selectedPackage: { architecture: 'x86_64', format: 'deb' },
    candidate: { ...CANDIDATE, productProofClosureSha256: 'c'.repeat(64) },
    packageManifest: record(root, files.manifest),
    packageManifestSignature: record(root, files.signature),
    packages: [record(root, files.package)],
    proofs: [
      { role: 'aggregate-product-proof-closure', ...record(root, files.aggregate) },
      { role: 'feature.computer-use', evidenceClass: 'feature', mediaType: 'application/json', ...record(root, files.feature) }
    ],
    blockers: []
  };
  const releasePath = `${ROOT_PREFIX}/release-closure.json`;
  const releaseFile = writeJson(root, releasePath, closure);
  const release = { path: releasePath, sha256: sha256(releaseFile) };
  const context = {
    schemaVersion: 1,
    repoRoot: root,
    requirementId: 'P-07',
    checkId: 'p-07.computer-use',
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: { ...release, document: closure },
    subjects: {
      release,
      packageManifest: record(root, files.manifest),
      packageManifestSignature: record(root, files.signature),
      packages: [record(root, files.package)],
      features: [{ role: 'feature.computer-use', mediaType: 'application/json', ...record(root, files.feature) }],
      runtimes: [record(root, files.runtime)],
      installation: [],
      environment: record(root, files.environment)
    }
  };
  return { root, context, proof, files, sourceEvidence };
}

function cleanup(fixture) {
  fs.rmSync(fixture.root, { recursive: true, force: true });
}

function refreshFeatureHash(fixture) {
  const feature = record(fixture.root, fixture.files.feature);
  fixture.context.subjects.features[0].sha256 = feature.sha256;
  const closureProof = fixture.context.releaseClosure.document.proofs
    .find((proof) => proof.role === 'feature.computer-use');
  closureProof.sha256 = feature.sha256;
  closureProof.size = feature.size;
}

test('P-07 validator accepts a candidate-bound six-target computer-use proof', async () => {
  const fixture = createFixture();
  try {
    const receipt = await validateProductRequirement(fixture.context);
    assert.equal(receipt.status, 'passed');
    assert.equal(receipt.requirementId, 'P-07');
    for (const row of fixture.sourceEvidence) {
      assert.ok(receipt.artifacts.some((artifact) => artifact.path === row.path && artifact.sha256 === row.sha256));
    }
  } finally {
    cleanup(fixture);
  }
});

test('P-07 validator rejects target, candidate, rejection-policy, and source mutations', async () => {
  for (const [name, mutate, pattern] of [
    ['target status', (proof) => { proof.targets['VAL-CU-002'].status = 'blocked'; }, /not an accepted pass/u],
    ['candidate substitution', (proof) => { proof.candidate.artifactDigest = `sha256:${'f'.repeat(64)}`; }, /candidate binding/u],
    ['unsafe fallback policy', (proof) => { proof.rejectionPolicy.x11OrXtestFallbackAcceptedAsPass = true; }, /rejection policy/u],
    ['source hash substitution', (proof) => { proof.sourceEvidence[0].sha256 = 'f'.repeat(64); }, /source evidence hash changed/u]
  ]) {
      const fixture = createFixture();
    try {
      mutate(fixture.proof);
      writeJson(fixture.root, fixture.files.feature, fixture.proof);
      refreshFeatureHash(fixture);
      await assert.rejects(() => validateProductRequirement(fixture.context), pattern, name);
    } finally {
      cleanup(fixture);
    }
  }
});

test('P-07 validator rejects an unbound historical product-computer-use summary', async () => {
  const fixture = createFixture();
  try {
    delete fixture.proof.candidate;
    delete fixture.proof.targetHead;
    writeJson(fixture.root, fixture.files.feature, fixture.proof);
    refreshFeatureHash(fixture);
    await assert.rejects(
      () => validateProductRequirement(fixture.context),
      /not bound to the invoked requirement, environment, or HEAD/u
    );
  } finally {
    cleanup(fixture);
  }
});
