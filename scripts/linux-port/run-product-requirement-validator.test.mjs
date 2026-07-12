import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  CANONICAL_ENVIRONMENT_IDS,
  CANONICAL_REQUIREMENT_IDS,
  canonicalOutputPath,
  main,
  queryInstalledPackage
} from './run-product-requirement-validator.mjs';
import { environmentPackage } from './lib/product-proof-closure.mjs';

const ENVIRONMENT = CANONICAL_ENVIRONMENT_IDS[0];
const SOURCE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const INSTALLED_SCHEMA = 'packaging/linux/attestation/openburnbar-installed-manifest.schema.json';
const RUNTIME_SCHEMA = 'schemas/linux-runtime-capability-manifest.schema.json';
const RUNTIME_CATALOG = 'packaging/linux/runtime-capability-catalog.json';
const FEATURE_SCHEMAS = [
  'schemas/linux-product-feature-proof-registry.schema.json',
  'schemas/linux-product-feature-proof-registration.schema.json',
  'schemas/linux-product-feature-proof-closure.schema.json'
];
const CANDIDATE_RUN_ID = '12345';
const CANDIDATE_ARTIFACT_DIGEST = `sha256:${'e'.repeat(64)}`;
const RELEASE_ONLY_REQUIREMENTS_FOR_TEST = new Set(['P-01', 'P-03', 'P-04', 'P-37']);

function write(root, relativePath, contents) {
  const absolute = path.join(root, relativePath);
  fs.mkdirSync(path.dirname(absolute), { recursive: true });
  fs.writeFileSync(absolute, contents);
  return absolute;
}

function writeJson(root, relativePath, value) {
  return write(root, relativePath, `${JSON.stringify(value, null, 2)}\n`);
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function git(root, args) {
  return execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
}

function requirementManifest() {
  const minimumSupportMatrix = [
    ['ubuntu-24.04-gnome-x11-x86_64', 'Ubuntu 24.04', 'GNOME', 'X11', 'x86_64'],
    ['ubuntu-24.04-gnome-x11-aarch64', 'Ubuntu 24.04', 'GNOME', 'X11', 'aarch64'],
    ['ubuntu-24.04-gnome-wayland-x86_64', 'Ubuntu 24.04', 'GNOME', 'Wayland', 'x86_64'],
    ['ubuntu-24.04-gnome-wayland-aarch64', 'Ubuntu 24.04', 'GNOME', 'Wayland', 'aarch64'],
    ['fedora-kde-wayland-x86_64', 'Fedora', 'KDE Plasma', 'Wayland', 'x86_64'],
    ['fedora-kde-wayland-aarch64', 'Fedora', 'KDE Plasma', 'Wayland', 'aarch64'],
    ['arch-sway-wayland-x86_64', 'Arch Linux', 'Sway/wlroots', 'Wayland', 'x86_64']
  ].map(([id, os, desktop, session, architecture]) => ({ id, os, desktop, session, architecture }));
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-macos-parity-v1',
    minimumSupportMatrix,
    requirements: CANONICAL_REQUIREMENT_IDS.map((id) => ({ id, area: 'test' }))
  };
}

function validValidatorModule() {
  return `export async function validateProductRequirement(context) {
  const artifacts = [
    context.subjects.release,
    context.subjects.packageManifest,
    context.subjects.packageManifestSignature,
    ...context.subjects.packages,
    ...context.subjects.features.map(({ path, sha256 }) => ({ path, sha256 })),
    ...context.subjects.runtimes,
    ...context.subjects.installation,
    context.subjects.environment
  ];
  return {
    schemaVersion: 1,
    requirementId: context.requirementId,
    checkId: context.checkId,
    environmentId: context.environmentId,
    targetHead: context.targetHead,
    status: 'passed',
    artifacts
  };
}\n`;
}

function createRepository(options = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-product-validator-'));
  git(root, ['init', '-q']);
  git(root, ['config', 'user.name', 'OpenBurnBar Test']);
  git(root, ['config', 'user.email', 'test@openburnbar.invalid']);
  writeJson(root, 'docs/linux-port/product-parity-requirements.json', requirementManifest());
  for (const relativePath of [INSTALLED_SCHEMA, RUNTIME_SCHEMA, RUNTIME_CATALOG, ...FEATURE_SCHEMAS]) {
    write(root, relativePath, fs.readFileSync(path.join(SOURCE_ROOT, relativePath)));
  }
  writeJson(root, 'docs/linux-port/product-feature-proof-registry.json', options.featureRegistry ?? {
    schemaVersion: 1,
    id: 'openburnbar-linux-product-feature-proof-registry-v1',
    requirements: []
  });
  write(root, 'tracked-anchor.txt', 'clean\n');
  for (const [requirementId, source] of Object.entries(options.validators ?? {})) {
    write(root, `scripts/linux-port/product-validators/${requirementId}.mjs`, source);
  }
  git(root, ['add', '.']);
  git(root, ['commit', '-qm', 'test fixture']);
  return { root, head: git(root, ['rev-parse', 'HEAD']) };
}

function evidencePaths(requirementId, environmentId = ENVIRONMENT) {
  const directory = `docs/linux-port/evidence/product-parity-inputs/${requirementId}/${environmentId}`;
  const format = environmentPackage(environmentId).format;
  const extension = format === 'arch' ? 'pkg.tar.zst' : format;
  return {
    directory,
    closure: `${directory}/release-closure.json`,
    manifest: `${directory}/installed-manifest.json`,
    manifestSignature: `${directory}/installed-manifest.json.sig`,
    package: `${directory}/OpenBurnBar.${extension}`,
    runtime: `${directory}/live-runtime-capabilities.json`,
    runtimeFinal: `${directory}/live-runtime-capabilities-final.json`,
    liveManifest: `${directory}/live-installed-manifest.json`,
    liveSignature: `${directory}/live-installed-manifest.json.sig`,
    livePublicKey: `${directory}/live-release-ed25519.pub.pem`,
    liveVerification: `${directory}/live-install-verification.json`
  };
}

function filesRoot(files) {
  const lines = files.map((file) => file.type === 'file'
    ? `${file.path}\0file\0${file.sha256}\0${file.size}\0${file.mode}\0${file.uid}\0${file.gid}`
    : `${file.path}\0symlink\0${file.target}\0${file.mode}\0${file.uid}\0${file.gid}`)
    .sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)));
  return crypto.createHash('sha256').update(Buffer.from(lines.join('\n'), 'utf8')).digest('hex');
}

