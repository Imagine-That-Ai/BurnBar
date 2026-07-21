import assert from "node:assert/strict";
import test from "node:test";
import { verifyLinuxWorkflowWiring } from "./verify-linux-workflow-wiring.mjs";

function valid() {
  return {
    pr: [
      "bash scripts/linux-port/run-linux-native-tests.sh",
      "verify-linux-release.test.mjs",
      "assemble-linux-release.test.mjs",
      "linux-aggregate-installed-attestation.test.mjs",
      "linux-package-session.test.mjs",
      "arch-lifecycle-authentication.test.mjs",
      "linux-installed-manifest.test.mjs",
      "linux-appimage-peer-manifest.test.mjs",
      "linux-native-package-real-tools.test.mjs",
      "validate-linux-release-public-config.test.mjs",
      "sign-linux-release-requests.test.mjs",
      "sign-product-proof-closure.test.mjs",
      "signed-installed-package-wiring.test.mjs",
      "scripts/linux-port/browser-runtime-packaging.test.mjs",
      "scripts/linux-port/aur-browser-runtime-packaging.test.mjs",
      "scripts/linux-port/arch-package-lifecycle.test.mjs",
      "scripts/linux-port/embed-linux-appimage-payload.test.mjs",
      "render-parity-ledger.mjs --check",
      "npm ci --prefix scripts/linux-port --ignore-scripts",
      "attest-product-requirement.test.mjs",
      "github-artifact-provenance.test.mjs",
      "live-installed-product-evidence.test.mjs",
      "smoke-linux-packages.test.mjs",
      "product-proof-closure.test.mjs",
      "product-feature-proof-closure.test.mjs",
      "p07-computer-use-proof.test.mjs",
      "p08-mercury-media-proof.test.mjs",
      "p09-navigation-shell-proof.test.mjs",
      "p10-dashboard-layout-proof.test.mjs",
      "p11-usage-ingestion-proof.test.mjs",
      "p12-quota-proof.test.mjs",
      "p13-native-onboarding-probes.test.mjs",
      "p13-onboarding-proof.test.mjs",
      "p17-native-activity-probes.test.mjs",
      "p17-activity-proof.test.mjs",
      "p18-native-memory-probes.test.mjs",
      "p18-memory-review-proof.test.mjs",
      "p19-native-projects-probes.test.mjs",
      "p19-projects-proof.test.mjs",
      "p20-native-missions-probes.test.mjs",
      "p20-missions-proof.test.mjs",
      "p21-native-insights-probes.test.mjs",
      "p21-insights-proof.test.mjs",
      "p22-native-database-probes.test.mjs",
      "p22-database-proof.test.mjs",
      "p24-installed-settings-workflow.test.mjs",
      "p24-native-settings-probes.test.mjs",
      "p24-settings-proof.test.mjs",
      "p26-native-tray-probes.test.mjs",
      "p26-tray-proof.test.mjs",
      "p27-native-notification-probes.test.mjs",
      "p27-notifications-proof.test.mjs",
      "p28-native-smarthub-probes.test.mjs",
      "p28-smarthub-proof.test.mjs",
      "p29-native-text-expansion-probes.test.mjs",
      "p29-text-expansion-proof.test.mjs",
      "p30-native-pet-probes.test.mjs",
      "p30-pet-proof.test.mjs",
      "p15-account-billing-proof.test.mjs",
      "p16-cloud-devices-proof.test.mjs",
      "p16-physical-ipad-coordination.test.mjs",
      "p32-performance-proof.test.mjs",
      "p33-reliability-proof.test.mjs",
      "p35-diagnostics-support-proof.test.mjs",
      "p36-visual-polish-proof.test.mjs",
      "install-tauri-webdriver-prerequisites.test.mjs",
      "p25-installed-update-lifecycle.test.mjs",
      "p25-native-update-probes.test.mjs",
      "p25-updates-proof.test.mjs",
      "p38-release-automation-proof.test.mjs",
      "p31-accessibility-proof.test.mjs",
      "p34-credential-security-proof.test.mjs",
      "parity-certification-preflight.test.mjs",
      "run-linux-matrix-harness.test.mjs",
      "run-product-requirement-validator.test.mjs",
      "resolve-product-evidence-run.test.mjs",
      "resolve-product-receipt-artifacts.test.mjs",
      "linux-toolchain-node-runtime.test.mjs",
      "macos-matched-performance",
      "run-matched-performance.mjs",
      "--profile pr",
      "matched-performance-contract.test.mjs",
      "perf-budget-contract.test.mjs",
      "text-expansion-native-evidence.test.mjs",
      "linux-parity-macos-performance-pr",
      '-v "$OPENBURNBAR_LINUX_EVIDENCE_OUT:/evidence"',
      "--env OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests",
      "      - name: Upload Linux gate evidence",
      "        if: always()",
      "        uses: actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874",
      "        with:",
      "          name: linux-pr-gate-evidence",
      "          path: ${{ env.OPENBURNBAR_LINUX_EVIDENCE_OUT }}/",
      "          include-hidden-files: true",
      "          if-no-files-found: warn",
      "npm run typecheck --prefix apps/linux-desktop",
    ].join("\n"),
    productParityWorkflow: [
      "id-token: write",
      "attestations: write",
      "artifact-metadata: write",
      "ref: ${{ github.sha }}",
      "resolve-product-evidence-run.mjs",
      "CANDIDATE_RUN_ID: ${{ inputs.candidate_run_id }}",
      "TARGET_HEAD: ${{ github.sha }}",
      '--run-id "$CANDIDATE_RUN_ID"',
      '--target-head "$TARGET_HEAD"',
      "artifact-ids: ${{ steps.evidence.outputs.artifact_id }}",
      "CANDIDATE_RUN_ID: ${{ steps.evidence.outputs.run_id }}",
      "CANDIDATE_ARTIFACT_DIGEST: ${{ steps.evidence.outputs.artifact_digest }}",
      [
        "  p16-ipad-producer:",
        "    name: P-16 physical iPad trust-cycle producer",
        "    if: inputs.requirement == 'P-16'",
        "    runs-on:",
        "      - self-hosted",
        "      - macos",
        "      - arm64",
        "    steps:",
        "      - name: Check out the exact evidence source",
        "        with:",
        "          ref: ${{ github.sha }}",
        "      - name: Inject physical-iPad Firebase configuration",
        "        env:",
        "          FIREBASE_PLIST_BASE64: ${{ secrets.FIREBASE_PLIST_BASE64 }}",
        "        run: bash scripts/ci/inject-firebase-config.sh",
        "      - name: Resolve the trusted immutable release evidence artifact",
        "        run: node scripts/linux-port/resolve-product-evidence-run.mjs",
        "      - name: Capture P-16 physical iPad trust cycle",
        "        env:",
        "          P16_COORDINATION_ROOT: ${{ vars.OPENBURNBAR_P16_MACOS_COORDINATION_ROOT }}",
        "        run: |",
        "          set -euo pipefail",
        '          test -n "$P16_COORDINATION_ROOT"',
        '          [[ "$P16_COORDINATION_ROOT" == /* ]]',
        '          test ! -L "$P16_COORDINATION_ROOT"',
        '          test "$(stat -f \'%Su\' "$P16_COORDINATION_ROOT")" = "$(id -un)"',
        '          test "$(stat -f \'%Lp\' "$P16_COORDINATION_ROOT")" = 700',
        '          coordination_dir="$P16_COORDINATION_ROOT/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${ENVIRONMENT_ID}"',
        '          scratch_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p16-ipad.XXXXXX")"',
        '          rm -rf "$scratch_root" || status=1',
        "          bash scripts/linux-port/capture-p16-physical-ipad-trust-cycle.sh",
        '            --coordination-dir "$coordination_dir"',
        '            --scratch-root "$scratch_root"',
        '            --target-head "$TARGET_HEAD"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
      ].join("\n"),
      "  p32-macos-producer:",
      "P-32 macOS nightly performance producer",
      "Capture P-32 candidate-bound macOS nightly performance",
      "--macos-only",
      "--profile nightly",
      "linux-p32-macos-nightly-performance",
      "p39-macos-producer",
      "P-39 macOS parser corpus producer",
      "--platform macos",
      "linux-p39-macos-platform-evidence",
      "capture-p39-platform-evidence.mjs",
      "capture-parity-certification-preflight.mjs",
      "capture-p34-credential-security-proof.mjs",
      "resolve-p39-platform-evidence.mjs",
      "capture-p39-differential.mjs",
      "run-p40-privacy-rpc-session.mjs",
      "Capture P-40 installed privacy proof",
      "if: inputs.requirement == 'P-02'",
      "if: inputs.requirement == 'P-34'",
      "if: always() && inputs.requirement == 'P-02'",
      "linux-product-parity-diagnostic-",
      "id: p02_capture",
      'mktemp -d "${RUNNER_TEMP}/openburnbar-p02.XXXXXX"',
      'printf \'diagnostic_root=%s\\n\' "$diagnostic_root" >> "$GITHUB_OUTPUT"',
      '--diagnostic-root "$diagnostic_root"',
      "${{ steps.p02_capture.outputs.diagnostic_root }}/",
      "capture-failure.json",
      "capture.log",
      '2>&1 | tee "$capture_log"',
      "capture-p31-accessibility.mjs",
      "if: inputs.requirement == 'P-31'",
      "id: p31_capture",
      '--session-report "$session_report"',
      "p31-live-session.json",
      "P-34 credential security proof",
      "finalize-product-feature-proof-closure.mjs",
      "prepare-product-requirement-input.mjs",
      "run-product-requirement-validator.mjs",
      '--candidate-run-id "$CANDIDATE_RUN_ID"',
      '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
      "uses: actions/attest@",
      ".sigstore.jsonl",
      "if-no-files-found: error",
      "include-hidden-files: true",
      "Download exact-candidate installed evidence",
      "Download P-39 macOS platform evidence",
      "Download P-32 macOS nightly performance",
      [
        "      - name: Capture P-38 release automation verification",
        "        if: inputs.requirement == 'P-38'",
        "        run: |",
        "          set -euo pipefail",
        "          node scripts/linux-port/capture-p38-release-automation.mjs",
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
      ].join("\n"),
      "Capture parity certification preflight",
      "Preserve non-promotable P-02 diagnostic evidence",
      [
        "      - name: Install P-06 signed candidate package",
        "        if: inputs.requirement == 'P-06'",
        "        run: |",
        "          set -euo pipefail",
        '          test "$(awk -F \' = \' \'$1 == "pkgname" { print $2 }\' <<<"$package_info")" = openburnbar',
        '          version="${version%-*}"',
        '          sudo pacman -U --noconfirm "$package"',
      ].join("\n"),
      [
        "      - name: Install P-08 signed candidate package",
        "        if: inputs.requirement == 'P-08'",
        "        run: |",
        "          set -euo pipefail",
        '          sudo apt-get install -y --reinstall "$package"',
        '          sudo dnf install -y "$package"',
        '          sudo pacman -U --noconfirm "$package"',
        "          sha256sum /usr/share/openburnbar/attestation/installed-manifest.json",
        "          sha256sum /usr/share/openburnbar/attestation/installed-manifest.json.sig",
      ].join("\n"),
      [
        "      - name: Capture P-08 installed Mercury media proof",
        "        if: inputs.requirement == 'P-08'",
        "        run: |",
        "          set -euo pipefail",
        '          test -f "$desktop_report"',
        '          test -f "$device_report"',
        "          node scripts/linux-port/run-p08-mercury-media-session.mjs",
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/capture-p08-mercury-media-proof.mjs",
        '            --session-report "$input_root/p08-installed-mercury-media-session.json"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
      ].join("\n"),
      [
        "      - name: Install signed candidate for installed feature proofs",
        "        if: inputs.requirement == 'P-09' || inputs.requirement == 'P-10' || inputs.requirement == 'P-11' || inputs.requirement == 'P-12' || inputs.requirement == 'P-13' || inputs.requirement == 'P-14' || inputs.requirement == 'P-15' || inputs.requirement == 'P-16' || inputs.requirement == 'P-17' || inputs.requirement == 'P-18' || inputs.requirement == 'P-19' || inputs.requirement == 'P-20' || inputs.requirement == 'P-21' || inputs.requirement == 'P-22' || inputs.requirement == 'P-23' || inputs.requirement == 'P-24' || inputs.requirement == 'P-25' || inputs.requirement == 'P-26' || inputs.requirement == 'P-27' || inputs.requirement == 'P-28' || inputs.requirement == 'P-29' || inputs.requirement == 'P-30' || inputs.requirement == 'P-32' || inputs.requirement == 'P-33' || inputs.requirement == 'P-35' || inputs.requirement == 'P-36'",
        "        run: |",
        "          set -euo pipefail",
        '          sudo apt-get install -y --reinstall "$package"',
        '          sudo dnf install -y "$package"',
        '          sudo pacman -U --noconfirm "$package"',
        '          test "$(awk -F \' = \' \'$1 == "pkgname" { print $2 }\' <<<"$package_info")" = openburnbar',
        "          sha256sum /usr/share/openburnbar/attestation/installed-manifest.json",
        "          sha256sum /usr/share/openburnbar/attestation/installed-manifest.json.sig",
      ].join("\n"),
      [
        "      - name: Provision native Tauri WebDriver prerequisites",
        "        if: inputs.requirement == 'P-15' || inputs.requirement == 'P-16' || inputs.requirement == 'P-27' || inputs.requirement == 'P-36'",
        "        run: |",
        "          set -euo pipefail",
        "          bash scripts/linux-port/install-tauri-webdriver-prerequisites.sh",
      ].join("\n"),
      [
        "      - name: Capture P-09 installed navigation shell proof",
        "        if: inputs.requirement == 'P-09'",
        "        run: |",
        "          set -euo pipefail",
        "          node scripts/linux-port/run-p09-native-navigation-probes.mjs",
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p09-navigation-shell-session.mjs",
        "          node scripts/linux-port/capture-p09-navigation-shell-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-10 installed dashboard layout proof",
        "        if: inputs.requirement == 'P-10'",
        "        run: |",
        "          set -euo pipefail",
        "          node scripts/linux-port/run-p10-native-dashboard-probes.mjs",
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p10-dashboard-layout-session.mjs",
        "          node scripts/linux-port/capture-p10-dashboard-layout-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-11 installed usage ingestion proof",
        "        if: inputs.requirement == 'P-11'",
        "        run: |",
        "          set -euo pipefail",
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p11-support.XXXXXX")"',
        '          chmod 700 "$evidence_root" "$support_root"',
        "          systemctl --user set-environment \\",
        "          systemctl --user restart openburnbar-daemon.service",
        '          test -S "$socket_path"',
        '          test -s "$token_file"',
        '          test ! -e "$support_root/usage-events.jsonl"',
        "          node scripts/linux-port/run-p11-usage-ingestion-session.mjs",
        '            --ledger-path "$support_root/usage-events.jsonl"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p11-usage-ingestion-session.mjs",
        "          node scripts/linux-port/capture-p11-usage-ingestion-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-12 installed quota proof",
        "        if: inputs.requirement == 'P-12'",
        "        run: |",
        "          set -euo pipefail",
        '          gateway_token_file="$support_root/gateway-auth-token"',
        "          if systemctl --user is-active --quiet openburnbar-daemon.service; then service_was_active=1; else service_was_active=0; fi",
        '          systemctl --user show-environment >"$original_environment"',
        "          restore_manager_environment() {",
        '            systemctl --user unset-environment "${managed_variables[@]}"',
        '            if [[ "$service_was_active" == 1 ]]; then',
        "              systemctl --user stop openburnbar-daemon.service || status=1",
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/bin/openburnbar-daemon",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$gateway_token_file"',
        '          chmod 600 "$gateway_token_file"',
        '          gateway_token="$(<"$gateway_token_file")"',
        "          (( gateway_port >= 1024 && gateway_port <= 65535 ))",
        '          export OPENBURNBAR_DAEMON_SUPPORT_DIR="$support_root"',
        '          export OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path"',
        "          OPENBURNBAR_GATEWAY_ENABLED=1 \\",
        "          OPENBURNBAR_GATEWAY_HOST=127.0.0.1 \\",
        '          "OPENBURNBAR_GATEWAY_PORT=$gateway_port" \\',
        '          "OPENBURNBAR_GATEWAY_AUTH_TOKEN=$gateway_token"',
        "          systemctl --user restart openburnbar-daemon.service",
        "          node scripts/linux-port/run-p12-native-quota-probes.mjs",
        '            --support-dir "$support_root"',
        '            --gateway-token-file "$gateway_token_file"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p12-quota-session.mjs",
        "          node scripts/linux-port/capture-p12-quota-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-13 installed onboarding proof",
        "        if: inputs.requirement == 'P-13'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p13-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p13-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p13-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
        '          chmod 700 "$evidence_root" "$support_root" "$home_root"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/libexec/openburnbar-daemon-launch",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p13-native-onboarding-probes.mjs",
        '            --home-dir "$home_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p13-onboarding-session.mjs",
        "          node scripts/linux-port/capture-p13-onboarding-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-14 installed chat proof",
        "        if: inputs.requirement == 'P-14'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-home.XXXXXX")"',
        '          download_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-downloads.XXXXXX")"',
        '          systemctl --user show-environment >"$original_environment"',
        "          restore_manager_environment() {",
        '            systemctl --user unset-environment "${managed_variables[@]}"',
        "          }",
        '          if [[ "$service_was_active" == 1 ]]; then',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" "$download_root" || status=1',
        '          printf \'XDG_DOWNLOAD_DIR="%s"\\n\' "$download_root" >"$home_root/.config/user-dirs.dirs"',
        '          export HOME="$home_root"',
        '          export XDG_CONFIG_HOME="$home_root/.config"',
        '          test -S "$socket_path"',
        '          test -s "$token_file"',
        '          test -s "$database_path"',
        "          node scripts/linux-port/run-p14-chat-session.mjs",
        '            --database-path "$database_path"',
        '            --attachment "$attachment_path"',
        '            --download-dir "$download_root"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p14-chat-session.mjs",
        '            --thread-id "$thread_id"',
        "          node scripts/linux-port/capture-p14-chat-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-15 installed account and billing proof",
        "        if: inputs.requirement == 'P-15'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p15-evidence.XXXXXX")"',
        '          state_home="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p15-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$state_home" || status=1',
        '          chmod 700 "$evidence_root" "$state_home"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/bin/openburnbar-daemon",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        "          node scripts/linux-port/run-p15-native-account-billing-probes.mjs",
        '            --state-home "$state_home"',
        '            --architecture "$architecture"',
        '            --package-format "$package_format"',
        '            --desktop "$desktop"',
        '            --display-server "$display_server"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p15-account-billing-session.mjs",
        '            --compositor "$compositor"',
        "          node scripts/linux-port/capture-p15-account-billing-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-16 installed cloud and devices proof",
        "        if: inputs.requirement == 'P-16'",
        "        env:",
        "          P16_COORDINATION_ROOT: ${{ vars.OPENBURNBAR_P16_LINUX_COORDINATION_ROOT }}",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p16-evidence.XXXXXX")"',
        '          state_home="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p16-home.XXXXXX")"',
        '          test -n "$P16_COORDINATION_ROOT"',
        '          [[ "$P16_COORDINATION_ROOT" == /* ]]',
        '          test ! -L "$P16_COORDINATION_ROOT"',
        '          test "$(stat -c \'%U\' "$P16_COORDINATION_ROOT")" = "$(id -un)"',
        '          test "$(stat -c \'%a\' "$P16_COORDINATION_ROOT")" = 700',
        '          coordination_dir="$P16_COORDINATION_ROOT/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${ENVIRONMENT_ID}"',
        '          mobile_receipt="$coordination_dir/p16-mobile-receipt.json"',
        '          rm -rf "$evidence_root" "$state_home" "$coordination_dir" || status=1',
        '          chmod 700 "$evidence_root" "$state_home" "$coordination_dir"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/bin/openburnbar-daemon",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p16-native-cloud-devices-probes.mjs",
        '            --state-home "$state_home"',
        '            --mobile-receipt "$mobile_receipt"',
        '            --coordination-dir "$coordination_dir"',
        '            --architecture "$architecture"',
        '            --package-format "$package_format"',
        '            --desktop "$desktop"',
        '            --display-server "$display_server"',
        '            --support-dir "$support_root"',
        '            --home-dir "$home_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p16-cloud-devices-session.mjs",
        '            --compositor "$compositor"',
        "          node scripts/linux-port/capture-p16-cloud-devices-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-17 installed Activity proof",
        "        if: inputs.requirement == 'P-17'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-home.XXXXXX")"',
        '          download_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-downloads.XXXXXX")"',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" "$download_root" || status=1',
        '          chmod 700 "$evidence_root" "$support_root" "$home_root" "$download_root"',
        "          test -x /usr/bin/openburnbar-cli",
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/libexec/openburnbar-daemon-launch",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p17-native-activity-probes.mjs",
        '            --home-dir "$home_root"',
        '            --download-dir "$download_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p17-activity-session.mjs",
        "          node scripts/linux-port/capture-p17-activity-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-18 installed memory-review proof",
        "        if: inputs.requirement == 'P-18'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
        '          chmod 700 "$evidence_root" "$support_root" "$home_root"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/libexec/openburnbar-daemon-launch",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p18-native-memory-probes.mjs",
        '            --home-dir "$home_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p18-memory-review-session.mjs",
        "          node scripts/linux-port/capture-p18-memory-review-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-19 installed Projects proof",
        "        if: inputs.requirement == 'P-19'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
        '          chmod 700 "$evidence_root" "$support_root" "$home_root"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/libexec/openburnbar-daemon-launch",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p19-native-projects-probes.mjs",
        '            --home-dir "$home_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p19-projects-session.mjs",
        "          node scripts/linux-port/capture-p19-projects-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-20 installed Missions proof",
        "        if: inputs.requirement == 'P-20'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
        '          chmod 700 "$evidence_root" "$support_root" "$home_root"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/libexec/openburnbar-daemon-launch",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p20-native-missions-probes.mjs",
        '            --home-dir "$home_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p20-missions-session.mjs",
        "          node scripts/linux-port/capture-p20-missions-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-21 installed Insights proof",
        "        if: inputs.requirement == 'P-21'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
        '          chmod 700 "$evidence_root" "$support_root" "$home_root"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/libexec/openburnbar-daemon-launch",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p21-native-insights-probes.mjs",
        '            --home-dir "$home_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p21-insights-session.mjs",
        "          node scripts/linux-port/capture-p21-insights-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-22 installed Database proof",
        "        if: inputs.requirement == 'P-22'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
        '          chmod 700 "$evidence_root" "$support_root" "$home_root"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/libexec/openburnbar-daemon-launch",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p22-native-database-probes.mjs",
        '            --home-dir "$home_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p22-database-session.mjs",
        "          node scripts/linux-port/capture-p22-database-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-23 installed Provider workspace proof",
        "        if: inputs.requirement == 'P-23'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p23-evidence.XXXXXX")"',
        '          socket_path="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}/openburnbar/daemon.sock"',
        '          token_file="${XDG_DATA_HOME:-$HOME/.local/share}/openburnbar/daemon-socket-auth-token"',
        '          rm -rf "$evidence_root" || status=1',
        '          chmod 700 "$evidence_root"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/bin/openburnbar-daemon",
        '          test -S "$socket_path"',
        '          test -s "$token_file"',
        "          systemctl --user is-active --quiet openburnbar-daemon.service",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        "          umask 077",
        "          node scripts/linux-port/run-p23-native-provider-workspace-probes.mjs",
        '            --raw-output-dir "$evidence_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p23-provider-workspace-session.mjs",
        "          node scripts/linux-port/capture-p23-provider-workspace-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-24 installed Settings proof",
        "        if: inputs.requirement == 'P-24'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
        '          chmod 700 "$evidence_root" "$support_root" "$home_root"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/libexec/openburnbar-daemon-launch",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p24-installed-settings-workflow.mjs",
        '            --home-dir "$home_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p24-settings-session.mjs",
        "          node scripts/linux-port/capture-p24-settings-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-26 installed tray proof",
        "        if: inputs.requirement == 'P-26'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
        '          chmod 700 "$evidence_root" "$support_root" "$home_root"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/libexec/openburnbar-daemon-launch",
        "          test -f /etc/xdg/autostart/openburnbar.desktop",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p26-native-tray-probes.mjs",
        '            --support-dir "$support_root"',
        '            --home-dir "$home_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p26-tray-session.mjs",
        "          node scripts/linux-port/capture-p26-tray-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-30 installed pet proof",
        "        if: inputs.requirement == 'P-30'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p30-evidence.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p30-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$home_root" || status=1',
        '          chmod 700 "$evidence_root" "$home_root"',
        "          test -x /usr/bin/openburnbar-daemon",
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          marker="p30-$(openssl rand -hex 8)"',
        "          node scripts/linux-port/run-p30-native-pet-probes.mjs",
        '            --home-dir "$home_root"',
        '            --desktop "$desktop"',
        '            --display-server "$display_server"',
        '            --marker "$marker"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p30-pet-session.mjs",
        '            --compositor "$compositor"',
        "          node scripts/linux-port/capture-p30-pet-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-27 installed notification and deep-link proof",
        "        if: inputs.requirement == 'P-27'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p27-evidence.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p27-home.XXXXXX")"',
        '          runtime_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p27-runtime.XXXXXX")"',
        '          rm -rf "$evidence_root" "$home_root" "$runtime_root" || status=1',
        '          chmod 700 "$evidence_root" "$home_root" "$runtime_root"',
        "          command -v tauri-driver >/dev/null",
        "          command -v WebKitWebDriver >/dev/null",
        "          node scripts/linux-port/run-p27-native-notification-probes.mjs",
        '            --home-dir "$home_root"',
        '            --runtime-dir "$runtime_root"',
        '            --desktop "$desktop"',
        '            --display-server "$display_server"',
        '            --marker "$marker"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p27-notifications-session.mjs",
        '            --compositor "$compositor"',
        "          node scripts/linux-port/capture-p27-notifications-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-28 installed SmartHub proof",
        "        if: inputs.requirement == 'P-28'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p28-evidence.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p28-home.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p28-support.XXXXXX")"',
        '          rm -rf "$evidence_root" "$home_root" "$support_root" || status=1',
        '          chmod 700 "$evidence_root" "$home_root" "$support_root"',
        "          node scripts/linux-port/run-p28-native-smarthub-probes.mjs",
        '            --home-dir "$home_root"',
        '            --support-dir "$support_root"',
        '            --desktop "$desktop"',
        '            --display-server "$display_server"',
        "            --bridge-port 8787",
        '            --marker "$marker"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p28-smarthub-session.mjs",
        '            --compositor "$compositor"',
        "          node scripts/linux-port/capture-p28-smarthub-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-29 installed text expansion proof",
        "        if: inputs.requirement == 'P-29'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p29-evidence.XXXXXX")"',
        '          support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p29-support.XXXXXX")"',
        '          home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p29-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
        '          chmod 700 "$evidence_root" "$support_root" "$home_root"',
        "          test -x /usr/libexec/openburnbar/text-expansion-engine",
        "          test -f /usr/share/ibus/component/openburnbar.xml",
        "          test -f /usr/share/openburnbar/text-expansion/text-expansion-engine.json",
        "          if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
        '          openssl rand -hex 32 >"$token_file"',
        '          chmod 600 "$token_file"',
        "          node scripts/linux-port/run-p29-installed-text-expansion-workflow.mjs",
        '            --support-dir "$support_root"',
        '            --home-dir "$home_root"',
        '            --socket-path "$socket_path"',
        '            --token-file "$token_file"',
        '            --index-database "$index_database"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        '            --compositor "$compositor"',
        "          node scripts/linux-port/materialize-p29-text-expansion-session.mjs",
        "          node scripts/linux-port/capture-p29-text-expansion-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-32 installed performance proof",
        "        if: inputs.requirement == 'P-32'",
        "        run: |",
        "          set -euo pipefail",
        '          raw_input="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p32-input.XXXXXX")"',
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p32-evidence.XXXXXX")"',
        '          rm -rf "$raw_input" "$evidence_root" || status=1',
        '          chmod 700 "$raw_input" "$evidence_root"',
        '          export OB_EVIDENCE_OUT="$raw_input"',
        "          node scripts/linux-port/run-matched-performance.mjs",
        "            --linux-only",
        "            --compare-only",
        "            --profile nightly",
        "          node scripts/linux-port/run-perf-budget.mjs",
        "          node scripts/linux-port/run-p32-installed-performance-workflow.mjs",
        '            --input-dir "$raw_input"',
        '            --output-dir "$evidence_root"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p32-performance-session.mjs",
        '            --raw-evidence-dir "$evidence_root"',
        "          node scripts/linux-port/capture-p32-performance-proof.mjs",
        '            --session-report "$input_root/p32-installed-performance-session.json"',
      ].join("\n"),
      [
        "      - name: Capture P-33 installed reliability proof",
        "        if: inputs.requirement == 'P-33'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p33-evidence.XXXXXX")"',
        '          state_home="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p33-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$state_home" || status=1',
        '          chmod 700 "$evidence_root" "$state_home"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/bin/openburnbar-daemon",
        "          test -x /usr/bin/openburnbar",
        "          node scripts/linux-port/run-p33-native-reliability-probes.mjs",
        '            --state-home "$state_home"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p33-reliability-session.mjs",
        '            --compositor "$compositor"',
        "          node scripts/linux-port/capture-p33-reliability-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-35 installed diagnostics and support proof",
        "        if: inputs.requirement == 'P-35'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p35-evidence.XXXXXX")"',
        '          destination_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p35-destination.XXXXXX")"',
        '          state_home="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p35-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$state_home" "$destination_root" || status=1',
        '          chmod 700 "$evidence_root" "$state_home" "$destination_root"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          test -x /usr/bin/openburnbar-daemon",
        "          node scripts/linux-port/run-p35-native-diagnostics-probes.mjs",
        '            --destination-dir "$destination_root"',
        '            --state-home "$state_home"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p35-diagnostics-support-session.mjs",
        '            --compositor "$compositor"',
        "          node scripts/linux-port/capture-p35-diagnostics-support-proof.mjs",
      ].join("\n"),
      [
        "      - name: Capture P-36 installed visual and interaction polish proof",
        "        if: inputs.requirement == 'P-36'",
        "        run: |",
        "          set -euo pipefail",
        '          evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p36-evidence.XXXXXX")"',
        '          state_home="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p36-home.XXXXXX")"',
        '          rm -rf "$evidence_root" "$state_home" || status=1',
        '          chmod 700 "$evidence_root" "$state_home"',
        "          test -x /usr/bin/openburnbar-linux-desktop",
        "          command -v tauri-driver >/dev/null",
        "          command -v WebKitWebDriver >/dev/null",
        "          node scripts/linux-port/run-p36-native-visual-polish-probes.mjs",
        '            --state-home "$state_home"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        '            --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
        "          node scripts/linux-port/materialize-p36-visual-polish-session.mjs",
        '            --compositor "$compositor"',
        "          node scripts/linux-port/capture-p36-visual-polish-proof.mjs",
      ].join("\n"),
      [
        "      - name: Resolve P-25 authenticated previous release",
        "        if: inputs.requirement == 'P-25'",
        "        id: p25_previous",
        "        run: node scripts/linux-port/resolve-linux-previous-release.mjs --github-output",
      ].join("\n"),
      [
        "      - name: Capture P-25 installed Updates proof",
        "        if: inputs.requirement == 'P-25'",
        "          PREVIOUS_VERSION: ${{ steps.p25_previous.outputs.version }}",
        "          PREVIOUS_TAG: ${{ steps.p25_previous.outputs.tag }}",
        "        run: bash scripts/linux-port/run-p25-installed-update-proof-workflow.sh",
      ].join("\n"),
      "Capture P-31 installed accessibility matrix evidence",
      "Capture P-34 credential security proof",
      [
        "      - name: Capture P-39 Linux candidate-bound platform evidence",
        "        if: inputs.requirement == 'P-39'",
        "        run: |",
        "          set -euo pipefail",
        "          node scripts/linux-port/capture-p39-platform-evidence.mjs",
        "            --platform linux",
        '            --candidate-closure "$input_root/.linux-release/product-proof-closure.json"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
      ].join("\n"),
      [
        "      - name: Resolve P-39 candidate-bound platform evidence inputs",
        "        if: inputs.requirement == 'P-39'",
        "        run: |",
        "          set -euo pipefail",
        "          node scripts/linux-port/resolve-p39-platform-evidence.mjs",
        '            --target-head "$TARGET_HEAD"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
      ].join("\n"),
      [
        "      - name: Capture P-39 same-commit macOS/Linux differential proof",
        "        if: inputs.requirement == 'P-39'",
        "        run: |",
        "          set -euo pipefail",
        "          node scripts/linux-port/capture-p39-differential.mjs",
        '            --input-root "$input_root"',
        '            --macos "$MACOS_INPUT"',
        '            --linux "$LINUX_INPUT"',
        '            --environment "$ENVIRONMENT_ID"',
        '            --target-head "$TARGET_HEAD"',
        '            --version "$VERSION"',
        '            --candidate-run-id "$CANDIDATE_RUN_ID"',
        '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
        "            --ignore '$.payload.generatedAt'",
        "            --ignore '$.payload.execution'",
      ].join("\n"),
      "Finalize registered feature proof closure",
      "Materialize the requirement-owned release closure",
      "Run the registered requirement validator",
    ].join("\n"),
    promotionWorkflow: [
      "resolve-product-evidence-run.mjs",
      "resolve-product-receipt-artifacts.mjs",
      'artifact_count }}" = "280"',
      'attest-product-requirement.mjs --requirement "P-${number}"',
      "validate-parity-ledger.mjs",
      "verify-linux-release.mjs",
      "--candidate",
      "finalize-linux-promotion-closure.mjs",
      "uses: actions/attest@",
      "promotion-closure.json.sigstore.jsonl",
      "product-proof-closure.json.ed25519.sig",
      "--candidate-artifact-digest",
      "--draft",
      "--draft=false",
      "'*source-*.tar'",
      "-name '*.pkg.tar.zst'",
      "-name 'PKGBUILD'",
      "-name 'arch-release-metadata.json'",
      "-name 'openburnbar-*.installed-manifest.json'",
      "-name 'openburnbar-*.installed-manifest.ed25519'",
      "OPENBURNBAR_R2_CUSTOM_DOMAIN: downloads.burnbar.ai",
      "upload-linux-downloads-r2.sh",
      "https://downloads.burnbar.ai/latest-linux.json",
      "Resolve the immutable successful candidate artifact",
      "Resolve the complete immutable receipt matrix",
      "Download all 280 exact receipt artifacts",
      "Generate current-HEAD product parity attestations",
      "Verify strict product parity at promotion HEAD",
      "Download the exact candidate",
      "Reverify immutable candidate signatures and provenance",
      "Finalize candidate-bound promotion closure",
      "Attest the exact promotion closure",
      "Stage exact candidate as draft Linux GitHub release",
      "Configure branded Linux update origin",
      "Publish signed update feed to downloads origin",
      "Verify live Linux update feed after publish",
      "Publish verified Linux GitHub release",
      "      - name: Upload promotion closure\n        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4\n        with:\n          path: ${{ env.OPENBURNBAR_LINUX_RELEASE_OUT }}/promotion/\n          include-hidden-files: true\n          if-no-files-found: error",
    ].join("\n"),
    nightly: [
      "OPENBURNBAR_LINUX_EVIDENCE_OUT",
      "macos-matched-performance",
      "    outputs:",
      "      macos_artifact_name: ${{ steps.select-macos-performance-artifact.outputs.artifact_name }}",
      "      - name: Upload macOS nightly matched workload soak",
      "        id: upload-macos-performance-primary",
      "        continue-on-error: true",
      "        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4",
      "          name: linux-parity-macos-performance-nightly",
      "          path: ${{ env.OB_EVIDENCE_OUT }}/matched-performance-macos.json",
      "          if-no-files-found: error",
      "      - name: Retry macOS nightly matched workload soak upload",
      "        id: upload-macos-performance-retry",
      "        if: steps.upload-macos-performance-primary.outcome != 'success'",
      "        continue-on-error: true",
      "        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4",
      "          name: linux-parity-macos-performance-nightly-retry-${{ github.run_id }}",
      "          path: ${{ env.OB_EVIDENCE_OUT }}/matched-performance-macos.json",
      "          if-no-files-found: error",
      "      - name: Select uploaded macOS nightly matched workload soak",
      "        id: select-macos-performance-artifact",
      "        if: always()",
      "        env:",
      "          PRIMARY_OUTCOME: ${{ steps.upload-macos-performance-primary.outcome }}",
      "          RETRY_OUTCOME: ${{ steps.upload-macos-performance-retry.outcome }}",
      "          PRIMARY_NAME: linux-parity-macos-performance-nightly",
      "          RETRY_NAME: linux-parity-macos-performance-nightly-retry-${{ github.run_id }}",
      "        run: |",
      "          set -euo pipefail",
      '          if [[ "$PRIMARY_OUTCOME" == "success" ]]',
      '          echo "artifact_name=$PRIMARY_NAME" >> "$GITHUB_OUTPUT"',
      "          exit 0",
      '          if [[ "$RETRY_OUTCOME" == "success" ]]',
      '          echo "artifact_name=$RETRY_NAME" >> "$GITHUB_OUTPUT"',
      "          exit 0",
      "          Neither macOS matched-performance artifact upload succeeded.",
      "          exit 1",
      "linux-matched-performance",
      "--profile nightly",
      "OB_MATCHED_MACOS_INPUT",
      "OB_MATCHED_LINUX_INPUT",
      "linux-parity-matched-performance-nightly",
      "name: ${{ needs.macos-matched-performance.outputs.macos_artifact_name }}",
      '-v "$OPENBURNBAR_LINUX_EVIDENCE_OUT:/evidence"',
      "--env OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests",
      "      - name: Upload Linux nightly evidence",
      "        if: always()",
      "        uses: actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874",
      "        with:",
      "          name: linux-nightly-${{ matrix.label }}",
      "          path: ${{ env.OPENBURNBAR_LINUX_EVIDENCE_OUT }}/",
      "          include-hidden-files: true",
      "          if-no-files-found: warn",
      "OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests",
    ].join("\n"),
    release: [
      '- "linux-v*"',
      "COSIGN_MAX_ATTACHMENT_SIZE: 1GiB",
      "OPENBURNBAR_LINUX_COSIGN_IDENTITY: https://github.com/${{ github.workflow_ref }}",
      "resolve-linux-release-version.mjs --github-output",
      "validate-linux-release-public-config.mjs",
      "vars.OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID",
      "vars.OPENBURNBAR_FIREBASE_API_KEY",
      "vars.OPENBURNBAR_LINUX_APP_CHECK_APP_ID",
      "OPENBURNBAR_LINUX_RELEASE_OUT",
      "OPENBURNBAR_LINUX_EVIDENCE_OUT",
      "'*.sigstore.json'",
      "list-linux-release-attestation-subjects.mjs",
      "'*source-*.tar'",
      "'*parity-attestation.json'",
      "architecture: aarch64",
      "runner: ubuntu-24.04-arm",
      "architecture: x86_64",
      "runner: ubuntu-24.04",
      "--architecture-shard",
      "--phase prepare",
      "--network none",
      "--read-only",
      "--cap-drop ALL",
      "--security-opt no-new-privileges",
      "sign-linux-release-requests.mjs",
      "build-signed-arch-package.mjs",
      "smoke-arch-package.mjs",
      "verify-arch-package-update-rollback.mjs",
      "arch_signature_pattern",
      "arch_manifest_pattern",
      "arch_manifest_signature_pattern",
      "--pattern 'product-proof-closure.json'",
      "--previous-signature",
      '--previous-installed-manifest "/workspace/',
      "--previous-installed-manifest-signature",
      "--previous-product-proof",
      "--previous-product-proof-signature",
      "--previous-release-tag",
      "source=$PWD,target=/workspace,readonly",
      "source=$PWD/.linux-shard/session,target=/workspace/.linux-shard/session",
      "source=$PWD/.linux-shard/arch-lifecycle,target=/workspace/.linux-shard/arch-lifecycle",
      'docker create --name "$container"',
      'docker start --attach "$container"',
      "--phase finalize",
      "previous_version",
      "linux-desktop-session.sh",
      "verify-linux-package-update-rollback.sh",
      "finalize-linux-architecture-session.mjs",
      "linux-release-shard-${{ matrix.architecture }}",
      "assemble-linux-release.mjs",
      "--candidate",
      "finalize-product-proof-closure.mjs",
      "sign-product-proof-closure.mjs",
      "product-proof-closure.json.ed25519.sig",
      "include-hidden-files: true",
      "merge-multiple: false",
      "npm ci --prefix scripts/linux-port --ignore-scripts",
      "Resolve and validate Linux release version",
      "Validate public Linux release configuration",
      "Assert native runner architecture",
      "Prepare unsigned native architecture artifacts",
      "Prepare unsigned Arch installed-manifest request",
      "Materialize exact-commit isolated signer",
      "Sign exact native requests in isolated container",
      "Finalize signed Arch package with makepkg",
      "Finalize and verify signed native architecture artifacts",
      "Native package inspection/install/uninstall smoke",
      "Arch pacman install ownership and uninstall smoke",
      "Verify Arch package update, rollback, and data preservation",
      "Run package-owned desktop, daemon, accessibility, tray, and route session",
      "Verify native package update, rollback, and data preservation",
      "Finalize commit-bound architecture session",
      "Download native architecture shards",
      "Assemble signed two-architecture closure and feed",
      "Pre-attestation Linux release verification",
      "Attest Linux release sidecars and packages",
      "Final Linux release verification",
      "Finalize installed-product proof closure",
      "Sign installed-product proof closure",
      "      - name: Upload architecture shard\n        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4\n        with:\n          path: ${{ env.OPENBURNBAR_LINUX_RELEASE_OUT }}/\n          include-hidden-files: true\n          if-no-files-found: error",
      "      - name: Upload Linux release evidence\n        uses: actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4\n        with:\n          path: |\n            ${{ env.OPENBURNBAR_LINUX_RELEASE_OUT }}/\n            ${{ env.OPENBURNBAR_LINUX_EVIDENCE_OUT }}/\n            ${{ env.OPENBURNBAR_LINUX_SHARDS_DIR }}/\n          include-hidden-files: true\n          if-no-files-found: error",
    ].join("\n"),
    makefile: "release-linux:\n\tnode verify\n\nother:",
    nativeTests: [
      "run_swift_suite",
      "OpenBurnBarLinuxCoreFoundationTests",
      "OpenBurnBarLinuxSecurityTests",
      "OpenBurnBarDaemonLinuxGatewayTests",
      "timeout 900 swift test",
      "run_xctest_case",
      "Executed 1 test",
      "cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked",
    ].join("\n"),
    rustBridge: [
      "gateway_probe",
      "gateway_chat_stream",
      "gateway_chat_cancel",
      ".bearer_auth(token)",
      "gateway_non_loopback_host_refused",
      "Policy::none()",
      "validate_external_url",
      "open_external_url",
      "external_url_host_refused",
      "trusted_openburnbar_cli",
      "/usr/bin/openburnbar-cli",
      "runtime_capabilities",
      "RUNTIME_CAPABILITY_CATALOG",
      "runtime_capability_unknown_evaluator",
    ].join("\n"),
    updateFeed: [
      "PINNED_PUBLIC_KEY_SPKI_SHA256",
      "verify_strict",
      "validate_update_artifact_url",
      "allowed_download_url",
      "MAX_FEED_BYTES",
    ].join("\n"),
    capability: '{"permissions":["core:default"]}',
    tauriConfig: '{"csp":"connect-src self ipc: tauri:"}',
    fixturePolicy:
      "DAEMON_FIXTURE_AVAILABLE\nenabled && DAEMON_FIXTURE_AVAILABLE",
    desktopPackage:
      "vite build && node ../../scripts/linux-port/verify-linux-production-bundle.mjs",
    rendererBridge: [
      "invoke<boolean>('gateway_probe')",
      "invoke<void>('gateway_chat_stream'",
      "invoke<void>('gateway_chat_cancel'",
      "invoke<void>('open_external_url'",
      "invoke<RawJsonValue>('update_status')",
      "invoke<void>('open_update_url'",
      "invoke<RawJsonValue>('runtime_capabilities')",
      "decodeRuntimeCapabilityManifest",
      "runtime_capability_manifest_missing_ids",
    ].join("\n"),
    runtimeCatalog: '{"schemaVersion": 1}',
    runtimeSchema: '{"additionalProperties": false}',
    routes: "requiredCapability\nusage.read\nmedia.mercury",
    surfaceBoundary:
      "capabilityBlocksSurface\nfindRuntimeCapability\ncapabilityError",
    p25Workflow: [
      "set -euo pipefail",
      "P-25 prerequisite missing",
      'gh release download "$PREVIOUS_TAG"',
      "product-proof-closure.json.ed25519.sig",
      "run-p25-installed-update-lifecycle.mjs",
      '--previous-package "$previous_package"',
      '--candidate-package "$candidate_package"',
      '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
      "--release-public-key packaging/linux/openburnbar-linux-ed25519.pub.pem",
      "materialize-p25-updates-session.mjs",
      "capture-p25-updates-proof.mjs",
      'rm -rf "$evidence_root" || status=1',
    ].join("\n"),
  };
}

