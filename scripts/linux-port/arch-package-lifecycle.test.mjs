import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  extendSigningIndex,
  renderReleasePkgbuild
} from './build-signed-arch-package.mjs';
import {
  canonicalJsonBytes,
  createInstalledManifest,
  sha256Bytes
} from './lib/linux-installed-manifest.mjs';
import {
  ARCH_PACKAGE_ROOT_METADATA_ALLOWLIST,
  archPackageRemovalCandidates,
  assertSafeArchiveMemberNames,
  extractPreflightedArchiveBytes,
  inspectArchPackageDependencies,
  inspectNativePackageMetadata,
  remainingFilesystemEntriesNoFollow
} from './lib/linux-native-package.mjs';
import {
  copyRecordedFile,
  materializeArchReleaseMetadata
} from './lib/linux-arch-pkgbuild.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

const checksumSlots = [
  'APPIMAGE_X86_64', 'DAEMON_X86_64', 'INSTALLED_MANIFEST_X86_64',
  'INSTALLED_MANIFEST_SIGNATURE_X86_64', 'APPIMAGE_AARCH64', 'DAEMON_AARCH64',
  'INSTALLED_MANIFEST_AARCH64', 'INSTALLED_MANIFEST_SIGNATURE_AARCH64',
  'DESKTOP', 'SAFE_MODE_DESKTOP', 'SERVICE', 'LAUNCH',
  'DESKTOP_LAUNCHER', 'ICON',
  'COMPUTER_USE_POLKIT_POLICY', 'PLAYWRIGHT_BRIDGE', 'BROWSER_RUNTIME_PROBE',
  'BROWSER_RUNTIME_REQUIREMENTS', 'RELEASE_PUBLIC_KEY'
];

test('release PKGBUILD rendering fills every checksum slot without bypasses', () => {
  const template = fs.readFileSync(new URL('../../packaging/linux/aur/PKGBUILD.in', import.meta.url), 'utf8');
  const checksums = Object.fromEntries(checksumSlots.map((slot, index) => [
    slot,
    index.toString(16).padStart(64, '0')
  ]));
  const rendered = renderReleasePkgbuild(template, { version: '4.5.6', checksums });
  assert.match(rendered, /^pkgver=4\.5\.6$/mu);
  assert.doesNotMatch(rendered, /REPLACE_WITH_/u);
  assert.doesNotMatch(rendered, /\bSKIP\b/u);
  assert.match(rendered, /installed-manifest\.ed25519/u);
  assert.match(rendered, /release-ed25519\.pub\.pem/u);
  assert.match(rendered, /squashfs-root\/AppRun/u);
  assert.match(rendered, /usr\/lib\/openburnbar\/appdir/u);
  assert.match(rendered, /dev\.openburnbar\.OpenBurnBar\.png/u);
});

test('Arch prepare atomically extends the signing transaction with its fourth subject', (t) => {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-arch-index-'));
  t.after(() => fs.rmSync(stateDir, { recursive: true, force: true }));
  const requestsDir = path.join(stateDir, 'requests');
  fs.mkdirSync(requestsDir);
  const version = '1.2.3';
  const gitCommit = 'a'.repeat(40);
  const architecture = 'x86_64';
  const requests = [
    [`deb-${architecture}-installed-manifest`, 'installed-manifest'],
    [`rpm-${architecture}-installed-manifest`, 'installed-manifest'],
    [`appimage-${architecture}-peer-manifest`, 'appimage-peer-manifest']
  ].map(([id, kind]) => {
    const file = path.join(requestsDir, `${id}.json`);
    const bytes = Buffer.from(`{"id":"${id}"}\n`);
    fs.writeFileSync(file, bytes);
    return {
      id,
      kind,
      file: path.relative(stateDir, file).split(path.sep).join('/'),
      sha256: sha256Bytes(bytes),
      size: bytes.length
    };
  });
  const index = { schemaVersion: 1, product: 'OpenBurnBar', version, gitCommit, architecture, requests };
  fs.writeFileSync(path.join(stateDir, 'signing-request.json'), canonicalJsonBytes(index));
  const files = [
    record('/usr/bin/openburnbar-daemon', 'daemon', '0755'),
    record('/usr/bin/openburnbar-linux-desktop', 'desktop', '0755'),
    record('/usr/share/openburnbar/attestation/release-ed25519.pub.pem', 'key', '0644')
  ];
  const manifestBytes = canonicalJsonBytes(createInstalledManifest({
    files,
    packageVersion: version,
    gitCommit,
    packageArchitecture: architecture,
    packageFormat: 'arch',
    firebaseAppId: '1:123456789012:web:abcdef1234567890'
  }));
  const request = extendSigningIndex({ stateDir, version, gitCommit, architecture, manifestBytes });
  assert.equal(request.id, `arch-${architecture}-installed-manifest`);
  const extended = JSON.parse(fs.readFileSync(path.join(stateDir, 'signing-request.json'), 'utf8'));
  assert.deepEqual(extended.requests.map((entry) => entry.id), [
    `deb-${architecture}-installed-manifest`,
    `rpm-${architecture}-installed-manifest`,
    `arch-${architecture}-installed-manifest`,
    `appimage-${architecture}-peer-manifest`
  ]);
  assert.equal(fs.readFileSync(path.join(stateDir, request.file)).equals(manifestBytes), true);
  assert.throws(
    () => extendSigningIndex({ stateDir, version, gitCommit, architecture, manifestBytes }),
    /does not match the release identity/u
  );
});

