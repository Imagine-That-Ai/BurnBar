#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {
  manifestPath,
  readJson,
  reanchorEvidenceDir,
  repoRoot,
  writeJson
} from './lib/linux-release-common.mjs';
import { validateFcitx5AddonContract } from './validate-fcitx5-addon-source.mjs';

const manifest = readJson(manifestPath);
const failures = [];
failures.push(...validateFcitx5AddonContract({ root: repoRoot }));
for (const key of ['product', 'appId', 'primaryArtifact', 'requiredArtifacts', 'tailMetadata', 'updateMetadata']) {
  if (!manifest[key]) failures.push(`manifest missing ${key}`);
}
for (const artifact of ['appimage', 'deb', 'rpm']) {
  if (!manifest.requiredArtifacts?.includes(artifact)) failures.push(`manifest does not require ${artifact}`);
}
if (JSON.stringify(manifest.supportedArchitectures) !== JSON.stringify(['aarch64', 'x86_64'])) {
  failures.push('manifest supportedArchitectures must be exactly aarch64 and x86_64');
}
if (manifest.updateMetadata?.publicUrl !== 'https://downloads.burnbar.ai/latest-linux.json') {
  failures.push('manifest updateMetadata.publicUrl must be the branded signed-feed URL');
}
for (const [kind, relPath] of Object.entries(manifest.tailMetadata ?? {})) {
  if (!fs.existsSync(path.join(repoRoot, relPath))) failures.push(`${kind} metadata missing at ${relPath}`);
}
// Unit ExecStart requires the launch script to ship with packages (203/EXEC).
const launchRel = manifest.tailMetadata?.daemonLaunchScript;
if (!launchRel) {
  failures.push('manifest.tailMetadata.daemonLaunchScript is required');
} else {
  const launchFull = path.join(repoRoot, launchRel);
  if (!fs.existsSync(launchFull)) {
    failures.push(`daemon launch script missing at ${launchRel}`);
  } else {
    const mode = fs.statSync(launchFull).mode & 0o111;
    if (!mode) failures.push(`${launchRel} must be executable`);
    const unit = fs.readFileSync(path.join(repoRoot, manifest.tailMetadata.systemdUserService), 'utf8');
    if (!unit.includes('/usr/libexec/openburnbar-daemon-launch')) {
      failures.push('systemd unit must ExecStart=/usr/libexec/openburnbar-daemon-launch');
    }
  }
}
if (!manifest.installPaths?.daemonLaunch) {
  failures.push('manifest.installPaths.daemonLaunch is required');
}
const expectedInstallPaths = {
  cliBinary: '/usr/bin/openburnbar-cli',
  daemonBinary: '/usr/bin/openburnbar-daemon',
  swiftRuntime: '/usr/lib/openburnbar/swift',
  nativeRuntime: '/usr/lib/openburnbar/native',
  playwrightRuntime: '/usr/lib/openburnbar/playwright',
  irohNativeLibrary: '/usr/lib/openburnbar/native/libopenburnbar_iroh.so',
    cloudAuthConfig: '/usr/share/openburnbar/cloud-auth.json',
    installedManifest: '/usr/share/openburnbar/attestation/installed-manifest.json',
  installedManifestSignature: '/usr/share/openburnbar/attestation/installed-manifest.json.sig',
  releasePublicKey: '/usr/share/openburnbar/attestation/release-ed25519.pub.pem',
  computerUsePolkitPolicy: '/usr/share/polkit-1/actions/com.openburnbar.computer-use.policy',
  autostartEntry: '/etc/xdg/autostart/openburnbar.desktop'
};
for (const [key, expected] of Object.entries(expectedInstallPaths)) {
  if (manifest.installPaths?.[key] !== expected) {
    failures.push(`manifest.installPaths.${key} must be ${expected}`);
  }
}
if (manifest.tailMetadata?.computerUsePolkitPolicy !== 'packaging/linux/com.openburnbar.computer-use.policy') {
  failures.push('manifest.tailMetadata.computerUsePolkitPolicy must name the canonical privileged policy source');
}

