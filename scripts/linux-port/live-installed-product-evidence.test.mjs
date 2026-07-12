import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  captureLiveRuntimeCapabilities,
  LIVE_DESKTOP_BINARY_PATH,
  verifyLiveInstalledProduct
} from './lib/live-installed-product-evidence.mjs';

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]));
  }
  return value;
}

function canonicalJson(value) {
  return Buffer.from(`${JSON.stringify(canonicalize(value))}\n`, 'utf8');
}

function fileRoot(files) {
  const lines = files.map((file) => file.type === 'file'
    ? `${file.path}\0file\0${file.sha256}\0${file.size}\0${file.mode}\0${file.uid}\0${file.gid}`
    : `${file.path}\0symlink\0${file.target}\0${file.mode}\0${file.uid}\0${file.gid}`)
    .sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)));
  return sha256(Buffer.from(lines.join('\n'), 'utf8'));
}

function writeInstalled(root, absolutePath, contents, mode = 0o755) {
  const target = path.join(root, absolutePath.slice(1));
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, contents, { mode });
  fs.chmodSync(target, mode);
  return target;
}

function createFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-live-install-'));
  const daemonBytes = Buffer.from('daemon-binary\n');
  const desktopBytes = Buffer.from('desktop-binary\n');
  writeInstalled(root, '/usr/bin/openburnbar-daemon', daemonBytes);
  writeInstalled(root, '/usr/bin/openburnbar-linux-desktop', desktopBytes);
  const linkPath = path.join(root, 'usr/bin/openburnbar');
  fs.symlinkSync('openburnbar-linux-desktop', linkPath);
  const files = [
    {
      path: '/usr/bin/openburnbar',
      type: 'symlink',
      target: 'openburnbar-linux-desktop',
      mode: (fs.lstatSync(linkPath).mode & 0o7777).toString(8).padStart(4, '0'),
      uid: 0,
      gid: 0
    },
    {
      path: '/usr/bin/openburnbar-daemon',
      type: 'file',
      sha256: sha256(daemonBytes),
      size: daemonBytes.length,
      mode: '0755',
      uid: 0,
      gid: 0
    },
    {
      path: '/usr/bin/openburnbar-linux-desktop',
      type: 'file',
      sha256: sha256(desktopBytes),
      size: desktopBytes.length,
      mode: '0755',
      uid: 0,
      gid: 0
    }
  ].sort((left, right) => Buffer.compare(Buffer.from(left.path), Buffer.from(right.path)));
  const manifest = {
    schemaVersion: 1,
    packageVersion: '1.2.3',
    packageFormat: 'deb',
    packageName: 'open-burn-bar',
    policyId: 'openburnbar-linux-signed-package-inventory-v1',
    installedFilesRootSha256: fileRoot(files),
    authorizedClients: [{
      role: 'daemon',
      path: '/usr/bin/openburnbar-daemon',
      sha256: sha256(daemonBytes),
      ownerUid: 0,
      ownerGid: 0,
      mode: 0o755
    }],
    files
  };
  const manifestBytes = canonicalJson(manifest);
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  writeInstalled(root, '/usr/share/openburnbar/attestation/installed-manifest.json', manifestBytes, 0o644);
  const signatureBytes = crypto.sign(null, manifestBytes, privateKey);
  writeInstalled(
    root,
    '/usr/share/openburnbar/attestation/installed-manifest.json.sig',
    signatureBytes,
    0o644
  );
  writeInstalled(
    root,
    '/usr/share/openburnbar/attestation/release-ed25519.pub.pem',
    publicKey.export({ type: 'spki', format: 'pem' }),
    0o644
  );
  return { root, manifest, manifestBytes, signatureBytes };
}

function ownedPaths(fixture, extra = []) {
  return [
    ...fixture.manifest.files.map((entry) => entry.path),
    '/usr/share/openburnbar/attestation/installed-manifest.json',
    '/usr/share/openburnbar/attestation/installed-manifest.json.sig',
    ...extra
  ];
}

test('live installed verification binds exact manifest bytes, signature, metadata, and inventory root', (t) => {
  const fixture = createFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  const result = verifyLiveInstalledProduct({
    installedManifest: fixture.manifest,
    expectedManifestBytes: fixture.manifestBytes,
    expectedSignatureBytes: fixture.signatureBytes,
    installedRoot: fixture.root,
    ownership: { uid: 0, gid: 0 },
    packageOwnedPaths: ownedPaths(fixture)
  });
  assert.equal(result.verification.passed, true);
  assert.equal(result.verification.liveManifestSha256, sha256(fixture.manifestBytes));
  assert.equal(result.verification.installedFilesRootSha256, fixture.manifest.installedFilesRootSha256);
  assert.equal(result.verification.installedFileCount, fixture.manifest.files.length);
  assert.equal(result.verification.packageOwnedPathCount, fixture.manifest.files.length + 2);
});