test("complete fail-closed workflow wiring passes", () => {
  assert.deepEqual(verifyLinuxWorkflowWiring(valid()), {
    passed: true,
    failures: [],
  });
});

test("P-38 workflow step cannot be removed or weakened", () => {
  for (const marker of [
    "capture-p38-release-automation.mjs",
    "if: inputs.requirement == 'P-38'",
    "Capture P-38 release automation verification",
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replace(
      marker,
      "removed-p38-capture-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) =>
        /product parity evidence workflow/u.test(failure),
      ),
      marker,
    );
  }
  for (const [name, from, to] of [
    [
      "commented producer",
      "          node scripts/linux-port/capture-p38-release-automation.mjs",
      "          # node scripts/linux-port/capture-p38-release-automation.mjs",
    ],
    [
      "swallowed producer failure",
      "          set -euo pipefail",
      "          set -euo pipefail\n          continue-on-error: true",
    ],
    [
      "disabled fail-fast shell",
      "          set -euo pipefail",
      "          set +e",
    ],
  ]) {
    const input = valid();
    const stepName = "Capture P-38 release automation verification";
    const stepStart = input.productParityWorkflow.indexOf(
      `      - name: ${stepName}`,
    );
    const nextStep = input.productParityWorkflow.indexOf(
      "\n      - name:",
      stepStart + 1,
    );
    const end = nextStep < 0 ? input.productParityWorkflow.length : nextStep;
    const block = input.productParityWorkflow
      .slice(stepStart, end)
      .replace(from, to);
    input.productParityWorkflow = `${input.productParityWorkflow.slice(0, stepStart)}${block}${input.productParityWorkflow.slice(end)}`;
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, name);
    assert.ok(
      result.failures.some((failure) =>
        /P-38 release automation verification/u.test(failure),
      ),
      name,
    );
  }
});

