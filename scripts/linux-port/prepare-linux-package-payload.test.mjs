import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  buildLinuxCloudAuthConfig,
  resolveIrohNativeLibrary,
  resolveSqlcipherLibDir,
  resolveSwiftRuntimeDir,
  stageLinuxPackagePayload
} from './lib/linux-package-payload.mjs';

const fixtureFirebaseAPIKey = ['AI', 'za', '12345678901234567890123456789012345'].join('');

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

test('payload staging copies daemon, Swift tree, and SQLCipher SONAME', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-package-payload-'));
  const daemon = path.join(root, 'OpenBurnBarDaemon');
  const bridge = path.join(root, 'openburnbar-playwright-bridge.js');
  const browserProbe = path.join(root, 'openburnbar-browser-runtime-probe');
  const browserRequirements = path.join(root, 'browser-runtime-requirements.json');
  const swift = path.join(root, 'swift-source');
  const sqlcipher = path.join(root, 'sqlcipher-source');
  const iroh = path.join(root, 'libopenburnbar_iroh.so');
  const payload = path.join(root, 'payload');
  fs.writeFileSync(daemon, '#!/bin/sh\nexit 0\n');
  fs.writeFileSync(bridge, 'bridge');
  fs.writeFileSync(browserProbe, '#!/bin/sh\nexit 0\n');
  fs.writeFileSync(browserRequirements, '{"schemaVersion":1}\n');
  fs.chmodSync(daemon, 0o755);
  fs.mkdirSync(swift);
  fs.writeFileSync(path.join(swift, 'libswiftCore.so'), 'swift');
  fs.mkdirSync(sqlcipher);
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so.0'), 'sqlcipher');
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so'), 'sqlcipher');
  fs.writeFileSync(iroh, 'iroh');

  const report = stageLinuxPackagePayload({
    daemonBinary: daemon,
    playwrightBridge: bridge,
    browserRuntimeProbe: browserProbe,
    browserRuntimeRequirements: browserRequirements,
    payloadRoot: payload,
    swiftRuntimeDir: swift,
    sqlcipherLibDir: sqlcipher,
    irohNativeLibrary: iroh,
    probe: false
  });

  assert.ok(fs.statSync(report.daemon).mode & 0o100);
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
  fs.rmSync(root, { recursive: true, force: true });
});

test('payload staging rejects SQLCipher trees without the required SONAME', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-package-payload-invalid-'));
  const daemon = path.join(root, 'daemon');
  const bridge = path.join(root, 'bridge');
  const browserProbe = path.join(root, 'probe');
  const browserRequirements = path.join(root, 'requirements');
  const swift = path.join(root, 'swift');
  const sqlcipher = path.join(root, 'sqlcipher');
  const iroh = path.join(root, 'libopenburnbar_iroh.so');
  fs.writeFileSync(daemon, 'daemon');
  fs.writeFileSync(bridge, 'bridge');
  fs.writeFileSync(browserProbe, 'probe');
  fs.writeFileSync(browserRequirements, '{}');
  fs.mkdirSync(swift);
  fs.mkdirSync(sqlcipher);
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so'), 'sqlcipher');
  fs.writeFileSync(iroh, 'iroh');

  assert.throws(() => stageLinuxPackagePayload({
    daemonBinary: daemon,
    playwrightBridge: bridge,
    browserRuntimeProbe: browserProbe,
    browserRuntimeRequirements: browserRequirements,
    payloadRoot: path.join(root, 'payload'),
    swiftRuntimeDir: swift,
    sqlcipherLibDir: sqlcipher,
    irohNativeLibrary: iroh,
    probe: false
  }), /missing required SONAME/);
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
      OPENBURNBAR_LINUX_APP_CHECK_APP_ID: '1:123456789012:linux:abcdef1234567890'
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
