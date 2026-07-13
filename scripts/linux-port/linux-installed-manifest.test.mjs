import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  canonicalJsonBytes,
  collectInstalledFiles,
  createInstalledManifest,
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH,
  signInstalledManifest,
  verifyInstalledManifestTree
} from './lib/linux-installed-manifest.mjs';
import { withoutLinuxReleasePrivateKey } from './lib/linux-signing-environment.mjs';
import {
  assertSafeArchiveMemberNames,
  extractPreflightedArchiveBytes,
  verifySignedNativePackage
} from './lib/linux-native-package.mjs';

function write(root, installedPath, bytes, mode) {
  const destination = path.join(root, installedPath.slice(1));
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, bytes, { mode });
  fs.chmodSync(destination, mode);
}

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-installed-manifest-'));
  write(root, '/usr/bin/openburnbar-daemon', 'daemon\n', 0o755);
  write(root, '/usr/bin/openburnbar-linux-desktop', 'desktop\n', 0o755);
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });
  write(root, '/usr/share/openburnbar/attestation/release-ed25519.pub.pem', publicKeyPem, 0o644);
  write(root, INSTALLED_MANIFEST_PATH, '{}\n', 0o644);
  write(root, INSTALLED_MANIFEST_SIGNATURE_PATH, Buffer.alloc(64), 0o644);
  const metadataProvider = () => ({ uid: 0, gid: 0 });
  const files = collectInstalledFiles(root, { metadataProvider });
  const manifest = createInstalledManifest({
    files,
    packageVersion: '1.2.3',
    gitCommit: 'a'.repeat(40),
    packageArchitecture: 'x86_64',
    packageFormat: 'deb',
    firebaseAppId: '1:123456789012:web:abcdef1234567890'
  });
  const manifestBytes = canonicalJsonBytes(manifest);
  const signatureBytes = signInstalledManifest(
    manifestBytes,
    privateKey.export({ type: 'pkcs8', format: 'pem' }),
    publicKeyPem
  );
  write(root, INSTALLED_MANIFEST_PATH, manifestBytes, 0o644);
  write(root, INSTALLED_MANIFEST_SIGNATURE_PATH, signatureBytes, 0o644);
  return {
    root,
    installedRoot: root,
    manifest,
    manifestBytes,
    signatureBytes,
    publicKeyPem,
    metadataProvider
  };
}

test('signed installed manifest binds exact inventory and authorized daemon', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const verified = verifyInstalledManifestTree(value);
  assert.equal(verified.installedFilesRootSha256, value.manifest.installedFilesRootSha256);
  assert.equal(verified.authorizedClients[0].sha256, value.manifest.files.find((row) => row.path.endsWith('daemon')).sha256);
});

test('Arch installed manifests bind the pacman package identity', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const manifest = createInstalledManifest({
    files: value.manifest.files,
    packageVersion: '1.2.3',
    gitCommit: 'a'.repeat(40),
    packageArchitecture: 'x86_64',
    packageFormat: 'arch',
    firebaseAppId: '1:123456789012:web:abcdef1234567890'
  });
  assert.equal(manifest.packageFormat, 'arch');
  assert.equal(manifest.packageName, 'openburnbar');
});

test('inventory generation is byte-deterministic and excludes only manifest self-subjects', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const first = collectInstalledFiles(value.root, { metadataProvider: value.metadataProvider });
  const second = collectInstalledFiles(value.root, { metadataProvider: value.metadataProvider });
  assert.deepEqual(first, second);
  assert.ok(first.some((row) => row.path.endsWith('release-ed25519.pub.pem')));
  assert.ok(!first.some((row) => row.path === INSTALLED_MANIFEST_PATH));
  assert.ok(!first.some((row) => row.path === INSTALLED_MANIFEST_SIGNATURE_PATH));
});

