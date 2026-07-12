import assert from 'node:assert/strict';
import test from 'node:test';
import { verifyLinuxWorkflowWiring } from './verify-linux-workflow-wiring.mjs';

function valid() {
  return {
    pr: [
      'bash scripts/linux-port/run-linux-native-tests.sh',
      'verify-linux-release.test.mjs',
      'assemble-linux-release.test.mjs',
      'linux-aggregate-installed-attestation.test.mjs',
      'linux-package-session.test.mjs',
      'linux-installed-manifest.test.mjs',
      'linux-appimage-peer-manifest.test.mjs',
      'linux-native-package-real-tools.test.mjs',
      'sign-linux-release-requests.test.mjs',
      'signed-installed-package-wiring.test.mjs',
      'scripts/linux-port/browser-runtime-packaging.test.mjs',
      'scripts/linux-port/aur-browser-runtime-packaging.test.mjs',
      'scripts/linux-port/arch-package-lifecycle.test.mjs',
      'scripts/linux-port/embed-linux-appimage-payload.test.mjs',
      'render-parity-ledger.mjs --check',
      'npm ci --prefix scripts/linux-port --ignore-scripts',
      'attest-product-requirement.test.mjs',
      'github-artifact-provenance.test.mjs',
      'live-installed-product-evidence.test.mjs',
      'smoke-linux-packages.test.mjs',
      'product-proof-closure.test.mjs',
      'product-feature-proof-closure.test.mjs',
      'parity-certification-preflight.test.mjs',
      'run-linux-matrix-harness.test.mjs',
      'run-product-requirement-validator.test.mjs',
      'resolve-product-evidence-run.test.mjs',
      'resolve-product-receipt-artifacts.test.mjs',
      'macos-matched-performance',
      'run-matched-performance.mjs',
      '--profile pr',
      'matched-performance-contract.test.mjs',
      'perf-budget-contract.test.mjs',
      'linux-parity-macos-performance-pr'
    ].join('\n'),
    productParityWorkflow: [
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
      'capture-parity-certification-preflight.mjs',
      "if: inputs.requirement == 'P-02'",
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
      'finalize-product-feature-proof-closure.mjs',
      'prepare-product-requirement-input.mjs',
      'run-product-requirement-validator.mjs',
      '--candidate-run-id "$CANDIDATE_RUN_ID"',
      '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
      'uses: actions/attest@',
      '.sigstore.jsonl',
      'if-no-files-found: error',
      'include-hidden-files: true',
      'Download exact-candidate installed evidence',
      'Capture parity certification preflight',
      'Preserve non-promotable P-02 diagnostic evidence',
      'Finalize registered feature proof closure',
      'Materialize the requirement-owned release closure',
      'Run the registered requirement validator'
    ].join('\n'),
    promotionWorkflow: [
      'resolve-product-evidence-run.mjs',
      'resolve-product-receipt-artifacts.mjs',
      'artifact_count }}" = "280"',
      'attest-product-requirement.mjs --requirement "P-${number}"',
      'validate-parity-ledger.mjs',
      'verify-linux-release.mjs',
      '--candidate',
      'finalize-linux-promotion-closure.mjs',
      'uses: actions/attest@',
      'promotion-closure.json.sigstore.jsonl',
      '--candidate-artifact-digest',
      '--draft',
      '--draft=false',
      "'*source-*.tar'",
      "-name '*.pkg.tar.zst'",
      "-name 'PKGBUILD'",
      "-name 'arch-release-metadata.json'",
      "-name 'openburnbar-*.installed-manifest.json'",
      "-name 'openburnbar-*.installed-manifest.ed25519'",
      'OPENBURNBAR_R2_CUSTOM_DOMAIN: downloads.burnbar.ai',
      'upload-linux-downloads-r2.sh',
      'https://downloads.burnbar.ai/latest-linux.json',
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
      'Publish verified Linux GitHub release',
      '      - name: Upload promotion closure\n        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4\n        with:\n          path: ${{ env.OPENBURNBAR_LINUX_RELEASE_OUT }}/promotion/\n          include-hidden-files: true\n          if-no-files-found: error'
    ].join('\n'),
    nightly: [
      'OPENBURNBAR_LINUX_EVIDENCE_OUT',
      'macos-matched-performance',
      'linux-matched-performance',
      '--profile nightly',
      'OB_MATCHED_MACOS_INPUT',
      'OB_MATCHED_LINUX_INPUT',
      'linux-parity-matched-performance-nightly'
    ].join('\n'),
    release: [
      '- "linux-v*"',
      'resolve-linux-release-version.mjs --github-output',
      'OPENBURNBAR_LINUX_RELEASE_OUT',
      'OPENBURNBAR_LINUX_EVIDENCE_OUT',
      "'*.sigstore.json'",
      'list-linux-release-attestation-subjects.mjs',
      "'*source-*.tar'",
      "'*parity-attestation.json'",
      'architecture: aarch64',
      'runner: ubuntu-24.04-arm',
      'architecture: x86_64',
      'runner: ubuntu-24.04',
      '--architecture-shard',
      '--phase prepare',
      '--network none',
      '--read-only',
      '--cap-drop ALL',
      '--security-opt no-new-privileges',
      'sign-linux-release-requests.mjs',
      'build-signed-arch-package.mjs',
      'smoke-arch-package.mjs',
      'verify-arch-package-update-rollback.mjs',
      'docker create --name "$container"',
      'docker start --attach "$container"',
      '--phase finalize',
      'previous_version',
      'linux-desktop-session.sh',
      'verify-linux-package-update-rollback.sh',
      'finalize-linux-architecture-session.mjs',
      'linux-release-shard-${{ matrix.architecture }}',
      'assemble-linux-release.mjs',
      '--candidate',
      'finalize-product-proof-closure.mjs',
      'include-hidden-files: true',
      'merge-multiple: false',
      'npm ci --prefix scripts/linux-port --ignore-scripts',
      'Resolve and validate Linux release version',
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
      '      - name: Upload architecture shard\n        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4\n        with:\n          path: ${{ env.OPENBURNBAR_LINUX_RELEASE_OUT }}/\n          include-hidden-files: true\n          if-no-files-found: error',
      '      - name: Upload Linux release evidence\n        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4\n        with:\n          path: |\n            ${{ env.OPENBURNBAR_LINUX_RELEASE_OUT }}/\n            ${{ env.OPENBURNBAR_LINUX_EVIDENCE_OUT }}/\n            ${{ env.OPENBURNBAR_LINUX_SHARDS_DIR }}/\n          include-hidden-files: true\n          if-no-files-found: error'
    ].join('\n'),
    makefile: 'release-linux:\n\tnode verify\n\nother:',
    nativeTests: [
      'run_swift_suite',
      'OpenBurnBarLinuxCoreFoundationTests',
      'OpenBurnBarLinuxSecurityTests',
      'OpenBurnBarDaemonLinuxGatewayTests',
      'timeout 900 swift test',
      'run_xctest_case',
      'Executed 1 test',
      'cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked'
    ].join('\n'),
    rustBridge: [
      'gateway_probe',
      'gateway_chat_stream',
      'gateway_chat_cancel',
      '.bearer_auth(token)',
      'gateway_non_loopback_host_refused',
      'Policy::none()',
      'validate_external_url',
      'open_external_url',
      'external_url_host_refused',
      'trusted_openburnbar_cli',
      '/usr/bin/openburnbar-cli',
      'runtime_capabilities',
      'RUNTIME_CAPABILITY_CATALOG',
      'runtime_capability_unknown_evaluator'
    ].join('\n'),
    updateFeed: [
      'PINNED_PUBLIC_KEY_SPKI_SHA256',
      'verify_strict',
      'validate_update_artifact_url',
      'allowed_download_url',
      'MAX_FEED_BYTES'
    ].join('\n'),
    capability: '{"permissions":["core:default"]}',
    tauriConfig: '{"csp":"connect-src self ipc: tauri:"}',
    fixturePolicy: 'DAEMON_FIXTURE_AVAILABLE\nenabled && DAEMON_FIXTURE_AVAILABLE',
    desktopPackage: 'vite build && node ../../scripts/linux-port/verify-linux-production-bundle.mjs',
    rendererBridge: [
      "invoke<boolean>('gateway_probe')",
      "invoke<void>('gateway_chat_stream'",
      "invoke<void>('gateway_chat_cancel'",
      "invoke<void>('open_external_url'",
      "invoke<RawJsonValue>('update_status')",
      "invoke<void>('open_update_url'",
      "invoke<RawJsonValue>('runtime_capabilities')",
      'decodeRuntimeCapabilityManifest',
      'runtime_capability_manifest_missing_ids'
    ].join('\n'),
    runtimeCatalog: '{"schemaVersion": 1}',
    runtimeSchema: '{"additionalProperties": false}',
    routes: 'requiredCapability\nusage.read\nmedia.mercury',
    surfaceBoundary: 'capabilityBlocksSurface\nfindRuntimeCapability\ncapabilityError'
  };
}

