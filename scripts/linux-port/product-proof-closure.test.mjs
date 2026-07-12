import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { finalizeProductProofClosure } from './finalize-product-proof-closure.mjs';
import { finalizeLinuxPromotionClosure } from './finalize-linux-promotion-closure.mjs';
import { prepareProductRequirementInput } from './prepare-product-requirement-input.mjs';
import { validateProductRequirement as validateP01 } from './product-validators/P-01.mjs';
import { validateProductRequirement as validateP03 } from './product-validators/P-03.mjs';
import { validateProductRequirement as validateP04 } from './product-validators/P-04.mjs';
import { validateProductRequirement as validateP37 } from './product-validators/P-37.mjs';

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

function createReleaseFixture() {
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
  const artifacts = [];
  for (const architecture of ['aarch64', 'x86_64']) {
    for (const format of ['appimage', 'deb', 'rpm', 'daemon']) {
      const name = format === 'appimage' ? `OpenBurnBar-${architecture}.AppImage`
        : format === 'daemon' ? `openburnbar-daemon-${architecture}`
          : `OpenBurnBar-${architecture}.${format}`;
      const packageFile = write(path.join(output, 'artifacts', name), `package:${format}:${architecture}\n`);
      write(
        path.join(output, 'sidecars', `${name}.ed25519.sig`),
        crypto.sign(null, fs.readFileSync(packageFile), privateKey)
      );
      writeJson(`${packageFile}.sigstore.json`, { verified: true });
      const artifact = { type: format, architecture, ...record(root, packageFile) };
      if (!['deb', 'rpm'].includes(format)) {
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
        packageName: 'open-burn-bar',
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
  const architectureSessions = sidecar('architecture-sessions.json', {
    passed: true,
    failedCount: 0,
    sessions: ['aarch64', 'x86_64'].map((architecture) => ({
      schemaVersion: 1,
      architecture,
      version: VERSION,
      gitCommit: HEAD,
      lifecycle: Object.fromEntries([
        'guiLaunch', 'daemonLaunch', 'versionReadback', 'update', 'rollback', 'dataPreservation'
      ].map((step) => [step, { status: 'passed' }])),
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
      provenancePredicate: sidecar('provenance.json', { git: { commit: HEAD } }),
      sourceArchive: binarySidecar('source.tar', 'source archive\n'),
      parityAttestation: sidecar('parity.json', { promotionPassed: true, productParityClaim: true }),
      architectureSessions,
      packageSmoke,
      updateFeed: feed,
      updateFeedSignature: feedSignature
    },
    blockers: []
  };
  writeJson(path.join(output, 'package-closure.json'), packageClosure);
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

test('finalizer emits a two-architecture cryptographic product closure', (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const result = finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  assert.equal(result.document.status, 'passed');
  assert.equal(result.document.packages.length, 4);
  assert.equal(result.document.releaseArtifacts.length, 8);
  assert.deepEqual(result.document.architectures, ['aarch64', 'x86_64']);
  assert.equal(result.document.proofs.filter((proof) => proof.role === 'package-sigstore').length, 8);
  assert.equal(fs.existsSync(result.output), true);
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
    }, /update feed signature does not verify/u]
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
  assert.equal(result.closure.proofs.filter((proof) => proof.role === 'package-signature').length, 8);
  assert.equal(result.closure.proofs.filter((proof) => proof.role === 'release-artifact').length, 8);
  assert.equal(fs.existsSync(result.output), true);
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
    }), /no release-proof materializer/u);
  });
  await t.test('Arch lifecycle absent', () => {
    const environmentId = 'arch-sway-wayland-x86_64';
    const inputRoot = stageAggregate(fixture, 'P-37', environmentId);
    assert.throws(() => prepareProductRequirementInput({
      requirementId: 'P-37', environmentId, inputRoot,
      targetHead: HEAD, candidateRunId: CANDIDATE_RUN_ID,
      candidateArtifactDigest: CANDIDATE_ARTIFACT_DIGEST, repoRoot: fixture.root
    }), /Arch product evidence remains blocked/u);
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
});

function validatorContext(fixture, requirementId, closure, checkId, mutateRuntime = null) {
  const root = requirementRoot(fixture.root, requirementId);
  const relative = (file) => path.relative(fixture.root, file).split(path.sep).join('/');
  const closureFile = path.join(root, 'release-closure.json');
  const runtime = {
    schemaVersion: 1,
    shellVersion: VERSION,
    daemonVersion: VERSION,
    daemonProtocolVersion: 2,
    sessionType: 'x11',
    desktop: 'GNOME',
    capabilities: [{ id: 'usage.read' }]
  };
  if (mutateRuntime) mutateRuntime(runtime);
  const runtimeFile = writeJson(path.join(root, 'live-runtime-capabilities.json'), runtime);
  const environmentFile = writeJson(path.join(root, 'live-environment-manifest.json'), {
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    architecture: 'x86_64',
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
    environmentId: ENVIRONMENT,
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

test('P-01, P-03, P-04, and P-37 validators enforce their distinct release/runtime contracts', async (t) => {
  const fixture = createReleaseFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  finalizeProductProofClosure({ repoRoot: fixture.root, outputDir: fixture.output, targetHead: HEAD });
  const cases = [
    ['P-01', 'p-01.release-integrity', validateP01],
    ['P-03', 'p-03.installed-runtime', validateP03],
    ['P-04', 'p-04.architecture-reach', validateP04],
    ['P-37', 'p-37.linux-matrix', validateP37]
  ];
  for (const [requirementId, checkId, validator] of cases) {
    const inputRoot = stageAggregate(fixture, requirementId);
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
