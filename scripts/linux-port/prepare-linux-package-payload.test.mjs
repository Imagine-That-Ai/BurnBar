import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { readStableUtf8File } from './lib/stable-file.mjs';
import {
  buildLinuxCloudAuthConfig,
  resolveIrohNativeLibrary,
  resolveLinuxResourceBundle,
  resolveLinuxResourceBundles,
  resolveSqlcipherLibDir,
  resolveSwiftRuntimeDir,
  stageLinuxPackagePayload,
  validateLinuxPackagePayload
} from './lib/linux-package-payload.mjs';

const fixtureFirebaseAPIKey = ['AI', 'za', '12345678901234567890123456789012345'].join('');

function createResourceBundle(root) {
  const resourceBundle = path.join(root, 'OpenBurnBarCore_OpenBurnBarCore.resources');
  fs.mkdirSync(resourceBundle);
  fs.writeFileSync(path.join(resourceBundle, 'catalog.json'), '{}\n');
  return resourceBundle;
}

test('runtime discovery honors explicit architecture-local directories', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-runtime-discovery-'));
  const swift = path.join(root, 'swift');
  const sqlcipher = path.join(root, 'sqlcipher', 'lib');
  fs.mkdirSync(swift, { recursive: true });
  fs.mkdirSync(sqlcipher, { recursive: true });
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so.0'), 'runtime');
  const iroh = path.join(root, 'iroh');
  fs.mkdirSync(iroh);
  fs.writeFileSync(path.join(iroh, 'libopenburnbar_iroh.so'), 'iroh');

  assert.equal(
    resolveSwiftRuntimeDir({ env: { OPENBURNBAR_SWIFT_LIB_DIR: swift }, targetInfo: { paths: {} } }),
    swift
  );
  assert.equal(
    resolveSqlcipherLibDir({ env: { OPENBURNBAR_SQLCIPHER_PREFIX: path.join(root, 'sqlcipher') } }),
    sqlcipher
  );
  assert.equal(
    resolveIrohNativeLibrary({ env: { OPENBURNBAR_LINUX_IROH_LIBRARY_DIR: iroh } }),
    path.join(iroh, 'libopenburnbar_iroh.so')
  );
  fs.rmSync(root, { recursive: true, force: true });
});

test('valid Swift runtime override bypasses the swift target-info probe', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-runtime-override-'));
  const swift = path.join(root, 'swift-runtime');
  const probe = path.join(root, 'swift');
  const marker = path.join(root, 'probe-invoked');
  fs.mkdirSync(swift);
  fs.writeFileSync(
    probe,
    `#!/bin/sh\nprintf probe > "$OPENBURNBAR_TEST_SWIFT_MARKER"\nexit 91\n`
  );
  fs.chmodSync(probe, 0o755);

  assert.equal(
    resolveSwiftRuntimeDir({
      env: {
        OPENBURNBAR_SWIFT_LIB_DIR: swift,
        OPENBURNBAR_TEST_SWIFT_MARKER: marker,
        PATH: root
      }
    }),
    swift
  );
  assert.equal(fs.existsSync(marker), false);
  fs.rmSync(root, { recursive: true, force: true });
});

test('invalid Swift runtime override fails clearly without falling back to swift', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-runtime-invalid-'));
  const probe = path.join(root, 'swift');
  const marker = path.join(root, 'probe-invoked');
  fs.writeFileSync(
    probe,
    `#!/bin/sh\nprintf probe > "$OPENBURNBAR_TEST_SWIFT_MARKER"\nexit 91\n`
  );
  fs.chmodSync(probe, 0o755);

  assert.throws(
    () => resolveSwiftRuntimeDir({
      env: {
        OPENBURNBAR_SWIFT_LIB_DIR: path.join(root, 'missing-runtime'),
        OPENBURNBAR_TEST_SWIFT_MARKER: marker,
        PATH: root
      }
    }),
    /Swift runtime directory not found:/
  );
  assert.equal(fs.existsSync(marker), false);
  fs.rmSync(root, { recursive: true, force: true });
});

