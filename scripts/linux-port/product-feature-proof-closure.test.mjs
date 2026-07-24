import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { main as runFeatureProofMaterializer } from './finalize-product-feature-proof-closure.mjs';
import { P06_PROOF_ROLE } from './lib/p06-gateway-credential-boundary-proof.mjs';
import { P08_PROOF_ROLE } from './lib/p08-mercury-media-proof.mjs';
import { P09_PROOF_ROLE } from './lib/p09-navigation-shell-proof.mjs';
import { P10_PROOF_ROLE } from './lib/p10-dashboard-layout-proof.mjs';
import { P11_PROOF_ROLE } from './lib/p11-usage-ingestion-proof.mjs';
import { P12_PROOF_ROLE } from './lib/p12-quota-proof.mjs';
import { P13_PROOF_ROLE } from './lib/p13-onboarding-proof.mjs';
import { P14_PROOF_ROLE } from './lib/p14-chat-proof.mjs';
import { P15_PROOF_ROLE } from './lib/p15-account-billing-proof.mjs';
import { P16_PROOF_ROLE } from './lib/p16-cloud-devices-proof.mjs';
import { P17_PROOF_ROLE } from './lib/p17-activity-proof.mjs';
import { P18_PROOF_ROLE } from './lib/p18-memory-review-proof.mjs';
import { P19_PROOF_ROLE } from './lib/p19-projects-proof.mjs';
import { P20_PROOF_ROLE } from './lib/p20-missions-proof.mjs';
import { P21_PROOF_ROLE } from './lib/p21-insights-proof.mjs';
import { P22_PROOF_ROLE } from './lib/p22-database-proof.mjs';
import { P23_PROOF_ROLE } from './lib/p23-provider-workspace-proof.mjs';
import { P24_PROOF_ROLE } from './lib/p24-settings-proof.mjs';
import { P25_PROOF_ROLE } from './lib/p25-updates-proof.mjs';
import { P26_PROOF_ROLE } from './lib/p26-tray-proof.mjs';
import { P27_PROOF_ROLE } from './lib/p27-notifications-proof.mjs';
import { P28_PROOF_ROLE } from './lib/p28-smarthub-proof.mjs';
import { P29_PROOF_ROLE } from './lib/p29-text-expansion-proof.mjs';
import { P30_PROOF_ROLE } from './lib/p30-pet-proof.mjs';
import { P32_PROOF_ROLE } from './lib/p32-performance-proof.mjs';
import { P33_PROOF_ROLE } from './lib/p33-reliability-proof.mjs';
import { P35_PROOF_ROLE } from './lib/p35-diagnostics-support-proof.mjs';
import { P36_PROOF_ROLE } from './lib/p36-visual-polish-proof.mjs';
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

