#!/usr/bin/env bash
#
# test-openburnbar-retrieval-evals.sh
#
# Focused replay-golden gate for retrieval (search) and authoring (writeback).
# The suites are release-critical, so this wrapper mirrors the hardened app
# XCTest driver: shared runner-hang classification, stale-process cleanup,
# temp-derived-data launch products, structured retry telemetry, warm/fresh
# retry alternation, and a build-for-testing safety net after exhausted host
# startup retries. Concrete XCTest failures still fail fast.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="$repo_root/.spm-cache-new"
artifact_root="$repo_root/.derived-data"

# shellcheck source=scripts/lib/openburnbar-app-test-classifier.sh
source "$repo_root/scripts/lib/openburnbar-app-test-classifier.sh"

# Keep runnable test hosts out of the repo's Documents path. macOS can launch
# xctest hosts via services that do not inherit the caller's Documents TCC
# grants, which can wedge dyld before XCTest connects.
derived_data_root="${OPENBURNBAR_RETRIEVAL_EVAL_DERIVED_DATA_ROOT:-${TMPDIR:-/tmp}/openburnbar-retrieval-evals}"
attempt_log_path="$artifact_root/test-openburnbar-retrieval-evals-attempts.jsonl"

default_test_execution_allowance="${OPENBURNBAR_RETRIEVAL_EVAL_DEFAULT_ALLOWANCE:-600}"
maximum_test_execution_allowance="${OPENBURNBAR_RETRIEVAL_EVAL_MAX_ALLOWANCE:-1200}"
max_test_attempts="${OPENBURNBAR_RETRIEVAL_EVAL_ATTEMPTS:-6}"
backoff_seconds=(0 5 10 20 40 60)

