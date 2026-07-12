import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { finalizeProductProofClosure } from './finalize-product-proof-closure.mjs';
import { finalizeProductFeatureProofClosure } from './lib/product-feature-proof.mjs';
import { finalizeLinuxPromotionClosure } from './finalize-linux-promotion-closure.mjs';
import { prepareProductRequirementInput } from './prepare-product-requirement-input.mjs';
import { validateProductRequirement as validateP01 } from './product-validators/P-01.mjs';
import { validateProductRequirement as validateP03 } from './product-validators/P-03.mjs';
import { validateProductRequirement as validateP04 } from './product-validators/P-04.mjs';
import { validateProductRequirement as validateP37 } from './product-validators/P-37.mjs';
import { validateProductRequirement as validateP38 } from './product-validators/P-38.mjs';
import {
  archPkgbuildCommonSources,
  materializeArchReleaseMetadata
} from './lib/linux-arch-pkgbuild.mjs';
import { deriveReleaseAttestationSubjects } from './lib/product-proof-closure.mjs';
import {
  P38_WORKFLOW_PROOF_FILENAME,
  P38_WORKFLOW_SOURCE_PATHS,
  captureP38SourceRecords
} from './lib/p38-release-automation-proof.mjs';
import { loadLinuxWorkflowWiringInput, verifyLinuxWorkflowWiring } from './verify-linux-workflow-wiring.mjs';

const HEAD = 'a'.repeat(40);
const VERSION = '1.2.3';
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-x86_64';
const CANDIDATE_RUN_ID = '12345';
const CANDIDATE_ARTIFACT_DIGEST = `sha256:${'e'.repeat(64)}`;

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
    file: path.relative(root, file).split(path.sep).join('/'),
    sha256: sha256(file),
    size: fs.statSync(file).size
  };
}