for (const [name, mutate, pattern] of [
  ['file bytes', (value) => write(value.root, '/usr/bin/openburnbar-daemon', 'changed\n', 0o755), /inventory differs/u],
  ['extra file', (value) => write(value.root, '/usr/bin/openburnbar-extra', 'extra\n', 0o755), /inventory differs/u],
  ['signature', (value) => { value.signatureBytes[0] ^= 0xff; }, /signature verification failed/u],
  ['manifest identity', (value) => {
    const document = JSON.parse(value.manifestBytes);
    document.gitCommit = 'b'.repeat(40);
    value.manifestBytes = canonicalJsonBytes(document);
  }, /signature verification failed/u],
  ['trusted directory mode', (value) => {
    fs.chmodSync(path.join(value.root, 'usr/bin'), 0o777);
  }, /directory is not root-owned and write-safe/u],
  ['embedded release key', (value) => {
    const other = crypto.generateKeyPairSync('ed25519').publicKey.export({ type: 'spki', format: 'pem' });
    write(value.root, '/usr/share/openburnbar/attestation/release-ed25519.pub.pem', other, 0o644);
  }, /does not match the pinned signing key/u]
]) {
  test(`verification rejects mutated ${name}`, (t) => {
    const value = fixture();
    t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
    mutate(value);
    assert.throws(() => verifyInstalledManifestTree(value), pattern);
  });
}

test('inventory rejects non-root archive ownership instead of normalizing it', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  assert.throws(
    () => collectInstalledFiles(value.root, {
      metadataProvider: ({ installedPath }) => installedPath === '/usr/bin/openburnbar-daemon'
        ? { uid: 501, gid: 20 }
        : { uid: 0, gid: 0 }
    }),
    /not root-owned/u
  );
});

test('inventory accepts only non-dangling relative symlinks contained by packaged /usr', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const native = path.join(value.root, 'usr/lib/openburnbar/native');
  fs.mkdirSync(native, { recursive: true });
  write(value.root, '/usr/lib/openburnbar/native/libsafe.so.1', 'library\n', 0o644);
  fs.symlinkSync('libsafe.so.1', path.join(native, 'libsafe.so'));
  assert.ok(collectInstalledFiles(value.root, { metadataProvider: value.metadataProvider })
    .some((entry) => entry.path.endsWith('/libsafe.so') && entry.target === 'libsafe.so.1'));

  fs.symlinkSync('/tmp/libescape.so', path.join(native, 'libescape.so'));
  assert.throws(
    () => collectInstalledFiles(value.root, { metadataProvider: value.metadataProvider }),
    /target must be relative/u
  );
  fs.rmSync(path.join(native, 'libescape.so'));
  fs.symlinkSync('missing.so', path.join(native, 'libdangling.so'));
  assert.throws(
    () => collectInstalledFiles(value.root, { metadataProvider: value.metadataProvider }),
    /is dangling/u
  );
});

test('manifest creation rejects a private key that does not match the pinned public key', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const other = crypto.generateKeyPairSync('ed25519').privateKey.export({ type: 'pkcs8', format: 'pem' });
  assert.throws(
    () => signInstalledManifest(value.manifestBytes, other, value.publicKeyPem),
    /does not match/u
  );
});

test('unsigned build subprocess environment never receives the release private key', () => {
  const source = {
    PATH: '/usr/bin',
    OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM: 'private-key-material'
  };
  assert.deepEqual(withoutLinuxReleasePrivateKey(source), { PATH: '/usr/bin' });
  assert.equal(source.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM, 'private-key-material');
});

test('native package closure re-extracts and rejects artifact/sidecar swaps', (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const copyFixture = (_format, _artifact, destination) => {
    for (const entry of fs.readdirSync(value.root)) {
      fs.cpSync(path.join(value.root, entry), path.join(destination, entry), {
        recursive: true,
        dereference: false
      });
    }
  };
  const verified = verifySignedNativePackage({
    format: 'deb',
    artifact: '/synthetic/openburnbar.deb',
    manifestBytes: value.manifestBytes,
    signatureBytes: value.signatureBytes,
    publicKeyPem: value.publicKeyPem,
    metadataProvider: value.metadataProvider,
    extractor: copyFixture,
    metadataInspector: () => ({
      packageName: 'open-burn-bar',
      packageVersion: '1.2.3',
      packageArchitecture: 'x86_64'
    })
  });
  assert.equal(verified.gitCommit, 'a'.repeat(40));

  assert.throws(() => verifySignedNativePackage({
    format: 'deb',
    artifact: '/synthetic/swapped.deb',
    manifestBytes: value.manifestBytes,
    signatureBytes: value.signatureBytes,
    publicKeyPem: value.publicKeyPem,
    metadataProvider: value.metadataProvider,
    extractor: (...args) => {
      copyFixture(...args);
      write(args[2], INSTALLED_MANIFEST_PATH, '{}\n', 0o644);
    },
    metadataInspector: () => ({
      packageName: 'open-burn-bar',
      packageVersion: '1.2.3',
      packageArchitecture: 'x86_64'
    })
  }), /does not embed its recorded installed attestation bytes/u);

  assert.throws(() => verifySignedNativePackage({
    format: 'deb',
    artifact: '/synthetic/wrong-version.deb',
    manifestBytes: value.manifestBytes,
    signatureBytes: value.signatureBytes,
    publicKeyPem: value.publicKeyPem,
    metadataProvider: value.metadataProvider,
    extractor: copyFixture,
    metadataInspector: () => ({
      packageName: 'open-burn-bar',
      packageVersion: '9.9.9',
      packageArchitecture: 'x86_64'
    })
  }), /manager metadata does not match/u);
});

