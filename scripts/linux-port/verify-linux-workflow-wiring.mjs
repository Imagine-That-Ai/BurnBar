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
  for (const marker of [
    'architecture: aarch64',
    'runner: ubuntu-24.04-arm',
    'architecture: x86_64',
    'runner: ubuntu-24.04',
    '--architecture-shard',
    '--phase prepare',
    'Materialize exact-commit isolated signer',
    '--network none',
    '--read-only',
    '--cap-drop ALL',
    '--security-opt no-new-privileges',
    'sign-linux-release-requests.mjs',
    '--phase finalize',
    'previous_version',
    'linux-desktop-session.sh',
    'verify-linux-package-update-rollback.sh',
    'finalize-linux-architecture-session.mjs',
    'linux-release-shard-${{ matrix.architecture }}',
    'assemble-linux-release.mjs',
    'merge-multiple: false',
    "-o -name 'latest-linux.json'",
    'OPENBURNBAR_R2_CUSTOM_DOMAIN: downloads.burnbar.ai',
    'upload-linux-downloads-r2.sh',
    'https://downloads.burnbar.ai/latest-linux.json'
  ]) requireText(input.release, marker, 'two-architecture release closure');
  requireText(input.pr, 'bash scripts/linux-port/run-linux-native-tests.sh', 'PR native behavior gate');
  requireText(input.pr, 'verify-linux-release.test.mjs', 'PR release mutation suite');
  requireText(input.pr, 'assemble-linux-release.test.mjs', 'PR architecture assembly mutation suite');
  requireText(input.pr, 'linux-package-session.test.mjs', 'PR package lifecycle session suite');
  requireText(input.pr, 'linux-installed-manifest.test.mjs', 'PR installed manifest mutation suite');
  requireText(input.pr, 'linux-appimage-peer-manifest.test.mjs', 'PR AppImage peer manifest suite');
  requireText(input.pr, 'linux-native-package-real-tools.test.mjs', 'PR real native package suite');
  requireText(input.pr, 'sign-linux-release-requests.test.mjs', 'PR isolated signer mutation suite');
  requireText(
    input.pr,
    'scripts/linux-port/browser-runtime-packaging.test.mjs',
    'PR Browser Computer Use package runtime suite'
  );
  requireText(
    input.pr,
    'scripts/linux-port/aur-browser-runtime-packaging.test.mjs',
    'PR AUR Browser Computer Use package runtime suite'
  );
  requireText(
    input.pr,
    'scripts/linux-port/embed-linux-appimage-payload.test.mjs',
    'PR AppImage Browser Computer Use payload suite'
  );
  requireText(input.pr, 'render-parity-ledger.mjs --check', 'PR Markdown drift gate');
  for (const command of [
    'npm ci --prefix scripts/linux-port --ignore-scripts',
    'attest-product-requirement.test.mjs',
    'github-artifact-provenance.test.mjs',
    'live-installed-product-evidence.test.mjs',
    'run-linux-matrix-harness.test.mjs',
    'run-product-requirement-validator.test.mjs',
    'resolve-product-evidence-run.test.mjs'
  ]) requireText(input.pr, command, 'PR product evidence gate');
  for (const marker of [
    'id-token: write',
    'attestations: write',
    'artifact-metadata: write',
    'ref: ${{ github.sha }}',
    'resolve-product-evidence-run.mjs',
    'RELEASE_RUN_ID: ${{ inputs.release_run_id }}',
    'TARGET_HEAD: ${{ github.sha }}',
    '--run-id "$RELEASE_RUN_ID"',
    '--target-head "$TARGET_HEAD"',
    'artifact-ids: ${{ steps.evidence.outputs.artifact_id }}',
    'run-product-requirement-validator.mjs',
    'uses: actions/attest@',
    '.sigstore.jsonl',
    'if-no-files-found: error'
  ]) requireText(input.productParityWorkflow, marker, 'product parity evidence workflow');
  if (/--run-id\s+['"]?\$\{\{\s*inputs\.release_run_id/u.test(input.productParityWorkflow)) {
    failures.push('product parity workflow may not interpolate release_run_id directly into shell.');
  }
  for (const marker of [
    'npm ci --prefix scripts/linux-port --ignore-scripts',
    'Generate current-HEAD product parity attestations',
    'attest-product-requirement.mjs --requirement "P-${number}"'
  ]) requireText(input.release, marker, 'release product evidence generation');
  for (const command of [
    'macos-matched-performance',
    'run-matched-performance.mjs',
    '--profile pr',
    'matched-performance-contract.test.mjs',
    'perf-budget-contract.test.mjs',
    'linux-parity-macos-performance-pr'
  ]) requireText(input.pr, command, 'PR matched performance gate');
  for (const command of [
    'macos-matched-performance',
    'linux-matched-performance',
    '--profile nightly',
    'OB_MATCHED_MACOS_INPUT',
    'OB_MATCHED_LINUX_INPUT',
    'linux-parity-matched-performance-nightly'
  ]) requireText(input.nightly, command, 'nightly matched performance gate');
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
    'PINNED_PUBLIC_KEY_SPKI_SHA256',
    'verify_strict',
    'validate_update_artifact_url',
    'allowed_download_url',
    'MAX_FEED_BYTES'
  ]) requireText(input.updateFeed, command, 'native signed update boundary');
  for (const command of [
    "invoke<boolean>('gateway_probe')",
    "invoke<void>('gateway_chat_stream'",
    "invoke<void>('gateway_chat_cancel'",
    "invoke<void>('open_external_url'",
    "invoke<RawJsonValue>('update_status')",
    "invoke<void>('open_update_url'"
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
    'Resolve and validate Linux release version',
    'Assert native runner architecture',
    'Prepare unsigned native architecture artifacts',
    'Materialize exact-commit isolated signer',
    'Sign exact native requests in isolated container',
    'Finalize and verify signed native architecture artifacts',
    'Native package inspection/install/uninstall smoke',
    'Run package-owned desktop, daemon, accessibility, tray, and route session',
    'Verify native package update, rollback, and data preservation',
    'Finalize commit-bound architecture session',
    'Download native architecture shards',
    'Generate current-HEAD product parity attestations',
    'Verify product parity at release HEAD',
    'Assemble signed two-architecture closure and feed',
    'Pre-attestation Linux release verification',
    'Attest Linux release sidecars and packages',
    'Final Linux release verification',
    'Publish Linux GitHub release',
    'Configure branded Linux update origin',
    'Publish signed update feed to downloads origin',
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
  if (/matched performance[\s\S]{0,300}continue-on-error:\s*true/i.test(input.pr + input.nightly)) {
    failures.push('matched performance gates may not continue on error.');
  }
  if (/\#\[tauri::command\][\s\S]{0,120}fn\s+gateway_auth_token/.test(input.rustBridge)) {
    failures.push('a Tauri command may not return the gateway bearer token to the renderer.');
  }
  for (const [forbidden, pattern] of [
    ['gatewayAuthToken', /gatewayAuthToken/],
    ['bearerToken', /bearerToken/],
    ['Authorization', /\bAuthorization\b/]
  ]) {
    if (pattern.test(input.rendererBridge)) {
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
    productParityWorkflow: read('.github/workflows/linux-product-parity.yml'),
    nightly: read('.github/workflows/linux-nightly.yml'),
    release: read('.github/workflows/linux-release.yml'),
    makefile: read('Makefile'),
    nativeTests: read('scripts/linux-port/run-linux-native-tests.sh'),
    rustBridge: read('apps/linux-desktop/src-tauri/src/lib.rs'),
    updateFeed: read('apps/linux-desktop/src-tauri/src/update_feed.rs'),
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
