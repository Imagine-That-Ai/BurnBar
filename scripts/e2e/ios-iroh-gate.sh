#!/usr/bin/env bash
#
# Gate C/D runner for the physical iOS Hermes -> iroh hosted-relay path.
# It starts one debug Mac host for the whole sequence, executes N clean
# completions by calling scripts/e2e/ios-iroh-chat.sh, records a per-run
# Firestore audit export, and stops on the first failure.
#
# The --interfaces plan is comma-separated. If the plan has fewer entries than
# --runs, the final interface entry is repeated. Example:
#
#   scripts/e2e/ios-iroh-gate.sh \
#     --uid 6YTomKTKdQdpvIJgmz6VTIrrQ4w1 \
#     --runs 10 \
#     --interfaces wifi,cellular
#
# That command requires run 1 to audit as wifi and runs 2-10 to audit as
# cellular. Use a longer explicit plan when switching topologies mid-sequence.
#
# By default the gate resolves --model auto from the live BurnBar daemon
# /v1/models catalog and skips local-only runtimes such as Ollama.

set -euo pipefail

cd "$(dirname "$0")/../.."

UID_VALUE=""
RUNS=10
INTERFACES="cellular"
OUTPUT_DIR="docs/runbooks/iroh-dev-validation/ios-iroh-gate-$(date -u '+%Y%m%dT%H%M%SZ')"
PROJECT="burnbar"
DEVICE_ID="AFB07C15-AD18-5EFA-AD1C-CADB4F286797"
DEVICE_WAIT_SECONDS=0
DEVICE_WAIT_INTERVAL=5
MODEL="auto"
PROMPT="Reply exactly: ok"
RELAY_URL="https://use1-1.relay.alberto8793.burnbar.iroh.link/"
POLL_SECONDS=420
POLL_INTERVAL=10
START_HOST=1
MAC_HOST_APP="build/DerivedData-mac/Build/Products/Debug/OpenBurnBar.app/Contents/MacOS/OpenBurnBar"
MAC_HOST_LOG=""

usage() {
    cat <<'USAGE'
Usage: scripts/e2e/ios-iroh-gate.sh --uid <firebase-uid> [options]

Options:
  --uid <uid>                  Firebase UID to read iroh_audit_events from.
  --runs <count>               Number of clean completions required. Default: 10
  --interfaces <csv>           Expected networkInterfaces plan. Default: cellular
  --output-dir <path>          Directory for run logs and Firestore exports.
  --project <id>               Firebase/GCP project. Default: burnbar
  --device <id>                CoreDevice identifier. Default: current dev iPhone
  --wait-for-device-seconds <n>
                               Wait for CoreDevice tunnel before failing. Default: 0
  --wait-for-device-interval <n>
                               Poll interval while waiting for device. Default: 5
  --relay-url <url>            Hosted relay URL.
  --model <id|auto>            Hermes model for each run. Default: auto from live /v1/models.
  --prompt <text>              Hidden E2E prompt text for each run.
  --poll-seconds <seconds>     Max Firestore polling time per run. Default: 420
  --poll-interval <seconds>    Poll interval. Default: 10
  --mac-host-app <path>        Debug Mac host executable to start.
  --mac-host-log <path>        Log path for the started Mac host.
  --no-start-host              Do not start/stop a Mac host process.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --uid) UID_VALUE="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --interfaces) INTERFACES="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --project) PROJECT="$2"; shift 2 ;;
        --device) DEVICE_ID="$2"; shift 2 ;;
        --wait-for-device-seconds) DEVICE_WAIT_SECONDS="$2"; shift 2 ;;
        --wait-for-device-interval) DEVICE_WAIT_INTERVAL="$2"; shift 2 ;;
        --relay-url) RELAY_URL="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --prompt) PROMPT="$2"; shift 2 ;;
        --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
        --mac-host-app) MAC_HOST_APP="$2"; shift 2 ;;
        --mac-host-log) MAC_HOST_LOG="$2"; shift 2 ;;
        --no-start-host) START_HOST=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "${UID_VALUE}" ]]; then
    echo "Missing required --uid <firebase-uid>." >&2
    exit 2
