import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');

test('deb, rpm, and Arch package exact installed attestation subjects', () => {
  const config = JSON.parse(read('apps/linux-desktop/src-tauri/tauri.conf.json'));
  const expected = {
    '/usr/share/openburnbar/attestation/installed-manifest.json': 'target/openburnbar-package-payload/attestation/installed-manifest.json',
    '/usr/share/openburnbar/attestation/installed-manifest.json.sig': 'target/openburnbar-package-payload/attestation/installed-manifest.json.sig',
    '/usr/share/openburnbar/attestation/release-ed25519.pub.pem': 'target/openburnbar-package-payload/attestation/release-ed25519.pub.pem'
  };
  for (const format of ['deb', 'rpm']) {
    const files = config.bundle.linux[format].files;
    for (const [destination, source] of Object.entries(expected)) assert.equal(files[destination], source);
  }
  const pkgbuild = read('packaging/linux/aur/PKGBUILD.in');
  for (const destination of Object.keys(expected)) {
    assert.ok(pkgbuild.includes(destination), `Arch recipe missing ${destination}`);
  }
});

test('release build uses isolated signing phases and emits closure records', () => {
  const source = read('scripts/linux-port/build-linux-release.mjs');
  assert.match(source, /tauri:build[\s\S]*--no-bundle/u);
  assert.match(source, /bundle-signed-linux-packages\.mjs/u);
  assert.match(source, /--phase/u);
  assert.match(source, /installedManifest = shardRecord/u);
  assert.match(source, /installedManifestSignature = shardRecord/u);
  assert.match(source, /verifyEd25519Signature/u);
  assert.doesNotMatch(source, /tauri:build[\s\S]{0,80}--bundles/u);
});

test('package preparation and finalization never receive the private key', () => {
  const source = read('scripts/linux-port/bundle-signed-linux-packages.mjs');
  for (const marker of [
    "for (const format of ['deb', 'rpm'])",
    "phase === 'prepare'",
    'const artifact = bundleFormat(format)',
    'const artifact = bundleFormat(format)',
    'verifySignedNativePackage',
    'withoutLinuxReleasePrivateKey',
    'must not receive OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM'
  ]) assert.ok(source.includes(marker), `missing ${marker}`);
  const signer = read('scripts/linux-port/sign-linux-release-requests.mjs');
  assert.match(signer, /ED25519_PRIVATE_KEY_PEM is required in the isolated signer/u);
  assert.doesNotMatch(signer, /tauri|npm|extractNativePackage/u);
  const arch = read('scripts/linux-port/build-signed-arch-package.mjs');
  assert.match(arch, /must not receive the Linux release private key/u);
  assert.match(arch, /verifySignedNativePackage/u);
  assert.match(arch, /makepkg/u);
});

test('release workflow isolates the signer from mutable build tools and the network', () => {
  const workflow = read('.github/workflows/linux-release.yml');
  const signerStart = workflow.indexOf('Materialize exact-commit isolated signer');
  assert.ok(signerStart > 0);
  const unsignedBuild = workflow.slice(0, signerStart);
  assert.doesNotMatch(unsignedBuild, /OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM/u);
  for (const marker of [
    'git archive "$GITHUB_SHA"',
    '--network none',
    '--read-only',
    '--cap-drop ALL',
    '--security-opt no-new-privileges',
    '$SIGNER_ROOT:/signer:ro',
    'sign-linux-release-requests.mjs',
    '--git-commit "$GITHUB_SHA"',
    '--phase finalize',
    'docker create --name "$container"',
    'docker start --attach "$container"'
  ]) assert.ok(workflow.includes(marker), `missing isolated signer marker: ${marker}`);
});

test('Arch pacman smoke verifies the live signed inventory before uninstall', () => {
  const source = read('scripts/linux-port/smoke-arch-package.mjs');
  const install = source.indexOf("['-U', '--noconfirm'");
  const verify = source.indexOf('steps.push(installedPackageVerificationStep');
  const uninstall = source.indexOf("['-R', '--noconfirm'");
  assert.ok(install > 0 && verify > install && uninstall > verify);
  assert.match(source, /packageManager: 'pacman'/u);
  assert.doesNotMatch(source, /--nodeps/u);
  assert.match(source, /inspectArchPackageDependencies/u);
  assert.match(source, /\['-Syu', '--noconfirm', '--needed'/u);
  assert.match(source, /\/usr\/bin\/openburnbar-linux-desktop/u);
  assert.match(source, /\/usr\/bin\/openburnbar-daemon/u);
  assert.match(source, /pacman -Q openburnbar expects package absence/u);
  assert.match(source, /package-owned filesystem entries removed/u);
});
