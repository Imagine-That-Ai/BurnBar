import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  readShardAttestationSubject,
  validateAggregateInstalledManifest
} from './lib/linux-aggregate-installed-attestation.mjs';
import { createInstalledManifest } from './lib/linux-installed-manifest.mjs';

const COMMIT = 'a'.repeat(40);

function subject(root, name = 'manifest.json', bytes = Buffer.from('subject\n')) {
  const file = path.join(root, name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  return {
    file: name,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    size: bytes.length
  };
}

test('aggregate shard subject reader accepts exact regular bytes', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-aggregate-subject-'));
  const record = subject(root);
  assert.equal(readShardAttestationSubject(root, record, 'manifest').bytes.toString(), 'subject\n');
  fs.rmSync(root, { recursive: true, force: true });
});

test('aggregate shard subject reader rejects missing, escaping, symlinked, and hash-drifted inputs', async (t) => {
  for (const [name, prepare, pattern] of [
    ['missing', (root) => ({ file: 'missing', sha256: 'a'.repeat(64), size: 1 }), /missing/u],
    ['escape', (root) => ({ file: '../outside', sha256: 'a'.repeat(64), size: 1 }), /escapes/u],
    ['symlink', (root) => {
      const target = subject(root, 'target');
      fs.symlinkSync('target', path.join(root, 'link'));
      return { ...target, file: 'link' };
    }, /symlink/u],
    ['hash drift', (root) => ({ ...subject(root), sha256: 'b'.repeat(64) }), /SHA-256/u]
  ]) {
    await t.test(name, () => {
      const root = fs.mkdtempSync(path.join(os.tmpdir(), 'obb-aggregate-subject-'));
      assert.throws(() => readShardAttestationSubject(root, prepare(root), 'manifest'), pattern);
      fs.rmSync(root, { recursive: true, force: true });
    });
  }
});

test('aggregate installed manifest rejects a package-row identity swap', () => {
  const manifest = createInstalledManifest({
    packageVersion: '1.2.3',
    gitCommit: COMMIT,
    packageArchitecture: 'aarch64',
    packageFormat: 'deb',
    firebaseAppId: '1:123456789012:web:abcdef1234567890',
    files: [
      {
        path: '/usr/bin/openburnbar-daemon', type: 'file', sha256: 'b'.repeat(64),
        size: 1, mode: '0755', uid: 0, gid: 0
      },
      {
        path: '/usr/bin/openburnbar-linux-desktop', type: 'file', sha256: 'c'.repeat(64),
        size: 1, mode: '0755', uid: 0, gid: 0
      },
      {
        path: '/usr/share/openburnbar/attestation/release-ed25519.pub.pem', type: 'file',
        sha256: 'd'.repeat(64), size: 1, mode: '0644', uid: 0, gid: 0
      }
    ]
  });
  const bytes = Buffer.from(`${JSON.stringify(manifest)}\n`);
  assert.throws(() => validateAggregateInstalledManifest(bytes, {
    architecture: 'x86_64', format: 'deb', version: '1.2.3', commit: COMMIT
  }), /identity does not match/u);
});