function writeEvidence(root, requirementId, head, options = {}) {
  const environmentId = options.environmentId ?? ENVIRONMENT;
  const environment = requirementManifest().minimumSupportMatrix.find((row) => row.id === environmentId);
  const selected = environmentPackage(environmentId);
  const paths = evidencePaths(requirementId, environmentId);
  const files = [
    {
      path: '/usr/bin/openburnbar-daemon',
      type: 'file',
      sha256: 'b'.repeat(64),
      size: 1,
      mode: '0755',
      uid: 0,
      gid: 0
    },
    {
      path: '/usr/bin/openburnbar-linux-desktop',
      type: 'file',
      sha256: 'c'.repeat(64),
      size: 1,
      mode: '0755',
      uid: 0,
      gid: 0
    }
  ];
  const manifest = options.manifest ?? {
    schemaVersion: 1,
    product: 'OpenBurnBar',
    appId: 'dev.openburnbar.OpenBurnBar',
    firebaseAppId: '1:123456789:web:abcdef',
    packageVersion: '1.2.3',
    gitCommit: head,
    packageArchitecture: selected.architecture,
    packageFormat: selected.format,
    packageName: selected.format === 'arch' ? 'openburnbar' : 'open-burn-bar',
    policyId: 'openburnbar-linux-signed-package-inventory-v1',
    brokerProtocolVersion: 2,
    installedFilesRootSha256: filesRoot(files),
    authorizedClients: [{
      role: 'daemon',
      path: '/usr/bin/openburnbar-daemon',
      sha256: 'b'.repeat(64),
      ownerUid: 0,
      ownerGid: 0,
      mode: 493
    }],
    files
  };
  const manifestFile = options.manifestBytes === undefined
    ? writeJson(root, paths.manifest, manifest)
    : write(root, paths.manifest, options.manifestBytes);
  const manifestSignatureFile = write(root, paths.manifestSignature, options.manifestSignatureBytes ?? Buffer.alloc(64, 7));
  const packageFile = write(root, paths.package, options.packageBytes ?? `package:${requirementId}\n`);
  const catalog = JSON.parse(fs.readFileSync(path.join(root, RUNTIME_CATALOG), 'utf8'));
  const runtime = options.runtime ?? {
    schemaVersion: 1,
    catalogVersion: catalog.catalogVersion,
    shellVersion: manifest.packageVersion,
    daemonVersion: manifest.packageVersion,
    daemonProtocolVersion: 1,
    sessionType: environment.session.toLowerCase(),
    desktop: environment.desktop,
    capabilities: catalog.capabilities.map((entry) => ({
      id: entry.id,
      domain: entry.domain,
      state: 'available',
      reason: 'test fixture',
      substitute: null,
      source: 'test-fixture'
    }))
  };
  const closure = {
    schemaVersion: 1,
    targetHead: options.targetHead ?? head,
    sourceCommit: options.sourceCommit ?? head,
    passed: true,
    blockers: [],
    candidate: {
      runId: CANDIDATE_RUN_ID,
      artifactDigest: CANDIDATE_ARTIFACT_DIGEST,
      productProofClosureSha256: sha256(manifestFile)
    },
    packageManifest: {
      path: paths.manifest,
      sha256: options.manifestSha256 ?? sha256(manifestFile)
    },
    packageManifestSignature: {
      path: paths.manifestSignature,
      sha256: options.manifestSignatureSha256 ?? sha256(manifestSignatureFile)
    },
    packages: [{ path: paths.package, sha256: options.packageSha256 ?? sha256(packageFile) }]
  };
  writeJson(root, paths.closure, closure);
  return { paths, closure, manifest, runtime };
}

function record(root, relativePath, includeSize = false) {
  const absolute = path.join(root, relativePath);
  return {
    path: relativePath,
    sha256: sha256(absolute),
    ...(includeSize ? { size: fs.statSync(absolute).size } : {})
  };
}

function featureRegistry(requirementId = 'P-02') {
  return {
    schemaVersion: 1,
    id: 'openburnbar-linux-product-feature-proof-registry-v1',
    requirements: [{
      requirementId,
      artifacts: [{
        role: 'feature.parity-report',
        mediaType: 'application/json',
        maxBytes: 4096
      }]
    }]
  };
}

