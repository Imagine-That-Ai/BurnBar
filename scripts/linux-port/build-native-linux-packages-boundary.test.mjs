import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const signer = path.join(repoRoot, 'scripts/linux-port/build-native-linux-packages.mjs');

test('legacy native-signing key environment is rejected before any child executes', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-env-reject-'));
  const marker = path.join(root, 'child-ran');
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'git'), `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(marker)}, 'ran');\n`, { mode: 0o755 });
  const result = spawnSync(process.execPath, [signer, '--private-key-stdin', '--version', '1.2.3'], {
    cwd: repoRoot,
    encoding: 'utf8',
    input: 'not-used',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM: 'environment-secret-must-not-leak'
    }
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /is forbidden/u);
  assert.doesNotMatch(result.stdout + result.stderr, /environment-secret-must-not-leak/u);
  assert.equal(fs.existsSync(marker), false);
  fs.rmSync(root, { recursive: true, force: true });
});

test('native signer requires a dedicated Linux Firebase app ID before any child executes', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-firebase-required-'));
  const marker = path.join(root, 'child-ran');
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'git'), `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(marker)}, 'ran');\n`, { mode: 0o755 });
  const result = spawnSync(process.execPath, [signer, '--private-key-stdin', '--version', '1.2.3'], {
    cwd: repoRoot,
    encoding: 'utf8',
    input: 'not-used',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      OPENBURNBAR_LINUX_FIREBASE_APP_ID: ''
    }
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /dedicated Linux firebaseAppId is required/u);
  assert.equal(fs.existsSync(marker), false);
  fs.rmSync(root, { recursive: true, force: true });
});

test('native signer rejects dedicated Linux Firebase ID collision before git', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-firebase-collision-'));
  const marker = path.join(root, 'child-ran');
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'git'), `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(marker)}, 'ran');\n`, { mode: 0o755 });
  const appId = '1:246956661961:web:2e267f5d3a84a525480118';
  const result = spawnSync(process.execPath, [signer, '--private-key-stdin', '--version', '1.2.3'], {
    cwd: repoRoot,
    encoding: 'utf8',
    input: 'not-used',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      OPENBURNBAR_LINUX_FIREBASE_APP_ID: appId,
      APP_CHECK_STANDARD_WEB_APP_IDS: appId
    }
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must not match a standard web Firebase app ID/u);
  assert.equal(fs.existsSync(marker), false);
  fs.rmSync(root, { recursive: true, force: true });
});

test('native signer rejects stale or omissive standard Web registry before git', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-firebase-registry-'));
  const marker = path.join(root, 'child-ran');
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'git'), `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(marker)}, 'ran');\n`, { mode: 0o755 });
  const result = spawnSync(process.execPath, [signer, '--private-key-stdin', '--version', '1.2.3'], {
    cwd: repoRoot,
    encoding: 'utf8',
    input: 'not-used',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      OPENBURNBAR_LINUX_FIREBASE_APP_ID: '1:123456789:web:linuxabcdef012345',
      APP_CHECK_STANDARD_WEB_APP_IDS: '1:987654321:web:stale\n1:987654321:web:omissive'
    }
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /does not exactly match committed production/u);
  assert.equal(fs.existsSync(marker), false);
  fs.rmSync(root, { recursive: true, force: true });
});

test('native signer rejects mismatched CLI and environment Firebase IDs before git', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-firebase-mismatch-'));
  const marker = path.join(root, 'child-ran');
  const bin = path.join(root, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'git'), `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(marker)}, 'ran');\n`, { mode: 0o755 });
  const result = spawnSync(process.execPath, [
    signer,
    '--private-key-stdin',
    '--version', '1.2.3',
    '--firebase-app-id', '1:123456789:web:linuxabcdef012345'
  ], {
    cwd: repoRoot,
    encoding: 'utf8',
    input: 'not-used',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      OPENBURNBAR_LINUX_FIREBASE_APP_ID: '1:987654321:web:otherlinuxabcdef'
    }
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /does not match OPENBURNBAR_LINUX_FIREBASE_APP_ID/u);
  assert.equal(fs.existsSync(marker), false);
  fs.rmSync(root, { recursive: true, force: true });
});
