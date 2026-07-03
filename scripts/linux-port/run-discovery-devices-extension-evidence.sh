#!/usr/bin/env bash
# W08DiscoveryEvidenceRepair — rerunnable mission-worktree discovery/device/extension evidence.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/docs/linux-port/evidence/mission-001-discovery-devices-extension}"
BUILD_DIR="${BUILD_DIR:-$ROOT/OpenBurnBarDaemon/.build-linux-w08-gate-remediation}"
CONTAINER_BUILD_PATH="/workspace/OpenBurnBarDaemon/.build-linux-w08-gate-remediation"
IMAGE="${OPENBURNBAR_LINUX_TOOLCHAIN_IMAGE:-openburnbar-linux-toolchain:mission-001-fts5}"
DOCKER="${OPENBURNBAR_LINUX_DOCKER:-docker}"

mkdir -p "$EVIDENCE_DIR"

find_binary() {
  local name="$1"
  local found
  found="$(find "$BUILD_DIR" -path "*/debug/$name" -type f -perm -111 2>/dev/null | head -n 1 || true)"
  if [[ -z "$found" ]]; then
    echo "missing built binary: $name under $BUILD_DIR" >&2
    return 127
  fi
  printf '%s\n' "$found"
}

capture_section() {
  local file="$1"
  local title="$2"
  shift 2
  local output rc
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
PARSER_LOG="$EVIDENCE_DIR/avahi-parser-fixture-transcript.txt"
EXT_TEST_LOG="$EVIDENCE_DIR/extension-focused-tests.log"
PATHS_JSON="$EVIDENCE_DIR/linux-xdg-path-evidence.json"
EXT_JSON="$EVIDENCE_DIR/extension-linux-path-sample.json"
MDNS_JSON="$EVIDENCE_DIR/mdns-metadata-sample.json"
PARITY_JSON="$EVIDENCE_DIR/parity-ledger-sample.json"
FIRMWARE_JSON="$EVIDENCE_DIR/pixelclock-firmware-lane-sample.json"
REPAIR_REPORT="$EVIDENCE_DIR/W08-discovery-evidence-repair-report.md"

: >"$CLI_LOG"
: >"$AVahi_LOG"
: >"$PARSER_LOG"

{
  echo "image=$IMAGE"
  echo "build_dir=$BUILD_DIR"
  echo "container_build_path=$CONTAINER_BUILD_PATH"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$BUILD_LOG"

set +e
"$DOCKER" run --rm   -v "$ROOT:/workspace"   -w /workspace/OpenBurnBarDaemon   "$IMAGE"   swift build   --build-path "$CONTAINER_BUILD_PATH"   --product OpenBurnBarCLI   >>"$BUILD_LOG" 2>&1
BUILD_RC=$?
set -e
echo "swift_build_exit_code=$BUILD_RC" >>"$BUILD_LOG"

if [[ "$BUILD_RC" -ne 0 ]]; then
  echo "swift build failed; see $BUILD_LOG" >&2
  exit "$BUILD_RC"
fi

if ! CLI_BIN="$(find_binary OpenBurnBarCLI)"; then
  echo "OpenBurnBarCLI missing after successful build; see $BUILD_LOG" >&2
  exit 127
fi
CONTAINER_CLI="/workspace/OpenBurnBarDaemon/${CLI_BIN#"$ROOT/OpenBurnBarDaemon/"}"
if [[ ! -f "$CLI_BIN" ]]; then
  echo "host CLI binary path missing: $CLI_BIN" >&2
  exit 127
fi
{
  echo "cli_bin=$CLI_BIN"
  echo "container_cli=$CONTAINER_CLI"
  file "$CLI_BIN"
  sha256sum "$CLI_BIN" 2>/dev/null || shasum -a 256 "$CLI_BIN"
} >>"$BUILD_LOG"

run_cli() {
  if [[ ! -x "$CLI_BIN" ]]; then
    echo "fail-closed: OpenBurnBarCLI not executable at $CLI_BIN" >&2
    return 127
  fi
  "$DOCKER" run --rm     -v "$ROOT:/workspace"     -w /workspace     "$IMAGE"     "$CONTAINER_CLI" "$@"
}

capture_section "$CLI_LOG" "local-peer advertise-metadata (json)"   run_cli local-peer advertise-metadata --json || true

capture_section "$CLI_LOG" "local-peer disabled-state (json)"   run_cli local-peer disabled-state --json || true

capture_section "$CLI_LOG" "local-peer disabled-state with OPENBURNBAR_DISABLE_LOCAL_DISCOVERY=1 (json)"   "$DOCKER" run --rm     -e OPENBURNBAR_DISABLE_LOCAL_DISCOVERY=1     -v "$ROOT:/workspace"     -w /workspace     "$IMAGE"     "$CONTAINER_CLI" local-peer disabled-state --json || true

capture_section "$CLI_LOG" "local-peer browse (json, timeout 1)"   run_cli local-peer browse --json --timeout 1 || true

capture_section "$CLI_LOG" "devices parity (json)"   run_cli devices parity --json || true

capture_section "$CLI_LOG" "devices iot cast status (json)"   run_cli devices iot cast status --json || true

capture_section "$CLI_LOG" "devices pixel-clock discover (json)"   run_cli devices pixel-clock discover --json || true

capture_section "$CLI_LOG" "devices pixel-clock firmware-lane (json)"   run_cli devices pixel-clock firmware-lane --json || true

set +e
"$DOCKER" run --rm   -v "$ROOT:/workspace"   -w /workspace   "$IMAGE"   bash -lc 'set -euo pipefail; echo "probe_started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "avahi_browse_path=$(command -v avahi-browse || echo missing)"; echo "avahi_publish_path=$(command -v avahi-publish-service || echo missing)"; dpkg -l avahi-utils 2>/dev/null | tail -n 1 || true; echo "dbus_system_bus=$(test -S /run/dbus/system_bus_socket && echo present || echo missing)"; echo "busctl_path=$(command -v busctl || echo missing)"; echo "udevadm_path=$(command -v udevadm || echo missing)"; echo "serial_devices=$(ls -1 /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | tr "\n" " " || echo none)"'   >>"$AVahi_LOG" 2>&1
AVahi_PROBE_RC=$?
set -e
echo "docker_avahi_probe_exit_code=$AVahi_PROBE_RC" >>"$AVahi_LOG"

LIVE_AVAHI_BLOCKER=""
if ! grep -qE 'avahi_browse_path=/.+avahi-browse' "$AVahi_LOG" 2>/dev/null; then
  LIVE_AVAHI_BLOCKER="avahi-browse not on PATH in toolchain image"
fi
if ! grep -qE 'avahi_publish_path=/.+avahi-publish' "$AVahi_LOG" 2>/dev/null; then
  if [[ -n "$LIVE_AVAHI_BLOCKER" ]]; then
    LIVE_AVAHI_BLOCKER+="; "
  fi
  LIVE_AVAHI_BLOCKER+="avahi-publish-service not on PATH in toolchain image"
fi
if grep -q 'dbus_system_bus=missing' "$AVahi_LOG" 2>/dev/null; then
  if [[ -n "$LIVE_AVAHI_BLOCKER" ]]; then
    LIVE_AVAHI_BLOCKER+="; "
  fi
  LIVE_AVAHI_BLOCKER+="D-Bus system bus socket missing (/run/dbus/system_bus_socket)"
fi

LINUX_XDG_CONFIG="${LINUX_XDG_CONFIG:-/tmp/openburnbar-w08-xdg}"
LINUX_SUPPORT="${LINUX_XDG_CONFIG}/OpenBurnBar"
cat >"$PATHS_JSON" <<JSON
{
  "platform": "linux",
  "xdg_config_home": "${LINUX_XDG_CONFIG}",
  "daemon_support_directory_default": "${LINUX_SUPPORT}",
  "daemon_socket_default": "${LINUX_SUPPORT}/openburnbar-daemon.sock",
  "daemon_auth_token_file_default": "${LINUX_SUPPORT}/daemon-socket-auth-token",
  "swift_source": "OpenBurnBarLinuxPaths.supportDirectoryURL + defaultDaemonSocketURL",
  "override_env": [
    "OPENBURNBAR_DAEMON_SUPPORT_DIR",
    "BURNBAR_DAEMON_SUPPORT_DIR",
    "OPENBURNBAR_DAEMON_SOCKET_PATH",
    "BURNBAR_DAEMON_SOCKET_PATH",
    "XDG_CONFIG_HOME"
  ],
  "note": "Sample uses Linux-style XDG_CONFIG_HOME for mission evidence; host macOS HOME is not claimed as Linux proof."
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

if FIRMWARE_OUT="$(run_cli devices pixel-clock firmware-lane --json 2>/dev/null)"; then
  printf '%s\n' "$FIRMWARE_OUT" >"$FIRMWARE_JSON"
fi

FIXTURE_CONTAINER="/workspace/docs/linux-port/evidence/mission-001-discovery-devices-extension/avahi-parsable-fixture.txt"
capture_section "$CLI_LOG" "local-peer parse-fixture (captured Avahi parsable line, json)"   run_cli local-peer parse-fixture "$FIXTURE_CONTAINER" --json || true

set +e
{
  echo "fixture_path=$FIXTURE_CONTAINER"
  echo "note=Parser/fixture proof via linked OpenBurnBarCLI; not live mDNS."
  run_cli local-peer parse-fixture "$FIXTURE_CONTAINER" --json
} >>"$PARSER_LOG" 2>&1
PARSER_TEST_RC=$?
set -e
echo "local_peer_parse_fixture_exit_code=$PARSER_TEST_RC" >>"$PARSER_LOG"

set +e
if [[ -x "$ROOT/extensions/openburnbar/node_modules/.bin/vitest" ]]; then
  npm --prefix "$ROOT/extensions/openburnbar" run test:unit -- test/daemonClient.test.ts test/controller.test.ts >>"$EXT_TEST_LOG" 2>&1
  EXT_TEST_RC=$?
else
  {
    echo "blocker=extensions/openburnbar/node_modules missing; run npm ci --prefix extensions/openburnbar before extension-focused evidence."
    echo "paths_source=extensions/openburnbar/src/platform/paths.ts (static sample in extension-linux-path-sample.json)"
    echo "health_alert=state/controller.ts -> alertDaemonUnreachable(socketPath)"
  } >>"$EXT_TEST_LOG"
  EXT_TEST_RC=127
fi
set -e
echo "extension_focused_test_exit_code=$EXT_TEST_RC" >>"$EXT_TEST_LOG"

cat >"$REPAIR_REPORT" <<MD
# W08 Discovery Evidence Repair

Lane: \`W08DiscoveryEvidenceRepair\`
Worktree: \`$ROOT\`
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Summary

- CLI evidence is rerunnable from the mission worktree via linked \`OpenBurnBarCLI\` in Docker (\`$CONTAINER_CLI\`).
- Parser/fixture proof is separate from live mDNS: \`local-peer parse-fixture\` on \`avahi-parsable-fixture.txt\` (not live browse/publish).
- Live Avahi browse/publish remains **blocked** when toolchain image lacks Avahi CLI and D-Bus (see \`avahi-environment.txt\`).

## Commands and exit codes

| Step | Exit | Artifact |
| --- | ---: | --- |
| \`swift build --product OpenBurnBarCLI\` (Docker) | $BUILD_RC | \`linux-compile-gate.txt\` |
| OpenBurnBarCLI local-peer/devices transcript | see sections | \`cli-linux-transcript.txt\` |
| Avahi/DBus/hardware probe (toolchain container) | $AVahi_PROBE_RC | \`avahi-environment.txt\` |
| \`OpenBurnBarCLI local-peer parse-fixture avahi-parsable-fixture.txt\` | $PARSER_TEST_RC | \`avahi-parser-fixture-transcript.txt\` |
| Extension focused tests (daemonClient + controller) | $EXT_TEST_RC | \`extension-focused-tests.log\` |

- \`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift\` — \`local-peer parse-fixture\` evidence subcommand
- \`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/BurnBarLinuxLocalPeerDiscovery.swift\` — Avahi octal escape + quoted TXT parsing; parsable field indices
- \`OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarLinuxLocalPeerDiscoveryTests.swift\` — optional XCTest (full \`swift test\` graph blocked on unrelated daemon tests)
- \`scripts/linux-port/run-discovery-devices-extension-evidence.sh\` — fail-closed CLI path, expanded probes, separate live vs fixture evidence
- \`docs/linux-port/evidence/mission-001-discovery-devices-extension/avahi-parsable-fixture.txt\` — captured real Avahi line (fixture only)

## Blockers (fail-closed)

**Live mDNS / Avahi services:** ${LIVE_AVAHI_BLOCKER:-none recorded; inspect avahi-environment.txt}

**Hardware / firmware lane:** PixelClock USB/UART and NetworkManager-dependent flashing not available in default toolchain container; see \`pixelclock-firmware-lane-sample.json\` and \`cli-linux-transcript.txt\` firmware-lane section.

## Contract notes

| Contract | Evidence | Status |
| --- | --- | --- |
| VAL-MDNS-001 | CLI advertise/disabled + parser fixture tests; live browse blocked without Avahi | Partial — parser/fixture improved; live mDNS blocked |
| VAL-DEVICE-001 | CLI pixel-clock discover/parity/firmware-lane | Partial — blocked rows when Avahi/hardware absent |
| VAL-IOT-001 | CLI cast status + parity | Partial — Avahi-dependent adapters blocked |
| VAL-EXTENSION-001 | XDG path samples + extension unit tests | Improved — paths + \`alertDaemonUnreachable\` |

## Artifact index

- \`linux-compile-gate.txt\`
- \`cli-linux-transcript.txt\`
- \`avahi-environment.txt\`
- \`avahi-parser-fixture-transcript.txt\`
- \`avahi-parsable-fixture.txt\`
- \`mdns-metadata-sample.json\`
- \`parity-ledger-sample.json\`
- \`pixelclock-firmware-lane-sample.json\`
- \`linux-xdg-path-evidence.json\`
- \`extension-linux-path-sample.json\`
- \`extension-focused-tests.log\`
MD

echo "w08-discovery-evidence-repair-ok evidence_dir=$EVIDENCE_DIR report=$REPAIR_REPORT"
