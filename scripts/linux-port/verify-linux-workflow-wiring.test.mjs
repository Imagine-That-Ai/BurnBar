import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { verifyLinuxWorkflowWiring } from './verify-linux-workflow-wiring.mjs';

function valid() {
  const refresh = fs.readFileSync(new URL('../../.github/workflows/linux-repository-refresh.yml', import.meta.url), 'utf8');
  return {
    prYaml: fs.readFileSync(new URL('../../.github/workflows/linux-pr-gate.yml', import.meta.url), 'utf8'),
    productParityWorkflow: fs.readFileSync(
      new URL('../../.github/workflows/linux-product-parity.yml', import.meta.url),
      'utf8'
    ),
    releaseYaml: fs.readFileSync(new URL('../../.github/workflows/linux-release.yml', import.meta.url), 'utf8'),
    refresh,
    refreshYaml: refresh,
    refreshEvidenceUploader: fs.readFileSync(
      new URL('./upload-linux-repository-refresh-evidence.mjs', import.meta.url),
      'utf8'
    ),
    pr: [
      'bash scripts/linux-port/run-linux-native-tests.sh',
      'crates/openburnbar-attestd/**',
      'schemas/linux-attestation-*',
      'tests/fixtures/linux-attestation/**',
      'linux-attestation-contract.test.mjs',
      'verify-linux-release.test.mjs',
      'assemble-linux-release.test.mjs',
      'build-linux-release-boundary.test.mjs',
      'build-native-linux-packages-boundary.test.mjs',
      'linux-package-session.test.mjs',
      'linux-native-signing-receipt.test.mjs',
      'scripts/linux-port/browser-runtime-packaging.test.mjs',
      'scripts/linux-port/aur-browser-runtime-packaging.test.mjs',
      'scripts/linux-port/embed-linux-appimage-payload.test.mjs',
      'workers/linux-repository-router/**',
      'workers/linux-repository-router/package-lock.json',
      'workers/linux-repository-router/wrangler-upload.jsonc',
      'workers/linux-repository-router/wrangler-control.jsonc',
      'workers/linux-repository-router/wrangler-feed.jsonc',
      'setup-linux-downloads-r2.test.mjs',
      'activate-linux-repository.test.mjs',
      'fetch-linux-repository-snapshot.test.mjs',
      'inspect-linux-repository-freshness.test.mjs',
      'rebind-linux-repository-feed.test.mjs',
      'upload-linux-repository-refresh.test.mjs',
      'drill-linux-repository-rollback.test.mjs',
      'compensate-linux-repository-activation.test.mjs',
      'cleanup-linux-github-release.test.mjs',
      'verify-linux-public-repository.test.mjs',
      'publish-linux-update-feed-r2.test.mjs',
      'upload-linux-repository-refresh-evidence.test.mjs',
      'npm test --prefix workers/linux-repository-router',
      'wrangler deploy',
      '--dry-run',
      'render-parity-ledger.mjs --check',
      'attest-product-requirement.test.mjs',
      'live-installed-product-evidence.test.mjs',
      'npm ci --prefix scripts/linux-port --ignore-scripts',
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
      'linux-parity-matched-performance-nightly',
      'npm ci --prefix scripts/linux-port --ignore-scripts'
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
      '--prepare-only',
      '--private-key-stdin',
      '--finalize-only',
      'previous_version',
      'linux-desktop-session.sh',
      'verify-linux-package-update-rollback.sh',
      'finalize-linux-architecture-session.mjs',
      'linux-release-shard-${{ matrix.architecture }}',
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
      'repository-activation-compensation.json',
      'receipt.passed !== true || receipt.contained !== true',
      'https://downloads.burnbar.ai/latest-linux.json',
      'https://downloads.burnbar.ai/linux/update/$channel/latest-linux.json',
      'vars.OPENBURNBAR_LINUX_FIREBASE_APP_ID',
      'vars.APP_CHECK_STANDARD_WEB_APP_IDS',
      '${OPENBURNBAR_LINUX_FIREBASE_APP_ID:?',
      '${APP_CHECK_STANDARD_WEB_APP_IDS:?',
      '-e OPENBURNBAR_LINUX_FIREBASE_APP_ID',
      '-e APP_CHECK_STANDARD_WEB_APP_IDS',
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
      'unset OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM',
      'printf signing_key',
      'assemble-linux-release.mjs',
      '--private-key-stdin',
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
      'Enforce atomic repository publication outcome',
      'steps.deploy_repository_routes.outcome',
      'steps.verify_public_repository.outcome',
      'steps.verify_public_lifecycle.outcome',
      'steps.drill_repository_rollback.outcome',
      'steps.publish_feed_pointer.outcome',
      'steps.deploy_feed_routes.outcome',
      'steps.verify_public_feed.outcome',
      'steps.verify_live_feed.outcome',
      'steps.attest_repository_publication.outcome',
      'steps.publish_github_release.outcome'
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
      'cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked',
      'RUSTUP_TOOLCHAIN=1.94.0',
      'build_attestd_test_harness',
      'cargo test --manifest-path "${manifest}" --locked --lib --no-run',
      'run_attestd_tests',
      'cargo clippy --manifest-path crates/openburnbar-attestd/Cargo.toml'
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
      'runtime_capability_unknown_evaluator',
      '"--runtime-capabilities"',
      'TRAY_INIT_FAILED.store(true, Ordering::Relaxed)',
      'serialize_runtime_capabilities(&manifest)'
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

test('product requirement attester mutation suite is mandatory in the PR gate', () => {
  const input = valid();
  input.prYaml = input.prYaml.replace('attest-product-requirement.test.mjs', 'removed-attester-tests');
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /product evidence suite/u);
});

test('live installed product trust-boundary suite is mandatory in the PR gate', () => {
  const input = valid();
  input.prYaml = input.prYaml.replace(
    'live-installed-product-evidence.test.mjs',
    'removed-live-install-tests'
  );
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /product evidence suite/u);
});

test('a comment mentioning the attester suite cannot satisfy PR execution wiring', () => {
  const input = valid();
  input.prYaml = input.prYaml
    .replace('scripts/linux-port/attest-product-requirement.test.mjs', 'scripts/linux-port/removed-attester-tests.mjs')
    .concat('\n# node --test scripts/linux-port/attest-product-requirement.test.mjs\n');
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /product evidence suite/u);
});

