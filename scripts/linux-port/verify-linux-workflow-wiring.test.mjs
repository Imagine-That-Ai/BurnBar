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
      'arch-lifecycle-authentication.test.mjs',
      'linux-installed-manifest.test.mjs',
      'linux-appimage-peer-manifest.test.mjs',
      'linux-native-package-real-tools.test.mjs',
      'validate-linux-release-public-config.test.mjs',
      'sign-linux-release-requests.test.mjs',
      'sign-product-proof-closure.test.mjs',
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
      'p07-computer-use-proof.test.mjs',
      'p08-mercury-media-proof.test.mjs',
      'p09-navigation-shell-proof.test.mjs',
      'p10-dashboard-layout-proof.test.mjs',
      'p11-usage-ingestion-proof.test.mjs',
      'p12-quota-proof.test.mjs',
      'p38-release-automation-proof.test.mjs',
      'p31-accessibility-proof.test.mjs',
      'p34-credential-security-proof.test.mjs',
      'parity-certification-preflight.test.mjs',
      'run-linux-matrix-harness.test.mjs',
      'run-product-requirement-validator.test.mjs',
      'resolve-product-evidence-run.test.mjs',
      'resolve-product-receipt-artifacts.test.mjs',
      'linux-toolchain-node-runtime.test.mjs',
      'macos-matched-performance',
      'run-matched-performance.mjs',
      '--profile pr',
      'matched-performance-contract.test.mjs',
      'perf-budget-contract.test.mjs',
      'text-expansion-native-evidence.test.mjs',
      'linux-parity-macos-performance-pr',
      '-v "$OPENBURNBAR_LINUX_EVIDENCE_OUT:/evidence"',
      '--env OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests',
      '      - name: Upload Linux gate evidence',
      '        if: always()',
      '        uses: actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874',
      '        with:',
      '          name: linux-pr-gate-evidence',
      '          path: ${{ env.OPENBURNBAR_LINUX_EVIDENCE_OUT }}/',
      '          include-hidden-files: true',
      '          if-no-files-found: warn',
      'npm run typecheck --prefix apps/linux-desktop'
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
      'p39-macos-producer',
      'P-39 macOS parser corpus producer',
      '--platform macos',
      'linux-p39-macos-platform-evidence',
      'capture-p39-platform-evidence.mjs',
      'capture-parity-certification-preflight.mjs',
      'capture-p34-credential-security-proof.mjs',
      'resolve-p39-platform-evidence.mjs',
      'capture-p39-differential.mjs',
      'run-p40-privacy-rpc-session.mjs',
      'Capture P-40 installed privacy proof',
      "if: inputs.requirement == 'P-02'",
      "if: inputs.requirement == 'P-34'",
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
      'Download P-39 macOS platform evidence',
      [
        '      - name: Capture P-38 release automation verification',
        "        if: inputs.requirement == 'P-38'",
        '        run: |',
        '          set -euo pipefail',
        '          node scripts/linux-port/capture-p38-release-automation.mjs',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
      ].join('\n'),
      'Capture parity certification preflight',
      'Preserve non-promotable P-02 diagnostic evidence',
      [
        '      - name: Install P-08 signed candidate package',
        "        if: inputs.requirement == 'P-08'",
        '        run: |',
        '          set -euo pipefail',
        '          sudo apt-get install -y --reinstall "$package"',
        '          sudo dnf install -y "$package"',
        '          sudo pacman -U --noconfirm "$package"',
        '          sha256sum /usr/share/openburnbar/attestation/installed-manifest.json',
        '          sha256sum /usr/share/openburnbar/attestation/installed-manifest.json.sig'
      ].join('\n'),
      [
        '      - name: Capture P-08 installed Mercury media proof',
        "        if: inputs.requirement == 'P-08'",
        '        run: |',
        '          set -euo pipefail',
        '          test -f "$desktop_report"',
        '          test -f "$device_report"',
        '          node scripts/linux-port/run-p08-mercury-media-session.mjs',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        '          node scripts/linux-port/capture-p08-mercury-media-proof.mjs',
        '            --session-report "$input_root/p08-installed-mercury-media-session.json"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
      ].join('\n'),
      [
        '      - name: Install P-09 through P-12 signed candidate package',
        "        if: inputs.requirement == 'P-09' || inputs.requirement == 'P-10' || inputs.requirement == 'P-11' || inputs.requirement == 'P-12'",
        '        run: |',
        '          set -euo pipefail',
        '          sudo apt-get install -y --reinstall "$package"',
        '          sudo dnf install -y "$package"',
        '          sudo pacman -U --noconfirm "$package"',
        '          sha256sum /usr/share/openburnbar/attestation/installed-manifest.json',
        '          sha256sum /usr/share/openburnbar/attestation/installed-manifest.json.sig'
      ].join('\n'),
      [
        '      - name: Capture P-09 installed navigation shell proof',
        "        if: inputs.requirement == 'P-09'",
        '        run: |',
        '          set -euo pipefail',
        '          node scripts/linux-port/run-p09-native-navigation-probes.mjs',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        '          node scripts/linux-port/materialize-p09-navigation-shell-session.mjs',
        '          node scripts/linux-port/capture-p09-navigation-shell-proof.mjs'
      ].join('\n'),
      [
        '      - name: Capture P-10 installed dashboard layout proof',
        "        if: inputs.requirement == 'P-10'",
        '        run: |',
        '          set -euo pipefail',
        '          node scripts/linux-port/run-p10-native-dashboard-probes.mjs',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        '          node scripts/linux-port/materialize-p10-dashboard-layout-session.mjs',
        '          node scripts/linux-port/capture-p10-dashboard-layout-proof.mjs'
      ].join('\n'),
      [
        '      - name: Capture P-11 installed usage ingestion proof',
        "        if: inputs.requirement == 'P-11'",
        '        run: |',
        '          set -euo pipefail',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p11-support.XXXXXX")"',
        '          chmod 700 "$evidence_root" "$support_root"',
        '          systemctl --user set-environment \\',
        '          systemctl --user restart openburnbar-daemon.service',
        '          test -S "$socket_path"',
        '          test -s "$token_file"',
        '          test ! -e "$support_root/usage-events.jsonl"',
        '          node scripts/linux-port/run-p11-usage-ingestion-session.mjs',
        '            --ledger-path "$support_root/usage-events.jsonl"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        '          node scripts/linux-port/materialize-p11-usage-ingestion-session.mjs',
        '          node scripts/linux-port/capture-p11-usage-ingestion-proof.mjs'
      ].join('\n'),
      [
        '      - name: Capture P-12 installed quota proof',
        "        if: inputs.requirement == 'P-12'",
        '        run: |',
        '          set -euo pipefail',
        '          gateway_token_file="$support_root/gateway-auth-token"',
        '          if systemctl --user is-active --quiet openburnbar-daemon.service; then service_was_active=1; else service_was_active=0; fi',
        '          systemctl --user show-environment >"$original_environment"',
        '          restore_manager_environment() {',
        '            systemctl --user unset-environment "${managed_variables[@]}"',
        '            if [[ "$service_was_active" == 1 ]]; then',
        '              systemctl --user stop openburnbar-daemon.service || status=1',
        '          test -x /usr/bin/openburnbar-linux-desktop',
        '          test -x /usr/bin/openburnbar-daemon',
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$gateway_token_file"',
        '          chmod 600 "$gateway_token_file"',
        '          gateway_token="$(<"$gateway_token_file")"',
        '          (( gateway_port >= 1024 && gateway_port <= 65535 ))',
        '          export OPENBURNBAR_DAEMON_SUPPORT_DIR="$support_root"',
        '          export OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path"',
        '          OPENBURNBAR_GATEWAY_ENABLED=1 \\',
        '          OPENBURNBAR_GATEWAY_HOST=127.0.0.1 \\',
        '          "OPENBURNBAR_GATEWAY_PORT=$gateway_port" \\',
        '          "OPENBURNBAR_GATEWAY_AUTH_TOKEN=$gateway_token"',
        '          systemctl --user restart openburnbar-daemon.service',
        '          node scripts/linux-port/run-p12-native-quota-probes.mjs',
        '            --support-dir "$support_root"',
        '            --gateway-token-file "$gateway_token_file"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        '          node scripts/linux-port/materialize-p12-quota-session.mjs',
        '          node scripts/linux-port/capture-p12-quota-proof.mjs'
      ].join('\n'),
      'Capture P-31 installed accessibility matrix evidence',
      'Capture P-34 credential security proof',
      [
        '      - name: Capture P-39 Linux candidate-bound platform evidence',
        "        if: inputs.requirement == 'P-39'",
        '        run: |',
        '          set -euo pipefail',
        '          node scripts/linux-port/capture-p39-platform-evidence.mjs',
        '            --platform linux',
        '            --candidate-closure "$input_root/.linux-release/product-proof-closure.json"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
      ].join('\n'),
      [
        '      - name: Resolve P-39 candidate-bound platform evidence inputs',
        "        if: inputs.requirement == 'P-39'",
        '        run: |',
        '          set -euo pipefail',
        '          node scripts/linux-port/resolve-p39-platform-evidence.mjs',
        '            --target-head "$TARGET_HEAD"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
      ].join('\n'),
      [
        '      - name: Capture P-39 same-commit macOS/Linux differential proof',
        "        if: inputs.requirement == 'P-39'",
        '        run: |',
        '          set -euo pipefail',
        '          node scripts/linux-port/capture-p39-differential.mjs',
        '            --input-root "$input_root"',
        '            --macos "$MACOS_INPUT"',
        '            --linux "$LINUX_INPUT"',
        '            --environment "$ENVIRONMENT_ID"',
        '            --target-head "$TARGET_HEAD"',
        '            --version "$VERSION"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        "            --ignore '$.payload.generatedAt'"
      ].join('\n'),
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
      'product-proof-closure.json.ed25519.sig',
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
      '    outputs:',
      '      macos_artifact_name: ${{ steps.select-macos-performance-artifact.outputs.artifact_name }}',
      '      - name: Upload macOS nightly matched workload soak',
      '        id: upload-macos-performance-primary',
      '        continue-on-error: true',
      '        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4',
      '          name: linux-parity-macos-performance-nightly',
      '          path: ${{ env.OB_EVIDENCE_OUT }}/matched-performance-macos.json',
      '          if-no-files-found: error',
      '      - name: Retry macOS nightly matched workload soak upload',
      '        id: upload-macos-performance-retry',
      "        if: steps.upload-macos-performance-primary.outcome != 'success'",
      '        continue-on-error: true',
      '        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4',
      '          name: linux-parity-macos-performance-nightly-retry-${{ github.run_id }}',
      '          path: ${{ env.OB_EVIDENCE_OUT }}/matched-performance-macos.json',
      '          if-no-files-found: error',
      '      - name: Select uploaded macOS nightly matched workload soak',
      '        id: select-macos-performance-artifact',
      '        if: always()',
      '        env:',
      '          PRIMARY_OUTCOME: ${{ steps.upload-macos-performance-primary.outcome }}',
      '          RETRY_OUTCOME: ${{ steps.upload-macos-performance-retry.outcome }}',
      '          PRIMARY_NAME: linux-parity-macos-performance-nightly',
      '          RETRY_NAME: linux-parity-macos-performance-nightly-retry-${{ github.run_id }}',
      '        run: |',
      '          set -euo pipefail',
      '          if [[ "$PRIMARY_OUTCOME" == "success" ]]',
      '          echo "artifact_name=$PRIMARY_NAME" >> "$GITHUB_OUTPUT"',
      '          exit 0',
      '          if [[ "$RETRY_OUTCOME" == "success" ]]',
      '          echo "artifact_name=$RETRY_NAME" >> "$GITHUB_OUTPUT"',
      '          exit 0',
      '          Neither macOS matched-performance artifact upload succeeded.',
      '          exit 1',
      'linux-matched-performance',
      '--profile nightly',
      'OB_MATCHED_MACOS_INPUT',
      'OB_MATCHED_LINUX_INPUT',
      'linux-parity-matched-performance-nightly',
      'name: ${{ needs.macos-matched-performance.outputs.macos_artifact_name }}',
      '-v "$OPENBURNBAR_LINUX_EVIDENCE_OUT:/evidence"',
      '--env OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests',
      '      - name: Upload Linux nightly evidence',
      '        if: always()',
      '        uses: actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874',
      '        with:',
      '          name: linux-nightly-${{ matrix.label }}',
      '          path: ${{ env.OPENBURNBAR_LINUX_EVIDENCE_OUT }}/',
      '          include-hidden-files: true',
      '          if-no-files-found: warn',
      'OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests'
    ].join('\n'),
    release: [
      '- "linux-v*"',
      'COSIGN_MAX_ATTACHMENT_SIZE: 1GiB',
      'OPENBURNBAR_LINUX_COSIGN_IDENTITY: https://github.com/${{ github.workflow_ref }}',
      'resolve-linux-release-version.mjs --github-output',
      'validate-linux-release-public-config.mjs',
      'vars.OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID',
      'vars.OPENBURNBAR_FIREBASE_API_KEY',
      'vars.OPENBURNBAR_LINUX_APP_CHECK_APP_ID',
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
      '--candidate',
      'finalize-product-proof-closure.mjs',
      'sign-product-proof-closure.mjs',
      'product-proof-closure.json.ed25519.sig',
      'include-hidden-files: true',
      'merge-multiple: false',
      'npm ci --prefix scripts/linux-port --ignore-scripts',
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
      'Sign installed-product proof closure',
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

test('P-38 workflow step cannot be removed or weakened', () => {
  for (const marker of [
    'capture-p38-release-automation.mjs',
    "if: inputs.requirement == 'P-38'",
    'Capture P-38 release automation verification'
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replace(marker, 'removed-p38-capture-marker');
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(result.failures.some((failure) => /product parity evidence workflow/u.test(failure)), marker);
  }
  for (const [name, from, to] of [
    ['commented producer', '          node scripts/linux-port/capture-p38-release-automation.mjs', '          # node scripts/linux-port/capture-p38-release-automation.mjs'],
    ['swallowed producer failure', '          set -euo pipefail', '          set -euo pipefail\n          continue-on-error: true'],
    ['disabled fail-fast shell', '          set -euo pipefail', '          set +e']
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replace(from, to);
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, name);
    assert.ok(result.failures.some((failure) => /P-38 release automation verification/u.test(failure)), name);
  }
});

test('P-08 installed media workflow cannot omit package trust or paired live evidence', () => {
  for (const marker of [
    'Install P-08 signed candidate package',
    'Capture P-08 installed Mercury media proof',
    'run-p08-mercury-media-session.mjs',
    'capture-p08-mercury-media-proof.mjs',
    '--manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
    'test -f "$desktop_report"',
    'test -f "$device_report"'
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(marker, 'removed-p08-marker');
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(result.failures.some((failure) => /P-08/u.test(failure)), marker);
  }
  for (const [stepName, mutation] of [
    ['Install P-08 signed candidate package', ['set -euo pipefail', 'set +e']],
    ['Capture P-08 installed Mercury media proof', ['set -euo pipefail', 'set +e']],
    ['Capture P-08 installed Mercury media proof', ['test -f "$device_report"', 'true']]
  ]) {
    const input = valid();
    const stepStart = input.productParityWorkflow.indexOf(`      - name: ${stepName}`);
    assert.ok(stepStart >= 0, stepName);
    const nextStep = input.productParityWorkflow.indexOf('\n      - name:', stepStart + 1);
    const end = nextStep < 0 ? input.productParityWorkflow.length : nextStep;
    const block = input.productParityWorkflow.slice(stepStart, end).replace(...mutation);
    input.productParityWorkflow = `${input.productParityWorkflow.slice(0, stepStart)}${block}${input.productParityWorkflow.slice(end)}`;
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, `${stepName}: ${mutation[0]}`);
    assert.ok(result.failures.some((failure) => /P-08/u.test(failure)));
  }
});

test('P-09 through P-12 installed workflows require native runners before materialization and fail closed', () => {
  for (const [requirementId, stepName, runner, materializer, capture] of [
    [
      'P-09', 'Capture P-09 installed navigation shell proof',
      'scripts/linux-port/run-p09-native-navigation-probes.mjs',
      'scripts/linux-port/materialize-p09-navigation-shell-session.mjs',
      'scripts/linux-port/capture-p09-navigation-shell-proof.mjs'
    ],
    [
      'P-10', 'Capture P-10 installed dashboard layout proof',
      'scripts/linux-port/run-p10-native-dashboard-probes.mjs',
      'scripts/linux-port/materialize-p10-dashboard-layout-session.mjs',
      'scripts/linux-port/capture-p10-dashboard-layout-proof.mjs'
    ],
    [
      'P-11', 'Capture P-11 installed usage ingestion proof',
      'scripts/linux-port/run-p11-usage-ingestion-session.mjs',
      'scripts/linux-port/materialize-p11-usage-ingestion-session.mjs',
      'scripts/linux-port/capture-p11-usage-ingestion-proof.mjs'
    ],
    [
      'P-12', 'Capture P-12 installed quota proof',
      'scripts/linux-port/run-p12-native-quota-probes.mjs',
      'scripts/linux-port/materialize-p12-quota-session.mjs',
      'scripts/linux-port/capture-p12-quota-proof.mjs'
    ]
  ]) {
    for (const marker of [
      'Install P-09 through P-12 signed candidate package', stepName, runner, materializer, capture,
      '--manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ]) {
      const input = valid();
      input.productParityWorkflow = input.productParityWorkflow.replaceAll(marker, `removed-${requirementId}-marker`);
      const result = verifyLinuxWorkflowWiring(input);
      assert.equal(result.passed, false, `${requirementId}: ${marker}`);
      assert.ok(result.failures.some((failure) => failure.includes(requirementId)), `${requirementId}: ${marker}`);
    }

    const runnerFailure = valid();
    runnerFailure.productParityWorkflow = runnerFailure.productParityWorkflow.replace(
      `node ${runner}`,
      `node ${runner} || true`
    );
    let result = verifyLinuxWorkflowWiring(runnerFailure);
    assert.equal(result.passed, false, `${requirementId} runner failure swallowing`);
    assert.ok(result.failures.some((failure) => failure.includes(requirementId)));

    const reordered = valid();
    reordered.productParityWorkflow = reordered.productParityWorkflow
      .replace(`node ${runner}`, 'node __TEMP_NATIVE_RUNNER__')
      .replace(`node ${materializer}`, `node ${runner}`)
      .replace('node __TEMP_NATIVE_RUNNER__', `node ${materializer}`);
    result = verifyLinuxWorkflowWiring(reordered);
    assert.equal(result.passed, false, `${requirementId} runner/materializer order`);
    assert.ok(result.failures.some((failure) => failure.includes(requirementId)));
  }
});

test('P-12 installed quota workflow preserves isolated gateway and daemon state fail closed', () => {
  for (const marker of [
    'systemctl --user show-environment >"$original_environment"',
    'systemctl --user unset-environment "${managed_variables[@]}"',
    'if [[ "$service_was_active" == 1 ]]; then',
    'openssl rand -hex 32 >"$gateway_token_file"',
    'gateway_token="$(<"$gateway_token_file")"',
    '(( gateway_port >= 1024 && gateway_port <= 65535 ))',
    'export OPENBURNBAR_DAEMON_SUPPORT_DIR="$support_root"',
    'export OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path"',
    'OPENBURNBAR_GATEWAY_ENABLED=1 \\',
    'OPENBURNBAR_GATEWAY_HOST=127.0.0.1 \\',
    '"OPENBURNBAR_GATEWAY_PORT=$gateway_port" \\',
    '"OPENBURNBAR_GATEWAY_AUTH_TOKEN=$gateway_token"',
    '--gateway-token-file "$gateway_token_file"'
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(marker, 'removed-p12-state-marker');
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(result.failures.some((failure) => failure.includes('P-12')), marker);
  }
});

test('P-39 differential workflow cannot be removed or weakened', () => {
  for (const marker of [
    'resolve-p39-platform-evidence.mjs',
    'capture-p39-differential.mjs',
    'Resolve P-39 candidate-bound platform evidence inputs',
    'Capture P-39 same-commit macOS/Linux differential proof',
    "--ignore '$.payload.generatedAt'"
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(marker, 'removed-p39-capture-marker');
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(result.failures.some((failure) => /P-39/u.test(failure)), marker);
  }
  for (const [name, from, to] of [
    ['commented resolver', '          node scripts/linux-port/resolve-p39-platform-evidence.mjs', '          # node scripts/linux-port/resolve-p39-platform-evidence.mjs'],
    ['swallowed capture failure', '          set -euo pipefail', '          set -euo pipefail\n          continue-on-error: true'],
    ['disabled capture fail-fast shell', '          set -euo pipefail', '          set +e']
  ]) {
    const input = valid();
    const stepName = name.includes('resolver')
      ? '      - name: Resolve P-39 candidate-bound platform evidence inputs'
      : '      - name: Capture P-39 same-commit macOS/Linux differential proof';
    const stepStart = input.productParityWorkflow.indexOf(stepName);
    assert.ok(stepStart >= 0);
    const before = input.productParityWorkflow.slice(0, stepStart);
    const step = input.productParityWorkflow.slice(stepStart);
    input.productParityWorkflow = `${before}${step.replace(from, to)}`;
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, name);
    assert.ok(result.failures.some((failure) => /P-39/u.test(failure)), name);
  }
});

test('hidden Linux output uploads fail closed when upload protections mutate', () => {
  for (const [surface, step, mutation] of [
    ['release', 'Upload architecture shard', 'include-hidden-files: false'],
    ['release', 'Upload Linux release evidence', 'if-no-files-found: warn'],
    ['promotionWorkflow', 'Upload promotion closure', 'actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874'],
    ['nightly', 'Upload Linux nightly evidence', 'include-hidden-files: false']
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

test('Linux Swift evidence must remain host-mounted and routed in both workflows', () => {
  for (const field of ['pr', 'nightly']) {
    const input = valid();
    input[field] = input[field].replace('-v "$OPENBURNBAR_LINUX_EVIDENCE_OUT:/evidence"', '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, `${field}:evidence mount`);

    const routed = valid();
    routed[field] = routed[field].replace(
      '--env OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests',
      ''
    );
    assert.equal(verifyLinuxWorkflowWiring(routed).passed, false, `${field}:evidence route`);
  }
});

test('product evidence dependency install and mutation suites are mandatory in the PR gate', () => {
  for (const marker of [
    'npm ci --prefix scripts/linux-port --ignore-scripts',
    'attest-product-requirement.test.mjs',
    'github-artifact-provenance.test.mjs',
    'smoke-linux-packages.test.mjs',
    'product-feature-proof-closure.test.mjs',
    'p07-computer-use-proof.test.mjs',
    'p08-mercury-media-proof.test.mjs',
    'p09-navigation-shell-proof.test.mjs',
    'p10-dashboard-layout-proof.test.mjs',
    'p11-usage-ingestion-proof.test.mjs',
    'p12-quota-proof.test.mjs',
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
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(marker, 'removed');
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
    'arch_signature_pattern',
    '--previous-installed-manifest "/workspace/',
    'source=$PWD,target=/workspace,readonly',
    'source=$PWD/.linux-shard/session,target=/workspace/.linux-shard/session',
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

test('nightly macOS evidence upload retries once and fails closed without an artifact', () => {
  for (const marker of [
    'id: upload-macos-performance-primary',
    'continue-on-error: true',
    "if: steps.upload-macos-performance-primary.outcome != 'success'",
    'name: linux-parity-macos-performance-nightly-retry-${{ github.run_id }}',
    'id: select-macos-performance-artifact',
    'if: always()',
    'if [[ "$RETRY_OUTCOME" == "success" ]]',
    'echo "artifact_name=$RETRY_NAME" >> "$GITHUB_OUTPUT"',
    'Neither macOS matched-performance artifact upload succeeded.',
    'name: ${{ needs.macos-matched-performance.outputs.macos_artifact_name }}'
  ]) {
    const input = valid();
    input.nightly = input.nightly.replace(marker, '');
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test('Linux Swift evidence must route through the host-mounted evidence tree', () => {
  const marker = 'OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests';
  for (const field of ['pr', 'nightly']) {
    const input = valid();
    input[field] = input[field].replace(marker, '');
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, field);
    assert.ok(result.failures.some((failure) => failure.includes('Linux Swift evidence routing')), field);
  }
});

test('removing the TypeScript typecheck gate from the PR workflow fails', () => {
  const input = valid();
  input.pr = input.pr.replace('npm run typecheck --prefix apps/linux-desktop', '');
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((f) => f.includes('TypeScript typecheck gate')));
});

test('TypeScript typecheck gate may not continue on error', () => {
  const input = valid();
  input.pr = input.pr.replace(
    'npm run typecheck --prefix apps/linux-desktop',
    '- name: Linux desktop TypeScript typecheck\n        run: npm run typecheck --prefix apps/linux-desktop\n        continue-on-error: true'
  );
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((f) => f.includes('typecheck gate may not continue on error')));
});