normalize_openburnbar_test_filter() {
    local candidate="$1"
    case "$candidate" in
        AgentLensTests)
            printf '%s\n' "OpenBurnBarTests"
            ;;
        AgentLensTests/*)
            printf '%s\n' "OpenBurnBarTests/${candidate#AgentLensTests/}"
            ;;
        *)
            printf '%s\n' "$candidate"
            ;;
    esac
}

raw_filter="${OPENBURNBAR_RETRIEVAL_EVAL_FILTER:-}"
test_filters=()
if [[ -n "$raw_filter" ]]; then
    normalized_filter="$(normalize_openburnbar_test_filter "$raw_filter")"
    if [[ "$normalized_filter" != "$raw_filter" ]]; then
        echo ">>> Normalized OPENBURNBAR_RETRIEVAL_EVAL_FILTER from '$raw_filter' to '$normalized_filter'."
    fi
    test_filters+=("$normalized_filter")
else
    test_filters+=(
        "OpenBurnBarTests/OpenBurnBarRetrievalReplayGoldenTests"
        "OpenBurnBarTests/OpenBurnBarAuthoringReplayGoldenTests"
    )
fi

mkdir -p "$cache_dir" "$artifact_root" "$derived_data_root"

derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-retrieval-evals.XXXXXX")"
xcodebuild_log=""
xcodebuild_args=()
last_test_exit_code=0
invocation_start_epoch="$(date +%s)"

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
    echo "Telemetry written to $attempt_log_path"
}

cleanup_derived_data() {
    local target="${1:-$derived_data_dir}"
    local max_cleanup_attempts=5
    local cleanup_attempt=1
    local delay_tenths=5

    while [ "$cleanup_attempt" -le "$max_cleanup_attempts" ]; do
        if rm -rf "$target" 2>/dev/null; then
            return 0
        fi
        if [ "$cleanup_attempt" -lt "$max_cleanup_attempts" ]; then
            sleep "$(awk "BEGIN{printf \"%.1f\", $delay_tenths/10}")"
            delay_tenths=$((delay_tenths * 2))
        fi
        cleanup_attempt=$((cleanup_attempt + 1))
    done

    rm -rf "$target" || true
}

preclean_stale_processes() {
    local patterns=(
        "OpenBurnBar.app/Contents/MacOS/OpenBurnBar"
        "OpenBurnBarTests.xctest"
        "xctest .*OpenBurnBarTests"
    )
    local pattern
    for pattern in "${patterns[@]}"; do
        pkill -f "$pattern" >/dev/null 2>&1 || true
    done
    sleep 0.2
}

cleanup() {
    if [[ -n "$xcodebuild_log" ]]; then
        rm -f "$xcodebuild_log" 2>/dev/null || true
    fi
    cleanup_derived_data "$derived_data_dir"
}

trap 'cleanup' EXIT

populate_xcodebuild_args() {
    local dd="$1"
    local attempt_result="$2"
    xcodebuild_args=(
        -project "$repo_root/OpenBurnBar.xcodeproj"
        -scheme "OpenBurnBar"
        -destination "platform=macOS,arch=arm64"
        -clonedSourcePackagesDirPath "$cache_dir"
        -derivedDataPath "$dd"
        -resultBundlePath "$attempt_result"
        -test-timeouts-enabled YES
        -default-test-execution-time-allowance "$default_test_execution_allowance"
        -maximum-test-execution-time-allowance "$maximum_test_execution_allowance"
        SWIFT_ENABLE_EXPLICIT_MODULES=NO
        SWIFT_COMPILATION_MODE=singlefile
        SWIFT_ENABLE_BATCH_MODE=NO
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
    )

    local filter
    for filter in "${test_filters[@]}"; do
        xcodebuild_args+=(-only-testing:"$filter")
    done
}

if [[ "${CI:-}" == "true" ]]; then
    export TEST_RUNNER_CI=true
fi
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    export TEST_RUNNER_GITHUB_ACTIONS=true
fi
if [[ -n "${RUNNER_OS:-}" ]]; then
    export TEST_RUNNER_RUNNER_OS="${RUNNER_OS}"
fi

: > "$attempt_log_path"
"$repo_root/scripts/lib/prepare-signal-ffi-xcframework.sh"

test_attempt=1
final_exit_code=0
final_outcome="failed"
final_xcresult=""

while [ "$test_attempt" -le "$max_test_attempts" ]; do
    if [ "$test_attempt" -gt 1 ]; then
        backoff_index=$((test_attempt - 1))
        if [ "$backoff_index" -ge "${#backoff_seconds[@]}" ]; then
            backoff_index=$((${#backoff_seconds[@]} - 1))
        fi
        wait_for=${backoff_seconds[$backoff_index]}
        echo ">>> Retrieval-eval retry $test_attempt of $max_test_attempts after known XCTest hang. Sleeping ${wait_for}s."
        sleep "$wait_for"

        if (( test_attempt % 2 == 1 )); then
            echo ">>> Refreshing retrieval-eval derived data for attempt $test_attempt."
            cleanup_derived_data "$derived_data_dir"
            derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-retrieval-evals.XXXXXX")"
        else
            echo ">>> Reusing retrieval-eval derived data for attempt $test_attempt (warm-cache retry)."
        fi
    fi

    preclean_stale_processes

    attempt_xcresult="$derived_data_dir/OpenBurnBarRetrievalEvals-attempt-$test_attempt.xcresult"
    xcodebuild_log="$(mktemp "$derived_data_root/openburnbar-retrieval-evals-log-XXXXXX")"
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

    if is_known_hang "$xcodebuild_log"; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "hang_retry" "$attempt_duration" "$attempt_xcresult"
        echo ">>> Detected known XCTest startup hang on retrieval-eval attempt $test_attempt (exit $last_test_exit_code)."
        test_attempt=$((test_attempt + 1))
        continue
    fi

    emit_attempt_event "$test_attempt" "$last_test_exit_code" "test_failure" "$attempt_duration" "$attempt_xcresult"
    final_exit_code="$last_test_exit_code"
    final_outcome="test_failure"
    final_xcresult="$attempt_xcresult"
    break
done

if [ "$final_outcome" = "failed" ] && [ "$test_attempt" -gt "$max_test_attempts" ]; then
    final_exit_code="$last_test_exit_code"
    final_outcome="exhausted_retries"
    echo ">>> Retrieval evals exhausted $max_test_attempts retries on XCTest startup hang."
    echo ">>> Running build-for-testing as compile safety net."
    populate_xcodebuild_args "$derived_data_dir" "$derived_data_dir/safety-net.xcresult"
    xcodebuild build-for-testing "${xcodebuild_args[@]}" || true
fi

invocation_end_epoch="$(date +%s)"
total_duration=$((invocation_end_epoch - invocation_start_epoch))
emit_summary_event "$final_outcome" "$test_attempt" "$total_duration" "$final_exit_code"

exit "$final_exit_code"