test('Arch manager metadata is read from the package .PKGINFO', {
  skip: commandAvailable('bsdtar') ? false : 'requires bsdtar'
}, (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-arch-metadata-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'payload/usr/bin'), { recursive: true });
  fs.writeFileSync(path.join(root, 'payload/.PKGINFO'), [
    'pkgname = openburnbar',
    'pkgver = 1.2.3-1',
    'arch = x86_64',
    'depend = gtk3',
    'depend = nodejs>=22',
    ''
  ].join('\n'));
  fs.writeFileSync(path.join(root, 'payload/usr/bin/openburnbar-daemon'), 'daemon\n');
  const artifact = path.join(root, 'openburnbar.pkg.tar');
  const result = spawnSync('bsdtar', ['-cf', artifact, '-C', path.join(root, 'payload'), '.'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(inspectNativePackageMetadata('arch', artifact), {
    packageName: 'openburnbar',
    packageVersion: '1.2.3',
    packageArchitecture: 'x86_64'
  });
  assert.deepEqual(inspectArchPackageDependencies(artifact), ['gtk3', 'nodejs>=22']);
});

test('Arch extraction preflight permits only known package metadata beside /usr', () => {
  assert.deepEqual(
    [...assertSafeArchiveMemberNames('.PKGINFO\n.BUILDINFO\n.MTREE\nusr/bin/openburnbar\n', {
      allowedRootMetadata: ARCH_PACKAGE_ROOT_METADATA_ALLOWLIST
    })],
    ['.PKGINFO', '.BUILDINFO', '.MTREE', 'usr/bin/openburnbar']
  );
  assert.throws(
    () => assertSafeArchiveMemberNames('.PKGINFO\netc/pacman.conf\n', {
      allowedRootMetadata: ARCH_PACKAGE_ROOT_METADATA_ALLOWLIST
    }),
    /outside \/usr/u
  );
  assert.throws(
    () => assertSafeArchiveMemberNames('.PKGINFO\n.INSTALL\nusr/bin/openburnbar\n', {
      allowedRootMetadata: ARCH_PACKAGE_ROOT_METADATA_ALLOWLIST
    }),
    /outside \/usr/u
  );
});

test('production Arch extraction rejects a real archive containing .INSTALL', {
  skip: commandAvailable('bsdtar') ? false : 'requires bsdtar'
}, (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-arch-malicious-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const payload = path.join(root, 'payload');
  fs.mkdirSync(path.join(payload, 'usr/bin'), { recursive: true });
  fs.writeFileSync(path.join(payload, '.PKGINFO'), 'pkgname = openburnbar\n');
  fs.writeFileSync(path.join(payload, '.INSTALL'), 'post_install() { id; }\n');
  fs.writeFileSync(path.join(payload, 'usr/bin/openburnbar'), 'binary\n');
  const archive = path.join(root, 'malicious.pkg.tar');
  const packed = spawnSync('bsdtar', ['-cf', archive, '-C', payload, '.'], { encoding: 'utf8' });
  assert.equal(packed.status, 0, packed.stderr);
  assert.throws(
    () => extractPreflightedArchiveBytes(fs.readFileSync(archive), path.join(root, 'out'), {
      allowedRootMetadata: ARCH_PACKAGE_ROOT_METADATA_ALLOWLIST,
      extractUsrOnly: true
    }),
    /outside \/usr/u
  );
  assert.equal(fs.existsSync(path.join(root, 'out')), false);
});

test('Arch uninstall candidates and no-follow checks include private dirs and dangling symlinks', (t) => {
  const metadata = new Map([
    ['/usr', 'directory'],
    ['/usr/lib/openburnbar', 'directory'],
    ['/usr/lib/openburnbar/native', 'directory'],
    ['/usr/bin/openburnbar', 'file'],
    ['/usr/lib/openburnbar/native/lib.so', 'symlink']
  ]);
  const stat = (file) => {
    const kind = metadata.get(file);
    if (!kind) throw Object.assign(new Error('missing'), { code: 'ENOENT' });
    return { isDirectory: () => kind === 'directory', isSymbolicLink: () => kind === 'symlink' };
  };
  const candidates = archPackageRemovalCandidates([...metadata.keys()].join('\n'), stat);
  assert.deepEqual(candidates, [
    '/usr/lib/openburnbar',
    '/usr/lib/openburnbar/native',
    '/usr/bin/openburnbar',
    '/usr/lib/openburnbar/native/lib.so'
  ]);
  metadata.delete('/usr/bin/openburnbar');
  assert.deepEqual(remainingFilesystemEntriesNoFollow(candidates, stat), [
    '/usr/lib/openburnbar',
    '/usr/lib/openburnbar/native',
    '/usr/lib/openburnbar/native/lib.so'
  ]);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-arch-remove-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const dangling = path.join(root, 'dangling');
  fs.symlinkSync('missing-target', dangling);
  assert.deepEqual(remainingFilesystemEntriesNoFollow([dangling, path.join(root, 'missing')]), [dangling]);
});

