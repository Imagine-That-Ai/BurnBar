#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = path.resolve(SCRIPT_DIR, '../..');
const FCITX_CONTRACT_DESTINATION = '/usr/share/openburnbar/text-expansion/fcitx5-openburnbar-addon.json';
const FCITX_CONTRACT_SOURCE = '../../../packaging/linux/fcitx5-openburnbar-addon.json';
const FCITX_ADDON_DESTINATION = '/usr/lib/openburnbar/fcitx5/openburnbar-fcitx5.so';
const FCITX_ADDON_SOURCE = 'target/openburnbar-package-payload/fcitx5-addon/openburnbar-fcitx5.so';
const FCITX_MANIFEST_DESTINATION = '/usr/share/openburnbar/text-expansion/text-expansion-engine-fcitx5.json';
const FCITX_MANIFEST_SOURCE = 'target/openburnbar-package-payload/text-expansion-engine-fcitx5.json';

function readJson(root, relativePath) {
  const absolute = path.join(root, relativePath);
  return JSON.parse(fs.readFileSync(absolute, 'utf8'));
}

/**
 * Validate that the packaged native Fcitx5 addon stays exact: real source,
 * real build wiring, signed-manifest binding, the same safety boundary as
 * the IBus engine, and consistent metadata across the capability contract,
 * release manifest, Tauri bundles, and the Arch recipe. This gate prevents
 * runtime support from drifting away from the shipped artifacts, and
 * prevents artifacts from shipping without their consent/safety contract.
 */