test('product receipt provenance generation is structurally mandatory', () => {
  const input = valid();
  input.productParityWorkflow = input.productParityWorkflow.replace(
    'actions/attest@59d89421af93a897026c735860bf21b6eb4f7b26',
    'actions/attest@removed'
  );
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /pinned actions\/attest/u);
});

test('product evidence must resolve the trusted release run before immutable-id download', () => {
  const mutations = [
    ['resolve-product-evidence-run.mjs', 'removed-evidence-resolver.mjs'],
    ['artifact-ids: ${{ steps.evidence.outputs.artifact_id }}', 'name: caller-selected-artifact'],
    ['repository: Imagine-That-Ai/BurnBar', 'repository: attacker/fork'],
    ['run-id: ${{ inputs.release_run_id }}', 'run-id: ${{ inputs.other_run_id }}'],
    ['release_run_id:', 'evidence_artifact:']
  ];
  for (const [from, to] of mutations) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replace(from, to);
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, from);
    assert.match(result.failures.join('\n'), /product parity workflow/u);
  }
});

test('repository refresh schedule, serialization, and manual channel contract are structural', () => {
  const mutations = [
    ['17 */6 * * *', '18 */6 * * *'],
    ['group: linux-repository-release', 'group: linux-repository-refresh'],
    ['cancel-in-progress: false', 'cancel-in-progress: true'],
    ['max-parallel: 1', 'max-parallel: 3'],
    ['- nightly', '- other']
  ];
  for (const [from, to] of mutations) {
    const input = valid();
    input.refresh = input.refresh.replace(from, to);
    input.refreshYaml = input.refreshYaml.replace(from, to);
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, from);
  }
});

test('repository refresh cannot load the signing key early or publish release/feed bytes', () => {
  for (const forbidden of [
    'gh release create linux-v1.2.3',
    'bash scripts/publish-linux-update-feed-r2.sh --publish-only',
    'curl https://downloads.burnbar.ai/linux/repository-admin/publish-feed',
    'key=linux/releases/linux-v1.2.3/latest-linux.json'
  ]) {
    const input = valid();
    input.refresh += `\n${forbidden}`;
    input.refreshYaml = input.refresh;
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, forbidden);
  }
  const input = valid();
  input.refresh = input.refresh.replace(
    'FORCE_REFRESH:',
    'OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY: ${{ secrets.OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY }}\n          FORCE_REFRESH:'
  );
  input.refreshYaml = input.refresh;
  assert.equal(verifyLinuxWorkflowWiring(input).passed, false);
});