function aggregateAttestationSubjects(releaseArtifacts, packages) {
  const row = (role, format = null, architecture = null) => {
    const suffix = [role, format, architecture].filter(Boolean).join('-');
    const subjectPath = `attestations/${suffix}`;
    return {
      role,
      ...(format ? { format } : {}),
      ...(architecture ? { architecture } : {}),
      subject: { path: subjectPath, sha256: '1'.repeat(64), size: 1 },
      bundle: { path: `${subjectPath}.sigstore.json`, sha256: '2'.repeat(64), size: 1 }
    };
  };
  return [
    ...releaseArtifacts.map((artifact) => row('release-artifact', artifact.type, artifact.architecture)),
    ...packages.flatMap((entry) => [
      row('installed-manifest', entry.format, entry.architecture),
      row('installed-manifest-signature', entry.format, entry.architecture)
    ]),
    ...[
      'checksums', 'sbom', 'vex', 'provenance', 'source-archive',
      'arch-pkgbuild', 'arch-release-metadata', 'update-feed'
    ].map((role) => row(role))
  ];
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
  const releaseArtifacts = ['appimage', 'arch', 'daemon', 'deb', 'rpm'].flatMap((type) =>
    architectures.map((architecture) => ({
      type,
      architecture,
      artifact: { path: `${type}-${architecture}`, sha256: 'c'.repeat(64) },
      detachedSignature: { path: `${type}-${architecture}.sig`, sha256: 'd'.repeat(64) },
      sigstore: { path: `${type}-${architecture}.sigstore`, sha256: 'e'.repeat(64) }
    }))
  );
  const packages = ['arch', 'deb', 'rpm'].flatMap((format) => architectures.map((architecture) => ({
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
    attestationSubjects: aggregateAttestationSubjects(releaseArtifacts, packages),
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

function materializeSingleFeatureProof(requirementId, role) {
  const subject = fixture({ registered: false });
  const artifactPath = `feature-artifacts/${requirementId.toLowerCase()}-proof.json`;
  writeJson(subject.registryFile, {
    schemaVersion: 1,
    id: 'openburnbar-linux-product-feature-proof-registry-v1',
    requirements: [{
      requirementId,
      artifacts: [{ role, mediaType: 'application/json', maxBytes: 1048576 }]
    }]
  });
  subject.aggregate.featureProofRegistry = record(subject.releaseRoot, subject.registryFile);
  writeJson(subject.aggregateFile, subject.aggregate);
  writeJson(path.join(subject.inputRoot, artifactPath), {
    requirementId,
    targetHead: HEAD,
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    observed: true
  });
  writeJson(path.join(subject.inputRoot, 'feature-proof-registration.json'), {
    schemaVersion: 1,
    requirementId,
    environmentId: ENVIRONMENT,
    artifacts: [{ role, path: artifactPath }]
  });
  const result = runFeatureProofMaterializer([
    '--requirement', requirementId,
    '--environment', ENVIRONMENT,
    '--input-root', subject.inputRoot,
    '--target-head', HEAD,
    '--candidate-run-id', RUN_ID,
    '--candidate-artifact-digest', DIGEST
  ], subject.root);
  return { subject, result };
}

test('P-02 materializer CLI materializes the exact candidate registration', (t) => {
  const subject = fixture();
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  registerEvidence(subject);
  const result = runFeatureProofMaterializer([
    '--requirement', 'P-02',
    '--environment', ENVIRONMENT,
    '--input-root', subject.inputRoot,
    '--target-head', HEAD,
    '--candidate-run-id', RUN_ID,
    '--candidate-artifact-digest', DIGEST
  ], subject.root);
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-02');
  assert.equal(result.closure.environmentId, ENVIRONMENT);
  assert.deepEqual(result.closure.candidate, {
    runId: RUN_ID,
    artifactDigest: DIGEST,
    productProofClosureSha256: sha256(subject.aggregateFile)
  });
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [
    'feature.parity-report',
    'feature.visual-capture'
  ]);
  assert.equal(fs.existsSync(result.output), true);
});

test('P-06 materializer selects the candidate-bound gateway boundary proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof(
    'P-06',
    P06_PROOF_ROLE
  );
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-06');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P06_PROOF_ROLE]);
});

test('P-06 feature registry role matches the installed gateway boundary producer', () => {
  const registry = JSON.parse(fs.readFileSync(
    'docs/linux-port/product-feature-proof-registry.json',
    'utf8'
  ));
  const contract = registry.requirements.find((entry) => entry.requirementId === 'P-06');
  assert.deepEqual(contract.artifacts.map((artifact) => artifact.role), [P06_PROOF_ROLE]);
});

test('P-07 materializer selects the candidate-bound computer-use proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-07', 'feature.computer-use');
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-07');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), ['feature.computer-use']);
});

