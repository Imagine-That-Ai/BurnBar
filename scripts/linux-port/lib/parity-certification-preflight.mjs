import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import { parse as parseYaml } from 'yaml';
import { RELEASE_PROOF_ROLES } from '../prepare-product-requirement-input.mjs';
import {
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
  validateAggregateDocument,
  validateRecord
} from './product-proof-closure.mjs';
import {
  MAX_FEATURE_PROOF_ARTIFACT_BYTES,
  MAX_FEATURE_PROOF_CONTRACT_BYTES
} from './product-feature-proof.mjs';
import {
  validatePolicyManifest,
  validateRequirementsManifest
} from './product-requirement-attestation.mjs';

export const PARITY_PREFLIGHT_SCHEMA_PATH = 'schemas/linux-parity-certification-preflight.schema.json';
export const PARITY_PREFLIGHT_ROLE = 'feature.parity-certification-preflight';
export const PARITY_PREFLIGHT_FILENAME = 'parity-certification-preflight.json';
export const REQUIREMENT_IDS = Object.freeze(
  Array.from({ length: 40 }, (_, index) => `P-${String(index + 1).padStart(2, '0')}`)
);

const REQUIREMENTS_PATH = 'docs/linux-port/product-parity-requirements.json';
const POLICIES_PATH = 'docs/linux-port/product-parity-evidence-policies.json';
const REGISTRY_PATH = 'docs/linux-port/product-feature-proof-registry.json';
const VALIDATOR_ROOT = 'scripts/linux-port/product-validators';
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const HEAD = /^[a-f0-9]{40,64}$/u;
const COMMAND_TIMEOUT_MS = 30_000;
const OWNERSHIP_TEST_TIMEOUT_MS = 120_000;
const COMMIT_SNAPSHOT_CACHE = new Map();
const MODULE_DEPENDENCY_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../node_modules'
);
const ISOLATED_TARGET_PATHS = Object.freeze([
  '.github/workflows',
  'Makefile',
  'OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js',
  'OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/LinuxSecretStorage.swift',
  'OpenBurnBarCore/Tests/OpenBurnBarComputerUseCoreTests/LinuxSecretStorageTests.swift',
  'apps/linux-desktop/package.json',
  'apps/linux-desktop/src',
  'apps/linux-desktop/src-tauri/capabilities/default.json',
  'apps/linux-desktop/src-tauri/icons/icon.png',
  'apps/linux-desktop/src-tauri/src',
  'apps/linux-desktop/src-tauri/tauri.conf.json',
  'contracts/provider-ingestion-catalog.json',
  'docs/linux-port/cloud-security-runbook.md',
  'docs/linux-port/product-feature-proof-registry.json',
  'docs/linux-port/product-parity-evidence-policies.json',
  'docs/linux-port/product-parity-requirements.json',
  'packaging/linux',
  'schemas',
  'scripts/linux-port'
]);
const CANONICAL_WORKFLOW_OWNERSHIP = Object.freeze({
  'scripts/linux-port/capture-p05-credential-custody-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-05 installed credential custody proof',
    condition: "inputs.requirement == 'P-05'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p05.XXXXXX")"',
      'trap \'rm -rf "$evidence_root"\' EXIT',
      'node scripts/linux-port/run-p05-credential-custody-session.mjs \\',
      '  --output-root "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256"',
      'install -m 600 "$evidence_root/p05-installed-custody-session.json" \\',
      '  "$input_root/p05-installed-custody-session.json"',
      'node scripts/linux-port/capture-p05-credential-custody-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p05-installed-custody-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p06-gateway-boundary-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-06 installed gateway credential boundary proof',
    condition: "inputs.requirement == 'P-06'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p06.XXXXXX")"',
      'desktop_pid=""',
      'cleanup_p06() {',
      '  if test -n "$desktop_pid"; then kill "$desktop_pid" 2>/dev/null || true; fi',
      '  rm -rf "$evidence_root"',
      '}',
      'trap cleanup_p06 EXIT',
      'systemctl --user restart openburnbar-daemon.service',
      '/usr/bin/openburnbar-linux-desktop --background >"$evidence_root/desktop.log" 2>&1 &',
      'desktop_pid=$!',
      'token_file="${XDG_DATA_HOME:-$HOME/.local/share}/openburnbar/daemon-socket-auth-token"',
      'for _ in $(seq 1 60); do',
      '  test -s "$token_file" && pgrep -f \'WebKit(Web|Network)Process\' >/dev/null && break',
      '  sleep 0.5',
      'done',
      'test -s "$token_file"',
      'node scripts/linux-port/run-p06-gateway-boundary-session.mjs \\',
      '  --token-file "$token_file" \\',
      '  --output-root "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256"',
      'install -m 600 "$evidence_root/p06-gateway-boundary-session.json" \\',
      '  "$input_root/p06-gateway-boundary-session.json"',
      'node scripts/linux-port/capture-p06-gateway-boundary-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p06-gateway-boundary-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p07-computer-use-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-07 candidate-bound computer-use proof',
    condition: "inputs.requirement == 'P-07'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'session_report="$input_root/p07-live-session.json"',
      'test -f "$session_report"',
      'node scripts/linux-port/capture-p07-computer-use-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$session_report" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p08-mercury-media-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-08 installed Mercury media proof',
    condition: "inputs.requirement == 'P-08'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'desktop_report="$input_root/p08-linux-desktop-observation.json"',
      'device_report="$input_root/p08-physical-device-observation.json"',
      'test -f "$desktop_report"',
      'test -f "$device_report"',
      'chmod 700 "$input_root"',
      'node scripts/linux-port/run-p08-mercury-media-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
      'node scripts/linux-port/capture-p08-mercury-media-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p08-installed-mercury-media-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p09-navigation-shell-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-09 installed navigation shell proof',
    condition: "inputs.requirement == 'P-09'",
    run: "set -euo pipefail\ninput_root=\"docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}\"\nevidence_root=\"$(mktemp -d \"${RUNNER_TEMP}/openburnbar-p09.XXXXXX\")\"\ntrap 'rm -rf \"$evidence_root\"' EXIT\ncase \"$ENVIRONMENT_ID\" in\n  *-gnome-*) compositor=Mutter ;;\n  *-kde-*) compositor=KWin ;;\n  *-sway-*) compositor=Sway ;;\n  *) echo \"unsupported P-09 compositor environment: $ENVIRONMENT_ID\" >&2; exit 1 ;;\nesac\nnode scripts/linux-port/run-p09-native-navigation-probes.mjs \\\n  --output-dir \"$evidence_root\" \\\n  --environment \"$ENVIRONMENT_ID\" \\\n  --target-head \"$TARGET_HEAD\" \\\n  --candidate-run-id \"$CANDIDATE_RUN_ID\" \\\n  --candidate-artifact-digest \"$CANDIDATE_ARTIFACT_DIGEST\" \\\n  --package-version \"$PACKAGE_VERSION\" \\\n  --manifest-sha256 \"$MANIFEST_SHA256\" \\\n  --manifest-signature-sha256 \"$MANIFEST_SIGNATURE_SHA256\" \\\n  --compositor \"$compositor\"\nnode scripts/linux-port/materialize-p09-navigation-shell-session.mjs \\\n  --output-root \"$input_root\" \\\n  --shell-evidence-dir \"$evidence_root\" \\\n  --environment \"$ENVIRONMENT_ID\" \\\n  --target-head \"$TARGET_HEAD\" \\\n  --candidate-run-id \"$CANDIDATE_RUN_ID\" \\\n  --candidate-artifact-digest \"$CANDIDATE_ARTIFACT_DIGEST\" \\\n  --package-version \"$PACKAGE_VERSION\" \\\n  --manifest-sha256 \"$MANIFEST_SHA256\" \\\n  --manifest-signature-sha256 \"$MANIFEST_SIGNATURE_SHA256\" \\\n  --compositor \"$compositor\"\nnode scripts/linux-port/capture-p09-navigation-shell-proof.mjs \\\n  --input-root \"$input_root\" \\\n  --session-report \"$input_root/p09-installed-navigation-shell-session.json\" \\\n  --environment \"$ENVIRONMENT_ID\" \\\n  --target-head \"$TARGET_HEAD\" \\\n  --candidate-run-id \"$CANDIDATE_RUN_ID\" \\\n  --candidate-artifact-digest \"$CANDIDATE_ARTIFACT_DIGEST\" \\\n  --package-version \"$PACKAGE_VERSION\" \\\n  --manifest-sha256 \"$MANIFEST_SHA256\" \\\n  --manifest-signature-sha256 \"$MANIFEST_SIGNATURE_SHA256\"\n"
  },
  'scripts/linux-port/capture-p10-dashboard-layout-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-10 installed dashboard layout proof',
    condition: "inputs.requirement == 'P-10'",
    run: "set -euo pipefail\ninput_root=\"docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}\"\nevidence_root=\"$(mktemp -d \"${RUNNER_TEMP}/openburnbar-p10.XXXXXX\")\"\ntrap 'rm -rf \"$evidence_root\"' EXIT\ncase \"$ENVIRONMENT_ID\" in\n  *-gnome-*) compositor=Mutter ;;\n  *-kde-*) compositor=KWin ;;\n  *-sway-*) compositor=Sway ;;\n  *) echo \"unsupported P-10 compositor environment: $ENVIRONMENT_ID\" >&2; exit 1 ;;\nesac\nrender_backend=webkitgtk-installed-dashboard\nnode scripts/linux-port/run-p10-native-dashboard-probes.mjs \\\n  --output-dir \"$evidence_root\" \\\n  --environment \"$ENVIRONMENT_ID\" \\\n  --target-head \"$TARGET_HEAD\" \\\n  --candidate-run-id \"$CANDIDATE_RUN_ID\" \\\n  --candidate-artifact-digest \"$CANDIDATE_ARTIFACT_DIGEST\" \\\n  --package-version \"$PACKAGE_VERSION\" \\\n  --manifest-sha256 \"$MANIFEST_SHA256\" \\\n  --manifest-signature-sha256 \"$MANIFEST_SIGNATURE_SHA256\" \\\n  --compositor \"$compositor\" \\\n  --render-backend \"$render_backend\"\nnode scripts/linux-port/materialize-p10-dashboard-layout-session.mjs \\\n  --output-root \"$input_root\" \\\n  --raw-evidence-dir \"$evidence_root\" \\\n  --environment \"$ENVIRONMENT_ID\" \\\n  --target-head \"$TARGET_HEAD\" \\\n  --candidate-run-id \"$CANDIDATE_RUN_ID\" \\\n  --candidate-artifact-digest \"$CANDIDATE_ARTIFACT_DIGEST\" \\\n  --package-version \"$PACKAGE_VERSION\" \\\n  --manifest-sha256 \"$MANIFEST_SHA256\" \\\n  --manifest-signature-sha256 \"$MANIFEST_SIGNATURE_SHA256\" \\\n  --compositor \"$compositor\" \\\n  --render-backend \"$render_backend\"\nnode scripts/linux-port/capture-p10-dashboard-layout-proof.mjs \\\n  --input-root \"$input_root\" \\\n  --session-report \"$input_root/p10-installed-dashboard-layout-session.json\" \\\n  --environment \"$ENVIRONMENT_ID\" \\\n  --target-head \"$TARGET_HEAD\" \\\n  --candidate-run-id \"$CANDIDATE_RUN_ID\" \\\n  --candidate-artifact-digest \"$CANDIDATE_ARTIFACT_DIGEST\" \\\n  --package-version \"$PACKAGE_VERSION\" \\\n  --manifest-sha256 \"$MANIFEST_SHA256\" \\\n  --manifest-signature-sha256 \"$MANIFEST_SIGNATURE_SHA256\"\n"
  },
  'scripts/linux-port/capture-p11-usage-ingestion-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-11 installed usage ingestion proof',
    condition: "inputs.requirement == 'P-11'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p11-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p11-support.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'cleanup() {',
      '  status=$?',
      '  systemctl --user unset-environment OPENBURNBAR_DAEMON_SUPPORT_DIR OPENBURNBAR_DAEMON_SOCKET_PATH || status=1',
      '  systemctl --user restart openburnbar-daemon.service || status=1',
      '  rm -rf "$evidence_root" "$support_root" || status=1',
      '  exit "$status"',
      '}',
      'trap cleanup EXIT',
      'chmod 700 "$evidence_root" "$support_root"',
      'case "$ENVIRONMENT_ID" in',
      '  *-gnome-*) compositor=Mutter ;;',
      '  *-kde-*) compositor=KWin ;;',
      '  *-sway-*) compositor=Sway ;;',
      '  *) echo "unsupported P-11 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac',
      'systemctl --user set-environment \\',
      '  "OPENBURNBAR_DAEMON_SUPPORT_DIR=$support_root" \\',
      '  "OPENBURNBAR_DAEMON_SOCKET_PATH=$socket_path"',
      'systemctl --user restart openburnbar-daemon.service',
      'for _ in $(seq 1 100); do',
      '  if [[ -S "$socket_path" && -s "$token_file" ]]; then break; fi',
      '  sleep 0.1',
      'done',
      'test -S "$socket_path"',
      'test -s "$token_file"',
      'test ! -e "$support_root/usage-events.jsonl"',
      'node scripts/linux-port/run-p11-usage-ingestion-session.mjs \\',
      '  --raw-output-dir "$evidence_root" \\',
      '  --ledger-path "$support_root/usage-events.jsonl" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
      'node scripts/linux-port/materialize-p11-usage-ingestion-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/capture-p11-usage-ingestion-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p11-installed-usage-ingestion-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p12-quota-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-12 installed quota proof',
    condition: "inputs.requirement == 'P-12'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p12-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p12-support.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'gateway_token_file="$support_root/gateway-auth-token"',
      'original_environment="$support_root/original-systemd-environment"',
      'gateway_variables=(OPENBURNBAR_GATEWAY_ENABLED OPENBURNBAR_GATEWAY_HOST OPENBURNBAR_GATEWAY_PORT OPENBURNBAR_GATEWAY_AUTH_TOKEN)',
      'managed_variables=(OPENBURNBAR_DAEMON_SUPPORT_DIR OPENBURNBAR_DAEMON_SOCKET_PATH "${gateway_variables[@]}")',
      'if systemctl --user is-active --quiet openburnbar-daemon.service; then service_was_active=1; else service_was_active=0; fi',
      'systemctl --user show-environment >"$original_environment"',
      'chmod 600 "$original_environment"',
      'restore_manager_environment() {',
      '  systemctl --user unset-environment "${managed_variables[@]}"',
      '  while IFS= read -r entry; do',
      '    for variable in "${managed_variables[@]}"; do',
      '      if [[ "$entry" == "$variable="* ]]; then systemctl --user set-environment "$entry"; fi',
      '    done',
      '  done <"$original_environment"',
      '}',
      'cleanup() {',
      '  status=$?',
      '  restore_manager_environment || status=1',
      '  if [[ "$service_was_active" == 1 ]]; then',
      '    systemctl --user restart openburnbar-daemon.service || status=1',
      '  else',
      '    systemctl --user stop openburnbar-daemon.service || status=1',
      '  fi',
      '  rm -rf "$evidence_root" "$support_root" || status=1',
      '  exit "$status"',
      '}',
      'trap cleanup EXIT',
      'chmod 700 "$evidence_root" "$support_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/bin/openburnbar-daemon',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-12 requires no pre-existing installed desktop process" >&2',
      '  exit 1',
      'fi',
      'case "$ENVIRONMENT_ID" in',
      '  *-gnome-*) compositor=Mutter ;;',
      '  *-kde-*) compositor=KWin ;;',
      '  *-sway-*) compositor=Sway ;;',
      '  *) echo "unsupported P-12 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac',
      'umask 077',
      'openssl rand -hex 32 >"$gateway_token_file"',
      'chmod 600 "$gateway_token_file"',
      'gateway_port="$(python3 -c \'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); p=s.getsockname()[1]; s.close(); assert 1024 <= p <= 65535; print(p)\')"',
      '[[ "$gateway_port" =~ ^[0-9]+$ ]]',
      '(( gateway_port >= 1024 && gateway_port <= 65535 ))',
      'gateway_token="$(<"$gateway_token_file")"',
      '[[ ${#gateway_token} -ge 32 ]]',
      'export OPENBURNBAR_DAEMON_SUPPORT_DIR="$support_root"',
      'export OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path"',
      'systemctl --user set-environment \\',
      '  "OPENBURNBAR_DAEMON_SUPPORT_DIR=$support_root" \\',
      '  "OPENBURNBAR_DAEMON_SOCKET_PATH=$socket_path" \\',
      '  OPENBURNBAR_GATEWAY_ENABLED=1 \\',
      '  OPENBURNBAR_GATEWAY_HOST=127.0.0.1 \\',
      '  "OPENBURNBAR_GATEWAY_PORT=$gateway_port" \\',
      '  "OPENBURNBAR_GATEWAY_AUTH_TOKEN=$gateway_token"',
      'systemctl --user restart openburnbar-daemon.service',
      'for _ in $(seq 1 100); do',
      '  if [[ -S "$socket_path" && -s "$token_file" ]]; then break; fi',
      '  sleep 0.1',
      'done',
      'test -S "$socket_path"',
      'test -s "$token_file"',
      'test ! -e "$support_root/quota-signals.jsonl"',
      'node scripts/linux-port/run-p12-native-quota-probes.mjs \\',
      '  --output-dir "$evidence_root" \\',
      '  --support-dir "$support_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --gateway-token-file "$gateway_token_file" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/materialize-p12-quota-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/capture-p12-quota-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p12-installed-quota-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p17-activity-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-17 installed Activity proof',
    condition: "inputs.requirement == 'P-17'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-home.XXXXXX")"',
      'download_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p17-downloads.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'index_database="$support_root/openburnbar-index.sqlite"',
      'cleanup() {',
      '  status=$?',
      '  rm -rf "$evidence_root" "$support_root" "$home_root" "$download_root" || status=1',
      '  exit "$status"',
      '}',
      'trap cleanup EXIT',
      'chmod 700 "$evidence_root" "$support_root" "$home_root" "$download_root"',
      'test -x /usr/bin/openburnbar-cli',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/libexec/openburnbar-daemon-launch',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-17 requires no pre-existing installed desktop process" >&2',
      '  exit 1',
      'fi',
      'case "$ENVIRONMENT_ID" in',
      '  *-gnome-*) compositor=Mutter ;;',
      '  *-kde-*) compositor=KWin ;;',
      '  *-sway-*) compositor=Sway ;;',
      '  *) echo "unsupported P-17 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac',
      'umask 077',
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      'node scripts/linux-port/run-p17-native-activity-probes.mjs \\',
      '  --raw-output-dir "$evidence_root" \\',
      '  --support-dir "$support_root" \\',
      '  --home-dir "$home_root" \\',
      '  --download-dir "$download_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --index-database "$index_database" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/materialize-p17-activity-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/capture-p17-activity-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p17-installed-activity-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  "scripts/linux-port/capture-p18-memory-review-proof.mjs": {
    workflow: ".github/workflows/linux-product-parity.yml",
    job: "validate",
    step: "Capture P-18 installed memory-review proof",
    condition: "inputs.requirement == 'P-18'",
    run: [
      "set -euo pipefail",
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p18-home.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'index_database="$support_root/openburnbar-index.sqlite"',
      "cleanup() {",
      "  status=$?",
      '  rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      '  exit "$status"',
      "}",
      "trap cleanup EXIT",
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-18 requires no pre-existing installed desktop process" >&2',
      "  exit 1",
      "fi",
      'case "$ENVIRONMENT_ID" in',
      "  *-gnome-*) compositor=Mutter ;;",
      "  *-kde-*) compositor=KWin ;;",
      "  *-sway-*) compositor=Sway ;;",
      '  *) echo "unsupported P-18 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      "esac",
      "umask 077",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      "node scripts/linux-port/run-p18-native-memory-probes.mjs \\",
      '  --raw-output-dir "$evidence_root" \\',
      '  --support-dir "$support_root" \\',
      '  --home-dir "$home_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --index-database "$index_database" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      "node scripts/linux-port/materialize-p18-memory-review-session.mjs \\",
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      "node scripts/linux-port/capture-p18-memory-review-proof.mjs \\",
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p18-installed-memory-review-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
    ].join("\n"),
  },
  "scripts/linux-port/capture-p19-projects-proof.mjs": {
    workflow: ".github/workflows/linux-product-parity.yml",
    job: "validate",
    step: "Capture P-19 installed Projects proof",
    condition: "inputs.requirement == 'P-19'",
    run: [
      "set -euo pipefail",
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p19-home.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'index_database="$support_root/openburnbar-index.sqlite"',
      "cleanup() {",
      "  status=$?",
      '  rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      '  exit "$status"',
      "}",
      "trap cleanup EXIT",
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-19 requires no pre-existing installed desktop process" >&2',
      "  exit 1",
      "fi",
      'case "$ENVIRONMENT_ID" in',
      "  *-gnome-*) compositor=Mutter ;;",
      "  *-kde-*) compositor=KWin ;;",
      "  *-sway-*) compositor=Sway ;;",
      '  *) echo "unsupported P-19 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      "esac",
      "umask 077",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      "node scripts/linux-port/run-p19-native-projects-probes.mjs \\",
      '  --raw-output-dir "$evidence_root" \\',
      '  --support-dir "$support_root" \\',
      '  --home-dir "$home_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --index-database "$index_database" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      "node scripts/linux-port/materialize-p19-projects-session.mjs \\",
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      "node scripts/linux-port/capture-p19-projects-proof.mjs \\",
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p19-installed-projects-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
    ].join("\n"),
  },
  "scripts/linux-port/capture-p20-missions-proof.mjs": {
    workflow: ".github/workflows/linux-product-parity.yml",
    job: "validate",
    step: "Capture P-20 installed Missions proof",
    condition: "inputs.requirement == 'P-20'",
    run: [
      "set -euo pipefail",
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p20-home.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'index_database="$support_root/openburnbar-index.sqlite"',
      "cleanup() {",
      "  status=$?",
      '  rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      '  exit "$status"',
      "}",
      "trap cleanup EXIT",
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-20 requires no pre-existing installed desktop process" >&2',
      "  exit 1",
      "fi",
      'case "$ENVIRONMENT_ID" in',
      "  *-gnome-*) compositor=Mutter ;;",
      "  *-kde-*) compositor=KWin ;;",
      "  *-sway-*) compositor=Sway ;;",
      '  *) echo "unsupported P-20 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      "esac",
      "umask 077",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      "node scripts/linux-port/run-p20-native-missions-probes.mjs \\",
      '  --raw-output-dir "$evidence_root" \\',
      '  --support-dir "$support_root" \\',
      '  --home-dir "$home_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --index-database "$index_database" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      "node scripts/linux-port/materialize-p20-missions-session.mjs \\",
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      "node scripts/linux-port/capture-p20-missions-proof.mjs \\",
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p20-installed-missions-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
    ].join("\n"),
  },
  "scripts/linux-port/capture-p21-insights-proof.mjs": {
    workflow: ".github/workflows/linux-product-parity.yml",
    job: "validate",
    step: "Capture P-21 installed Insights proof",
    condition: "inputs.requirement == 'P-21'",
    run: [
      "set -euo pipefail",
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p21-home.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'index_database="$support_root/openburnbar-index.sqlite"',
      "cleanup() {",
      "  status=$?",
      '  rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      '  exit "$status"',
      "}",
      "trap cleanup EXIT",
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-21 requires no pre-existing installed desktop process" >&2',
      "  exit 1",
      "fi",
      'case "$ENVIRONMENT_ID" in',
      "  *-gnome-*) compositor=Mutter ;;",
      "  *-kde-*) compositor=KWin ;;",
      "  *-sway-*) compositor=Sway ;;",
      '  *) echo "unsupported P-21 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      "esac",
      "umask 077",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      "node scripts/linux-port/run-p21-native-insights-probes.mjs \\",
      '  --raw-output-dir "$evidence_root" \\',
      '  --support-dir "$support_root" \\',
      '  --home-dir "$home_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --index-database "$index_database" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      "node scripts/linux-port/materialize-p21-insights-session.mjs \\",
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      "node scripts/linux-port/capture-p21-insights-proof.mjs \\",
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p21-installed-insights-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
    ].join("\n"),
  },
  "scripts/linux-port/capture-p22-database-proof.mjs": {
    workflow: ".github/workflows/linux-product-parity.yml",
    job: "validate",
    step: "Capture P-22 installed Database proof",
    condition: "inputs.requirement == 'P-22'",
    run: [
      "set -euo pipefail",
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p22-home.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'index_database="$support_root/openburnbar-index.sqlite"',
      "cleanup() {",
      "  status=$?",
      '  rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      '  exit "$status"',
      "}",
      "trap cleanup EXIT",
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-22 requires no pre-existing installed desktop process" >&2',
      "  exit 1",
      "fi",
      'case "$ENVIRONMENT_ID" in',
      "  *-gnome-*) compositor=Mutter ;;",
      "  *-kde-*) compositor=KWin ;;",
      "  *-sway-*) compositor=Sway ;;",
      '  *) echo "unsupported P-22 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      "esac",
      "umask 077",
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      "node scripts/linux-port/run-p22-native-database-probes.mjs \\",
      '  --raw-output-dir "$evidence_root" \\',
      '  --support-dir "$support_root" \\',
      '  --home-dir "$home_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --index-database "$index_database" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      "node scripts/linux-port/materialize-p22-database-session.mjs \\",
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      "node scripts/linux-port/capture-p22-database-proof.mjs \\",
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p22-installed-database-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
    ].join("\n"),
  },
  'scripts/linux-port/capture-p23-provider-workspace-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-23 installed Provider workspace proof',
    condition: "inputs.requirement == 'P-23'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p23-evidence.XXXXXX")"',
      'socket_path="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}/openburnbar/daemon.sock"',
      'token_file="${XDG_DATA_HOME:-$HOME/.local/share}/openburnbar/daemon-socket-auth-token"',
      'cleanup() {',
      '  status=$?',
      '  rm -rf "$evidence_root" || status=1',
      '  exit "$status"',
      '}',
      'trap cleanup EXIT',
      'chmod 700 "$evidence_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/bin/openburnbar-daemon',
      'test -S "$socket_path"',
      'test -s "$token_file"',
      'systemctl --user is-active --quiet openburnbar-daemon.service',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-23 requires no pre-existing installed desktop process" >&2',
      '  exit 1',
      'fi',
      'case "$ENVIRONMENT_ID" in',
      '  *-gnome-*) compositor=Mutter ;;',
      '  *-kde-*) compositor=KWin ;;',
      '  *-sway-*) compositor=Sway ;;',
      '  *) echo "unsupported P-23 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac',
      'umask 077',
      'node scripts/linux-port/run-p23-native-provider-workspace-probes.mjs \\',
      '  --raw-output-dir "$evidence_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/materialize-p23-provider-workspace-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/capture-p23-provider-workspace-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p23-installed-provider-workspace-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p25-updates-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-25 installed Updates proof',
    condition: "inputs.requirement == 'P-25'",
    run: 'bash scripts/linux-port/run-p25-installed-update-proof-workflow.sh'
  },
  'scripts/linux-port/capture-p24-settings-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-24 installed Settings proof',
    condition: "inputs.requirement == 'P-24'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p24-home.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'index_database="$support_root/openburnbar-index.sqlite"',
      'cleanup() {',
      '  status=$?',
      '  rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      '  exit "$status"',
      '}',
      'trap cleanup EXIT',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/libexec/openburnbar-daemon-launch',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-24 requires no pre-existing installed desktop process" >&2',
      '  exit 1',
      'fi',
      'case "$ENVIRONMENT_ID" in',
      '  *-gnome-*) compositor=Mutter ;;',
      '  *-kde-*) compositor=KWin ;;',
      '  *-sway-*) compositor=Sway ;;',
      '  *) echo "unsupported P-24 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac',
      'umask 077',
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      'node scripts/linux-port/run-p24-installed-settings-workflow.mjs \\',
      '  --raw-output-dir "$evidence_root" \\',
      '  --support-dir "$support_root" \\',
      '  --home-dir "$home_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --index-database "$index_database" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/materialize-p24-settings-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/capture-p24-settings-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p24-installed-settings-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p26-tray-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-26 installed tray proof',
    condition: "inputs.requirement == 'P-26'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p26-home.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'index_database="$support_root/openburnbar-index.sqlite"',
      'cleanup() {',
      '  status=$?',
      '  rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      '  exit "$status"',
      '}',
      'trap cleanup EXIT',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/libexec/openburnbar-daemon-launch',
      'test -f /etc/xdg/autostart/openburnbar.desktop',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-26 requires no pre-existing installed desktop process" >&2',
      '  exit 1',
      'fi',
      'case "$ENVIRONMENT_ID" in',
      '  *-gnome-*) compositor=Mutter ;;',
      '  *-kde-*) compositor=KWin ;;',
      '  *-sway-*) compositor=Sway ;;',
      '  *) echo "unsupported P-26 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac',
      'umask 077',
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      'node scripts/linux-port/run-p26-native-tray-probes.mjs \\',
      '  --raw-output-dir "$evidence_root" \\',
      '  --support-dir "$support_root" \\',
      '  --home-dir "$home_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --index-database "$index_database" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/materialize-p26-tray-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/capture-p26-tray-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p26-installed-tray-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p27-notifications-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-27 installed notification and deep-link proof',
    condition: "inputs.requirement == 'P-27'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p27-evidence.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p27-home.XXXXXX")"',
      'runtime_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p27-runtime.XXXXXX")"',
      'cleanup() {', '  status=$?',
      '  rm -rf "$evidence_root" "$home_root" "$runtime_root" || status=1',
      '  exit "$status"', '}', 'trap cleanup EXIT',
      'chmod 700 "$evidence_root" "$home_root" "$runtime_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/bin/openburnbar-daemon',
      'test -f /etc/xdg/autostart/openburnbar.desktop',
      'command -v tauri-driver >/dev/null',
      'command -v WebKitWebDriver >/dev/null',
      'case "$ENVIRONMENT_ID" in',
      '  ubuntu-24.04-gnome-x11-*) desktop=GNOME; display_server=X11; compositor=Mutter ;;',
      '  ubuntu-24.04-gnome-wayland-*) desktop=GNOME; display_server=Wayland; compositor=Mutter ;;',
      '  fedora-kde-wayland-*) desktop="KDE Plasma"; display_server=Wayland; compositor=KWin ;;',
      '  arch-sway-wayland-*) desktop="Sway/wlroots"; display_server=Wayland; compositor=Sway ;;',
      '  *) echo "unsupported P-27 environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac', 'umask 077', 'marker="p27-$(openssl rand -hex 8)"',
      'node scripts/linux-port/run-p27-native-notification-probes.mjs \\',
      '  --raw-output-dir "$evidence_root" \\',
      '  --home-dir "$home_root" \\',
      '  --runtime-dir "$runtime_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --desktop "$desktop" \\',
      '  --display-server "$display_server" \\',
      '  --marker "$marker" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
      'node scripts/linux-port/materialize-p27-notifications-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/capture-p27-notifications-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p27-installed-notifications-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p28-smarthub-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-28 installed SmartHub proof',
    condition: "inputs.requirement == 'P-28'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p28-evidence.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p28-home.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p28-support.XXXXXX")"',
      'cleanup() {', '  status=$?',
      '  rm -rf "$evidence_root" "$home_root" "$support_root" || status=1',
      '  exit "$status"', '}', 'trap cleanup EXIT',
      'chmod 700 "$evidence_root" "$home_root" "$support_root"',
      'case "$ENVIRONMENT_ID" in',
      '  ubuntu-24.04-gnome-x11-*) desktop=GNOME; display_server=X11; compositor=Mutter ;;',
      '  ubuntu-24.04-gnome-wayland-*) desktop=GNOME; display_server=Wayland; compositor=Mutter ;;',
      '  fedora-kde-wayland-*) desktop="KDE Plasma"; display_server=Wayland; compositor=KWin ;;',
      '  arch-sway-wayland-*) desktop="Sway/wlroots"; display_server=Wayland; compositor=Sway ;;',
      '  *) echo "unsupported P-28 environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac', 'umask 077', 'marker="p28-$(openssl rand -hex 8)"',
      'node scripts/linux-port/run-p28-native-smarthub-probes.mjs \\',
      '  --raw-output-dir "$evidence_root" \\',
      '  --home-dir "$home_root" \\',
      '  --support-dir "$support_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --desktop "$desktop" \\',
      '  --display-server "$display_server" \\',
      '  --bridge-port 8787 \\',
      '  --marker "$marker" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
      'node scripts/linux-port/materialize-p28-smarthub-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/capture-p28-smarthub-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p28-installed-smarthub-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p29-text-expansion-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-29 installed text expansion proof',
    condition: "inputs.requirement == 'P-29'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p29-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p29-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p29-home.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'index_database="$support_root/openburnbar-index.sqlite"',
      'cleanup() {',
      '  status=$?',
      '  rm -rf "$evidence_root" "$support_root" "$home_root" || status=1',
      '  exit "$status"',
      '}',
      'trap cleanup EXIT',
      'chmod 700 "$evidence_root" "$support_root" "$home_root"',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/libexec/openburnbar-daemon-launch',
      'test -x /usr/libexec/openburnbar/text-expansion-engine',
      'test -f /usr/share/ibus/component/openburnbar.xml',
      'test -f /usr/share/openburnbar/text-expansion/text-expansion-engine.json',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-29 requires no pre-existing installed desktop process" >&2',
      '  exit 1',
      'fi',
      'case "$ENVIRONMENT_ID" in',
      '  *-gnome-*) compositor=Mutter ;;',
      '  *-kde-*) compositor=KWin ;;',
      '  *-sway-*) compositor=Sway ;;',
      '  *) echo "unsupported P-29 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac',
      'umask 077',
      'openssl rand -hex 32 >"$token_file"',
      'chmod 600 "$token_file"',
      'node scripts/linux-port/run-p29-installed-text-expansion-workflow.mjs \\',
      '  --raw-output-dir "$evidence_root" \\',
      '  --support-dir "$support_root" \\',
      '  --home-dir "$home_root" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --index-database "$index_database" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/materialize-p29-text-expansion-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/capture-p29-text-expansion-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p29-installed-text-expansion-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p30-pet-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-30 installed pet proof',
    condition: "inputs.requirement == 'P-30'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p30-evidence.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p30-home.XXXXXX")"',
      'cleanup() {',
      '  status=$?',
      '  rm -rf "$evidence_root" "$home_root" || status=1',
      '  exit "$status"',
      '}',
      'trap cleanup EXIT',
      'chmod 700 "$evidence_root" "$home_root"',
      'test -x /usr/bin/openburnbar-daemon',
      'test -x /usr/bin/openburnbar-linux-desktop',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-30 requires no pre-existing installed desktop process" >&2',
      '  exit 1',
      'fi',
      'case "$ENVIRONMENT_ID" in',
      '  ubuntu-24.04-gnome-x11-*) desktop=GNOME; display_server=X11; compositor=Mutter ;;',
      '  ubuntu-24.04-gnome-wayland-*) desktop=GNOME; display_server=Wayland; compositor=Mutter ;;',
      '  fedora-kde-wayland-*) desktop="KDE Plasma"; display_server=Wayland; compositor=KWin ;;',
      '  arch-sway-wayland-*) desktop="Sway/wlroots"; display_server=Wayland; compositor=Sway ;;',
      '  *) echo "unsupported P-30 compositor environment: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac',
      'umask 077',
      'marker="p30-$(openssl rand -hex 8)"',
      'node scripts/linux-port/run-p30-native-pet-probes.mjs \\',
      '  --raw-output-dir "$evidence_root" \\',
      '  --home-dir "$home_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --desktop "$desktop" \\',
      '  --display-server "$display_server" \\',
      '  --marker "$marker" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
      'node scripts/linux-port/materialize-p30-pet-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor"',
      'node scripts/linux-port/capture-p30-pet-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p30-installed-pet-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p32-performance-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-32 installed performance proof',
    condition: "inputs.requirement == 'P-32'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'raw_input="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p32-input.XXXXXX")"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p32-evidence.XXXXXX")"',
      'cleanup() {',
      '  status=$?',
      '  rm -rf "$raw_input" "$evidence_root" || status=1',
      '  exit "$status"',
      '}',
      'trap cleanup EXIT',
      'chmod 700 "$raw_input" "$evidence_root"',
      'for report in linux-desktop-session-report.json runtime-perf-samples.jsonl tray-reconnect-handler-acks.jsonl tray-reconnect-daemon-health.log tray-reconnect-receipts.jsonl packaged-route-session-transcript.json matched-performance-macos.json; do',
      '  test -f "$input_root/$report"',
      '  install -m 600 "$input_root/$report" "$raw_input/$report"',
      'done',
      'export OB_EVIDENCE_OUT="$raw_input"',
      'node scripts/linux-port/run-matched-performance.mjs \\',
      '  --linux-only \\',
      '  --profile nightly \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
      'node scripts/linux-port/run-matched-performance.mjs \\',
      '  --compare-only \\',
      '  --profile nightly \\',
      '  --macos-input "$raw_input/matched-performance-macos.json" \\',
      '  --linux-input "$raw_input/matched-performance-linux.json" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"',
      'node scripts/linux-port/run-perf-budget.mjs',
      'node scripts/linux-port/run-p32-installed-performance-workflow.mjs \\',
      '  --input-dir "$raw_input" \\',
      '  --output-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
      'node scripts/linux-port/materialize-p32-performance-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"',
      'node scripts/linux-port/capture-p32-performance-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p32-installed-performance-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p13-onboarding-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-13 installed onboarding proof',
    condition: "inputs.requirement == 'P-13'",
    run: [
      "set -euo pipefail",
      "input_root=\"docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}\"",
      "evidence_root=\"$(mktemp -d \"${RUNNER_TEMP}/openburnbar-p13-evidence.XXXXXX\")\"",
      "support_root=\"$(mktemp -d \"${RUNNER_TEMP}/openburnbar-p13-support.XXXXXX\")\"",
      "home_root=\"$(mktemp -d \"${RUNNER_TEMP}/openburnbar-p13-home.XXXXXX\")\"",
      "socket_path=\"$support_root/openburnbar-daemon.sock\"",
      "token_file=\"$support_root/daemon-socket-auth-token\"",
      "index_database=\"$support_root/openburnbar-index.sqlite\"",
      "cleanup() {",
      "  status=$?",
      "  rm -rf \"$evidence_root\" \"$support_root\" \"$home_root\" || status=1",
      "  exit \"$status\"",
      "}",
      "trap cleanup EXIT",
      "chmod 700 \"$evidence_root\" \"$support_root\" \"$home_root\"",
      "test -x /usr/bin/openburnbar-linux-desktop",
      "test -x /usr/libexec/openburnbar-daemon-launch",
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      "  echo \"P-13 requires no pre-existing installed desktop process\" >&2",
      "  exit 1",
      "fi",
      "case \"$ENVIRONMENT_ID\" in",
      "  *-gnome-*) compositor=Mutter ;;",
      "  *-kde-*) compositor=KWin ;;",
      "  *-sway-*) compositor=Sway ;;",
      "  *) echo \"unsupported P-13 compositor environment: $ENVIRONMENT_ID\" >&2; exit 1 ;;",
      "esac",
      "umask 077",
      "openssl rand -hex 32 >\"$token_file\"",
      "chmod 600 \"$token_file\"",
      "node scripts/linux-port/run-p13-native-onboarding-probes.mjs \\",
      "  --raw-output-dir \"$evidence_root\" \\",
      "  --support-dir \"$support_root\" \\",
      "  --home-dir \"$home_root\" \\",
      "  --socket-path \"$socket_path\" \\",
      "  --token-file \"$token_file\" \\",
      "  --index-database \"$index_database\" \\",
      "  --environment \"$ENVIRONMENT_ID\" \\",
      "  --target-head \"$TARGET_HEAD\" \\",
      "  --candidate-run-id \"$CANDIDATE_RUN_ID\" \\",
      "  --candidate-artifact-digest \"$CANDIDATE_ARTIFACT_DIGEST\" \\",
      "  --package-version \"$PACKAGE_VERSION\" \\",
      "  --manifest-sha256 \"$MANIFEST_SHA256\" \\",
      "  --manifest-signature-sha256 \"$MANIFEST_SIGNATURE_SHA256\" \\",
      "  --compositor \"$compositor\"",
      "node scripts/linux-port/materialize-p13-onboarding-session.mjs \\",
      "  --output-root \"$input_root\" \\",
      "  --raw-evidence-dir \"$evidence_root\" \\",
      "  --environment \"$ENVIRONMENT_ID\" \\",
      "  --target-head \"$TARGET_HEAD\" \\",
      "  --candidate-run-id \"$CANDIDATE_RUN_ID\" \\",
      "  --candidate-artifact-digest \"$CANDIDATE_ARTIFACT_DIGEST\" \\",
      "  --package-version \"$PACKAGE_VERSION\" \\",
      "  --manifest-sha256 \"$MANIFEST_SHA256\" \\",
      "  --manifest-signature-sha256 \"$MANIFEST_SIGNATURE_SHA256\" \\",
      "  --compositor \"$compositor\"",
      "node scripts/linux-port/capture-p13-onboarding-proof.mjs \\",
      "  --input-root \"$input_root\" \\",
      "  --session-report \"$input_root/p13-installed-onboarding-session.json\" \\",
      "  --environment \"$ENVIRONMENT_ID\" \\",
      "  --target-head \"$TARGET_HEAD\" \\",
      "  --candidate-run-id \"$CANDIDATE_RUN_ID\" \\",
      "  --candidate-artifact-digest \"$CANDIDATE_ARTIFACT_DIGEST\" \\",
      "  --package-version \"$PACKAGE_VERSION\" \\",
      "  --manifest-sha256 \"$MANIFEST_SHA256\" \\",
      "  --manifest-signature-sha256 \"$MANIFEST_SIGNATURE_SHA256\""
    ].join("\n")
  },
  'scripts/linux-port/capture-p14-chat-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-14 installed chat proof',
    condition: "inputs.requirement == 'P-14'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'evidence_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-evidence.XXXXXX")"',
      'support_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-support.XXXXXX")"',
      'home_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-home.XXXXXX")"',
      'download_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p14-downloads.XXXXXX")"',
      'socket_path="$support_root/openburnbar-daemon.sock"',
      'token_file="$support_root/daemon-socket-auth-token"',
      'database_path="$support_root/openburnbar.sqlite"',
      'attachment_path="$support_root/p14-attachment.txt"',
      'original_environment="$support_root/original-systemd-environment"',
      'managed_variables=(OPENBURNBAR_DAEMON_SUPPORT_DIR OPENBURNBAR_DAEMON_SOCKET_PATH)',
      'if systemctl --user is-active --quiet openburnbar-daemon.service; then service_was_active=1; else service_was_active=0; fi',
      'systemctl --user show-environment >"$original_environment"',
      'chmod 600 "$original_environment"',
      'restore_manager_environment() {',
      '  systemctl --user unset-environment "${managed_variables[@]}"',
      '  while IFS= read -r entry; do',
      '    for variable in "${managed_variables[@]}"; do',
      '      if [[ "$entry" == "$variable="* ]]; then systemctl --user set-environment "$entry"; fi',
      '    done',
      '  done <"$original_environment"',
      '}',
      'cleanup() {',
      '  status=$?',
      '  restore_manager_environment || status=1',
      '  if [[ "$service_was_active" == 1 ]]; then',
      '    systemctl --user restart openburnbar-daemon.service || status=1',
      '  else',
      '    systemctl --user stop openburnbar-daemon.service || status=1',
      '  fi',
      '  rm -rf "$evidence_root" "$support_root" "$home_root" "$download_root" || status=1',
      '  exit "$status"',
      '}',
      'trap cleanup EXIT',
      'chmod 700 "$evidence_root" "$support_root" "$home_root" "$download_root"',
      'test -x /usr/bin/openburnbar-cli',
      'test -x /usr/bin/openburnbar-linux-desktop',
      'test -x /usr/libexec/openburnbar-daemon-launch',
      "if pgrep -f '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)' >/dev/null; then",
      '  echo "P-14 requires no pre-existing installed desktop process" >&2',
      '  exit 1',
      'fi',
      'case "$ENVIRONMENT_ID" in',
      '  *-gnome-x11-*) compositor=Mutter ;;',
      '  *) echo "P-14 native chooser and window proof requires GNOME X11: $ENVIRONMENT_ID" >&2; exit 1 ;;',
      'esac',
      'umask 077',
      "printf '%s\\n' 'P-14 installed attachment payload' >\"$attachment_path\"",
      'mkdir -p "$home_root/.config"',
      "printf 'XDG_DOWNLOAD_DIR=\"%s\"\\n' \"$download_root\" >\"$home_root/.config/user-dirs.dirs\"",
      'export HOME="$home_root"',
      'export XDG_CONFIG_HOME="$home_root/.config"',
      'export XDG_DATA_HOME="$home_root/.local/share"',
      'export OPENBURNBAR_DAEMON_SUPPORT_DIR="$support_root"',
      'export OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path"',
      'systemctl --user set-environment \\',
      '  "OPENBURNBAR_DAEMON_SUPPORT_DIR=$support_root" \\',
      '  "OPENBURNBAR_DAEMON_SOCKET_PATH=$socket_path"',
      'systemctl --user restart openburnbar-daemon.service',
      'for _ in $(seq 1 100); do',
      '  if [[ -S "$socket_path" && -s "$token_file" && -s "$database_path" ]]; then break; fi',
      '  sleep 0.1',
      'done',
      'test -S "$socket_path"',
      'test -s "$token_file"',
      'test -s "$database_path"',
      'node scripts/linux-port/run-p14-chat-session.mjs \\',
      '  --raw-output-dir "$evidence_root" \\',
      '  --database-path "$database_path" \\',
      '  --support-dir "$support_root" \\',
      '  --attachment "$attachment_path" \\',
      '  --socket-path "$socket_path" \\',
      '  --token-file "$token_file" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor" \\',
      '  --backend Codex \\',
      '  --model gpt-4.1 \\',
      '  --thinking High \\',
      '  --download-dir "$download_root"',
      'thread_id="$(node -p \'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).events[0].data.threadID\' "$evidence_root/daemon-chat-transcript.json")"',
      '[[ "$thread_id" =~ ^p14-thread-[a-f0-9-]{36}$ ]]',
      'node scripts/linux-port/materialize-p14-chat-session.mjs \\',
      '  --output-root "$input_root" \\',
      '  --raw-evidence-dir "$evidence_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \\',
      '  --compositor "$compositor" \\',
      '  --thread-id "$thread_id"',
      'node scripts/linux-port/capture-p14-chat-proof.mjs \\',
      '  --input-root "$input_root" \\',
      '  --session-report "$input_root/p14-installed-chat-session.json" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --package-version "$PACKAGE_VERSION" \\',
      '  --manifest-sha256 "$MANIFEST_SHA256" \\',
      '  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p15-account-billing-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-15 installed account and billing proof',
    condition: "inputs.requirement == 'P-15'",
    runSha256: '6c2b1f126978549283bae7cd77414fc2500bd75ba4c24622ed832b0f293b084c'
  },
  'scripts/linux-port/capture-p16-cloud-devices-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-16 installed cloud and devices proof',
    condition: "inputs.requirement == 'P-16'",
    runSha256: '2f5e5114bf700d0099791658b9d8a3148e6247bfd11593ed8fe56c7613fcd582'
  },
  'scripts/linux-port/capture-p33-reliability-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-33 installed reliability proof',
    condition: "inputs.requirement == 'P-33'",
    runSha256: '421ffc843a5ebfce199b2b3b1139c0b62aecd2495836661260ee5f37b0ddf382'
  },
  'scripts/linux-port/capture-p35-diagnostics-support-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-35 installed diagnostics and support proof',
    condition: "inputs.requirement == 'P-35'",
    runSha256: 'f8c45af298a46a687937f9609a2bd8df954c5eb4fb26e3027aa0cbcc5c79cf9d'
  },
  'scripts/linux-port/capture-p36-visual-polish-proof.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-36 installed visual and interaction polish proof',
    condition: "inputs.requirement == 'P-36'",
    runSha256: '93689b0e7af37589b490354c9d98de07632d534c01e9f901444095ab08ce979d'
  },
  'scripts/linux-port/finalize-product-proof-closure.mjs': {
    workflow: '.github/workflows/linux-release.yml',
    job: 'assemble-release',
    step: 'Finalize installed-product proof closure',
    run: 'node scripts/linux-port/finalize-product-proof-closure.mjs --target-head "$TARGET_HEAD"'
  },
  'scripts/linux-port/capture-parity-certification-preflight.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture parity certification preflight',
    stepId: 'p02_capture',
    condition: "inputs.requirement == 'P-02'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'diagnostic_root="$(mktemp -d "${RUNNER_TEMP}/openburnbar-p02.XXXXXX")"',
      'printf \'diagnostic_root=%s\\n\' "$diagnostic_root" >> "$GITHUB_OUTPUT"',
      'capture_log="$diagnostic_root/capture.log"',
      'node scripts/linux-port/capture-parity-certification-preflight.mjs \\',
      '  --input-root "$input_root" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      '  --diagnostic-root "$diagnostic_root" \\',
      '  2>&1 | tee "$capture_log"'
    ].join('\n')
  },
  'scripts/linux-port/capture-p39-differential.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Capture P-39 same-commit macOS/Linux differential proof',
    condition: "inputs.requirement == 'P-39'",
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'node scripts/linux-port/capture-p39-differential.mjs \\',
      '  --input-root "$input_root" \\',
      '  --macos "$MACOS_INPUT" \\',
      '  --linux "$LINUX_INPUT" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --version "$VERSION" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \\',
      "  --ignore '$.payload.generatedAt' \\",
      "  --ignore '$.payload.execution'"
    ].join('\n')
  },
  'scripts/linux-port/finalize-product-feature-proof-closure.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Finalize registered feature proof closure',
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'node scripts/linux-port/finalize-product-feature-proof-closure.mjs \\',
      '  --requirement "$REQUIREMENT_ID" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --input-root "$input_root" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
    ].join('\n')
  },
  'scripts/linux-port/prepare-product-requirement-input.mjs': {
    workflow: '.github/workflows/linux-product-parity.yml',
    job: 'validate',
    step: 'Materialize the requirement-owned release closure',
    run: [
      'set -euo pipefail',
      'input_root="docs/linux-port/evidence/product-parity-inputs/${REQUIREMENT_ID}/${ENVIRONMENT_ID}"',
      'node scripts/linux-port/prepare-product-requirement-input.mjs \\',
      '  --requirement "$REQUIREMENT_ID" \\',
      '  --environment "$ENVIRONMENT_ID" \\',
      '  --input-root "$input_root" \\',
      '  --target-head "$TARGET_HEAD" \\',
      '  --candidate-run-id "$CANDIDATE_RUN_ID" \\',
      '  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"'
    ].join('\n')
  }
});
const EXECUTION_AUTHENTICATION_FIELDS = Object.freeze([
  'requirementId', 'component', 'sourcePath', 'sourceEntrypoint', 'sourceSha256',
  'testPath', 'testName', 'testSha256', 'status', 'exitCode', 'spawnSignal',
  'spawnErrorCode', 'outputSha256', 'mutationDetected', 'mutationExitCode',
  'mutationSignal', 'mutationSpawnErrorCode', 'mutationOutputSha256'
]);