function createReleaseFixture(featureRequirements = []) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-product-proof-'));
  const output = path.join(root, '.linux-release');
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  write(
    path.join(root, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'),
    publicKey.export({ type: 'spki', format: 'pem' })
  );
  fs.mkdirSync(path.join(root, 'packaging/linux/attestation'), { recursive: true });
  fs.copyFileSync(
    path.resolve('packaging/linux/attestation/openburnbar-installed-manifest.schema.json'),
    path.join(root, 'packaging/linux/attestation/openburnbar-installed-manifest.schema.json')
  );
  fs.copyFileSync(
    path.resolve('packaging/linux/release-manifest.json'),
    path.join(root, 'packaging/linux/release-manifest.json')
  );
  for (const relative of [
    'docs/linux-port/product-feature-proof-registry.json',
    'docs/linux-port/product-parity-requirements.json',
    'schemas/linux-product-feature-proof-registry.schema.json',
    'schemas/linux-product-feature-proof-registration.schema.json',
    'schemas/linux-product-feature-proof-closure.schema.json'
  ]) {
    fs.mkdirSync(path.dirname(path.join(root, relative)), { recursive: true });
    fs.copyFileSync(path.resolve(relative), path.join(root, relative));
  }
  writeJson(path.join(root, 'docs/linux-port/product-feature-proof-registry.json'), {
    schemaVersion: 1,
    id: 'openburnbar-linux-product-feature-proof-registry-v1',
    requirements: featureRequirements
  });
  fs.mkdirSync(path.join(root, 'packaging/linux/aur'), { recursive: true });
  fs.copyFileSync(
    path.resolve('packaging/linux/aur/PKGBUILD.in'),
    path.join(root, 'packaging/linux/aur/PKGBUILD.in')
  );
  for (const [slot, relativeFile] of archPkgbuildCommonSources) {
    if (slot === 'RELEASE_PUBLIC_KEY') continue;
    const destination = path.join(root, relativeFile);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.resolve(relativeFile), destination);
  }
  const artifacts = [];
  for (const architecture of ['aarch64', 'x86_64']) {
    for (const format of ['appimage', 'arch', 'deb', 'rpm', 'daemon']) {
      const name = format === 'appimage' ? `OpenBurnBar-${architecture}.AppImage`
        : format === 'daemon' ? `openburnbar-daemon-${architecture}`
          : format === 'arch' ? `openburnbar-${architecture}.pkg.tar.zst`
          : `OpenBurnBar-${architecture}.${format}`;
      const packageFile = write(path.join(output, 'artifacts', name), `package:${format}:${architecture}\n`);
      write(
        path.join(output, 'sidecars', `${name}.ed25519.sig`),
        crypto.sign(null, fs.readFileSync(packageFile), privateKey)
      );
      writeJson(`${packageFile}.sigstore.json`, { verified: true });
      const artifact = { type: format, architecture, ...record(root, packageFile) };
      if (!['arch', 'deb', 'rpm'].includes(format)) {
        artifacts.push(artifact);
        continue;
      }
      const manifest = {
        schemaVersion: 1,
        product: 'OpenBurnBar',
        appId: 'dev.openburnbar.OpenBurnBar',
        firebaseAppId: '1:123456789:web:abcdef_123',
        packageVersion: VERSION,
        gitCommit: HEAD,
        packageArchitecture: architecture,
        packageFormat: format,
        packageName: format === 'arch' ? 'openburnbar' : 'open-burn-bar',
        policyId: 'openburnbar-linux-signed-package-inventory-v1',
        brokerProtocolVersion: 2,
        installedFilesRootSha256: 'd'.repeat(64),
        authorizedClients: [{
          role: 'daemon',
          path: '/usr/bin/openburnbar-daemon',
          sha256: 'b'.repeat(64),
          ownerUid: 0,
          ownerGid: 0,
          mode: 493
        }],
        files: [
          {
            path: '/usr/bin/openburnbar-daemon', type: 'file', sha256: 'b'.repeat(64),
            size: 1, mode: '0755', uid: 0, gid: 0
          },
          {
            path: '/usr/bin/openburnbar-linux-desktop', type: 'file', sha256: 'c'.repeat(64),
            size: 1, mode: '0755', uid: 0, gid: 0
          }
        ]
      };
      const manifestFile = writeJson(path.join(output, 'installed-manifests', `${name}.json`), manifest);
      const signatureFile = write(
        `${manifestFile}.sig`,
        crypto.sign(null, fs.readFileSync(manifestFile), privateKey)
      );
      artifacts.push({
        ...artifact,
        installedManifest: record(root, manifestFile),
        installedManifestSignature: record(root, signatureFile)
      });
    }
  }
  const sidecar = (name, value) => record(root, writeJson(path.join(output, 'sidecars', name), value));
  const binarySidecar = (name, value) => record(root, write(path.join(output, 'sidecars', name), value));
  const previousVersion = '1.2.2';
  const preservationHash = '7'.repeat(64);
  const architectureSessions = sidecar('architecture-sessions.json', {
    passed: true,
    failedCount: 0,
    sessions: ['aarch64', 'x86_64'].map((architecture) => ({
      schemaVersion: 1,
      architecture,
      version: VERSION,
      gitCommit: HEAD,
      packageSmokePassed: true,
      lifecycle: {
        guiLaunch: { status: 'passed' },
        daemonLaunch: { status: 'passed' },
        versionReadback: { status: 'passed' },
        update: { status: 'passed', fromVersion: previousVersion, toVersion: VERSION },
        rollback: { status: 'passed', fromVersion: VERSION, toVersion: previousVersion },
        dataPreservation: {
          status: 'passed', sentinelSha256: preservationHash,
          afterPreviousSha256: preservationHash, afterUpdateSha256: preservationHash,
          afterRollbackSha256: preservationHash, afterRestoreSha256: preservationHash
        }
      },
      blockers: [],
      passed: true
    }))
  });
  const packageSmoke = sidecar('package-smoke.json', {
    passed: true,
    failedCount: 0,
    architectures: ['aarch64', 'x86_64'],
    lifecycle: Object.fromEntries([
      'guiLaunch', 'daemonLaunch', 'versionReadback', 'update', 'rollback', 'dataPreservation'
    ].map((step) => [step, { status: 'passed', architectures: ['aarch64', 'x86_64'] }]))
  });
  writeJson(path.join(output, 'smoke/architecture-smoke-summary.json'), {
    passed: true,
    architectures: [{ architecture: 'aarch64' }, { architecture: 'x86_64' }]
  });
  const feed = sidecar('latest-linux.draft.json', { version: VERSION, gitCommit: HEAD });
  const feedSignature = record(root, write(
    path.join(output, 'sidecars/latest-linux.json.ed25519.sig'),
    crypto.sign(null, fs.readFileSync(path.join(root, feed.file)), privateKey)
  ));
  writeJson(path.join(output, 'sidecars/latest-linux.draft.json.sigstore.json'), { verified: true });
  const archRelease = materializeArchReleaseMetadata({
    repoRoot: root,
    outDir: path.join(output, 'arch'),
    version: VERSION,
    gitCommit: HEAD,
    artifacts
  });
  for (const artifact of artifacts.filter((entry) => entry.type === 'arch')) {
    Object.assign(artifact, archRelease.installedAttestations[artifact.architecture]);
  }
  const packageClosure = {
    schemaVersion: 3,
    stage: 'candidate',
    git: { commit: HEAD, dirty: false },
    version: VERSION,
    artifacts,
    sidecars: {
      checksums: binarySidecar('checksums.txt', 'checksums\n'),
      sbom: sidecar('sbom.json', { schemaVersion: 1 }),
      vex: sidecar('vex.json', { schemaVersion: 1 }),
      provenancePredicate: sidecar('provenance.json', {
        status: 'passed',
        failedCount: 0,
        git: { commit: HEAD, dirty: false },
        version: VERSION,
        architectures: ['aarch64', 'x86_64'].map((architecture) => ({ architecture }))
      }),
      sourceArchive: binarySidecar('source.tar', 'source archive\n'),
      parityAttestation: sidecar('parity.json', { promotionPassed: true, productParityClaim: true }),
      architectureSessions,
      packageSmoke,
      archPkgbuild: record(root, archRelease.pkgbuildFile),
      archReleaseMetadata: record(root, archRelease.metadataFile),
      updateFeed: feed,
      updateFeedSignature: feedSignature
    },
    blockers: []
  };
  writeJson(path.join(output, 'package-closure.json'), packageClosure);
  for (const subject of deriveReleaseAttestationSubjects(packageClosure)) {
    const subjectFile = path.join(root, subject.record.file ?? subject.record.path);
    writeJson(`${subjectFile}.sigstore.json`, { verified: true, subjectSha256: sha256(subjectFile) });
  }
  return { root, output, packageClosure };
}

function requirementRoot(root, requirementId, environmentId = ENVIRONMENT) {
  return path.join(root, 'docs/linux-port/evidence/product-parity-inputs', requirementId, environmentId);
}

