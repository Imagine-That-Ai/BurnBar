import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  resolveSqlcipherLibDir,
  resolveSwiftRuntimeDir,
  stageLinuxPackagePayload
} from './lib/linux-package-payload.mjs';

test('runtime discovery honors explicit architecture-local directories', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-runtime-discovery-'));
  const swift = path.join(root, 'swift');
  const sqlcipher = path.join(root, 'sqlcipher', 'lib');
  fs.mkdirSync(swift, { recursive: true });
  fs.mkdirSync(sqlcipher, { recursive: true });
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so.0'), 'runtime');

  assert.equal(
    resolveSwiftRuntimeDir({ env: { OPENBURNBAR_SWIFT_LIB_DIR: swift }, targetInfo: { paths: {} } }),
    swift
  );
  assert.equal(
    resolveSqlcipherLibDir({ env: { OPENBURNBAR_SQLCIPHER_PREFIX: path.join(root, 'sqlcipher') } }),
    sqlcipher
  );
  fs.rmSync(root, { recursive: true, force: true });
});

test('payload staging copies daemon, Swift tree, and SQLCipher SONAME', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-package-payload-'));
  const daemon = path.join(root, 'OpenBurnBarDaemon');
  const swift = path.join(root, 'swift-source');
  const sqlcipher = path.join(root, 'sqlcipher-source');
  const payload = path.join(root, 'payload');
  fs.writeFileSync(daemon, '#!/bin/sh\nexit 0\n');
  fs.chmodSync(daemon, 0o755);
  fs.mkdirSync(swift);
  fs.writeFileSync(path.join(swift, 'libswiftCore.so'), 'swift');
  fs.mkdirSync(sqlcipher);
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so.0'), 'sqlcipher');
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so'), 'sqlcipher');

  const report = stageLinuxPackagePayload({
    daemonBinary: daemon,
    payloadRoot: payload,
    swiftRuntimeDir: swift,
    sqlcipherLibDir: sqlcipher,
    probe: false
  });

  assert.ok(fs.statSync(report.daemon).mode & 0o100);
  assert.equal(fs.readFileSync(path.join(report.swiftRuntime, 'libswiftCore.so'), 'utf8'), 'swift');
  assert.equal(fs.readFileSync(path.join(report.nativeRuntime, 'libsqlcipher.so.0'), 'utf8'), 'sqlcipher');
  assert.deepEqual(report.sqlcipherFiles, ['libsqlcipher.so', 'libsqlcipher.so.0']);
  fs.rmSync(root, { recursive: true, force: true });
});

test('payload staging rejects SQLCipher trees without the required SONAME', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-package-payload-invalid-'));
  const daemon = path.join(root, 'daemon');
  const swift = path.join(root, 'swift');
  const sqlcipher = path.join(root, 'sqlcipher');
  fs.writeFileSync(daemon, 'daemon');
  fs.mkdirSync(swift);
  fs.mkdirSync(sqlcipher);
  fs.writeFileSync(path.join(sqlcipher, 'libsqlcipher.so'), 'sqlcipher');

  assert.throws(() => stageLinuxPackagePayload({
    daemonBinary: daemon,
    payloadRoot: path.join(root, 'payload'),
    swiftRuntimeDir: swift,
    sqlcipherLibDir: sqlcipher,
    probe: false
  }), /missing required SONAME/);
  fs.rmSync(root, { recursive: true, force: true });
});
