#!/usr/bin/env bash
#
# test-openburnbar-mobile.sh — SOTA test driver for OpenBurnBarMobileTests.
#
# Local default: first connected physical iPhone (USB, unlocked, trusted).
# CI (CI=true / GITHUB_ACTIONS=true): iOS Simulator — GitHub macOS runners have
# no USB-attached devices.
#
# Mirrors retry/telemetry patterns from test-openburnbar-app.sh.
#
# Environment knobs:
#   OPENBURNBAR_ENABLE_COVERAGE=YES      Capture xcresult at canonical mobile coverage path.
#   OPENBURNBAR_IOS_DESTINATION=...      Explicit xcodebuild destination (e.g. platform=iOS,id=<UDID>).
#   OPENBURNBAR_MOBILE_DRY_RUN=1         Print resolved destination and exit 0.
#   OPENBURNBAR_MOBILE_TEST_ATTEMPTS=N   Override max attempts (default 4).
#   OPENBURNBAR_MOBILE_TEST_FILTER=...   Pass a custom -only-testing target.
#   OPENBURNBAR_MOBILE_SIMULATOR=...     Simulator name for CI fallback (default: iPhone 17 Pro Max).
#
# Exit status:
#   0  — tests passed (or dry-run succeeded)
#   N  — final xcodebuild exit code

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$repo_root/.spm-cache-new"
artifact_root="$repo_root/.derived-data"
derived_data_root="${OPENBURNBAR_MOBILE_TEST_DERIVED_DATA_ROOT:-${TMPDIR:-/tmp}/openburnbar-mobile-tests}"
attempt_log_path="$artifact_root/test-openburnbar-mobile-attempts.jsonl"

default_test_execution_allowance="${OPENBURNBAR_MOBILE_TEST_DEFAULT_ALLOWANCE:-900}"
maximum_test_execution_allowance="${OPENBURNBAR_MOBILE_TEST_MAX_ALLOWANCE:-1800}"
max_test_attempts="${OPENBURNBAR_MOBILE_TEST_ATTEMPTS:-4}"
test_filter="${OPENBURNBAR_MOBILE_TEST_FILTER:-OpenBurnBarMobileTests}"
simulator_name="${OPENBURNBAR_MOBILE_SIMULATOR:-iPhone 17 Pro Max}"
ios_destination=""