test('complete fail-closed workflow wiring passes', () => {
  assert.deepEqual(verifyLinuxWorkflowWiring(valid()), { passed: true, failures: [] });
});

test('hidden Linux output uploads fail closed when upload protections mutate', () => {
  for (const [surface, step, mutation] of [
    ['release', 'Upload architecture shard', 'include-hidden-files: false'],
    ['release', 'Upload Linux release evidence', 'if-no-files-found: warn'],
    ['promotionWorkflow', 'Upload promotion closure', 'actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874']
  ]) {
    const input = valid();
    const start = input[surface].indexOf(`- name: ${step}`);
    assert.ok(start >= 0, step);
    const original = mutation.startsWith('include-hidden')
      ? 'include-hidden-files: true'
      : mutation.startsWith('if-no-files')
        ? 'if-no-files-found: error'
        : 'actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4';
    input[surface] = `${input[surface].slice(0, start)}${input[surface].slice(start).replace(original, mutation)}`;
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, `${surface}:${step}`);
  }
});

test('product evidence dependency install and mutation suites are mandatory in the PR gate', () => {
  for (const marker of [
    'npm ci --prefix scripts/linux-port --ignore-scripts',
    'attest-product-requirement.test.mjs',
    'github-artifact-provenance.test.mjs',
    'smoke-linux-packages.test.mjs',
    'product-feature-proof-closure.test.mjs',
    'run-linux-matrix-harness.test.mjs',
    'run-product-requirement-validator.test.mjs'
  ]) {
    const input = valid();
    input.pr = input.pr.replace(marker, 'removed');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test('product evidence producer identity and immutable artifact wiring fail closed independently', () => {
  for (const marker of [
    'id-token: write',
    'ref: ${{ github.sha }}',
    '--run-id "$CANDIDATE_RUN_ID"',
    '--target-head "$TARGET_HEAD"',
    'artifact-ids: ${{ steps.evidence.outputs.artifact_id }}',
    'id: p02_capture',
    'mktemp -d "${RUNNER_TEMP}/openburnbar-p02.XXXXXX"',
    "printf 'diagnostic_root=%s\\n' \"$diagnostic_root\" >> \"$GITHUB_OUTPUT\"",
    '--diagnostic-root "$diagnostic_root"',
    '${{ steps.p02_capture.outputs.diagnostic_root }}/',
    'capture-failure.json',
    'capture.log',
    '2>&1 | tee "$capture_log"',
    'finalize-product-feature-proof-closure.mjs',
    'uses: actions/attest@',
    '.sigstore.jsonl',
    'include-hidden-files: true'
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replace(marker, 'removed');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test('free-form candidate run input cannot be interpolated directly into shell', () => {
  const input = valid();
  input.productParityWorkflow += "\n--run-id '${{ inputs.candidate_run_id }}'";
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /candidate_run_id directly into shell/u);
});

test('promotion must generate current-HEAD attestations before strict parity validation', () => {
  const missing = valid();
  missing.promotionWorkflow = missing.promotionWorkflow.replace('attest-product-requirement.mjs --requirement "P-${number}"', 'removed');
  assert.equal(verifyLinuxWorkflowWiring(missing).passed, false);

  const reordered = valid();
  reordered.promotionWorkflow = reordered.promotionWorkflow.replace(
    'Generate current-HEAD product parity attestations\nVerify strict product parity at promotion HEAD',
    'Verify strict product parity at promotion HEAD\nGenerate current-HEAD product parity attestations'
  );
  assert.equal(verifyLinuxWorkflowWiring(reordered).passed, false);
});

test('promotion cannot create its unignored candidate scratch tree before clean-HEAD attestation', () => {
  const input = valid();
  input.promotionWorkflow = input.promotionWorkflow.replace(
    'Generate current-HEAD product parity attestations\nVerify strict product parity at promotion HEAD\nDownload the exact candidate',
    'Download the exact candidate\nGenerate current-HEAD product parity attestations\nVerify strict product parity at promotion HEAD'
  );
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /Download the exact candidate/u.test(failure)));
});

test('candidate workflow cannot attest parity or publish', () => {
  for (const forbidden of ['attest-product-requirement.mjs', 'validate-parity-ledger.mjs', 'gh release create']) {
    const input = valid();
    input.release += `\n${forbidden}`;
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, forbidden);
  }
});

test('removing any native behavior or process-isolation command fails', () => {
  for (const marker of [
    'CoreFoundationTests',
    'LinuxSecurityTests',
    'LinuxGatewayTests',
    'timeout 900',
    'run_xctest_case',
    'Executed 1 test',
    'cargo test'
  ]) {
    const input = valid();
    input.nativeTests = input.nativeTests.split('\n').filter((line) => !line.includes(marker)).join('\n');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test('legacy tag, swallowed verifier, and sealed evidence paths fail', () => {
  const input = valid();
  input.release = input.release.replace('- "linux-v*"', '- "v*"');
  input.makefile = 'release-linux:\n\tnode verify || true\n\nother:';
  input.pr += '\nmission-001-release';
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /legacy v/.test(failure)));
  assert.ok(result.failures.some((failure) => /swallow/.test(failure)));
  assert.ok(result.failures.some((failure) => /sealed mission/.test(failure)));
});

test('promotion publication cannot omit source, closure bundle, or public key', () => {
  for (const marker of ['*source-*.tar', 'promotion-closure.json.sigstore.jsonl']) {
    const input = valid();
    input.promotionWorkflow = input.promotionWorkflow.replace(marker, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
  const input = valid();
  input.promotionWorkflow += '\ncp packaging/linux/openburnbar-linux-ed25519.pub.pem "$art/" || true';
  assert.equal(verifyLinuxWorkflowWiring(input).passed, false);
});

test('candidate architecture closure and promotion publication cannot be removed', () => {
  for (const marker of [
    'architecture: aarch64',
    'architecture: x86_64',
    '--architecture-shard',
    'linux-desktop-session.sh',
    'verify-linux-package-update-rollback.sh',
    'verify-arch-package-update-rollback.mjs',
    'finalize-linux-architecture-session.mjs',
    'assemble-linux-release.mjs',
    'list-linux-release-attestation-subjects.mjs',
    '--phase prepare',
    '--network none',
    '--read-only',
    '--cap-drop ALL',
    '--security-opt no-new-privileges',
    'sign-linux-release-requests.mjs',
    '--phase finalize',
    'merge-multiple: false'
  ]) {
    const input = valid();
    input.release = input.release.replace(marker, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
  for (const marker of [
    'OPENBURNBAR_R2_CUSTOM_DOMAIN: downloads.burnbar.ai',
    'upload-linux-downloads-r2.sh',
    'https://downloads.burnbar.ai/latest-linux.json'
  ]) {
    const input = valid();
    input.promotionWorkflow = input.promotionWorkflow.replace(marker, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test('package lifecycle finalizer regression suite cannot be removed', () => {
  const input = valid();
  input.pr = input.pr.replace('linux-package-session.test.mjs', '');
  assert.equal(verifyLinuxWorkflowWiring(input).passed, false);
});

test('each Browser Computer Use package-family suite is independently required', () => {
  for (const marker of [
    'scripts/linux-port/browser-runtime-packaging.test.mjs',
    'scripts/linux-port/aur-browser-runtime-packaging.test.mjs',
    'scripts/linux-port/embed-linux-appimage-payload.test.mjs'
  ]) {
    const input = valid();
    input.pr = input.pr.replace(marker, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});
test('attestation and publish order drift fails', () => {
  const input = valid();
  input.release = input.release.replace(
    'Pre-attestation Linux release verification\nAttest Linux release sidecars and packages',
    'Attest Linux release sidecars and packages\nPre-attestation Linux release verification'
  );
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /out of order/.test(failure)));
});

test('gateway bearer exposure or native boundary removal fails', () => {
  for (const forbidden of ['gatewayAuthToken', 'bearerToken', 'Authorization']) {
    const input = valid();
    input.rendererBridge += `\n${forbidden}`;
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, forbidden);
  }
  const exposed = valid();
  exposed.rustBridge += '\n#[tauri::command]\nfn gateway_auth_token() -> Option<String> { None }';
  assert.equal(verifyLinuxWorkflowWiring(exposed).passed, false);

  const missingProxy = valid();
  missingProxy.rustBridge = missingProxy.rustBridge.replace('gateway_chat_stream', '');
  assert.equal(verifyLinuxWorkflowWiring(missingProxy).passed, false);
});

test('generic shell, renderer network, and production fixture activation drift fail', () => {
  const broadShell = valid();
  broadShell.capability = '{"permissions":["core:default","shell:default"]}';
  assert.equal(verifyLinuxWorkflowWiring(broadShell).passed, false);

  const rendererNetwork = valid();
  rendererNetwork.rendererBridge += '\nfetch("http://127.0.0.1:8642/health")';
  assert.equal(verifyLinuxWorkflowWiring(rendererNetwork).passed, false);

  const broadCSP = valid();
  broadCSP.tauriConfig = '{"csp":"connect-src self http://127.0.0.1:* ipc:"}';
  assert.equal(verifyLinuxWorkflowWiring(broadCSP).passed, false);

  const unguardedFixture = valid();
  unguardedFixture.fixturePolicy = unguardedFixture.fixturePolicy.replace(
    'enabled && DAEMON_FIXTURE_AVAILABLE',
    'enabled'
  );
  assert.equal(verifyLinuxWorkflowWiring(unguardedFixture).passed, false);

  const ambientPathCommand = valid();
  ambientPathCommand.rustBridge += '\nCommand::new("openburnbar-cli")';
  assert.equal(verifyLinuxWorkflowWiring(ambientPathCommand).passed, false);
});

test('runtime capability catalog, evaluator, bridge, route, and boundary drift fail', () => {
  for (const [field, marker] of [
    ['rustBridge', 'runtime_capabilities'],
    ['rendererBridge', 'decodeRuntimeCapabilityManifest'],
    ['routes', 'requiredCapability'],
    ['surfaceBoundary', 'capabilityBlocksSurface'],
    ['runtimeCatalog', '"schemaVersion": 1'],
    ['runtimeSchema', '"additionalProperties": false']
  ]) {
    const input = valid();
    input[field] = input[field].replace(marker, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, `${field}:${marker}`);
  }
});

test('signed update verification and navigation boundaries cannot be removed', () => {
  for (const [field, marker] of [
    ['updateFeed', 'PINNED_PUBLIC_KEY_SPKI_SHA256'],
    ['updateFeed', 'verify_strict'],
    ['updateFeed', 'validate_update_artifact_url'],
    ['rendererBridge', "invoke<RawJsonValue>('update_status')"],
    ['rendererBridge', "invoke<void>('open_update_url'"]
  ]) {
    const input = valid();
    input[field] = input[field].replace(marker, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, `${field}:${marker}`);
  }
});

test('removing PR or nightly matched performance wiring fails', () => {
  for (const [field, marker] of [
    ['pr', '--profile pr'],
    ['pr', 'matched-performance-contract.test.mjs'],
    ['nightly', '--profile nightly'],
    ['nightly', 'OB_MATCHED_LINUX_INPUT']
  ]) {
    const input = valid();
    input[field] = input[field].replace(marker, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, `${field}:${marker}`);
  }
});