test('live package ownership is queried from the native manager and rejects an extra installed file', (t) => {
  const fixture = createFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  writeInstalled(fixture.root, '/usr/bin/openburnbar-extra', 'extra\n');
  const calls = [];
  assert.throws(() => verifyLiveInstalledProduct({
    installedManifest: fixture.manifest,
    expectedManifestBytes: fixture.manifestBytes,
    installedRoot: fixture.root,
    ownership: { uid: 0, gid: 0 },
    packageListRunner: (command, args) => {
      calls.push({ command, args });
      return {
        status: 0,
        stdout: `${ownedPaths(fixture, ['/usr/bin/openburnbar-extra']).join('\n')}\n`,
        stderr: ''
      };
    }
  }), /extra=\/usr\/bin\/openburnbar-extra/u);
  assert.deepEqual(calls, [{ command: 'dpkg-query', args: ['-L', 'open-burn-bar'] }]);
});

test('Arch ownership proof queries the exact pacman package path set', (t) => {
  const fixture = createFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  fixture.manifest.packageFormat = 'arch';
  fixture.manifest.packageName = 'openburnbar';
  const calls = [];
  verifyLiveInstalledProduct({
    installedManifest: fixture.manifest,
    expectedManifestBytes: fixture.manifestBytes,
    installedRoot: fixture.root,
    ownership: { uid: 0, gid: 0 },
    packageListRunner: (command, args) => {
      calls.push({ command, args });
      return { status: 0, stdout: `${ownedPaths(fixture).join('\n')}\n`, stderr: '' };
    }
  });
  assert.deepEqual(calls, [{ command: 'pacman', args: ['-Qlq', 'openburnbar'] }]);
});

test('live package ownership rejects non-canonical and escaping manager output before lookup', async (t) => {
  for (const installedPath of ['/usr/../etc/passwd', 'usr/bin/openburnbar-daemon']) {
    await t.test(installedPath, () => {
      const fixture = createFixture();
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
      assert.throws(() => verifyLiveInstalledProduct({
        installedManifest: fixture.manifest,
        expectedManifestBytes: fixture.manifestBytes,
        expectedSignatureBytes: fixture.signatureBytes,
        installedRoot: fixture.root,
        ownership: { uid: 0, gid: 0 },
        packageListRunner: () => ({ status: 0, stdout: `${installedPath}\n`, stderr: '' })
      }), /non-canonical absolute owned path/u);
    });
  }
});

test('live installed verification rejects candidate, signature, payload, root, and symlink drift', async (t) => {
  for (const [name, mutate, pattern] of [
    ['candidate bytes', (fixture) => { fixture.manifestBytes = Buffer.from('{}\n'); }, /manifest bytes do not match/u],
    ['signature', (fixture) => {
      fs.writeFileSync(path.join(fixture.root, 'usr/share/openburnbar/attestation/installed-manifest.json.sig'), Buffer.alloc(64));
    }, /signature verification failed/u],
    ['file content', (fixture) => {
      fs.writeFileSync(path.join(fixture.root, 'usr/bin/openburnbar-daemon'), 'changed\n');
    }, /signed inventory/u],
    ['file mode', (fixture) => {
      fs.chmodSync(path.join(fixture.root, 'usr/bin/openburnbar-daemon'), 0o700);
    }, /signed inventory/u],
    ['inventory root', (fixture) => { fixture.manifest.installedFilesRootSha256 = '0'.repeat(64); }, /inventory root/u],
    ['symlink target', (fixture) => {
      const link = path.join(fixture.root, 'usr/bin/openburnbar');
      fs.unlinkSync(link);
      fs.symlinkSync('openburnbar-daemon', link);
    }, /signed inventory/u],
    ['parent symlink', (fixture) => {
      const bin = path.join(fixture.root, 'usr/bin');
      const real = path.join(fixture.root, 'usr/bin-real');
      fs.renameSync(bin, real);
      fs.symlinkSync('bin-real', bin);
    }, /traverses a non-directory or symlink/u]
  ]) {
    await t.test(name, () => {
      const fixture = createFixture();
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
      mutate(fixture);
      assert.throws(() => verifyLiveInstalledProduct({
        installedManifest: fixture.manifest,
        expectedManifestBytes: fixture.manifestBytes,
        installedRoot: fixture.root,
        ownership: { uid: 0, gid: 0 },
        packageOwnedPaths: ownedPaths(fixture)
      }), pattern);
    });
  }
});