function writeRegisteredFeatureEvidence(root, head) {
  const requirementId = 'P-02';
  const evidence = writeEvidence(root, requirementId, head);
  const { paths } = evidence;
  const registryPath = `${paths.directory}/.linux-release/sidecars/product-feature-proof-registry.json`;
  write(root, registryPath, fs.readFileSync(path.join(root, 'docs/linux-port/product-feature-proof-registry.json')));
  const registryAggregateRecord = {
    path: 'sidecars/product-feature-proof-registry.json',
    sha256: sha256(path.join(root, registryPath)),
    size: fs.statSync(path.join(root, registryPath)).size
  };
  const releaseTypes = ['appimage', 'daemon', 'deb', 'rpm'];
  const architectures = ['aarch64', 'x86_64'];
  const placeholder = { path: 'unused', sha256: 'a'.repeat(64) };
  const aggregate = {
    schemaVersion: 2,
    stage: 'candidate',
    status: 'passed',
    targetHead: head,
    sourceCommit: head,
    version: '1.2.3',
    git: { dirty: false },
    architectures,
    supportEnvironments: CANONICAL_ENVIRONMENT_IDS,
    releaseArtifacts: releaseTypes.flatMap((type) => architectures.map((architecture) => ({
      type,
      architecture,
      artifact: placeholder,
      detachedSignature: placeholder,
      sigstore: placeholder
    }))),
    packages: ['deb', 'rpm'].flatMap((format) => architectures.map((architecture) => ({
      format,
      architecture,
      artifact: placeholder,
      installedManifest: placeholder,
      installedManifestSignature: placeholder
    }))),
    featureProofRegistry: registryAggregateRecord,
    proofs: [{ role: 'fixture' }],
    blockers: []
  };
  const aggregatePath = `${paths.directory}/.linux-release/product-proof-closure.json`;
  writeJson(root, aggregatePath, aggregate);
  const featureSourcePath = `${paths.directory}/feature-artifacts/parity-report.json`;
  writeJson(root, featureSourcePath, { passed: true, requirementId, environmentId: ENVIRONMENT });
  const featureClosurePath = `${paths.directory}/feature-proof-closure.json`;
  const featureClosure = {
    schemaVersion: 1,
    targetHead: head,
    sourceCommit: head,
    status: 'collected',
    requirementId,
    environmentId: ENVIRONMENT,
    version: '1.2.3',
    candidate: {
      runId: CANDIDATE_RUN_ID,
      artifactDigest: CANDIDATE_ARTIFACT_DIGEST,
      productProofClosureSha256: sha256(path.join(root, aggregatePath))
    },
    registry: record(root, registryPath, true),
    proofs: [{
      role: 'feature.parity-report',
      mediaType: 'application/json',
      ...record(root, featureSourcePath, true)
    }],
    blockers: []
  };
  writeJson(root, featureClosurePath, featureClosure);
  const materializedPath = `${paths.directory}/release-subjects/00-feature-parity-report-parity-report.json`;
  write(root, materializedPath, fs.readFileSync(path.join(root, featureSourcePath)));
  const closure = {
    schemaVersion: 3,
    targetHead: head,
    sourceCommit: head,
    status: 'passed',
    requirementId,
    environmentId: ENVIRONMENT,
    version: '1.2.3',
    architectures,
    supportEnvironments: CANONICAL_ENVIRONMENT_IDS,
    selectedPackage: { architecture: 'x86_64', format: 'deb' },
    candidate: {
      runId: CANDIDATE_RUN_ID,
      artifactDigest: CANDIDATE_ARTIFACT_DIGEST,
      productProofClosureSha256: sha256(path.join(root, aggregatePath))
    },
    featureProofClosure: record(root, featureClosurePath, true),
    packageManifest: evidence.closure.packageManifest,
    packageManifestSignature: evidence.closure.packageManifestSignature,
    packages: evidence.closure.packages,
    proofs: [{
      role: 'feature.parity-report',
      mediaType: 'application/json',
      evidenceClass: 'feature',
      ...record(root, materializedPath, true)
    }],
    blockers: []
  };
  writeJson(root, paths.closure, closure);
  return {
    ...evidence,
    aggregatePath,
    featureClosurePath,
    featureSourcePath,
    materializedPath,
    featureClosure,
    closure
  };
}

function featureValidatorModule({ mutate = false } = {}) {
  return `import fs from 'node:fs';
import path from 'node:path';
export async function validateProductRequirement(context) {
  ${mutate ? "fs.writeFileSync(path.join(context.repoRoot, context.subjects.features[0].path), 'substituted-after-dispatch\\n');" : ''}
  const artifacts = [
    context.subjects.release,
    context.subjects.packageManifest,
    context.subjects.packageManifestSignature,
    ...context.subjects.packages,
    ...context.subjects.features.map(({ path, sha256 }) => ({ path, sha256 })),
    ...context.subjects.runtimes,
    ...context.subjects.installation,
    context.subjects.environment
  ];
  return {
    schemaVersion: 1,
    requirementId: context.requirementId,
    checkId: context.checkId,
    environmentId: context.environmentId,
    targetHead: context.targetHead,
    status: 'passed',
    artifacts
  };
}\n`;
}

function validHostProbe(expected, installedManifest) {
  const selected = environmentPackage(expected.id);
  const osIdentity = selected.format === 'deb'
    ? { id: 'ubuntu', versionId: '24.04' }
    : selected.format === 'rpm'
      ? { id: 'fedora', versionId: '43' }
      : { id: 'arch', versionId: null };
  return {
    schemaVersion: 1,
    environmentId: expected.id,
    platform: 'linux',
    os: osIdentity,
    architecture: expected.architecture,
    kernelRelease: '6.8.0-test',
    logind: {
      id: '2',
      type: expected.session.toLowerCase(),
      desktop: expected.desktop,
      class: 'user',
      active: true,
      remote: false,
      state: 'active',
      user: 1000
    },
    session: {
      type: expected.session.toLowerCase(),
      desktop: expected.desktop,
      display: ':99',
      waylandDisplay: null,
      dbusSession: true,
      runtimeDirectory: '/run/user/1000',
      swaySocket: null
    },
    package: {
      manager: { arch: 'pacman', deb: 'dpkg', rpm: 'rpm' }[selected.format],
      name: selected.format === 'arch' ? 'openburnbar' : 'open-burn-bar',
      status: 'installed',
      version: installedManifest.packageVersion,
      architecture: expected.architecture
    },
    checks: [{ id: 'fixture', passed: true, detail: 'measured' }],
    passed: true
  };
}

function validLiveInstallProbe({ installedManifest, expectedManifestBytes, expectedSignatureBytes }) {
  const signatureBytes = Buffer.from(expectedSignatureBytes);
  const publicKeyBytes = Buffer.from('test-ed25519-public-key\n', 'utf8');
  return {
    schemaVersion: 1,
    manifestBytes: Buffer.from(expectedManifestBytes),
    signatureBytes,
    publicKeyBytes,
    verification: {
      schemaVersion: 1,
      liveManifestSha256: crypto.createHash('sha256').update(expectedManifestBytes).digest('hex'),
      signatureSha256: crypto.createHash('sha256').update(signatureBytes).digest('hex'),
      publicKeySha256: crypto.createHash('sha256').update(publicKeyBytes).digest('hex'),
      installedFilesRootSha256: installedManifest.installedFilesRootSha256,
      installedFileCount: installedManifest.files.length,
      packageOwnedPathCount: installedManifest.files.length + 2,
      authorizedDaemonSha256: installedManifest.authorizedClients[0].sha256,
      passed: true
    }
  };
}

function validRuntimeProbe({ expectedEnvironment, installedManifest }) {
  const catalog = JSON.parse(fs.readFileSync(path.join(SOURCE_ROOT, RUNTIME_CATALOG), 'utf8'));
  const runtime = {
    schemaVersion: 1,
    catalogVersion: catalog.catalogVersion,
    shellVersion: installedManifest.packageVersion,
    daemonVersion: installedManifest.packageVersion,
    daemonProtocolVersion: 1,
    sessionType: expectedEnvironment.session.toLowerCase(),
    desktop: expectedEnvironment.desktop,
    capabilities: catalog.capabilities.map((entry) => ({
      id: entry.id,
      domain: entry.domain,
      state: 'available',
      reason: 'test fixture',
      substitute: null,
      source: 'test-fixture'
    }))
  };
  return { bytes: Buffer.from(`${JSON.stringify(runtime)}\n`, 'utf8') };
}