test("P-08 installed media workflow cannot omit package trust or paired live evidence", () => {
  for (const marker of [
    "Install P-08 signed candidate package",
    "Capture P-08 installed Mercury media proof",
    "run-p08-mercury-media-session.mjs",
    "capture-p08-mercury-media-proof.mjs",
    '--manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
    'test -f "$desktop_report"',
    'test -f "$device_report"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p08-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => /P-08/u.test(failure)),
      marker,
    );
  }
  for (const [stepName, mutation] of [
    ["Install P-08 signed candidate package", ["set -euo pipefail", "set +e"]],
    [
      "Capture P-08 installed Mercury media proof",
      ["set -euo pipefail", "set +e"],
    ],
    [
      "Capture P-08 installed Mercury media proof",
      ['test -f "$device_report"', "true"],
    ],
  ]) {
    const input = valid();
    const stepStart = input.productParityWorkflow.indexOf(
      `      - name: ${stepName}`,
    );
    assert.ok(stepStart >= 0, stepName);
    const nextStep = input.productParityWorkflow.indexOf(
      "\n      - name:",
      stepStart + 1,
    );
    const end = nextStep < 0 ? input.productParityWorkflow.length : nextStep;
    const block = input.productParityWorkflow
      .slice(stepStart, end)
      .replace(...mutation);
    input.productParityWorkflow = `${input.productParityWorkflow.slice(0, stepStart)}${block}${input.productParityWorkflow.slice(end)}`;
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, `${stepName}: ${mutation[0]}`);
    assert.ok(result.failures.some((failure) => /P-08/u.test(failure)));
  }
});

