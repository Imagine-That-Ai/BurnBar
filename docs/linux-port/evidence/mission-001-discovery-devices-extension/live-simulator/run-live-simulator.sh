#!/usr/bin/env bash
set -euo pipefail
EVIDENCE_DIR="/workspace/docs/linux-port/evidence/mission-001-discovery-devices-extension/live-simulator"
CLI="/workspace/OpenBurnBarDaemon/.build-linux-w08-gate-remediation/aarch64-unknown-linux-gnu/debug/OpenBurnBarCLI"
mkdir -p "$EVIDENCE_DIR"
: >"$EVIDENCE_DIR/avahi-publish-transcript.txt"
: >"$EVIDENCE_DIR/device-endpoint-log.jsonl"

need_apt=0
for cmd in avahi-browse avahi-publish-service avahi-daemon dbus-daemon curl python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    need_apt=1
  fi
done
if [[ "$need_apt" -eq 1 ]]; then
  timeout 300 apt-get update >"$EVIDENCE_DIR/apt-update.log" 2>&1
  DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y avahi-daemon avahi-utils dbus curl python3 >"$EVIDENCE_DIR/apt-install.log" 2>&1
else
  echo "all required packages already present" >"$EVIDENCE_DIR/apt-update.log"
  echo "apt install skipped" >"$EVIDENCE_DIR/apt-install.log"
fi
for cmd in avahi-browse avahi-publish-service avahi-daemon dbus-daemon curl python3; do
  command -v "$cmd" >>"$EVIDENCE_DIR/tool-paths.txt"
done

mkdir -p /run/dbus
dbus-daemon --system --fork --nopidfile
avahi-daemon --daemonize --no-drop-root --debug

