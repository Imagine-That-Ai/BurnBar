#!/usr/bin/env bash
#
# End-to-end smoke for the physical iOS Hermes -> iroh hosted-relay path.
# It launches the installed debug app with the hidden Hermes E2E prompt route,
# polls Firestore iroh audit events, and fails unless the expected phone
# network interface and terminal iOS response-complete event appear without
# a WSS fallback after launch.
#
# Required:
#   * A physical iPhone paired with CoreDevice.
#   * The debug OpenBurnBarMobile app installed on that iPhone.
#   * A built debug macOS host app at build/DerivedData-mac/.../OpenBurnBar,
#     unless --no-start-host is used.
#   * gcloud auth with Firestore read access to the Firebase project.
#   * jq and curl.
#
# Example:
#   scripts/e2e/ios-iroh-chat.sh \
#     --uid 6YTomKTKdQdpvIJgmz6VTIrrQ4w1 \
#     --expect-interface cellular
#
# By default the script resolves --model auto from the live BurnBar daemon
# /v1/models catalog and skips local-only runtimes; Ollama Cloud is allowed.

set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="burnbar"
DEVICE_ID="AFB07C15-AD18-5EFA-AD1C-CADB4F286797"
DEVICE_WAIT_SECONDS=0
DEVICE_WAIT_INTERVAL=5
BUNDLE_ID="com.openburnbar.app"
UID_VALUE=""
EXPECTED_INTERFACE="cellular"
MODEL="auto"
EXPECTED_REQUESTED_MODEL=""
PROMPT="Reply exactly: ok"
RELAY_URL="https://use1-1.relay.alberto8793.burnbar.iroh.link/"
POLL_SECONDS=420
POLL_INTERVAL=10
PAGE_SIZE=100
START_HOST=1
MAC_HOST_APP="build/DerivedData-mac/Build/Products/Debug/OpenBurnBar.app/Contents/MacOS/OpenBurnBar"
MAC_HOST_LOG="/tmp/openburnbar-ios-iroh-e2e-mac-host.log"
EVENTS_OUTPUT=""