test('copyRecordedFile rejects source symlinks and symlinked ancestors', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-arch-copy-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'real'));
  const source = path.join(root, 'real/source');
  fs.writeFileSync(source, 'trusted\n');
  const sourceRecord = {
    file: 'link/source',
    sha256: sha256Bytes(fs.readFileSync(source)),
    size: fs.statSync(source).size
  };
  fs.symlinkSync('real', path.join(root, 'link'));
  assert.throws(
    () => copyRecordedFile(root, sourceRecord, path.join(root, 'copied')),
    /traverses a symlink/u
  );
  fs.unlinkSync(path.join(root, 'link'));
  fs.symlinkSync('real/source', path.join(root, 'link'));
  sourceRecord.file = 'link';
  assert.throws(
    () => copyRecordedFile(root, sourceRecord, path.join(root, 'copied')),
    /traverses a symlink/u
  );
  fs.unlinkSync(path.join(root, 'link'));
  sourceRecord.file = 'real/source';
  fs.symlinkSync('real', path.join(root, 'destination-link'));
  assert.throws(
    () => copyRecordedFile(root, sourceRecord, path.join(root, 'destination-link/copied')),
    /destination traverses a symlink/u
  );
  fs.symlinkSync('missing-target', path.join(root, 'destination'));
  assert.throws(
    () => copyRecordedFile(root, sourceRecord, path.join(root, 'destination')),
    /destination is a symlink/u
  );
});

test('release assembly renders a two-architecture PKGBUILD from published assets', (t) => {
  const root = fs.mkdtempSync(path.join(repoRoot, '.tmp-openburnbar-arch-release-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const artifacts = [];
  for (const architecture of ['x86_64', 'aarch64']) {
    for (const type of ['appimage', 'daemon', 'arch']) {
      const file = path.join(root, `${type}-${architecture}`);
      fs.writeFileSync(file, `${type}:${architecture}\n`);
      const artifact = fileRecord(file);
      artifact.type = type;
      artifact.architecture = architecture;
      if (type === 'arch') {
        const manifest = path.join(root, `${architecture}.installed-manifest.json`);
        const signature = path.join(root, `${architecture}.installed-manifest.json.sig`);
        fs.writeFileSync(manifest, `manifest:${architecture}\n`);
        fs.writeFileSync(signature, Buffer.alloc(64, architecture === 'x86_64' ? 1 : 2));
        artifact.installedManifest = fileRecord(manifest);
        artifact.installedManifestSignature = fileRecord(signature);
      }
      artifacts.push(artifact);
    }
  }
  const result = materializeArchReleaseMetadata({
    repoRoot,
    outDir: path.join(root, 'out'),
    version: '4.5.6',
    gitCommit: 'a'.repeat(40),
    artifacts
  });
  const pkgbuild = fs.readFileSync(result.pkgbuildFile, 'utf8');
  assert.doesNotMatch(pkgbuild, /REPLACE_WITH_|\bSKIP\b/u);
  assert.match(pkgbuild, /^pkgver=4\.5\.6$/mu);
  assert.match(pkgbuild, /releases\/download\/linux-v\$\{pkgver\}\/OpenBurnBar_\$\{pkgver\}_amd64\.AppImage/u);
  assert.match(pkgbuild, /raw\.githubusercontent\.com\/Imagine-That-Ai\/BurnBar\/linux-v\$\{pkgver\}/u);
  const metadata = JSON.parse(fs.readFileSync(result.metadataFile, 'utf8'));
  assert.equal(metadata.releaseTag, 'linux-v4.5.6');
  assert.deepEqual(metadata.aurPublication, {
    published: false,
    status: 'operator-required',
    note: 'Release assets are consumable directly; publishing to the AUR requires a separate operator action.'
  });
  assert.equal(metadata.sources.length, 19);
});

function record(installedPath, value, mode) {
  const bytes = Buffer.from(value);
  return { path: installedPath, type: 'file', sha256: sha256Bytes(bytes), size: bytes.length, mode, uid: 0, gid: 0 };
}

function commandAvailable(command) {
  return (process.env.PATH ?? '').split(path.delimiter).some((directory) => {
    try {
      fs.accessSync(path.join(directory, command), fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function fileRecord(file) {
  const bytes = fs.readFileSync(file);
  return {
    file: path.relative(repoRoot, file).split(path.sep).join('/'),
    sha256: sha256Bytes(bytes),
    size: bytes.length
  };
}