test("P-25 signed update lifecycle workflow fails closed on provenance or restoration drift", () => {
  for (const [surface, marker] of [
    ["productParityWorkflow", "Resolve P-25 authenticated previous release"],
    [
      "productParityWorkflow",
      "PREVIOUS_VERSION: ${{ steps.p25_previous.outputs.version }}",
    ],
    [
      "productParityWorkflow",
      "bash scripts/linux-port/run-p25-installed-update-proof-workflow.sh",
    ],
    ["p25Workflow", 'gh release download "$PREVIOUS_TAG"'],
    ["p25Workflow", "product-proof-closure.json.ed25519.sig"],
    ["p25Workflow", "run-p25-installed-update-lifecycle.mjs"],
    ["p25Workflow", '--previous-package "$previous_package"'],
    ["p25Workflow", '--candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'],
    ["p25Workflow", 'rm -rf "$evidence_root" || status=1'],
  ]) {
    const input = valid();
    input[surface] = input[surface].replace(marker, "removed-p25-marker");
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-25")),
      marker,
    );
  }
});

test("P-16 physical iPad producer and Linux handshake remain exact and fail closed", () => {
  const producerStart = "  p16-ipad-producer:";
  const producerEnd = "\n  p32-macos-producer:";
  const linuxStart =
    "      - name: Capture P-16 installed cloud and devices proof";
  const linuxEnd = "\n      - name:";
  for (const [scope, marker, replacement = "removed-p16-marker"] of [
    ["producer", producerStart],
    ["producer", "      - self-hosted", "      - hosted"],
    ["producer", "      - macos", "      - linux"],
    ["producer", "      - arm64", "      - x64"],
    ["producer", "FIREBASE_PLIST_BASE64: ${{ secrets.FIREBASE_PLIST_BASE64 }}"],
    ["producer", "bash scripts/ci/inject-firebase-config.sh"],
    [
      "producer",
      "OPENBURNBAR_P16_MACOS_COORDINATION_ROOT",
      "OPENBURNBAR_P16_WRONG_COORDINATION_ROOT",
    ],
    [
      "producer",
      '          rm -rf "$scratch_root" || status=1',
      "          true",
    ],
    ["producer", '            --coordination-dir "$coordination_dir"'],
    ["producer", '            --scratch-root "$scratch_root"'],
    ["producer", '            --target-head "$TARGET_HEAD"'],
    ["producer", '            --candidate-run-id "$CANDIDATE_RUN_ID"'],
    [
      "producer",
      '            --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
    ],
    [
      "linux",
      "OPENBURNBAR_P16_LINUX_COORDINATION_ROOT",
      "OPENBURNBAR_P16_WRONG_COORDINATION_ROOT",
    ],
    [
      "linux",
      '          rm -rf "$evidence_root" "$state_home" "$coordination_dir" || status=1',
      "          true",
    ],
    ["linux", '            --mobile-receipt "$mobile_receipt"'],
    ["linux", '            --coordination-dir "$coordination_dir"'],
  ]) {
    const input = valid();
    const startMarker = scope === "producer" ? producerStart : linuxStart;
    const endMarker = scope === "producer" ? producerEnd : linuxEnd;
    const start = input.productParityWorkflow.indexOf(startMarker);
    assert.ok(start >= 0, `${scope}: ${marker}`);
    const endIndex = input.productParityWorkflow.indexOf(
      endMarker,
      start + startMarker.length,
    );
    const end = endIndex < 0 ? input.productParityWorkflow.length : endIndex;
    const original = input.productParityWorkflow.slice(start, end);
    const mutated = original.replace(marker, replacement);
    assert.notEqual(mutated, original, `${scope}: ${marker}`);
    input.productParityWorkflow = `${input.productParityWorkflow.slice(0, start)}${mutated}${input.productParityWorkflow.slice(end)}`;

    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, `${scope}: ${marker}`);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-16")),
      `${scope}: ${marker}`,
    );
  }
});

