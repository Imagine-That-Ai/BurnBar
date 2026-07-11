#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {
  manifestPath,
  readJson,
  reanchorEvidenceDir,
  repoRoot,
  writeJson
} from './lib/linux-release-common.mjs';
import {
  NATIVE_GENERATED_PACKAGE_INPUT_PATHS,
  NATIVE_PACKAGE_ASSET_PATHS,
  NATIVE_PACKAGE_LIFECYCLE_PATHS,
  NATIVE_SIGNER_INPUT_PATHS
} from './lib/linux-native-signing-receipt.mjs';
import { validateDistributionChannels } from './lib/linux-repository.mjs';

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
for (const gate of [
  'production repository OpenPGP primary and signing-subkey fingerprints are pinned',
  'signed repository closure and lifecycle receipt verify',
  'public apt and RPM bytes match the repository closure',
  'public apt and dnf install-update-rollback-uninstall lifecycle passes on both architectures',
  'interrupted repository publication preserves the previous snapshot through one-switch activation',
  'apt metadata refresh completes before signed expiry'
]) {
  if (!manifest.updateMetadata?.publishOnlyAfter?.includes(gate)) {
    failures.push(`manifest updateMetadata.publishOnlyAfter is missing repository gate: ${gate}`);
  }
}
for (const [kind, relPath] of Object.entries(manifest.tailMetadata ?? {})) {
  if (!fs.existsSync(path.join(repoRoot, relPath))) failures.push(`${kind} metadata missing at ${relPath}`);
}
if (manifest.distributionRepositories?.config !== manifest.tailMetadata?.distributionChannels) {
  failures.push('distribution repository config must be present in canonical tail metadata');
}
const distributionConfigPath = path.join(repoRoot, manifest.distributionRepositories?.config ?? '');
if (!fs.existsSync(distributionConfigPath)) {
  failures.push('distribution repository config is missing');
} else {
  failures.push(...validateDistributionChannels(readJson(distributionConfigPath)));
}
for (const [key, expected] of Object.entries({
  outputDirectory: 'repositories',
  closure: 'repositories/repository-closure.json',
  closureSignature: 'repositories/repository-closure.json.asc',
  lifecycleReceipt: 'repositories/repository-lifecycle.json',
  aptBuilder: 'dpkg-scanpackages',
  aptReleaseBuilder: 'apt-ftparchive',
  rpmPackageSigner: 'rpmsign',
  rpmBuilder: 'createrepo_c',
  lifecycleVerifier: 'scripts/linux-port/verify-linux-repository-lifecycle.sh',
  signingSecret: 'OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY'
})) {
  if (manifest.distributionRepositories?.[key] !== expected) {
    failures.push(`manifest.distributionRepositories.${key} must be ${expected}`);
  }
}
for (const relativePath of [
  'scripts/linux-port/build-linux-repositories.mjs',
  'scripts/linux-port/verify-linux-repositories.mjs',
  'scripts/linux-port/verify-linux-repository-lifecycle.sh',
  'scripts/linux-port/finalize-linux-repositories.mjs'
]) {
  if (!fs.existsSync(path.join(repoRoot, relativePath))) failures.push(`distribution repository command is missing: ${relativePath}`);
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
  attestationBroker: '/usr/libexec/openburnbar-attestd',
  attestationActivationReady: '/usr/libexec/openburnbar-attestd-activation-ready',
  restartActiveUserDaemons: '/usr/libexec/openburnbar-restart-active-user-daemons',
  attestationSystemService: '/usr/lib/systemd/system/openburnbar-attestd.service',
  attestationSystemSocket: '/usr/lib/systemd/system/openburnbar-attestd.socket',
  attestationSocket: '/run/openburnbar/attestd.sock',
  attestationEkContext: '/var/lib/openburnbar-attestd/ek.ctx',
  attestationEkPublic: '/var/lib/openburnbar-attestd/ek.pub',
  attestationEkCertificate: '/var/lib/openburnbar-attestd/ek.cert',
  attestationAkContext: '/var/lib/openburnbar-attestd/ak.ctx',
  attestationInstalledManifest: '/usr/share/openburnbar/attestation/installed-manifest.json',
  attestationInstalledManifestSignature: '/usr/share/openburnbar/attestation/installed-manifest.json.sig',
  attestationReleasePublicKey: '/usr/share/openburnbar/attestation/release-ed25519.pub.pem'
};
for (const [key, expected] of Object.entries(expectedInstallPaths)) {
  if (manifest.installPaths?.[key] !== expected) {
    failures.push(`manifest.installPaths.${key} must be ${expected}`);
  }
}
if (manifest.rootAttestationBroker?.defaultActivation !== 'disabled-until-enrolled-and-rollout-enabled') {
  failures.push('root attestation broker must remain disabled until enrollment and rollout gates pass');
}
if (manifest.rootAttestationBroker?.quoteCollector !== '/usr/bin/tpm2_quote') {
  failures.push('root attestation broker must use the packaged tpm2_quote collector');
}
if (manifest.rootAttestationBroker?.akLifecycle?.mode !== 'broker-cli-initialize-ak') {
  failures.push('root attestation broker must own AK initialization through the broker CLI');
}
if (manifest.rootAttestationBroker?.akLifecycle?.createak !== '/usr/bin/tpm2_createak') {
  failures.push('root attestation broker must use the packaged tpm2_createak lifecycle collector');
}
if (manifest.rootAttestationBroker?.akLifecycle?.rotation !== 'refuse-existing-unless-explicit-rotate') {
  failures.push('root attestation broker must refuse accidental AK overwrite without explicit rotation');
}
if (manifest.rootAttestationBroker?.akContext !== '/var/lib/openburnbar-attestd/ak.ctx') {
  failures.push('root attestation broker AK context path is fixed by the activation gate');
}
if (!(manifest.rootAttestationBroker?.peerAuthorization ?? []).some((entry) =>
  entry.includes('SCM_CREDENTIALS') && entry.includes('SOCK_SEQPACKET'))) {
  failures.push('root attestation broker must bind authorization to per-request SCM_CREDENTIALS');
}

