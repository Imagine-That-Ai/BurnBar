import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
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
  assertSafeArchiveMemberNames,
  inspectNativePackageMetadata
} from './lib/linux-native-package.mjs';

const checksumSlots = [
  'APPIMAGE', 'DAEMON', 'DESKTOP', 'SAFE_MODE_DESKTOP', 'SERVICE', 'LAUNCH',
  'COMPUTER_USE_POLKIT_POLICY', 'PLAYWRIGHT_BRIDGE', 'BROWSER_RUNTIME_PROBE',
  'BROWSER_RUNTIME_REQUIREMENTS', 'INSTALLED_MANIFEST',
  'INSTALLED_MANIFEST_SIGNATURE', 'RELEASE_PUBLIC_KEY'
];

test('release PKGBUILD rendering fills every checksum slot without bypasses', () => {
  const template = fs.readFileSync(new URL('../../packaging/linux/aur/PKGBUILD', import.meta.url), 'utf8');
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
});

test('Arch prepare atomically extends the exact three-subject signing transaction', (t) => {
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
});

test('Arch extraction preflight permits only known package metadata beside /usr', () => {
  assert.deepEqual(
    [...assertSafeArchiveMemberNames('.PKGINFO\n.BUILDINFO\n.MTREE\nusr/bin/openburnbar\n', {
      allowedRootMetadata: ['.BUILDINFO', '.INSTALL', '.MTREE', '.PKGINFO']
    })],
    ['.PKGINFO', '.BUILDINFO', '.MTREE', 'usr/bin/openburnbar']
  );
  assert.throws(
    () => assertSafeArchiveMemberNames('.PKGINFO\netc/pacman.conf\n', {
      allowedRootMetadata: ['.BUILDINFO', '.INSTALL', '.MTREE', '.PKGINFO']
    }),
    /outside \/usr/u
  );
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