test("new installed proof and WebDriver PR fixtures are mandatory", () => {
  for (const marker of [
    "p15-account-billing-proof.test.mjs",
    "p16-cloud-devices-proof.test.mjs",
    "p16-physical-ipad-coordination.test.mjs",
    "p33-reliability-proof.test.mjs",
    "p35-diagnostics-support-proof.test.mjs",
    "p36-visual-polish-proof.test.mjs",
    "install-tauri-webdriver-prerequisites.test.mjs",
  ]) {
    const input = valid();
    input.pr = input.pr.replace(marker, "removed-pr-fixture");
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes(marker)),
      marker,
    );
  }
});

test("registered installed UI workflows require native runners before materialization and fail closed", () => {
  for (const [requirementId, stepName, runner, materializer, capture] of [
    [
      "P-09",
      "Capture P-09 installed navigation shell proof",
      "scripts/linux-port/run-p09-native-navigation-probes.mjs",
      "scripts/linux-port/materialize-p09-navigation-shell-session.mjs",
      "scripts/linux-port/capture-p09-navigation-shell-proof.mjs",
    ],
    [
      "P-10",
      "Capture P-10 installed dashboard layout proof",
      "scripts/linux-port/run-p10-native-dashboard-probes.mjs",
      "scripts/linux-port/materialize-p10-dashboard-layout-session.mjs",
      "scripts/linux-port/capture-p10-dashboard-layout-proof.mjs",
    ],
    [
      "P-11",
      "Capture P-11 installed usage ingestion proof",
      "scripts/linux-port/run-p11-usage-ingestion-session.mjs",
      "scripts/linux-port/materialize-p11-usage-ingestion-session.mjs",
      "scripts/linux-port/capture-p11-usage-ingestion-proof.mjs",
    ],
    [
      "P-12",
      "Capture P-12 installed quota proof",
      "scripts/linux-port/run-p12-native-quota-probes.mjs",
      "scripts/linux-port/materialize-p12-quota-session.mjs",
      "scripts/linux-port/capture-p12-quota-proof.mjs",
    ],
    [
      "P-13",
      "Capture P-13 installed onboarding proof",
      "scripts/linux-port/run-p13-native-onboarding-probes.mjs",
      "scripts/linux-port/materialize-p13-onboarding-session.mjs",
      "scripts/linux-port/capture-p13-onboarding-proof.mjs",
    ],
    [
      "P-14",
      "Capture P-14 installed chat proof",
      "scripts/linux-port/run-p14-chat-session.mjs",
      "scripts/linux-port/materialize-p14-chat-session.mjs",
      "scripts/linux-port/capture-p14-chat-proof.mjs",
    ],
    [
      "P-15",
      "Capture P-15 installed account and billing proof",
      "scripts/linux-port/run-p15-native-account-billing-probes.mjs",
      "scripts/linux-port/materialize-p15-account-billing-session.mjs",
      "scripts/linux-port/capture-p15-account-billing-proof.mjs",
    ],
    [
      "P-16",
      "Capture P-16 installed cloud and devices proof",
      "scripts/linux-port/run-p16-native-cloud-devices-probes.mjs",
      "scripts/linux-port/materialize-p16-cloud-devices-session.mjs",
      "scripts/linux-port/capture-p16-cloud-devices-proof.mjs",
    ],
    [
      "P-17",
      "Capture P-17 installed Activity proof",
      "scripts/linux-port/run-p17-native-activity-probes.mjs",
      "scripts/linux-port/materialize-p17-activity-session.mjs",
      "scripts/linux-port/capture-p17-activity-proof.mjs",
    ],
    [
      "P-18",
      "Capture P-18 installed memory-review proof",
      "scripts/linux-port/run-p18-native-memory-probes.mjs",
      "scripts/linux-port/materialize-p18-memory-review-session.mjs",
      "scripts/linux-port/capture-p18-memory-review-proof.mjs",
    ],
    [
      "P-19",
      "Capture P-19 installed Projects proof",
      "scripts/linux-port/run-p19-native-projects-probes.mjs",
      "scripts/linux-port/materialize-p19-projects-session.mjs",
      "scripts/linux-port/capture-p19-projects-proof.mjs",
    ],
    [
      "P-20",
      "Capture P-20 installed Missions proof",
      "scripts/linux-port/run-p20-native-missions-probes.mjs",
      "scripts/linux-port/materialize-p20-missions-session.mjs",
      "scripts/linux-port/capture-p20-missions-proof.mjs",
    ],
    [
      "P-21",
      "Capture P-21 installed Insights proof",
      "scripts/linux-port/run-p21-native-insights-probes.mjs",
      "scripts/linux-port/materialize-p21-insights-session.mjs",
      "scripts/linux-port/capture-p21-insights-proof.mjs",
    ],
    [
      "P-22",
      "Capture P-22 installed Database proof",
      "scripts/linux-port/run-p22-native-database-probes.mjs",
      "scripts/linux-port/materialize-p22-database-session.mjs",
      "scripts/linux-port/capture-p22-database-proof.mjs",
    ],
    [
      "P-23",
      "Capture P-23 installed Provider workspace proof",
      "scripts/linux-port/run-p23-native-provider-workspace-probes.mjs",
      "scripts/linux-port/materialize-p23-provider-workspace-session.mjs",
      "scripts/linux-port/capture-p23-provider-workspace-proof.mjs",
    ],
    [
      "P-24",
      "Capture P-24 installed Settings proof",
      "scripts/linux-port/run-p24-installed-settings-workflow.mjs",
      "scripts/linux-port/materialize-p24-settings-session.mjs",
      "scripts/linux-port/capture-p24-settings-proof.mjs",
    ],
    [
      "P-26",
      "Capture P-26 installed tray proof",
      "scripts/linux-port/run-p26-native-tray-probes.mjs",
      "scripts/linux-port/materialize-p26-tray-session.mjs",
      "scripts/linux-port/capture-p26-tray-proof.mjs",
    ],
    [
      "P-27",
      "Capture P-27 installed notification and deep-link proof",
      "scripts/linux-port/run-p27-native-notification-probes.mjs",
      "scripts/linux-port/materialize-p27-notifications-session.mjs",
      "scripts/linux-port/capture-p27-notifications-proof.mjs",
    ],
    [
      "P-28",
      "Capture P-28 installed SmartHub proof",
      "scripts/linux-port/run-p28-native-smarthub-probes.mjs",
      "scripts/linux-port/materialize-p28-smarthub-session.mjs",
      "scripts/linux-port/capture-p28-smarthub-proof.mjs",
    ],
    [
      "P-29",
      "Capture P-29 installed text expansion proof",
      "scripts/linux-port/run-p29-installed-text-expansion-workflow.mjs",
      "scripts/linux-port/materialize-p29-text-expansion-session.mjs",
      "scripts/linux-port/capture-p29-text-expansion-proof.mjs",
    ],
    [
      "P-30",
      "Capture P-30 installed pet proof",
      "scripts/linux-port/run-p30-native-pet-probes.mjs",
      "scripts/linux-port/materialize-p30-pet-session.mjs",
      "scripts/linux-port/capture-p30-pet-proof.mjs",
    ],
    [
      "P-32",
      "Capture P-32 installed performance proof",
      "scripts/linux-port/run-p32-installed-performance-workflow.mjs",
      "scripts/linux-port/materialize-p32-performance-session.mjs",
      "scripts/linux-port/capture-p32-performance-proof.mjs",
    ],
    [
      "P-33",
      "Capture P-33 installed reliability proof",
      "scripts/linux-port/run-p33-native-reliability-probes.mjs",
      "scripts/linux-port/materialize-p33-reliability-session.mjs",
      "scripts/linux-port/capture-p33-reliability-proof.mjs",
    ],
    [
      "P-35",
      "Capture P-35 installed diagnostics and support proof",
      "scripts/linux-port/run-p35-native-diagnostics-probes.mjs",
      "scripts/linux-port/materialize-p35-diagnostics-support-session.mjs",
      "scripts/linux-port/capture-p35-diagnostics-support-proof.mjs",
    ],
    [
      "P-36",
      "Capture P-36 installed visual and interaction polish proof",
      "scripts/linux-port/run-p36-native-visual-polish-probes.mjs",
      "scripts/linux-port/materialize-p36-visual-polish-session.mjs",
      "scripts/linux-port/capture-p36-visual-polish-proof.mjs",
    ],
  ]) {
    for (const marker of [
      "Install signed candidate for installed feature proofs",
      stepName,
      runner,
      materializer,
      capture,
      '--manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
    ]) {
      const input = valid();
      input.productParityWorkflow = input.productParityWorkflow.replaceAll(
        marker,
        `removed-${requirementId}-marker`,
      );
      const result = verifyLinuxWorkflowWiring(input);
      assert.equal(result.passed, false, `${requirementId}: ${marker}`);
      assert.ok(
        result.failures.some((failure) => failure.includes(requirementId)),
        `${requirementId}: ${marker}`,
      );
    }

    const runnerFailure = valid();
    runnerFailure.productParityWorkflow =
      runnerFailure.productParityWorkflow.replace(
        `node ${runner}`,
        `node ${runner} || true`,
      );
    let result = verifyLinuxWorkflowWiring(runnerFailure);
    assert.equal(
      result.passed,
      false,
      `${requirementId} runner failure swallowing`,
    );
    assert.ok(
      result.failures.some((failure) => failure.includes(requirementId)),
    );

    const reordered = valid();
    reordered.productParityWorkflow = reordered.productParityWorkflow
      .replace(`node ${runner}`, "node __TEMP_NATIVE_RUNNER__")
      .replace(`node ${materializer}`, `node ${runner}`)
      .replace("node __TEMP_NATIVE_RUNNER__", `node ${materializer}`);
    result = verifyLinuxWorkflowWiring(reordered);
    assert.equal(
      result.passed,
      false,
      `${requirementId} runner/materializer order`,
    );
    assert.ok(
      result.failures.some((failure) => failure.includes(requirementId)),
    );
  }
});

