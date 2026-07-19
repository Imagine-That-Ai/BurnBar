import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  isAllowedNativeNonUsrPath,
  NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST
} from './lib/linux-native-package.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');

test('release Cargo target is ignored exactly without masking adjacent checkout paths', () => {
  const gitignore = read('.gitignore');
  assert.match(gitignore, /^crates\/openburnbar-iroh\/target-linux-release\/$/mu);

  const checkIgnore = (candidate) => spawnSync(
    'git',
    ['check-ignore', '--no-index', '--stdin'],
    { cwd: root, input: `${candidate}\n`, encoding: 'utf8' }
  );
  const generated = checkIgnore('crates/openburnbar-iroh/target-linux-release/release/libopenburnbar_iroh.so');
  assert.equal(generated.status, 0, generated.stderr || generated.stdout);

  const nearMiss = checkIgnore('crates/openburnbar-iroh/target-linux-release-not-generated/release/libopenburnbar_iroh.so');
  assert.notEqual(nearMiss.status, 0, nearMiss.stdout || nearMiss.stderr);
});

test('deb, rpm, and Arch package exact installed attestation subjects', () => {
  const config = JSON.parse(read('apps/linux-desktop/src-tauri/tauri.conf.json'));
  const expected = {
    '/usr/bin/openburnbar-cli': 'target/openburnbar-package-payload/openburnbar-cli',
    '/usr/bin/OpenBurnBarCore_OpenBurnBarCore.resources': 'target/openburnbar-package-payload/OpenBurnBarCore_OpenBurnBarCore.resources',
    '/usr/share/openburnbar/attestation/installed-manifest.json': 'target/openburnbar-package-payload/attestation/installed-manifest.json',
    '/usr/share/openburnbar/attestation/installed-manifest.json.sig': 'target/openburnbar-package-payload/attestation/installed-manifest.json.sig',
    '/usr/share/openburnbar/attestation/release-ed25519.pub.pem': 'target/openburnbar-package-payload/attestation/release-ed25519.pub.pem',
    '/usr/libexec/openburnbar-cli-migrate': '../../../packaging/linux/openburnbar-cli-migrate.sh'
  };
  for (const format of ['deb', 'rpm']) {
    const files = config.bundle.linux[format].files;
    for (const [destination, source] of Object.entries(expected)) assert.equal(files[destination], source);
    assert.equal(config.bundle.linux[format].postInstallScript, '../../../packaging/linux/openburnbar-cli-migrate.sh');
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

test('Linux Swift daemon builds receive the native iroh library environment', () => {
  const source = read('scripts/linux-port/build-linux-release.mjs');
  assert.match(source, /OPENBURNBAR_LINUX_IROH_LIBRARY_DIR:\s*irohNativeLibraryDirectory/u);
  const swiftBuilds = [...source.matchAll(/runStep\('swift',[\s\S]*?--allow-shlib-undefined'[\s\S]*?\}\)\);/gu)];
  assert.equal(swiftBuilds.length, 2, 'release must build both daemon and CLI Swift products');
  for (const [index, match] of swiftBuilds.entries()) {
    assert.match(
      match[0],
      /\],\s*\{\s*env:\s*packageBuildEnv\s*\}\)\);/u,
      `Swift product ${index + 1} must receive packageBuildEnv so SwiftPM enables Linux iroh FFI`
    );
  }
});

test('Linux daemon and trusted CLI carry relocatable runtime paths and both are probed', () => {
  const packageSwift = read('OpenBurnBarDaemon/Package.swift');
  assert.ok(packageSwift.includes('$ORIGIN/../lib/openburnbar/swift'));
  assert.ok(packageSwift.includes('$ORIGIN/../lib/openburnbar/native'));
  assert.match(
    packageSwift,
    /name: "OpenBurnBarDaemonExecutable"[\s\S]*?linkerSettings: linuxExecutableLinkerSettings/u
  );
  assert.match(
    packageSwift,
    /name: "OpenBurnBarCLI"[\s\S]*?linkerSettings: linuxExecutableLinkerSettings/u
  );
  const payload = read('scripts/linux-port/lib/linux-package-payload.mjs');
  assert.match(payload, /probeRuntimeBinary\(cli, 'CLI'/u);
  assert.match(payload, /cliLdd: cliProbe\.ldd/u);
});

test('package preparation and finalization never receive the private key', () => {
  const source = read('scripts/linux-port/bundle-signed-linux-packages.mjs');
  for (const marker of [
    "for (const format of ['deb', 'rpm'])",
    "phase === 'prepare'",
    "bundleFormat(format, format === 'rpm' ? { debArtifact } : undefined)",
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

test('RPM release packaging is rebuilt from the validated DEB filesystem', () => {
  const source = read('scripts/linux-port/bundle-signed-linux-packages.mjs');
  assert.match(source, /function bundleRpmFromDeb\(debArtifact\)/u);
  assert.match(source, /run\('dpkg-deb', \['--fsys-tarfile', debArtifact\]/u);
  assert.match(
    source,
    /extractPreflightedArchiveBytes\(dataArchive, extractedRoot, \{\s*env: childEnvironment,\s*allowedPaths: NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST\s*\}\)/u
  );
  assert.match(source, /run\('rpmbuild'/u);
  assert.match(source, /Requires: libsecret/u);
  assert.match(source, /%post[\s\S]*\/usr\/libexec\/openburnbar-cli-migrate/u);
  assert.match(source, /Tauri's RPM bundler can emit an archive/u);
  assert.doesNotMatch(source, /bundleFormat\('rpm'\)/u);
});

test('RPM spec path validation allows only canonical XDG autostart and its parents', () => {
  const source = read('scripts/linux-port/bundle-signed-linux-packages.mjs');
  const guardStart = source.indexOf('function rpmSpecPath(value)');
  const guardEnd = source.indexOf('function rpmSpecToken', guardStart);
  assert.ok(guardStart >= 0 && guardEnd > guardStart, 'RPM spec path guard must remain explicit');
  const guard = source.slice(guardStart, guardEnd);
  assert.match(guard, /const packagePath = value\.startsWith\('\/'\) \? value\.slice\(1\) : value/u);
  assert.match(guard, /isAllowedNativeNonUsrPath\(packagePath\)/u);

  assert.deepEqual([...NATIVE_PACKAGE_NON_USR_PATH_ALLOWLIST], [
    'etc/xdg/autostart/openburnbar.desktop'
  ]);
  for (const candidate of [
    'etc',
    'etc/xdg',
    'etc/xdg/autostart',
    'etc/xdg/autostart/openburnbar.desktop'
  ]) {
    assert.equal(isAllowedNativeNonUsrPath(candidate), true, `${candidate} should be allowed`);
  }
  for (const candidate of [
    'etc/pacman.conf',
    'etc/xdg/autostart/other.desktop',
    'var/lib/openburnbar/state'
  ]) {
    assert.equal(isAllowedNativeNonUsrPath(candidate), false, `${candidate} should be rejected`);
  }
});

test('Arch preparation embeds the native payload before makepkg without unsigned peer files', () => {
  const source = read('scripts/linux-port/bundle-signed-linux-packages.mjs');
  assert.match(source, /const packagePayloadRoot =/u);
  assert.match(source, /const intermediateEnvironment = \{ \.\.\.childEnvironment \}/u);
  assert.match(source, /delete intermediateEnvironment\.OPENBURNBAR_LINUX_RELEASE_BUILD/u);
  assert.match(source, /peerManifestBytes: null/u);
  assert.match(source, /peerSignature: null/u);
  assert.match(source, /embedLinuxAppImagePayload\(/u);
});

test('Arch preparation maps every common PKGBUILD source slot to a filename', () => {
  const source = read('scripts/linux-port/build-signed-arch-package.mjs');
  assert.match(source, /\['AUTOSTART_DESKTOP', 'openburnbar-autostart\.desktop'\]/u);
});

test('signed AppImage finalization reuses the attested prepare artifact', () => {
  const source = read('scripts/linux-port/bundle-signed-linux-packages.mjs');
  const finalizeStart = source.indexOf('function finalizeSignedPackages()');
  assert.ok(finalizeStart > 0, 'finalization function must remain explicit');
  const finalize = source.slice(finalizeStart);
  assert.match(
    finalize,
    /findSingleArtifact\(path\.join\(bundleRoot, 'appimage'\), 'appimage'\)/u
  );
  assert.doesNotMatch(finalize, /bundleFormat\('appimage'\)/u);
  assert.doesNotMatch(finalize, /verifyLinuxAppImagePeerManifest\(/u);
  assert.doesNotMatch(finalize, /target\/release\/openburnbar-linux-desktop/u);
  assert.match(
    finalize,
    /embedLinuxAppImagePayload\([\s\S]*peerManifestBytes: appImageSigned\.manifestBytes/u
  );
  const embedder = read('scripts/linux-port/embed-linux-appimage-payload.mjs');
  assert.match(embedder, /assertEmbeddedPayload\(verifiedRoot, \{ requirePeerManifest: peerAttestation !== null \}\)/u);
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
  assert.match(source, /archDependencyPackagesForInstall/u);
  assert.match(source, /\['-Syu', '--noconfirm', '--needed'/u);
  assert.match(source, /readRecordedFile\(artifact, 'Arch package artifact', repoRoot\)/u);
  assert.match(source, /readRecordedFile\(record, label, outDir\)/u);
  assert.match(source, /'\/usr\/lib\/openburnbar\/swift'/u);
  assert.match(source, /'\/usr\/lib\/openburnbar\/native'/u);
  assert.match(source, /LD_LIBRARY_PATH: packagedLibraryPaths\.join\(':'\)/u);
  assert.match(read('scripts/linux-port/lib/linux-native-package.mjs'), /ttf-dejavu/u);
  assert.match(source, /\/usr\/bin\/openburnbar-linux-desktop/u);
  assert.match(source, /\/usr\/lib\/openburnbar\/appdir\/AppRun/u);
  assert.match(source, /\/usr\/share\/icons\/hicolor\/256x256\/apps\/dev\.openburnbar\.OpenBurnBar\.png/u);
  assert.doesNotMatch(source, /--appimage-extract-and-run/u);
  assert.match(source, /\/usr\/bin\/openburnbar-daemon/u);
  assert.match(source, /pacman -Q openburnbar expects package absence/u);
  assert.match(source, /package-owned filesystem entries removed/u);
});