function dispatch(argv, root, options = {}) {
  return main(argv, root, {
    hostProbe: validHostProbe,
    liveInstallProbe: validLiveInstallProbe,
    runtimeProbe: validRuntimeProbe,
    allowLegacyReleaseClosureFixture: true,
    ...options
  });
}

function productionDispatch(argv, root, options = {}) {
  return dispatch(argv, root, { ...options, allowLegacyReleaseClosureFixture: false });
}

function args(
  requirementId,
  releaseClosurePath = evidencePaths(requirementId).closure,
  outputPath = null,
  environmentId = ENVIRONMENT,
  candidateRunId = CANDIDATE_RUN_ID,
  candidateArtifactDigest = CANDIDATE_ARTIFACT_DIGEST
) {
  const checkId = `${requirementId.toLowerCase()}.test`;
  return [
    '--requirement', requirementId,
    '--environment', environmentId,
    '--release-closure', releaseClosurePath,
    '--candidate-run-id', candidateRunId,
    '--candidate-artifact-digest', candidateArtifactDigest,
    '--output', outputPath ?? canonicalOutputPath(requirementId, checkId, environmentId)
  ];
}

async function rejectsWithMessage(action, pattern) {
  await assert.rejects(action, pattern);
}

test('only explicit release-owned legacy fixtures reach missing validators; all other legacy closures fail first', async (t) => {
  const { root, head } = createRepository();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const requirementId of CANONICAL_REQUIREMENT_IDS) writeEvidence(root, requirementId, head);

  for (const requirementId of CANONICAL_REQUIREMENT_IDS) {
    await rejectsWithMessage(
      () => dispatch(args(requirementId), root),
      RELEASE_ONLY_REQUIREMENTS_FOR_TEST.has(requirementId)
        ? new RegExp(`${requirementId} validator module does not exist`)
        : /release closure schemaVersion must be 3/u
    );
    const output = canonicalOutputPath(requirementId, `${requirementId.toLowerCase()}.test`, ENVIRONMENT);
    assert.equal(fs.existsSync(path.join(root, output)), false, `${requirementId} must not leave a receipt`);
  }
});

test('missing validator failure removes a stale canonical receipt before checking cleanliness', async (t) => {
  const { root, head } = createRepository();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const requirementId = 'P-01';
  writeEvidence(root, requirementId, head);
  const output = canonicalOutputPath(requirementId, 'p-01.test', ENVIRONMENT);
  write(root, output, 'stale receipt\n');

  await rejectsWithMessage(() => dispatch(args(requirementId), root), /validator module does not exist/u);
  assert.equal(fs.existsSync(path.join(root, output)), false);
});

