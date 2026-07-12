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
  main
} from './run-product-requirement-validator.mjs';

const ENVIRONMENT = CANONICAL_ENVIRONMENT_IDS[0];
const SOURCE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const INSTALLED_SCHEMA = 'packaging/linux/attestation/openburnbar-installed-manifest.schema.json';
const RUNTIME_SCHEMA = 'schemas/linux-runtime-capability-manifest.schema.json';
const RUNTIME_CATALOG = 'packaging/linux/runtime-capability-catalog.json';
const CANDIDATE_RUN_ID = '12345';
const CANDIDATE_ARTIFACT_DIGEST = `sha256:${'e'.repeat(64)}`;

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
  for (const relativePath of [INSTALLED_SCHEMA, RUNTIME_SCHEMA, RUNTIME_CATALOG]) {
    write(root, relativePath, fs.readFileSync(path.join(SOURCE_ROOT, relativePath)));
  }
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
  return {
    directory,
    closure: `${directory}/release-closure.json`,
    manifest: `${directory}/installed-manifest.json`,
    manifestSignature: `${directory}/installed-manifest.json.sig`,
    package: `${directory}/OpenBurnBar.deb`,
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
  const paths = evidencePaths(requirementId, options.environmentId);
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
    packageArchitecture: 'x86_64',
    packageFormat: 'deb',
    packageName: 'open-burn-bar',
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
    sessionType: 'x11',
    desktop: 'GNOME',
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

function validHostProbe(expected, installedManifest) {
  return {
    schemaVersion: 1,
    environmentId: expected.id,
    platform: 'linux',
    os: { id: 'ubuntu', versionId: '24.04' },
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
      manager: 'dpkg',
      name: 'open-burn-bar',
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
    ...options
  });
}

function args(requirementId, releaseClosurePath = evidencePaths(requirementId).closure, outputPath = null) {
  const checkId = `${requirementId.toLowerCase()}.test`;
  return [
    '--requirement', requirementId,
    '--environment', ENVIRONMENT,
    '--release-closure', releaseClosurePath,
    '--output', outputPath ?? canonicalOutputPath(requirementId, checkId, ENVIRONMENT)
  ];
}

async function rejectsWithMessage(action, pattern) {
  await assert.rejects(action, pattern);
}

test('all 40 canonical requirements fail closed while their owned validator modules are absent', async (t) => {
  const { root, head } = createRepository();
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const requirementId of CANONICAL_REQUIREMENT_IDS) writeEvidence(root, requirementId, head);

  for (const requirementId of CANONICAL_REQUIREMENT_IDS) {
    await rejectsWithMessage(
      () => dispatch(args(requirementId), root),
      new RegExp(`${requirementId} validator module does not exist`)
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
    /canonical release closure schemaVersion must be 3/u
  );
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
