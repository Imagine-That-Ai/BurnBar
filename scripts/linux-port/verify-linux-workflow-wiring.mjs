#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { repoRoot } from './lib/linux-release-common.mjs';

export const LINUX_WORKFLOW_WIRING_SOURCE_PATHS = Object.freeze({
  pr: '.github/workflows/linux-pr-gate.yml',
  productParityWorkflow: '.github/workflows/linux-product-parity.yml',
  promotionWorkflow: '.github/workflows/linux-release-promote.yml',
  nightly: '.github/workflows/linux-nightly.yml',
  release: '.github/workflows/linux-release.yml',
  makefile: 'Makefile',
  nativeTests: 'scripts/linux-port/run-linux-native-tests.sh',
  rustBridge: 'apps/linux-desktop/src-tauri/src/lib.rs',
  updateFeed: 'apps/linux-desktop/src-tauri/src/update_feed.rs',
  capability: 'apps/linux-desktop/src-tauri/capabilities/default.json',
  tauriConfig: 'apps/linux-desktop/src-tauri/tauri.conf.json',
  desktopPackage: 'apps/linux-desktop/package.json',
  runtimeCatalog: 'packaging/linux/runtime-capability-catalog.json',
  runtimeSchema: 'schemas/linux-runtime-capability-manifest.schema.json',
  routes: 'apps/linux-desktop/src/routes.ts',
  surfaceBoundary: 'apps/linux-desktop/src/surfaces/SurfaceRouter.tsx'
});

export const LINUX_WORKFLOW_WIRING_COMPOSITE_SOURCE_PATHS = Object.freeze({
  fixturePolicy: [
    'apps/linux-desktop/src/daemonFixture.ts',
    'apps/linux-desktop/src/state/shellStore.ts',
    'apps/linux-desktop/src/surfaces/support/SupportSurface.tsx'
  ],
  rendererBridge: [
    'apps/linux-desktop/src/tauriBridge.ts',
    'apps/linux-desktop/src/runtimeCapabilities.ts',
    'apps/linux-desktop/src/state/chatStore.ts',
    'apps/linux-desktop/src/chat/gatewayClient.ts'
  ]
});