function stageAggregate(fixture, requirementId, environmentId = ENVIRONMENT) {
  const inputRoot = requirementRoot(fixture.root, requirementId, environmentId);
  fs.mkdirSync(inputRoot, { recursive: true });
  fs.cpSync(fixture.output, path.join(inputRoot, '.linux-release'), { recursive: true });
  return inputRoot;
}

function stageP38WorkflowProof(fixture, inputRoot, environmentId = ENVIRONMENT) {
  for (const relative of P38_WORKFLOW_SOURCE_PATHS) {
    const destination = path.join(fixture.root, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.resolve(relative), destination);
  }
  const workflowVerification = verifyLinuxWorkflowWiring(loadLinuxWorkflowWiringInput(fixture.root));
  assert.equal(workflowVerification.passed, true);
  return writeJson(path.join(inputRoot, P38_WORKFLOW_PROOF_FILENAME), {
    schemaVersion: 1,
    id: 'openburnbar-linux-p38-release-automation-proof-v1',
    generatedAt: new Date(0).toISOString(),
    requirementId: 'P-38',
    environmentId,
    targetHead: HEAD,
    candidate: { runId: CANDIDATE_RUN_ID, artifactDigest: CANDIDATE_ARTIFACT_DIGEST },
    workflowVerification,
    mutationSuite: {
      command: 'node --test scripts/linux-port/verify-linux-workflow-wiring.test.mjs',
      testPath: 'scripts/linux-port/verify-linux-workflow-wiring.test.mjs',
      exitCode: 0,
      testCount: 18,
      passCount: 18,
      failCount: 0,
      outputSha256: '8'.repeat(64),
      passed: true
    },
    sources: captureP38SourceRecords(fixture.root),
    status: 'passed'
  });
}

