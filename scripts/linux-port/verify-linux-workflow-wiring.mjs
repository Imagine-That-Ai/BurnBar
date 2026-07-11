#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse as parseYaml } from 'yaml';
import { repoRoot } from './lib/linux-release-common.mjs';

function verifyReleaseTransactionStructure(source, failures) {
  let workflow;
  try {
    workflow = parseYaml(source);
  } catch (error) {
    failures.push(`release workflow YAML is invalid: ${error.message}`);
    return;
  }
  const steps = workflow?.jobs?.['assemble-release']?.steps;
  if (!Array.isArray(steps)) {
    failures.push('release workflow assemble-release steps are missing.');
    return;
  }
  const byId = new Map(steps.filter((step) => typeof step?.id === 'string').map((step) => [step.id, step]));
  const transactionIds = [
    'activate_repository',
    'deploy_repository_routes',
    'verify_public_repository',
    'verify_public_lifecycle',
    'drill_repository_rollback',
    'publish_feed_pointer',
    'deploy_feed_routes',
    'verify_public_feed',
    'verify_live_feed',
    'attest_repository_publication',
    'publish_github_release'
  ];
  for (const id of [...transactionIds, 'cleanup_github_release', 'compensate_repository_publication']) {
    if (!byId.has(id)) failures.push(`release transaction step id is missing: ${id}`);
  }
  const expectedPredecessor = new Map([
    ['verify_public_repository', 'deploy_repository_routes'],
    ['verify_public_lifecycle', 'verify_public_repository'],
    ['drill_repository_rollback', 'verify_public_lifecycle'],
    ['publish_feed_pointer', 'drill_repository_rollback'],
    ['deploy_feed_routes', 'publish_feed_pointer'],
    ['verify_public_feed', 'deploy_feed_routes'],
    ['verify_live_feed', 'verify_public_feed'],
    ['attest_repository_publication', 'verify_live_feed'],
    ['publish_github_release', 'attest_repository_publication']
  ]);
  for (const [id, predecessor] of expectedPredecessor) {
    const condition = String(byId.get(id)?.if ?? '');
    if (!condition.includes(`steps.${predecessor}.outcome == 'success'`)) {
      failures.push(`release transaction step ${id} is not structurally gated by ${predecessor}.`);
    }
  }
  for (const id of transactionIds.slice(1)) {
    if (byId.get(id)?.['continue-on-error'] !== true) {
      failures.push(`release transaction step ${id} must continue only to the compensation gate.`);
    }
  }
  const cleanup = byId.get('cleanup_github_release');
  if (!String(cleanup?.if ?? '').includes("steps.publish_github_release.outcome == 'failure'")) {
    failures.push('GitHub release cleanup is not structurally gated by publication failure.');
  }
  const compensation = byId.get('compensate_repository_publication');
  const compensationCondition = String(compensation?.if ?? '');
  if (!compensationCondition.includes('always()') || compensation?.['continue-on-error'] !== true) {
    failures.push('repository compensation must run under always() and preserve the final enforcement step.');
  }
  for (const id of transactionIds.slice(1)) {
    if (!compensationCondition.includes(`steps.${id}.outcome != 'success'`)) {
      failures.push(`repository compensation condition omits transaction step: ${id}`);
    }
  }
  const finalGate = steps.find((step) => step?.name === 'Enforce atomic repository publication outcome');
  const finalRun = String(finalGate?.run ?? '');
  if (!String(finalGate?.if ?? '').includes('always()')
      || !finalRun.includes('steps.cleanup_github_release.outcome')
      || !finalRun.includes('receipt.passed !== true || receipt.contained !== true')) {
    failures.push('final repository publication gate is not structurally bound to cleanup and compensation proof.');
  }
}