test('P-08 materializer selects the installed Mercury media proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-08', P08_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-08');
  assert.deepEqual(result.closure.candidate, {
    runId: RUN_ID,
    artifactDigest: DIGEST,
    productProofClosureSha256: sha256(subject.aggregateFile)
  });
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P08_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-09 materializer selects the installed navigation shell proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-09', P09_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-09');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P09_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-10 materializer selects the installed dashboard layout proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-10', P10_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-10');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P10_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-11 materializer selects the installed usage ingestion proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-11', P11_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-11');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P11_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-12 materializer selects the installed quota proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-12', P12_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-12');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P12_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-13 materializer selects the installed onboarding proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-13', P13_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-13');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P13_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-14 materializer selects the installed chat proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-14', P14_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-14');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P14_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-15 materializer selects the installed account and billing proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-15', P15_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-15');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P15_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-16 materializer selects the installed cloud and devices proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-16', P16_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-16');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P16_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-17 materializer selects the installed Activity proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-17', P17_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-17');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P17_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test("P-18 materializer selects the installed memory-review proof", (t) => {
  const { subject, result } = materializeSingleFeatureProof(
    "P-18",
    P18_PROOF_ROLE,
  );
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, "P-18");
  assert.deepEqual(
    result.closure.proofs.map((proof) => proof.role),
    [P18_PROOF_ROLE],
  );
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test("P-19 materializer selects the installed Projects proof", (t) => {
  const { subject, result } = materializeSingleFeatureProof(
    "P-19",
    P19_PROOF_ROLE,
  );
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, "P-19");
  assert.deepEqual(
    result.closure.proofs.map((proof) => proof.role),
    [P19_PROOF_ROLE],
  );
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test("P-20 materializer selects the installed Missions proof", (t) => {
  const { subject, result } = materializeSingleFeatureProof(
    "P-20",
    P20_PROOF_ROLE,
  );
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, "P-20");
  assert.deepEqual(
    result.closure.proofs.map((proof) => proof.role),
    [P20_PROOF_ROLE],
  );
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test("P-21 materializer selects the installed Insights proof", (t) => {
  const { subject, result } = materializeSingleFeatureProof(
    "P-21",
    P21_PROOF_ROLE,
  );
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, "P-21");
  assert.deepEqual(
    result.closure.proofs.map((proof) => proof.role),
    [P21_PROOF_ROLE],
  );
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test("P-22 materializer selects the installed Database proof", (t) => {
  const { subject, result } = materializeSingleFeatureProof(
    "P-22",
    P22_PROOF_ROLE,
  );
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, "P-22");
  assert.deepEqual(
    result.closure.proofs.map((proof) => proof.role),
    [P22_PROOF_ROLE],
  );
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-23 materializer selects the installed Provider workspace proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-23', P23_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-23');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P23_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-24 materializer selects the installed Settings proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-24', P24_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-24');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P24_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-25 materializer selects the installed Updates proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-25', P25_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-25');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P25_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-26 materializer selects the installed tray proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-26', P26_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-26');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P26_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-27 materializer selects the installed notification/deep-link proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-27', P27_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-27');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P27_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-28 materializer selects the installed SmartHub proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-28', P28_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-28');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P28_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-29 materializer selects the installed text-expansion proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-29', P29_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-29');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P29_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-30 materializer selects the installed pet proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-30', P30_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-30');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P30_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-32 materializer selects the installed performance proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-32', P32_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-32');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P32_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-33 materializer selects the installed reliability proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-33', P33_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-33');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P33_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-35 materializer selects the installed diagnostics and support proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-35', P35_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-35');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P35_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

test('P-36 materializer selects the installed visual and interaction polish proof', (t) => {
  const { subject, result } = materializeSingleFeatureProof('P-36', P36_PROOF_ROLE);
  t.after(() => fs.rmSync(subject.root, { recursive: true, force: true }));
  assert.equal(result.registered, true);
  assert.equal(result.closure.requirementId, 'P-36');
  assert.deepEqual(result.closure.proofs.map((proof) => proof.role), [P36_PROOF_ROLE]);
  const proof = result.closure.proofs[0];
  assert.equal(proof.sha256, sha256(path.join(subject.root, proof.path)));
});

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