function parseJson(snapshot, label) {
  try {
    return JSON.parse(snapshot.bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function sourceRecord(snapshot) {
  return { path: snapshot.path, sha256: snapshot.sha256 };
}

function currentHead(repoRoot) {
  const result = spawnSync('git', ['rev-parse', '--verify', 'HEAD'], {
    cwd: repoRoot,
    encoding: 'utf8',
    timeout: COMMAND_TIMEOUT_MS,
    killSignal: 'SIGKILL'
  });
  if (result.status !== 0) throw new Error(`git HEAD lookup failed: ${(result.stderr || result.stdout).trim()}`);
  return result.stdout.trim();
}

function commitSnapshot(repoRoot, targetHead, relativePath, label, optional = false) {
  const cacheKey = `${repoRoot}\0${targetHead}\0${relativePath}`;
  if (COMMIT_SNAPSHOT_CACHE.has(cacheKey)) return COMMIT_SNAPSHOT_CACHE.get(cacheKey);
  const tree = spawnSync('git', ['ls-tree', '-z', targetHead, '--', relativePath], {
    cwd: repoRoot,
    encoding: 'buffer',
    timeout: COMMAND_TIMEOUT_MS,
    killSignal: 'SIGKILL'
  });
  if (tree.status !== 0) throw new Error(`git tree lookup failed for ${label}`);
  if (tree.stdout.length === 0) {
    if (optional) {
      COMMIT_SNAPSHOT_CACHE.set(cacheKey, null);
      return null;
    }
    throw new Error(`${label} is missing from target commit ${targetHead}`);
  }
  const entry = tree.stdout.toString('utf8').replace(/\0$/u, '');
  const match = /^(100644|100755) blob [a-f0-9]+\t(.+)$/u.exec(entry);
  if (!match || match[2] !== relativePath) {
    if (optional) return null;
    throw new Error(`${label} must be a regular target-commit blob`);
  }
  const shown = spawnSync('git', ['show', `${targetHead}:${relativePath}`], {
    cwd: repoRoot,
    encoding: 'buffer',
    maxBuffer: 64 * 1024 * 1024,
    timeout: COMMAND_TIMEOUT_MS,
    killSignal: 'SIGKILL'
  });
  if (shown.status !== 0) throw new Error(`git blob read failed for ${label}`);
  const snapshot = {
    path: relativePath,
    bytes: shown.stdout,
    sha256: cryptoHash(shown.stdout),
    size: shown.stdout.length
  };
  if (COMMIT_SNAPSHOT_CACHE.size > 4096) COMMIT_SNAPSHOT_CACHE.clear();
  COMMIT_SNAPSHOT_CACHE.set(cacheKey, snapshot);
  return snapshot;
}

function cryptoHash(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function addBlocker(blockers, code, subject, detail) {
  blockers.push({ code, subject, detail });
}

function componentCode(prefix, status) {
  if (status === 'ready') return null;
  return `${status}-${prefix}`;
}

function reportSourcePath(inputRoot, repoRoot) {
  const absolute = path.join(inputRoot, 'feature-artifacts', PARITY_PREFLIGHT_FILENAME);
  return path.relative(repoRoot, absolute).split(path.sep).join('/');
}

function certificationRows(registry) {
  return Array.isArray(registry.certification) ? registry.certification : [];
}

function executionKey(requirementId, component) {
  return `${requirementId}\0${component}`;
}

function testOwnershipKey(testPath, testName) {
  return `${testPath}\0${testName}`;
}

function ownershipExecutions(registry) {
  const entries = [];
  for (const ownership of certificationRows(registry)) {
    for (const component of ['validator', 'capture', 'materializer']) {
      const value = ownership?.[component];
      const testName = component === 'validator' ? value?.mutationTestName : value?.testName;
      if (typeof value?.testPath !== 'string' || typeof testName !== 'string') continue;
      entries.push({
        requirementId: ownership.requirementId,
        component,
        sourcePath: component === 'validator' ? value.sourcePath : value.producerPath,
        sourceEntrypoint: value.entrypoint,
        testPath: value.testPath,
        testName
      });
    }
  }
  return entries.sort((left, right) =>
    executionKey(left.requirementId, left.component).localeCompare(
      executionKey(right.requirementId, right.component)
    )
  );
}

function duplicateOwnershipTests(registry) {
  const owners = new Map();
  for (const entry of ownershipExecutions(registry)) {
    const key = testOwnershipKey(entry.testPath, entry.testName);
    const rows = owners.get(key) ?? [];
    rows.push(entry);
    owners.set(key, rows);
  }
  return [...owners.values()].filter((rows) => rows.length > 1);
}

function validateExecutionInventory(registry, testExecutions, blockers) {
  const expected = new Set(ownershipExecutions(registry).map((entry) =>
    executionKey(entry.requirementId, entry.component)
  ));
  const counts = new Map();
  for (const entry of testExecutions) {
    const key = executionKey(entry?.requirementId, entry?.component);
    counts.set(key, (counts.get(key) ?? 0) + 1);
    if (!expected.has(key)) {
      addBlocker(blockers, 'unexpected-test-execution', entry?.requirementId ?? '<missing>',
        'test execution is not owned by the candidate registry');
    }
  }
  for (const entry of ownershipExecutions(registry)) {
    const count = counts.get(executionKey(entry.requirementId, entry.component)) ?? 0;
    if (count !== 1) {
      addBlocker(blockers, count === 0 ? 'missing-test-execution' : 'duplicate-test-execution',
        entry.requirementId, `${entry.component} execution occurs ${count} times`);
    }
  }
  for (const rows of duplicateOwnershipTests(registry)) {
    const subjects = rows.map((entry) => `${entry.requirementId}/${entry.component}`).join(', ');
    addBlocker(blockers, 'reused-ownership-test', subjects,
      `${rows[0].testPath} :: ${rows[0].testName} is registered by multiple components`);
  }
}

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..'
    && !path.isAbsolute(relative));
}

function validateIsolatedTree(root, { allowInternalSymlinks }) {
  const canonicalRoot = fs.realpathSync(root);
  const pending = [canonicalRoot];
  while (pending.length > 0) {
    const directory = pending.pop();
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      const metadata = fs.lstatSync(absolute);
      if (metadata.isSymbolicLink()) {
        if (!allowInternalSymlinks) {
          throw new Error(`isolated target archive contains a symbolic link: ${path.relative(canonicalRoot, absolute)}`);
        }
        let resolved;
        try {
          resolved = fs.realpathSync(absolute);
        } catch {
          throw new Error(`isolated dependency symbolic link is unresolved: ${path.relative(canonicalRoot, absolute)}`);
        }
        if (!isWithin(canonicalRoot, resolved)) {
          throw new Error(`isolated dependency symbolic link escapes its root: ${path.relative(canonicalRoot, absolute)}`);
        }
      } else if (metadata.isDirectory()) {
        pending.push(absolute);
      }
    }
  }
}

function isolatedTargetCheckout(repoRoot, targetHead) {
  const availablePaths = ISOLATED_TARGET_PATHS.filter((relativePath) => {
    const present = spawnSync('git', ['ls-tree', '--name-only', targetHead, '--', relativePath], {
      cwd: repoRoot,
      encoding: 'utf8',
      timeout: COMMAND_TIMEOUT_MS,
      killSignal: 'SIGKILL'
    });
    if (present.status !== 0) throw new Error(`failed to inspect target path ${relativePath}`);
    return present.stdout.trim().length > 0;
  });
  const archive = spawnSync('git', ['archive', '--format=tar', targetHead, '--', ...availablePaths], {
    cwd: repoRoot,
    encoding: 'buffer',
    maxBuffer: 128 * 1024 * 1024,
    timeout: COMMAND_TIMEOUT_MS,
    killSignal: 'SIGKILL'
  });
  if (archive.status !== 0) throw new Error('failed to archive target-controlled ownership-test bytes');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p02-target-'));
  try {
    const extracted = spawnSync('tar', ['-xf', '-', '-C', root], {
      input: archive.stdout,
      encoding: 'buffer',
      maxBuffer: 16 * 1024 * 1024,
      timeout: COMMAND_TIMEOUT_MS,
      killSignal: 'SIGKILL'
    });
    if (extracted.status !== 0) throw new Error('failed to extract target-controlled ownership-test bytes');
    validateIsolatedTree(root, { allowInternalSymlinks: false });
    fs.rmSync(path.join(root, 'scripts/linux-port/node_modules'), {
      recursive: true,
      force: true
    });
    const dependencyRoot = fs.existsSync(path.join(repoRoot, 'scripts/linux-port/node_modules'))
      ? path.join(repoRoot, 'scripts/linux-port/node_modules')
      : MODULE_DEPENDENCY_ROOT;
    if (!fs.lstatSync(dependencyRoot).isDirectory()) {
      throw new Error('Linux parity tool dependencies must be an installed directory');
    }
    fs.cpSync(dependencyRoot, path.join(root, 'scripts/linux-port/node_modules'), {
      recursive: true,
      dereference: false,
      verbatimSymlinks: true,
      mode: fs.constants.COPYFILE_FICLONE
    });
    validateIsolatedTree(path.join(root, 'scripts/linux-port/node_modules'), {
      allowInternalSymlinks: true
    });
    return root;
  } catch (error) {
    fs.rmSync(root, { recursive: true, force: true });
    throw error;
  }
}

function escapedPattern(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

export function classifyOwnershipTestSpawn(result, testName) {
  const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
  const exitCode = Number.isInteger(result.status) ? result.status : null;
  const signal = typeof result.signal === 'string' ? result.signal : null;
  const errorCode = typeof result.error?.code === 'string'
    ? result.error.code : result.error ? 'UNKNOWN' : null;
  const completedNormally = exitCode !== null && signal === null && errorCode === null;
  const namedTestPassed = new RegExp(
    `^ok [0-9]+ - ${escapedPattern(testName)}$`,
    'mu'
  ).test(output);
  return {
    exitCode,
    signal,
    errorCode,
    output,
    passed: completedNormally && exitCode === 0 && namedTestPassed && /# fail 0/u.test(output),
    failedNormally: completedNormally && exitCode > 0
  };
}

function canonicalOwnershipOutput(output, roots) {
  let normalized = output.replace(/\r\n/gu, '\n');
  for (const root of roots) normalized = normalized.replaceAll(root, '<isolated-root>');
  return normalized
    .replace(/^(\s*duration_ms:\s*)[0-9.]+$/gmu, '$1<elapsed>')
    .replace(/^(# duration_ms\s+)[0-9.]+$/gmu, '$1<elapsed>');
}

function runOwnedTest(checkout, entry) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p02-home-'));
  const environment = {
    HOME: home,
    LANG: 'C.UTF-8',
    LC_ALL: 'C',
    OPENBURNBAR_PARITY_PREFLIGHT_OWNERSHIP_TEST: '1',
    PATH: process.env.PATH ?? '/usr/bin:/bin',
    TMPDIR: os.tmpdir()
  };
  try {
    const result = spawnSync(process.execPath, [
      '--test',
      `--test-name-pattern=^${escapedPattern(entry.testName)}$`,
      entry.testPath
    ], {
      cwd: checkout,
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
      env: environment,
      timeout: OWNERSHIP_TEST_TIMEOUT_MS,
      killSignal: 'SIGKILL'
    });
    const classified = classifyOwnershipTestSpawn(result, entry.testName);
    return {
      ...classified,
      output: canonicalOwnershipOutput(classified.output, [checkout, home])
    };
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}

function installSemanticMutation(checkout, entry) {
  const { sourcePath, sourceEntrypoint } = entry;
  const absolute = path.join(checkout, sourcePath);
  const probe = spawnSync(process.execPath, [
    '--input-type=module',
    '--eval',
    `import(${JSON.stringify(pathToFileURL(absolute).href)})`
      + ".then((module) => process.stdout.write(JSON.stringify(Object.keys(module).sort())))"
  ], {
    cwd: checkout,
    encoding: 'utf8',
    maxBuffer: 4 * 1024 * 1024,
    timeout: COMMAND_TIMEOUT_MS,
    killSignal: 'SIGKILL',
    env: {
      HOME: os.tmpdir(),
      LANG: 'C.UTF-8',
      LC_ALL: 'C',
      PATH: process.env.PATH ?? '/usr/bin:/bin',
      TMPDIR: os.tmpdir()
    }
  });
  if (probe.status !== 0) {
    const detail = canonicalOwnershipOutput(`${probe.stderr || ''}\n${probe.stdout || ''}`, [checkout])
      .replace(/\s+/gu, ' ').trim().slice(0, 768);
    throw new Error(`cannot enumerate exports for semantic mutation of ${sourcePath}${detail ? `: ${detail}` : ''}`);
  }
  let exports;
  try {
    exports = JSON.parse(probe.stdout);
  } catch {
    throw new Error(`cannot parse exports for semantic mutation of ${sourcePath}`);
  }
  if (!Array.isArray(exports) || exports.length === 0 || !exports.includes(sourceEntrypoint)
      || exports.some((name) => name !== 'default' && !/^[$A-Z_a-z][$\w]*$/u.test(name))) {
    throw new Error(`semantic mutation requires exported entrypoint ${sourceEntrypoint} in ${sourcePath}`);
  }
  const original = `${absolute}.ownership-original.mjs`;
  fs.copyFileSync(absolute, original);
  const lines = [
    `import * as original from ${JSON.stringify(`./${path.basename(original)}`)};`,
    "const fail = () => { throw new Error('OpenBurnBar semantic ownership mutation'); };"
  ];
  for (const name of exports) {
    if (name === sourceEntrypoint) {
      lines.push(name === 'default'
        ? 'export default (...args) => fail(...args);'
        : `export const ${name} = (...args) => fail(...args);`);
    } else if (name === 'default') {
      lines.push('export default original.default;');
    } else {
      lines.push(`export const ${name} = original.${name};`);
    }
  }
  fs.writeFileSync(absolute, `${lines.join('\n')}\n`);
}

function cloneIsolatedTarget(templateRoot) {
  const container = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p02-run-'));
  const checkout = path.join(container, 'checkout');
  fs.cpSync(templateRoot, checkout, {
    recursive: true,
    dereference: false,
    mode: fs.constants.COPYFILE_FICLONE
  });
  return { checkout, container };
}

function executeOwnershipTest(repoRoot, targetHead, templateRoot, entry) {
  const sourceSnapshot = commitSnapshot(
    repoRoot, targetHead, entry.sourcePath, `${entry.requirementId} ${entry.component} source`
  );
  const testSnapshot = commitSnapshot(
    repoRoot, targetHead, entry.testPath, `${entry.requirementId} ${entry.component} ownership test`
  );
  const baselineRoot = cloneIsolatedTarget(templateRoot);
  let baseline;
  try {
    baseline = runOwnedTest(baselineRoot.checkout, entry);
  } finally {
    fs.rmSync(baselineRoot.container, { recursive: true, force: true });
  }
  const mutationRoot = cloneIsolatedTarget(templateRoot);
  let mutation;
  try {
    installSemanticMutation(mutationRoot.checkout, entry);
    mutation = runOwnedTest(mutationRoot.checkout, entry);
  } finally {
    fs.rmSync(mutationRoot.container, { recursive: true, force: true });
  }
  return {
    requirementId: entry.requirementId,
    component: entry.component,
    sourcePath: entry.sourcePath,
    sourceEntrypoint: entry.sourceEntrypoint,
    sourceSha256: sourceSnapshot.sha256,
    testPath: entry.testPath,
    testName: entry.testName,
    testSha256: testSnapshot.sha256,
    status: baseline.passed && mutation.failedNormally ? 'passed' : 'failed',
    exitCode: baseline.exitCode,
    spawnSignal: baseline.signal,
    spawnErrorCode: baseline.errorCode,
    outputSha256: cryptoHash(Buffer.from(baseline.output)),
    mutationDetected: mutation.failedNormally,
    mutationExitCode: mutation.exitCode,
    mutationSignal: mutation.signal,
    mutationSpawnErrorCode: mutation.errorCode,
    mutationOutputSha256: cryptoHash(Buffer.from(mutation.output))
  };
}

export function collectCertificationTestExecutions(repoRoot, targetHead) {
  const repository = fs.realpathSync(repoRoot);
  if (!HEAD.test(targetHead ?? '')) throw new Error('test execution requires a canonical target HEAD');
  const registrySnapshot = commitSnapshot(repository, targetHead, REGISTRY_PATH, 'feature proof registry');
  const registry = parseJson(registrySnapshot, 'feature proof registry');
  const duplicates = duplicateOwnershipTests(registry);
  if (duplicates.length > 0) {
    throw new Error('certification ownership tests must be unique to one requirement component');
  }
  const templateRoot = isolatedTargetCheckout(repository, targetHead);
  try {
    return ownershipExecutions(registry).map((entry) =>
      executeOwnershipTest(repository, targetHead, templateRoot, entry)
    ).sort((left, right) =>
      executionKey(left.requirementId, left.component).localeCompare(
        executionKey(right.requirementId, right.component)
      )
    );
  } finally {
    fs.rmSync(templateRoot, { recursive: true, force: true });
  }
}

function ownedSource(repoRoot, targetHead, relativePath, label) {
  if (typeof relativePath !== 'string') return null;
  return commitSnapshot(repoRoot, targetHead, relativePath, label, true);
}

function executionReady(testExecutions, targetHead, requirementId, component, sourceSnapshot,
  sourceEntrypoint, testPath, testName, testSnapshot) {
  if (!testSnapshot) return false;
  const rows = testExecutions.filter((entry) =>
    entry?.requirementId === requirementId && entry?.component === component
  );
  return rows.length === 1
    && rows[0].sourcePath === sourceSnapshot?.path
    && rows[0].sourceEntrypoint === sourceEntrypoint
    && rows[0].sourceSha256 === sourceSnapshot?.sha256
    && rows[0].testPath === testPath
    && rows[0].testName === testName
    && rows[0].status === 'passed'
    && rows[0].exitCode === 0
    && rows[0].spawnSignal === null
    && rows[0].spawnErrorCode === null
    && rows[0].testSha256 === testSnapshot.sha256
    && rows[0].mutationDetected === true
    && Number.isInteger(rows[0].mutationExitCode)
    && rows[0].mutationExitCode > 0
    && rows[0].mutationSignal === null
    && rows[0].mutationSpawnErrorCode === null
    && HEAD.test(targetHead);
}

function normalizedRunScript(value) {
  return value.split(/\r?\n/u).map((line) => line.trimEnd()).join('\n').trim();
}

function workflowExecutesProducer(
  workflowSnapshot, workflowPath, producerPath, requirementId, component
) {
  const canonical = CANONICAL_WORKFLOW_OWNERSHIP[producerPath] ?? {
    workflow: `.github/workflows/${requirementId.toLowerCase()}-${component}.yml`,
    job: 'certification',
    step: `${requirementId} ${component} executes`,
    run: `node ${producerPath}`
  };
  if (canonical.workflow !== workflowPath) return false;
  let document;
  try {
    document = parseYaml(workflowSnapshot.bytes.toString('utf8'));
  } catch {
    return false;
  }
  const steps = document?.jobs?.[canonical.job]?.steps;
  if (!Array.isArray(steps)) return false;
  const owned = steps.filter((step) => step?.name === canonical.step);
  if (owned.length !== 1 || typeof owned[0].run !== 'string'
      || owned[0]['continue-on-error'] !== undefined
      || (canonical.stepId !== undefined && owned[0].id !== canonical.stepId)
      || (canonical.condition === undefined && owned[0].if !== undefined)
      || (canonical.condition !== undefined && owned[0].if !== canonical.condition)) return false;
  const normalizedRun = normalizedRunScript(owned[0].run);
  if (canonical.runSha256 !== undefined) {
    return cryptoHash(Buffer.from(normalizedRun, 'utf8')) === canonical.runSha256;
  }
  return normalizedRun === normalizedRunScript(canonical.run);
}

function componentOwnershipStatus({
  repoRoot, targetHead, requirementId, ownership, component, testExecutions, expectedProducerPath
}) {
  if (!ownership || typeof ownership !== 'object') {
    return {
      status: 'missing', producerPath: null, workflowPath: null, testPath: null, testName: null
    };
  }
  const producer = ownedSource(repoRoot, targetHead, ownership.producerPath, `${component} producer`);
  const workflow = ownedSource(repoRoot, targetHead, ownership.workflowPath, `${component} workflow`);
  const test = ownedSource(repoRoot, targetHead, ownership.testPath, `${component} test`);
  const wired = producer && workflow && test
    && ownership.producerPath === expectedProducerPath
    && workflowExecutesProducer(
      workflow, ownership.workflowPath, ownership.producerPath, requirementId, component
    )
    && executionReady(
      testExecutions, targetHead, requirementId, component, producer, ownership.entrypoint,
      ownership.testPath, ownership.testName, test
    );
  return {
    status: wired ? 'ready' : 'invalid',
    producerPath: ownership.producerPath ?? null,
    workflowPath: ownership.workflowPath ?? null,
    testPath: ownership.testPath ?? null,
    testName: ownership.testName ?? null
  };
}

export function buildParityCertificationPreflight({
  repoRoot,
  inputRoot,
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  testExecutions = []
}) {
  const repository = fs.realpathSync(repoRoot);
  const root = fs.realpathSync(inputRoot);
  const proofPath = reportSourcePath(root, repository);
  if (!HEAD.test(targetHead ?? '') || !RUN_ID.test(String(candidateRunId ?? ''))
      || !DIGEST.test(candidateArtifactDigest ?? '')) {
    throw new Error('canonical target HEAD, candidate run ID, and artifact digest are required');
  }
  const requirementSnapshot = commitSnapshot(repository, targetHead, REQUIREMENTS_PATH, 'parity requirements manifest');
  const policySnapshot = commitSnapshot(repository, targetHead, POLICIES_PATH, 'parity evidence policy manifest');
  const registrySourceSnapshot = commitSnapshot(repository, targetHead, REGISTRY_PATH, 'feature proof registry');
  const requirementsManifest = parseJson(requirementSnapshot, 'parity requirements manifest');
  const policyManifest = parseJson(policySnapshot, 'parity evidence policy manifest');
  const aggregateSnapshot = readRegularSnapshot(root, '.linux-release/product-proof-closure.json', 'aggregate product proof closure');
  const aggregate = validateAggregateDocument(parseJson(aggregateSnapshot, 'aggregate product proof closure'));
  const candidateRegistrySnapshot = validateRecord(
    path.dirname(aggregateSnapshot.absolute),
    aggregate.featureProofRegistry,
    'candidate feature proof registry'
  );
  const registry = parseJson(candidateRegistrySnapshot, 'candidate feature proof registry');
  const blockers = [];
  const observedHead = currentHead(repository);
  if (observedHead !== targetHead) {
    addBlocker(blockers, 'stale-target-head', 'candidate', `repository HEAD ${observedHead} does not match ${targetHead}`);
  }
  if (aggregate.targetHead !== targetHead || aggregate.sourceCommit !== targetHead) {
    addBlocker(blockers, 'stale-candidate', 'candidate', 'aggregate product proof closure is not bound to target HEAD');
  }
  if (candidateRegistrySnapshot.sha256 !== registrySourceSnapshot.sha256
      || !candidateRegistrySnapshot.bytes.equals(registrySourceSnapshot.bytes)) {
    addBlocker(blockers, 'stale-candidate-registry', 'candidate', 'candidate registry differs from the target source tree');
  }
  if (!SUPPORT_ENVIRONMENTS.includes(environmentId)) {
    addBlocker(blockers, 'unsupported-environment', environmentId, 'environment is outside the canonical support matrix');
  }

  const observedRequirements = Array.isArray(requirementsManifest.requirements)
    ? requirementsManifest.requirements : [];
  const observedEnvironments = Array.isArray(requirementsManifest.minimumSupportMatrix)
    ? requirementsManifest.minimumSupportMatrix : [];
  const observedPolicies = Array.isArray(policyManifest.policies) ? policyManifest.policies : [];
  const observedContracts = Array.isArray(registry.requirements) ? registry.requirements : [];
  const observedOwnership = certificationRows(registry);
  validateExecutionInventory(registry, testExecutions, blockers);
  let canonicalRequirements = null;
  let canonicalPolicies = false;
  try {
    canonicalRequirements = validateRequirementsManifest(requirementsManifest);
  } catch (error) {
    addBlocker(blockers, 'invalid-requirements-manifest', 'inventory', error.message);
  }
  if (canonicalRequirements) {
    try {
      validatePolicyManifest(policyManifest, canonicalRequirements);
      canonicalPolicies = true;
    } catch (error) {
      addBlocker(blockers, 'invalid-policy-manifest', 'inventory', error.message);
    }
  }
  for (const row of observedRequirements) {
    if (!REQUIREMENT_IDS.includes(row?.id)) {
      addBlocker(blockers, 'unknown-requirement', String(row?.id ?? '<missing>'), 'requirements manifest contains an unknown row');
    }
  }
  for (const row of observedEnvironments) {
    if (!SUPPORT_ENVIRONMENTS.includes(row?.id)) {
      addBlocker(blockers, 'unknown-environment', String(row?.id ?? '<missing>'), 'requirements manifest contains an unknown environment');
    }
  }
  for (const policy of observedPolicies) {
    if (!REQUIREMENT_IDS.includes(policy?.requirementId)) {
      addBlocker(blockers, 'unknown-policy', String(policy?.requirementId ?? '<missing>'), 'policy manifest contains an unknown requirement');
    }
  }
  for (const contract of observedContracts) {
    if (!REQUIREMENT_IDS.includes(contract?.requirementId)) {
      addBlocker(blockers, 'unknown-capture', String(contract?.requirementId ?? '<missing>'), 'feature registry contains an unknown requirement');
    }
  }
  for (const ownership of observedOwnership) {
    if (!REQUIREMENT_IDS.includes(ownership?.requirementId)) {
      addBlocker(blockers, 'unknown-ownership', String(ownership?.requirementId ?? '<missing>'), 'certification registry contains an unknown requirement');
    }
  }

  const environments = SUPPORT_ENVIRONMENTS.map((id) => {
    const presentCount = observedEnvironments.filter((row) => row?.id === id).length;
    const status = presentCount === 1 ? 'ready' : presentCount === 0 ? 'missing' : 'duplicate';
    if (status !== 'ready') addBlocker(blockers, `${status}-environment`, id, `environment occurs ${presentCount} times`);
    return { environmentId: id, presentCount, status };
  });

  const rows = REQUIREMENT_IDS.map((requirementId) => {
    const requirementRows = observedRequirements.filter((entry) => entry?.id === requirementId);
    const area = typeof requirementRows[0]?.area === 'string' && requirementRows[0].area.length > 0
      ? requirementRows[0].area : 'missing';
    const policyRows = observedPolicies.filter((entry) => entry?.requirementId === requirementId);
    const policyState = policyRows.length === 1
      ? canonicalPolicies ? 'ready' : 'invalid'
      : policyRows.length === 0 ? 'missing' : 'duplicate';
    const validatorPath = `${VALIDATOR_ROOT}/${requirementId}.mjs`;
    const ownershipRows = observedOwnership.filter((entry) => entry?.requirementId === requirementId);
    const ownership = ownershipRows.length === 1 ? ownershipRows[0] : null;
    const validatorSnapshot = ownedSource(repository, targetHead, validatorPath, `${requirementId} validator`);
    const validatorTest = ownedSource(
      repository, targetHead, ownership?.validator?.testPath, `${requirementId} validator mutation test`
    );
    const validatorOwned = ownership
      && ownership.validator?.sourcePath === validatorPath
      && validatorSnapshot
      && validatorTest
      && executionReady(
        testExecutions,
        targetHead,
        requirementId,
        'validator',
        validatorSnapshot,
        ownership.validator.entrypoint,
        ownership.validator.testPath,
        ownership.validator.mutationTestName,
        validatorTest
      );
    const validator = {
      status: ownershipRows.length > 1 ? 'duplicate'
        : !validatorSnapshot || ownershipRows.length === 0 ? 'missing'
          : validatorOwned ? 'ready' : 'invalid',
      path: validatorSnapshot ? validatorPath : null,
      sha256: validatorSnapshot?.sha256 ?? null,
      testPath: ownership?.validator?.testPath ?? null,
      testName: ownership?.validator?.mutationTestName ?? null,
      testSha256: validatorTest?.sha256 ?? null
    };
    const contracts = observedContracts.filter((entry) => entry?.requirementId === requirementId);
    const releaseRoles = RELEASE_PROOF_ROLES[requirementId] ? [...RELEASE_PROOF_ROLES[requirementId]].sort() : [];
    let capture;
    const captureOwner = ownershipRows.length === 1
      ? componentOwnershipStatus({
        repoRoot: repository,
        targetHead,
        requirementId,
        ownership: ownership.capture,
        component: 'capture',
        testExecutions,
        expectedProducerPath: releaseRoles.length > 0
          ? requirementId === 'P-39'
            ? 'scripts/linux-port/capture-p39-differential.mjs'
            : 'scripts/linux-port/finalize-product-proof-closure.mjs'
          : requirementId === 'P-02'
            ? 'scripts/linux-port/capture-parity-certification-preflight.mjs'
            : ownership.capture?.producerPath
      })
      : {
        status: ownershipRows.length > 1 ? 'duplicate' : 'missing',
        producerPath: null,
        workflowPath: null,
        testPath: null,
        testName: null
      };
    if (releaseRoles.length > 0) {
      capture = {
        ...captureOwner,
        status: contracts.length > 0 ? 'duplicate' : captureOwner.status,
        kind: 'release',
        roles: releaseRoles
      };
    } else if (contracts.length === 0) {
      capture = { ...captureOwner, status: 'missing', kind: 'none', roles: [] };
    } else if (contracts.length > 1) {
      capture = { ...captureOwner, status: 'duplicate', kind: 'feature', roles: [] };
    } else {
      const roles = Array.isArray(contracts[0].artifacts)
        ? contracts[0].artifacts.map((artifact) => artifact?.role).filter((role) => typeof role === 'string') : [];
      const unique = new Set(roles);
      const artifacts = Array.isArray(contracts[0].artifacts) ? contracts[0].artifacts : [];
      const totalBytes = artifacts.reduce((sum, artifact) => sum + (Number.isInteger(artifact?.maxBytes) ? artifact.maxBytes : 0), 0);
      const valid = roles.length > 0 && unique.size === roles.length
        && artifacts.every((artifact) =>
          /^feature\.[a-z0-9]+(?:[._-][a-z0-9]+)*$/u.test(artifact?.role ?? '')
          && /^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/u.test(artifact?.mediaType ?? '')
          && Number.isInteger(artifact?.maxBytes) && artifact.maxBytes > 0
          && artifact.maxBytes <= MAX_FEATURE_PROOF_ARTIFACT_BYTES
        )
        && totalBytes <= MAX_FEATURE_PROOF_CONTRACT_BYTES
        && (requirementId !== 'P-02' || (roles.length === 1 && roles[0] === PARITY_PREFLIGHT_ROLE));
      capture = {
        ...captureOwner,
        status: valid && captureOwner.status === 'ready' ? 'ready' : 'invalid',
        kind: 'feature',
        roles: [...roles].sort()
      };
    }
    const materializerOwner = ownershipRows.length === 1
      ? componentOwnershipStatus({
        repoRoot: repository,
        targetHead,
        requirementId,
        ownership: ownership.materializer,
        component: 'materializer',
        testExecutions,
        expectedProducerPath: ownership.materializer?.producerPath
      })
      : { status: 'invalid', producerPath: null, workflowPath: null, testPath: null, testName: null };
    const materializer = capture.status === 'ready' && materializerOwner.status === 'ready'
      ? { ...materializerOwner, kind: capture.kind }
      : { ...materializerOwner, status: 'unsupported', kind: 'none' };
    let rowBlockers = [];
    if (requirementRows.length !== 1) rowBlockers.push(requirementRows.length === 0 ? 'missing-requirement' : 'duplicate-requirement');
    if (policyState !== 'ready') rowBlockers.push(`${policyState}-policy`);
    const validatorCode = componentCode('validator', validator.status);
    if (validatorCode) rowBlockers.push(validatorCode);
    if (capture.status !== 'ready') rowBlockers.push(`${capture.status}-capture`);
    if (materializer.status !== 'ready') rowBlockers.push('unsupported-materializer');
    rowBlockers = [...new Set(rowBlockers)];
    for (const code of rowBlockers) addBlocker(blockers, code, requirementId, `${requirementId} ${code.replaceAll('-', ' ')}`);
    return {
      requirementId,
      area,
      presentCount: requirementRows.length,
      policy: {
        status: policyState,
        presentCount: policyRows.length,
        requiredEnvironmentIds: Array.isArray(policyRows[0]?.requiredEnvironmentIds)
          ? policyRows[0].requiredEnvironmentIds : []
      },
      validator,
      capture,
      materializer,
      ready: rowBlockers.length === 0,
      blockers: rowBlockers.sort()
    };
  });

  const validatorHashes = new Map();
  const featureRoles = new Map();
  for (const row of rows) {
    if (row.validator.status === 'ready') {
      const owners = validatorHashes.get(row.validator.sha256) ?? [];
      owners.push(row);
      validatorHashes.set(row.validator.sha256, owners);
    }
    if (row.capture.status === 'ready' && row.capture.kind === 'feature') {
      for (const role of row.capture.roles) {
        const owners = featureRoles.get(role) ?? [];
        owners.push(row);
        featureRoles.set(role, owners);
      }
    }
  }
  for (const owners of validatorHashes.values()) {
    if (owners.length < 2) continue;
    for (const row of owners) {
      row.validator.status = 'reused';
      row.ready = false;
      row.blockers.push('reused-validator');
      addBlocker(blockers, 'reused-validator', row.requirementId, 'validator bytes are reused by another requirement');
    }
  }
  for (const owners of featureRoles.values()) {
    if (owners.length < 2) continue;
    for (const row of owners) {
      row.capture.status = 'reused';
      row.materializer = {
        ...row.materializer,
        status: 'unsupported',
        kind: 'none'
      };
      row.ready = false;
      row.blockers.push('reused-capture', 'unsupported-materializer');
      addBlocker(blockers, 'reused-capture', row.requirementId, 'feature capture role is reused by another requirement');
      addBlocker(blockers, 'unsupported-materializer', row.requirementId, 'reused capture cannot materialize parity evidence');
    }
  }

  const sources = {
    requirementsManifest: sourceRecord(requirementSnapshot),
    policyManifest: sourceRecord(policySnapshot),
    featureRegistry: sourceRecord(candidateRegistrySnapshot)
  };
  for (const source of Object.values(sources)) {
    if (source.path === proofPath) addBlocker(blockers, 'self-referential-proof', source.path, 'proof cites itself as an inventory source');
  }
  for (const row of rows) {
    if (row.validator.path === proofPath) {
      row.ready = false;
      row.blockers.push('self-referential-proof');
      addBlocker(blockers, 'self-referential-proof', row.requirementId, 'proof is used as its own validator source');
    }
    row.blockers = [...new Set(row.blockers)].sort();
  }
  blockers.sort((left, right) =>
    `${left.subject}:${left.code}:${left.detail}`.localeCompare(`${right.subject}:${right.code}:${right.detail}`)
  );
  const summary = {
    requirementCount: rows.filter((row) => row.presentCount === 1).length,
    policyCount: rows.filter((row) => row.policy.status === 'ready').length,
    environmentCount: environments.filter((row) => row.status === 'ready').length,
    validatorCount: rows.filter((row) => row.validator.status === 'ready').length,
    captureCount: rows.filter((row) => row.capture.status === 'ready').length,
    materializerCount: rows.filter((row) => row.materializer.status === 'ready').length,
    readyCount: rows.filter((row) => row.ready).length,
    blockerCount: blockers.length
  };
  return {
    schemaVersion: 1,
    targetHead,
    sourceCommit: targetHead,
    status: blockers.length === 0 ? 'passed' : 'blocked',
    requirementId: 'P-02',
    environmentId,
    proofPath,
    candidate: {
      runId: String(candidateRunId),
      artifactDigest: candidateArtifactDigest,
      productProofClosureSha256: aggregateSnapshot.sha256
    },
    sources,
    testExecutions,
    environments,
    requirements: rows,
    summary,
    blockers
  };
}

export function validateParityCertificationPreflightSchema(repoRoot, document) {
  const schema = parseJson(
    readRegularSnapshot(repoRoot, PARITY_PREFLIGHT_SCHEMA_PATH, 'parity preflight schema'),
    'parity preflight schema'
  );
  const validate = new Ajv2020({ allErrors: true, strict: true }).compile(schema);
  if (!validate(document)) {
    const detail = validate.errors?.map((error) => `${error.instancePath || '/'} ${error.message}`).join('; ');
    throw new Error(`parity certification preflight does not satisfy its schema: ${detail}`);
  }
}

function normalizedExecution(entry) {
  return Object.fromEntries(EXECUTION_AUTHENTICATION_FIELDS.map((field) => [field, entry?.[field]]));
}

export function certificationTestExecutionsMatch(claimed, independent) {
  return Array.isArray(claimed) && Array.isArray(independent)
    && claimed.length === independent.length
    && claimed.every((entry, index) =>
      JSON.stringify(normalizedExecution(entry))
        === JSON.stringify(normalizedExecution(independent[index]))
    );
}

export function validateParityCertificationPreflight(document, expected) {
  validateParityCertificationPreflightSchema(expected.repoRoot, document);
  const citedPaths = [
    ...Object.values(document.sources).map((source) => source.path),
    ...document.requirements.map((row) => row.validator.path).filter(Boolean)
  ];
  if (document.proofPath === expected.materializedProofPath || citedPaths.includes(document.proofPath)) {
    throw new Error('parity certification preflight proof is self-referential');
  }
  if (document.candidate.runId !== expected.candidate.runId
      || document.candidate.artifactDigest !== expected.candidate.artifactDigest
      || document.candidate.productProofClosureSha256 !== expected.candidate.productProofClosureSha256) {
    throw new Error('parity certification preflight is stale, substituted, or not bound to current candidate');
  }
  const independentlyExecuted = collectCertificationTestExecutions(expected.repoRoot, expected.targetHead);
  if (independentlyExecuted.some((entry) => entry.status !== 'passed')) {
    throw new Error('independent target-commit ownership test execution failed');
  }
  if (!certificationTestExecutionsMatch(document.testExecutions, independentlyExecuted)) {
    throw new Error('parity certification ownership executions are not independently authenticated');
  }
  const rebuilt = buildParityCertificationPreflight({
    repoRoot: expected.repoRoot,
    inputRoot: path.dirname(path.dirname(path.join(expected.repoRoot, document.proofPath))),
    environmentId: expected.environmentId,
    targetHead: expected.targetHead,
    candidateRunId: expected.candidate.runId,
    candidateArtifactDigest: expected.candidate.artifactDigest,
    testExecutions: document.testExecutions
  });
  if (JSON.stringify(document) !== JSON.stringify(rebuilt)) {
    throw new Error('parity certification preflight is stale, substituted, or not bound to current inventory');
  }
  return document;
}

export function parseParityCertificationPreflight(snapshot) {
  return parseJson(snapshot, 'parity certification preflight proof');
}
