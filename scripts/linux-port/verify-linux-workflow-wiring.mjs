#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { repoRoot } from './lib/linux-release-common.mjs';

export function verifyLinuxWorkflowWiring(input) {
  const failures = [];
  const requireText = (body, needle, label) => {
    if (!body.includes(needle)) failures.push(`${label} is missing: ${needle}`);
  };
  const requireOrder = (body, labels, source) => {
    let previous = -1;
    for (const label of labels) {
      const index = body.indexOf(label);
      if (index < 0) failures.push(`${source} is missing ordered step: ${label}`);
      else if (index <= previous) failures.push(`${source} step is out of order: ${label}`);
      previous = Math.max(previous, index);
    }
  };

  requireText(input.release, '- "linux-v*"', 'release tag trigger');
  if (input.release.includes('- "v*"')) failures.push('legacy v* tag trigger is forbidden in the Linux release workflow.');
  requireText(input.release, 'resolve-linux-release-version.mjs --github-output', 'release version resolver');
  requireText(input.release, 'OPENBURNBAR_LINUX_RELEASE_OUT', 'canonical release output');
  requireText(input.release, 'OPENBURNBAR_LINUX_EVIDENCE_OUT', 'canonical evidence output');
  requireText(input.release, "'*.sigstore.json'", 'published Sigstore bundles');
  requireText(input.release, "'*source-*.tar'", 'published source archive');
  requireText(input.release, "'*parity-attestation.json'", 'published parity attestation');
  requireText(input.pr, 'bash scripts/linux-port/run-linux-native-tests.sh', 'PR native behavior gate');
  requireText(input.pr, 'verify-linux-release.test.mjs', 'PR release mutation suite');
  requireText(input.pr, 'render-parity-ledger.mjs --check', 'PR Markdown drift gate');
  for (const command of [
    'run_swift_suite',
    'OpenBurnBarLinuxCoreFoundationTests',
    'OpenBurnBarLinuxSecurityTests',
    'OpenBurnBarDaemonLinuxGatewayTests',
    'timeout 900 swift test',
    'run_xctest_case',
    'Executed 1 test',
    'cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked'
  ]) requireText(input.nativeTests, command, 'native test runner');
  for (const command of [
    'gateway_probe',
    'gateway_chat_stream',
    'gateway_chat_cancel',
    '.bearer_auth(token)',
    'gateway_non_loopback_host_refused',
    'Policy::none()'
  ]) requireText(input.rustBridge, command, 'native gateway credential boundary');
  for (const command of [
    'validate_external_url',
    'open_external_url',
    'external_url_host_refused',
    'trusted_openburnbar_cli',
    '/usr/bin/openburnbar-cli'
  ]) requireText(input.rustBridge, command, 'native external URL boundary');
  for (const command of [
    'runtime_capabilities',
    'RUNTIME_CAPABILITY_CATALOG',
    'runtime_capability_unknown_evaluator'
  ]) requireText(input.rustBridge, command, 'native runtime capability contract');
  for (const command of [
    "invoke<boolean>('gateway_probe')",
    "invoke<void>('gateway_chat_stream'",
    "invoke<void>('gateway_chat_cancel'",
    "invoke<void>('open_external_url'"
  ]) requireText(input.rendererBridge, command, 'renderer native gateway bridge');
  for (const command of [
    "invoke<RawJsonValue>('runtime_capabilities')",
    'decodeRuntimeCapabilityManifest',
    'runtime_capability_manifest_missing_ids'
  ]) requireText(input.rendererBridge, command, 'renderer runtime capability contract');
  for (const command of ['requiredCapability', 'usage.read', 'media.mercury']) {
    requireText(input.routes, command, 'route capability mapping');
  }
  for (const command of ['capabilityBlocksSurface', 'findRuntimeCapability', 'capabilityError']) {
    requireText(input.surfaceBoundary, command, 'surface capability boundary');
  }
  requireText(input.runtimeCatalog, '"schemaVersion": 1', 'runtime capability catalog');
  requireText(input.runtimeSchema, '"additionalProperties": false', 'runtime capability schema');
  requireText(input.capability, '"core:default"', 'Tauri capability');
  requireText(input.fixturePolicy, 'DAEMON_FIXTURE_AVAILABLE', 'production fixture policy');
  requireText(input.fixturePolicy, "enabled && DAEMON_FIXTURE_AVAILABLE", 'fixture state guard');
  requireText(input.desktopPackage, 'verify-linux-production-bundle.mjs', 'production bundle gate');

  requireOrder(input.release, [
    'Verify product parity at release HEAD',
    'Build Linux release artifacts',
    'Package install/uninstall/update smoke',
    'Pre-attestation Linux release verification',
    'Attest Linux release sidecars and packages',
    'Final Linux release verification',
    'Publish Linux GitHub prerelease',
    'Verify live Linux update feed after publish'
  ], 'release workflow');

  if (/verify-linux-release\.mjs[^\n]*--allow-blocked/.test(input.release)) {
    failures.push('release verification may not use --allow-blocked.');
  }
  if (/continue-on-error:\s*true[\s\S]{0,200}(parity|signature|release verification)/i.test(input.release)) {
    failures.push('release integrity steps may not continue on error.');
  }
  if (/openburnbar-linux-ed25519\.pub\.pem[^\n]*\|\|\s*true/.test(input.release)) {
    failures.push('release public-key publication may not swallow copy failures.');
  }
  if (input.pr.includes('mission-001-release') || input.nightly.includes('mission-001-release')) {
    failures.push('PR/nightly workflows may not write or upload sealed mission-001 evidence.');
  }
  if (/\#\[tauri::command\][\s\S]{0,120}fn\s+gateway_auth_token/.test(input.rustBridge)) {
    failures.push('a Tauri command may not return the gateway bearer token to the renderer.');
  }
  for (const forbidden of ['gatewayAuthToken', 'bearerToken', 'Authorization']) {
    if (input.rendererBridge.includes(forbidden)) {
      failures.push(`renderer gateway code may not contain credential surface: ${forbidden}`);
    }
  }
  for (const forbidden of ['shell:default', 'shell:allow-execute', 'shell:allow-spawn']) {
    if (input.capability.includes(forbidden)) {
      failures.push(`Tauri WebView capability may not grant generic process access: ${forbidden}`);
    }
  }
  if (/connect-src[^;]*(?:https?:\/\/|wss?:\/\/)/.test(input.tauriConfig)) {
    failures.push('renderer CSP may not grant direct HTTP or WebSocket network access.');
  }
  if (/\bfetch\s*\(/.test(input.rendererBridge)) {
    failures.push('renderer gateway code may not issue direct network requests.');
  }
  if (input.rustBridge.includes('Command::new("openburnbar-cli")')) {
    failures.push('native commands may not resolve openburnbar-cli through ambient PATH.');
  }
  const releaseTarget = input.makefile.split('release-linux:')[1]?.split('\n\n')[0] ?? '';
  if (releaseTarget.includes('|| true')) failures.push('release-linux Make target may not swallow failures.');

  return { passed: failures.length === 0, failures };
}

function main() {
  const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');
  const result = verifyLinuxWorkflowWiring({
    pr: read('.github/workflows/linux-pr-gate.yml'),
    nightly: read('.github/workflows/linux-nightly.yml'),
    release: read('.github/workflows/linux-release.yml'),
    makefile: read('Makefile'),
    nativeTests: read('scripts/linux-port/run-linux-native-tests.sh'),
    rustBridge: read('apps/linux-desktop/src-tauri/src/lib.rs'),
    capability: read('apps/linux-desktop/src-tauri/capabilities/default.json'),
    tauriConfig: read('apps/linux-desktop/src-tauri/tauri.conf.json'),
    fixturePolicy: [
      read('apps/linux-desktop/src/daemonFixture.ts'),
      read('apps/linux-desktop/src/state/shellStore.ts'),
      read('apps/linux-desktop/src/surfaces/support/SupportSurface.tsx')
    ].join('\n'),
    desktopPackage: read('apps/linux-desktop/package.json'),
    runtimeCatalog: read('packaging/linux/runtime-capability-catalog.json'),
    runtimeSchema: read('schemas/linux-runtime-capability-manifest.schema.json'),
    routes: read('apps/linux-desktop/src/routes.ts'),
    surfaceBoundary: read('apps/linux-desktop/src/surfaces/SurfaceRouter.tsx'),
    rendererBridge: [
      read('apps/linux-desktop/src/tauriBridge.ts'),
      read('apps/linux-desktop/src/runtimeCapabilities.ts'),
      read('apps/linux-desktop/src/state/chatStore.ts'),
      read('apps/linux-desktop/src/chat/gatewayClient.ts')
    ].join('\n')
  });
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.passed ? 0 : 1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