test('dispatcher binds distinct release, package, live installed environment, and runtime subjects', async (t) => {
  const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const { paths } = writeEvidence(root, 'P-01', head);

  const result = await dispatch(args('P-01'), root);
  assert.equal(result.receipt.schemaVersion, 2);
  assert.equal(result.receipt.status, 'passed');
  assert.equal(result.receipt.subject.releaseClosureSha256, sha256(path.join(root, paths.closure)));
  assert.equal(result.receipt.subject.packageManifestSha256, sha256(path.join(root, paths.manifest)));
  const liveEnvironment = `${paths.directory}/live-environment-manifest.json`;
  assert.equal(result.receipt.subject.installedEnvironmentSha256, sha256(path.join(root, liveEnvironment)));
  assert.equal(result.receipt.subject.runtimeManifestSha256, sha256(path.join(root, paths.runtimeFinal)));
  assert.equal(result.receipt.producer.sourceTree, head);
  assert.equal(result.receipt.producer.repository, 'Imagine-That-Ai/BurnBar');
  assert.match(result.receipt.producer.sourceRef, /^refs\/heads\//u);
  assert.deepEqual(
    result.receipt.artifacts,
    [
      paths.package,
      paths.closure,
      paths.manifest,
      paths.manifestSignature,
      paths.runtime,
      paths.runtimeFinal,
      paths.liveManifest,
      paths.liveSignature,
      paths.livePublicKey,
      paths.liveVerification,
      liveEnvironment
    ]
      .sort((left, right) => left.localeCompare(right))
      .map((relativePath) => ({ path: relativePath, sha256: sha256(path.join(root, relativePath)) }))
  );
  assert.equal(fs.statSync(path.join(root, result.outputPath)).mode & 0o777, 0o600);
});

test('canonical schema-3 closures require the immutable aggregate and registry before dispatch', async (t) => {
  const repository = createRepository({ validators: { 'P-01': validValidatorModule() } });
  t.after(() => fs.rmSync(repository.root, { recursive: true, force: true }));
  const evidence = writeEvidence(repository.root, 'P-01', repository.head);
  evidence.closure.schemaVersion = 3;
  evidence.closure.requirementId = 'P-01';
  evidence.closure.environmentId = ENVIRONMENT;
  evidence.closure.status = 'passed';
  evidence.closure.selectedPackage = { architecture: 'x86_64', format: 'deb' };
  writeJson(repository.root, evidence.paths.closure, evidence.closure);
  await rejectsWithMessage(
    () => dispatch(args('P-01'), repository.root),
    /aggregate product proof closure does not exist/u
  );
});

test('canonical materialized closures cannot downgrade the release closure schema', async (t) => {
  const repository = createRepository({ validators: { 'P-01': validValidatorModule() } });
  t.after(() => fs.rmSync(repository.root, { recursive: true, force: true }));
  const evidence = writeEvidence(repository.root, 'P-01', repository.head);
  evidence.closure.schemaVersion = 2;
  evidence.closure.requirementId = 'P-01';
  evidence.closure.environmentId = ENVIRONMENT;
  evidence.closure.status = 'passed';
  writeJson(repository.root, evidence.paths.closure, evidence.closure);
  await rejectsWithMessage(
    () => dispatch(args('P-01'), repository.root),
    /release closure schemaVersion must be 3/u
  );
});

test('marker stripping cannot downgrade a production release closure to legacy schema', async (t) => {
  const repository = createRepository({ validators: { 'P-01': validValidatorModule() } });
  t.after(() => fs.rmSync(repository.root, { recursive: true, force: true }));
  const evidence = writeEvidence(repository.root, 'P-01', repository.head);
  evidence.closure.schemaVersion = 1;
  for (const field of ['requirementId', 'environmentId', 'status', 'selectedPackage', 'featureProofClosure', 'proofs']) {
    delete evidence.closure[field];
  }
  writeJson(repository.root, evidence.paths.closure, evidence.closure);
  await rejectsWithMessage(
    () => productionDispatch(args('P-01'), repository.root),
    /release closure schemaVersion must be 3/u
  );
});

test('legacy compatibility rejects future schemas and every non-release requirement', async (t) => {
  for (const [requirementId, schemaVersion] of [['P-01', 4], ['P-02', 1]]) {
    await t.test(`${requirementId} schema ${schemaVersion}`, async (subtest) => {
      const repository = createRepository({ validators: { [requirementId]: validValidatorModule() } });
      subtest.after(() => fs.rmSync(repository.root, { recursive: true, force: true }));
      const evidence = writeEvidence(repository.root, requirementId, repository.head);
      evidence.closure.schemaVersion = schemaVersion;
      writeJson(repository.root, evidence.paths.closure, evidence.closure);
      await rejectsWithMessage(
        () => dispatch(args(requirementId), repository.root),
        /release closure schemaVersion must be 3/u
      );
    });
  }
});

test('dispatcher binds registered feature proof bytes and path into validator-required subjects', async (t) => {
  const repository = createRepository({
    featureRegistry: featureRegistry(),
    validators: { 'P-02': featureValidatorModule() }
  });
  t.after(() => fs.rmSync(repository.root, { recursive: true, force: true }));
  const evidence = writeRegisteredFeatureEvidence(repository.root, repository.head);
  const result = await productionDispatch(args('P-02'), repository.root);
  assert.ok(result.receipt.artifacts.some((artifact) =>
    artifact.path === evidence.materializedPath
      && artifact.sha256 === sha256(path.join(repository.root, evidence.materializedPath))
  ));
});

test('dispatcher rejects materialized feature path and byte substitutions', async (t) => {
  for (const mutation of ['path', 'bytes']) {
    await t.test(mutation, async (subtest) => {
      const repository = createRepository({
        featureRegistry: featureRegistry(),
        validators: { 'P-02': featureValidatorModule() }
      });
      subtest.after(() => fs.rmSync(repository.root, { recursive: true, force: true }));
      const evidence = writeRegisteredFeatureEvidence(repository.root, repository.head);
      const row = evidence.closure.proofs[0];
      if (mutation === 'path') {
        const substitutedPath = `${evidence.paths.directory}/release-subjects/substituted.json`;
        write(repository.root, substitutedPath, fs.readFileSync(path.join(repository.root, evidence.materializedPath)));
        row.path = substitutedPath;
      } else {
        writeJson(repository.root, evidence.materializedPath, { passed: false, substituted: true });
        Object.assign(row, record(repository.root, evidence.materializedPath, true));
      }
      writeJson(repository.root, evidence.paths.closure, evidence.closure);
      await rejectsWithMessage(
        () => productionDispatch(args('P-02'), repository.root),
        mutation === 'path' ? /materialized feature proof path is not canonical/u : /does not match its immutable closure/u
      );
    });
  }
});

test('dispatcher detects registered feature mutation after validator import and removes stale output', async (t) => {
  const repository = createRepository({
    featureRegistry: featureRegistry(),
    validators: { 'P-02': featureValidatorModule({ mutate: true }) }
  });
  t.after(() => fs.rmSync(repository.root, { recursive: true, force: true }));
  writeRegisteredFeatureEvidence(repository.root, repository.head);
  await rejectsWithMessage(
    () => productionDispatch(args('P-02'), repository.root),
    /validator result artifact hash mismatch/u
  );
  assert.equal(
    fs.existsSync(path.join(repository.root, canonicalOutputPath('P-02', 'p-02.test', ENVIRONMENT))),
    false
  );
});

test('joint release and feature candidate substitution cannot replace trusted resolver provenance', async (t) => {
  const repository = createRepository({
    featureRegistry: featureRegistry(),
    validators: { 'P-02': featureValidatorModule() }
  });
  t.after(() => fs.rmSync(repository.root, { recursive: true, force: true }));
  const evidence = writeRegisteredFeatureEvidence(repository.root, repository.head);
  const substituted = {
    runId: '99999',
    artifactDigest: `sha256:${'9'.repeat(64)}`,
    productProofClosureSha256: evidence.closure.candidate.productProofClosureSha256
  };
  evidence.featureClosure.candidate = substituted;
  writeJson(repository.root, evidence.featureClosurePath, evidence.featureClosure);
  evidence.closure.candidate = substituted;
  evidence.closure.featureProofClosure = record(repository.root, evidence.featureClosurePath, true);
  writeJson(repository.root, evidence.paths.closure, evidence.closure);
  await rejectsWithMessage(
    () => productionDispatch(args('P-02'), repository.root),
    /candidate does not match the independently resolved evidence artifact/u
  );
});

test('dispatcher rejects canonical closure identity mismatches before validator import', async (t) => {
  const mutations = [
    ['requirementId', (closure) => { closure.requirementId = 'P-03'; }, /requirementId does not match/u],
    ['environmentId', (closure) => { closure.environmentId = CANONICAL_ENVIRONMENT_IDS[1]; }, /environmentId does not match/u],
    ['selectedPackage', (closure) => { closure.selectedPackage.architecture = 'aarch64'; }, /selectedPackage does not match/u]
  ];
  for (const [name, mutate, pattern] of mutations) {
    await t.test(name, async (subtest) => {
      const repository = createRepository({
        featureRegistry: featureRegistry(),
        validators: { 'P-02': featureValidatorModule() }
      });
      subtest.after(() => fs.rmSync(repository.root, { recursive: true, force: true }));
      const evidence = writeRegisteredFeatureEvidence(repository.root, repository.head);
      mutate(evidence.closure);
      writeJson(repository.root, evidence.paths.closure, evidence.closure);
      await rejectsWithMessage(() => productionDispatch(args('P-02'), repository.root), pattern);
    });
  }
});

test('native package probe selects and parses the canonical manager for every support OS', () => {
  const environments = requirementManifest().minimumSupportMatrix;
  const cases = [
    {
      id: 'ubuntu-24.04-gnome-x11-x86_64',
      command: 'dpkg-query',
      output: 'installed\t1.2.3\tamd64',
      expected: { manager: 'dpkg', name: 'open-burn-bar', status: 'installed', version: '1.2.3', architecture: 'x86_64' }
    },
    {
      id: 'fedora-kde-wayland-aarch64',
      command: 'rpm',
      output: 'open-burn-bar\t1.2.3\taarch64',
      expected: { manager: 'rpm', name: 'open-burn-bar', status: 'installed', version: '1.2.3', architecture: 'aarch64' }
    },
    {
      id: 'arch-sway-wayland-x86_64',
      command: 'pacman',
      output: 'Name            : openburnbar\nVersion         : 1.2.3-1\nArchitecture    : x86_64\nDescription     : OpenBurnBar',
      expected: { manager: 'pacman', name: 'openburnbar', status: 'installed', version: '1.2.3', architecture: 'x86_64' }
    }
  ];
  for (const fixture of cases) {
    const expectedEnvironment = environments.find((row) => row.id === fixture.id);
    const calls = [];
    const actual = queryInstalledPackage(expectedEnvironment, (command, commandArgs) => {
      calls.push({ command, commandArgs });
      return fixture.output;
    });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].command, fixture.command);
    assert.deepEqual(actual, fixture.expected);
  }
  const arch = environments.find((row) => row.id === 'arch-sway-wayland-x86_64');
  assert.throws(
    () => queryInstalledPackage(arch, () => 'Name : openburnbar\nVersion : 1.2.3'),
    /missing Name, Version, or Architecture/u
  );
});