python3 "$EVIDENCE_DIR/device-simulator.py" --log "$EVIDENCE_DIR/device-endpoint-log.jsonl" >"$EVIDENCE_DIR/device-simulator.stdout.log" 2>"$EVIDENCE_DIR/device-simulator.stderr.log" &
SIM_PID=$!
PUBLISH_PIDS=()
cleanup() {
  for pid in "${PUBLISH_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  kill "$SIM_PID" 2>/dev/null || true
  avahi-daemon --kill >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 1
publish() {
  avahi-publish-service "$@" >>"$EVIDENCE_DIR/avahi-publish-transcript.txt" 2>&1 &
  PUBLISH_PIDS+=("$!")
}

publish "OpenBurnBar validator" _openburnbar-peer._tcp 48312 "transport=unix-domain" "daemon_version=mission-001" "protocol_version=1" "friendly=OpenBurnBar\\032validator" "note=quoted\\059semi" "path_hint=xdg_config"
publish "OpenBurnBar validator" _openburnbar-peer._tcp 48313 "transport=unix-domain" "daemon_version=mission-001-conflict" "protocol_version=1" "friendly=OpenBurnBar\\032validator" "note=quoted\\059semi" "conflict_attempt=1"
publish "AWTRIX PixelClock" _http._tcp 18081 "id=awtrix-sim" "model=awtrix-light" "openburnbar=1"
publish "OpenBurnBar Cast" _googlecast._tcp 18082 "id=cast-sim" "md=OpenBurnBar"
publish "Home Assistant" _home-assistant._tcp 18083 "version=2026.7-sim" "openburnbar=1"
publish "OpenBurnBar SmartHub Bridge" _openburnbar-peer._tcp 18084 "transport=http" "daemon_version=smarthub-sim" "protocol_version=1" "friendly=SmartHub\\032Bridge"
sleep 2

timeout 20 avahi-browse -rtp _openburnbar-peer._tcp >"$EVIDENCE_DIR/raw-avahi-openburnbar.txt" 2>"$EVIDENCE_DIR/raw-avahi-openburnbar.err"
timeout 20 avahi-browse -rtp _http._tcp >"$EVIDENCE_DIR/raw-avahi-http.txt" 2>"$EVIDENCE_DIR/raw-avahi-http.err"
timeout 20 avahi-browse -rtp _googlecast._tcp >"$EVIDENCE_DIR/raw-avahi-googlecast.txt" 2>"$EVIDENCE_DIR/raw-avahi-googlecast.err"
timeout 20 avahi-browse -rtp _home-assistant._tcp >"$EVIDENCE_DIR/raw-avahi-homeassistant.txt" 2>"$EVIDENCE_DIR/raw-avahi-homeassistant.err"

"$CLI" local-peer browse --json --timeout 2 >"$EVIDENCE_DIR/product-local-peer-browse.json" 2>"$EVIDENCE_DIR/product-local-peer-browse.err"
"$CLI" local-peer parse-fixture "$EVIDENCE_DIR/raw-avahi-openburnbar.txt" --json >"$EVIDENCE_DIR/product-local-peer-parse-live.json" 2>"$EVIDENCE_DIR/product-local-peer-parse-live.err"
"$CLI" devices discover all --json >"$EVIDENCE_DIR/product-devices-discover-all.json" 2>"$EVIDENCE_DIR/product-devices-discover-all.err"
OPENBURNBAR_PIXELCLOCK_URL=http://127.0.0.1:18081 "$CLI" devices pixel-clock control --json >"$EVIDENCE_DIR/product-pixelclock-control.json" 2>"$EVIDENCE_DIR/product-pixelclock-control.err"
OPENBURNBAR_SMARTHUB_BRIDGE_PORT=18084 OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 "$CLI" devices iot smarthub status --json >"$EVIDENCE_DIR/product-smarthub-status.json" 2>"$EVIDENCE_DIR/product-smarthub-status.err"
OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 "$CLI" devices iot homeassistant status --json >"$EVIDENCE_DIR/product-homeassistant-status.json" 2>"$EVIDENCE_DIR/product-homeassistant-status.err"
"$CLI" devices iot cast status --json >"$EVIDENCE_DIR/product-cast-status.json" 2>"$EVIDENCE_DIR/product-cast-status.err"
OPENBURNBAR_SMARTHUB_BRIDGE_PORT=18084 OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 "$CLI" devices parity --json >"$EVIDENCE_DIR/product-parity-ledger.json" 2>"$EVIDENCE_DIR/product-parity-ledger.err"

{
  echo "### $CLI local-peer browse --json --timeout 2"
  cat "$EVIDENCE_DIR/product-local-peer-browse.json"
  cat "$EVIDENCE_DIR/product-local-peer-browse.err"
  echo
  echo "### $CLI local-peer parse-fixture $EVIDENCE_DIR/raw-avahi-openburnbar.txt --json"
  cat "$EVIDENCE_DIR/product-local-peer-parse-live.json"
  cat "$EVIDENCE_DIR/product-local-peer-parse-live.err"
  echo
  echo "### $CLI devices discover all --json"
  cat "$EVIDENCE_DIR/product-devices-discover-all.json"
  cat "$EVIDENCE_DIR/product-devices-discover-all.err"
  echo
  echo "### OPENBURNBAR_PIXELCLOCK_URL=http://127.0.0.1:18081 $CLI devices pixel-clock control --json"
  cat "$EVIDENCE_DIR/product-pixelclock-control.json"
  cat "$EVIDENCE_DIR/product-pixelclock-control.err"
  echo
  echo "### OPENBURNBAR_SMARTHUB_BRIDGE_PORT=18084 OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 $CLI devices iot smarthub status --json"
  cat "$EVIDENCE_DIR/product-smarthub-status.json"
  cat "$EVIDENCE_DIR/product-smarthub-status.err"
  echo
  echo "### OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 $CLI devices iot homeassistant status --json"
  cat "$EVIDENCE_DIR/product-homeassistant-status.json"
  cat "$EVIDENCE_DIR/product-homeassistant-status.err"
  echo
  echo "### $CLI devices iot cast status --json"
  cat "$EVIDENCE_DIR/product-cast-status.json"
  cat "$EVIDENCE_DIR/product-cast-status.err"
  echo
  echo "### OPENBURNBAR_SMARTHUB_BRIDGE_PORT=18084 OPENBURNBAR_HOME_ASSISTANT_URL=http://127.0.0.1:18083 $CLI devices parity --json"
  cat "$EVIDENCE_DIR/product-parity-ledger.json"
  cat "$EVIDENCE_DIR/product-parity-ledger.err"
} >"$EVIDENCE_DIR/product-cli-discovery-control-transcript.txt"

for pid in "${PUBLISH_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
PUBLISH_PIDS=()
sleep 1
timeout 10 avahi-browse -rtp _openburnbar-peer._tcp >"$EVIDENCE_DIR/avahi-teardown-browse.txt" 2>"$EVIDENCE_DIR/avahi-teardown-browse.err" || true

python3 - "$EVIDENCE_DIR" <<'PY'
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
validator_token = r"OpenBurnBar\032validator"

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