export function verifyLinuxWorkflowWiring(input) {
  const failures = [];
  verifyReleaseTransactionStructure(input.releaseYaml ?? input.release, failures);
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
    '--prepare-only',
    '--private-key-stdin',
    '--finalize-only',
    'previous_version',
    'linux-desktop-session.sh',
    'verify-linux-package-update-rollback.sh',
    'finalize-linux-architecture-session.mjs',
    'linux-release-shard-${{ matrix.architecture }}',
    'assemble-linux-release.mjs',
    'merge-multiple: false',
    "-o -name 'latest-linux.json'",
    'OPENBURNBAR_R2_CUSTOM_DOMAIN: downloads.burnbar.ai',
    'group: linux-repository-release',
    'setup-linux-downloads-r2.sh',
    'upload-linux-downloads-r2.sh',
    'activate-linux-repository.mjs',
    'OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN',
    'OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN',
    'verify-linux-public-repository.mjs',
    'OPENBURNBAR_LINUX_REPOSITORY_PUBLIC_BASE_URL',
    'drill-linux-repository-rollback.mjs',
    'compensate-linux-repository-activation.mjs',
    'publish-linux-update-feed-r2.sh',
    'repository-feed-verification.json',
    'linux-repository-publication/v1',
    'gh release create "$tag" --draft',
    'OpenBurnBar-Release-Run:',
    'Linux release asset basenames are not unique',
    'GitHub release assets do not match the exact local byte closure',
    'verify_release_assets draft',
    'verify_release_assets published',
    'OPENBURNBAR_LINUX_REPOSITORY_FEED_VERIFICATION_RECEIPT',
    'steps.cleanup_github_release.outcome',
    'cleanup-linux-github-release.mjs',
    "steps.activate_repository.outcome != 'skipped'",
    'Enforce atomic repository publication outcome',
    'https://downloads.burnbar.ai/latest-linux.json',
    'https://downloads.burnbar.ai/linux/update/$channel/latest-linux.json'
  ]) requireText(input.release, marker, 'two-architecture release closure');
  requireText(input.release, 'unset OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM', 'signer environment scrub');
  for (const marker of [
    'vars.OPENBURNBAR_LINUX_FIREBASE_APP_ID',
    'vars.APP_CHECK_STANDARD_WEB_APP_IDS',
    '${OPENBURNBAR_LINUX_FIREBASE_APP_ID:?',
    '${APP_CHECK_STANDARD_WEB_APP_IDS:?',
    '-e OPENBURNBAR_LINUX_FIREBASE_APP_ID',
    '-e APP_CHECK_STANDARD_WEB_APP_IDS'
  ]) requireText(input.release, marker, 'dedicated Linux Firebase release identity');
  const privateKeyStdinUses = input.release.match(/--private-key-stdin/g)?.length ?? 0;
  if (privateKeyStdinUses < 2) {
    failures.push('both native-package and aggregate release signers must use --private-key-stdin.');
  }
  const aggregateStart = input.release.indexOf('Assemble signed two-architecture closure and feed');
  const aggregateEnd = input.release.indexOf('Pre-attestation Linux release verification', aggregateStart + 1);
  const aggregateSigner = aggregateStart >= 0 && aggregateEnd > aggregateStart
    ? input.release.slice(aggregateStart, aggregateEnd)
    : '';
  for (const marker of [
    'unset OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM',
    'printf',
    'assemble-linux-release.mjs',
    '--private-key-stdin'
  ]) requireText(aggregateSigner, marker, 'aggregate signer custody');
  requireText(input.pr, 'bash scripts/linux-port/run-linux-native-tests.sh', 'PR native behavior gate');
  requireText(input.pr, 'crates/openburnbar-attestd/**', 'PR attestation broker path trigger');
  requireText(input.pr, 'schemas/linux-attestation-*', 'PR attestation schema path trigger');
  requireText(input.pr, 'tests/fixtures/linux-attestation/**', 'PR attestation fixture path trigger');
  requireText(input.pr, 'linux-attestation-contract.test.mjs', 'PR attestation schema contract suite');
  requireText(input.pr, 'verify-linux-release.test.mjs', 'PR release mutation suite');
  requireText(input.pr, 'assemble-linux-release.test.mjs', 'PR architecture assembly mutation suite');
  requireText(input.pr, 'build-linux-release-boundary.test.mjs', 'PR release phase-boundary suite');
  requireText(input.pr, 'build-native-linux-packages-boundary.test.mjs', 'PR native signer custody suite');
  requireText(input.pr, 'linux-package-session.test.mjs', 'PR package lifecycle session suite');
  requireText(input.pr, 'linux-native-signing-receipt.test.mjs', 'PR signed package receipt suite');
  for (const marker of [
    'workers/linux-repository-router/**',
    'workers/linux-repository-router/package-lock.json',
    'workers/linux-repository-router/wrangler-upload.jsonc',
    'workers/linux-repository-router/wrangler-control.jsonc',
    'workers/linux-repository-router/wrangler-feed.jsonc',
    'setup-linux-downloads-r2.test.mjs',
    'activate-linux-repository.test.mjs',
    'drill-linux-repository-rollback.test.mjs',
    'compensate-linux-repository-activation.test.mjs',
    'cleanup-linux-github-release.test.mjs',
    'verify-linux-public-repository.test.mjs',
    'publish-linux-update-feed-r2.test.mjs',
    'npm test --prefix workers/linux-repository-router',
    'wrangler deploy',
    '--dry-run'
  ]) requireText(input.pr, marker, 'PR repository activation gate');
  requireText(input.pr, 'render-parity-ledger.mjs --check', 'PR Markdown drift gate');
  requireText(input.pr, 'npm ci --prefix scripts/linux-port --ignore-scripts', 'PR Linux docs tool install');
  requireText(input.nightly, 'npm ci --prefix scripts/linux-port --ignore-scripts', 'nightly Linux docs tool install');
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
    'cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked',
    'RUSTUP_TOOLCHAIN=1.94.0',
    'cargo test --manifest-path crates/openburnbar-attestd/Cargo.toml --locked',
    'cargo clippy --manifest-path crates/openburnbar-attestd/Cargo.toml'
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
    'Build unsigned native architecture inputs',
    'Sign installed manifests and build native packages',
    'Finalize native architecture artifacts without signing key',
    'Native package inspection/install/uninstall smoke',
    'Run package-owned desktop, daemon, accessibility, tray, and route session',
    'Verify native package update, rollback, and data preservation',
    'Finalize commit-bound architecture session',
    'Download native architecture shards',
    'Verify product parity at release HEAD',
    'Assemble signed two-architecture closure and feed',
    'Pre-attestation Linux release verification',
    'Attest Linux release sidecars and packages',
    'Final Linux release verification',
    'Provision branded Linux repository storage',
    'Publish immutable Linux release and repository snapshot',
    'Verify exact snapshot apt and dnf lifecycle before activation',
    'Atomically activate Linux repository snapshot',
    'Deploy branded Linux repository serving routes',
    'Verify active public Linux repository bytes',
    'Verify clean public apt and dnf repository lifecycle',
    'Drill repository rollback and candidate reactivation',
    'Atomically publish signed update feed pointer',
    'Deploy branded Linux update feed routes',
    'Verify signed update feed pointer and public bytes',
    'Verify live Linux update feed after publish',
    'Preserve and attest repository publication evidence',
    'Publish Linux GitHub release',
    'Remove partial draft GitHub release',
    'Compensate failed repository publication',
    'Enforce atomic repository publication outcome'
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
  const uploadIndex = input.release.indexOf('Publish immutable Linux release and repository snapshot');
  const previewIndex = input.release.indexOf('Verify exact snapshot apt and dnf lifecycle before activation');
  const activationIndex = input.release.indexOf('Atomically activate Linux repository snapshot');
  const servingIndex = input.release.indexOf('Deploy branded Linux repository serving routes');
  const feedIndex = input.release.indexOf('Atomically publish signed update feed pointer');
  const feedRouteIndex = input.release.indexOf('Deploy branded Linux update feed routes');
  if (!(uploadIndex >= 0 && previewIndex > uploadIndex && activationIndex > previewIndex
      && servingIndex > activationIndex && feedIndex > servingIndex && feedRouteIndex > feedIndex)) {
    failures.push('repository upload, preview, activation, serving cutover, feed pointer, and feed route must remain strictly ordered.');
  }
  for (const stepId of [
    'deploy_repository_routes',
    'verify_public_repository',
    'verify_public_lifecycle',
    'drill_repository_rollback',
    'publish_feed_pointer',
    'deploy_feed_routes',
    'verify_public_feed',
    'verify_live_feed',
    'attest_repository_publication',
    'publish_github_release'
  ]) {
    requireText(input.release, `steps.${stepId}.outcome`, 'atomic repository publication transaction');
  }
  requireText(input.release, 'repository-activation-compensation.json', 'atomic repository publication containment receipt');
  requireText(input.release, 'receipt.passed !== true || receipt.contained !== true', 'atomic repository publication containment gate');
  if (input.release.includes('-e OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM')) {
    failures.push('the installed-manifest signing key must not enter the build container environment.');
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
  const release = read('.github/workflows/linux-release.yml');
  const result = verifyLinuxWorkflowWiring({
    pr: read('.github/workflows/linux-pr-gate.yml'),
    nightly: read('.github/workflows/linux-nightly.yml'),
    release,
    releaseYaml: release,
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