normalize_ios_destination() {
    local raw="$1"

    if [[ -z "$raw" ]]; then
        return 1
    fi
    if [[ "$raw" == platform=* || "$raw" == generic/* ]]; then
        echo "$raw"
        return 0
    fi
    if [[ "$raw" == id=* ]]; then
        echo "platform=iOS,$raw"
        return 0
    fi
    if [[ "$raw" =~ ^[0-9A-Fa-f-]{25,40}$ ]]; then
        echo "platform=iOS,id=$raw"
        return 0
    fi
    if [[ "$raw" == name=* ]]; then
        echo "platform=iOS,$raw"
        return 0
    fi

    echo "$raw"
}

discover_physical_iphone_destination() {
    local devices online_iphone device_name udid

    devices="$(xcrun xctrace list devices 2>/dev/null || true)"
    online_iphone="$(echo "$devices" | sed -n '/== Devices ==/,/== Devices Offline ==/p' | grep -i "iPhone" | grep -v "Simulator" | head -1 || true)"

    if [[ -z "$online_iphone" ]]; then
        echo "ERROR: No connected physical iPhone found for OpenBurnBar mobile tests." >&2
        echo "" >&2
        echo "Connect an iPhone over USB, unlock it, tap Trust on the device, and ensure Developer Mode is on." >&2
        echo "Or set OPENBURNBAR_IOS_DESTINATION to an explicit UDID, e.g.:" >&2
        echo "  OPENBURNBAR_IOS_DESTINATION='platform=iOS,id=<UDID>' ./scripts/test-openburnbar-mobile.sh" >&2
        echo "" >&2
        echo "Offline devices (if any):" >&2
        echo "$devices" | sed -n '/== Devices Offline ==/,/== Simulators ==/p' | grep -i "iPhone" | grep -v "Simulator" || true >&2
        return 1
    fi

    device_name="$(echo "$online_iphone" | sed -E 's/[[:space:]]*\(.+$//' | xargs)"
    udid="$(echo "$online_iphone" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{40}' | head -1 || true)"
    if [[ -z "$udid" ]]; then
        echo "ERROR: Found a connected iPhone but could not parse its UDID from xctrace output:" >&2
        echo "  $online_iphone" >&2
        return 1
    fi

    echo ">>> Using connected physical iPhone: $device_name ($udid)" >&2
    echo "platform=iOS,id=$udid"
}

resolve_ios_destination() {
    local resolved=""

    if [[ -n "${OPENBURNBAR_IOS_DESTINATION:-}" ]]; then
        resolved="$(normalize_ios_destination "$OPENBURNBAR_IOS_DESTINATION")"
        echo ">>> Using OPENBURNBAR_IOS_DESTINATION: $resolved" >&2
        echo "$resolved"
        return 0
    fi

    if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
        # GitHub-hosted macOS runners cannot attach USB physical devices.
        resolved="platform=iOS Simulator,name=${simulator_name}"
        echo ">>> CI environment: using iOS Simulator destination ($resolved)" >&2
        echo "$resolved"
        return 0
    fi

    discover_physical_iphone_destination
}

simulator_udid=""
simulator_destination="platform=iOS Simulator,name=${simulator_name}"

resolve_simulator_udid() {
    simulator_udid="$(python3 - "$simulator_name" <<'PY'
import json, subprocess, sys
name = sys.argv[1]
proc = subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "-j"],
    check=False,
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    raise SystemExit(0)
payload = json.loads(proc.stdout)
for runtime, devices in payload.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("name") == name and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)
PY
)"
    if [[ -n "$simulator_udid" ]]; then
        simulator_destination="platform=iOS Simulator,id=${simulator_udid}"
    fi
}

ios_destination="$(resolve_ios_destination)"
uses_ios_simulator=0
if [[ "$ios_destination" == *"Simulator"* ]]; then
    uses_ios_simulator=1
fi

if [[ "$uses_ios_simulator" -eq 1 ]]; then
    resolve_simulator_udid
    ios_destination="$simulator_destination"
fi

if [[ "${OPENBURNBAR_MOBILE_DRY_RUN:-}" == "1" ]]; then
    echo ">>> Dry run: would test OpenBurnBarMobile at destination:"
    echo "$ios_destination"
    exit 0
fi

mkdir -p "$cache_dir"
mkdir -p "$artifact_root"
mkdir -p "$derived_data_root"

derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-mobile-tests.XXXXXX")"
xcodebuild_log=""
xcodebuild_args=()
last_test_exit_code=0

emit_attempt_event() {
    local attempt="$1"
    local exit_code="$2"
    local outcome="$3"
    local duration="$4"
    local xcresult_path="$5"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$attempt" "$exit_code" "$outcome" "$duration" "$xcresult_path" "$timestamp" "$attempt_log_path" <<'PY'
import json
import sys

attempt, exit_code, outcome, duration, xcresult_path, timestamp, dest = sys.argv[1:]
record = {
    "kind": "attempt",
    "timestamp": timestamp,
    "attempt": int(attempt),
    "exitCode": int(exit_code),
    "outcome": outcome,
    "durationSeconds": int(duration),
    "xcresultPath": xcresult_path,
}
with open(dest, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
}

emit_summary_event() {
    local outcome="$1"
    local attempts="$2"
    local total_duration="$3"
    local final_exit="$4"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$outcome" "$attempts" "$total_duration" "$final_exit" "$timestamp" "$attempt_log_path" <<'PY'
import json
import sys

outcome, attempts, duration, final_exit, timestamp, dest = sys.argv[1:]
record = {
    "kind": "summary",
    "timestamp": timestamp,
    "outcome": outcome,
    "attempts": int(attempts),
    "totalDurationSeconds": int(duration),
    "finalExitCode": int(final_exit),
}
with open(dest, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
}

cleanup_derived_data() {
    local dd="$1"
    rm -rf "$dd" 2>/dev/null || true
}

cleanup() {
    if [ -n "$xcodebuild_log" ]; then
        rm -f "$xcodebuild_log" 2>/dev/null || true
    fi
    cleanup_derived_data "$derived_data_dir"
}

ensure_simulator_booted() {
    if [[ -z "$simulator_udid" ]]; then
        return 0
    fi
    local state
    state="$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
target = sys.argv[1]
payload = json.loads(sys.stdin.read() or "{}")
for runtime, devices in payload.get("devices", {}).items():
    for device in devices:
        if device.get("udid") == target:
            print(device.get("state", ""))
            raise SystemExit(0)
print("")
' "$simulator_udid")"
    if [[ "$state" != "Booted" ]]; then
        echo ">>> Booting iOS Simulator ${simulator_name} (${simulator_udid})."
        xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
        xcrun simctl bootstatus "$simulator_udid" -b >/dev/null 2>&1 || sleep 3
    fi
}

preclean_stale_mobile_processes() {
    local patterns=(
        "OpenBurnBarMobile.app/Contents/MacOS/OpenBurnBarMobile"
        "OpenBurnBarMobileTests.xctest"
        "xctest .*OpenBurnBarMobileTests"
        "OpenBurnBarMobileUITests.xctest"
    )
    for pattern in "${patterns[@]}"; do
        pkill -f "$pattern" >/dev/null 2>&1 || true
    done
    if [[ -n "$simulator_udid" ]]; then
        xcrun simctl terminate "$simulator_udid" com.openburnbar.app >/dev/null 2>&1 || true
    fi
    sleep 0.2
}

trap 'cleanup' EXIT

populate_xcodebuild_args() {
    local dd="$1"
    local attempt_result="$2"
    xcodebuild_args=(
        -project "$repo_root/OpenBurnBar.xcodeproj"
        -scheme "OpenBurnBarMobile"
        -destination "$ios_destination"
        -clonedSourcePackagesDirPath "$cache_dir"
        -derivedDataPath "$dd"
        -resultBundlePath "$attempt_result"
        -test-timeouts-enabled YES
        -default-test-execution-time-allowance "$default_test_execution_allowance"
        -maximum-test-execution-time-allowance "$maximum_test_execution_allowance"
        SWIFT_ENABLE_EXPLICIT_MODULES=NO
        SWIFT_COMPILATION_MODE=singlefile
        SWIFT_ENABLE_BATCH_MODE=NO
        -parallel-testing-enabled NO
        -skip-testing:OpenBurnBarMobileUITests
        -only-testing:"$test_filter"
    )
    if [[ "$uses_ios_simulator" -eq 1 ]]; then
        xcodebuild_args+=(
            CODE_SIGNING_ALLOWED=NO
            CODE_SIGNING_REQUIRED=NO
        )
    fi
    if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
        xcodebuild_args+=(-enableCodeCoverage YES)
    fi
}

if [[ "${CI:-}" == "true" ]]; then
    export TEST_RUNNER_CI=true
fi
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    export TEST_RUNNER_GITHUB_ACTIONS=true
fi

canonical_xcresult_path="$artifact_root/OpenBurnBarMobile_TestCoverage.xcresult"
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
    rm -rf "$canonical_xcresult_path"
fi

: > "$attempt_log_path"

hang_substrings=(
    "test runner hung before establishing connection"
    "Test runner never began executing tests"
    "Test session timed out"
    "Failed to launch test runner"
    "failed to launch"
    "Lost connection to the test runner"
    "Could not attach to pid"
    "TestRunner crashed"
    "Early unexpected exit, operation never finished bootstrapping"
    "operation never finished bootstrapping"
)

is_known_hang() {
    local log_path="$1"
    local pattern
    for pattern in "${hang_substrings[@]}"; do
        if grep -Fq "$pattern" "$log_path"; then
            return 0
        fi
    done
    return 1
}

is_xcode_false_negative_pass() {
    local log_path="$1"

    grep -Fq "Test Suite 'Selected tests' passed" "$log_path" || return 1
    grep -Eq "Executed [1-9][0-9]* tests, with ([0-9]+ tests skipped and )?0 failures" "$log_path" || return 1

    if grep -Eq "Test Case '-\\[[^]]+\\]' failed" "$log_path"; then
        return 1
    fi
    if grep -A40 "^Failing tests:" "$log_path" | tail -n +2 | grep -qE '^[[:space:]]*[A-Za-z0-9_]+Tests\\.'; then
        return 1
    fi
    if awk "/Test Suite 'Selected tests'/{found=1} found && /Executed [0-9]+ tests/ && /with .*[^0] failures/" "$log_path" | grep -q .; then
        return 1
    fi

    return 0
}

backoff_seconds=(0 5 10 20 40)

test_attempt=1
final_exit_code=0
final_outcome="failed"
final_xcresult=""

while [ "$test_attempt" -le "$max_test_attempts" ]; do
    if [ "$test_attempt" -gt 1 ]; then
        local_idx=$((test_attempt - 1))
        if [ "$local_idx" -ge "${#backoff_seconds[@]}" ]; then
            local_idx=$((${#backoff_seconds[@]} - 1))
        fi
        wait_for=${backoff_seconds[$local_idx]}
        echo ">>> Mobile retry attempt $test_attempt of $max_test_attempts. Sleeping ${wait_for}s."
        sleep "$wait_for"
        if (( test_attempt % 2 == 1 )); then
            cleanup_derived_data "$derived_data_dir"
            derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-mobile-tests.XXXXXX")"
        fi
    fi

    attempt_xcresult="$derived_data_dir/OpenBurnBarMobileTests-attempt-$test_attempt.xcresult"
    xcodebuild_log="$(mktemp "$derived_data_root/openburnbar-mobile-tests-log-XXXXXX")"

    preclean_stale_mobile_processes
    if [[ "$uses_ios_simulator" -eq 1 ]]; then
        ensure_simulator_booted
    fi

    populate_xcodebuild_args "$derived_data_dir" "$attempt_xcresult"

    attempt_start_epoch="$(date +%s)"
    set +e
    xcodebuild test "${xcodebuild_args[@]}" 2>&1 | tee "$xcodebuild_log"
    last_test_exit_code=${PIPESTATUS[0]}
    set -e
    attempt_end_epoch="$(date +%s)"
    attempt_duration=$((attempt_end_epoch - attempt_start_epoch))

    if [ "$last_test_exit_code" -eq 0 ]; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "passed" "$attempt_duration" "$attempt_xcresult"
        final_exit_code=0
        final_outcome="passed"
        final_xcresult="$attempt_xcresult"
        break
    fi

    if is_xcode_false_negative_pass "$xcodebuild_log"; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "xcode_false_negative_passed" "$attempt_duration" "$attempt_xcresult"
        echo ">>> xcodebuild exited $last_test_exit_code after XCTest reported Selected tests passed with 0 failures; accepting attempt as passed."
        final_exit_code=0
        final_outcome="passed"
        final_xcresult="$attempt_xcresult"
        break
    fi

    if is_known_hang "$xcodebuild_log" && [ "$test_attempt" -lt "$max_test_attempts" ]; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "hang_retry" "$attempt_duration" "$attempt_xcresult"
        echo ">>> Known XCTest hang detected on mobile attempt $test_attempt; retrying."
        test_attempt=$((test_attempt + 1))
        continue
    fi

    emit_attempt_event "$test_attempt" "$last_test_exit_code" "failed" "$attempt_duration" "$attempt_xcresult"
    final_exit_code="$last_test_exit_code"
    final_outcome="failed"
    final_xcresult="$attempt_xcresult"
    break
done

if [[ -n "$final_xcresult" && "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" && "$final_outcome" == "passed" ]]; then
    rm -rf "$canonical_xcresult_path"
    cp -R "$final_xcresult" "$canonical_xcresult_path"
fi

invocation_end_epoch="$(date +%s)"
total_duration=$((invocation_end_epoch - $(date -r "$attempt_log_path" +%s 2>/dev/null || echo "$invocation_end_epoch")))
emit_summary_event "$final_outcome" "$test_attempt" "$total_duration" "$final_exit_code"

echo ">>> Mobile test summary: outcome=$final_outcome attempts=$test_attempt exit=$final_exit_code"
echo ">>> Telemetry: $attempt_log_path"

exit "$final_exit_code"