test('native package archive preflight rejects traversal and contains symlink pivots', (t) => {
  assert.throws(
    () => assertSafeArchiveMemberNames('./usr/bin/openburnbar\n../outside/payload\n'),
    /traverses its extraction root/u
  );
  assert.throws(
    () => assertSafeArchiveMemberNames('./usr/bin/openburnbar\n./usr/bin/openburnbar\n'),
    /duplicate member/u
  );

  const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-archive-sandbox-'));
  const destination = path.join(sandbox, 'root');
  const escaped = path.join(sandbox, 'escaped');
  fs.mkdirSync(escaped);
  t.after(() => fs.rmSync(sandbox, { recursive: true, force: true }));
  const archive = tarArchive([
    { name: './usr/', type: '5', mode: 0o755 },
    { name: './usr/pivot', type: '2', mode: 0o777, link: '../../escaped' },
    { name: './usr/pivot/payload', type: '0', mode: 0o644, bytes: Buffer.from('escape-attempt\n') }
  ]);
  assert.throws(
    () => extractPreflightedArchiveBytes(archive, destination),
    /bsdtar/u
  );
  assert.equal(fs.existsSync(path.join(escaped, 'payload')), false);

  const deviceArchive = tarArchive([
    { name: './usr/', type: '5', mode: 0o755 },
    { name: './usr/device', type: '3', mode: 0o644 }
  ]);
  assert.throws(
    () => extractPreflightedArchiveBytes(deviceArchive, destination),
    /unsupported or ambiguous member types/u
  );
});

function tarArchive(entries) {
  const blocks = [];
  for (const entry of entries) {
    const bytes = entry.bytes ?? Buffer.alloc(0);
    const header = Buffer.alloc(512);
    writeTarString(header, 0, 100, entry.name);
    writeTarOctal(header, 100, 8, entry.mode);
    writeTarOctal(header, 108, 8, 0);
    writeTarOctal(header, 116, 8, 0);
    writeTarOctal(header, 124, 12, bytes.length);
    writeTarOctal(header, 136, 12, 0);
    header.fill(0x20, 148, 156);
    header[156] = (entry.type ?? '0').charCodeAt(0);
    writeTarString(header, 157, 100, entry.link ?? '');
    writeTarString(header, 257, 6, 'ustar');
    writeTarString(header, 263, 2, '00');
    writeTarString(header, 265, 32, 'root');
    writeTarString(header, 297, 32, 'root');
    const checksum = header.reduce((sum, value) => sum + value, 0);
    const checksumBytes = Buffer.from(checksum.toString(8).padStart(6, '0'));
    checksumBytes.copy(header, 148);
    header[154] = 0;
    header[155] = 0x20;
    blocks.push(header, bytes, Buffer.alloc((512 - (bytes.length % 512)) % 512));
  }
  blocks.push(Buffer.alloc(1024));
  return Buffer.concat(blocks);
}

function writeTarString(buffer, offset, length, value) {
  Buffer.from(value, 'utf8').copy(buffer, offset, 0, length);
}

function writeTarOctal(buffer, offset, length, value) {
  writeTarString(buffer, offset, length, `${value.toString(8).padStart(length - 1, '0')}\0`);
}