test("shared installed proof package and WebDriver prerequisites fail closed", () => {
  for (const [stepName, marker] of [
    [
      "Install signed candidate for installed feature proofs",
      "if: inputs.requirement == 'P-09' || inputs.requirement == 'P-10' || inputs.requirement == 'P-11' || inputs.requirement == 'P-12' || inputs.requirement == 'P-13' || inputs.requirement == 'P-14' || inputs.requirement == 'P-15' || inputs.requirement == 'P-16' || inputs.requirement == 'P-17' || inputs.requirement == 'P-18' || inputs.requirement == 'P-19' || inputs.requirement == 'P-20' || inputs.requirement == 'P-21' || inputs.requirement == 'P-22' || inputs.requirement == 'P-23' || inputs.requirement == 'P-24' || inputs.requirement == 'P-25' || inputs.requirement == 'P-26' || inputs.requirement == 'P-27' || inputs.requirement == 'P-28' || inputs.requirement == 'P-29' || inputs.requirement == 'P-30' || inputs.requirement == 'P-32' || inputs.requirement == 'P-33' || inputs.requirement == 'P-35' || inputs.requirement == 'P-36'",
    ],
    [
      "Install signed candidate for installed feature proofs",
      "set -euo pipefail",
    ],
    [
      "Install signed candidate for installed feature proofs",
      'sudo apt-get install -y --reinstall "$package"',
    ],
    [
      "Install signed candidate for installed feature proofs",
      'sudo dnf install -y "$package"',
    ],
    [
      "Install signed candidate for installed feature proofs",
      'sudo pacman -U --noconfirm "$package"',
    ],
    [
      "Install signed candidate for installed feature proofs",
      'test "$(awk -F \' = \' \'$1 == "pkgname" { print $2 }\' <<<"$package_info")" = openburnbar',
    ],
    [
      "Install signed candidate for installed feature proofs",
      "sha256sum /usr/share/openburnbar/attestation/installed-manifest.json",
    ],
    [
      "Install signed candidate for installed feature proofs",
      "sha256sum /usr/share/openburnbar/attestation/installed-manifest.json.sig",
    ],
    [
      "Provision native Tauri WebDriver prerequisites",
      "if: inputs.requirement == 'P-15' || inputs.requirement == 'P-16' || inputs.requirement == 'P-27' || inputs.requirement == 'P-36'",
    ],
    ["Provision native Tauri WebDriver prerequisites", "set -euo pipefail"],
    [
      "Provision native Tauri WebDriver prerequisites",
      "bash scripts/linux-port/install-tauri-webdriver-prerequisites.sh",
    ],
  ]) {
    const input = valid();
    const stepStart = input.productParityWorkflow.indexOf(
      `      - name: ${stepName}`,
    );
    assert.ok(stepStart >= 0, stepName);
    const nextStep = input.productParityWorkflow.indexOf(
      "\n      - name:",
      stepStart + 1,
    );
    const end = nextStep < 0 ? input.productParityWorkflow.length : nextStep;
    const block = input.productParityWorkflow
      .slice(stepStart, end)
      .replace(marker, "removed-prerequisite");
    assert.notEqual(
      block,
      input.productParityWorkflow.slice(stepStart, end),
      marker,
    );
    input.productParityWorkflow = `${input.productParityWorkflow.slice(0, stepStart)}${block}${input.productParityWorkflow.slice(end)}`;

    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes(stepName)),
      marker,
    );
  }
});

test("P-24 installed Settings workflow preserves isolated daemon, home, and process cleanup fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-evidence.XXXXXX")"',
    'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-support.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-home.XXXXXX")"',
    'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
    'openssl rand -hex 32 >"$token_file"',
    '--home-dir "$home_root"',
    '--socket-path "$socket_path"',
    '--token-file "$token_file"',
    '--index-database "$index_database"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p24-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-24")),
      marker,
    );
  }
});

test("P-26 installed tray workflow preserves isolated state, package ownership, and cleanup fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-evidence.XXXXXX")"',
    'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-support.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-home.XXXXXX")"',
    'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
    "test -f /etc/xdg/autostart/openburnbar.desktop",
    'openssl rand -hex 32 >"$token_file"',
    '--support-dir "$support_root"',
    '--home-dir "$home_root"',
    '--socket-path "$socket_path"',
    '--token-file "$token_file"',
    '--index-database "$index_database"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p26-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-26")),
      marker,
    );
  }
});

test("P-30 installed pet workflow preserves compositor honesty, isolated state, and cleanup fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p30-evidence.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p30-home.XXXXXX")"',
    'rm -rf "$evidence_root" "$home_root" || status=1',
    "test -x /usr/bin/openburnbar-daemon",
    'marker="p30-$(openssl rand -hex 8)"',
    '--home-dir "$home_root"',
    '--desktop "$desktop"',
    '--display-server "$display_server"',
    '--marker "$marker"',
    '--compositor "$compositor"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p30-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-30")),
      marker,
    );
  }
});

test("P-32 performance workflow preserves candidate binding, nightly producers, and cleanup fail closed", () => {
  for (const marker of [
    "p32-macos-producer",
    "Capture P-32 candidate-bound macOS nightly performance",
    "--macos-only",
    "linux-p32-macos-nightly-performance",
    "Download P-32 macOS nightly performance",
    'raw_input="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p32-input.XXXXXX")"',
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p32-evidence.XXXXXX")"',
    'rm -rf "$raw_input" "$evidence_root" || status=1',
    'export OB_EVIDENCE_OUT="$raw_input"',
    "--linux-only",
    "--compare-only",
    "--profile nightly",
    "node scripts/linux-port/run-perf-budget.mjs",
    '--input-dir "$raw_input"',
    '--output-dir "$evidence_root"',
    '--raw-evidence-dir "$evidence_root"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p32-performance-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-32")),
      marker,
    );
  }
});

test("shared installed UI Arch package identity remains canonical", () => {
  const input = valid();
  const stepName = "Install signed candidate for installed feature proofs";
  const stepStart = input.productParityWorkflow.indexOf(
    `      - name: ${stepName}`,
  );
  const nextStep = input.productParityWorkflow.indexOf(
    "\n      - name:",
    stepStart + 1,
  );
  const end = nextStep < 0 ? input.productParityWorkflow.length : nextStep;
  const block = input.productParityWorkflow
    .slice(stepStart, end)
    .replace(
      'test "$(awk -F \' = \' \'$1 == "pkgname" { print $2 }\' <<<"$package_info")" = openburnbar',
      'test "$(awk -F \' = \' \'$1 == "pkgname" { print $2 }\' <<<"$package_info")" = open-burn-bar',
    );
  input.productParityWorkflow = `${input.productParityWorkflow.slice(0, stepStart)}${block}${input.productParityWorkflow.slice(end)}`;

  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => failure.includes(stepName)));
});