test('default Swift runtime discovery still probes swift target info', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-runtime-default-'));
  const swift = path.join(root, 'swift');
  const runtime = path.join(root, 'swift-runtime');
  const marker = path.join(root, 'probe-invoked');
  fs.mkdirSync(runtime);
  const targetInfo = JSON.stringify({ paths: { runtimeLibraryPaths: [runtime] } });
  fs.writeFileSync(
    swift,
    `#!/bin/sh\nprintf probe > "$OPENBURNBAR_TEST_SWIFT_MARKER"\nprintf '%s' '${targetInfo}'\n`
  );
  fs.chmodSync(swift, 0o755);

  assert.equal(
    resolveSwiftRuntimeDir({
      env: {
        OPENBURNBAR_TEST_SWIFT_MARKER: marker,
        PATH: root
      }
    }),
    runtime
  );
  assert.equal(fs.readFileSync(marker, 'utf8'), 'probe');
  fs.rmSync(root, { recursive: true, force: true });
});

test('resource bundle discovery honors the Linux SwiftPM output name', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-resource-bundle-'));
  const bundle = path.join(root, 'OpenBurnBarCore_OpenBurnBarCore.resources');
  fs.mkdirSync(bundle);
  assert.equal(
    resolveLinuxResourceBundle({
      repoRoot: root,
      env: { OPENBURNBAR_LINUX_RESOURCE_BUNDLE: bundle }
    }),
    bundle
  );
  fs.rmSync(root, { recursive: true, force: true });
});

test('resource bundle discovery returns every OpenBurnBarCore SwiftPM sibling', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-resource-bundles-'));
  const release = path.join(root, 'OpenBurnBarDaemon', '.build', 'release');
  fs.mkdirSync(release, { recursive: true });
  for (const name of [
    'OpenBurnBarCore_OpenBurnBarKernel.resources',
    'OpenBurnBarCore_OpenBurnBarPretext.resources'
  ]) fs.mkdirSync(path.join(release, name));
  fs.mkdirSync(path.join(release, 'Unrelated.resources'));

  assert.deepEqual(resolveLinuxResourceBundles({ repoRoot: root, env: {} }), [
    path.join(release, 'OpenBurnBarCore_OpenBurnBarKernel.resources'),
    path.join(release, 'OpenBurnBarCore_OpenBurnBarPretext.resources')
  ]);
  assert.equal(
    resolveLinuxResourceBundle({ repoRoot: root, env: {} }),
    path.join(release, 'OpenBurnBarCore_OpenBurnBarKernel.resources')
  );
  fs.rmSync(root, { recursive: true, force: true });
});

