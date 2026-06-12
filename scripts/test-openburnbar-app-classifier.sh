#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=scripts/lib/openburnbar-app-test-classifier.sh
source "$repo_root/scripts/lib/openburnbar-app-test-classifier.sh"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-app-classifier.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

write_fixture() {
    local name="$1"
    local dest="$tmpdir/$name.log"
    cat > "$dest"
    printf '%s\n' "$dest"
}

assert_true() {
    local label="$1"
    shift
    if ! "$@"; then
        echo "FAIL: expected true: $label" >&2
        exit 1
    fi
}

assert_false() {
    local label="$1"
    shift
    if "$@"; then
        echo "FAIL: expected false: $label" >&2
        exit 1
    fi
}

false_negative_log="$(write_fixture false-negative <<'LOG'
Test Suite 'Selected tests' started at 2026-06-03 17:02:02.338.
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
Test Suite 'OpenBurnBarTests.xctest' passed at 2026-06-03 17:02:03.411.
	 Executed 21 tests, with 0 failures (0 unexpected) in 1.063 (1.072) seconds
Test Suite 'Selected tests' passed at 2026-06-03 17:02:03.411.
	 Executed 21 tests, with 0 failures (0 unexpected) in 1.063 (1.073) seconds
Test session results, code coverage, and logs:
	/var/folders/.../OpenBurnBarTests-attempt-1.xcresult

** TEST FAILED **
LOG
)"

concrete_failure_log="$(write_fixture concrete-failure <<'LOG'
Test Suite 'Selected tests' started at 2026-06-03 17:02:02.338.
Test Case '-[OpenBurnBarTests.UsageSyncRoundTripTests test_usageUpload_writesToFirestoreAndMarksSynced]' failed (0.123 seconds).
Test Suite 'Selected tests' failed at 2026-06-03 17:02:03.411.
	 Executed 1 test, with 1 failure (0 unexpected) in 1.063 (1.073) seconds
Failing tests:
	OpenBurnBarTests.UsageSyncRoundTripTests/test_usageUpload_writesToFirestoreAndMarksSynced
LOG
)"

recovered_retry_log="$(write_fixture recovered-retry <<'LOG'
Test Suite 'Selected tests' started at 2026-06-03 16:52:00.000.
Test Case '-[OpenBurnBarTests.MacAppStoreReviewComplianceTests testMacCloudStoreHasNativeStoreKitPurchaseAndLegalLinks]' failed (0.112 seconds).
Test Suite 'MacAppStoreReviewComplianceTests' failed at 2026-06-03 16:53:16.452.
	 Executed 6 tests, with 2 failures (0 unexpected) in 0.148 (0.151) seconds
Test Suite 'Selected tests' started at 2026-06-03 17:02:02.338.
Test Suite 'OpenBurnBarTests.xctest' passed at 2026-06-03 17:02:03.411.
	 Executed 21 tests, with 0 failures (0 unexpected) in 1.063 (1.072) seconds
Test Suite 'Selected tests' passed at 2026-06-03 17:02:03.411.
	 Executed 21 tests, with 0 failures (0 unexpected) in 1.063 (1.073) seconds
** TEST FAILED **
LOG
)"

final_failing_tests_log="$(write_fixture final-failing-tests <<'LOG'
Test Suite 'Selected tests' started at 2026-06-03 17:02:02.338.
Test Suite 'Selected tests' passed at 2026-06-03 17:02:03.411.
	 Executed 21 tests, with 0 failures (0 unexpected) in 1.063 (1.073) seconds
Failing tests:
	OpenBurnBarTests.SomeTests/test_realRegression
** TEST FAILED **
LOG
)"

hang_log="$(write_fixture hang <<'LOG'
Test Suite 'Selected tests' started at 2026-06-03 16:58:03.425.
freed pointer was not the last allocation
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.

** TEST FAILED **
LOG
)"

hang_with_failure_log="$(write_fixture hang-with-failure <<'LOG'
Test Suite 'Selected tests' started at 2026-06-03 16:58:03.425.
freed pointer was not the last allocation
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
Test Case '-[OpenBurnBarTests.SomeTests test_realRegression]' failed (0.123 seconds).
LOG
)"

timeout_restart_log="$(write_fixture timeout-restart <<'LOG'
Test Suite 'Selected tests' started at 2026-06-12 22:42:42.654.
Test Case '-[OpenBurnBarTests.MediaSessionCoordinatorTests testStartScreenShareRollsBackAfterCaptureStartFailureAndCanRetry]' started.
Test Case '-[OpenBurnBarTests.MediaSessionCoordinatorTests testStartScreenShareRollsBackAfterCaptureStartFailureAndCanRetry]' exceeded execution time allowance of 10 minutes. The test may have hung.
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
Test Suite 'Selected tests' passed at 2026-06-12 22:56:21.884.
     Executed 2032 tests, with 3 tests skipped and 0 failures (0 unexpected) in 194.596 (196.137) seconds
Failing tests:
    MediaSessionCoordinatorTests.testStartScreenShareRollsBackAfterCaptureStartFailureAndCanRetry()
** TEST FAILED **
LOG
)"

timeout_restart_with_assertion_log="$(write_fixture timeout-restart-with-assertion <<'LOG'
Test Suite 'Selected tests' started at 2026-06-12 22:42:42.654.
Test Case '-[OpenBurnBarTests.SomeTests test_realRegression]' failed (0.123 seconds).
Test Case '-[OpenBurnBarTests.SomeTests test_slowCleanup]' exceeded execution time allowance of 10 minutes. The test may have hung.
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
LOG
)"

unknown_failure_log="$(write_fixture unknown-failure <<'LOG'
** TEST FAILED **
LOG
)"

assert_true "green XCTest summary plus trailing Xcode failure is accepted" is_xcode_false_negative_pass "$false_negative_log"
assert_false "concrete XCTest failure is not accepted as a false-negative pass" is_xcode_false_negative_pass "$concrete_failure_log"
assert_true "earlier Xcode retry failure is accepted only when final Selected tests summary is green" is_xcode_false_negative_pass "$recovered_retry_log"
assert_false "final failing-tests section is not hidden by a stale green summary" is_xcode_false_negative_pass "$final_failing_tests_log"
assert_true "runner crash without concrete XCTest failure is retryable" is_known_hang "$hang_log"
assert_false "runner crash with concrete XCTest failure is not hidden as infrastructure" is_known_hang "$hang_with_failure_log"
assert_true "test-host timeout relaunch with stale failing footer is retryable" is_known_hang "$timeout_restart_log"
assert_false "test-host timeout relaunch with assertion failure is not hidden" is_known_hang "$timeout_restart_with_assertion_log"
assert_false "unknown failure is not retryable" is_known_hang "$unknown_failure_log"

echo "OpenBurnBar app-test classifier fixtures passed."
