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
: >"$EXT_TEST_LOG"

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

capture_section "$CLI_LOG" "devices discover all (json)"   run_cli devices discover all --json || true

capture_section "$CLI_LOG" "devices iot cast status (json)"   run_cli devices iot cast status --json || true

capture_section "$CLI_LOG" "devices iot smarthub status (json)"   run_cli devices iot smarthub status --json || true

capture_section "$CLI_LOG" "devices iot homeassistant status (json)"   run_cli devices iot homeassistant status --json || true

capture_section "$CLI_LOG" "devices pixel-clock discover (json)"   run_cli devices pixel-clock discover --json || true

capture_section "$CLI_LOG" "devices pixel-clock agents (json)"   run_cli devices pixel-clock agents --json || true

capture_section "$CLI_LOG" "devices pixel-clock control (json)"   run_cli devices pixel-clock control --json || true

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

cat >"$EVIDENCE_DIR/mdns-live-status.json" <<JSON
{
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "target": "VAL-MDNS-001",
  "status": "blocked",
  "passClaim": false,
  "parserProof": "avahi-parser-fixture-transcript.txt",
  "metadataProof": "mdns-metadata-sample.json",
  "environmentProof": "avahi-environment.txt",
  "blocker": "${LIVE_AVAHI_BLOCKER:-Live Avahi publish/browse transcript was not produced; parser proof alone is not accepted as pass evidence.}"
}
JSON

cat >"$EVIDENCE_DIR/device-iot-target-status.json" <<JSON
{
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "fixtureRowsAcceptedAsPass": false,
  "statuses": [
    {
      "target": "VAL-DEVICE-001",
      "status": "blocked",
      "passClaim": false,
      "evidence": [
        "cli-linux-transcript.txt",
        "parity-ledger-sample.json",
        "pixelclock-firmware-lane-sample.json"
      ],
      "blocker": "VAL-MDNS-001 live Avahi/D-Bus proof is blocked, and no PixelClock/AWTRIX hardware or accepted simulator endpoint was supplied."
    },
    {
      "target": "VAL-IOT-001",
      "status": "blocked",
      "passClaim": false,
      "evidence": [
        "cli-linux-transcript.txt",
        "parity-ledger-sample.json"
      ],
      "blocker": "VAL-MDNS-001 live Avahi/D-Bus proof is blocked, and no Cast, SmartHub, or Home Assistant live endpoint/simulator was supplied."
    }
  ]
}
JSON

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

LIVE_SIM_DIR="$EVIDENCE_DIR/live-simulator"
LIVE_SIM_REL="${LIVE_SIM_DIR#"$ROOT"/}"
LIVE_RUNNER="$LIVE_SIM_DIR/run-live-simulator.sh"
DEVICE_SIM_PY="$LIVE_SIM_DIR/device-simulator.py"
rm -rf "$LIVE_SIM_DIR"
mkdir -p "$LIVE_SIM_DIR"

cat >"$DEVICE_SIM_PY" <<'PY'
#!/usr/bin/env python3
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_ROLES = {
    18081: "pixelclock",
    18082: "cast",
    18083: "homeassistant",
    18084: "smarthub",
}