test('Arch Sway dispatch binds the signed Arch package and live pacman identity', async (t) => {
  const environmentId = 'arch-sway-wayland-x86_64';
  const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const { paths } = writeEvidence(root, 'P-01', head, { environmentId });
  const result = await dispatch(
    args('P-01', paths.closure, null, environmentId),
    root
  );

  assert.equal(result.receipt.environmentId, environmentId);
  assert.ok(result.receipt.artifacts.some((artifact) => artifact.path.endsWith('.pkg.tar.zst')));
  const liveEnvironment = JSON.parse(
    fs.readFileSync(path.join(root, `${paths.directory}/live-environment-manifest.json`), 'utf8')
  );
  assert.deepEqual(liveEnvironment.os, { id: 'arch', versionId: null });
  assert.equal(liveEnvironment.package.manager, 'pacman');
  assert.equal(liveEnvironment.package.name, 'openburnbar');
});

test('Arch dispatch rejects substituted package format and live package manager', async (t) => {
  const environmentId = 'arch-sway-wayland-x86_64';
  for (const scenario of ['manifest-format', 'live-manager']) {
    await t.test(scenario, async (subtest) => {
      const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
      subtest.after(() => fs.rmSync(root, { recursive: true, force: true }));
      const evidence = writeEvidence(root, 'P-01', head, { environmentId });
      if (scenario === 'manifest-format') {
        evidence.manifest.packageFormat = 'rpm';
        evidence.manifest.packageName = 'open-burn-bar';
        writeJson(root, evidence.paths.manifest, evidence.manifest);
        evidence.closure.packageManifest.sha256 = sha256(path.join(root, evidence.paths.manifest));
        writeJson(root, evidence.paths.closure, evidence.closure);
        await rejectsWithMessage(
          () => dispatch(args('P-01', evidence.paths.closure, null, environmentId), root),
          /package manifest format must be arch/u
        );
        return;
      }
      const hostProbe = (expected, manifest) => {
        const result = validHostProbe(expected, manifest);
        result.package.manager = 'rpm';
        return result;
      };
      await rejectsWithMessage(
        () => dispatch(args('P-01', evidence.paths.closure, null, environmentId), root, { hostProbe }),
        /live installed package does not match/u
      );
    });
  }
});

test('live environment probe rejects every mismatched identity dimension', async (t) => {
  const mutations = [
    ['operating system', (manifest) => { manifest.os.id = 'fedora'; }, /operating system/u],
    ['architecture', (manifest) => { manifest.architecture = 'aarch64'; }, /architecture/u],
    ['session', (manifest) => { manifest.session.type = 'wayland'; }, /session/u],
    ['desktop', (manifest) => { manifest.session.desktop = 'KDE Plasma'; }, /desktop/u],
    ['logind session', (manifest) => { manifest.logind.type = 'wayland'; }, /logind session/u],
    ['logind desktop', (manifest) => { manifest.logind.desktop = 'KDE Plasma'; }, /logind session/u],
    ['remote logind session', (manifest) => { manifest.logind.remote = true; }, /logind session/u],
    ['package version', (manifest) => { manifest.package.version = '9.9.9'; }, /installed package/u],
    ['failed live check', (manifest) => { manifest.checks[0].passed = false; manifest.passed = false; }, /failed or missing check/u]
  ];
  for (const [name, mutate, pattern] of mutations) {
    await t.test(name, async (subtest) => {
      const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
      subtest.after(() => fs.rmSync(root, { recursive: true, force: true }));
      writeEvidence(root, 'P-01', head);
      const hostProbe = (expected, installedManifest) => {
        const manifest = validHostProbe(expected, installedManifest);
        mutate(manifest);
        return manifest;
      };
      await rejectsWithMessage(() => dispatch(args('P-01'), root, { hostProbe }), pattern);
    });
  }
});

test('dispatcher rejects live install evidence not bound to the signed package payload', async (t) => {
  for (const [name, mutate, pattern] of [
    ['manifest bytes', (result) => { result.manifestBytes = Buffer.from('{}\n'); }, /manifest bytes do not match/u],
    ['signature bytes', (result) => { result.signatureBytes = Buffer.alloc(64, 9); }, /signature bytes do not match/u],
    ['signature digest', (result) => { result.verification.signatureSha256 = '0'.repeat(64); }, /summary is not bound/u],
    ['inventory root', (result) => { result.verification.installedFilesRootSha256 = '0'.repeat(64); }, /summary is not bound/u]
  ]) {
    await t.test(name, async (subtest) => {
      const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
      subtest.after(() => fs.rmSync(root, { recursive: true, force: true }));
      writeEvidence(root, 'P-01', head);
      const liveInstallProbe = (context) => {
        const result = validLiveInstallProbe(context);
        mutate(result);
        return result;
      };
      await rejectsWithMessage(() => dispatch(args('P-01'), root, { liveInstallProbe }), pattern);
      for (const evidencePath of Object.values(evidencePaths('P-01')).filter((value) => value.includes('/live-'))) {
        assert.equal(fs.existsSync(path.join(root, evidencePath)), false);
      }
    });
  }
});

