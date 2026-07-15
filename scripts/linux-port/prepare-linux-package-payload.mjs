#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  resolveIrohNativeLibrary,
  resolveLinuxResourceBundle,
  resolveSqlcipherLibDir,
  resolveSwiftRuntimeDir,
  stageLinuxPackagePayload
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
const payloadRoot = process.env.OPENBURNBAR_LINUX_PACKAGE_PAYLOAD?.trim()
  || path.join(repoRoot, 'apps/linux-desktop/src-tauri/target/openburnbar-package-payload');

try {
  const report = stageLinuxPackagePayload({
    daemonBinary,
    cliBinary,
    playwrightBridge,
    browserRuntimeProbe,
    browserRuntimeRequirements,
    releasePublicKey,
    resourceBundle: resolveLinuxResourceBundle({ repoRoot }),
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