test('repository refresh reauthenticates the exact fetched parent before signing', () => {
  for (const marker of [
    'freshness.current?.snapshotId !== snapshotId',
    'acquisition.snapshotId !== snapshotId',
    "steps.verify_parent_snapshot.outcome == 'success'",
    "--repository-root '/workspace/.linux-refresh-source/${{ matrix.channel }}'"
  ]) {
    const input = valid();
    input.refresh = input.refresh.replaceAll(marker, 'removed-parent-authentication');
    input.refreshYaml = input.refresh;
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test('every repository refresh post-activation step remains compensated', () => {
  for (const id of [
    'activate_refresh',
    'rebind_feed',
    'verify_feed_pointer',
    'verify_live_feed',
    'verify_public_repository',
    'verify_public_lifecycle',
    'attest_refresh',
    'upload_refresh_evidence'
  ]) {
    const input = valid();
    input.refresh = input.refresh.replace(`steps.${id}.outcome != 'success'`, `steps.${id}.outcome == 'success'`);
    input.refreshYaml = input.refresh;
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, id);
    assert.match(result.failures.join('\n'), new RegExp(`compensation condition omits transaction step: ${id}`, 'u'));
  }
});

test('repository refresh feed rebind and containment gate cannot be removed', () => {
  for (const marker of [
    'rebind-linux-repository-feed.mjs',
    '--target current',
    '--output "$OPENBURNBAR_LINUX_EVIDENCE_OUT/repository-refresh-feed-rebind.json"',
    'publish-linux-update-feed-r2.sh --verify-only',
    'check-linux-update-feed.mjs --url',
    'repository-refresh-feed-verification.json',
    'upload-linux-repository-refresh-evidence.mjs',
    'repository-refresh-evidence-closure.json',
    'repository-refresh-evidence-upload.json',
    'activationGeneration',
    'transactionInputs',
    'repository-refresh-compensation.json',
    'receipt.passed !== true || receipt.contained !== true'
  ]) {
    const input = valid();
    input.refresh = input.refresh.replaceAll(marker, 'removed-refresh-contract');
    input.refreshYaml = input.refresh;
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test('repository refresh production branch and Sigstore verifier identity cannot drift', () => {
  const branch = valid();
  branch.refresh = branch.refresh.replaceAll('refs/heads/main', 'refs/heads/feature');
  branch.refreshYaml = branch.refresh;
  assert.equal(verifyLinuxWorkflowWiring(branch).passed, false);

  for (const marker of [
    'verify-blob-attestation',
    '--certificate-identity',
    'linux-repository-refresh.yml@refs/heads/main',
    '--certificate-oidc-issuer',
    'https://token.actions.githubusercontent.com'
  ]) {
    const input = valid();
    input.refreshEvidenceUploader = input.refreshEvidenceUploader.replaceAll(marker, 'removed-sigstore-contract');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test('repository refresh upload credentials remain scoped to immutable upload steps', () => {
  const jobScoped = valid();
  jobScoped.refresh = jobScoped.refresh.replace(
    'OPENBURNBAR_LINUX_REFRESH_CHANNEL:',
    'OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN: ${{ secrets.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN }}\n      OPENBURNBAR_LINUX_REFRESH_CHANNEL:'
  );
  jobScoped.refreshYaml = jobScoped.refresh;
  assert.equal(verifyLinuxWorkflowWiring(jobScoped).passed, false);

  const attestationScoped = valid();
  attestationScoped.refresh = attestationScoped.refresh.replace(
    'id: attest_refresh',
    'id: attest_refresh\n        env:\n          OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN: ${{ secrets.OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN }}'
  );
  attestationScoped.refreshYaml = attestationScoped.refresh;
  assert.equal(verifyLinuxWorkflowWiring(attestationScoped).passed, false);
});

test('every post-activation stage remains inside the compensated publication transaction', () => {
  for (const marker of [
    'steps.deploy_repository_routes.outcome',
    'steps.verify_public_repository.outcome',
    'steps.verify_public_lifecycle.outcome',
    'steps.drill_repository_rollback.outcome',
    'steps.publish_feed_pointer.outcome',
    'steps.deploy_feed_routes.outcome',
    'steps.verify_public_feed.outcome',
    'steps.verify_live_feed.outcome',
    'steps.attest_repository_publication.outcome',
    'steps.publish_github_release.outcome',
    'repository-activation-compensation.json',
    'receipt.passed !== true || receipt.contained !== true'
  ]) {
    const input = valid();
    input.release = input.release.replace(marker, 'removed-transaction-marker');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test('release transaction structure rejects decoy markers and compensation-condition omissions', () => {
  const missingCondition = valid();
  missingCondition.releaseYaml = missingCondition.releaseYaml.replace(
    "steps.verify_live_feed.outcome != 'success' ||",
    "steps.verify_live_feed.outcome == 'success' ||"
  );
  let result = verifyLinuxWorkflowWiring(missingCondition);
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /compensation condition omits transaction step: verify_live_feed/u);

  const decoyCleanup = valid();
  decoyCleanup.releaseYaml = decoyCleanup.releaseYaml.replace(
    '        id: cleanup_github_release',
    '        # id: cleanup_github_release'
  );
  result = verifyLinuxWorkflowWiring(decoyCleanup);
  assert.equal(result.passed, false);
  assert.match(result.failures.join('\n'), /step id is missing: cleanup_github_release/u);
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

test('installed-manifest signing key cannot enter the build container environment', () => {
  const input = valid();
  input.release += '\ndocker run -e OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM builder';
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /signing key/.test(failure)));
});

test('aggregate signer must scrub the key environment and use stdin custody', () => {
  const missingScrub = valid();
  missingScrub.release = missingScrub.release.replace('unset OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM', '');
  assert.equal(verifyLinuxWorkflowWiring(missingScrub).passed, false);

  const missingAggregateStdin = valid();
  const first = missingAggregateStdin.release.indexOf('--private-key-stdin');
  const second = missingAggregateStdin.release.indexOf('--private-key-stdin', first + 1);
  missingAggregateStdin.release = `${missingAggregateStdin.release.slice(0, second)}${missingAggregateStdin.release.slice(second + '--private-key-stdin'.length)}`;
  const result = verifyLinuxWorkflowWiring(missingAggregateStdin);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /aggregate release signers/u.test(failure)));
});

test('native signer requires a dedicated Linux Firebase id and the standard Web collision registry', () => {
  for (const marker of [
    'vars.OPENBURNBAR_LINUX_FIREBASE_APP_ID',
    'vars.APP_CHECK_STANDARD_WEB_APP_IDS',
    '${OPENBURNBAR_LINUX_FIREBASE_APP_ID:?',
    '${APP_CHECK_STANDARD_WEB_APP_IDS:?',
    '-e OPENBURNBAR_LINUX_FIREBASE_APP_ID',
    '-e APP_CHECK_STANDARD_WEB_APP_IDS'
  ]) {
    const input = valid();
    input.release = input.release.replace(marker, '');
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(result.failures.some((failure) => /dedicated Linux Firebase release identity/.test(failure)), marker);
  }
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
    'https://downloads.burnbar.ai/latest-linux.json',
    'https://downloads.burnbar.ai/linux/update/$channel/latest-linux.json'
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

test('native signing phase-boundary and receipt suites cannot be removed', () => {
  for (const marker of [
    'build-linux-release-boundary.test.mjs',
    'build-native-linux-packages-boundary.test.mjs',
    'linux-native-signing-receipt.test.mjs'
  ]) {
    const input = valid();
    input.pr = input.pr.replace(marker, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
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

test('attestation broker, schema, and fixture changes must trigger the Linux PR gate', () => {
  for (const [marker, failurePattern] of [
    ['crates/openburnbar-attestd/**', /attestation broker path trigger/],
    ['schemas/linux-attestation-*', /attestation schema path trigger/],
    ['tests/fixtures/linux-attestation/**', /attestation fixture path trigger/]
  ]) {
    const input = valid();
    input.pr = input.pr.replace(marker, '');
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(result.failures.some((failure) => failurePattern.test(failure)), marker);
  }
});

test('attestation schema contract suite cannot be removed from the PR gate', () => {
  const input = valid();
  input.pr = input.pr.replace('linux-attestation-contract.test.mjs', '');
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /attestation schema contract suite/.test(failure)));
});

test('clean-checkout docs dependency install cannot be removed', () => {
  for (const workflow of ['pr', 'nightly']) {
    const input = valid();
    input[workflow] = input[workflow].replace('npm ci --prefix scripts/linux-port --ignore-scripts', '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, workflow);
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
    ['rustBridge', 'runtime_capability_unknown_evaluator'],
    ['rustBridge', '"--runtime-capabilities"'],
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