function prepareP38Fixture() {
  const fixture = createReleaseFixture();
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, 'P-38');
  stageP38WorkflowProof(fixture, inputRoot);
  const { closure } = prepareProductRequirementInput({
    requirementId: 'P-38', environmentId: ENVIRONMENT, inputRoot, targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  return {
    fixture,
    inputRoot,
    closure,
    context: validatorContext(fixture, 'P-38', closure, 'p-38.ci-and-release-automation')
  };
}

test('finalizer emits a two-architecture cryptographic product closure', (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const result = finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  assert.equal(result.document.status, 'passed');
  assert.equal(result.document.packages.length, 6);
  assert.equal(result.document.releaseArtifacts.length, 10);
  assert.deepEqual(result.document.architectures, ['aarch64', 'x86_64']);
  assert.equal(result.document.featureProofRegistry.path, 'sidecars/product-feature-proof-registry.json');
  assert.equal(result.document.proofs.filter((proof) => proof.role === 'package-sigstore').length, 10);
  assert.equal(result.document.attestationSubjects.length, 30);
  assert.ok(result.document.packages
    .filter((row) => row.format === 'arch')
    .every((row) => row.installedManifest.path.startsWith('arch/openburnbar-')));
  assert.equal(fs.existsSync(result.output), true);
});

function assertRequirementReleaseCapture(t, requirementId, role) {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const result = finalizeProductProofClosure({
    repoRoot: fixture.root,
    outputDir: fixture.output,
    targetHead: HEAD
  });
  const selected = result.document.proofs.filter((proof) => proof.role === role);
  assert.ok(selected.length > 0, `${requirementId} must capture ${role}`);
  assert.ok(selected.every((proof) => /^[a-f0-9]{64}$/u.test(proof.sha256)));
}

test('P-01 release capture includes signed application artifacts', (t) => {
  assertRequirementReleaseCapture(t, 'P-01', 'package-signature');
});

test('P-03 release capture includes daemon protocol evidence', (t) => {
  assertRequirementReleaseCapture(t, 'P-03', 'package-smoke');
});

test('P-04 release capture includes two-architecture smoke evidence', (t) => {
  assertRequirementReleaseCapture(t, 'P-04', 'architecture-smoke');
});

test('P-37 release capture includes Linux matrix evidence', (t) => {
  assertRequirementReleaseCapture(t, 'P-37', 'architecture-smoke');
});

test('P-38 release capture includes architecture lifecycle and signing evidence', (t) => {
  assertRequirementReleaseCapture(t, 'P-38', 'architecture-sessions');
  assertRequirementReleaseCapture(t, 'P-38', 'package-signature');
});

test('finalizer rejects blockers, missing manifests, and signature mutation', async (t) => {
  for (const [name, mutate, pattern] of [
    ['release blocker', (fixture) => {
      fixture.packageClosure.blockers.push({ kind: 'test' });
      writeJson(path.join(fixture.output, 'package-closure.json'), fixture.packageClosure);
    }, /clean, passed/u],
    ['missing manifest record', (fixture) => {
      delete fixture.packageClosure.artifacts.find((artifact) => artifact.type === 'deb').installedManifest;
      writeJson(path.join(fixture.output, 'package-closure.json'), fixture.packageClosure);
    }, /installed manifest.*must contain/u],
    ['mutated manifest signature', (fixture) => {
      const signature = fixture.packageClosure.artifacts.find((artifact) => artifact.type === 'deb').installedManifestSignature;
      const file = path.join(fixture.root, signature.file);
      write(file, Buffer.alloc(64, 9));
      signature.sha256 = sha256(file);
      writeJson(path.join(fixture.output, 'package-closure.json'), fixture.packageClosure);
    }, /does not verify/u],
    ['mutated package signature', (fixture) => {
      const artifact = fixture.packageClosure.artifacts[0];
      write(path.join(fixture.output, 'sidecars', `${path.basename(artifact.file)}.ed25519.sig`), Buffer.alloc(64, 9));
    }, /release artifact .* signature does not verify/u],
    ['mutated update feed signature', (fixture) => {
      const signature = fixture.packageClosure.sidecars.updateFeedSignature;
      const file = path.join(fixture.root, signature.file);
      write(file, Buffer.alloc(64, 9));
      signature.sha256 = sha256(file);
      writeJson(path.join(fixture.output, 'package-closure.json'), fixture.packageClosure);
    }, /update feed signature does not verify/u],
    ['missing artifact Sigstore bundle', (fixture) => {
      const artifact = fixture.packageClosure.artifacts[0];
      fs.rmSync(`${path.join(fixture.root, artifact.file)}.sigstore.json`);
    }, /Sigstore bundle/u],
    ['missing installed-manifest Sigstore bundle', (fixture) => {
      const manifest = fixture.packageClosure.artifacts.find((artifact) => artifact.type === 'arch').installedManifest;
      fs.rmSync(`${path.join(fixture.root, manifest.file)}.sigstore.json`);
    }, /Sigstore bundle/u],
    ['deleted Arch PKGBUILD', (fixture) => {
      fs.rmSync(path.join(fixture.root, fixture.packageClosure.sidecars.archPkgbuild.file));
    }, /Arch PKGBUILD/u],
    ['corrupt Arch release metadata identity', (fixture) => {
      const record = fixture.packageClosure.sidecars.archReleaseMetadata;
      const file = path.join(fixture.root, record.file);
      const document = JSON.parse(fs.readFileSync(file, 'utf8'));
      document.gitCommit = 'b'.repeat(40);
      writeJson(file, document);
      Object.assign(record, { sha256: sha256(file), size: fs.statSync(file).size });
      writeJson(path.join(fixture.output, 'package-closure.json'), fixture.packageClosure);
    }, /not bound to the release identity/u],
    ['cross-bind an Arch source record to the wrong release file', (fixture) => {
      const record = fixture.packageClosure.sidecars.archReleaseMetadata;
      const file = path.join(fixture.root, record.file);
      const document = JSON.parse(fs.readFileSync(file, 'utf8'));
      const appImage = document.sources.find((source) => source.slot === 'APPIMAGE_X86_64');
      appImage.file = fixture.packageClosure.artifacts.find((artifact) =>
        artifact.type === 'appimage' && artifact.architecture === 'aarch64'
      ).file;
      writeJson(file, document);
      Object.assign(record, { sha256: sha256(file), size: fs.statSync(file).size });
      writeJson(path.join(fixture.output, 'package-closure.json'), fixture.packageClosure);
    }, /not bound to release bytes and identity/u],
    ['corrupt Arch PKGBUILD with self-consistent metadata hashes', (fixture) => {
      const pkgbuildRecord = fixture.packageClosure.sidecars.archPkgbuild;
      const pkgbuildFile = path.join(fixture.root, pkgbuildRecord.file);
      fs.appendFileSync(pkgbuildFile, '# semantic drift\n');
      Object.assign(pkgbuildRecord, { sha256: sha256(pkgbuildFile), size: fs.statSync(pkgbuildFile).size });
      const metadataRecord = fixture.packageClosure.sidecars.archReleaseMetadata;
      const metadataFile = path.join(fixture.root, metadataRecord.file);
      const metadata = JSON.parse(fs.readFileSync(metadataFile, 'utf8'));
      Object.assign(metadata.pkgbuild, { sha256: pkgbuildRecord.sha256, size: pkgbuildRecord.size });
      writeJson(metadataFile, metadata);
      Object.assign(metadataRecord, { sha256: sha256(metadataFile), size: fs.statSync(metadataFile).size });
      writeJson(path.join(fixture.output, 'package-closure.json'), fixture.packageClosure);
    }, /canonical release template/u]
  ]) {
    await t.test(name, () => {
      const fixture = createReleaseFixture();
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
      writeJson(path.join(fixture.output, 'product-proof-closure.json'), { status: 'stale-passed' });
      mutate(fixture);
      assert.throws(
        () => finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD }),
        pattern
      );
      assert.equal(fs.existsSync(path.join(fixture.output, 'product-proof-closure.json')), false);
    });
  }
});

