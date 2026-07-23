#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = path.resolve(SCRIPT_DIR, '../..');
const FCITX_CONTRACT_DESTINATION = '/usr/share/openburnbar/text-expansion/fcitx5-openburnbar-addon.json';
const FCITX_CONTRACT_SOURCE = '../../../packaging/linux/fcitx5-openburnbar-addon.json';

function readJson(root, relativePath) {
  const absolute = path.join(root, relativePath);
  return JSON.parse(fs.readFileSync(absolute, 'utf8'));
}

/**
 * Validate that Fcitx5 remains an explicit source-only capability until a
 * signed native addon exists. This gate prevents package metadata from
 * accidentally promoting the host's fcitx5 installation to product support.
 */
export function validateFcitx5AddonContract({ root = DEFAULT_ROOT } = {}) {
  const failures = [];
  const manifest = readJson(root, 'packaging/linux/release-manifest.json');
  const addon = readJson(root, 'packaging/linux/fcitx5-openburnbar-addon.json');
  const tauri = readJson(root, 'apps/linux-desktop/src-tauri/tauri.conf.json');
  const aur = fs.readFileSync(path.join(root, 'packaging/linux/aur/PKGBUILD.in'), 'utf8');

  const installPath = manifest.installPaths?.textExpansionFcitx5Contract;
  if (installPath !== FCITX_CONTRACT_DESTINATION) {
    failures.push(`release manifest must install the Fcitx5 contract at ${FCITX_CONTRACT_DESTINATION}`);
  }
  const runtime = manifest.textExpansionRuntime?.fcitx5;
  if (!runtime || runtime.contract !== 'packaging/linux/fcitx5-openburnbar-addon.json') {
    failures.push('release manifest must point textExpansionRuntime.fcitx5.contract at the canonical contract');
  }
  if (runtime?.status !== 'source-only-not-packaged'
      || runtime.nativeAddonPath !== null
      || runtime.runtimeSupport !== false
      || runtime.packageSupport !== false) {
    failures.push('release manifest must keep Fcitx5 source-only and unavailable');
  }

  const requiredContractFields = {
    schemaVersion: 1,
    backend: 'fcitx5',
    status: 'source-only-not-packaged',
    nativeAddonPath: null,
    runtimeSupport: false,
    packageSupport: false,
    noGlobalCapture: true,
    readsClipboard: false,
    readsSurroundingText: false,
    secureFieldPolicy: 'deny-unless-inspectable-and-explicitly-nonsecure'
  };
  for (const [field, expected] of Object.entries(requiredContractFields)) {
    if (addon[field] !== expected) failures.push(`Fcitx5 contract ${field} must remain ${String(expected)}`);
  }
  if (!Array.isArray(addon.requiredHeaders) || addon.requiredHeaders.length === 0) {
    failures.push('Fcitx5 contract must name the native headers needed for a future build');
  }
  if (addon.sourceContract !== 'packaging/linux/FCITX5_ADDON_CONTRACT.md'
      || !fs.existsSync(path.join(root, addon.sourceContract ?? ''))) {
    failures.push('Fcitx5 contract must point to the checked-in safety contract documentation');
  }
  if (!addon.promotionBlocker) failures.push('Fcitx5 contract must name its promotion blocker');

  for (const packageType of ['deb', 'rpm', 'appimage']) {
    const files = tauri.bundle?.linux?.[packageType]?.files ?? {};
    if (files[FCITX_CONTRACT_DESTINATION] !== FCITX_CONTRACT_SOURCE) {
      failures.push(`${packageType} must package the source-only Fcitx5 contract at ${FCITX_CONTRACT_DESTINATION}`);
    }
  }
  for (const marker of [
    FCITX_CONTRACT_DESTINATION,
    'fcitx5: input-method host (OpenBurnBar Fcitx5 addon is source-only and unavailable)',
    'usr/share/openburnbar/text-expansion/fcitx5-openburnbar-addon.json'
  ]) {
    if (!aur.includes(marker)) failures.push(`Arch recipe must preserve Fcitx5 source-only marker: ${marker}`);
  }
  if (aur.includes('native OpenBurnBar addon not yet packaged')) {
    failures.push('Arch recipe contains stale Fcitx5 wording');
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