test('live installed verification rejects non-root installed ownership', (t) => {
  const fixture = createFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  assert.throws(() => verifyLiveInstalledProduct({
    installedManifest: fixture.manifest,
    expectedManifestBytes: fixture.manifestBytes,
    installedRoot: fixture.root,
    ownership: { uid: 1, gid: 0 },
    packageOwnedPaths: ownedPaths(fixture)
  }), /root-owned|signed inventory/u);
});

test('live installed verification rejects unsafe parent ownership and modes', async (t) => {
  for (const [name, metadata, pattern] of [
    ['non-root owner', { uid: 1000, gid: 0, mode: 0o755 }, /not root-owned/u],
    ['group writable', { uid: 0, gid: 0, mode: 0o775 }, /group\/world-writable/u],
    ['world writable', { uid: 0, gid: 0, mode: 0o757 }, /group\/world-writable/u]
  ]) {
    await t.test(name, () => {
      const fixture = createFixture();
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
      assert.throws(() => verifyLiveInstalledProduct({
        installedManifest: fixture.manifest,
        expectedManifestBytes: fixture.manifestBytes,
        expectedSignatureBytes: fixture.signatureBytes,
        installedRoot: fixture.root,
        ownership: { uid: 0, gid: 0 },
        directoryMetadata: { '/usr/share/openburnbar': metadata },
        packageOwnedPaths: ownedPaths(fixture)
      }), pattern);
    });
  }
});

test('live installed verification rejects a release-closure signature mismatch', (t) => {
  const fixture = createFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  assert.throws(() => verifyLiveInstalledProduct({
    installedManifest: fixture.manifest,
    expectedManifestBytes: fixture.manifestBytes,
    expectedSignatureBytes: Buffer.alloc(64, 7),
    installedRoot: fixture.root,
    ownership: { uid: 0, gid: 0 },
    packageOwnedPaths: ownedPaths(fixture)
  }), /signature bytes do not match/u);
});

test('live installed verification does not overclaim TPM or IMA policy', (t) => {
  const fixture = createFixture();
  t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
  fixture.manifest.policyId = 'openburnbar-linux-tpm2-ima-v1';
  assert.throws(() => verifyLiveInstalledProduct({
    installedManifest: fixture.manifest,
    expectedManifestBytes: fixture.manifestBytes,
    expectedSignatureBytes: fixture.signatureBytes,
    installedRoot: fixture.root,
    ownership: { uid: 0, gid: 0 },
    packageOwnedPaths: ownedPaths(fixture)
  }), /signed-package-inventory-v1/u);
});

test('live installed verification rejects extra or missing package-owned files', async (t) => {
  for (const [name, paths, pattern] of [
    ['extra', (fixture) => ownedPaths(fixture, ['/usr/bin/openburnbar-extra']), /extra=\/usr\/bin\/openburnbar-extra/u],
    ['missing', (fixture) => ownedPaths(fixture).filter((entry) => entry !== '/usr/bin/openburnbar-linux-desktop'), /missing=\/usr\/bin\/openburnbar-linux-desktop/u]
  ]) {
    await t.test(name, () => {
      const fixture = createFixture();
      t.after(() => fs.rmSync(fixture.root, { recursive: true, force: true }));
      assert.throws(() => verifyLiveInstalledProduct({
        installedManifest: fixture.manifest,
        expectedManifestBytes: fixture.manifestBytes,
        installedRoot: fixture.root,
        ownership: { uid: 0, gid: 0 },
        packageOwnedPaths: paths(fixture)
      }), pattern);
    });
  }
});

test('runtime capture invokes only the installed one-shot shell probe and preserves its JSON bytes', () => {
  const calls = [];
  const result = captureLiveRuntimeCapabilities({ runner: (command, args, options) => {
    calls.push({ command, args, options });
    return { status: 0, stdout: '{"schemaVersion":1}\n', stderr: '' };
  } });
  assert.deepEqual(result, { bytes: Buffer.from('{"schemaVersion":1}\n') });
  assert.equal(calls[0].command, LIVE_DESKTOP_BINARY_PATH);
  assert.deepEqual(calls[0].args, ['--runtime-capabilities']);
});

test('runtime capture rejects process failure, empty output, and non-JSON output', () => {
  assert.throws(
    () => captureLiveRuntimeCapabilities({ runner: () => ({ status: 1, stdout: '', stderr: 'failed' }) }),
    /failed/u
  );
  assert.throws(
    () => captureLiveRuntimeCapabilities({ runner: () => ({ status: 0, stdout: '', stderr: '' }) }),
    /no JSON/u
  );
  assert.throws(
    () => captureLiveRuntimeCapabilities({ runner: () => ({ status: 0, stdout: 'nope', stderr: '' }) }),
    /not valid JSON/u
  );
});
