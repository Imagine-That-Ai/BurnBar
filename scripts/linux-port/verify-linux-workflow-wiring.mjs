#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readLinuxDesktopRustSource } from './lib/linux-desktop-rust-source.mjs';
import { repoRoot } from './lib/linux-release-common.mjs';

export const LINUX_WORKFLOW_WIRING_SOURCE_PATHS = Object.freeze({
  pr: '.github/workflows/linux-pr-gate.yml',
  productParityWorkflow: '.github/workflows/linux-product-parity.yml',
  promotionWorkflow: '.github/workflows/linux-release-promote.yml',
  nightly: '.github/workflows/linux-nightly.yml',
  release: '.github/workflows/linux-release.yml',
  makefile: 'Makefile',
  nativeTests: 'scripts/linux-port/run-linux-native-tests.sh',
  updateFeed: 'apps/linux-desktop/src-tauri/src/update_feed.rs',
  capability: 'apps/linux-desktop/src-tauri/capabilities/default.json',
  tauriConfig: 'apps/linux-desktop/src-tauri/tauri.conf.json',
  desktopPackage: 'apps/linux-desktop/package.json',
  runtimeCatalog: 'packaging/linux/runtime-capability-catalog.json',
  runtimeSchema: 'schemas/linux-runtime-capability-manifest.schema.json',
  routes: 'apps/linux-desktop/src/routes.ts',
  surfaceBoundary: 'apps/linux-desktop/src/surfaces/SurfaceRouter.tsx',
  p25Workflow: 'scripts/linux-port/run-p25-installed-update-proof-workflow.sh'
});