test("P-06 Arch package identity and version normalization remain canonical", () => {
  for (const marker of [
    'test "$(awk -F \' = \' \'$1 == "pkgname" { print $2 }\' <<<"$package_info")" = openburnbar',
    'version="${version%-*}"',
  ]) {
    const input = valid();
    const stepName = "Install P-06 signed candidate package";
    const stepStart = input.productParityWorkflow.indexOf(
      `      - name: ${stepName}`,
    );
    const nextStep = input.productParityWorkflow.indexOf(
      "\n      - name:",
      stepStart + 1,
    );
    const end = nextStep < 0 ? input.productParityWorkflow.length : nextStep;
    const block = input.productParityWorkflow
      .slice(stepStart, end)
      .replace(marker, "removed-p06-arch-marker");
    input.productParityWorkflow = `${input.productParityWorkflow.slice(0, stepStart)}${block}${input.productParityWorkflow.slice(end)}`;

    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes(stepName)),
      marker,
    );
  }
});

test("P-12 installed quota workflow preserves isolated gateway and daemon state fail closed", () => {
  for (const marker of [
    'systemctl --user show-environment >"$original_environment"',
    'systemctl --user unset-environment "${managed_variables[@]}"',
    'if [[ "$service_was_active" == 1 ]]; then',
    'openssl rand -hex 32 >"$gateway_token_file"',
    'gateway_token="$(<"$gateway_token_file")"',
    "(( gateway_port >= 1024 && gateway_port <= 65535 ))",
    'export OPENBURNBAR_DAEMON_SUPPORT_DIR="$support_root"',
    'export OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path"',
    "OPENBURNBAR_GATEWAY_ENABLED=1 \\",
    "OPENBURNBAR_GATEWAY_HOST=127.0.0.1 \\",
    '"OPENBURNBAR_GATEWAY_PORT=$gateway_port" \\',
    '"OPENBURNBAR_GATEWAY_AUTH_TOKEN=$gateway_token"',
    '--gateway-token-file "$gateway_token_file"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p12-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-12")),
      marker,
    );
  }
});

test("P-13 installed onboarding workflow preserves isolated daemon, home, and credential cleanup fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p13-evidence.XXXXXX")"',
    'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p13-support.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p13-home.XXXXXX")"',
    'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
    'openssl rand -hex 32 >"$token_file"',
    '--home-dir "$home_root"',
    '--socket-path "$socket_path"',
    '--token-file "$token_file"',
    '--index-database "$index_database"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p13-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-13")),
      marker,
    );
  }
});

test("P-14 installed chat workflow preserves isolated daemon, home, and download state fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-evidence.XXXXXX")"',
    'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-support.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-home.XXXXXX")"',
    'download_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-downloads.XXXXXX")"',
    'systemctl --user show-environment >"$original_environment"',
    'systemctl --user unset-environment "${managed_variables[@]}"',
    'rm -rf "$evidence_root" "$support_root" "$home_root" "$download_root" || status=1',
    'export HOME="$home_root"',
    'export XDG_CONFIG_HOME="$home_root/.config"',
    '--database-path "$database_path"',
    '--attachment "$attachment_path"',
    '--download-dir "$download_root"',
    '--thread-id "$thread_id"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p14-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-14")),
      marker,
    );
  }
});

test("P-17 installed Activity workflow preserves isolated state and exact export routing fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-evidence.XXXXXX")"',
    'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-support.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-home.XXXXXX")"',
    'download_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-downloads.XXXXXX")"',
    'rm -rf "$evidence_root" "$support_root" "$home_root" "$download_root" || status=1',
    'openssl rand -hex 32 >"$token_file"',
    '--home-dir "$home_root"',
    '--download-dir "$download_root"',
    '--index-database "$index_database"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p17-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-17")),
      marker,
    );
  }
});

test("P-18 installed memory workflow preserves isolated daemon and home state fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-evidence.XXXXXX")"',
    'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-support.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-home.XXXXXX")"',
    'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
    'openssl rand -hex 32 >"$token_file"',
    '--home-dir "$home_root"',
    '--socket-path "$socket_path"',
    '--token-file "$token_file"',
    '--index-database "$index_database"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p18-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-18")),
      marker,
    );
  }
});

test("P-19 installed Projects workflow preserves isolated daemon and home state fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-evidence.XXXXXX")"',
    'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-support.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-home.XXXXXX")"',
    'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
    'openssl rand -hex 32 >"$token_file"',
    '--home-dir "$home_root"',
    '--socket-path "$socket_path"',
    '--token-file "$token_file"',
    '--index-database "$index_database"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p19-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-19")),
      marker,
    );
  }
});

test("P-20 installed Missions workflow preserves isolated daemon and home state fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-evidence.XXXXXX")"',
    'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-support.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-home.XXXXXX")"',
    'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
    'openssl rand -hex 32 >"$token_file"',
    '--home-dir "$home_root"',
    '--socket-path "$socket_path"',
    '--token-file "$token_file"',
    '--index-database "$index_database"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p20-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-20")),
      marker,
    );
  }
});

test("P-21 installed Insights workflow preserves isolated daemon and home state fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-evidence.XXXXXX")"',
    'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-support.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-home.XXXXXX")"',
    'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
    'openssl rand -hex 32 >"$token_file"',
    '--home-dir "$home_root"',
    '--socket-path "$socket_path"',
    '--token-file "$token_file"',
    '--index-database "$index_database"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p21-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-21")),
      marker,
    );
  }
});

test("P-22 installed Database workflow preserves isolated daemon and home state fail closed", () => {
  for (const marker of [
    'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-evidence.XXXXXX")"',
    'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-support.XXXXXX")"',
    'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-home.XXXXXX")"',
    'rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
    'openssl rand -hex 32 >"$token_file"',
    '--home-dir "$home_root"',
    '--socket-path "$socket_path"',
    '--token-file "$token_file"',
    '--index-database "$index_database"',
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p22-state-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => failure.includes("P-22")),
      marker,
    );
  }
});

test("P-39 differential workflow cannot be removed or weakened", () => {
  for (const marker of [
    "resolve-p39-platform-evidence.mjs",
    "capture-p39-differential.mjs",
    "Resolve P-39 candidate-bound platform evidence inputs",
    "Capture P-39 same-commit macOS/Linux differential proof",
    "--ignore '$.payload.generatedAt'",
    "--ignore '$.payload.execution'",
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed-p39-capture-marker",
    );
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, marker);
    assert.ok(
      result.failures.some((failure) => /P-39/u.test(failure)),
      marker,
    );
  }
  for (const [name, from, to] of [
    [
      "commented resolver",
      "          node scripts/linux-port/resolve-p39-platform-evidence.mjs",
      "          # node scripts/linux-port/resolve-p39-platform-evidence.mjs",
    ],
    [
      "swallowed capture failure",
      "          set -euo pipefail",
      "          set -euo pipefail\n          continue-on-error: true",
    ],
    [
      "disabled capture fail-fast shell",
      "          set -euo pipefail",
      "          set +e",
    ],
  ]) {
    const input = valid();
    const stepName = name.includes("resolver")
      ? "      - name: Resolve P-39 candidate-bound platform evidence inputs"
      : "      - name: Capture P-39 same-commit macOS/Linux differential proof";
    const stepStart = input.productParityWorkflow.indexOf(stepName);
    assert.ok(stepStart >= 0);
    const before = input.productParityWorkflow.slice(0, stepStart);
    const step = input.productParityWorkflow.slice(stepStart);
    input.productParityWorkflow = `${before}${step.replace(from, to)}`;
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, name);
    assert.ok(
      result.failures.some((failure) => /P-39/u.test(failure)),
      name,
    );
  }
});

test("hidden Linux output uploads fail closed when upload protections mutate", () => {
  for (const [surface, step, mutation] of [
    ["release", "Upload architecture shard", "include-hidden-files: false"],
    ["release", "Upload Linux release evidence", "if-no-files-found: warn"],
    [
      "promotionWorkflow",
      "Upload promotion closure",
      "actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874",
    ],
    ["nightly", "Upload Linux nightly evidence", "include-hidden-files: false"],
  ]) {
    const input = valid();
    const start = input[surface].indexOf(`- name: ${step}`);
    assert.ok(start >= 0, step);
    const original = mutation.startsWith("include-hidden")
      ? "include-hidden-files: true"
      : mutation.startsWith("if-no-files")
        ? "if-no-files-found: error"
        : "actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4";
    input[surface] =
      `${input[surface].slice(0, start)}${input[surface].slice(start).replace(original, mutation)}`;
    assert.equal(
      verifyLinuxWorkflowWiring(input).passed,
      false,
      `${surface}:${step}`,
    );
  }
});

test("Linux Swift evidence must remain host-mounted and routed in both workflows", () => {
  for (const field of ["pr", "nightly"]) {
    const input = valid();
    input[field] = input[field].replace(
      '-v "$OPENBURNBAR_LINUX_EVIDENCE_OUT:/evidence"',
      "",
    );
    assert.equal(
      verifyLinuxWorkflowWiring(input).passed,
      false,
      `${field}:evidence mount`,
    );

    const routed = valid();
    routed[field] = routed[field].replace(
      "--env OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests",
      "",
    );
    assert.equal(
      verifyLinuxWorkflowWiring(routed).passed,
      false,
      `${field}:evidence route`,
    );
  }
});

