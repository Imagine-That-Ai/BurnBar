#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  resolveIrohNativeLibrary,
  resolveLinuxResourceBundles,
  resolveSqlcipherLibDir,
  resolveSwiftRuntimeDir,
  stageLinuxPackagePayload,
  validateLinuxPackagePayload
} from './lib/linux-package-payload.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const daemonBinary = process.env.OPENBURNBAR_LINUX_DAEMON_BIN?.trim()
  || path.join(repoRoot, 'OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon');
const cliBinary = process.env.OPENBURNBAR_LINUX_CLI_BIN?.trim()
  || path.join(repoRoot, 'OpenBurnBarDaemon/.build/release/OpenBurnBarCLI');
const playwrightBridge = path.join(
  repoRoot,
  'OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js'
);
const browserRuntimeProbe = path.join(
  repoRoot,
  'packaging/linux/openburnbar-browser-runtime-probe'
);
const browserRuntimeRequirements = path.join(
  repoRoot,
  'packaging/linux/browser-runtime-requirements.json'
);
const releasePublicKey = path.join(
  repoRoot,
  'packaging/linux/openburnbar-linux-ed25519.pub.pem'
);
const textExpansionManifest = process.env.OPENBURNBAR_LINUX_TEXT_EXPANSION_SIGNED_MANIFEST?.trim()
  || path.join(repoRoot, '.linux-trust/text-expansion-engine.json');
const fcitx5AddonDir = process.env.OPENBURNBAR_FCITX5_ADDON_OUT?.trim()
  || path.join(repoRoot, 'apps/linux-desktop/src-tauri/target/openburnbar-fcitx5-addon');
const fcitx5Manifest = process.env.OPENBURNBAR_LINUX_TEXT_EXPANSION_SIGNED_MANIFEST_FCITX5?.trim()
  || path.join(repoRoot, '.linux-trust/text-expansion-engine-fcitx5.json');
const payloadRoot = process.env.OPENBURNBAR_LINUX_PACKAGE_PAYLOAD?.trim()
  || path.join(repoRoot, 'apps/linux-desktop/src-tauri/target/openburnbar-package-payload');

try {
  const reuseStagedPayload = process.env.OPENBURNBAR_LINUX_REUSE_STAGED_PAYLOAD === '1';
  if (reuseStagedPayload && process.env.OPENBURNBAR_LINUX_RELEASE_BUILD === '1') {
    throw new Error(
      'OPENBURNBAR_LINUX_REUSE_STAGED_PAYLOAD is forbidden for release builds; stage fresh architecture inputs'
    );
  }
  const report = reuseStagedPayload
    ? validateLinuxPackagePayload({ payloadRoot })
    : stageLinuxPackagePayload({
      daemonBinary,
      cliBinary,
      playwrightBridge,
      browserRuntimeProbe,
      browserRuntimeRequirements,
      releasePublicKey,
      textExpansionManifest,
      fcitx5AddonDir,
      fcitx5Manifest,
      resourceBundles: resolveLinuxResourceBundles({ repoRoot }),
      payloadRoot,
      swiftRuntimeDir: resolveSwiftRuntimeDir(),
      sqlcipherLibDir: resolveSqlcipherLibDir(),
      irohNativeLibrary: resolveIrohNativeLibrary()
    });
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  console.error(`prepare-linux-package-payload: ${error.message}`);
  process.exit(1);
}
