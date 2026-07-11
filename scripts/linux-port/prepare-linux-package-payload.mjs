#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  resolveSqlcipherLibDir,
  resolveSwiftRuntimeDir,
  stageLinuxPackagePayload
} from './lib/linux-package-payload.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const daemonBinary = process.env.OPENBURNBAR_LINUX_DAEMON_BIN?.trim()
  || path.join(repoRoot, 'OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon');
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
const payloadRoot = process.env.OPENBURNBAR_LINUX_PACKAGE_PAYLOAD?.trim()
  || path.join(repoRoot, 'apps/linux-desktop/src-tauri/target/openburnbar-package-payload');

try {
  const report = stageLinuxPackagePayload({
    daemonBinary,
    playwrightBridge,
    browserRuntimeProbe,
    browserRuntimeRequirements,
    payloadRoot,
    swiftRuntimeDir: resolveSwiftRuntimeDir(),
    sqlcipherLibDir: resolveSqlcipherLibDir()
  });
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  console.error(`prepare-linux-package-payload: ${error.message}`);
  process.exit(1);
}
