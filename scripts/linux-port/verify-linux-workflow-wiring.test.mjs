import assert from 'node:assert/strict';
import test from 'node:test';
import { verifyLinuxWorkflowWiring } from './verify-linux-workflow-wiring.mjs';

function valid() {
  return {
    pr: [
      'bash scripts/linux-port/run-linux-native-tests.sh',
      'verify-linux-release.test.mjs',
      'assemble-linux-release.test.mjs',
      'linux-package-session.test.mjs',
      'render-parity-ledger.mjs --check',
      'include-hidden-files: true',
      'macos-matched-performance',
      'run-matched-performance.mjs',
      '--profile pr',
      'matched-performance-contract.test.mjs',
      'perf-budget-contract.test.mjs',
      'linux-parity-macos-performance-pr'
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
      "'*source-*.tar'",
      "'*parity-attestation.json'",
      'architecture: aarch64',
      'runner: ubuntu-24.04-arm',
      'architecture: x86_64',
      'runner: ubuntu-24.04',
      '--architecture-shard',
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
      'https://downloads.burnbar.ai/latest-linux.json',
      'Resolve and validate Linux release version',
      'Assert native runner architecture',
      'Build native architecture artifacts',
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
      'Publish Linux GitHub release',
      'Configure branded Linux update origin',
      'Publish signed update feed to downloads origin',
      'Verify live Linux update feed after publish'
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

test('release closure publication cannot omit source, parity, bundles, or public key', () => {
  for (const marker of ['*.sigstore.json', '*source-*.tar', '*parity-attestation.json']) {
    const input = valid();
    input.release = input.release.replace(`'${marker}'`, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
  const input = valid();
  input.release += '\ncp packaging/linux/openburnbar-linux-ed25519.pub.pem "$art/" || true';
  assert.equal(verifyLinuxWorkflowWiring(input).passed, false);
});

test('architecture matrix, aggregate closure, and feed publication cannot be removed', () => {
  for (const marker of [
    'architecture: aarch64',
    'architecture: x86_64',
    '--architecture-shard',
    'linux-desktop-session.sh',
    'verify-linux-package-update-rollback.sh',
    'finalize-linux-architecture-session.mjs',
    'assemble-linux-release.mjs',
    'merge-multiple: false',
    "-o -name 'latest-linux.json'",
    'OPENBURNBAR_R2_CUSTOM_DOMAIN: downloads.burnbar.ai',
    'upload-linux-downloads-r2.sh',
    'https://downloads.burnbar.ai/latest-linux.json'
  ]) {
    const input = valid();
    input.release = input.release.replace(marker, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test('package lifecycle finalizer regression suite cannot be removed', () => {
  const input = valid();
  input.pr = input.pr.replace('linux-package-session.test.mjs', '');
  assert.equal(verifyLinuxWorkflowWiring(input).passed, false);
});

test('hidden Linux evidence upload cannot be disabled', () => {
  const input = valid();
  input.pr = input.pr.replace('include-hidden-files: true', 'include-hidden-files: false');
  assert.equal(verifyLinuxWorkflowWiring(input).passed, false);
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