test("product evidence dependency install and mutation suites are mandatory in the PR gate", () => {
  for (const marker of [
    "npm ci --prefix scripts/linux-port --ignore-scripts",
    "attest-product-requirement.test.mjs",
    "github-artifact-provenance.test.mjs",
    "smoke-linux-packages.test.mjs",
    "product-feature-proof-closure.test.mjs",
    "p07-computer-use-proof.test.mjs",
    "p08-mercury-media-proof.test.mjs",
    "p09-navigation-shell-proof.test.mjs",
    "p10-dashboard-layout-proof.test.mjs",
    "p11-usage-ingestion-proof.test.mjs",
    "p12-quota-proof.test.mjs",
    "p17-native-activity-probes.test.mjs",
    "p17-activity-proof.test.mjs",
    "p18-native-memory-probes.test.mjs",
    "p18-memory-review-proof.test.mjs",
    "p19-native-projects-probes.test.mjs",
    "p19-projects-proof.test.mjs",
    "p20-native-missions-probes.test.mjs",
    "p20-missions-proof.test.mjs",
    "p21-native-insights-probes.test.mjs",
    "p21-insights-proof.test.mjs",
    "p22-native-database-probes.test.mjs",
    "p22-database-proof.test.mjs",
    "run-linux-matrix-harness.test.mjs",
    "run-product-requirement-validator.test.mjs",
  ]) {
    const input = valid();
    input.pr = input.pr.replace(marker, "removed");
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test("product evidence producer identity and immutable artifact wiring fail closed independently", () => {
  for (const marker of [
    "id-token: write",
    "ref: ${{ github.sha }}",
    '--run-id "$CANDIDATE_RUN_ID"',
    '--target-head "$TARGET_HEAD"',
    "artifact-ids: ${{ steps.evidence.outputs.artifact_id }}",
    "id: p02_capture",
    'mktemp -d "${RUNNER_TEMP}/openburnbar-p02.XXXXXX"',
    'printf \'diagnostic_root=%s\\n\' "$diagnostic_root" >> "$GITHUB_OUTPUT"',
    '--diagnostic-root "$diagnostic_root"',
    "${{ steps.p02_capture.outputs.diagnostic_root }}/",
    "capture-failure.json",
    "capture.log",
    '2>&1 | tee "$capture_log"',
    "finalize-product-feature-proof-closure.mjs",
    "uses: actions/attest@",
    ".sigstore.jsonl",
    "include-hidden-files: true",
  ]) {
    const input = valid();
    input.productParityWorkflow = input.productParityWorkflow.replaceAll(
      marker,
      "removed",
    );
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test("free-form candidate run input cannot be interpolated directly into shell", () => {
  const input = valid();
  input.productParityWorkflow += "\n--run-id '${{ inputs.candidate_run_id }}'";
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.match(
    result.failures.join("\n"),
    /candidate_run_id directly into shell/u,
  );
});

test("promotion must generate current-HEAD attestations before strict parity validation", () => {
  const missing = valid();
  missing.promotionWorkflow = missing.promotionWorkflow.replace(
    'attest-product-requirement.mjs --requirement "P-${number}"',
    "removed",
  );
  assert.equal(verifyLinuxWorkflowWiring(missing).passed, false);

  const reordered = valid();
  reordered.promotionWorkflow = reordered.promotionWorkflow.replace(
    "Generate current-HEAD product parity attestations\nVerify strict product parity at promotion HEAD",
    "Verify strict product parity at promotion HEAD\nGenerate current-HEAD product parity attestations",
  );
  assert.equal(verifyLinuxWorkflowWiring(reordered).passed, false);
});

test("promotion cannot create its unignored candidate scratch tree before clean-HEAD attestation", () => {
  const input = valid();
  input.promotionWorkflow = input.promotionWorkflow.replace(
    "Generate current-HEAD product parity attestations\nVerify strict product parity at promotion HEAD\nDownload the exact candidate",
    "Download the exact candidate\nGenerate current-HEAD product parity attestations\nVerify strict product parity at promotion HEAD",
  );
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(
    result.failures.some((failure) =>
      /Download the exact candidate/u.test(failure),
    ),
  );
});

test("candidate workflow cannot attest parity or publish", () => {
  for (const forbidden of [
    "attest-product-requirement.mjs",
    "validate-parity-ledger.mjs",
    "gh release create",
  ]) {
    const input = valid();
    input.release += `\n${forbidden}`;
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, forbidden);
  }
});

test("removing any native behavior or process-isolation command fails", () => {
  for (const marker of [
    "CoreFoundationTests",
    "LinuxSecurityTests",
    "LinuxGatewayTests",
    "timeout 900",
    "run_xctest_case",
    "Executed 1 test",
    "cargo test",
  ]) {
    const input = valid();
    input.nativeTests = input.nativeTests
      .split("\n")
      .filter((line) => !line.includes(marker))
      .join("\n");
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test("legacy tag, swallowed verifier, and sealed evidence paths fail", () => {
  const input = valid();
  input.release = input.release.replace('- "linux-v*"', '- "v*"');
  input.makefile = "release-linux:\n\tnode verify || true\n\nother:";
  input.pr += "\nmission-001-release";
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /legacy v/.test(failure)));
  assert.ok(result.failures.some((failure) => /swallow/.test(failure)));
  assert.ok(result.failures.some((failure) => /sealed mission/.test(failure)));
});

test("promotion publication cannot omit source, closure bundle, or public key", () => {
  for (const marker of [
    "*source-*.tar",
    "promotion-closure.json.sigstore.jsonl",
  ]) {
    const input = valid();
    input.promotionWorkflow = input.promotionWorkflow.replace(marker, "");
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
  const input = valid();
  input.promotionWorkflow +=
    '\ncp packaging/linux/openburnbar-linux-ed25519.pub.pem "$art/" || true';
  assert.equal(verifyLinuxWorkflowWiring(input).passed, false);
});

test("candidate architecture closure and promotion publication cannot be removed", () => {
  for (const marker of [
    "architecture: aarch64",
    "architecture: x86_64",
    "--architecture-shard",
    "linux-desktop-session.sh",
    "verify-linux-package-update-rollback.sh",
    "verify-arch-package-update-rollback.mjs",
    "finalize-linux-architecture-session.mjs",
    "assemble-linux-release.mjs",
    "list-linux-release-attestation-subjects.mjs",
    "--phase prepare",
    "--network none",
    "--read-only",
    "--cap-drop ALL",
    "--security-opt no-new-privileges",
    "sign-linux-release-requests.mjs",
    "--phase finalize",
    "arch_signature_pattern",
    '--previous-installed-manifest "/workspace/',
    "source=$PWD,target=/workspace,readonly",
    "source=$PWD/.linux-shard/session,target=/workspace/.linux-shard/session",
    "merge-multiple: false",
  ]) {
    const input = valid();
    input.release = input.release.replace(marker, "");
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
  for (const marker of [
    "OPENBURNBAR_R2_CUSTOM_DOMAIN: downloads.burnbar.ai",
    "upload-linux-downloads-r2.sh",
    "https://downloads.burnbar.ai/latest-linux.json",
  ]) {
    const input = valid();
    input.promotionWorkflow = input.promotionWorkflow.replace(marker, "");
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test("package lifecycle finalizer regression suite cannot be removed", () => {
  const input = valid();
  input.pr = input.pr.replace("linux-package-session.test.mjs", "");
  assert.equal(verifyLinuxWorkflowWiring(input).passed, false);
});

test("each Browser Computer Use package-family suite is independently required", () => {
  for (const marker of [
    "scripts/linux-port/browser-runtime-packaging.test.mjs",
    "scripts/linux-port/aur-browser-runtime-packaging.test.mjs",
    "scripts/linux-port/embed-linux-appimage-payload.test.mjs",
  ]) {
    const input = valid();
    input.pr = input.pr.replace(marker, "");
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test("hidden Linux evidence upload cannot be disabled", () => {
  const input = valid();
  input.pr = input.pr.replace(
    "include-hidden-files: true",
    "include-hidden-files: false",
  );
  assert.equal(verifyLinuxWorkflowWiring(input).passed, false);
});
test("attestation and publish order drift fails", () => {
  const input = valid();
  input.release = input.release.replace(
    "Pre-attestation Linux release verification\nAttest Linux release sidecars and packages",
    "Attest Linux release sidecars and packages\nPre-attestation Linux release verification",
  );
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /out of order/.test(failure)));
});

test("gateway bearer exposure or native boundary removal fails", () => {
  for (const forbidden of [
    "gatewayAuthToken",
    "bearerToken",
    "Authorization",
  ]) {
    const input = valid();
    input.rendererBridge += `\n${forbidden}`;
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, forbidden);
  }
  const exposed = valid();
  exposed.rustBridge +=
    "\n#[tauri::command]\nfn gateway_auth_token() -> Option<String> { None }";
  assert.equal(verifyLinuxWorkflowWiring(exposed).passed, false);

  const missingProxy = valid();
  missingProxy.rustBridge = missingProxy.rustBridge.replace(
    "gateway_chat_stream",
    "",
  );
  assert.equal(verifyLinuxWorkflowWiring(missingProxy).passed, false);
});

test("generic shell, renderer network, and production fixture activation drift fail", () => {
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
    "enabled && DAEMON_FIXTURE_AVAILABLE",
    "enabled",
  );
  assert.equal(verifyLinuxWorkflowWiring(unguardedFixture).passed, false);

  const ambientPathCommand = valid();
  ambientPathCommand.rustBridge += '\nCommand::new("openburnbar-cli")';
  assert.equal(verifyLinuxWorkflowWiring(ambientPathCommand).passed, false);
});

test("runtime capability catalog, evaluator, bridge, route, and boundary drift fail", () => {
  for (const [field, marker] of [
    ["rustBridge", "runtime_capabilities"],
    ["rendererBridge", "decodeRuntimeCapabilityManifest"],
    ["routes", "requiredCapability"],
    ["surfaceBoundary", "capabilityBlocksSurface"],
    ["runtimeCatalog", '"schemaVersion": 1'],
    ["runtimeSchema", '"additionalProperties": false'],
  ]) {
    const input = valid();
    input[field] = input[field].replace(marker, "");
    assert.equal(
      verifyLinuxWorkflowWiring(input).passed,
      false,
      `${field}:${marker}`,
    );
  }
});

test("signed update verification and navigation boundaries cannot be removed", () => {
  for (const [field, marker] of [
    ["updateFeed", "PINNED_PUBLIC_KEY_SPKI_SHA256"],
    ["updateFeed", "verify_strict"],
    ["updateFeed", "validate_update_artifact_url"],
    ["rendererBridge", "invoke<RawJsonValue>('update_status')"],
    ["rendererBridge", "invoke<void>('open_update_url'"],
  ]) {
    const input = valid();
    input[field] = input[field].replace(marker, "");
    assert.equal(
      verifyLinuxWorkflowWiring(input).passed,
      false,
      `${field}:${marker}`,
    );
  }
});

test("removing PR or nightly matched performance wiring fails", () => {
  for (const [field, marker] of [
    ["pr", "--profile pr"],
    ["pr", "matched-performance-contract.test.mjs"],
    ["nightly", "--profile nightly"],
    ["nightly", "OB_MATCHED_LINUX_INPUT"],
  ]) {
    const input = valid();
    input[field] = input[field].replace(marker, "");
    assert.equal(
      verifyLinuxWorkflowWiring(input).passed,
      false,
      `${field}:${marker}`,
    );
  }
});

test("nightly macOS evidence upload retries once and fails closed without an artifact", () => {
  for (const marker of [
    "id: upload-macos-performance-primary",
    "continue-on-error: true",
    "if: steps.upload-macos-performance-primary.outcome != 'success'",
    "name: linux-parity-macos-performance-nightly-retry-${{ github.run_id }}",
    "id: select-macos-performance-artifact",
    "if: always()",
    'if [[ "$RETRY_OUTCOME" == "success" ]]',
    'echo "artifact_name=$RETRY_NAME" >> "$GITHUB_OUTPUT"',
    "Neither macOS matched-performance artifact upload succeeded.",
    "name: ${{ needs.macos-matched-performance.outputs.macos_artifact_name }}",
  ]) {
    const input = valid();
    input.nightly = input.nightly.replace(marker, "");
    assert.equal(verifyLinuxWorkflowWiring(input).passed, false, marker);
  }
});

test("Linux Swift evidence must route through the host-mounted evidence tree", () => {
  const marker =
    "OPENBURNBAR_LINUX_SWIFT_TEST_RESULTS=/evidence/linux-swift-tests";
  for (const field of ["pr", "nightly"]) {
    const input = valid();
    input[field] = input[field].replace(marker, "");
    const result = verifyLinuxWorkflowWiring(input);
    assert.equal(result.passed, false, field);
    assert.ok(
      result.failures.some((failure) =>
        failure.includes("Linux Swift evidence routing"),
      ),
      field,
    );
  }
});

test("removing the TypeScript typecheck gate from the PR workflow fails", () => {
  const input = valid();
  input.pr = input.pr.replace(
    "npm run typecheck --prefix apps/linux-desktop",
    "",
  );
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(
    result.failures.some((f) => f.includes("TypeScript typecheck gate")),
  );
});

test("TypeScript typecheck gate may not continue on error", () => {
  const input = valid();
  input.pr = input.pr.replace(
    "npm run typecheck --prefix apps/linux-desktop",
    "- name: Linux desktop TypeScript typecheck\n        run: npm run typecheck --prefix apps/linux-desktop\n        continue-on-error: true",
  );
  const result = verifyLinuxWorkflowWiring(input);
  assert.equal(result.passed, false);
  assert.ok(
    result.failures.some((f) =>
      f.includes("typecheck gate may not continue on error"),
    ),
  );
});
