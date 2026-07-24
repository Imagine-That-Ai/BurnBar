import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  linuxAppImagePeerExecutableRelativePath,
  linuxReleasePublicKeySpkiSha256,
  signLinuxAppImagePeerManifest,
  validateLinuxAppImagePeerManifest,
  verifyLinuxAppImagePeerManifest,
  writeSignedLinuxAppImagePeerManifest
} from './lib/linux-appimage-peer-manifest.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-peer-manifest-'));
  const executable = path.join(root, linuxAppImagePeerExecutableRelativePath);
  fs.mkdirSync(path.dirname(executable), { recursive: true });
  fs.writeFileSync(executable, 'official OpenBurnBar GUI fixture', { mode: 0o755 });
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });
  const trustedKeyId = crypto
    .createHash('sha256')
    .update(publicKey.export({ type: 'spki', format: 'der' }))
    .digest('hex');
  return { root, executable, privateKeyPem, publicKeyPem, trustedKeyId };
}

test('compiled manifest key id matches the repository Linux release public key', () => {
  const publicKey = crypto.createPublicKey(
    fs.readFileSync(path.join(repoRoot, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'))
  );
  const actual = crypto.createHash('sha256')
    .update(publicKey.export({ type: 'spki', format: 'der' }))
    .digest('hex');
  assert.equal(actual, linuxReleasePublicKeySpkiSha256);
});

test('signed AppImage peer manifest binds exact identity, basename, path, and executable digest', () => {
  const value = fixture();
  try {
    const signed = signLinuxAppImagePeerManifest(value);
    const verified = verifyLinuxAppImagePeerManifest({
      ...value,
      manifestBytes: signed.bytes,
      signature: signed.signature
    });
    assert.equal(verified.identity, 'com.openburnbar.app');
    assert.equal(verified.executableRelativePath, 'usr/bin/openburnbar-linux-desktop');
    assert.equal(verified.executableBasename, 'openburnbar-linux-desktop');
    assert.match(verified.executableSHA256, /^[0-9a-f]{64}$/u);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('manifest verification rejects tampered bytes and a changed GUI executable', () => {
  const value = fixture();
  try {
    const signed = signLinuxAppImagePeerManifest(value);
    const tampered = Buffer.from(signed.bytes);
    tampered[tampered.indexOf(Buffer.from('com.openburnbar.app'))] ^= 1;
    assert.throws(
      () => verifyLinuxAppImagePeerManifest({ ...value, manifestBytes: tampered, signature: signed.signature }),
      /identity is invalid|signature is invalid/
    );

    fs.appendFileSync(value.executable, 'tampered');
    assert.throws(
      () => verifyLinuxAppImagePeerManifest({ ...value, manifestBytes: signed.bytes, signature: signed.signature }),
      /does not match the GUI executable/
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('manifest verification rejects an unknown signing key', () => {
  const value = fixture();
  const other = fixture();
  try {
    const signed = signLinuxAppImagePeerManifest(value);
    assert.throws(
      () => verifyLinuxAppImagePeerManifest({
        ...value,
        publicKeyPem: other.publicKeyPem,
        manifestBytes: signed.bytes,
        signature: signed.signature
      }),
      /key is not trusted/
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
    fs.rmSync(other.root, { recursive: true, force: true });
  }
});

test('manifest creation rejects a symlinked GUI executable', () => {
  const value = fixture();
  try {
    const target = `${value.executable}.target`;
    fs.renameSync(value.executable, target);
    fs.symlinkSync(path.basename(target), value.executable);
    assert.throws(() => signLinuxAppImagePeerManifest(value), /not a regular file/);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('manifest verification rejects oversized input before parsing', () => {
  const value = fixture();
  try {
    assert.throws(
      () => verifyLinuxAppImagePeerManifest({
        ...value,
        manifestBytes: Buffer.alloc(4097, 0x20),
        signature: Buffer.alloc(64)
      }),
      /between 1 and 4096 bytes/
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('manifest verification rejects a valid signature over non-canonical JSON bytes', () => {
  const value = fixture();
  try {
    const manifest = signLinuxAppImagePeerManifest(value).manifest;
    const nonCanonical = Buffer.from(JSON.stringify(manifest), 'utf8');
    const privateKey = crypto.createPrivateKey(value.privateKeyPem);
    const signature = crypto.sign(null, nonCanonical, privateKey);
    assert.throws(
      () => verifyLinuxAppImagePeerManifest({
        ...value,
        manifestBytes: nonCanonical,
        signature
      }),
      /bytes are not canonical/
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('manifest schema rejects path traversal, basename drift, and extra fields', () => {
  const value = fixture();
  try {
    const manifest = signLinuxAppImagePeerManifest(value).manifest;
    assert.throws(
      () => validateLinuxAppImagePeerManifest(
        { ...manifest, executableRelativePath: '../../usr/bin/openburnbar-linux-desktop' },
        { trustedKeyId: value.trustedKeyId }
      ),
      /executable path is invalid/
    );
    assert.throws(
      () => validateLinuxAppImagePeerManifest(
        { ...manifest, executableBasename: 'OpenBurnBar' },
        { trustedKeyId: value.trustedKeyId }
      ),
      /executable basename is invalid/
    );
    assert.throws(
      () => validateLinuxAppImagePeerManifest(
        { ...manifest, unexpected: true },
        { trustedKeyId: value.trustedKeyId }
      ),
      /fields do not exactly match schema/
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('writer creates bounded regular manifest sidecars with deterministic modes', () => {
  const value = fixture();
  try {
    const output = writeSignedLinuxAppImagePeerManifest({ appDir: value.root, ...value });
    for (const file of [output.manifestFile, output.signatureFile]) {
      const stat = fs.lstatSync(file);
      assert.equal(stat.isFile(), true);
      assert.equal(stat.isSymbolicLink(), false);
      assert.equal(stat.mode & 0o777, 0o644);
    }
    assert.ok(fs.statSync(output.manifestFile).size <= 4096);
    assert.equal(fs.statSync(output.signatureFile).size, 64);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test('writer refuses pre-existing and symlinked manifest output paths', () => {
  const value = fixture();
  try {
    const outputDirectory = path.join(value.root, 'usr/share/openburnbar');
    fs.mkdirSync(outputDirectory, { recursive: true });
    const outside = path.join(value.root, 'outside-manifest');
    fs.writeFileSync(outside, 'outside');
    fs.symlinkSync(outside, path.join(outputDirectory, 'appimage-peer-manifest.json'));
    assert.throws(
      () => writeSignedLinuxAppImagePeerManifest({ appDir: value.root, ...value }),
      /output already exists/
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