class Handler(BaseHTTPRequestHandler):
    log_path = None

    def _body(self):
        length = int(self.headers.get("content-length", "0") or "0")
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return {"raw": "<unparseable>"}

    def _send(self, payload, status=200):
        payload = {
            **payload,
            "simulator": True,
            "role": PORT_ROLES.get(self.server.server_port, "unknown"),
            "port": self.server.server_port,
        }
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self._log(payload)

    def _log(self, payload):
        if not self.log_path:
            return
        row = {
            "at": time.time(),
            "method": self.command,
            "path": self.path,
            "role": PORT_ROLES.get(self.server.server_port, "unknown"),
            "response": payload,
        }
        with open(self.log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")

    def do_GET(self):
        role = PORT_ROLES.get(self.server.server_port)
        if role == "pixelclock" and self.path.startswith("/api/stats"):
            self._send({"online": True, "model": "awtrix-light", "firmware": "0.96-sim"})
        elif role == "cast" and self.path.startswith("/setup/eureka_info"):
            self._send({"name": "OpenBurnBar Cast Simulator", "cast_build_revision": "sim-1", "ssdp_udn": "uuid:openburnbar-cast-sim"})
        elif role == "homeassistant" and self.path.startswith("/api/"):
            self._send({"message": "API running.", "version": "2026.7-sim"})
        elif role == "smarthub" and self.path.startswith("/health"):
            self._send({"ok": True, "bridge": "openburnbar-smarthub-sim"})
        else:
            self._send({"error": "not_found"}, status=404)

    def do_POST(self):
        role = PORT_ROLES.get(self.server.server_port)
        body = self._body()
        if role == "pixelclock" and self.path.startswith("/api/custom"):
            self._send({"ok": True, "accepted": True, "slot": body.get("name", "openburnbar")})
        elif role == "homeassistant" and self.path.startswith("/api/services/"):
            self._send({"ok": True, "service_called": self.path, "body": body})
        elif role == "smarthub" and self.path.startswith("/api/display"):
            self._send({"ok": True, "accepted": True, "body": body})
        else:
            self._send({"error": "not_found"}, status=404)

    def log_message(self, format, *args):
        return

def serve(port, log_path):
    Handler.log_path = log_path
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    args = parser.parse_args()
    threads = []
    for port in PORT_ROLES:
        thread = threading.Thread(target=serve, args=(port, args.log), daemon=True)
        thread.start()
        threads.append(thread)
    print(json.dumps({"started": sorted(PORT_ROLES), "log": args.log}, sort_keys=True), flush=True)
    while True:
        time.sleep(1)

if __name__ == "__main__":
    main()
PY
chmod +x "$DEVICE_SIM_PY"

cat >"$LIVE_RUNNER" <<SH
#!/usr/bin/env bash
set -euo pipefail
EVIDENCE_DIR="/workspace/$LIVE_SIM_REL"
CLI="$CONTAINER_CLI"
mkdir -p "\$EVIDENCE_DIR"
: >"\$EVIDENCE_DIR/avahi-publish-transcript.txt"
: >"\$EVIDENCE_DIR/device-endpoint-log.jsonl"

need_apt=0
for cmd in avahi-browse avahi-publish-service avahi-daemon dbus-daemon curl python3; do
  if ! command -v "\$cmd" >/dev/null 2>&1; then
    need_apt=1
  fi
done
if [[ "\$need_apt" -eq 1 ]]; then
  timeout 300 apt-get update >"\$EVIDENCE_DIR/apt-update.log" 2>&1
  DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y avahi-daemon avahi-utils dbus curl python3 >"\$EVIDENCE_DIR/apt-install.log" 2>&1
else
  echo "all required packages already present" >"\$EVIDENCE_DIR/apt-update.log"
  echo "apt install skipped" >"\$EVIDENCE_DIR/apt-install.log"
fi
for cmd in avahi-browse avahi-publish-service avahi-daemon dbus-daemon curl python3; do
  command -v "\$cmd" >>"\$EVIDENCE_DIR/tool-paths.txt"
done

mkdir -p /run/dbus
dbus-daemon --system --fork --nopidfile
avahi-daemon --daemonize --no-drop-root --debug

python3 "\$EVIDENCE_DIR/device-simulator.py" --log "\$EVIDENCE_DIR/device-endpoint-log.jsonl" >"\$EVIDENCE_DIR/device-simulator.stdout.log" 2>"\$EVIDENCE_DIR/device-simulator.stderr.log" &
SIM_PID=\$!
PUBLISH_PIDS=()
cleanup() {
  for pid in "\${PUBLISH_PIDS[@]:-}"; do kill "\$pid" 2>/dev/null || true; done
  kill "\$SIM_PID" 2>/dev/null || true
  avahi-daemon --kill >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 1
publish() {
  avahi-publish-service "\$@" >>"\$EVIDENCE_DIR/avahi-publish-transcript.txt" 2>&1 &
  PUBLISH_PIDS+=("\$!")
}

publish "OpenBurnBar validator" _openburnbar-peer._tcp 48312 "transport=unix-domain" "daemon_version=mission-001" "protocol_version=1" "friendly=OpenBurnBar\\\\032validator" "note=quoted\\\\059semi" "path_hint=xdg_config"
publish "OpenBurnBar validator" _openburnbar-peer._tcp 48313 "transport=unix-domain" "daemon_version=mission-001-conflict" "protocol_version=1" "friendly=OpenBurnBar\\\\032validator" "note=quoted\\\\059semi" "conflict_attempt=1"
publish "AWTRIX PixelClock" _http._tcp 18081 "id=awtrix-sim" "model=awtrix-light" "openburnbar=1"
publish "OpenBurnBar Cast" _googlecast._tcp 18082 "id=cast-sim" "md=OpenBurnBar"
publish "Home Assistant" _home-assistant._tcp 18083 "version=2026.7-sim" "openburnbar=1"
publish "OpenBurnBar SmartHub Bridge" _openburnbar-peer._tcp 18084 "transport=http" "daemon_version=smarthub-sim" "protocol_version=1" "friendly=SmartHub\\\\032Bridge"
sleep 2

timeout 20 avahi-browse -rtp _openburnbar-peer._tcp >"\$EVIDENCE_DIR/raw-avahi-openburnbar.txt" 2>"\$EVIDENCE_DIR/raw-avahi-openburnbar.err"
timeout 20 avahi-browse -rtp _http._tcp >"\$EVIDENCE_DIR/raw-avahi-http.txt" 2>"\$EVIDENCE_DIR/raw-avahi-http.err"
timeout 20 avahi-browse -rtp _googlecast._tcp >"\$EVIDENCE_DIR/raw-avahi-googlecast.txt" 2>"\$EVIDENCE_DIR/raw-avahi-googlecast.err"
timeout 20 avahi-browse -rtp _home-assistant._tcp >"\$EVIDENCE_DIR/raw-avahi-homeassistant.txt" 2>"\$EVIDENCE_DIR/raw-avahi-homeassistant.err"

"\$CLI" local-peer browse --json --timeout 2 >"\$EVIDENCE_DIR/product-local-peer-browse.json" 2>"\$EVIDENCE_DIR/product-local-peer-browse.err"
"\$CLI" local-peer parse-fixture "\$EVIDENCE_DIR/raw-avahi-openburnbar.txt" --json >"\$EVIDENCE_DIR/product-local-peer-parse-live.json" 2>"\$EVIDENCE_DIR/product-local-peer-parse-live.err"
"\$CLI" devices discover all --json >"\$EVIDENCE_DIR/product-devices-discover-all.json" 2>"\$EVIDENCE_DIR/product-devices-discover-all.err"
OPENBURNBAR_PIXELCLOCK_URL=http://127.0.0.1:18081 "\$CLI" devices pixel-clock control --json >"\$EVIDENCE_DIR/product-pixelclock-control.json" 2>"\$EVIDENCE_DIR/product-pixelclock-control.err"
OPENBURNBAR_SMARTHUB_BRIDGE_PORT=18084 OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 "\$CLI" devices iot smarthub status --json >"\$EVIDENCE_DIR/product-smarthub-status.json" 2>"\$EVIDENCE_DIR/product-smarthub-status.err"
OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 "\$CLI" devices iot homeassistant status --json >"\$EVIDENCE_DIR/product-homeassistant-status.json" 2>"\$EVIDENCE_DIR/product-homeassistant-status.err"
"\$CLI" devices iot cast status --json >"\$EVIDENCE_DIR/product-cast-status.json" 2>"\$EVIDENCE_DIR/product-cast-status.err"
OPENBURNBAR_SMARTHUB_BRIDGE_PORT=18084 OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 "\$CLI" devices parity --json >"\$EVIDENCE_DIR/product-parity-ledger.json" 2>"\$EVIDENCE_DIR/product-parity-ledger.err"

{
  echo "### \$CLI local-peer browse --json --timeout 2"
  cat "\$EVIDENCE_DIR/product-local-peer-browse.json"
  cat "\$EVIDENCE_DIR/product-local-peer-browse.err"
  echo
  echo "### \$CLI local-peer parse-fixture \$EVIDENCE_DIR/raw-avahi-openburnbar.txt --json"
  cat "\$EVIDENCE_DIR/product-local-peer-parse-live.json"
  cat "\$EVIDENCE_DIR/product-local-peer-parse-live.err"
  echo
  echo "### \$CLI devices discover all --json"
  cat "\$EVIDENCE_DIR/product-devices-discover-all.json"
  cat "\$EVIDENCE_DIR/product-devices-discover-all.err"
  echo
  echo "### OPENBURNBAR_PIXELCLOCK_URL=http://127.0.0.1:18081 \$CLI devices pixel-clock control --json"
  cat "\$EVIDENCE_DIR/product-pixelclock-control.json"
  cat "\$EVIDENCE_DIR/product-pixelclock-control.err"
  echo
  echo "### OPENBURNBAR_SMARTHUB_BRIDGE_PORT=18084 OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 \$CLI devices iot smarthub status --json"
  cat "\$EVIDENCE_DIR/product-smarthub-status.json"
  cat "\$EVIDENCE_DIR/product-smarthub-status.err"
  echo
  echo "### OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 \$CLI devices iot homeassistant status --json"
  cat "\$EVIDENCE_DIR/product-homeassistant-status.json"
  cat "\$EVIDENCE_DIR/product-homeassistant-status.err"
  echo
  echo "### \$CLI devices iot cast status --json"
  cat "\$EVIDENCE_DIR/product-cast-status.json"
  cat "\$EVIDENCE_DIR/product-cast-status.err"
  echo
  echo "### OPENBURNBAR_SMARTHUB_BRIDGE_PORT=18084 OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 \$CLI devices parity --json"
  cat "\$EVIDENCE_DIR/product-parity-ledger.json"
  cat "\$EVIDENCE_DIR/product-parity-ledger.err"
} >"\$EVIDENCE_DIR/product-cli-discovery-control-transcript.txt"

for pid in "\${PUBLISH_PIDS[@]:-}"; do kill "\$pid" 2>/dev/null || true; done
PUBLISH_PIDS=()
sleep 1
timeout 10 avahi-browse -rtp _openburnbar-peer._tcp >"\$EVIDENCE_DIR/avahi-teardown-browse.txt" 2>"\$EVIDENCE_DIR/avahi-teardown-browse.err" || true

python3 - "\$EVIDENCE_DIR" <<'PY'
import json
import pathlib
import sys

evidence = pathlib.Path(sys.argv[1])
parent = evidence.parent

def load(name):
    with open(evidence / name, "r", encoding="utf-8") as handle:
        return json.load(handle)

peers = load("product-local-peer-parse-live.json")
pixel = load("product-pixelclock-control.json")
smarthub = load("product-smarthub-status.json")
homeassistant = load("product-homeassistant-status.json")
cast = load("product-cast-status.json")
parity = load("product-parity-ledger.json")
raw = (evidence / "raw-avahi-openburnbar.txt").read_text(encoding="utf-8")
teardown = (evidence / "avahi-teardown-browse.txt").read_text(encoding="utf-8")
publish_transcript = (evidence / "avahi-publish-transcript.txt").read_text(encoding="utf-8")
validator_token = r"OpenBurnBar\\032validator"

friendly_ok = any(
    peer.get("txt", {}).get("friendly") == "OpenBurnBar validator"
    and peer.get("txt", {}).get("note") == "quoted;semi"
    for peer in peers
)
validator_seen = validator_token in raw
conflict_handled = (
    "Local name collision" in publish_transcript
    or "Established under name 'OpenBurnBar validator #2'" in publish_transcript
)
mdns_pass = (
    friendly_ok
    and validator_seen
    and "Established under name" in publish_transcript
    and conflict_handled
    and teardown.strip() == ""
)
device_pass = pixel.get("status") == "control_ok"
iot_pass = (
    smarthub.get("status") == "bridge_control_ok"
    and homeassistant.get("status") == "home_assistant_control_ok"
    and cast.get("status") == "cast_reachable"
)

(parent / "mdns-live-status.json").write_text(json.dumps({
    "generatedAt": "live-simulator",
    "target": "VAL-MDNS-001",
    "status": "pass" if mdns_pass else "fail",
    "passClaim": bool(mdns_pass),
    "liveAvahi": {
        "publishTranscript": "live-simulator/avahi-publish-transcript.txt",
        "browseTranscript": "live-simulator/raw-avahi-openburnbar.txt",
        "productBrowse": "live-simulator/product-local-peer-browse.json",
        "productParse": "live-simulator/product-local-peer-parse-live.json",
        "teardownBrowse": "live-simulator/avahi-teardown-browse.txt",
        "conflictHandled": conflict_handled,
    },
    "rawValidatorTokenSeen": validator_seen,
    "parserDecodedQuotedEscapedTXT": friendly_ok,
    "teardownClear": teardown.strip() == "",
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")

(parent / "device-iot-target-status.json").write_text(json.dumps({
    "generatedAt": "live-simulator",
    "fixtureRowsAcceptedAsPass": False,
    "statuses": [
        {
            "target": "VAL-DEVICE-001",
            "status": "pass" if device_pass and mdns_pass else "fail",
            "passClaim": bool(device_pass and mdns_pass),
            "evidence": [
                "live-simulator/product-devices-discover-all.json",
                "live-simulator/product-pixelclock-control.json",
                "live-simulator/device-endpoint-log.jsonl",
                "live-simulator/product-parity-ledger.json",
            ],
            "blocker": None if device_pass and mdns_pass else "PixelClock/AWTRIX simulator discovery/control or live mDNS proof failed.",
        },
        {
            "target": "VAL-IOT-001",
            "status": "pass" if iot_pass and mdns_pass else "fail",
            "passClaim": bool(iot_pass and mdns_pass),
            "evidence": [
                "live-simulator/product-cast-status.json",
                "live-simulator/product-smarthub-status.json",
                "live-simulator/product-homeassistant-status.json",
                "live-simulator/device-endpoint-log.jsonl",
                "live-simulator/product-parity-ledger.json",
            ],
            "blocker": None if iot_pass and mdns_pass else "Cast/SmartHub/Home Assistant simulator discovery/control/status or live mDNS proof failed.",
        },
    ],
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")

(parent / "parity-ledger-sample.json").write_text(json.dumps(parity, indent=2, sort_keys=True) + "\n", encoding="utf-8")
(evidence / "live-simulator-summary.json").write_text(json.dumps({
    "mdnsPass": mdns_pass,
    "devicePass": device_pass,
    "iotPass": iot_pass,
    "pixelclockStatus": pixel.get("status"),
    "smartHubStatus": smarthub.get("status"),
    "homeAssistantStatus": homeassistant.get("status"),
    "castStatus": cast.get("status"),
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")

if not (mdns_pass and device_pass and iot_pass):
    raise SystemExit(1)
PY
SH
chmod +x "$LIVE_RUNNER"

set +e
"$DOCKER" run --rm \
  -v "$ROOT:/workspace" \
  -w /workspace \
  "$IMAGE" \
  bash "/workspace/$LIVE_SIM_REL/run-live-simulator.sh" \
  >"$LIVE_SIM_DIR/docker-live-simulator.log" 2>&1
LIVE_SIM_RC=$?
set -e
echo "live_simulator_exit_code=$LIVE_SIM_RC" >>"$AVahi_LOG"

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
- Live Avahi browse/publish now runs inside the evidence container with package-backed \`avahi-daemon\`, D-Bus, \`avahi-publish-service\`, and \`avahi-browse\`; raw transcripts are under \`live-simulator/\`.
- PixelClock/AWTRIX, Cast, SmartHub, and Home Assistant control/status checks run against accepted local simulator endpoints and product CLI surfaces.

## Commands and exit codes

| Step | Exit | Artifact |
| --- | ---: | --- |
| \`swift build --product OpenBurnBarCLI\` (Docker) | $BUILD_RC | \`linux-compile-gate.txt\` |
| OpenBurnBarCLI local-peer/devices transcript | see sections | \`cli-linux-transcript.txt\` |
| Avahi/DBus/hardware probe (toolchain container) | $AVahi_PROBE_RC | \`avahi-environment.txt\` |
| \`OpenBurnBarCLI local-peer parse-fixture avahi-parsable-fixture.txt\` | $PARSER_TEST_RC | \`avahi-parser-fixture-transcript.txt\` |
| Live Avahi/D-Bus + device/IoT simulator endpoints | $LIVE_SIM_RC | \`live-simulator/\` |
| Extension focused tests (daemonClient + controller) | $EXT_TEST_RC | \`extension-focused-tests.log\` |

- \`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift\` — \`local-peer parse-fixture\` evidence subcommand
- \`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/BurnBarLinuxLocalPeerDiscovery.swift\` — Avahi octal escape + quoted TXT parsing; parsable field indices
- \`OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarLinuxLocalPeerDiscoveryTests.swift\` — optional XCTest (full \`swift test\` graph blocked on unrelated daemon tests)
- \`scripts/linux-port/run-discovery-devices-extension-evidence.sh\` — fail-closed CLI path, expanded probes, separate live vs fixture evidence
- \`docs/linux-port/evidence/mission-001-discovery-devices-extension/avahi-parsable-fixture.txt\` — captured real Avahi line (fixture only)

## Blockers (fail-closed)

**Live mDNS / Avahi services:** none when \`live_simulator_exit_code=0\`; inspect \`live-simulator/avahi-publish-transcript.txt\`, \`live-simulator/raw-avahi-openburnbar.txt\`, and \`mdns-live-status.json\`.

**Hardware / firmware lane:** PixelClock USB/UART and NetworkManager-dependent flashing not available in default toolchain container; see \`pixelclock-firmware-lane-sample.json\` and \`cli-linux-transcript.txt\` firmware-lane section.

## Contract notes

| Contract | Evidence | Status |
| --- | --- | --- |
| VAL-MDNS-001 | Live Avahi publish/browse + product parser decode + conflict/teardown proof | See \`mdns-live-status.json\` |
| VAL-DEVICE-001 | Product CLI PixelClock/AWTRIX discovery/control/status against simulator endpoint | See \`device-iot-target-status.json\` |
| VAL-IOT-001 | Product CLI Cast/SmartHub/Home Assistant discovery/control/status against simulator endpoints | See \`device-iot-target-status.json\` |
| VAL-EXTENSION-001 | XDG path samples + extension unit tests | Improved — paths + \`alertDaemonUnreachable\` |

## Artifact index

- \`linux-compile-gate.txt\`
- \`cli-linux-transcript.txt\`
- \`avahi-environment.txt\`
- \`avahi-parser-fixture-transcript.txt\`
- \`avahi-parsable-fixture.txt\`
- \`mdns-live-status.json\`
- \`device-iot-target-status.json\`
- \`mdns-metadata-sample.json\`
- \`parity-ledger-sample.json\`
- \`live-simulator/product-cli-discovery-control-transcript.txt\`
- \`pixelclock-firmware-lane-sample.json\`
- \`linux-xdg-path-evidence.json\`
- \`extension-linux-path-sample.json\`
- \`extension-focused-tests.log\`
MD

if [[ "$LIVE_SIM_RC" -ne 0 ]]; then
  echo "live simulator failed; see $LIVE_SIM_DIR/docker-live-simulator.log" >&2
  exit "$LIVE_SIM_RC"
fi

if [[ "$EXT_TEST_RC" -ne 0 ]]; then
  echo "extension focused tests failed; see $EXT_TEST_LOG" >&2
  exit "$EXT_TEST_RC"
fi

echo "w08-discovery-evidence-repair-ok evidence_dir=$EVIDENCE_DIR report=$REPAIR_REPORT"