const tauri = readJson(path.join(repoRoot, 'apps/linux-desktop/src-tauri/tauri.conf.json'));
if (JSON.stringify(tauri.bundle?.targets) !== JSON.stringify(['appimage'])) {
  failures.push('Tauri must build AppImage only; native dpkg/rpmbuild own privileged package lifecycle');
}
for (const packageType of ['deb', 'rpm']) {
  if (tauri.bundle?.linux?.[packageType]) {
    failures.push(`Tauri ${packageType} configuration must be absent; native package builder owns ${packageType}`);
  }
  const expectedBuilder = packageType === 'deb' ? 'native-dpkg' : 'native-rpmbuild';
  if (manifest.packageBuilders?.[packageType] !== expectedBuilder) {
    failures.push(`manifest.packageBuilders.${packageType} must be ${expectedBuilder}`);
  }
}
const appImageFiles = tauri.bundle?.linux?.appimage?.files ?? {};
for (const destination of [
  '/usr/bin/openburnbar-daemon',
  '/usr/lib/openburnbar/swift',
  '/usr/lib/openburnbar/native',
  '/usr/libexec/openburnbar-attestd',
  '/usr/lib/systemd/system/openburnbar-attestd.service',
  '/usr/lib/systemd/system/openburnbar-attestd.socket'
]) {
  if (appImageFiles[destination]) {
    failures.push(`AppImage must not contain privileged attestation payload ${destination}`);
  }
}
for (const destination of [
  '/usr/libexec/openburnbar-daemon-launch',
  '/usr/lib/systemd/user/openburnbar-daemon.service',
  '/usr/share/openburnbar/autostart/openburnbar.desktop'
]) {
  if (!appImageFiles[destination]) failures.push(`appimage must package ${destination}`);
}
const desktopPackage = readJson(path.join(repoRoot, 'apps/linux-desktop/package.json'));
if (desktopPackage.scripts?.['pretauri:build'] !== 'node ../../scripts/linux-port/prepare-linux-package-payload.mjs') {
  failures.push('tauri build must stage and runtime-probe the native Linux package payload');
}
const releaseBuilder = fs.readFileSync(path.join(repoRoot, 'scripts/linux-port/build-linux-release.mjs'), 'utf8');
if (!releaseBuilder.includes('embed-linux-appimage-payload.mjs')) {
  failures.push('release build must inject the staged native payload into the base AppImage');
}
for (const requiredSource of [
  'crates/openburnbar-attestd/Cargo.toml',
  "'--bundles', 'appimage'",
  '--prepare-only',
  '--finalize-only'
]) {
  if (!releaseBuilder.includes(requiredSource)) {
    failures.push(`release build is missing native attestation/package wiring: ${requiredSource}`);
  }
}
if (releaseBuilder.includes('build-native-linux-packages.mjs')) {
  failures.push('release build must not invoke the signing-capable native package builder');
}
if (releaseBuilder.includes("'--bundles', 'deb,rpm,appimage'")) {
  failures.push('release build must not delegate deb/rpm lifecycle to Tauri');
}
const nativeBuilder = fs.readFileSync(path.join(repoRoot, 'scripts/linux-port/build-native-linux-packages.mjs'), 'utf8');
for (const requiredContract of [
  'NATIVE_GENERATED_PACKAGE_INPUT_PATHS',
  'NATIVE_PACKAGE_ASSET_PATHS',
  'NATIVE_PACKAGE_LIFECYCLE_PATHS',
  'measureNativeSignerInputs',
  'signNativePackageSigningReceipt',
  'OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM'
]) {
  if (!nativeBuilder.includes(requiredContract)) failures.push(`native package builder missing ${requiredContract}`);
}
const canonicalSignerInputs = [
  'functions/.env.burnbar.production',
  ...Object.values(NATIVE_GENERATED_PACKAGE_INPUT_PATHS),
  ...Object.values(NATIVE_PACKAGE_ASSET_PATHS),
  ...Object.values(NATIVE_PACKAGE_LIFECYCLE_PATHS.deb),
  ...Object.values(NATIVE_PACKAGE_LIFECYCLE_PATHS.rpm)
];
if (JSON.stringify(NATIVE_SIGNER_INPUT_PATHS) !== JSON.stringify(canonicalSignerInputs)) {
  failures.push('native signer input inventory must derive exactly from generated inputs, assets, and lifecycle scripts');
}
for (const relativePath of [
  ...Object.values(NATIVE_PACKAGE_ASSET_PATHS),
  ...Object.values(NATIVE_PACKAGE_LIFECYCLE_PATHS.deb),
  ...Object.values(NATIVE_PACKAGE_LIFECYCLE_PATHS.rpm)
]) {
  if (!fs.existsSync(path.join(repoRoot, relativePath))) {
    failures.push(`native signer source input is missing: ${relativePath}`);
  }
}
const canonicalLauncher = fs.readFileSync(path.join(repoRoot, 'packaging/linux/openburnbar-daemon-launch.sh'));
const aurLauncher = fs.readFileSync(path.join(repoRoot, 'packaging/linux/aur/openburnbar-daemon-launch'));
if (!canonicalLauncher.equals(aurLauncher)) {
  failures.push('AUR and canonical daemon launch scripts must be byte-identical');
}
if (fs.existsSync(path.join(repoRoot, 'website/public/downloads/latest-linux.json'))) {
  failures.push('website/public/downloads/latest-linux.json must not be checked in before release verification is green');
}
const report = { generatedAt: new Date().toISOString(), passed: failures.length === 0, failures };
// Never rewrite sealed mission-001-release evidence (same rule as parity-ledger validator).
fs.mkdirSync(reanchorEvidenceDir, { recursive: true });
writeJson(path.join(reanchorEvidenceDir, 'release-config-validation.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(failures.length === 0 ? 0 : 1);