test('explicit resource bundle discovers matching siblings without falling back elsewhere', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-explicit-resource-bundles-'));
  const explicitRoot = path.join(root, 'explicit');
  fs.mkdirSync(explicitRoot);
  const kernel = path.join(explicitRoot, 'OpenBurnBarCore_OpenBurnBarKernel.resources');
  const pretext = path.join(explicitRoot, 'OpenBurnBarCore_OpenBurnBarPretext.resources');
  fs.mkdirSync(kernel);
  fs.mkdirSync(pretext);
  assert.deepEqual(resolveLinuxResourceBundles({
    repoRoot: root,
    env: { OPENBURNBAR_LINUX_RESOURCE_BUNDLE: kernel }
  }), [kernel, pretext]);
  assert.throws(() => resolveLinuxResourceBundles({
    repoRoot: root,
    env: { OPENBURNBAR_LINUX_RESOURCE_BUNDLE: path.join(root, 'missing') }
  }), /directory not found/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('payload staging copies daemon, Swift tree, and SQLCipher SONAME', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-package-payload-'));
  const daemon = path.join(root, 'OpenBurnBarDaemon');
  const cli = path.join(root, 'OpenBurnBarCLI');
  const bridge = path.join(root, 'openburnbar-playwright-bridge.js');
  const browserProbe = path.join(root, 'openburnbar-browser-runtime-probe');
  const browserRequirements = path.join(root, 'browser-runtime-requirements.json');
  const swift = path.join(root, 'swift-source');
  const sqlcipher = path.join(root, 'sqlcipher-source');
  const iroh = path.join(root, 'libopenburnbar_iroh.so');
  const releasePublicKey = path.join(root, 'release-ed25519.pub.pem');
  const resourceBundle = createResourceBundle(root);
  const payload = path.join(root, 'payload');
  fs.writeFileSync(daemon, '#!/bin/sh\nexit 0\n');
  fs.writeFileSync(cli, '#!/bin/sh\nexit 0\n');
  fs.writeFileSync(bridge, 'bridge');
  fs.writeFileSync(browserProbe, '#!/bin/sh\nexit 0\n');
  fs.writeFileSync(browserRequirements, '{"schemaVersion":1}\n');
  fs.chmodSync(daemon, 0o755);
  fs.chmodSync(cli, 0o755);
  fs.mkdirSync(swift);
  fs.writeFileSync(path.join(swift, 'libswiftCore.so'), 'swift');
  fs.mkdirSync(sqlcipher);
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so.0'), 'sqlcipher');
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so'), 'sqlcipher');
  fs.writeFileSync(iroh, 'iroh');
  fs.writeFileSync(releasePublicKey, 'public-key');

  const report = stageLinuxPackagePayload({
    daemonBinary: daemon,
    cliBinary: cli,
    playwrightBridge: bridge,
    browserRuntimeProbe: browserProbe,
    browserRuntimeRequirements: browserRequirements,
    releasePublicKey,
    resourceBundle,
    payloadRoot: payload,
    swiftRuntimeDir: swift,
    sqlcipherLibDir: sqlcipher,
    irohNativeLibrary: iroh,
    probe: false
  });

  assert.ok(fs.statSync(report.daemon).mode & 0o100);
  assert.ok(fs.statSync(report.cli).mode & 0o100);
  assert.equal(fs.readFileSync(path.join(report.resourceBundle, 'catalog.json'), 'utf8'), '{}\n');
  assert.equal(fs.readFileSync(path.join(report.swiftRuntime, 'libswiftCore.so'), 'utf8'), 'swift');
  assert.equal(fs.readFileSync(path.join(report.nativeRuntime, 'libsqlcipher.so.0'), 'utf8'), 'sqlcipher');
  assert.deepEqual(report.sqlcipherFiles, ['libsqlcipher.so', 'libsqlcipher.so.0']);
  assert.equal(fs.readFileSync(report.irohNativeLibrary, 'utf8'), 'iroh');
  assert.equal(fs.statSync(report.irohNativeLibrary).mode & 0o777, 0o644);
  assert.equal(fs.readFileSync(report.playwrightBridge, 'utf8'), 'bridge');
  assert.equal(fs.statSync(report.playwrightBridge).mode & 0o777, 0o644);
  assert.equal(fs.statSync(report.browserRuntimeProbe).mode & 0o777, 0o755);
  assert.equal(fs.statSync(report.browserRuntimeRequirements).mode & 0o777, 0o644);
  assert.deepEqual(JSON.parse(fs.readFileSync(report.cloudAuthConfig, 'utf8')), {
    schemaVersion: 1,
    configured: false
  });
  assert.equal(fs.statSync(report.cloudAuthConfig).mode & 0o777, 0o644);
  assert.equal(fs.readFileSync(report.releasePublicKey, 'utf8'), 'public-key');
  assert.equal(fs.readFileSync(report.installedManifest, 'utf8'), '{}\n');
  assert.equal(fs.readFileSync(report.installedManifestSignature).length, 64);
  assert.equal(fs.statSync(report.releasePublicKey).mode & 0o777, 0o644);
  fs.rmSync(root, { recursive: true, force: true });
});

test('payload staging and reuse preserve every resource bundle exact basename', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-multi-bundle-payload-'));
  const inputs = Object.fromEntries(['daemon', 'cli', 'bridge', 'probe', 'requirements', 'iroh', 'key']
    .map((name) => [name, path.join(root, name)]));
  for (const candidate of Object.values(inputs)) fs.writeFileSync(candidate, candidate);
  const swift = path.join(root, 'swift');
  const sqlcipher = path.join(root, 'sqlcipher');
  fs.mkdirSync(swift);
  fs.mkdirSync(sqlcipher);
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so.0'), 'sqlcipher');
  const bundles = [
    'OpenBurnBarCore_OpenBurnBarKernel.resources',
    'OpenBurnBarCore_OpenBurnBarPretext.resources'
  ].map((name) => {
    const bundle = path.join(root, name);
    fs.mkdirSync(bundle);
    fs.writeFileSync(path.join(bundle, 'marker'), name);
    return bundle;
  });
  const payload = path.join(root, 'payload');
  const report = stageLinuxPackagePayload({
    daemonBinary: inputs.daemon,
    cliBinary: inputs.cli,
    playwrightBridge: inputs.bridge,
    browserRuntimeProbe: inputs.probe,
    browserRuntimeRequirements: inputs.requirements,
    releasePublicKey: inputs.key,
    resourceBundles: bundles,
    payloadRoot: payload,
    swiftRuntimeDir: swift,
    sqlcipherLibDir: sqlcipher,
    irohNativeLibrary: inputs.iroh,
    probe: false
  });
  assert.deepEqual(
    report.resourceBundles.map((bundle) => path.basename(bundle)),
    bundles.map((bundle) => path.basename(bundle))
  );
  for (const bundle of report.resourceBundles) {
    assert.equal(fs.readFileSync(path.join(bundle, 'marker'), 'utf8'), path.basename(bundle));
  }
  const reused = validateLinuxPackagePayload({ payloadRoot: payload, probe: false });
  assert.deepEqual(
    reused.resourceBundles.map((bundle) => path.basename(bundle)),
    bundles.map((bundle) => path.basename(bundle))
  );
  fs.rmSync(root, { recursive: true, force: true });
});

