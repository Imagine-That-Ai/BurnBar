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
  nativeRuntime: '/usr/lib/openburnbar/native'
};
for (const [key, expected] of Object.entries(expectedInstallPaths)) {
  if (manifest.installPaths?.[key] !== expected) {
    failures.push(`manifest.installPaths.${key} must be ${expected}`);
  }
}

const tauri = readJson(path.join(repoRoot, 'apps/linux-desktop/src-tauri/tauri.conf.json'));
const packageSources = {
  '/usr/bin/openburnbar-daemon': 'target/openburnbar-package-payload/openburnbar-daemon',
  '/usr/lib/openburnbar/swift': 'target/openburnbar-package-payload/swift',
  '/usr/lib/openburnbar/native': 'target/openburnbar-package-payload/native'
};
for (const packageType of ['deb', 'rpm']) {
  const files = tauri.bundle?.linux?.[packageType]?.files ?? {};
  for (const [destination, source] of Object.entries(packageSources)) {
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
const releaseBuilder = fs.readFileSync(path.join(repoRoot, 'scripts/linux-port/build-linux-release.mjs'), 'utf8');
if (!releaseBuilder.includes('embed-linux-appimage-payload.mjs')) {
  failures.push('release build must inject the staged native payload into the base AppImage');
}
const canonicalLauncher = fs.readFileSync(path.join(repoRoot, 'packaging/linux/openburnbar-daemon-launch.sh'));
const aurLauncher = fs.readFileSync(path.join(repoRoot, 'packaging/linux/aur/openburnbar-daemon-launch'));
if (!canonicalLauncher.equals(aurLauncher)) {
  failures.push('AUR and canonical daemon launch scripts must be byte-identical');
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