const tauri = readJson(path.join(repoRoot, 'apps/linux-desktop/src-tauri/tauri.conf.json'));
const packageSources = {
  '/usr/bin/openburnbar-cli': 'target/openburnbar-package-payload/openburnbar-cli',
  '/usr/bin/openburnbar-daemon': 'target/openburnbar-package-payload/openburnbar-daemon',
  '/usr/bin': 'target/openburnbar-package-payload/resource-bundles',
  '/usr/lib/openburnbar/swift': 'target/openburnbar-package-payload/swift',
  '/usr/lib/openburnbar/native': 'target/openburnbar-package-payload/native',
  '/usr/lib/openburnbar/playwright': 'target/openburnbar-package-payload/playwright',
  '/usr/share/openburnbar/cloud-auth.json': 'target/openburnbar-package-payload/cloud-auth.json',
  '/usr/share/openburnbar/attestation/installed-manifest.json': 'target/openburnbar-package-payload/attestation/installed-manifest.json',
  '/usr/share/openburnbar/attestation/installed-manifest.json.sig': 'target/openburnbar-package-payload/attestation/installed-manifest.json.sig',
  '/usr/share/openburnbar/attestation/release-ed25519.pub.pem': 'target/openburnbar-package-payload/attestation/release-ed25519.pub.pem',
  '/usr/libexec/openburnbar-cli-migrate': '../../../packaging/linux/openburnbar-cli-migrate.sh',
  '/etc/xdg/autostart/openburnbar.desktop': '../../../packaging/linux/autostart/openburnbar.desktop'
};
for (const packageType of ['deb', 'rpm']) {
  const bundle = tauri.bundle?.linux?.[packageType] ?? {};
  const files = bundle.files ?? {};
  if (bundle.desktopTemplate !== '../../../packaging/linux/tauri-installed.desktop') {
    failures.push(`${packageType} must use the canonical installed desktop template`);
  }
  for (const [destination, source] of Object.entries(packageSources)) {
    if (files[destination] !== source) {
      failures.push(`${packageType} must package ${source} at ${destination}`);
    }
  }
  if (tauri.bundle?.linux?.[packageType]?.postInstallScript !== '../../../packaging/linux/openburnbar-cli-migrate.sh') {
    failures.push(`${packageType} must run the canonical CLI migration post-install script`);
  }
}
const appImageFiles = tauri.bundle?.linux?.appimage?.files ?? {};
for (const destination of Object.keys(packageSources)) {
  if (appImageFiles[destination]) {
    failures.push(`appimage payload ${destination} must be injected after linuxdeploy to avoid custom-file collisions`);
  }
}
for (const destination of [
  '/usr/libexec/openburnbar-daemon-launch',
  '/usr/lib/systemd/user/openburnbar-daemon.service'
]) {
  if (!appImageFiles[destination]) failures.push(`appimage must package ${destination}`);
}
if (!tauri.bundle?.linux?.deb?.depends?.includes('libsecret-tools')) {
  failures.push('deb package must depend on libsecret-tools');
}
if (!tauri.bundle?.linux?.rpm?.depends?.includes('libsecret')) {
  failures.push('rpm package must depend on libsecret');
}
const desktopPackage = readJson(path.join(repoRoot, 'apps/linux-desktop/package.json'));
if (desktopPackage.scripts?.['pretauri:build'] !== 'node ../../scripts/linux-port/prepare-linux-package-payload.mjs') {
  failures.push('tauri build must stage and runtime-probe the native Linux package payload');
}
if (desktopPackage.scripts?.['tauri:bundle'] !== 'tauri bundle') {
  failures.push('Linux release packaging must expose the two-pass Tauri bundle command');
}
const releaseBuilder = fs.readFileSync(path.join(repoRoot, 'scripts/linux-port/build-linux-release.mjs'), 'utf8');
if (!releaseBuilder.includes('bundle-signed-linux-packages.mjs')) {
  failures.push('release build must create and verify signed installed manifests before native package closure');
}
if (!releaseBuilder.includes("['prepare', 'finalize']")
    || !releaseBuilder.includes('must not receive OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM')) {
  failures.push('release build must expose distinct no-key prepare and finalize phases');
}
if (!releaseBuilder.includes("OPENBURNBAR_LINUX_RELEASE_BUILD: '1'")) {
  failures.push('release builder must require configured Linux cloud-auth public identifiers');
}
const releaseWorkflow = fs.readFileSync(path.join(repoRoot, '.github/workflows/linux-release.yml'), 'utf8');
for (const marker of [
  '--phase prepare',
  'Materialize exact-commit isolated signer',
  '--network none',
  '--read-only',
  '--cap-drop ALL',
  '--security-opt no-new-privileges',
  'sign-linux-release-requests.mjs',
  '--phase finalize'
]) {
  if (!releaseWorkflow.includes(marker)) failures.push(`Linux isolated signing workflow missing ${marker}`);
}
// The text-expansion signer job and the isolated native-request signer are
// intentionally allowed to receive the private key. Inspect only the
// architecture build job's unsigned preparation phase so a separate signing
// job cannot trip this no-key invariant.
const buildArchitectureJob = releaseWorkflow.match(
  /^  build-architecture:\n[\s\S]*?(?=^  [a-z0-9-]+:\n|$(?![\s\S]))/m
)?.[0] ?? '';
const unsignedBuildArchitecture = buildArchitectureJob.split('Materialize exact-commit isolated signer')[0] ?? '';
if (!buildArchitectureJob) {
  failures.push('Linux release workflow must define the build-architecture job');
} else if (unsignedBuildArchitecture.includes('OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM')) {
  failures.push('Linux unsigned build environment must not receive the release Ed25519 private key');
}
for (const variable of manifest.externalCredentials?.publicCloudAuthVariables ?? []) {
  if (!releaseWorkflow.includes(`vars.${variable}`) || !releaseWorkflow.includes(`-e ${variable}`)) {
    failures.push(`Linux release workflow must inject repository variable ${variable} into the native build`);
  }
}
const functionsProductionConfig = fs.readFileSync(
  path.join(repoRoot, 'functions/.env.burnbar.production'),
  'utf8'
);
const productionLinuxAppID = functionsProductionConfig.match(/^LINUX_APP_CHECK_APP_ID=(\S+)$/mu)?.[1];
if (!productionLinuxAppID
    || !/^1:[0-9]{6,20}:web:[A-Za-z0-9_-]{8,128}$/u.test(productionLinuxAppID)
    || /placeholder/iu.test(productionLinuxAppID)) {
  failures.push('Functions production config must declare the real dedicated Linux Firebase web app id');
}
if (process.env.OPENBURNBAR_LINUX_APP_CHECK_APP_ID
    && process.env.OPENBURNBAR_LINUX_APP_CHECK_APP_ID !== productionLinuxAppID) {
  failures.push('Linux release App Check app id must match the Functions production app id');
}
const aurPkgbuild = fs.readFileSync(path.join(repoRoot, 'packaging/linux/aur/PKGBUILD.in'), 'utf8');
if (!aurPkgbuild.includes('--appimage-extract >"${extraction_log}" 2>&1')
    || !aurPkgbuild.includes('usr/lib/openburnbar/native/libopenburnbar_iroh.so')
    || !aurPkgbuild.includes('cp -a "${srcdir}/squashfs-root/." "${pkgdir}/usr/lib/openburnbar/appdir/"')
    || !aurPkgbuild.includes('openburnbar-cli" "${pkgdir}/usr/bin/openburnbar-cli"')
    || !aurPkgbuild.includes('openburnbar-linux-desktop" "${pkgdir}/usr/bin/openburnbar-linux-desktop"')
    || !aurPkgbuild.includes('dev.openburnbar.OpenBurnBar.png')) {
  failures.push('Arch release template must install the native AppDir, fixed launcher, icon, and iroh runtime from checksum-pinned sources');
}
if (/libopenburnbar_iroh\.so::https?:/u.test(aurPkgbuild)) {
  failures.push('Arch release template must not introduce an independent iroh runtime download');
}
const canonicalLauncher = fs.readFileSync(path.join(repoRoot, 'packaging/linux/openburnbar-daemon-launch.sh'));
const aurLauncher = fs.readFileSync(path.join(repoRoot, 'packaging/linux/aur/openburnbar-daemon-launch'));
if (!canonicalLauncher.equals(aurLauncher)) {
  failures.push('AUR and canonical daemon launch scripts must be byte-identical');
}
const launcherText = canonicalLauncher.toString('utf8');
if (/export OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS/u.test(launcherText)
    || !launcherText.includes('unset OPENBURNBAR_DAEMON_LINUX_PEER_SHA256_PINS')) {
  failures.push('packaged launchers must discard legacy peer roots and raw hash pins');
}
const appImageEmbedder = fs.readFileSync(
  path.join(repoRoot, 'scripts/linux-port/embed-linux-appimage-payload.mjs'),
  'utf8'
);
for (const marker of [
  'prepareLinuxAppImagePeerManifest',
  'resolveLinuxAppImagePeerAttestation',
  'verifyLinuxAppImagePeerManifest',
  'must not receive OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM'
]) {
  if (!appImageEmbedder.includes(marker)) failures.push(`AppImage peer-manifest embedder missing ${marker}`);
}
if (fs.existsSync(path.join(repoRoot, 'website/public/downloads/latest-linux.json'))) {
  failures.push('website/public/downloads/latest-linux.json must not be checked in before release verification is green');
}
const contractTest = spawnSync(process.execPath, ['--test', 'scripts/linux-port/resolve-linux-release-ref.test.mjs'], {
  cwd: repoRoot,
  encoding: 'utf8'
});
if (contractTest.status !== 0) {
  failures.push(`Linux release binding contract failed:\n${contractTest.stdout}${contractTest.stderr}`.trim());
}
const report = { generatedAt: new Date().toISOString(), passed: failures.length === 0, failures };
// Never rewrite sealed mission-001-release evidence (same rule as parity-ledger validator).
fs.mkdirSync(reanchorEvidenceDir, { recursive: true });
writeJson(path.join(reanchorEvidenceDir, 'release-config-validation.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(failures.length === 0 ? 0 : 1);