test('materializer selects the exact environment package and copies hash-bound proof subjects', (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, 'P-01');
  const result = prepareProductRequirementInput({
    requirementId: 'P-01', environmentId: ENVIRONMENT, inputRoot, targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  assert.equal(result.closure.selectedPackage.format, 'deb');
  assert.equal(result.closure.selectedPackage.architecture, 'x86_64');
  assert.equal(result.closure.proofs.filter((proof) => proof.role === 'package-signature').length, 10);
  assert.equal(result.closure.proofs.filter((proof) => proof.role === 'release-artifact').length, 10);
  assert.equal(fs.existsSync(result.output), true);
});

function assertRequirementMaterializer(t, requirementId, role) {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, requirementId);
  const result = prepareProductRequirementInput({
    requirementId,
    environmentId: ENVIRONMENT,
    inputRoot,
    targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID,
    candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  const selected = result.closure.proofs.filter((proof) => proof.role === role);
  assert.ok(selected.length > 0, `${requirementId} must materialize ${role}`);
  assert.ok(selected.every((proof) => fs.existsSync(path.join(fixture.root, proof.path))));
}

test('P-01 materializer selects signed application artifacts', (t) => {
  assertRequirementMaterializer(t, 'P-01', 'package-signature');
});

test('P-03 materializer selects daemon protocol evidence', (t) => {
  assertRequirementMaterializer(t, 'P-03', 'package-smoke');
});

test('P-04 materializer selects two-architecture smoke evidence', (t) => {
  assertRequirementMaterializer(t, 'P-04', 'architecture-smoke');
});

test('P-37 materializer selects Linux matrix evidence', (t) => {
  assertRequirementMaterializer(t, 'P-37', 'architecture-smoke');
});

test('P-38 materializer selects release automation evidence', (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, 'P-38');
  stageP38WorkflowProof(fixture, inputRoot);
  const result = prepareProductRequirementInput({
    requirementId: 'P-38', environmentId: ENVIRONMENT, inputRoot, targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  for (const role of [
    'architecture-sessions', 'package-signature', 'package-sigstore', 'package-smoke',
    'provenance', 'workflow-verification'
  ]) {
    assert.ok(result.closure.proofs.some((proof) => proof.role === role), `P-38 must materialize ${role}`);
  }
});

test('registered environment feature proofs are candidate-bound and materialized without implying pass', (t) => {
  const fixture = createReleaseFixture([{
    requirementId: 'P-02',
    artifacts: [{ role: 'feature.parity-report', mediaType: 'application/json', maxBytes: 4096 }]
  }]);
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, 'P-02');
  writeJson(path.join(inputRoot, 'feature-artifacts/parity-report.json'), {
    schemaVersion: 1,
    observed: true
  });
  writeJson(path.join(inputRoot, 'feature-proof-registration.json'), {
    schemaVersion: 1,
    requirementId: 'P-02',
    environmentId: ENVIRONMENT,
    artifacts: [{ role: 'feature.parity-report', path: 'feature-artifacts/parity-report.json' }]
  });
  const feature = finalizeProductFeatureProofClosure({
    repoRoot: fixture.root,
    inputRoot,
    requirementId: 'P-02',
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID,
    candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST
  });
  assert.equal(feature.closure.status, 'collected');
  assert.equal(Object.hasOwn(feature.closure, 'passed'), false);
  const { closure } = prepareProductRequirementInput({
    requirementId: 'P-02', environmentId: ENVIRONMENT, inputRoot, targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  assert.equal(closure.schemaVersion, 3);
  assert.equal(closure.featureProofClosure.sha256, sha256(feature.output));
  const proof = closure.proofs.find((entry) => entry.role === 'feature.parity-report');
  assert.equal(proof.evidenceClass, 'feature');
  assert.equal(proof.mediaType, 'application/json');
  assert.equal(sha256(path.join(fixture.root, proof.path)), proof.sha256);
});

test('materializer rejects wrong HEAD, unsupported requirements, Arch, and mutated aggregate subjects', async (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const finalized = finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  await t.test('wrong HEAD', () => {
    const inputRoot = stageAggregate(fixture, 'P-03');
    writeJson(path.join(inputRoot, 'release-closure.json'), { status: 'stale-passed' });
    assert.throws(() => prepareProductRequirementInput({
      requirementId: 'P-03', environmentId: ENVIRONMENT, inputRoot,
      targetHead: 'b'.repeat(40), candidateRunId: CANDIDATE_RUN_ID,
      candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST, repoRoot: fixture.root
    }), /target does not match/u);
    assert.equal(fs.existsSync(path.join(inputRoot, 'release-closure.json')), false);
  });
  await t.test('unsupported requirement', () => {
    const inputRoot = stageAggregate(fixture, 'P-02');
    assert.throws(() => prepareProductRequirementInput({
      requirementId: 'P-02', environmentId: ENVIRONMENT, inputRoot,
      targetHead: HEAD, candidateRunId: CANDIDATE_RUN_ID,
      candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST, repoRoot: fixture.root
    }), /no release or feature proof materializer/u);
  });
  await t.test('Arch selects its signed package lifecycle', () => {
    const environmentId = 'arch-sway-wayland-x86_64';
    const inputRoot = stageAggregate(fixture, 'P-37', environmentId);
    const result = prepareProductRequirementInput({
      requirementId: 'P-37', environmentId, inputRoot,
      targetHead: HEAD, candidateRunId: CANDIDATE_RUN_ID,
      candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST, repoRoot: fixture.root
    });
    assert.deepEqual(result.closure.selectedPackage, { architecture: 'x86_64', format: 'arch' });
  });
  await t.test('proof bytes mutated', () => {
    const inputRoot = stageAggregate(fixture, 'P-03');
    const proof = finalized.document.proofs.find((entry) => entry.role === 'package-smoke');
    write(path.join(inputRoot, '.linux-release', proof.path), 'mutated\n');
    assert.throws(() => prepareProductRequirementInput({
      requirementId: 'P-03', environmentId: ENVIRONMENT, inputRoot,
      targetHead: HEAD, candidateRunId: CANDIDATE_RUN_ID,
      candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST, repoRoot: fixture.root
    }), /SHA-256 does not match/u);
  });
  await t.test('aggregate attestation subject deleted', () => {
    const inputRoot = stageAggregate(fixture, 'P-01');
    const aggregateFile = path.join(inputRoot, '.linux-release/product-proof-closure.json');
    const aggregate = JSON.parse(fs.readFileSync(aggregateFile, 'utf8'));
    aggregate.attestationSubjects.pop();
    writeJson(aggregateFile, aggregate);
    assert.throws(() => prepareProductRequirementInput({
      requirementId: 'P-01', environmentId: ENVIRONMENT, inputRoot,
      targetHead: HEAD, candidateRunId: CANDIDATE_RUN_ID,
      candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST, repoRoot: fixture.root
    }), /exact attestation subject set/u);
  });
});

function validatorContext(
  fixture,
  requirementId,
  closure,
  checkId,
  mutateRuntime = null,
  environmentId = ENVIRONMENT
) {
  const root = requirementRoot(fixture.root, requirementId, environmentId);
  const relative = (file) => path.relative(fixture.root, file).split(path.sep).join('/');
  const closureFile = path.join(root, 'release-closure.json');
  const isArch = environmentId.startsWith('arch-');
  const runtime = {
    schemaVersion: 1,
    shellVersion: VERSION,
    daemonVersion: VERSION,
    daemonProtocolVersion: 2,
    sessionType: isArch ? 'wayland' : 'x11',
    desktop: isArch ? 'Sway/wlroots' : 'GNOME',
    capabilities: [{ id: 'usage.read' }]
  };
  if (mutateRuntime) mutateRuntime(runtime);
  const runtimeFile = writeJson(path.join(root, 'live-runtime-capabilities.json'), runtime);
  const environmentFile = writeJson(path.join(root, 'live-environment-manifest.json'), {
    environmentId,
    targetHead: HEAD,
    architecture: environmentId.endsWith('-aarch64') ? 'aarch64' : 'x86_64',
    passed: true
  });
  const manifestFile = path.join(fixture.root, closure.packageManifest.path);
  const packageFile = path.join(fixture.root, closure.packages[0].path);
  const signatureFile = path.join(fixture.root, closure.packageManifestSignature.path);
  return {
    schemaVersion: 1,
    repoRoot: fixture.root,
    requirementId,
    checkId,
    environmentId,
    targetHead: HEAD,
    releaseClosure: { path: relative(closureFile), sha256: sha256(closureFile), document: closure },
    subjects: {
      release: { path: relative(closureFile), sha256: sha256(closureFile) },
      packageManifest: { path: closure.packageManifest.path, sha256: sha256(manifestFile) },
      packageManifestSignature: {
        path: closure.packageManifestSignature.path,
        sha256: sha256(signatureFile)
      },
      packages: [{ path: closure.packages[0].path, sha256: sha256(packageFile) }],
      runtimes: [{ path: relative(runtimeFile), sha256: sha256(runtimeFile) }],
      installation: [{ path: closure.packageManifestSignature.path, sha256: sha256(signatureFile) }],
      environment: { path: relative(environmentFile), sha256: sha256(environmentFile) }
    }
  };
}

test('release-owned validators enforce their distinct release/runtime contracts', async (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const cases = [
    ['P-01', 'p-01.release-integrity', validateP01],
    ['P-03', 'p-03.installed-runtime', validateP03],
    ['P-04', 'p-04.architecture-reach', validateP04],
    ['P-37', 'p-37.linux-matrix', validateP37],
    ['P-38', 'p-38.ci-and-release-automation', validateP38]
  ];
  for (const [requirementId, checkId, validator] of cases) {
    const inputRoot = stageAggregate(fixture, requirementId);
    if (requirementId === 'P-38') stageP38WorkflowProof(fixture, inputRoot);
    const { closure } = prepareProductRequirementInput({
      requirementId, environmentId: ENVIRONMENT, inputRoot, targetHead: HEAD,
      candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
      repoRoot: fixture.root
    });
    const context = validatorContext(fixture, requirementId, closure, checkId);
    const result = await validator(context);
    assert.equal(result.requirementId, requirementId);
    assert.equal(result.status, 'passed');
    assert.ok(result.artifacts.length > 5);
  }
});

test('P-37 validator accepts the Arch package lifecycle and rejects a cross-format selection', async (t) => {
  const environmentId = 'arch-sway-wayland-x86_64';
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, 'P-37', environmentId);
  const { closure } = prepareProductRequirementInput({
    requirementId: 'P-37', environmentId, inputRoot, targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  const context = validatorContext(
    fixture,
    'P-37',
    closure,
    'p-37.linux-matrix',
    null,
    environmentId
  );
  const result = await validateP37(context);
  assert.equal(result.status, 'passed');
  assert.deepEqual(closure.selectedPackage, { architecture: 'x86_64', format: 'arch' });

  closure.selectedPackage.format = 'rpm';
  await assert.rejects(
    () => validateP37(context),
    /selected the wrong native package/u
  );
});

test('P-03 rejects a live daemon protocol that drifts from the signed package manifest', async (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, 'P-03');
  const { closure } = prepareProductRequirementInput({
    requirementId: 'P-03', environmentId: ENVIRONMENT, inputRoot, targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  const context = validatorContext(
    fixture,
    'P-03',
    closure,
    'p-03.installed-runtime',
    (runtime) => { runtime.daemonProtocolVersion = 1; }
  );
  await assert.rejects(() => validateP03(context), /daemon protocol does not match/u);
});

test('P-01 independently rejects a release artifact with a substituted detached signature', async (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, 'P-01');
  const { closure } = prepareProductRequirementInput({
    requirementId: 'P-01', environmentId: ENVIRONMENT, inputRoot, targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  const artifact = closure.proofs.find((proof) =>
    proof.role === 'release-artifact' && proof.format === 'appimage' && proof.architecture === 'aarch64'
  );
  const artifactFile = path.join(fixture.root, artifact.path);
  write(artifactFile, 'substituted release artifact\n');
  artifact.sha256 = sha256(artifactFile);
  writeJson(path.join(inputRoot, 'release-closure.json'), closure);
  const context = validatorContext(fixture, 'P-01', closure, 'p-01.release-integrity');
  await assert.rejects(() => validateP01(context), /release artifact signature does not verify/u);
});

test('P-03 rejects duplicate architecture lifecycle rows', async (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, 'P-03');
  const { closure } = prepareProductRequirementInput({
    requirementId: 'P-03', environmentId: ENVIRONMENT, inputRoot, targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  const smoke = closure.proofs.find((proof) => proof.role === 'package-smoke');
  const smokeFile = path.join(fixture.root, smoke.path);
  const document = JSON.parse(fs.readFileSync(smokeFile, 'utf8'));
  document.architectures = ['aarch64', 'aarch64'];
  writeJson(smokeFile, document);
  smoke.sha256 = sha256(smokeFile);
  writeJson(path.join(inputRoot, 'release-closure.json'), closure);
  const context = validatorContext(fixture, 'P-03', closure, 'p-03.installed-runtime');
  await assert.rejects(() => validateP03(context), /cover both release architectures/u);
});

test('P-04 rejects architecture smoke evidence missing a release architecture', async (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, 'P-04');
  const { closure } = prepareProductRequirementInput({
    requirementId: 'P-04', environmentId: ENVIRONMENT, inputRoot, targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  const smoke = closure.proofs.find((proof) => proof.role === 'architecture-smoke');
  const smokeFile = path.join(fixture.root, smoke.path);
  const document = JSON.parse(fs.readFileSync(smokeFile, 'utf8'));
  document.architectures = [{ architecture: 'x86_64' }];
  writeJson(smokeFile, document);
  smoke.sha256 = sha256(smokeFile);
  writeJson(path.join(inputRoot, 'release-closure.json'), closure);
  const context = validatorContext(fixture, 'P-04', closure, 'p-04.architecture-reach');
  await assert.rejects(() => validateP04(context), /does not cover aarch64/u);
});

test('P-37 rejects a failed architecture smoke proof', async (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const inputRoot = stageAggregate(fixture, 'P-37');
  const { closure } = prepareProductRequirementInput({
    requirementId: 'P-37', environmentId: ENVIRONMENT, inputRoot, targetHead: HEAD,
    candidateRunId: CANDIDATE_RUN_ID, candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    repoRoot: fixture.root
  });
  const smoke = closure.proofs.find((proof) => proof.role === 'architecture-smoke');
  const smokeFile = path.join(fixture.root, smoke.path);
  const document = JSON.parse(fs.readFileSync(smokeFile, 'utf8'));
  document.passed = false;
  writeJson(smokeFile, document);
  smoke.sha256 = sha256(smokeFile);
  writeJson(path.join(inputRoot, 'release-closure.json'), closure);
  const context = validatorContext(fixture, 'P-37', closure, 'p-37.linux-matrix');
  await assert.rejects(() => validateP37(context), /architecture-smoke proof is not passed/u);
});

function mutateP38Proof(subject, role, mutate) {
  const proof = subject.closure.proofs.find((row) => row.role === role);
  assert.ok(proof, `missing ${role} proof fixture`);
  const file = path.join(subject.fixture.root, proof.path);
  const document = JSON.parse(fs.readFileSync(file, 'utf8'));
  mutate(document);
  writeJson(file, document);
  proof.sha256 = sha256(file);
  proof.size = fs.statSync(file).size;
}

test('P-38 rejects missing prior-version lifecycle and workflow verification', async (t) => {
  await t.test('prior version transition', async () => {
    const subject = prepareP38Fixture();
    t.after(() => fs.rmSync(subject.fixture.root, { recursive: true, force: true }));
    mutateP38Proof(subject, 'architecture-sessions', (document) => {
      document.sessions[0].lifecycle.update.fromVersion = VERSION;
    });
    await assert.rejects(
      () => validateP38(subject.context),
      /no exact older-release update\/rollback transition/u
    );
  });
  await t.test('workflow mutation suite', async () => {
    const subject = prepareP38Fixture();
    t.after(() => fs.rmSync(subject.fixture.root, { recursive: true, force: true }));
    mutateP38Proof(subject, 'workflow-verification', (document) => {
      document.mutationSuite.passed = false;
      document.mutationSuite.failCount = 1;
      document.mutationSuite.passCount -= 1;
    });
    await assert.rejects(
      () => validateP38(subject.context),
      /workflow mutation suite did not pass completely/u
    );
  });
});

test('P-38 rejects missing architecture, signing, lifecycle, and current workflow source proof', async (t) => {
  await t.test('architecture session', async () => {
    const subject = prepareP38Fixture();
    t.after(() => fs.rmSync(subject.fixture.root, { recursive: true, force: true }));
    mutateP38Proof(subject, 'architecture-sessions', (document) => {
      document.sessions.pop();
    });
    await assert.rejects(() => validateP38(subject.context), /architecture sessions are not complete/u);
  });
  await t.test('signing matrix', async () => {
    const subject = prepareP38Fixture();
    t.after(() => fs.rmSync(subject.fixture.root, { recursive: true, force: true }));
    const index = subject.closure.proofs.findIndex((proof) => proof.role === 'package-signature');
    subject.closure.proofs.splice(index, 1);
    await assert.rejects(() => validateP38(subject.context), /must cover every release format and architecture/u);
  });
  await t.test('blocked package lifecycle', async () => {
    const subject = prepareP38Fixture();
    t.after(() => fs.rmSync(subject.fixture.root, { recursive: true, force: true }));
    mutateP38Proof(subject, 'package-smoke', (document) => {
      document.lifecycle.rollback.status = 'blocked';
      document.passed = false;
      document.failedCount = 1;
    });
    await assert.rejects(() => validateP38(subject.context), /package-smoke proof is not passed/u);
  });
  await t.test('workflow source drift', async () => {
    const subject = prepareP38Fixture();
    t.after(() => fs.rmSync(subject.fixture.root, { recursive: true, force: true }));
    fs.appendFileSync(path.join(subject.fixture.root, '.github/workflows/linux-release.yml'), '\n# forced failure\n');
    await assert.rejects(() => validateP38(subject.context), /workflow source is stale or substituted/u);
  });
});

function stagePassedPromotionEvidence(fixture) {
  const parityPath = path.join(fixture.root, 'docs/linux-port/evidence/mission-002-reanchor/parity-ledger-validation.json');
  const environments = [
    'ubuntu-24.04-gnome-x11-x86_64',
    'ubuntu-24.04-gnome-x11-aarch64',
    'ubuntu-24.04-gnome-wayland-x86_64',
    'ubuntu-24.04-gnome-wayland-aarch64',
    'fedora-kde-wayland-x86_64',
    'fedora-kde-wayland-aarch64',
    'arch-sway-wayland-x86_64'
  ];
  const candidate = {
    runId: CANDIDATE_RUN_ID,
    artifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    productProofClosureSha256: sha256(path.join(fixture.output, 'product-proof-closure.json'))
  };
  const validatedAttestations = [];
  for (let index = 1; index <= 40; index += 1) {
    const requirementId = `P-${String(index).padStart(2, '0')}`;
    const relative = `docs/linux-port/evidence/product-parity/${requirementId}.json`;
    const output = writeJson(path.join(fixture.root, relative), {
      schemaVersion: 1,
      rowId: requirementId,
      requirementId,
      targetHead: HEAD,
      status: 'passed',
      candidate,
      environments,
      validatorReceipts: environments.map((environmentId) => ({ environmentId, candidate }))
    });
    validatedAttestations.push({ requirementId, path: relative, sha256: sha256(output), candidate });
  }
  writeJson(parityPath, {
    targetHead: HEAD,
    allowBlocked: false,
    passed: true,
    structuralPassed: true,
    promotionPassed: true,
    productParityClaim: true,
    failures: [],
    structuralFailures: [],
    promotionFailures: [],
    validatedAttestations
  });
  return parityPath;
}

test('promotion closure binds one passed candidate, strict ledger report, and all 40 seven-environment rows', (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const parityReportPath = stagePassedPromotionEvidence(fixture);
  const result = finalizeLinuxPromotionClosure({
    repoRoot: fixture.root,
    candidateRoot: fixture.output,
    parityReportPath,
    candidateRunId: CANDIDATE_RUN_ID,
    candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    targetHead: HEAD
  });
  assert.equal(result.closure.status, 'passed');
  assert.equal(result.closure.requirementAttestations.length, 40);
  assert.equal(result.closure.candidate.runId, CANDIDATE_RUN_ID);
  assert.equal(result.closure.candidate.artifactDigest, CANDIDATE_ARTIFACT_DIGEST);
});

test('promotion closure deletes stale output and rejects a missing or incomplete row', (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const parityReportPath = stagePassedPromotionEvidence(fixture);
  const row = path.join(fixture.root, 'docs/linux-port/evidence/product-parity/P-40.json');
  fs.rmSync(row);
  writeJson(path.join(fixture.output, 'promotion-closure.json'), { status: 'stale-passed' });
  assert.throws(() => finalizeLinuxPromotionClosure({
    repoRoot: fixture.root,
    candidateRoot: fixture.output,
    parityReportPath,
    candidateRunId: CANDIDATE_RUN_ID,
    candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
    targetHead: HEAD
  }), /P-40 product attestation/u);
  assert.equal(fs.existsSync(path.join(fixture.output, 'promotion-closure.json')), false);
});

test('promotion closure rejects cross-candidate summaries and post-validation row mutation', async (t) => {
  await t.test('cross-candidate summary', () => {
    const fixture = createReleaseFixture();
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
    finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
    const parityReportPath = stagePassedPromotionEvidence(fixture);
    const parity = JSON.parse(fs.readFileSync(parityReportPath, 'utf8'));
    parity.validatedAttestations[0].candidate.artifactDigest = `sha256:${'f'.repeat(64)}`;
    writeJson(parityReportPath, parity);
    assert.throws(() => finalizeLinuxPromotionClosure({
      repoRoot: fixture.root,
      candidateRoot: fixture.output,
      parityReportPath,
      candidateRunId: CANDIDATE_RUN_ID,
      candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
      targetHead: HEAD
    }), /does not match the selected release candidate/u);
  });
  await t.test('post-validation row mutation', () => {
    const fixture = createReleaseFixture();
    t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
    finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
    const parityReportPath = stagePassedPromotionEvidence(fixture);
    const row = path.join(fixture.root, 'docs/linux-port/evidence/product-parity/P-01.json');
    fs.appendFileSync(row, ' ');
    assert.throws(() => finalizeLinuxPromotionClosure({
      repoRoot: fixture.root,
      candidateRoot: fixture.output,
      parityReportPath,
      candidateRunId: CANDIDATE_RUN_ID,
      candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST,
      targetHead: HEAD
    }), /not a complete passed seven-environment row/u);
  });
});
