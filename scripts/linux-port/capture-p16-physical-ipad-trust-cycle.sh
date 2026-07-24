#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
helper="$repo_root/scripts/linux-port/p16-physical-ipad-coordination.mjs"
mobile_runner="$repo_root/scripts/test-openburnbar-mobile.sh"
coordination_dir=""
target_head=""
candidate_run_id=""
candidate_artifact_digest=""
device_id=""
scratch_root=""
timeout_seconds=900

usage() {
    cat <<'EOF'
Usage: capture-p16-physical-ipad-trust-cycle.sh \
  --coordination-dir PATH --target-head SHA --candidate-run-id ID \
  --candidate-artifact-digest SHA256 [--device-id UDID] \
  [--scratch-root PATH] [--timeout-seconds N]

Run beside the live Linux P-16 probe. The coordination directory must be the
same owner-only UTM shared directory supplied to the Linux runner.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --coordination-dir) coordination_dir="${2:-}"; shift 2 ;;
        --target-head) target_head="${2:-}"; shift 2 ;;
        --candidate-run-id) candidate_run_id="${2:-}"; shift 2 ;;
        --candidate-artifact-digest) candidate_artifact_digest="${2:-}"; shift 2 ;;
        --device-id) device_id="${2:-}"; shift 2 ;;
        --scratch-root) scratch_root="${2:-}"; shift 2 ;;
        --timeout-seconds) timeout_seconds="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

[[ "$coordination_dir" == /* ]] || { echo "ERROR: --coordination-dir must be absolute." >&2; exit 64; }
[[ "$target_head" =~ ^[a-f0-9]{40}$ ]] || { echo "ERROR: --target-head must be a 40-character lowercase SHA." >&2; exit 64; }
[[ -n "$candidate_run_id" ]] || { echo "ERROR: --candidate-run-id is required." >&2; exit 64; }
[[ "$candidate_artifact_digest" =~ ^[a-f0-9]{64}$ ]] || { echo "ERROR: --candidate-artifact-digest must be a lowercase SHA-256." >&2; exit 64; }
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --timeout-seconds must be positive." >&2; exit 64; }

mkdir -p "$coordination_dir"
chmod 700 "$coordination_dir"
coordination_dir="$(cd "$coordination_dir" && pwd -P)"
request_file="$coordination_dir/p16-trust-request.json"
ready_file="$coordination_dir/p16-revoke-ready.json"
receipt_file="$coordination_dir/p16-mobile-receipt.json"
[[ ! -e "$receipt_file" ]] || { echo "ERROR: receipt already exists: $receipt_file" >&2; exit 64; }

wait_for_file() {
    local file="$1" label="$2" deadline=$((SECONDS + timeout_seconds))
    while [[ ! -f "$file" ]]; do
        if (( SECONDS >= deadline )); then
            echo "ERROR: timed out waiting for $label: $file" >&2
            return 1
        fi
        sleep 1
    done
}

discover_ipad() {
    local resolved
    command -v xcrun >/dev/null || { echo "ERROR: Xcode command-line tools are unavailable." >&2; return 1; }
    resolved="$(xcrun xctrace list devices 2>/dev/null | awk '
        /^== Simulators ==/ { exit }
        /iPad/ && /\([0-9A-Fa-f-]{24,}\)$/ {
            line=$0; sub(/^.*\(/, "", line); sub(/\)$/, "", line); print line
        }
    ' | head -1)"
    [[ -n "$resolved" ]] || { echo "ERROR: no connected physical iPad was discovered." >&2; return 1; }
    printf '%s\n' "$resolved"
}

if [[ -z "$device_id" ]]; then device_id="$(discover_ipad)"; fi
[[ "$device_id" != *"Simulator"* ]] || { echo "ERROR: Simulator destinations are forbidden." >&2; exit 64; }

echo ">>> Waiting for the live Linux P-16 request..."
wait_for_file "$request_file" "Linux trust-cycle request"
request_base64="$(node "$helper" request-base64 "$request_file" "$target_head" "$candidate_run_id" "$candidate_artifact_digest")"
marker="$(node -e 'const v=JSON.parse(Buffer.from(process.argv[1],"base64"));process.stdout.write(v.marker)' "$request_base64")"

if [[ -z "$scratch_root" ]]; then
    scratch_root="$repo_root/.tmp/p16-physical-ipad/$marker"
fi
[[ "$scratch_root" == /* ]] || { echo "ERROR: --scratch-root must be absolute." >&2; exit 64; }
mkdir -p "$scratch_root"
chmod 700 "$scratch_root"
scratch_root="$(cd "$scratch_root" && pwd -P)"
approval_log="$scratch_root/approval-xctest.log"
revoke_log="$scratch_root/revoke-xctest.log"

run_phase() {
    local phase="$1" selector="$2" log="$3" approval="${4:-}"
    : > "$log"
    chmod 600 "$log"
    echo ">>> Running P-16 $phase on physical iPad $device_id..."
    set +e
    OPENBURNBAR_IOS_DESTINATION="platform=iOS,id=$device_id" \
    OPENBURNBAR_MOBILE_TEST_FILTER="$selector" \
    OPENBURNBAR_MOBILE_TEST_ATTEMPTS=1 \
    OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT="$scratch_root" \
    OPENBURNBAR_P16_PHASE="$phase" \
    OPENBURNBAR_P16_REQUEST_BASE64="$request_base64" \
    OPENBURNBAR_P16_APPROVAL_BASE64="$approval" \
        "$mobile_runner" 2>&1 | tee "$log"
    local status=${PIPESTATUS[0]}
    set -e
    [[ $status -eq 0 ]] || { echo "ERROR: P-16 $phase XCTest failed ($status)." >&2; return "$status"; }
}

run_phase approve \
    "OpenBurnBarMobileTests/P16PhysicalIPadTrustCycleTests/testApprovePendingLinuxDevice" \
    "$approval_log"
approval_base64="$(node "$helper" approval-base64 "$request_file" "$approval_log")"

echo ">>> Linux approval observed; waiting for its restart-persistence acknowledgement..."
wait_for_file "$ready_file" "Linux revoke-ready acknowledgement"
node "$helper" validate-ready "$request_file" "$ready_file"

run_phase revoke \
    "OpenBurnBarMobileTests/P16PhysicalIPadTrustCycleTests/testRevokeApprovedLinuxDevice" \
    "$revoke_log" "$approval_base64"
node "$helper" publish-receipt "$request_file" "$approval_log" "$revoke_log" "$receipt_file"

echo ">>> P-16 physical-iPad receipt published: $receipt_file"
echo ">>> DerivedData and phase logs retained under: $scratch_root"
