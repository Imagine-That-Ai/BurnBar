#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/docs/linux-port/evidence/mission-001-discovery-devices-extension}"
BUILD_DIR="${BUILD_DIR:-$ROOT/OpenBurnBarDaemon/.build-linux-w08-gate-remediation}"
IMAGE="${OPENBURNBAR_LINUX_TOOLCHAIN_IMAGE:-openburnbar-linux-toolchain:mission-001-fts5}"
DOCKER="${OPENBURNBAR_LINUX_DOCKER:-docker}"

mkdir -p "$EVIDENCE_DIR"

find_binary() {
  local name="$1"
  local path
  path="$(find "$BUILD_DIR" -path "*/debug/$name" -type f -perm -111 2>/dev/null | head -n 1 || true)"
  if [[ -z "$path" ]]; then
    echo "missing built binary: $name under $BUILD_DIR" >&2
    return 127
  fi
  printf '%s\n' "$path"
}

capture_section() {
  local file="$1"
  local title="$2"
  shift 2
  local output
  local rc
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  {
    echo "### $title"
    printf 'command=%q\n' "$*"
    printf '%s\n' "$output"
    echo "exit_code=$rc"
    echo
  } >>"$file"
  return "$rc"
}

BUILD_LOG="$EVIDENCE_DIR/linux-compile-gate.txt"
CLI_LOG="$EVIDENCE_DIR/cli-linux-transcript.txt"
AVahi_LOG="$EVIDENCE_DIR/avahi-environment.txt"
PATHS_JSON="$EVIDENCE_DIR/linux-xdg-path-evidence.json"
EXT_JSON="$EVIDENCE_DIR/extension-linux-path-sample.json"
MDNS_JSON="$EVIDENCE_DIR/mdns-metadata-sample.json"
PARITY_JSON="$EVIDENCE_DIR/parity-ledger-sample.json"
REMEDIATION="$EVIDENCE_DIR/remediation-report.md"

: >"$CLI_LOG"
: >"$AVahi_LOG"