test('payload staging dereferences SQLCipher SONAME links', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-package-payload-links-'));
  const daemon = path.join(root, 'daemon');
  const cli = path.join(root, 'OpenBurnBarCLI');
  const bridge = path.join(root, 'bridge');
  const browserProbe = path.join(root, 'probe');
  const browserRequirements = path.join(root, 'requirements');
  const swift = path.join(root, 'swift');
  const sqlcipher = path.join(root, 'sqlcipher');
  const iroh = path.join(root, 'libopenburnbar_iroh.so');
  const releasePublicKey = path.join(root, 'release-ed25519.pub.pem');
  const resourceBundle = createResourceBundle(root);
  const payload = path.join(root, 'payload');
  const sqlcipherBinary = path.join(sqlcipher, 'libsqlcipher.so.0.8.6');
  fs.writeFileSync(daemon, 'daemon');
  fs.writeFileSync(cli, 'cli');
  fs.writeFileSync(bridge, 'bridge');
  fs.writeFileSync(browserProbe, 'probe');
  fs.writeFileSync(browserRequirements, '{}');
  fs.mkdirSync(swift);
  fs.mkdirSync(sqlcipher);
  fs.writeFileSync(sqlcipherBinary, 'sqlcipher');
  fs.symlinkSync(sqlcipherBinary, path.join(sqlcipher, 'libsqlcipher.so.0'));
  fs.symlinkSync('libsqlcipher.so.0', path.join(sqlcipher, 'libsqlcipher.so'));
  fs.writeFileSync(iroh, 'iroh');
  fs.writeFileSync(releasePublicKey, 'public-key');

  const report = stageLinuxPackagePayload({
    daemonBinary: daemon,
    cliBinary: cli,
    playwrightBridge: bridge,
    browserRuntimeProbe: browserProbe,
    browserRuntimeRequirements: browserRequirements,
    releasePublicKey,
    resourceBundle,
    payloadRoot: payload,
    swiftRuntimeDir: swift,
    sqlcipherLibDir: sqlcipher,
    irohNativeLibrary: iroh,
    probe: false
  });

  for (const entry of ['libsqlcipher.so', 'libsqlcipher.so.0']) {
    const staged = path.join(report.nativeRuntime, entry);
    assert.equal(fs.lstatSync(staged).isFile(), true);
    assert.equal(fs.lstatSync(staged).isSymbolicLink(), false);
    assert.ok(fs.existsSync(staged));
    assert.equal(readStableUtf8File(staged, `staged ${entry}`), 'sqlcipher');
  }
  assert.equal(
    readStableUtf8File(path.join(report.nativeRuntime, 'libsqlcipher.so.0.8.6'), 'staged SQLCipher target'),
    'sqlcipher'
  );
  fs.rmSync(root, { recursive: true, force: true });
});