test('dispatcher rejects live installation replacement during requirement validation and erases proof', async (t) => {
  const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  writeEvidence(root, 'P-01', head);
  let calls = 0;
  const liveInstallProbe = (context) => {
    calls += 1;
    const result = validLiveInstallProbe(context);
    if (calls === 2) result.signatureBytes = Buffer.alloc(64, 9);
    if (calls === 2) {
      result.verification.signatureSha256 = crypto.createHash('sha256').update(result.signatureBytes).digest('hex');
    }
    return result;
  };
  await rejectsWithMessage(
    () => dispatch(args('P-01'), root, { liveInstallProbe }),
    /signature bytes do not match the release closure subject/u
  );
  assert.equal(calls, 2);
  assert.equal(fs.existsSync(path.join(root, canonicalOutputPath('P-01', 'p-01.test', ENVIRONMENT))), false);
  for (const evidencePath of Object.values(evidencePaths('P-01')).filter((value) => value.includes('/live-'))) {
    assert.equal(fs.existsSync(path.join(root, evidencePath)), false);
  }
});

test('package manifest must satisfy the canonical schema and invocation binding', async (t) => {
  const cases = [
    ['opaque package manifest', 'manifest', (root, file) => write(root, file, 'not-json\n'), /package manifest subject is not valid JSON/u],
    ['wrong package commit', 'manifest', (root, file) => {
      const value = JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
      value.gitCommit = '0'.repeat(40);
      writeJson(root, file, value);
    }, /gitCommit does not match current HEAD/u]
  ];
  for (const [name, _subject, mutate, pattern] of cases) {
    await t.test(name, async (subtest) => {
      const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
      subtest.after(() => fs.rmSync(root, { recursive: true, force: true }));
      const { paths, closure } = writeEvidence(root, 'P-01', head);
      mutate(root, paths.manifest);
      const record = closure.packageManifest;
      record.sha256 = sha256(path.join(root, paths.manifest));
      writeJson(root, paths.closure, closure);
      await rejectsWithMessage(() => dispatch(args('P-01'), root), pattern);
    });
  }
});

test('runtime capability evidence is captured live and validated fail closed', async (t) => {
  for (const [name, mutate, pattern] of [
    ['opaque output', () => ({ bytes: Buffer.from('not-json\n') }), /runtime manifest subject is not valid JSON/u],
    ['incomplete inventory', (context) => {
      const captured = validRuntimeProbe(context);
      const value = JSON.parse(captured.bytes.toString('utf8'));
      value.capabilities.pop();
      return { bytes: Buffer.from(`${JSON.stringify(value)}\n`) };
    }, /capability inventory/u]
  ]) {
    await t.test(name, async (subtest) => {
      const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
      subtest.after(() => fs.rmSync(root, { recursive: true, force: true }));
      writeEvidence(root, 'P-01', head);
      await rejectsWithMessage(
        () => dispatch(args('P-01'), root, { runtimeProbe: (context) => mutate(context) }),
        pattern
      );
      assert.equal(fs.existsSync(path.join(root, evidencePaths('P-01').runtime)), false);
    });
  }
});

test('dispatcher preserves pre- and post-validator runtime state while binding the final capture', async (t) => {
  const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const { paths } = writeEvidence(root, 'P-01', head);
  let calls = 0;
  const runtimeProbe = (context) => {
    calls += 1;
    const capture = validRuntimeProbe(context);
    if (calls === 2) {
      const value = JSON.parse(capture.bytes.toString('utf8'));
      value.capabilities[0].state = 'degraded';
      value.capabilities[0].reason = 'changed during the validated workflow';
      capture.bytes = Buffer.from(`${JSON.stringify(value)}\n`);
    }
    return capture;
  };
  const result = await dispatch(args('P-01'), root, { runtimeProbe });
  assert.equal(calls, 2);
  assert.notEqual(sha256(path.join(root, paths.runtime)), sha256(path.join(root, paths.runtimeFinal)));
  assert.equal(result.receipt.subject.runtimeManifestSha256, sha256(path.join(root, paths.runtimeFinal)));
  assert.ok(result.receipt.artifacts.some((artifact) => artifact.path === paths.runtime));
  assert.ok(result.receipt.artifacts.some((artifact) => artifact.path === paths.runtimeFinal));
});

test('caller cannot supply a verdict or subject hash and stale output is still removed', async (t) => {
  const { root, head } = createRepository();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  writeEvidence(root, 'P-01', head);
  const output = canonicalOutputPath('P-01', 'p-01.test', ENVIRONMENT);
  write(root, output, 'stale\n');

  for (const forbidden of [
    ['--status', 'passed'],
    ['--passed', 'true'],
    ['--package-sha256', 'a'.repeat(64)],
    ['--runtime-sha256', 'b'.repeat(64)]
  ]) {
    write(root, output, 'stale\n');
    await rejectsWithMessage(() => dispatch([...args('P-01'), ...forbidden], root), /unknown argument/u);
    assert.equal(fs.existsSync(path.join(root, output)), false);
  }
});

test('argument parser rejects omissions, duplicates, unknown ids, and noncanonical output', async (t) => {
  const { root, head } = createRepository();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  writeEvidence(root, 'P-01', head);
  const canonicalArgs = args('P-01');
  const cases = [
    [canonicalArgs.slice(2), /--requirement is required/u],
    [[...canonicalArgs, '--requirement', 'P-01'], /--requirement may be specified only once/u],
    [canonicalArgs.map((value) => value === 'P-01' ? 'P-41' : value), /P-01 through P-40/u],
    [canonicalArgs.map((value) => value === ENVIRONMENT ? 'ubuntu-latest' : value), /canonical minimum support matrix/u],
    [args('P-01', evidencePaths('P-01').closure, 'tmp/receipt.json'), /--output must be exactly/u]
  ];
  for (const [argv, pattern] of cases) await rejectsWithMessage(() => dispatch(argv, root), pattern);
});