fi
if ! [[ "${RUNS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "--runs must be a positive integer." >&2
    exit 2
fi
if ! [[ "${DEVICE_WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
    echo "--wait-for-device-seconds must be a non-negative integer." >&2
    exit 2
fi
if ! [[ "${DEVICE_WAIT_INTERVAL}" =~ ^[1-9][0-9]*$ ]]; then
    echo "--wait-for-device-interval must be a positive integer." >&2
    exit 2
fi

IFS=',' read -r -a INTERFACE_PLAN <<<"${INTERFACES}"
if [[ "${#INTERFACE_PLAN[@]}" -eq 0 ]]; then
    echo "--interfaces must include at least one interface name." >&2
    exit 2
fi
LAST_INTERFACE_PLAN_INDEX=$((${#INTERFACE_PLAN[@]} - 1))

HOST_PID=""
trap 'if [[ -n "${HOST_PID}" ]] && kill -0 "${HOST_PID}" >/dev/null 2>&1; then kill "${HOST_PID}" >/dev/null 2>&1 || true; fi' EXIT

wait_for_device_tunnel() {
    DEVICE_DETAILS="$(xcrun devicectl device info details --device "${DEVICE_ID}" 2>&1 || true)"
    if grep -q "tunnelState: connected" <<<"${DEVICE_DETAILS}"; then
        return 0
    fi
    if [[ "${DEVICE_WAIT_SECONDS}" -gt 0 ]]; then
        echo "Waiting up to ${DEVICE_WAIT_SECONDS}s for CoreDevice tunnel: ${DEVICE_ID}" >&2
        local deadline=$((SECONDS + DEVICE_WAIT_SECONDS))
        while [[ "${SECONDS}" -lt "${deadline}" ]]; do
            sleep "${DEVICE_WAIT_INTERVAL}"
            DEVICE_DETAILS="$(xcrun devicectl device info details --device "${DEVICE_ID}" 2>&1 || true)"
            if grep -q "tunnelState: connected" <<<"${DEVICE_DETAILS}"; then
                return 0
            fi
        done
    fi
    return 1
}

resolve_model_if_needed() {
    local normalized
    normalized="$(printf '%s' "${MODEL}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${normalized}" != "auto" && "${normalized}" != "default" ]]; then
        return 0
    fi
    local models_json
    if ! models_json="$(curl -fsS --max-time 8 "http://127.0.0.1:8317/v1/models")"; then
        echo "Could not resolve --model auto from http://127.0.0.1:8317/v1/models." >&2
        echo "Start the BurnBar daemon gateway or pass --model <advertised-model-id>." >&2
        exit 1
    fi
    MODEL="$(
        jq -r '
          [ .data[]?
            | select((.route_eligible // true) == true)
            | select(([
                (.id // ""),
                (.owned_by // ""),
                (.provider_id // ""),
                (.providerID // ""),
                (.provider_name // ""),
                (.providerName // ""),
                (.source_kind // ""),
                (.capabilities // [] | join(" "))
              ] | join(" ") | test("ollama|lmstudio|lm studio|local"; "i") | not))
          ][0].id // empty
        ' <<<"${models_json}"
    )"
    if [[ -z "${MODEL}" ]]; then
        echo "No non-local route-eligible model is currently advertised by http://127.0.0.1:8317/v1/models." >&2
        jq -r '.data[]?.id // empty' <<<"${models_json}" >&2
        exit 1
    fi
    echo "Resolved --model auto to live BurnBar model: ${MODEL}"
}

verify_mac_host_signing() {
    local app_bundle
    app_bundle="${MAC_HOST_APP%/Contents/MacOS/OpenBurnBar}"
    if [[ "${app_bundle}" == "${MAC_HOST_APP}" || ! -d "${app_bundle}" ]]; then
        echo "Mac host path must point inside an OpenBurnBar.app bundle: ${MAC_HOST_APP}" >&2
        exit 1
    fi

    local signature
    if ! signature="$(codesign -dv --verbose=4 "${app_bundle}" 2>&1)"; then
        echo "Mac host is not code signed: ${app_bundle}" >&2
        echo "Build a signed Debug app; Firebase Auth keychain access is required for iroh pairing publication." >&2
        exit 1
    fi
    if grep -q "TeamIdentifier=not set" <<<"${signature}" || ! grep -q "TeamIdentifier=" <<<"${signature}"; then
        echo "Mac host is unsigned for Firebase/Auth purposes: ${app_bundle}" >&2
        echo "Build without CODE_SIGNING_ALLOWED=NO and pass the signed app via --mac-host-app." >&2
        exit 1
    fi

    local entitlements
    entitlements="$(codesign -d --entitlements :- "${app_bundle}" 2>/dev/null || true)"
    if ! grep -q "keychain-access-groups" <<<"${entitlements}"; then
        echo "Mac host is missing keychain-access-groups entitlement: ${app_bundle}" >&2
        echo "Firebase Auth cannot read the signed-in user without the app entitlement." >&2
        exit 1
    fi
}

if ! wait_for_device_tunnel; then
    echo "Device is not launchable through CoreDevice: ${DEVICE_ID}" >&2
    echo "For the cellular gate, connect the iPhone to this Mac over USB, unlock it, accept Trust prompts, keep Wi-Fi off, and rerun this command." >&2
    echo "${DEVICE_DETAILS}" | sed -n '/connectionProperties:/,/capabilities:/p' >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
SUMMARY_JSONL="${OUTPUT_DIR}/summary.jsonl"
SUMMARY_MD="${OUTPUT_DIR}/README.md"
if [[ -z "${MAC_HOST_LOG}" ]]; then
    MAC_HOST_LOG="${OUTPUT_DIR}/mac-host.log"
fi

cat >"${SUMMARY_MD}" <<EOF_SUMMARY
# iOS iroh Gate Run

- Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
- Runs required: ${RUNS}
- Interface plan: ${INTERFACES}
- Project: ${PROJECT}
- Device: ${DEVICE_ID}
- Model: ${MODEL}
- Relay URL: ${RELAY_URL}
- Mac host log: ${MAC_HOST_LOG}

EOF_SUMMARY

echo "Gate C/D iOS iroh run"
echo "  outputDir=${OUTPUT_DIR}"
echo "  runs=${RUNS}"
echo "  interfaces=${INTERFACES}"

if [[ "${START_HOST}" -eq 1 ]]; then
    if [[ ! -x "${MAC_HOST_APP}" ]]; then
        echo "Mac host executable missing or not executable: ${MAC_HOST_APP}" >&2
        echo "Build it first with xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-mac -skipPackagePluginValidation -skipMacroValidation" >&2
        exit 1
    fi
    verify_mac_host_signing
    echo "Starting Mac host for gate sequence: ${MAC_HOST_APP}"
    env \
        OPENBURNBAR_FORCE_LIVE_SCENE=1 \
        OPENBURNBAR_E2E_HOLD_OPEN=1 \
        OPENBURNBAR_ENABLE_IROH_TRANSPORT=1 \
        OPENBURNBAR_IROH_HOSTED_RELAY_URL="${RELAY_URL}" \
        "${MAC_HOST_APP}" >"${MAC_HOST_LOG}" 2>&1 &
    HOST_PID="$!"
    sleep 5
    if ! kill -0 "${HOST_PID}" >/dev/null 2>&1; then
        echo "Mac host exited before the gate sequence. Log: ${MAC_HOST_LOG}" >&2
        exit 1
    fi
    echo "  macHostPid=${HOST_PID}"
    echo "  macHostLog=${MAC_HOST_LOG}"
fi

resolve_model_if_needed
{
    echo "- Resolved model: ${MODEL}"
    echo
} >>"${SUMMARY_MD}"

for ((run = 1; run <= RUNS; run++)); do
    plan_index=$((run - 1))
    if ((plan_index > LAST_INTERFACE_PLAN_INDEX)); then
        plan_index="${LAST_INTERFACE_PLAN_INDEX}"
    fi
    expected_interface="${INTERFACE_PLAN[${plan_index}]}"
    run_id="$(printf '%02d' "${run}")"
    run_log="${OUTPUT_DIR}/run-${run_id}.log"
    events_json="${OUTPUT_DIR}/run-${run_id}-events.json"

    echo "Run ${run}/${RUNS}: expect networkInterfaces contains ${expected_interface}"
    started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    set +e
    scripts/e2e/ios-iroh-chat.sh \
        --uid "${UID_VALUE}" \
        --project "${PROJECT}" \
        --device "${DEVICE_ID}" \
        --wait-for-device-seconds "${DEVICE_WAIT_SECONDS}" \
        --wait-for-device-interval "${DEVICE_WAIT_INTERVAL}" \
        --relay-url "${RELAY_URL}" \
        --model "${MODEL}" \
        --prompt "${PROMPT}" \
        --expect-interface "${expected_interface}" \
        --poll-seconds "${POLL_SECONDS}" \
        --poll-interval "${POLL_INTERVAL}" \
        --events-output "${events_json}" \
        --no-start-host \
        > >(tee "${run_log}") \
        2> >(tee -a "${run_log}" >&2)
    status=$?
    set -e

    completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [[ "${status}" -eq 0 ]]; then
        jq -n \
            --argjson run "${run}" \
            --arg startedAt "${started_at}" \
            --arg completedAt "${completed_at}" \
            --arg expectedInterface "${expected_interface}" \
            --arg result "passed" \
            --arg log "${run_log}" \
            --arg events "${events_json}" \
            '{run:$run,startedAt:$startedAt,completedAt:$completedAt,expectedInterface:$expectedInterface,result:$result,log:$log,events:$events}' \
            >>"${SUMMARY_JSONL}"
        printf -- "- Run %s: passed (%s)\n" "${run_id}" "${expected_interface}" >>"${SUMMARY_MD}"
    else
        jq -n \
            --argjson run "${run}" \
            --arg startedAt "${started_at}" \
            --arg completedAt "${completed_at}" \
            --arg expectedInterface "${expected_interface}" \
            --arg result "failed" \
            --argjson exitCode "${status}" \
            --arg log "${run_log}" \
            --arg events "${events_json}" \
            '{run:$run,startedAt:$startedAt,completedAt:$completedAt,expectedInterface:$expectedInterface,result:$result,exitCode:$exitCode,log:$log,events:$events}' \
            >>"${SUMMARY_JSONL}"
        printf -- "- Run %s: failed (%s), exit %s\n" "${run_id}" "${expected_interface}" "${status}" >>"${SUMMARY_MD}"
        echo "Gate failed on run ${run}. Artifacts: ${OUTPUT_DIR}" >&2
        exit "${status}"
    fi
done

passed_count="$(jq -s '[.[] | select(.result == "passed")] | length' "${SUMMARY_JSONL}")"
if [[ "${passed_count}" -ne "${RUNS}" ]]; then
    echo "Gate summary mismatch: expected ${RUNS} passes, recorded ${passed_count}." >&2
    exit 1
fi

{
    echo
    echo "Gate result: passed ${RUNS}/${RUNS} clean iroh completions."
    echo "Completed: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >>"${SUMMARY_MD}"

echo "PASS: ${RUNS}/${RUNS} clean iOS iroh completions. Artifacts: ${OUTPUT_DIR}"