export const LINUX_WORKFLOW_WIRING_COMPOSITE_SOURCE_PATHS = Object.freeze({
  fixturePolicy: [
    'apps/linux-desktop/src/daemonFixture.ts',
    'apps/linux-desktop/src/state/shellStore.ts',
    'apps/linux-desktop/src/surfaces/support/SupportSurface.tsx'
  ],
  rendererBridge: [
    'apps/linux-desktop/src/tauriBridge.ts',
    'apps/linux-desktop/src/tauriBridgeCoreDecoders.ts',
    'apps/linux-desktop/src/tauriBridgePlatformDecoders.ts',
    'apps/linux-desktop/src/tauriBridgeRaw.ts',
    'apps/linux-desktop/src/tauriBridgeSystemDecoders.ts',
    'apps/linux-desktop/src/tauriBridgeTypes.ts',
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
  input.rustBridge = readLinuxDesktopRustSource(root);
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
  const requireUploadContract = (body, stepName, paths, source, options = {}) => {
    const start = body.indexOf(`- name: ${stepName}`);
    const end = start < 0 ? -1 : body.indexOf('\n      - name:', start + 1);
    const block = start < 0 ? '' : body.slice(start, end < 0 ? body.length : end);
    if (!block) {
      failures.push(`${source} is missing upload step: ${stepName}`);
      return;
    }
    const artifactAction = options.artifactAction ?? 'actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4';
    const noFilesFound = options.noFilesFound ?? 'if-no-files-found: error';
    for (const marker of [
      artifactAction,
      'include-hidden-files: true',
      noFilesFound,
      ...paths,
      ...(options.additionalMarkers ?? [])
    ]) requireText(block, marker, `${source} ${stepName}`);
  };
  const requireNightlyMacosArtifactRetryContract = (body) => {
    const blockFor = (stepName) => {
      const start = body.indexOf(`- name: ${stepName}`);
      const end = start < 0 ? -1 : body.indexOf('\n      - name:', start + 1);
      return start < 0 ? '' : body.slice(start, end < 0 ? body.length : end);
    };
    const primary = blockFor('Upload macOS nightly matched workload soak');
    const retry = blockFor('Retry macOS nightly matched workload soak upload');
    const selector = blockFor('Select uploaded macOS nightly matched workload soak');
    for (const [block, stepName] of [[primary, 'Upload macOS nightly matched workload soak'], [retry, 'Retry macOS nightly matched workload soak upload'], [selector, 'Select uploaded macOS nightly matched workload soak']]) {
      if (!block) failures.push(`nightly macOS artifact contract is missing step: ${stepName}`);
    }
    for (const marker of [
      'macos_artifact_name: ${{ steps.select-macos-performance-artifact.outputs.artifact_name }}',
      'name: ${{ needs.macos-matched-performance.outputs.macos_artifact_name }}'
    ]) requireText(body, marker, 'nightly macOS artifact contract');
    for (const marker of [
      'id: upload-macos-performance-primary',
      'continue-on-error: true',
      'actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4',
      'name: linux-parity-macos-performance-nightly',
      'path: ${{ env.OB_EVIDENCE_OUT }}/matched-performance-macos.json',
      'if-no-files-found: error'
    ]) requireText(primary, marker, 'nightly macOS primary artifact upload');
    for (const marker of [
      'id: upload-macos-performance-retry',
      "if: steps.upload-macos-performance-primary.outcome != 'success'",
      'continue-on-error: true',
      'actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4',
      'name: linux-parity-macos-performance-nightly-retry-${{ github.run_id }}',
      'path: ${{ env.OB_EVIDENCE_OUT }}/matched-performance-macos.json',
      'if-no-files-found: error'
    ]) requireText(retry, marker, 'nightly macOS retry artifact upload');
    for (const marker of [
      'id: select-macos-performance-artifact',
      'if: always()',
      'set -euo pipefail',
      'PRIMARY_OUTCOME: ${{ steps.upload-macos-performance-primary.outcome }}',
      'RETRY_OUTCOME: ${{ steps.upload-macos-performance-retry.outcome }}',
      'PRIMARY_NAME: linux-parity-macos-performance-nightly',
      'RETRY_NAME: linux-parity-macos-performance-nightly-retry-${{ github.run_id }}',
      'if [[ "$PRIMARY_OUTCOME" == "success" ]]',
      'if [[ "$RETRY_OUTCOME" == "success" ]]',
      'echo "artifact_name=$PRIMARY_NAME" >> "$GITHUB_OUTPUT"',
      'echo "artifact_name=$RETRY_NAME" >> "$GITHUB_OUTPUT"',
      'exit 0',
      'Neither macOS matched-performance artifact upload succeeded.',
      'exit 1'
    ]) requireText(selector, marker, 'nightly macOS artifact selector');
    requireOrder(body, [
      '- name: Upload macOS nightly matched workload soak',
      '- name: Retry macOS nightly matched workload soak upload',
      '- name: Select uploaded macOS nightly matched workload soak'
    ], 'nightly macOS artifact retry');
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

  const requireP08CaptureContract = (body) => {
    const blockFor = (stepName) => {
      const start = body.indexOf(`- name: ${stepName}`);
      const end = start < 0 ? -1 : body.indexOf('\n      - name:', start + 1);
      return start < 0 ? '' : body.slice(start, end < 0 ? body.length : end);
    };
    const installStep = 'Install P-08 signed candidate package';
    const captureStep = 'Capture P-08 installed Mercury media proof';
    const install = blockFor(installStep);
    const capture = blockFor(captureStep);
    if (!install) failures.push(`product parity evidence workflow is missing executable step: ${installStep}`);
    if (!capture) failures.push(`product parity evidence workflow is missing executable step: ${captureStep}`);
    const activeLines = (block) => block.split('\n').map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#'));
    for (const [step, block, lines] of [
      [installStep, install, [
        "if: inputs.requirement == 'P-08'",
        'set -euo pipefail',
        'sudo apt-get install -y --reinstall "$package"',
        'sudo dnf install -y "$package"',
        'sudo pacman -U --noconfirm "$package"',
        'sha256sum /usr/share/openburnbar/attestation/installed-manifest.json',
        'sha256sum /usr/share/openburnbar/attestation/installed-manifest.json.sig'
      ]],
      [captureStep, capture, [
        "if: inputs.requirement == 'P-08'",
        'set -euo pipefail',
        'test -f "$desktop_report"',
        'test -f "$device_report"',
        'node scripts/linux-port/run-p08-mercury-media-session.mjs',
        '--manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        'node scripts/linux-port/capture-p08-mercury-media-proof.mjs',
        '--session-report "$input_root/p08-installed-mercury-media-session.json"',
        '--candidate-run-id "$CANDIDATE_RUN_ID"',
        '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
      ]]
    ]) {
      const active = activeLines(block);
      for (const line of lines) {
        if (!active.includes(line) && !active.includes(`${line} \\`)) {
          failures.push(`product parity evidence workflow ${step} is missing: ${line}`);
        }
      }
      for (const forbidden of ['continue-on-error: true', 'set +e', '|| true', '; true']) {
        if (active.some((line) => line.includes(forbidden))) {
          failures.push(`product parity evidence workflow ${step} permits failure: ${forbidden}`);
        }
      }
    }
  };

  const requireInstalledUiCaptureContract = (body, requirementId, config) => {
    const blockFor = (stepName) => {
      const start = body.indexOf(`- name: ${stepName}`);
      const end = start < 0 ? -1 : body.indexOf('\n      - name:', start + 1);
      return start < 0 ? '' : body.slice(start, end < 0 ? body.length : end);
    };
    const installStep = 'Install signed candidate for installed feature proofs';
    const captureStep = config.step;
    const install = blockFor(installStep);
    const capture = blockFor(captureStep);
    if (!install) failures.push(`product parity evidence workflow is missing executable step: ${installStep}`);
    if (!capture) failures.push(`product parity evidence workflow is missing executable step: ${captureStep}`);
    const activeLines = (block) => block.split('\n').map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#'));
    const required = [
      [installStep, install, [
        "if: inputs.requirement == 'P-09' || inputs.requirement == 'P-10' || inputs.requirement == 'P-11' || inputs.requirement == 'P-12' || inputs.requirement == 'P-13' || inputs.requirement == 'P-14' || inputs.requirement == 'P-15' || inputs.requirement == 'P-16' || inputs.requirement == 'P-17' || inputs.requirement == 'P-18' || inputs.requirement == 'P-19' || inputs.requirement == 'P-20' || inputs.requirement == 'P-21' || inputs.requirement == 'P-22' || inputs.requirement == 'P-23' || inputs.requirement == 'P-24' || inputs.requirement == 'P-25' || inputs.requirement == 'P-26' || inputs.requirement == 'P-27' || inputs.requirement == 'P-28' || inputs.requirement == 'P-29' || inputs.requirement == 'P-30' || inputs.requirement == 'P-32' || inputs.requirement == 'P-33' || inputs.requirement == 'P-35' || inputs.requirement == 'P-36'",
        'set -euo pipefail',
        'sudo apt-get install -y --reinstall "$package"',
        'sudo dnf install -y "$package"',
        'sudo pacman -U --noconfirm "$package"',
        'test "$(awk -F \' = \' \'$1 == "pkgname" { print $2 }\' <<<"$package_info")" = openburnbar',
        'sha256sum /usr/share/openburnbar/attestation/installed-manifest.json',
        'sha256sum /usr/share/openburnbar/attestation/installed-manifest.json.sig'
      ]],
      [captureStep, capture, [
        `if: inputs.requirement == '${requirementId}'`,
        'set -euo pipefail',
        `node ${config.runner}`,
        `node ${config.materializer}`,
        `node ${config.capture}`,
        '--manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        '--candidate-run-id "$CANDIDATE_RUN_ID"',
        '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        ...(config.requiredLines ?? [])
      ]]
    ];
    for (const [step, block, lines] of required) {
      const active = activeLines(block);
      for (const line of lines) {
        if (!active.includes(line) && !active.includes(`${line} \\`)) {
          failures.push(`product parity evidence workflow ${step} is missing: ${line}`);
        }
      }
      for (const forbidden of ['continue-on-error: true', 'set +e', '|| true', '; true']) {
        if (active.some((line) => line.includes(forbidden))) {
          failures.push(`product parity evidence workflow ${step} permits failure: ${forbidden}`);
        }
      }
    }
    const runnerIndex = capture.indexOf(`node ${config.runner}`);
    const materializerIndex = capture.indexOf(`node ${config.materializer}`);
    const captureIndex = capture.indexOf(`node ${config.capture}`);
    if (!(runnerIndex >= 0 && runnerIndex < materializerIndex && materializerIndex < captureIndex)) {
      failures.push(`product parity evidence workflow ${captureStep} must run native probe, materializer, then capture in order`);
    }
  };
  const requireNativeWebDriverProvisioning = (body) => {
    const stepName = 'Provision native Tauri WebDriver prerequisites';
    const start = body.indexOf(`- name: ${stepName}`);
    const end = start < 0 ? -1 : body.indexOf('\n      - name:', start + 1);
    const block = start < 0 ? '' : body.slice(start, end < 0 ? body.length : end);
    if (!block) {
      failures.push(`product parity evidence workflow is missing executable step: ${stepName}`);
      return;
    }
    const active = block.split('\n').map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#'));
    for (const line of [
      "if: inputs.requirement == 'P-15' || inputs.requirement == 'P-16' || inputs.requirement == 'P-27' || inputs.requirement == 'P-36'",
      'set -euo pipefail',
      'bash scripts/linux-port/install-tauri-webdriver-prerequisites.sh'
    ]) {
      if (!active.includes(line)) {
        failures.push(`product parity evidence workflow ${stepName} is missing: ${line}`);
      }
    }
    for (const forbidden of ['continue-on-error: true', 'set +e', '|| true', '; true']) {
      if (active.some((line) => line.includes(forbidden))) {
        failures.push(`product parity evidence workflow ${stepName} permits failure: ${forbidden}`);
      }
    }
  };
  const requireP16PhysicalIPadProducer = (body) => {
    const jobStart = body.indexOf('  p16-ipad-producer:');
    const jobEnd = jobStart < 0 ? -1 : body.indexOf('\n  p32-macos-producer:', jobStart + 1);
    const job = jobStart < 0 ? '' : body.slice(jobStart, jobEnd < 0 ? body.length : jobEnd);
    const stepName = 'Capture P-16 physical iPad trust cycle';
    const stepStart = job.indexOf(`- name: ${stepName}`);
    const step = stepStart < 0 ? '' : job.slice(stepStart);
    if (!job) failures.push('product parity evidence workflow is missing P-16 physical iPad producer job');
    if (!step) failures.push(`product parity evidence workflow is missing executable step: ${stepName}`);
    for (const marker of [
      "if: inputs.requirement == 'P-16'",
      '- self-hosted',
      '- macos',
      '- arm64',
      'FIREBASE_PLIST_BASE64: ${{ secrets.FIREBASE_PLIST_BASE64 }}',
      'bash scripts/ci/inject-firebase-config.sh',
      'P16_COORDINATION_ROOT: ${{ vars.OPENBURNBAR_P16_MACOS_COORDINATION_ROOT }}',
      'resolve-product-evidence-run.mjs',
      'ref: ${{ github.sha }}'
    ]) requireText(job, marker, 'P-16 physical iPad producer job');
    const active = step.split('\n').map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#'));
    for (const line of [
      'set -euo pipefail',
      'test -n "$P16_COORDINATION_ROOT"',
      '[[ "$P16_COORDINATION_ROOT" == /* ]]',
      'test ! -L "$P16_COORDINATION_ROOT"',
      'test "$(stat -f \'%Su\' "$P16_COORDINATION_ROOT")" = "$(id -un)"',
      'test "$(stat -f \'%Lp\' "$P16_COORDINATION_ROOT")" = 700',
      'coordination_dir="$P16_COORDINATION_ROOT/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${ENVIRONMENT_ID}"',
      'scratch_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p16-ipad.XXXXXX")"',
      'rm -rf "$scratch_root" || status=1',
      'bash scripts/linux-port/capture-p16-physical-ipad-trust-cycle.sh',
      '--coordination-dir "$coordination_dir"',
      '--scratch-root "$scratch_root"',
      '--target-head "$TARGET_HEAD"',
      '--candidate-run-id "$CANDIDATE_RUN_ID"',
      '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
    ]) {
      if (!active.includes(line) && !active.includes(`${line} \\`)) {
        failures.push(`product parity evidence workflow ${stepName} is missing: ${line}`);
      }
    }
    for (const forbidden of ['continue-on-error: true', 'set +e', '|| true', '; true']) {
      if (active.some((line) => line.includes(forbidden))) {
        failures.push(`product parity evidence workflow ${stepName} permits failure: ${forbidden}`);
      }
    }
  };

  const requireP06ArchPackageContract = (body) => {
    const stepName = 'Install P-06 signed candidate package';
    const start = body.indexOf(`- name: ${stepName}`);
    const end = start < 0 ? -1 : body.indexOf('\n      - name:', start + 1);
    const block = start < 0 ? '' : body.slice(start, end < 0 ? body.length : end);
    const active = block.split('\n').map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#'));
    for (const line of [
      "if: inputs.requirement == 'P-06'",
      'test "$(awk -F \' = \' \'$1 == "pkgname" { print $2 }\' <<<"$package_info")" = openburnbar',
      'version="${version%-*}"',
      'sudo pacman -U --noconfirm "$package"'
    ]) {
      if (!active.includes(line)) {
        failures.push(`product parity evidence workflow ${stepName} is missing: ${line}`);
      }
    }
  };

  const requireP39CaptureContract = (body) => {
    const blockFor = (stepName) => {
      const start = body.indexOf(`- name: ${stepName}`);
      const end = start < 0 ? -1 : body.indexOf('\n      - name:', start + 1);
      return start < 0 ? '' : body.slice(start, end < 0 ? body.length : end);
    };
    const resolveStep = 'Resolve P-39 candidate-bound platform evidence inputs';
    const captureStep = 'Capture P-39 same-commit macOS/Linux differential proof';
    const linuxProducerStep = 'Capture P-39 Linux candidate-bound platform evidence';
    const resolve = blockFor(resolveStep);
    const capture = blockFor(captureStep);
    const linuxProducer = blockFor(linuxProducerStep);
    if (!resolve) failures.push(`product parity evidence workflow is missing executable step: ${resolveStep}`);
    if (!capture) failures.push(`product parity evidence workflow is missing executable step: ${captureStep}`);
    if (!linuxProducer) failures.push(`product parity evidence workflow is missing executable step: ${linuxProducerStep}`);
    const activeLines = (block) => block.split('\n').map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#'));
    for (const [step, lines] of [
      [linuxProducerStep, [
        "if: inputs.requirement == 'P-39'",
        'set -euo pipefail',
        'node scripts/linux-port/capture-p39-platform-evidence.mjs',
        '--platform linux',
        '--candidate-closure "$input_root/.linux-release/product-proof-closure.json"',
        '--candidate-run-id "$CANDIDATE_RUN_ID"',
        '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
      ]],
      [resolveStep, [
        "if: inputs.requirement == 'P-39'",
        'set -euo pipefail',
        'node scripts/linux-port/resolve-p39-platform-evidence.mjs',
        '--target-head "$TARGET_HEAD"',
        '--candidate-run-id "$CANDIDATE_RUN_ID"',
        '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
      ]],
      [captureStep, [
        "if: inputs.requirement == 'P-39'",
        'set -euo pipefail',
        'node scripts/linux-port/capture-p39-differential.mjs',
        '--input-root "$input_root"',
        '--macos "$MACOS_INPUT"',
        '--linux "$LINUX_INPUT"',
        '--environment "$ENVIRONMENT_ID"',
        '--target-head "$TARGET_HEAD"',
        '--version "$VERSION"',
        '--candidate-run-id "$CANDIDATE_RUN_ID"',
        '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        "--ignore '$.payload.generatedAt'",
        "--ignore '$.payload.execution'"
      ]]
    ]) {
      const linesInStep = activeLines(
        step === resolveStep ? resolve : step === captureStep ? capture : linuxProducer
      );
      for (const line of lines) {
        if (!linesInStep.includes(line) && !linesInStep.includes(`${line} \\`)) {
          failures.push(`product parity evidence workflow ${step} is missing: ${line}`);
        }
      }
      for (const forbidden of ['continue-on-error: true', 'set +e', '|| true', '; true']) {
        if (linesInStep.some((line) => line.includes(forbidden))) {
          failures.push(`product parity evidence workflow ${step} permits failure: ${forbidden}`);
        }
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
  requireText(input.release, 'COSIGN_MAX_ATTACHMENT_SIZE: 1GiB', 'large release attestation support');
  requireText(input.release, 'OPENBURNBAR_LINUX_COSIGN_IDENTITY: https://github.com/${{ github.workflow_ref }}', 'candidate cosign identity binding');
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
  requireUploadContract(
    input.pr,
    'Upload Linux gate evidence',
    ['${{ env.OPENBURNBAR_LINUX_EVIDENCE_OUT }}/'],
    'PR workflow',
    {
      artifactAction: 'actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874',
      noFilesFound: 'if-no-files-found: warn',
      additionalMarkers: ['if: always()']
    }
  );
  requireUploadContract(
    input.nightly,
    'Upload Linux nightly evidence',
    ['${{ env.OPENBURNBAR_LINUX_EVIDENCE_OUT }}/'],
    'nightly workflow',
    {
      artifactAction: 'actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874',
      noFilesFound: 'if-no-files-found: warn',
      additionalMarkers: ['if: always()']
    }
  );
  for (const [field, source] of [['pr', 'PR workflow'], ['nightly', 'nightly workflow']]) {
    requireText(
      input[field],
      '-v "$OPENBURNBAR_LINUX_EVIDENCE_OUT:/evidence"',
      `${source} Linux Swift evidence mount`
    );
    requireText(
      input[field],
      '--env OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests',
      `${source} Linux Swift evidence routing`
    );
  }
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
  const linuxSwiftResults =
    'OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests';
  requireText(input.pr, linuxSwiftResults, 'PR Linux Swift evidence routing');
  requireText(input.nightly, linuxSwiftResults, 'nightly Linux Swift evidence routing');
  requireText(input.pr, 'include-hidden-files: true', 'PR hidden evidence upload');
  for (const command of [
    'npm ci --prefix scripts/linux-port --ignore-scripts',
    'attest-product-requirement.test.mjs',
    'github-artifact-provenance.test.mjs',
    'live-installed-product-evidence.test.mjs',
    'smoke-linux-packages.test.mjs',
    'product-proof-closure.test.mjs',
    'product-feature-proof-closure.test.mjs',
    'p07-computer-use-proof.test.mjs',
    'p08-mercury-media-proof.test.mjs',
    'p09-navigation-shell-proof.test.mjs',
    'p10-dashboard-layout-proof.test.mjs',
    'p11-usage-ingestion-proof.test.mjs',
    'p12-quota-proof.test.mjs',
    'p13-native-onboarding-probes.test.mjs',
    'p13-onboarding-proof.test.mjs',
    'p17-native-activity-probes.test.mjs',
    'p17-activity-proof.test.mjs',
    'p18-native-memory-probes.test.mjs',
    'p18-memory-review-proof.test.mjs',
    'p19-native-projects-probes.test.mjs',
    'p19-projects-proof.test.mjs',
    'p20-native-missions-probes.test.mjs',
    'p20-missions-proof.test.mjs',
    'p21-native-insights-probes.test.mjs',
    'p21-insights-proof.test.mjs',
    'p22-native-database-probes.test.mjs',
    'p22-database-proof.test.mjs',
    'p24-installed-settings-workflow.test.mjs',
    'p24-native-settings-probes.test.mjs',
    'p24-settings-proof.test.mjs',
    'p26-native-tray-probes.test.mjs',
    'p26-tray-proof.test.mjs',
    'p27-native-notification-probes.test.mjs',
    'p27-notifications-proof.test.mjs',
    'p28-native-smarthub-probes.test.mjs',
    'p28-smarthub-proof.test.mjs',
    'p29-native-text-expansion-probes.test.mjs',
    'p29-text-expansion-proof.test.mjs',
    'p30-native-pet-probes.test.mjs',
    'p30-pet-proof.test.mjs',
    'p32-performance-proof.test.mjs',
    'p38-release-automation-proof.test.mjs',
    'p31-accessibility-proof.test.mjs',
    'p34-credential-security-proof.test.mjs',
    'parity-certification-preflight.test.mjs',
    'run-linux-matrix-harness.test.mjs',
    'run-product-requirement-validator.test.mjs',
    'resolve-product-evidence-run.test.mjs',
    'resolve-product-receipt-artifacts.test.mjs',
    'linux-toolchain-node-runtime.test.mjs'
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
    'run-p08-mercury-media-session.mjs',
    'capture-p08-mercury-media-proof.mjs',
    'Capture P-08 installed Mercury media proof',
    "if: inputs.requirement == 'P-08'",
    'run-p09-native-navigation-probes.mjs',
    'materialize-p09-navigation-shell-session.mjs',
    'capture-p09-navigation-shell-proof.mjs',
    'Capture P-09 installed navigation shell proof',
    "if: inputs.requirement == 'P-09'",
    'run-p10-native-dashboard-probes.mjs',
    'materialize-p10-dashboard-layout-session.mjs',
    'capture-p10-dashboard-layout-proof.mjs',
    'Capture P-10 installed dashboard layout proof',
    "if: inputs.requirement == 'P-10'",
    'run-p11-usage-ingestion-session.mjs',
    'materialize-p11-usage-ingestion-session.mjs',
    'capture-p11-usage-ingestion-proof.mjs',
    'Capture P-11 installed usage ingestion proof',
    "if: inputs.requirement == 'P-11'",
    'run-p12-native-quota-probes.mjs',
    'materialize-p12-quota-session.mjs',
    'capture-p12-quota-proof.mjs',
    'Capture P-12 installed quota proof',
    "if: inputs.requirement == 'P-12'",
    'run-p13-native-onboarding-probes.mjs',
    'materialize-p13-onboarding-session.mjs',
    'capture-p13-onboarding-proof.mjs',
    'Capture P-13 installed onboarding proof',
    "if: inputs.requirement == 'P-13'",
    'run-p14-chat-session.mjs',
    'materialize-p14-chat-session.mjs',
    'capture-p14-chat-proof.mjs',
    'Capture P-14 installed chat proof',
    "if: inputs.requirement == 'P-14'",
    'run-p15-native-account-billing-probes.mjs',
    'materialize-p15-account-billing-session.mjs',
    'capture-p15-account-billing-proof.mjs',
    'Capture P-15 installed account and billing proof',
    "if: inputs.requirement == 'P-15'",
    'run-p16-native-cloud-devices-probes.mjs',
    'materialize-p16-cloud-devices-session.mjs',
    'capture-p16-cloud-devices-proof.mjs',
    'Capture P-16 installed cloud and devices proof',
    "if: inputs.requirement == 'P-16'",
    'run-p17-native-activity-probes.mjs',
    'materialize-p17-activity-session.mjs',
    'capture-p17-activity-proof.mjs',
    'Capture P-17 installed Activity proof',
    "if: inputs.requirement == 'P-17'",
    'run-p18-native-memory-probes.mjs',
    'materialize-p18-memory-review-session.mjs',
    'capture-p18-memory-review-proof.mjs',
    'Capture P-18 installed memory-review proof',
    "if: inputs.requirement == 'P-18'",
    'run-p19-native-projects-probes.mjs',
    'materialize-p19-projects-session.mjs',
    'capture-p19-projects-proof.mjs',
    'Capture P-19 installed Projects proof',
    "if: inputs.requirement == 'P-19'",
    'run-p20-native-missions-probes.mjs',
    'materialize-p20-missions-session.mjs',
    'capture-p20-missions-proof.mjs',
    'Capture P-20 installed Missions proof',
    "if: inputs.requirement == 'P-20'",
    'run-p21-native-insights-probes.mjs',
    'materialize-p21-insights-session.mjs',
    'capture-p21-insights-proof.mjs',
    'Capture P-21 installed Insights proof',
    "if: inputs.requirement == 'P-21'",
    'run-p22-native-database-probes.mjs',
    'materialize-p22-database-session.mjs',
    'capture-p22-database-proof.mjs',
    'Capture P-22 installed Database proof',
    "if: inputs.requirement == 'P-22'",
    'run-p24-installed-settings-workflow.mjs',
    'materialize-p24-settings-session.mjs',
    'capture-p24-settings-proof.mjs',
    'Capture P-24 installed Settings proof',
    "if: inputs.requirement == 'P-24'",
    'run-p26-native-tray-probes.mjs',
    'materialize-p26-tray-session.mjs',
    'capture-p26-tray-proof.mjs',
    'Capture P-26 installed tray proof',
    "if: inputs.requirement == 'P-26'",
    'run-p27-native-notification-probes.mjs',
    'materialize-p27-notifications-session.mjs',
    'capture-p27-notifications-proof.mjs',
    'Capture P-27 installed notification and deep-link proof',
    "if: inputs.requirement == 'P-27'",
    'run-p28-native-smarthub-probes.mjs',
    'materialize-p28-smarthub-session.mjs',
    'capture-p28-smarthub-proof.mjs',
    'Capture P-28 installed SmartHub proof',
    "if: inputs.requirement == 'P-28'",
    'run-p29-installed-text-expansion-workflow.mjs',
    'materialize-p29-text-expansion-session.mjs',
    'capture-p29-text-expansion-proof.mjs',
    'Capture P-29 installed text expansion proof',
    "if: inputs.requirement == 'P-29'",
    'run-p30-native-pet-probes.mjs',
    'materialize-p30-pet-session.mjs',
    'capture-p30-pet-proof.mjs',
    'Capture P-30 installed pet proof',
    "if: inputs.requirement == 'P-30'",
    'run-p32-installed-performance-workflow.mjs',
    'materialize-p32-performance-session.mjs',
    'capture-p32-performance-proof.mjs',
    'Capture P-32 installed performance proof',
    "if: inputs.requirement == 'P-32'",
    'run-p33-native-reliability-probes.mjs',
    'materialize-p33-reliability-session.mjs',
    'capture-p33-reliability-proof.mjs',
    'Capture P-33 installed reliability proof',
    "if: inputs.requirement == 'P-33'",
    'run-p35-native-diagnostics-probes.mjs',
    'materialize-p35-diagnostics-support-session.mjs',
    'capture-p35-diagnostics-support-proof.mjs',
    'Capture P-35 installed diagnostics and support proof',
    "if: inputs.requirement == 'P-35'",
    'run-p36-native-visual-polish-probes.mjs',
    'materialize-p36-visual-polish-session.mjs',
    'capture-p36-visual-polish-proof.mjs',
    'Capture P-36 installed visual and interaction polish proof',
    "if: inputs.requirement == 'P-36'",
    'Provision native Tauri WebDriver prerequisites',
    'install-tauri-webdriver-prerequisites.sh',
    'capture-parity-certification-preflight.mjs',
    'capture-p34-credential-security-proof.mjs',
    'run-p40-privacy-rpc-session.mjs',
    'Capture P-40 installed privacy proof',
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
  requireP08CaptureContract(input.productParityWorkflow);
  requireP06ArchPackageContract(input.productParityWorkflow);
  requireNativeWebDriverProvisioning(input.productParityWorkflow);
  requireP16PhysicalIPadProducer(input.productParityWorkflow);
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-09', {
    step: 'Capture P-09 installed navigation shell proof',
    runner: 'scripts/linux-port/run-p09-native-navigation-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p09-navigation-shell-session.mjs',
    capture: 'scripts/linux-port/capture-p09-navigation-shell-proof.mjs'
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-10', {
    step: 'Capture P-10 installed dashboard layout proof',
    runner: 'scripts/linux-port/run-p10-native-dashboard-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p10-dashboard-layout-session.mjs',
    capture: 'scripts/linux-port/capture-p10-dashboard-layout-proof.mjs'
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-11', {
    step: 'Capture P-11 installed usage ingestion proof',
    runner: 'scripts/linux-port/run-p11-usage-ingestion-session.mjs',
    materializer: 'scripts/linux-port/materialize-p11-usage-ingestion-session.mjs',
    capture: 'scripts/linux-port/capture-p11-usage-ingestion-proof.mjs',
    requiredLines: [
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p11-support.XXXXXX")"',
      'chmod 700 "$evidence_root" "$support_root"',
      'systemctl --user set-environment \\',
      'systemctl --user restart openburnbar-daemon.service',
      'test -S "$socket_path"',
      'test -s "$token_file"',
      'test ! -e "$support_root/usage-events.jsonl"',
      '--ledger-path "$support_root/usage-events.jsonl"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-12', {
    step: 'Capture P-12 installed quota proof',
    runner: 'scripts/linux-port/run-p12-native-quota-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p12-quota-session.mjs',
    capture: 'scripts/linux-port/capture-p12-quota-proof.mjs',
    requiredLines: [
      'gateway_token_file="$support_root/gateway-auth-token"',
      'systemctl --user show-environment >"$original_environment"',
      'if systemctl --user is-active --quiet openburnbar-daemon.service; then service_was_active=1; else service_was_active=0; fi',
      'restore_manager_environment() {',
      'systemctl --user unset-environment "${managed_variables[@]}"',
      'if [[ "$service_was_active" == 1 ]]; then',
      'systemctl --user stop openburnbar-daemon.service || status=1',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/bin/openburnbar-daemon',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$gateway_token_file"',
      'chmod 600 "$gateway_token_file"',
      'gateway_token="$(<"$gateway_token_file")"',
      '(( gateway_port >= 1024 && gateway_port <= 65535 ))',
      'export OPENBURNBAR_DAEMON_SUPPORT_DIR="$support_root"',
      'export OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path"',
      'OPENBURNBAR_GATEWAY_ENABLED=1 \\',
      'OPENBURNBAR_GATEWAY_HOST=127.0.0.1 \\',
      '"OPENBURNBAR_GATEWAY_PORT=$gateway_port" \\',
      '"OPENBURNBAR_GATEWAY_AUTH_TOKEN=$gateway_token"',
      'systemctl --user restart openburnbar-daemon.service',
      '--support-dir "$support_root"',
      '--gateway-token-file "$gateway_token_file"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-13', {
    step: 'Capture P-13 installed onboarding proof',
    runner: 'scripts/linux-port/run-p13-native-onboarding-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p13-onboarding-session.mjs',
    capture: 'scripts/linux-port/capture-p13-onboarding-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p13-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p13-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p13-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/libexec/openburnbar-daemon-launch',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      '--home-dir "$home_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"',
      '--index-database "$index_database"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-14', {
    step: 'Capture P-14 installed chat proof',
    runner: 'scripts/linux-port/run-p14-chat-session.mjs',
    materializer: 'scripts/linux-port/materialize-p14-chat-session.mjs',
    capture: 'scripts/linux-port/capture-p14-chat-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-home.XXXXXX")"',
      'download_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-downloads.XXXXXX")"',
      'systemctl --user show-environment >"$original_environment"',
      'restore_manager_environment() {',
      'systemctl --user unset-environment "${managed_variables[@]}"',
      'if [[ "$service_was_active" == 1 ]]; then',
      'rm -rf "$evidence_root" "$support_root" "$home_root" "$download_root" || status=1',
      'printf \'XDG_DOWNLOAD_DIR="%s"\\n\' "$download_root" >"$home_root/.config/user-dirs.dirs"',
      'export HOME="$home_root"',
      'export XDG_CONFIG_HOME="$home_root/.config"',
      'test -S "$socket_path"',
      'test -s "$token_file"',
      'test -s "$database_path"',
      '--database-path "$database_path"',
      '--attachment "$attachment_path"',
      '--download-dir "$download_root"',
      '--thread-id "$thread_id"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-15', {
    step: 'Capture P-15 installed account and billing proof',
    runner: 'scripts/linux-port/run-p15-native-account-billing-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p15-account-billing-session.mjs',
    capture: 'scripts/linux-port/capture-p15-account-billing-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p15-evidence.XXXXXX")"',
      'state_home="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p15-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$state_home" || status=1',
      'chmod 700 "$evidence_root" "$state_home"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/bin/openburnbar-daemon',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '--state-home "$state_home"',
      '--architecture "$architecture"',
      '--package-format "$package_format"',
      '--desktop "$desktop"',
      '--display-server "$display_server"',
      '--compositor "$compositor"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-16', {
    step: 'Capture P-16 installed cloud and devices proof',
    runner: 'scripts/linux-port/run-p16-native-cloud-devices-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p16-cloud-devices-session.mjs',
    capture: 'scripts/linux-port/capture-p16-cloud-devices-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p16-evidence.XXXXXX")"',
      'state_home="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p16-home.XXXXXX")"',
      'P16_COORDINATION_ROOT: ${{ vars.OPENBURNBAR_P16_LINUX_COORDINATION_ROOT }}',
      'test -n "$P16_COORDINATION_ROOT"',
      '[[ "$P16_COORDINATION_ROOT" == /* ]]',
      'test ! -L "$P16_COORDINATION_ROOT"',
      'test "$(stat -c \'%U\' "$P16_COORDINATION_ROOT")" = "$(id -un)"',
      'test "$(stat -c \'%a\' "$P16_COORDINATION_ROOT")" = 700',
      'coordination_dir="$P16_COORDINATION_ROOT/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${ENVIRONMENT_ID}"',
      'mobile_receipt="$coordination_dir/p16-mobile-receipt.json"',
      'rm -rf "$evidence_root" "$state_home" "$coordination_dir" || status=1',
      'chmod 700 "$evidence_root" "$state_home" "$coordination_dir"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/bin/openburnbar-daemon',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '--state-home "$state_home"',
      '--mobile-receipt "$mobile_receipt"',
      '--coordination-dir "$coordination_dir"',
      '--architecture "$architecture"',
      '--package-format "$package_format"',
      '--desktop "$desktop"',
      '--display-server "$display_server"',
      '--compositor "$compositor"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-17', {
    step: 'Capture P-17 installed Activity proof',
    runner: 'scripts/linux-port/run-p17-native-activity-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p17-activity-session.mjs',
    capture: 'scripts/linux-port/capture-p17-activity-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-home.XXXXXX")"',
      'download_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-downloads.XXXXXX")"',
      'rm -rf "$evidence_root" "$support_root" "$home_root" "$download_root" || status=1',
      'chmod 700 "$evidence_root" "$support_root" "$home_root" "$download_root"',
      'test -x /usr/bin/openburnbar-cli',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/libexec/openburnbar-daemon-launch',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      '--home-dir "$home_root"',
      '--download-dir "$download_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"',
      '--index-database "$index_database"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, "P-18", {
    step: "Capture P-18 installed memory-review proof",
    runner: "scripts/linux-port/run-p18-native-memory-probes.mjs",
    materializer:
      "scripts/linux-port/materialize-p18-memory-review-session.mjs",
    capture: "scripts/linux-port/capture-p18-memory-review-proof.mjs",
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      '--home-dir "$home_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"',
      '--index-database "$index_database"',
    ],
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, "P-19", {
    step: "Capture P-19 installed Projects proof",
    runner: "scripts/linux-port/run-p19-native-projects-probes.mjs",
    materializer: "scripts/linux-port/materialize-p19-projects-session.mjs",
    capture: "scripts/linux-port/capture-p19-projects-proof.mjs",
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      '--home-dir "$home_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"',
      '--index-database "$index_database"',
    ],
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, "P-20", {
    step: "Capture P-20 installed Missions proof",
    runner: "scripts/linux-port/run-p20-native-missions-probes.mjs",
    materializer: "scripts/linux-port/materialize-p20-missions-session.mjs",
    capture: "scripts/linux-port/capture-p20-missions-proof.mjs",
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      '--home-dir "$home_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"',
      '--index-database "$index_database"',
    ],
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, "P-21", {
    step: "Capture P-21 installed Insights proof",
    runner: "scripts/linux-port/run-p21-native-insights-probes.mjs",
    materializer: "scripts/linux-port/materialize-p21-insights-session.mjs",
    capture: "scripts/linux-port/capture-p21-insights-proof.mjs",
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      '--home-dir "$home_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"',
      '--index-database "$index_database"',
    ],
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, "P-22", {
    step: "Capture P-22 installed Database proof",
    runner: "scripts/linux-port/run-p22-native-database-probes.mjs",
    materializer: "scripts/linux-port/materialize-p22-database-session.mjs",
    capture: "scripts/linux-port/capture-p22-database-proof.mjs",
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      '--home-dir "$home_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"',
      '--index-database "$index_database"',
    ],
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-23', {
    step: 'Capture P-23 installed Provider workspace proof',
    runner: 'scripts/linux-port/run-p23-native-provider-workspace-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p23-provider-workspace-session.mjs',
    capture: 'scripts/linux-port/capture-p23-provider-workspace-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p23-evidence.XXXXXX")"',
      'socket_path="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}/openburnbar/daemon.sock"',
      'token_file="${XDG_DATA_HOME:-$HOME/.local/share}/openburnbar/daemon-socket-auth-token"',
      'rm -rf "$evidence_root" || status=1',
      'chmod 700 "$evidence_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/bin/openburnbar-daemon',
      'test -S "$socket_path"',
      'test -s "$token_file"',
      'systemctl --user is-active --quiet openburnbar-daemon.service',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'umask 077',
      '--raw-output-dir "$evidence_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-24', {
    step: 'Capture P-24 installed Settings proof',
    runner: 'scripts/linux-port/run-p24-installed-settings-workflow.mjs',
    materializer: 'scripts/linux-port/materialize-p24-settings-session.mjs',
    capture: 'scripts/linux-port/capture-p24-settings-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/libexec/openburnbar-daemon-launch',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      '--home-dir "$home_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"',
      '--index-database "$index_database"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-26', {
    step: 'Capture P-26 installed tray proof',
    runner: 'scripts/linux-port/run-p26-native-tray-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p26-tray-session.mjs',
    capture: 'scripts/linux-port/capture-p26-tray-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/libexec/openburnbar-daemon-launch',
      'test -f /etc/xdg/autostart/openburnbar.desktop',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      '--support-dir "$support_root"',
      '--home-dir "$home_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"',
      '--index-database "$index_database"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-27', {
    step: 'Capture P-27 installed notification and deep-link proof',
    runner: 'scripts/linux-port/run-p27-native-notification-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p27-notifications-session.mjs',
    capture: 'scripts/linux-port/capture-p27-notifications-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p27-evidence.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p27-home.XXXXXX")"',
      'runtime_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p27-runtime.XXXXXX")"',
      'rm -rf "$evidence_root" "$home_root" "$runtime_root" || status=1',
      'chmod 700 "$evidence_root" "$home_root" "$runtime_root"',
      'command -v tauri-driver >/dev/null',
      'command -v WebKitWebDriver >/dev/null',
      '--home-dir "$home_root"',
      '--runtime-dir "$runtime_root"',
      '--desktop "$desktop"',
      '--display-server "$display_server"',
      '--marker "$marker"',
      '--compositor "$compositor"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-28', {
    step: 'Capture P-28 installed SmartHub proof',
    runner: 'scripts/linux-port/run-p28-native-smarthub-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p28-smarthub-session.mjs',
    capture: 'scripts/linux-port/capture-p28-smarthub-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p28-evidence.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p28-home.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p28-support.XXXXXX")"',
      'rm -rf "$evidence_root" "$home_root" "$support_root" || status=1',
      'chmod 700 "$evidence_root" "$home_root" "$support_root"',
      '--home-dir "$home_root"',
      '--support-dir "$support_root"',
      '--desktop "$desktop"',
      '--display-server "$display_server"',
      '--bridge-port 8787',
      '--marker "$marker"',
      '--compositor "$compositor"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-29', {
    step: 'Capture P-29 installed text expansion proof',
    runner: 'scripts/linux-port/run-p29-installed-text-expansion-workflow.mjs',
    materializer: 'scripts/linux-port/materialize-p29-text-expansion-session.mjs',
    capture: 'scripts/linux-port/capture-p29-text-expansion-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p29-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p29-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p29-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      'test -x /usr/libexec/openburnbar/text-expansion-engine',
      'test -f /usr/share/ibus/component/openburnbar.xml',
      'test -f /usr/share/openburnbar/text-expansion/text-expansion-engine.json',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      '--support-dir "$support_root"',
      '--home-dir "$home_root"',
      '--socket-path "$socket_path"',
      '--token-file "$token_file"',
      '--index-database "$index_database"',
      '--compositor "$compositor"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-30', {
    step: 'Capture P-30 installed pet proof',
    runner: 'scripts/linux-port/run-p30-native-pet-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p30-pet-session.mjs',
    capture: 'scripts/linux-port/capture-p30-pet-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p30-evidence.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p30-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$home_root" || status=1',
      'chmod 700 "$evidence_root" "$home_root"',
      'test -x /usr/bin/openburnbar-daemon',
      'test -x /usr/bin/openburnbar-linux-desktop',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      'marker="p30-$(openssl rand -hex 8)"',
      '--home-dir "$home_root"',
      '--desktop "$desktop"',
      '--display-server "$display_server"',
      '--marker "$marker"',
      '--compositor "$compositor"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-32', {
    step: 'Capture P-32 installed performance proof',
    runner: 'scripts/linux-port/run-p32-installed-performance-workflow.mjs',
    materializer: 'scripts/linux-port/materialize-p32-performance-session.mjs',
    capture: 'scripts/linux-port/capture-p32-performance-proof.mjs',
    requiredLines: [
      'raw_input="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p32-input.XXXXXX")"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p32-evidence.XXXXXX")"',
      'rm -rf "$raw_input" "$evidence_root" || status=1',
      'chmod 700 "$raw_input" "$evidence_root"',
      'export OB_EVIDENCE_OUT="$raw_input"',
      'node scripts/linux-port/run-matched-performance.mjs',
      '--linux-only',
      '--compare-only',
      '--profile nightly',
      'node scripts/linux-port/run-perf-budget.mjs',
      '--input-dir "$raw_input"',
      '--output-dir "$evidence_root"',
      '--raw-evidence-dir "$evidence_root"',
      '--session-report "$input_root/p32-installed-performance-session.json"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-33', {
    step: 'Capture P-33 installed reliability proof',
    runner: 'scripts/linux-port/run-p33-native-reliability-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p33-reliability-session.mjs',
    capture: 'scripts/linux-port/capture-p33-reliability-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p33-evidence.XXXXXX")"',
      'state_home="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p33-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$state_home" || status=1',
      'chmod 700 "$evidence_root" "$state_home"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/bin/openburnbar-daemon',
      'test -x /usr/bin/openburnbar',
      '--state-home "$state_home"',
      '--compositor "$compositor"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-35', {
    step: 'Capture P-35 installed diagnostics and support proof',
    runner: 'scripts/linux-port/run-p35-native-diagnostics-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p35-diagnostics-support-session.mjs',
    capture: 'scripts/linux-port/capture-p35-diagnostics-support-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p35-evidence.XXXXXX")"',
      'destination_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p35-destination.XXXXXX")"',
      'state_home="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p35-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$state_home" "$destination_root" || status=1',
      'chmod 700 "$evidence_root" "$state_home" "$destination_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/bin/openburnbar-daemon',
      '--destination-dir "$destination_root"',
      '--state-home "$state_home"',
      '--compositor "$compositor"'
    ]
  });
  requireInstalledUiCaptureContract(input.productParityWorkflow, 'P-36', {
    step: 'Capture P-36 installed visual and interaction polish proof',
    runner: 'scripts/linux-port/run-p36-native-visual-polish-probes.mjs',
    materializer: 'scripts/linux-port/materialize-p36-visual-polish-session.mjs',
    capture: 'scripts/linux-port/capture-p36-visual-polish-proof.mjs',
    requiredLines: [
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p36-evidence.XXXXXX")"',
      'state_home="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p36-home.XXXXXX")"',
      'rm -rf "$evidence_root" "$state_home" || status=1',
      'chmod 700 "$evidence_root" "$state_home"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'command -v tauri-driver >/dev/null',
      'command -v WebKitWebDriver >/dev/null',
      '--state-home "$state_home"',
      '--compositor "$compositor"'
    ]
  });
  for (const marker of [
    'p32-macos-producer',
    'P-32 macOS nightly performance producer',
    'Capture P-32 candidate-bound macOS nightly performance',
    '--macos-only',
    '--profile nightly',
    'linux-p32-macos-nightly-performance',
    'Download P-32 macOS nightly performance'
  ]) requireText(input.productParityWorkflow, marker, 'P-32 cross-platform performance wiring');
  for (const marker of [
    'Resolve P-25 authenticated previous release',
    "if: inputs.requirement == 'P-25'",
    'id: p25_previous',
    'resolve-linux-previous-release.mjs --github-output',
    'PREVIOUS_VERSION: ${{ steps.p25_previous.outputs.version }}',
    'PREVIOUS_TAG: ${{ steps.p25_previous.outputs.tag }}',
    'bash scripts/linux-port/run-p25-installed-update-proof-workflow.sh'
  ]) requireText(input.productParityWorkflow, marker, 'P-25 installed updates workflow');
  for (const marker of [
    'set -euo pipefail',
    'P-25 prerequisite missing',
    'gh release download "$PREVIOUS_TAG"',
    'product-proof-closure.json.ed25519.sig',
    'run-p25-installed-update-lifecycle.mjs',
    '--previous-package "$previous_package"',
    '--candidate-package "$candidate_package"',
    '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
    '--release-public-key packaging/linux/openburnbar-linux-ed25519.pub.pem',
    'materialize-p25-updates-session.mjs',
    'capture-p25-updates-proof.mjs',
    'rm -rf "$evidence_root" || status=1'
  ]) requireText(input.p25Workflow, marker, 'P-25 installed updates orchestrator');
  for (const marker of [
    'p25-installed-update-lifecycle.test.mjs',
    'p25-native-update-probes.test.mjs',
    'p25-updates-proof.test.mjs'
  ]) requireText(input.pr, marker, 'P-25 PR gate');
  for (const marker of [
    'p15-account-billing-proof.test.mjs',
    'p16-cloud-devices-proof.test.mjs',
    'p16-physical-ipad-coordination.test.mjs',
    'p33-reliability-proof.test.mjs',
    'p35-diagnostics-support-proof.test.mjs',
    'p36-visual-polish-proof.test.mjs',
    'install-tauri-webdriver-prerequisites.test.mjs'
  ]) requireText(input.pr, marker, 'new installed proof PR gate');
  requireP39CaptureContract(input.productParityWorkflow);
  for (const marker of [
    'p39-macos-producer',
    'P-39 macOS parser corpus producer',
    'capture-p39-platform-evidence.mjs',
    '--platform macos',
    'linux-p39-macos-platform-evidence',
    'Download P-39 macOS platform evidence'
  ]) requireText(input.productParityWorkflow, marker, 'P-39 cross-platform producer wiring');
  if (/--run-id\s+['"]?\$\{\{\s*inputs\.candidate_run_id/u.test(input.productParityWorkflow)) {
    failures.push('product parity workflow may not interpolate candidate_run_id directly into shell.');
  }
  requireOrder(input.productParityWorkflow, [
    'Download exact-candidate installed evidence',
    'Download P-39 macOS platform evidence',
    'Download P-32 macOS nightly performance',
    'Capture P-38 release automation verification',
    'Capture parity certification preflight',
    'Preserve non-promotable P-02 diagnostic evidence',
    'Install P-08 signed candidate package',
    'Capture P-08 installed Mercury media proof',
    'Install signed candidate for installed feature proofs',
    'Provision native Tauri WebDriver prerequisites',
    'Capture P-09 installed navigation shell proof',
    'Capture P-10 installed dashboard layout proof',
    'Capture P-11 installed usage ingestion proof',
    'Capture P-12 installed quota proof',
    'Capture P-13 installed onboarding proof',
    'Capture P-14 installed chat proof',
    'Capture P-15 installed account and billing proof',
    'Capture P-16 installed cloud and devices proof',
    'Capture P-17 installed Activity proof',
    'Capture P-18 installed memory-review proof',
    'Capture P-19 installed Projects proof',
    'Capture P-20 installed Missions proof',
    'Capture P-21 installed Insights proof',
    'Capture P-22 installed Database proof',
    'Capture P-23 installed Provider workspace proof',
    'Capture P-24 installed Settings proof',
    'Capture P-26 installed tray proof',
    'Capture P-30 installed pet proof',
    'Capture P-27 installed notification and deep-link proof',
    'Capture P-28 installed SmartHub proof',
    'Capture P-29 installed text expansion proof',
    'Capture P-32 installed performance proof',
    'Capture P-33 installed reliability proof',
    'Capture P-35 installed diagnostics and support proof',
    'Capture P-36 installed visual and interaction polish proof',
    'Resolve P-25 authenticated previous release',
    'Capture P-25 installed Updates proof',
    'Capture P-31 installed accessibility matrix evidence',
    'Capture P-34 credential security proof',
    'Capture P-39 Linux candidate-bound platform evidence',
    'Resolve P-39 candidate-bound platform evidence inputs',
    'Capture P-39 same-commit macOS/Linux differential proof',
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
    'text-expansion-native-evidence.test.mjs',
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
  requireNightlyMacosArtifactRetryContract(input.nightly);
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
    'Resolve signed Domain Core profile for Linux artifact',
    'Download signed text-expansion trust',
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
  requireText(input.pr, 'npm run typecheck --prefix apps/linux-desktop', 'PR TypeScript typecheck gate');
  if (/TypeScript typecheck[\s\S]{0,200}continue-on-error:\s*true/i.test(input.pr)) {
    failures.push('TypeScript typecheck gate may not continue on error.');
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