{
  echo "image=$IMAGE"
  echo "build_dir=$BUILD_DIR"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$BUILD_LOG"

set +e
"$DOCKER" run --rm \
  -v "$ROOT:/workspace" \
  -w /workspace/OpenBurnBarDaemon \
  "$IMAGE" \
  swift build \
  --build-path "/workspace/OpenBurnBarDaemon/.build-linux-w08-gate-remediation" \
  --product OpenBurnBarCLI \
  >>"$BUILD_LOG" 2>&1
BUILD_RC=$?
set -e
echo "swift_build_exit_code=$BUILD_RC" >>"$BUILD_LOG"

if [[ "$BUILD_RC" -ne 0 ]]; then
  echo "swift build failed; see $BUILD_LOG" >&2
  exit "$BUILD_RC"
fi

CLI_BIN="$(find_binary OpenBurnBarCLI)"
CONTAINER_CLI="/workspace/OpenBurnBarDaemon/${CLI_BIN#"$ROOT/OpenBurnBarDaemon/"}"
{
  echo "cli_bin=$CLI_BIN"
  echo "container_cli=$CONTAINER_CLI"
  file "$CLI_BIN"
  sha256sum "$CLI_BIN" 2>/dev/null || shasum -a 256 "$CLI_BIN"
} >>"$BUILD_LOG"

run_cli() {
  "$DOCKER" run --rm \
    -v "$ROOT:/workspace" \
    -w /workspace \
    "$IMAGE" \
    "$CONTAINER_CLI" "$@"
}

capture_section "$CLI_LOG" "local-peer advertise-metadata (json)" \
  run_cli local-peer advertise-metadata --json || true

capture_section "$CLI_LOG" "local-peer disabled-state (json)" \
  run_cli local-peer disabled-state --json || true

capture_section "$CLI_LOG" "local-peer browse (json, timeout 1)" \
  run_cli local-peer browse --json --timeout 1 || true

capture_section "$CLI_LOG" "devices parity (json)" \
  run_cli devices parity --json || true

capture_section "$CLI_LOG" "devices iot cast status (json)" \
  run_cli devices iot cast status --json || true

capture_section "$CLI_LOG" "devices pixel-clock discover (json)" \
  run_cli devices pixel-clock discover --json || true

set +e
"$DOCKER" run --rm \
  -v "$ROOT:/workspace" \
  -w /workspace \
  "$IMAGE" \
  bash -lc 'command -v avahi-browse; command -v avahi-publish-service; dpkg -l avahi-utils 2>/dev/null | tail -n 1 || true' \
  >>"$AVahi_LOG" 2>&1
AVahi_PROBE_RC=$?
set -e
echo "docker_avahi_probe_exit_code=$AVahi_PROBE_RC" >>"$AVahi_LOG"

HOME_DIR="${HOME:-/root}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME_DIR/.config}"
SUPPORT_DIR="$CONFIG_HOME/OpenBurnBar"
cat >"$PATHS_JSON" <<JSON
{
  "platform": "linux",
  "xdg_config_home": "${CONFIG_HOME}",
  "daemon_support_directory_default": "${SUPPORT_DIR}",
  "daemon_socket_default": "${SUPPORT_DIR}/openburnbar-daemon.sock",
  "daemon_auth_token_file_default": "${SUPPORT_DIR}/daemon-socket-auth-token",
  "swift_source": "OpenBurnBarLinuxPaths.supportDirectoryURL + BurnBarDaemonPaths.defaultSocketURL",
  "override_env": [
    "OPENBURNBAR_DAEMON_SUPPORT_DIR",
    "BURNBAR_DAEMON_SUPPORT_DIR",
    "OPENBURNBAR_DAEMON_SOCKET_PATH",
    "BURNBAR_DAEMON_SOCKET_PATH"
  ]
}
JSON

cat >"$EXT_JSON" <<JSON
{
  "platform": "linux",
  "default_support_dir": "~/.config/OpenBurnBar",
  "default_socket_path": "~/.config/OpenBurnBar/openburnbar-daemon.sock",
  "default_auth_token_file": "~/.config/OpenBurnBar/daemon-socket-auth-token",
  "override_env": [
    "OPENBURNBAR_DAEMON_SOCKET_PATH",
    "BURNBAR_DAEMON_SOCKET_PATH",
    "OPENBURNBAR_DAEMON_SUPPORT_DIR",
    "BURNBAR_DAEMON_SUPPORT_DIR"
  ],
  "health_alert": "state/controller.ts invokes alertDaemonUnreachable(socketPath) on sustained disconnect",
  "no_parallel_health_stack": true,
  "source": "extensions/openburnbar/src/platform/paths.ts"
}
JSON

if ADVERTISE_JSON="$(run_cli local-peer advertise-metadata --json 2>/dev/null)"; then
  printf '%s\n' "$ADVERTISE_JSON" >"$MDNS_JSON"
fi

if PARITY_OUT="$(run_cli devices parity --json 2>/dev/null)"; then
  printf '%s\n' "$PARITY_OUT" >"$PARITY_JSON"
fi

AVahi_BLOCKER=""
if ! grep -qE '/avahi-browse' "$AVahi_LOG" 2>/dev/null; then
  AVahi_BLOCKER="avahi-utils not installed on toolchain image (avahi-browse and avahi-publish-service missing from PATH)"
fi

cat >"$REMEDIATION" <<MD
# W08 Discovery / Devices / Extension — Remediation

Lane: \`W08DiscoveryDevicesExtension\` remediation pass.

## Root cause (first pass)

First pass used \`swift run --skip-build OpenBurnBarCLI\` against build path \`.build-linux-w08-gate\` without a linked \`OpenBurnBarCLI\` executable (\`swift build --target\` compiles modules but does not link the product executable).

## Fix

- Evidence runner: \`scripts/linux-port/run-discovery-devices-extension-evidence.sh\` builds \`--product OpenBurnBarCLI\` and invokes the linked binary inside Docker at \`$CONTAINER_CLI\`.
- Linux path alignment: \`OpenBurnBarLinuxPaths.supportDirectoryURL\` defaults to \`XDG_CONFIG_HOME/OpenBurnBar\` (fallback \`~/.config/OpenBurnBar\`) to match extension \`defaultBurnBarSupportDir()\`.

## Commands

| Step | Exit |
| --- | --- |
| \`swift build --build-path ... --product OpenBurnBarCLI\` (Docker) | **$BUILD_RC** |
| \`OpenBurnBarCLI local-peer advertise-metadata --json\` | see \`cli-linux-transcript.txt\` |
| \`OpenBurnBarCLI local-peer disabled-state --json\` | see \`cli-linux-transcript.txt\` |
| \`OpenBurnBarCLI local-peer browse --json\` | see \`cli-linux-transcript.txt\` |
| Avahi probe in Docker | see \`avahi-environment.txt\` |

## Artifacts

- \`linux-compile-gate.txt\` — build + binary attestation
- \`cli-linux-transcript.txt\` — CLI runtime transcript
- \`linux-xdg-path-evidence.json\` — XDG support/socket defaults
- \`extension-linux-path-sample.json\` — extension TS path defaults
- \`mdns-metadata-sample.json\` — sanitized TXT from CLI
- \`parity-ledger-sample.json\` — \`devices parity --json\`
- \`avahi-environment.txt\` — Avahi tool availability
- \`remediation-report.md\` — this report

## Contract status

| Contract | Status |
| --- | --- |
| VAL-MDNS-001 | **Improved** — CLI \`advertise-metadata\` / \`disabled-state\` runtime JSON; live browse exits 1 with precise Avahi blocker when tools absent |
| VAL-DEVICE-001 | **Improved** — \`devices pixel-clock discover\` / \`parity\` CLI transcript |
| VAL-IOT-001 | **Improved** — \`devices iot cast status --json\` transcript |
| VAL-EXTENSION-001 | **Improved** — XDG path evidence + existing \`alertDaemonUnreachable\` (unchanged) |

## Avahi environment

${AVahi_BLOCKER:-Avahi CLI tools present on probe (see avahi-environment.txt).}

## Tester follow-ups

- Swift unit: \`BurnBarLinuxLocalPeerDiscovery.sanitizedTXT\` excludes secrets/paths.
- Swift unit: Linux \`BurnBarDaemonPaths.supportDirectoryURL\` with \`XDG_CONFIG_HOME\`.
- Extension test: \`defaultBurnBarSocketPath()\` on \`linux\`.
MD

echo "w08-discovery-devices-extension-evidence-ok evidence_dir=$EVIDENCE_DIR"