test('payload staging rejects SQLCipher links outside the runtime directory', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-package-payload-links-invalid-'));
  const daemon = path.join(root, 'daemon');
  const cli = path.join(root, 'OpenBurnBarCLI');
  const bridge = path.join(root, 'bridge');
  const browserProbe = path.join(root, 'probe');
  const browserRequirements = path.join(root, 'requirements');
  const swift = path.join(root, 'swift');
  const sqlcipher = path.join(root, 'sqlcipher');
  const iroh = path.join(root, 'libopenburnbar_iroh.so');
  const releasePublicKey = path.join(root, 'release-ed25519.pub.pem');
  const resourceBundle = createResourceBundle(root);
  const outside = path.join(root, 'outside.so');
  fs.writeFileSync(daemon, 'daemon');
  fs.writeFileSync(cli, 'cli');
  fs.writeFileSync(bridge, 'bridge');
  fs.writeFileSync(browserProbe, 'probe');
  fs.writeFileSync(browserRequirements, '{}');
  fs.mkdirSync(swift);
  fs.mkdirSync(sqlcipher);
  fs.writeFileSync(outside, 'outside');
  fs.symlinkSync(outside, path.join(sqlcipher, 'libsqlcipher.so.0'));
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so'), 'sqlcipher');
  fs.writeFileSync(iroh, 'iroh');
  fs.writeFileSync(releasePublicKey, 'public-key');

  assert.throws(() => stageLinuxPackagePayload({
    daemonBinary: daemon,
    cliBinary: cli,
    playwrightBridge: bridge,
    browserRuntimeProbe: browserProbe,
    browserRuntimeRequirements: browserRequirements,
    releasePublicKey,
    resourceBundle,
    payloadRoot: path.join(root, 'payload'),
    swiftRuntimeDir: swift,
    sqlcipherLibDir: sqlcipher,
    irohNativeLibrary: iroh,
    probe: false
  }), /SQLCipher runtime symlink escapes its runtime directory/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('payload staging rejects SQLCipher trees without the required SONAME', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-package-payload-invalid-'));
  const daemon = path.join(root, 'daemon');
  const cli = path.join(root, 'OpenBurnBarCLI');
  const bridge = path.join(root, 'bridge');
  const browserProbe = path.join(root, 'probe');
  const browserRequirements = path.join(root, 'requirements');
  const swift = path.join(root, 'swift');
  const sqlcipher = path.join(root, 'sqlcipher');
  const iroh = path.join(root, 'libopenburnbar_iroh.so');
  const releasePublicKey = path.join(root, 'release-ed25519.pub.pem');
  const resourceBundle = createResourceBundle(root);
  fs.writeFileSync(daemon, 'daemon');
  fs.writeFileSync(cli, 'cli');
  fs.writeFileSync(bridge, 'bridge');
  fs.writeFileSync(browserProbe, 'probe');
  fs.writeFileSync(browserRequirements, '{}');
  fs.mkdirSync(swift);
  fs.mkdirSync(sqlcipher);
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so'), 'sqlcipher');
  fs.writeFileSync(iroh, 'iroh');
  fs.writeFileSync(releasePublicKey, 'public-key');

  assert.throws(() => stageLinuxPackagePayload({
    daemonBinary: daemon,
    cliBinary: cli,
    playwrightBridge: bridge,
    browserRuntimeProbe: browserProbe,
    browserRuntimeRequirements: browserRequirements,
    releasePublicKey,
    resourceBundle,
    payloadRoot: path.join(root, 'payload'),
    swiftRuntimeDir: swift,
    sqlcipherLibDir: sqlcipher,
    irohNativeLibrary: iroh,
    probe: false
  }), /missing required SONAME/);
  fs.rmSync(root, { recursive: true, force: true });
});

test('staged payload reuse validates in place without deleting the payload', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-staged-package-payload-'));
  const payload = path.join(root, 'payload');
  fs.mkdirSync(path.join(payload, 'OpenBurnBarCore_OpenBurnBarCore.resources'), { recursive: true });
  fs.mkdirSync(path.join(payload, 'swift'));
  fs.mkdirSync(path.join(payload, 'native'));
  fs.mkdirSync(path.join(payload, 'playwright'));
  fs.mkdirSync(path.join(payload, 'attestation'));
  fs.writeFileSync(path.join(payload, 'openburnbar-daemon'), 'daemon', { mode: 0o755 });
  fs.writeFileSync(path.join(payload, 'openburnbar-cli'), 'cli', { mode: 0o755 });
  fs.writeFileSync(
    path.join(payload, 'OpenBurnBarCore_OpenBurnBarCore.resources', 'catalog.json'),
    '{}\n'
  );
  fs.writeFileSync(path.join(payload, 'swift', 'libswiftCore.so'), 'swift');
  fs.writeFileSync(path.join(payload, 'native', 'libsqlcipher.so.0'), 'sqlcipher');
  fs.writeFileSync(path.join(payload, 'native', 'libopenburnbar_iroh.so'), 'iroh', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'playwright', 'openburnbar-playwright-bridge.js'), 'bridge', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'playwright', 'openburnbar-browser-runtime-probe'), 'probe', { mode: 0o755 });
  fs.writeFileSync(path.join(payload, 'playwright', 'browser-runtime-requirements.json'), '{}', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'cloud-auth.json'), '{"schemaVersion":1,"configured":false}\n', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'attestation', 'release-ed25519.pub.pem'), 'public-key', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'attestation', 'installed-manifest.json'), '{}\n', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'attestation', 'installed-manifest.json.sig'), Buffer.alloc(64), { mode: 0o644 });

  const before = fs.readdirSync(payload).sort();
  const report = validateLinuxPackagePayload({ payloadRoot: payload, probe: false });

  assert.equal(report.staged, true);
  assert.equal(report.payloadRoot, path.resolve(payload));
  assert.equal(report.daemon, path.join(path.resolve(payload), 'openburnbar-daemon'));
  assert.deepEqual(report.sqlcipherFiles, ['libsqlcipher.so.0']);
  assert.deepEqual(fs.readdirSync(payload).sort(), before);
  assert.equal(fs.readFileSync(path.join(payload, 'openburnbar-daemon'), 'utf8'), 'daemon');
  fs.rmSync(root, { recursive: true, force: true });
});