usage() {
    cat <<'USAGE'
Usage: scripts/e2e/ios-iroh-chat.sh --uid <firebase-uid> [options]

Options:
  --project <id>              Firebase/GCP project. Default: burnbar
  --device <id>               CoreDevice identifier. Default: current dev iPhone
  --wait-for-device-seconds <n>
                              Wait for CoreDevice tunnel before failing. Default: 0
  --wait-for-device-interval <n>
                              Poll interval while waiting for device. Default: 5
  --bundle-id <id>            iOS app bundle id. Default: com.openburnbar.app
  --relay-url <url>           Hosted relay URL.
  --model <id|auto>           Hermes model for the hidden E2E prompt. Default: auto from live /v1/models.
  --expect-requested-model <id>
                              Model id expected in host_forward_chat_start. Defaults to --model.
                              Use this when the app should canonicalize an old catalog alias.
  --prompt <text>             Hidden E2E prompt text.
  --expect-interface <name>   Required iOS networkInterfaces value. Default: cellular
  --poll-seconds <seconds>    Max Firestore polling time. Default: 420
  --poll-interval <seconds>   Poll interval. Default: 10
  --mac-host-app <path>       Debug Mac host executable to start.
  --mac-host-log <path>       Log path for the started Mac host.
  --events-output <path>      Write post-launch Firestore audit events JSON.
  --no-start-host             Do not start/stop a Mac host process.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT="$2"; shift 2 ;;
        --device) DEVICE_ID="$2"; shift 2 ;;
        --wait-for-device-seconds) DEVICE_WAIT_SECONDS="$2"; shift 2 ;;
        --wait-for-device-interval) DEVICE_WAIT_INTERVAL="$2"; shift 2 ;;
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --uid) UID_VALUE="$2"; shift 2 ;;
        --relay-url) RELAY_URL="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --expect-requested-model) EXPECTED_REQUESTED_MODEL="$2"; shift 2 ;;
        --prompt) PROMPT="$2"; shift 2 ;;
        --expect-interface) EXPECTED_INTERFACE="$2"; shift 2 ;;
        --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
        --mac-host-app) MAC_HOST_APP="$2"; shift 2 ;;
        --mac-host-log) MAC_HOST_LOG="$2"; shift 2 ;;
        --events-output) EVENTS_OUTPUT="$2"; shift 2 ;;
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
if ! [[ "${DEVICE_WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
    echo "--wait-for-device-seconds must be a non-negative integer." >&2
    exit 2
fi
if ! [[ "${DEVICE_WAIT_INTERVAL}" =~ ^[1-9][0-9]*$ ]]; then
    echo "--wait-for-device-interval must be a positive integer." >&2
    exit 2
fi

for bin in curl gcloud jq xcrun; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
        echo "Required command not found: ${bin}" >&2
        exit 1
    fi
done

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

if ! wait_for_device_tunnel; then
    echo "Device is not launchable through CoreDevice: ${DEVICE_ID}" >&2
    echo "For the cellular gate, connect the iPhone to this Mac over USB, unlock it, accept Trust prompts, keep Wi-Fi off, and rerun this command." >&2
    echo "${DEVICE_DETAILS}" | sed -n '/connectionProperties:/,/capabilities:/p' >&2
    exit 1
fi

STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
LAUNCH_JSON="/tmp/openburnbar-mobile-hermes-ios-iroh-${STAMP}.json"
LAUNCH_LOG="/tmp/openburnbar-mobile-hermes-ios-iroh-${STAMP}.log"
HOST_PID=""
trap 'if [[ -n "${HOST_PID}" ]] && kill -0 "${HOST_PID}" >/dev/null 2>&1; then kill "${HOST_PID}" >/dev/null 2>&1 || true; fi' EXIT

write_events_if_requested() {
    if [[ -n "${EVENTS_OUTPUT}" ]]; then
        mkdir -p "$(dirname "${EVENTS_OUTPUT}")"
        printf '%s\n' "${POST_LAUNCH_EVENTS:-[]}" >"${EVENTS_OUTPUT}"
    fi
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
            | . as $model
            | select(([
                ($model.id // ""),
                ($model.provider_name // ""),
                ($model.providerName // ""),
                ($model.source_kind // ""),
                ($model.capabilities // [] | join(" "))
              ] | join(" ") | test("lmstudio|lm studio|local"; "i") | not))
            | select(
                ((($model.provider_id // $model.providerID // $model.owned_by // "") | test("^ollama$"; "i")) | not)
                or (($model.provider_name // $model.providerName // "") | test("ollama cloud"; "i"))
                or (($model.source_kind // "") | test("ollama_cloud"; "i"))
              )
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

wait_for_burnbar_gateway() {
    local deadline=$((SECONDS + 60))
    while [[ "${SECONDS}" -lt "${deadline}" ]]; do
        if curl -fsS --max-time 3 "http://127.0.0.1:8317/v1/models" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "BurnBar daemon gateway did not become reachable at http://127.0.0.1:8317/v1/models." >&2
    echo "Mac host log: ${MAC_HOST_LOG}" >&2
    exit 1
}

if [[ "${START_HOST}" -eq 1 ]]; then
    if [[ ! -x "${MAC_HOST_APP}" ]]; then
        echo "Mac host executable missing or not executable: ${MAC_HOST_APP}" >&2
        echo "Build it first with xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-mac -skipPackagePluginValidation -skipMacroValidation" >&2
        exit 1
    fi
    verify_mac_host_signing
    echo "Starting Mac host: ${MAC_HOST_APP}"
    env \
        OPENBURNBAR_FORCE_LIVE_SCENE=1 \
        OPENBURNBAR_E2E_HOLD_OPEN=1 \
        OPENBURNBAR_ENABLE_IROH_TRANSPORT=1 \
        OPENBURNBAR_IROH_HOSTED_RELAY_URL="${RELAY_URL}" \
        "${MAC_HOST_APP}" >"${MAC_HOST_LOG}" 2>&1 &
    HOST_PID="$!"
    sleep 5
    if ! kill -0 "${HOST_PID}" >/dev/null 2>&1; then
        echo "Mac host exited before launch. Log: ${MAC_HOST_LOG}" >&2
        exit 1
    fi
    echo "  macHostPid=${HOST_PID}"
    echo "  macHostLog=${MAC_HOST_LOG}"
    wait_for_burnbar_gateway
fi

resolve_model_if_needed
if [[ -z "${EXPECTED_REQUESTED_MODEL}" ]]; then
    EXPECTED_REQUESTED_MODEL="${MODEL}"
fi

echo "E2E: iOS Hermes iroh hosted-relay path"
echo "  project=${PROJECT}"
echo "  uid=${UID_VALUE}"
echo "  device=${DEVICE_ID}"
echo "  model=${MODEL}"
echo "  expectedRequestedModel=${EXPECTED_REQUESTED_MODEL}"
echo "  expectedNetworkInterface=${EXPECTED_INTERFACE}"
echo "  startedAt=${STARTED_AT}"

xcrun devicectl device process launch \
    --device "${DEVICE_ID}" \
    --terminate-existing \
    --json-output "${LAUNCH_JSON}" \
    --log-output "${LAUNCH_LOG}" \
    --environment-variables "{\"OPENBURNBAR_ENABLE_IROH_TRANSPORT\":\"1\",\"OPENBURNBAR_IROH_HOSTED_RELAY_URL\":\"${RELAY_URL}\",\"OPENBURNBAR_E2E_HERMES_MODEL\":\"${MODEL}\",\"OPENBURNBAR_E2E_HERMES_PROMPT\":\"${PROMPT}\"}" \
    "${BUNDLE_ID}"

TOKEN="$(gcloud auth print-access-token)"
BASE_URL="https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/users/${UID_VALUE}/iroh_audit_events"
DEADLINE=$((SECONDS + POLL_SECONDS))
POLL_FAILURE_COUNT=0
LAST_POLL_ERROR=""

latest_events() {
    curl -fsS -H "Authorization: Bearer ${TOKEN}" \
        "${BASE_URL}?pageSize=${PAGE_SIZE}&orderBy=observedAt%20desc"
}

while [[ "${SECONDS}" -lt "${DEADLINE}" ]]; do
    if ! EVENTS_JSON="$(latest_events 2>&1)"; then
        POLL_FAILURE_COUNT=$((POLL_FAILURE_COUNT + 1))
        LAST_POLL_ERROR="${EVENTS_JSON//$'\n'/ }"
        echo "Waiting: firestorePollFailed=${POLL_FAILURE_COUNT} error=${LAST_POLL_ERROR}" >&2
        sleep "${POLL_INTERVAL}"
        continue
    fi
    if ! PARSED_EVENTS="$(
        jq --arg started "${STARTED_AT}" '
          [ .documents[]?
            | {
                id: (.name | split("/")[-1]),
                observedAt: (.fields.observedAt.timestampValue // .fields.observedAt.stringValue // .createTime // ""),
                eventType: (.fields.eventType.stringValue // ""),
                transport: (.fields.transport.stringValue // ""),
                stage: (.fields.detail.mapValue.fields.stage.stringValue // ""),
                side: (.fields.detail.mapValue.fields.side.stringValue // ""),
                requestId: (.fields.detail.mapValue.fields.requestId.stringValue // ""),
                requestedModel: (.fields.detail.mapValue.fields.requestedModel.stringValue // ""),
                operation: (.fields.detail.mapValue.fields.operation.stringValue // ""),
                path: (.fields.detail.mapValue.fields.path.stringValue // ""),
                done: (.fields.detail.mapValue.fields.done.stringValue // ""),
                networkInterfaces: (.fields.detail.mapValue.fields.networkInterfaces.stringValue // ""),
                error: (.fields.detail.mapValue.fields.error.stringValue // "")
              }
            | select(.observedAt >= $started)
          ]' <<<"${EVENTS_JSON}" 2>&1
    )"; then
        POLL_FAILURE_COUNT=$((POLL_FAILURE_COUNT + 1))
        LAST_POLL_ERROR="${PARSED_EVENTS//$'\n'/ }"
        echo "Waiting: firestorePollParseFailed=${POLL_FAILURE_COUNT} error=${LAST_POLL_ERROR}" >&2
        sleep "${POLL_INTERVAL}"
        continue
    fi
    POST_LAUNCH_EVENTS="${PARSED_EVENTS}"

    FALLBACK_COUNT="$(jq '[.[] | select(.eventType == "iroh_fallback_to_wss")] | length' <<<"${POST_LAUNCH_EVENTS}")"
    FAILURE_COUNT="$(jq '[.[] | select(.eventType == "iroh_stream_failed")] | length' <<<"${POST_LAUNCH_EVENTS}")"
    INTERFACE_COUNT="$(jq --arg iface "${EXPECTED_INTERFACE}" '[.[] | select(.networkInterfaces | split(",") | index($iface))] | length' <<<"${POST_LAUNCH_EVENTS}")"
    CHAT_PROOF="$(
        jq --arg model "${EXPECTED_REQUESTED_MODEL}" '
          ([.[] | select(.stage == "host_forward_chat_start" and .requestedModel == $model) | .requestId] | unique) as $chatIds
          | {
              start: ($chatIds | length),
              hostComplete: ([.[] | select(.stage == "host_forward_chat_complete" and (.requestId as $id | $chatIds | index($id)))] | length),
              iosComplete: ([.[] | select(.eventType == "iroh_stream_closed" and .stage == "ios_response_complete" and (.requestId as $id | $chatIds | index($id)))] | length)
            }
        ' <<<"${POST_LAUNCH_EVENTS}"
    )"
    CHAT_START_COUNT="$(jq -r '.start' <<<"${CHAT_PROOF}")"
    CHAT_HOST_COMPLETE_COUNT="$(jq -r '.hostComplete' <<<"${CHAT_PROOF}")"
    CHAT_IOS_COMPLETE_COUNT="$(jq -r '.iosComplete' <<<"${CHAT_PROOF}")"

    if [[ "${FALLBACK_COUNT}" -gt 0 ]]; then
        echo "FAIL: WSS fallback recorded after launch." >&2
        jq '.[] | select(.eventType == "iroh_fallback_to_wss" or .eventType == "iroh_stream_failed")' <<<"${POST_LAUNCH_EVENTS}" >&2
        write_events_if_requested
        exit 1
    fi
    if [[ "${FAILURE_COUNT}" -gt 0 ]]; then
        echo "FAIL: iroh stream failure recorded after launch." >&2
        jq '.[] | select(.eventType == "iroh_stream_failed")' <<<"${POST_LAUNCH_EVENTS}" >&2
        write_events_if_requested
        exit 1
    fi
    if [[ "${INTERFACE_COUNT}" -gt 0 && "${CHAT_START_COUNT}" -gt 0 && "${CHAT_HOST_COMPLETE_COUNT}" -gt 0 && "${CHAT_IOS_COMPLETE_COUNT}" -gt 0 ]]; then
        echo "PASS: expected interface and selected-model chat completion observed with no WSS fallback."
        jq --arg model "${EXPECTED_REQUESTED_MODEL}" '
          ([.[] | select(.stage == "host_forward_chat_start" and .requestedModel == $model) | .requestId] | unique) as $chatIds
          | .[]
          | select(.networkInterfaces != "" or (.requestId as $id | $chatIds | index($id)))
        ' <<<"${POST_LAUNCH_EVENTS}"
        write_events_if_requested
        exit 0
    fi

    echo "Waiting: interfaceMatches=${INTERFACE_COUNT} chatStart=${CHAT_START_COUNT} chatHostComplete=${CHAT_HOST_COMPLETE_COUNT} chatIosComplete=${CHAT_IOS_COMPLETE_COUNT}"
    sleep "${POLL_INTERVAL}"
done

echo "FAIL: timed out waiting for expected interface and selected-model chat completion." >&2
echo "Launch JSON: ${LAUNCH_JSON}" >&2
echo "Launch log: ${LAUNCH_LOG}" >&2
if [[ -n "${LAST_POLL_ERROR}" ]]; then
    echo "Last Firestore poll error: ${LAST_POLL_ERROR}" >&2
fi
jq '.' <<<"${POST_LAUNCH_EVENTS:-[]}" >&2
write_events_if_requested
exit 1
