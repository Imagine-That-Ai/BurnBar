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

set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="burnbar"
DEVICE_ID="AFB07C15-AD18-5EFA-AD1C-CADB4F286797"
BUNDLE_ID="com.openburnbar.app"
UID_VALUE=""
EXPECTED_INTERFACE="cellular"
MODEL="gpt-5.4-mini"
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
  --bundle-id <id>            iOS app bundle id. Default: com.openburnbar.app
  --relay-url <url>           Hosted relay URL.
  --model <id>                Hermes model for the hidden E2E prompt.
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
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --uid) UID_VALUE="$2"; shift 2 ;;
        --relay-url) RELAY_URL="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
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

for bin in curl gcloud jq xcrun; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
        echo "Required command not found: ${bin}" >&2
        exit 1
    fi
done

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

echo "E2E: iOS Hermes iroh hosted-relay path"
echo "  project=${PROJECT}"
echo "  uid=${UID_VALUE}"
echo "  device=${DEVICE_ID}"
echo "  model=${MODEL}"
echo "  expectedNetworkInterface=${EXPECTED_INTERFACE}"
echo "  startedAt=${STARTED_AT}"

if [[ "${START_HOST}" -eq 1 ]]; then
    if [[ ! -x "${MAC_HOST_APP}" ]]; then
        echo "Mac host executable missing or not executable: ${MAC_HOST_APP}" >&2
        echo "Build it first with xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-mac -skipPackagePluginValidation -skipMacroValidation" >&2
        exit 1
    fi
    echo "Starting Mac host: ${MAC_HOST_APP}"
    env \
        OPENBURNBAR_FORCE_LIVE_SCENE=1 \
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
fi

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

latest_events() {
    curl -fsS -H "Authorization: Bearer ${TOKEN}" \
        "${BASE_URL}?pageSize=${PAGE_SIZE}&orderBy=observedAt%20desc"
}

while [[ "${SECONDS}" -lt "${DEADLINE}" ]]; do
    EVENTS_JSON="$(latest_events)"
    POST_LAUNCH_EVENTS="$(
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
                networkInterfaces: (.fields.detail.mapValue.fields.networkInterfaces.stringValue // ""),
                error: (.fields.detail.mapValue.fields.error.stringValue // "")
              }
            | select(.observedAt >= $started)
          ]' <<<"${EVENTS_JSON}"
    )"

    FALLBACK_COUNT="$(jq '[.[] | select(.eventType == "iroh_fallback_to_wss")] | length' <<<"${POST_LAUNCH_EVENTS}")"
    FAILURE_COUNT="$(jq '[.[] | select(.eventType == "iroh_stream_failed")] | length' <<<"${POST_LAUNCH_EVENTS}")"
    INTERFACE_COUNT="$(jq --arg iface "${EXPECTED_INTERFACE}" '[.[] | select(.networkInterfaces | split(",") | index($iface))] | length' <<<"${POST_LAUNCH_EVENTS}")"
    COMPLETE_COUNT="$(jq '[.[] | select(.eventType == "iroh_stream_closed" and .stage == "ios_response_complete")] | length' <<<"${POST_LAUNCH_EVENTS}")"

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
    if [[ "${INTERFACE_COUNT}" -gt 0 && "${COMPLETE_COUNT}" -gt 0 ]]; then
        echo "PASS: expected interface and ios_response_complete observed with no WSS fallback."
        jq '.[] | select(.networkInterfaces != "" or .stage == "ios_response_complete")' <<<"${POST_LAUNCH_EVENTS}"
        write_events_if_requested
        exit 0
    fi

    echo "Waiting: interfaceMatches=${INTERFACE_COUNT} iosResponseComplete=${COMPLETE_COUNT}"
    sleep "${POLL_INTERVAL}"
done

echo "FAIL: timed out waiting for expected interface and ios_response_complete." >&2
echo "Launch JSON: ${LAUNCH_JSON}" >&2
echo "Launch log: ${LAUNCH_LOG}" >&2
jq '.' <<<"${POST_LAUNCH_EVENTS:-[]}" >&2
write_events_if_requested
exit 1