export function validateFcitx5AddonContract({ root = DEFAULT_ROOT } = {}) {
  const failures = [];
  const manifest = readJson(root, 'packaging/linux/release-manifest.json');
  const addon = readJson(root, 'packaging/linux/fcitx5-openburnbar-addon.json');
  const tauri = readJson(root, 'apps/linux-desktop/src-tauri/tauri.conf.json');
  const aur = fs.readFileSync(path.join(root, 'packaging/linux/aur/PKGBUILD.in'), 'utf8');

  // Native addon source must exist and preserve the safety boundary in code.
  const addonSource = path.join(root, 'packaging/linux/fcitx5-addon/src/openburnbar-fcitx5.cpp');
  if (!fs.existsSync(addonSource)) {
    failures.push('native Fcitx5 addon source is missing at packaging/linux/fcitx5-addon/src/openburnbar-fcitx5.cpp');
  } else {
    const source = fs.readFileSync(addonSource, 'utf8');
    for (const [marker, why] of [
      ['CapabilityFlag::Password', 'secure-field denial'],
      ['CapabilityFlag::Sensitive', 'sensitive-field denial'],
      ['sawCapabilityMetadata', 'deny-by-default before capability metadata'],
      ['text-expansion-engine-expand', 'daemon-owned expansion path'],
      ['kDaemonTimeoutMs', 'bounded daemon timeout'],
      ['SIGKILL', 'kill-on-timeout']
    ]) {
      if (!source.includes(marker)) failures.push(`Fcitx5 addon source lost its ${why} (${marker})`);
    }
    // Match concrete API usage, not descriptive comments: includes of
    // capture headers or calls into capture entrypoints.
    for (const forbidden of [
      '#include <libevdev',
      '#include <linux/input',
      'XRecordCreateContext',
      'XTestFakeKeyEvent',
      'surroundingText()',
      'clipboard()'
    ]) {
      if (source.includes(forbidden)) failures.push(`Fcitx5 addon source references forbidden capture surface: ${forbidden}`);
    }
  }
  for (const buildFile of [
    'packaging/linux/fcitx5-addon/CMakeLists.txt',
    'packaging/linux/fcitx5-addon/openburnbar-fcitx5-addon.conf',
    'packaging/linux/fcitx5-addon/openburnbar-fcitx5-im.conf',
    'scripts/linux-port/build-fcitx5-addon.sh',
    'packaging/linux/openburnbar-fcitx5-register.sh',
    'packaging/linux/openburnbar-fcitx5-unregister.sh'
  ]) {
    if (!fs.existsSync(path.join(root, buildFile))) failures.push(`missing Fcitx5 packaging file: ${buildFile}`);
  }

  const installPaths = manifest.installPaths ?? {};
  if (installPaths.textExpansionFcitx5Contract !== FCITX_CONTRACT_DESTINATION) {
    failures.push(`release manifest must install the Fcitx5 contract at ${FCITX_CONTRACT_DESTINATION}`);
  }
  if (installPaths.textExpansionFcitx5Addon !== FCITX_ADDON_DESTINATION) {
    failures.push(`release manifest must install the native Fcitx5 addon at ${FCITX_ADDON_DESTINATION}`);
  }
  if (installPaths.textExpansionFcitx5Manifest !== FCITX_MANIFEST_DESTINATION) {
    failures.push(`release manifest must install the signed Fcitx5 engine manifest at ${FCITX_MANIFEST_DESTINATION}`);
  }
  const runtime = manifest.textExpansionRuntime?.fcitx5;
  if (!runtime || runtime.contract !== 'packaging/linux/fcitx5-openburnbar-addon.json') {
    failures.push('release manifest must point textExpansionRuntime.fcitx5.contract at the canonical contract');
  }
  if (runtime?.status !== 'native-addon-packaged'
      || runtime.nativeAddonPath !== FCITX_ADDON_DESTINATION
      || runtime.runtimeSupport !== true
      || runtime.packageSupport !== true) {
    failures.push('release manifest must declare the packaged native Fcitx5 addon exactly');
  }
  if (!Array.isArray(manifest.textExpansionRuntime?.supportedBackends)
      || !manifest.textExpansionRuntime.supportedBackends.includes('fcitx5')
      || !manifest.textExpansionRuntime.supportedBackends.includes('ibus')) {
    failures.push('release manifest must keep IBus supported alongside the Fcitx5 addon');
  }

  const requiredContractFields = {
    schemaVersion: 2,
    backend: 'fcitx5',
    status: 'native-addon-packaged',
    nativeAddonPath: FCITX_ADDON_DESTINATION,
    signedManifestPath: FCITX_MANIFEST_DESTINATION,
    runtimeSupport: true,
    packageSupport: true,
    noGlobalCapture: true,
    readsClipboard: false,
    readsSurroundingText: false,
    consent: 'daemon-enforced-explicit-opt-in',
    secureFieldPolicy: 'deny-unless-inspectable-and-explicitly-nonsecure'
  };
  for (const [field, expected] of Object.entries(requiredContractFields)) {
    if (addon[field] !== expected) failures.push(`Fcitx5 contract ${field} must be ${String(expected)}`);
  }
  if (!Array.isArray(addon.requiredHeaders) || addon.requiredHeaders.length === 0) {
    failures.push('Fcitx5 contract must name the native headers required for its build');
  }
  if (addon.sourceContract !== 'packaging/linux/FCITX5_ADDON_CONTRACT.md'
      || !fs.existsSync(path.join(root, addon.sourceContract ?? ''))) {
    failures.push('Fcitx5 contract must point to the checked-in safety contract documentation');
  }

  for (const packageType of ['deb', 'rpm']) {
    const files = tauri.bundle?.linux?.[packageType]?.files ?? {};
    if (files[FCITX_CONTRACT_DESTINATION] !== FCITX_CONTRACT_SOURCE) {
      failures.push(`${packageType} must package the Fcitx5 capability contract at ${FCITX_CONTRACT_DESTINATION}`);
    }
    if (files[FCITX_ADDON_DESTINATION] !== FCITX_ADDON_SOURCE) {
      failures.push(`${packageType} must package the native Fcitx5 addon at ${FCITX_ADDON_DESTINATION}`);
    }
    if (files[FCITX_MANIFEST_DESTINATION] !== FCITX_MANIFEST_SOURCE) {
      failures.push(`${packageType} must package the signed Fcitx5 engine manifest at ${FCITX_MANIFEST_DESTINATION}`);
    }
  }
  // AppImage keeps the capability contract for diagnostics but must NOT claim
  // system Fcitx5 registration: a transient mount path cannot satisfy the
  // manifest's signed path identity (same rule as the IBus engine).
  const appimageFiles = tauri.bundle?.linux?.appimage?.files ?? {};
  if (appimageFiles[FCITX_CONTRACT_DESTINATION] !== FCITX_CONTRACT_SOURCE) {
    failures.push('appimage must keep the Fcitx5 capability contract for diagnostics');
  }
  if (appimageFiles[FCITX_ADDON_DESTINATION]) {
    failures.push('appimage must not claim system Fcitx5 addon registration from a transient mount');
  }

  for (const marker of [
    FCITX_CONTRACT_DESTINATION.replace(/^\//u, ''),
    'usr/lib/openburnbar/fcitx5/openburnbar-fcitx5.so',
    'usr/share/openburnbar/text-expansion/text-expansion-engine-fcitx5.json',
    'fcitx5: enables the packaged OpenBurnBar Fcitx5 text-expansion addon'
  ]) {
    if (!aur.includes(marker)) failures.push(`Arch recipe must carry the packaged Fcitx5 addon: ${marker}`);
  }
  if (aur.includes('source-only and unavailable')) {
    failures.push('Arch recipe contains stale source-only Fcitx5 wording');
  }

  return failures;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  try {
    const failures = validateFcitx5AddonContract();
    const report = { passed: failures.length === 0, failures };
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    process.exitCode = failures.length === 0 ? 0 : 1;
  } catch (error) {
    process.stderr.write(`validate-fcitx5-addon-source: ${error.message}\n`);
    process.exitCode = 1;
  }
}
