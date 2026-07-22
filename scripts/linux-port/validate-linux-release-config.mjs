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

const manifest = readJson(manifestPath);
const failures = [];
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
  daemonBinary: '/usr/bin/openburnbar-daemon',
  swiftRuntime: '/usr/lib/openburnbar/swift',
  nativeRuntime: '/usr/lib/openburnbar/native',
  playwrightRuntime: '/usr/lib/openburnbar/playwright',
  irohNativeLibrary: '/usr/lib/openburnbar/native/libopenburnbar_iroh.so',
  cloudAuthConfig: '/usr/share/openburnbar/cloud-auth.json',
  computerUsePolkitPolicy: '/usr/share/polkit-1/actions/com.openburnbar.computer-use.policy'
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
  '/usr/bin/openburnbar-daemon': 'target/openburnbar-package-payload/openburnbar-daemon',
  '/usr/lib/openburnbar/swift': 'target/openburnbar-package-payload/swift',
  '/usr/lib/openburnbar/native': 'target/openburnbar-package-payload/native',
  '/usr/lib/openburnbar/playwright': 'target/openburnbar-package-payload/playwright',
  '/usr/share/openburnbar/cloud-auth.json': 'target/openburnbar-package-payload/cloud-auth.json'
};
const shellPackageSources = {
  '/usr/share/applications/dev.openburnbar.OpenBurnBar.desktop': '../../../packaging/linux/openburnbar.desktop',
  '/usr/share/applications/dev.openburnbar.OpenBurnBar.SafeMode.desktop': '../../../packaging/linux/openburnbar-safe-mode.desktop',
  '/etc/xdg/autostart/openburnbar.desktop': '../../../packaging/linux/autostart/openburnbar.desktop'
};
for (const packageType of ['deb', 'rpm']) {
  const files = tauri.bundle?.linux?.[packageType]?.files ?? {};
  for (const [destination, source] of Object.entries(packageSources)) {
    if (files[destination] !== source) {
      failures.push(`${packageType} must package ${source} at ${destination}`);
    }
  }
  for (const [destination, source] of Object.entries(shellPackageSources)) {
    if (files[destination] !== source) {
      failures.push(`${packageType} must package ${source} at ${destination}`);
    }
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
  '/usr/lib/systemd/user/openburnbar-daemon.service',
  ...Object.keys(shellPackageSources)
]) {
  if (!appImageFiles[destination]) failures.push(`appimage must package ${destination}`);
}
for (const [destination, source] of Object.entries(shellPackageSources)) {
  if (appImageFiles[destination] !== source) {
    failures.push(`appimage must package ${source} at ${destination}`);
  }
}
const desktopEntry = fs.readFileSync(path.join(repoRoot, 'packaging/linux/openburnbar.desktop'), 'utf8');
if (!desktopEntry.includes('Exec=openburnbar-linux-desktop %U')
    || !desktopEntry.includes('MimeType=x-scheme-handler/openburnbar;')) {
  failures.push('desktop entry must register openburnbar:// and pass URL arguments to the shell');
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
const releaseBuilder = fs.readFileSync(path.join(repoRoot, 'scripts/linux-port/build-linux-release.mjs'), 'utf8');
if (!releaseBuilder.includes('embed-linux-appimage-payload.mjs')) {
  failures.push('release build must inject the staged native payload into the base AppImage');
}
if (!releaseBuilder.includes("OPENBURNBAR_LINUX_RELEASE_BUILD: '1'")) {
  failures.push('release builder must require configured Linux cloud-auth public identifiers');
}
const releaseWorkflow = fs.readFileSync(path.join(repoRoot, '.github/workflows/linux-release.yml'), 'utf8');
if (!releaseWorkflow.includes('OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM: ${{ secrets.OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM }}')
    || !releaseWorkflow.includes('-e OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM')) {
  failures.push('Linux architecture builds must receive the release Ed25519 key for the signed AppImage peer manifest');
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
const aurPkgbuild = fs.readFileSync(path.join(repoRoot, 'packaging/linux/aur/PKGBUILD'), 'utf8');
if (!aurPkgbuild.includes('--appimage-extract usr/lib/openburnbar/native/libopenburnbar_iroh.so')
    || !aurPkgbuild.includes('/usr/lib/openburnbar/native/libopenburnbar_iroh.so')) {
  failures.push('AUR must install the Linux iroh runtime from the checksum-pinned AppImage');
}
if (/libopenburnbar_iroh\.so::https?:/u.test(aurPkgbuild)) {
  failures.push('AUR must not introduce an independent iroh runtime download');
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
  'writeSignedLinuxAppImagePeerManifest',
  'verifyLinuxAppImagePeerManifest',
  'OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM is required'
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