test('release closure traversal and absolute paths fail closed', async (t) => {
  const { root, head } = createRepository();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  writeEvidence(root, 'P-01', head);
  for (const malicious of ['../release-closure.json', '/tmp/release-closure.json', 'docs/linux-port/../release.json']) {
    await rejectsWithMessage(() => dispatch(args('P-01', malicious), root), /repository-relative|canonical|escapes|must be exactly/u);
  }
});

test('release closure symlinks fail closed even when their target is repository-confined', async (t) => {
  const { root, head } = createRepository();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const { paths } = writeEvidence(root, 'P-01', head);
  const target = `${paths.directory}/real-release-closure.json`;
  fs.renameSync(path.join(root, paths.closure), path.join(root, target));
  fs.symlinkSync(path.basename(target), path.join(root, paths.closure));

  await rejectsWithMessage(() => dispatch(args('P-01'), root), /traverses a symlink/u);
  assert.equal(fs.existsSync(path.join(root, canonicalOutputPath('P-01', 'p-01.test', ENVIRONMENT))), false);
});

test('symlinked package manifest and installed package subjects fail closed', async (t) => {
  for (const kind of ['manifest', 'package']) {
    await t.test(kind, async (subtest) => {
      const { root, head } = createRepository();
      subtest.after(() => fs.rmSync(root, { recursive: true, force: true }));
      const { paths, closure } = writeEvidence(root, 'P-01', head);
      const subjectPath = paths[kind];
      const targetPath = `${subjectPath}.real`;
      fs.renameSync(path.join(root, subjectPath), path.join(root, targetPath));
      fs.symlinkSync(path.basename(targetPath), path.join(root, subjectPath));
      const record = kind === 'manifest'
        ? closure.packageManifest
        : closure.packages[0];
      record.sha256 = sha256(path.join(root, targetPath));
      writeJson(root, paths.closure, closure);
      await rejectsWithMessage(() => dispatch(args('P-01'), root), /traverses a symlink/u);
    });
  }
});

test('tracked source or index dirt fails before validator dispatch', async (t) => {
  for (const mutation of ['worktree', 'index']) {
    await t.test(mutation, async (subtest) => {
      const { root, head } = createRepository();
      subtest.after(() => fs.rmSync(root, { recursive: true, force: true }));
      writeEvidence(root, 'P-01', head);
      fs.appendFileSync(path.join(root, 'tracked-anchor.txt'), 'dirty\n');
      if (mutation === 'index') git(root, ['add', 'tracked-anchor.txt']);
      await rejectsWithMessage(() => dispatch(args('P-01'), root), /tracked worktree and index must be clean/u);
    });
  }
});

test('unexpected untracked source outside evidence roots fails before validator dispatch', async (t) => {
  const { root, head } = createRepository();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  writeEvidence(root, 'P-01', head);
  write(root, 'unexpected.txt', 'dirty\n');
  await rejectsWithMessage(() => dispatch(args('P-01'), root), /unexpected untracked files/u);
});

test('release closure target and source commits must independently equal current HEAD', async (t) => {
  for (const field of ['targetHead', 'sourceCommit']) {
    await t.test(field, async (subtest) => {
      const { root, head } = createRepository();
      subtest.after(() => fs.rmSync(root, { recursive: true, force: true }));
      writeEvidence(root, 'P-01', head, { [field]: '0'.repeat(40) });
      await rejectsWithMessage(() => dispatch(args('P-01'), root), new RegExp(`${field === 'targetHead' ? 'target' : 'source'} commit does not match`));
    });
  }
});

test('subject hash mutation is detected before a validator result can pass', async (t) => {
  const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  writeEvidence(root, 'P-01', head, { packageSha256: 'f'.repeat(64) });
  await rejectsWithMessage(() => dispatch(args('P-01'), root), /package subject 0 sha256 does not match/u);
});

test('missing or checksum-mutated package manifest fails before validator dispatch', async (t) => {
  for (const mode of ['missing', 'mutated']) {
    await t.test(mode, async (subtest) => {
      const { root, head } = createRepository({ validators: { 'P-01': validValidatorModule() } });
      subtest.after(() => fs.rmSync(root, { recursive: true, force: true }));
      const { paths, closure } = writeEvidence(root, 'P-01', head);
      if (mode === 'missing') {
        delete closure.packageManifest;
      } else {
        closure.packageManifest.sha256 = 'f'.repeat(64);
      }
      writeJson(root, paths.closure, closure);
      await rejectsWithMessage(
        () => dispatch(args('P-01'), root),
        mode === 'missing' ? /exactly one package manifest/u : /package manifest subject sha256 does not match/u
      );
    });
  }
});

test('validator result must use the exact receipt schema and current invocation bindings', async (t) => {
  const mutations = [
    ['extra field', 'result.extra = true;', /fields must be exactly/u],
    ['failed status', "result.status = 'failed';", /status must be passed/u],
    ['wrong head', "result.targetHead = '0'.repeat(40);", /targetHead is not current HEAD/u],
    ['missing runtime subject', 'result.artifacts = result.artifacts.filter((item) => !item.path.includes(\'live-runtime-capabilities\'));', /omits or changes release subject/u]
  ];
  for (const [name, mutation, pattern] of mutations) {
    await t.test(name, async (subtest) => {
      const base = validValidatorModule();
      const source = base.replace('  return {', '  const result = {').replace('\n  };\n}', `\n  };\n  ${mutation}\n  return result;\n}`);
      const { root, head } = createRepository({ validators: { 'P-01': source } });
      subtest.after(() => fs.rmSync(root, { recursive: true, force: true }));
      writeEvidence(root, 'P-01', head);
      await rejectsWithMessage(() => dispatch(args('P-01'), root), pattern);
      assert.equal(fs.existsSync(path.join(root, canonicalOutputPath('P-01', 'p-01.test', ENVIRONMENT))), false);
    });
  }
});

test('noncanonical output never deletes a caller-selected path', async (t) => {
  const { root, head } = createRepository();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  writeEvidence(root, 'P-01', head);
  const protectedFile = write(root, 'protected.json', 'keep\n');
  await rejectsWithMessage(() => dispatch(args('P-01', evidencePaths('P-01').closure, '../protected.json'), root), /--output must be exactly/u);
  assert.equal(fs.readFileSync(protectedFile, 'utf8'), 'keep\n');
});