export function loadLinuxWorkflowWiringInput(root = repoRoot) {
  const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
  const input = Object.fromEntries(
    Object.entries(LINUX_WORKFLOW_WIRING_SOURCE_PATHS).map(([key, relative]) => [key, read(relative)])
  );
  for (const [key, paths] of Object.entries(LINUX_WORKFLOW_WIRING_COMPOSITE_SOURCE_PATHS)) {
    input[key] = paths.map(read).join('\n');
  }
  return input;
}

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
  const requireUploadContract = (body, stepName, paths, source) => {
    const start = body.indexOf(`- name: ${stepName}`);
    const end = start < 0 ? -1 : body.indexOf('\n      - name:', start + 1);
    const block = start < 0 ? '' : body.slice(start, end < 0 ? body.length : end);
    if (!block) {
      failures.push(`${source} is missing upload step: ${stepName}`);
      return;
    }
    for (const marker of [
      'actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4',
      'include-hidden-files: true',
      'if-no-files-found: error',
      ...paths
    ]) requireText(block, marker, `${source} ${stepName}`);
  };
  const requireP38CaptureContract = (body) => {
    const stepName = 'Capture P-38 release automation verification';
    const start = body.indexOf(`- name: ${stepName}`);
    const end = start < 0 ? -1 : body.indexOf('\n      - name:', start + 1);
    const block = start < 0 ? '' : body.slice(start, end < 0 ? body.length : end);
    if (!block) {
      failures.push(`product parity evidence workflow is missing executable step: ${stepName}`);
      return;
    }
    const activeLines = block.split('\n').map((line) => line.trim()).filter((line) => line && !line.startsWith('#'));
    for (const line of [
      "if: inputs.requirement == 'P-38'",
      'set -euo pipefail',
      'node scripts/linux-port/capture-p38-release-automation.mjs',
      '--candidate-run-id "$CANDIDATE_RUN_ID"',
      '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
    ]) {
      if (!activeLines.includes(line) && !activeLines.includes(`${line} \\`)) {
        failures.push(`product parity evidence workflow ${stepName} is missing: ${line}`);
      }
    }
    for (const forbidden of ['continue-on-error: true', 'set +e', '|| true', '; true']) {
      if (activeLines.some((line) => line.includes(forbidden))) {
        failures.push(`product parity evidence workflow ${stepName} permits failure: ${forbidden}`);
      }
    }
  };

  requireText(input.release, '- "linux-v*"', 'release tag trigger');
  if (input.release.includes('- "v*"')) failures.push('legacy v* tag trigger is forbidden in the Linux release workflow.');
  requireText(input.release, 'resolve-linux-release-version.mjs --github-output', 'release version resolver');
  requireText(
    input.release,
    'validate-linux-release-public-config.mjs',
    'public Linux release configuration preflight'
  );
  for (const variable of [
    'OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID',
    'OPENBURNBAR_FIREBASE_API_KEY',
    'OPENBURNBAR_LINUX_APP_CHECK_APP_ID'
  ]) {
    requireText(input.release, `vars.${variable}`, `public Linux release configuration preflight ${variable}`);
  }
  requireText(input.release, 'OPENBURNBAR_LINUX_RELEASE_OUT', 'canonical release output');
  requireText(input.release, 'OPENBURNBAR_LINUX_EVIDENCE_OUT', 'canonical evidence output');
  requireText(input.release, '--candidate', 'candidate-only release assembly');
  requireText(
    input.release,
    'list-linux-release-attestation-subjects.mjs',
    'exact release attestation subject selection'
  );
  requireText(input.promotionWorkflow, "-name '*.pkg.tar.zst'", 'Arch package publication selection');
  for (const marker of [
    "-name 'PKGBUILD'",
    "-name 'arch-release-metadata.json'",
    "-name 'openburnbar-*.installed-manifest.json'",
    "-name 'openburnbar-*.installed-manifest.ed25519'"
  ]) {
    requireText(input.promotionWorkflow, marker, 'Arch release metadata publication selection');
  }
  requireUploadContract(
    input.release,
    'Upload architecture shard',
    ['${{ env.OPENBURNBAR_LINUX_RELEASE_OUT }}/'],
    'candidate workflow'
  );
  requireUploadContract(
    input.release,
    'Upload Linux release evidence',
    [
      '${{ env.OPENBURNBAR_LINUX_RELEASE_OUT }}/',
      '${{ env.OPENBURNBAR_LINUX_EVIDENCE_OUT }}/',
      '${{ env.OPENBURNBAR_LINUX_SHARDS_DIR }}/'
    ],
    'candidate workflow'
  );
  requireUploadContract(
    input.promotionWorkflow,
    'Upload promotion closure',
    ['${{ env.OPENBURNBAR_LINUX_RELEASE_OUT }}/promotion/'],
    'promotion workflow'
  );
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
    'build-signed-arch-package.mjs',
    'smoke-arch-package.mjs',
    'verify-arch-package-update-rollback.mjs',
    'product-proof-closure.json.ed25519.sig',
    'sign-product-proof-closure.mjs',
    '.linux-shard/arch-lifecycle',
    'arch_signature_pattern',
    'arch_manifest_pattern',
    'arch_manifest_signature_pattern',
    "--pattern 'product-proof-closure.json'",
    '--previous-signature',
    '--previous-installed-manifest "/workspace/',
    '--previous-installed-manifest-signature',
    '--previous-product-proof',
    '--previous-product-proof-signature',
    '--previous-release-tag',
    'source=$PWD,target=/workspace,readonly',
    'source=$PWD/.linux-shard/session,target=/workspace/.linux-shard/session',
    'source=$PWD/.linux-shard/arch-lifecycle,target=/workspace/.linux-shard/arch-lifecycle',
    'docker create --name "$container"',
    'docker start --attach "$container"',
    '--phase finalize',
    'previous_version',
    'linux-desktop-session.sh',
    'verify-linux-package-update-rollback.sh',
    'finalize-linux-architecture-session.mjs',
    'linux-release-shard-${{ matrix.architecture }}',
    'assemble-linux-release.mjs',
    'list-linux-release-attestation-subjects.mjs',
    'finalize-product-proof-closure.mjs',
    'sign-product-proof-closure.mjs',
    'product-proof-closure.json.ed25519.sig',
    'include-hidden-files: true',
    'merge-multiple: false',
    'finalize-product-proof-closure.mjs',
    'include-hidden-files: true'
  ]) requireText(input.release, marker, 'two-architecture release closure');
  for (const marker of [
    'resolve-product-evidence-run.mjs',
    'resolve-product-receipt-artifacts.mjs',
    'artifact_count }}" = "280"',
    'Generate current-HEAD product parity attestations',
    'attest-product-requirement.mjs --requirement "P-${number}"',
    'validate-parity-ledger.mjs',
    'verify-linux-release.mjs',
    '--candidate',
    'finalize-linux-promotion-closure.mjs',
    'uses: actions/attest@',
    'promotion-closure.json.sigstore.jsonl',
    'product-proof-closure.json.ed25519.sig',
    '--candidate-artifact-digest',
    '--draft',
    '--draft=false',
    "'*source-*.tar'",
    'OPENBURNBAR_R2_CUSTOM_DOMAIN: downloads.burnbar.ai',
    'upload-linux-downloads-r2.sh',
    'https://downloads.burnbar.ai/latest-linux.json'
  ]) requireText(input.promotionWorkflow, marker, 'strict release promotion workflow');
  for (const forbidden of [
    'attest-product-requirement.mjs',
    'validate-parity-ledger.mjs',
    'gh release create',
    'upload-linux-downloads-r2.sh'
  ]) {
    if (input.release.includes(forbidden)) failures.push(`candidate workflow may not perform promotion action: ${forbidden}`);
  }
  requireText(input.pr, 'bash scripts/linux-port/run-linux-native-tests.sh', 'PR native behavior gate');
  requireText(input.pr, 'verify-linux-release.test.mjs', 'PR release mutation suite');
  requireText(input.pr, 'assemble-linux-release.test.mjs', 'PR architecture assembly mutation suite');
  requireText(input.pr, 'linux-aggregate-installed-attestation.test.mjs', 'PR aggregate installed-attestation mutation suite');
  requireText(input.pr, 'linux-package-session.test.mjs', 'PR package lifecycle session suite');
  requireText(input.pr, 'arch-lifecycle-authentication.test.mjs', 'PR authenticated Arch lifecycle suite');
  requireText(input.pr, 'linux-installed-manifest.test.mjs', 'PR installed manifest mutation suite');
  requireText(input.pr, 'linux-appimage-peer-manifest.test.mjs', 'PR AppImage peer manifest suite');
  requireText(input.pr, 'linux-native-package-real-tools.test.mjs', 'PR real native package suite');
  requireText(
    input.pr,
    'validate-linux-release-public-config.test.mjs',
    'PR public Linux release configuration preflight suite'
  );
  requireText(input.pr, 'sign-linux-release-requests.test.mjs', 'PR isolated signer mutation suite');
  requireText(input.pr, 'sign-product-proof-closure.test.mjs', 'PR product-proof closure signer suite');
  requireText(input.pr, 'signed-installed-package-wiring.test.mjs', 'PR signed package wiring suite');
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
    'scripts/linux-port/arch-package-lifecycle.test.mjs',
    'PR signed Arch package lifecycle suite'
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
    'smoke-linux-packages.test.mjs',
    'product-proof-closure.test.mjs',
    'product-feature-proof-closure.test.mjs',
    'p38-release-automation-proof.test.mjs',
    'p31-accessibility-proof.test.mjs',
    'p34-credential-security-proof.test.mjs',
    'parity-certification-preflight.test.mjs',
    'run-linux-matrix-harness.test.mjs',
    'run-product-requirement-validator.test.mjs',
    'resolve-product-evidence-run.test.mjs',
    'resolve-product-receipt-artifacts.test.mjs'
  ]) requireText(input.pr, command, 'PR product evidence gate');
  for (const marker of [
    'id-token: write',
    'attestations: write',
    'artifact-metadata: write',
    'ref: ${{ github.sha }}',
    'resolve-product-evidence-run.mjs',
    'CANDIDATE_RUN_ID: ${{ inputs.candidate_run_id }}',
    'TARGET_HEAD: ${{ github.sha }}',
    '--run-id "$CANDIDATE_RUN_ID"',
    '--target-head "$TARGET_HEAD"',
    'artifact-ids: ${{ steps.evidence.outputs.artifact_id }}',
    'CANDIDATE_RUN_ID: ${{ steps.evidence.outputs.run_id }}',
    'CANDIDATE_ARTIFACT_DIGEST: ${{ steps.evidence.outputs.artifact_digest }}',
    'capture-p38-release-automation.mjs',
    "if: inputs.requirement == 'P-38'",
    'Capture P-38 release automation verification',
    'capture-parity-certification-preflight.mjs',
    'capture-p34-credential-security-proof.mjs',
    "if: inputs.requirement == 'P-02'",
    "if: inputs.requirement == 'P-34'",
    'Preserve non-promotable P-02 diagnostic evidence',
    "if: always() && inputs.requirement == 'P-02'",
    'linux-product-parity-diagnostic-',
    'id: p02_capture',
    'mktemp -d "${RUNNER_TEMP}/openburnbar-p02.XXXXXX"',
    "printf 'diagnostic_root=%s\\n' \"$diagnostic_root\" >> \"$GITHUB_OUTPUT\"",
    '--diagnostic-root "$diagnostic_root"',
    '${{ steps.p02_capture.outputs.diagnostic_root }}/',
    'capture-failure.json',
    'capture.log',
    '2>&1 | tee "$capture_log"',
    'capture-p31-accessibility.mjs',
    "if: inputs.requirement == 'P-31'",
    'id: p31_capture',
    '--session-report "$session_report"',
    'p31-live-session.json',
    'P-34 credential security proof',
    '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
    'finalize-product-feature-proof-closure.mjs',
    'prepare-product-requirement-input.mjs',
    'run-product-requirement-validator.mjs',
    '--candidate-run-id "$CANDIDATE_RUN_ID"',
    '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
    'uses: actions/attest@',
    '.sigstore.jsonl',
    'if-no-files-found: error',
    'include-hidden-files: true'
  ]) requireText(input.productParityWorkflow, marker, 'product parity evidence workflow');
  requireP38CaptureContract(input.productParityWorkflow);
  if (/--run-id\s+['"]?\$\{\{\s*inputs\.candidate_run_id/u.test(input.productParityWorkflow)) {
    failures.push('product parity workflow may not interpolate candidate_run_id directly into shell.');
  }
  requireOrder(input.productParityWorkflow, [
    'Download exact-candidate installed evidence',
    'Capture P-38 release automation verification',
    'Capture parity certification preflight',
    'Preserve non-promotable P-02 diagnostic evidence',
    'Capture P-31 installed accessibility matrix evidence',
    'Capture P-34 credential security proof',
    'Finalize registered feature proof closure',
    'Materialize the requirement-owned release closure',
    'Run the registered requirement validator'
  ], 'product parity evidence workflow');
  requireText(input.release, 'npm ci --prefix scripts/linux-port --ignore-scripts', 'candidate evidence dependencies');
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
    'Validate public Linux release configuration',
    'Assert native runner architecture',
    'Prepare unsigned native architecture artifacts',
    'Prepare unsigned Arch installed-manifest request',
    'Materialize exact-commit isolated signer',
    'Sign exact native requests in isolated container',
    'Finalize signed Arch package with makepkg',
    'Finalize and verify signed native architecture artifacts',
    'Native package inspection/install/uninstall smoke',
    'Arch pacman install ownership and uninstall smoke',
    'Verify Arch package update, rollback, and data preservation',
    'Run package-owned desktop, daemon, accessibility, tray, and route session',
    'Verify native package update, rollback, and data preservation',
    'Finalize commit-bound architecture session',
    'Download native architecture shards',
    'Assemble signed two-architecture closure and feed',
    'Pre-attestation Linux release verification',
    'Attest Linux release sidecars and packages',
    'Final Linux release verification',
    'Finalize installed-product proof closure',
    'Sign installed-product proof closure'
  ], 'candidate workflow');
  requireOrder(input.promotionWorkflow, [
    'Resolve the immutable successful candidate artifact',
    'Resolve the complete immutable receipt matrix',
    'Download all 280 exact receipt artifacts',
    'Generate current-HEAD product parity attestations',
    'Verify strict product parity at promotion HEAD',
    'Download the exact candidate',
    'Reverify immutable candidate signatures and provenance',
    'Finalize candidate-bound promotion closure',
    'Attest the exact promotion closure',
    'Stage exact candidate as draft Linux GitHub release',
    'Configure branded Linux update origin',
    'Publish signed update feed to downloads origin',
    'Verify live Linux update feed after publish',
    'Publish verified Linux GitHub release'
  ], 'promotion workflow');

  if (/verify-linux-release\.mjs[^\n]*--allow-blocked/.test(input.release + input.promotionWorkflow)) {
    failures.push('release verification may not use --allow-blocked.');
  }
  if (/continue-on-error:\s*true[\s\S]{0,200}(parity|signature|release verification)/i.test(input.release + input.promotionWorkflow)) {
    failures.push('release integrity steps may not continue on error.');
  }
  if (/openburnbar-linux-ed25519\.pub\.pem[^\n]*\|\|\s*true/.test(input.promotionWorkflow)) {
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
  const result = verifyLinuxWorkflowWiring(loadLinuxWorkflowWiringInput(repoRoot));
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.passed ? 0 : 1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