test('staged payload reuse fails closed when attestation is incomplete', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-staged-package-payload-invalid-'));
  const payload = path.join(root, 'payload');
  fs.mkdirSync(path.join(payload, 'OpenBurnBarCore_OpenBurnBarCore.resources'), { recursive: true });
  fs.mkdirSync(path.join(payload, 'swift'));
  fs.mkdirSync(path.join(payload, 'native'));
  fs.mkdirSync(path.join(payload, 'playwright'));
  fs.mkdirSync(path.join(payload, 'attestation'));
  fs.writeFileSync(path.join(payload, 'openburnbar-daemon'), 'daemon', { mode: 0o755 });
  fs.writeFileSync(path.join(payload, 'openburnbar-cli'), 'cli', { mode: 0o755 });
  fs.writeFileSync(path.join(payload, 'native', 'libsqlcipher.so.0'), 'sqlcipher');
  fs.writeFileSync(path.join(payload, 'native', 'libopenburnbar_iroh.so'), 'iroh', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'playwright', 'openburnbar-playwright-bridge.js'), 'bridge', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'playwright', 'openburnbar-browser-runtime-probe'), 'probe', { mode: 0o755 });
  fs.writeFileSync(path.join(payload, 'playwright', 'browser-runtime-requirements.json'), '{}', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'cloud-auth.json'), '{}', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'attestation', 'release-ed25519.pub.pem'), 'public-key', { mode: 0o644 });
  fs.writeFileSync(path.join(payload, 'attestation', 'installed-manifest.json'), '{}\n', { mode: 0o644 });

  assert.throws(
    () => validateLinuxPackagePayload({ payloadRoot: payload, probe: false }),
    /installed manifest signature file not found/
  );
  fs.rmSync(root, { recursive: true, force: true });
});

test('Linux package staging fails closed without the iroh native runtime', () => {
  assert.throws(
    () => resolveIrohNativeLibrary({ env: {} }),
    /OPENBURNBAR_LINUX_IROH_LIBRARY_DIR is required/
  );
});

test('release cloud auth config is complete, validated, and never contains tokens', () => {
  const config = buildLinuxCloudAuthConfig({
    requireConfigured: true,
    env: {
      OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID: '123456789012-desktop.apps.googleusercontent.com',
      OPENBURNBAR_FIREBASE_API_KEY: fixtureFirebaseAPIKey,
      OPENBURNBAR_LINUX_APP_CHECK_APP_ID: '1:123456789012:web:abcdef1234567890'
    }
  });
  assert.equal(config.configured, true);
  assert.doesNotMatch(JSON.stringify(config), /refreshToken|idToken|appCheckToken/);
  assert.throws(
    () => buildLinuxCloudAuthConfig({ requireConfigured: true, env: {} }),
    /Release packaging requires/
  );
  assert.throws(
    () => buildLinuxCloudAuthConfig({
      env: { OPENBURNBAR_FIREBASE_API_KEY: fixtureFirebaseAPIKey }
    }),
    /all public identifiers together/
  );
});
