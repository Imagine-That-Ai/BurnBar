#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=scripts/lib/openburnbar-app-test-classifier.sh
source "$repo_root/scripts/lib/openburnbar-app-test-classifier.sh"

classifier_tmp_root="${OPENBURNBAR_APP_TEST_CLASSIFIER_TMPDIR:-/tmp}"
mkdir -p "$classifier_tmp_root"
tmpdir="$(mktemp -d "${classifier_tmp_root%/}/openburnbar-app-classifier.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
timeout_supervisor="$repo_root/scripts/lib/run_xcodebuild_with_timeout_containment.py"

fake_xcodebuild="$tmpdir/fake_xcodebuild.py"
cat >"$fake_xcodebuild" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import signal
import sys
import time


def exit_for_signal(exit_code: int):
    def handler(_signum, _frame):
        raise SystemExit(exit_code)

    return handler


signal.signal(signal.SIGINT, exit_for_signal(130))
signal.signal(signal.SIGTERM, exit_for_signal(143))

mode = sys.argv[1]
if mode == "timeout-restart":
    print("Test Suite 'Selected tests' started.", flush=True)
    print("Test Case '-[OpenBurnBarTests.VisualTests test_one]' started.", flush=True)
    print(
        "Test Case '-[OpenBurnBarTests.VisualTests test_one]' exceeded execution "
        "time allowance of 10 minutes. The test may have hung.",
        flush=True,
    )
    print(
        "Restarting after unexpected exit, crash, or test timeout; summary will "
        "include totals from previous launches.",
        flush=True,
    )
    time.sleep(0.5)
    for test_number in range(2, 24):
        print(
            "Test Case "
            f"'-[OpenBurnBarTests.VisualTests test_{test_number}]' started.",
            flush=True,
        )
        time.sleep(0.1)
elif mode == "timeout-without-restart":
    print("Test Case '-[OpenBurnBarTests.VisualTests test_one]' started.", flush=True)
    print(
        "Test Case '-[OpenBurnBarTests.VisualTests test_one]' exceeded execution "
        "time allowance of 10 minutes. The test may have hung.",
        flush=True,
    )
    time.sleep(1)
    print("Test Case '-[OpenBurnBarTests.VisualTests test_two]' started.", flush=True)
elif mode == "restart-before-timeout":
    print("Test Case '-[OpenBurnBarTests.VisualTests test_one]' started.", flush=True)
    print(
        "Restarting after unexpected exit, crash, or test timeout; summary will "
        "include totals from previous launches.",
        flush=True,
    )
    print(
        "Test Case '-[OpenBurnBarTests.VisualTests test_one]' exceeded execution "
        "time allowance of 10 minutes. The test may have hung.",
        flush=True,
    )
    time.sleep(1)
    print("Test Case '-[OpenBurnBarTests.VisualTests test_two]' started.", flush=True)
elif mode == "timeout-ignore-int":
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    print("Test Case '-[OpenBurnBarTests.VisualTests test_one]' started.", flush=True)
    print(
        "Test Case '-[OpenBurnBarTests.VisualTests test_one]' exceeded execution "
        "time allowance of 10 minutes. The test may have hung.",
        flush=True,
    )
    print(
        "Restarting after unexpected exit, crash, or test timeout; summary will "
        "include totals from previous launches.",
        flush=True,
    )
    time.sleep(2)
    print("Test Case '-[OpenBurnBarTests.VisualTests test_two]' started.", flush=True)
elif mode == "timeout-ignore-int-term":
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print("Test Case '-[OpenBurnBarTests.VisualTests test_one]' started.", flush=True)
    print(
        "Test Case '-[OpenBurnBarTests.VisualTests test_one]' exceeded execution "
        "time allowance of 10 minutes. The test may have hung.",
        flush=True,
    )
    print(
        "Restarting after unexpected exit, crash, or test timeout; summary will "
        "include totals from previous launches.",
        flush=True,
    )
    time.sleep(2)
    print("Test Case '-[OpenBurnBarTests.VisualTests test_two]' started.", flush=True)
elif mode == "silent-hang":
    time.sleep(2)
elif mode == "assertion":
    print("Test Suite 'Selected tests' started.", flush=True)
    print(
        "Test Case '-[OpenBurnBarTests.SecurityTests test_realRegression]' failed "
        "(0.123 seconds).",
        flush=True,
    )
    print("Executed 1 test, with 1 failure (0 unexpected).", flush=True)
    raise SystemExit(65)
elif mode == "pass":
    print("Test Suite 'Selected tests' passed.", flush=True)
    print("Executed 1 test, with 0 failures (0 unexpected).", flush=True)
else:
    raise SystemExit(f"unknown fixture mode: {mode}")
PY

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

assert_equals() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: $label" >&2
        printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
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

final_green_bundle_with_stale_footer_log="$(write_fixture final-green-bundle-with-stale-footer <<'LOG'
Test Suite 'Selected tests' started at 2026-06-15 23:30:09.118.
Test Suite 'OpenBurnBarMobileTests.xctest' passed at 2026-06-15 23:37:29.625.
	 Executed 528 tests, with 3 tests skipped and 0 failures (0 unexpected) in 19.317 (23.614) seconds
Test Suite 'Selected tests' passed at 2026-06-15 23:37:29.630.
	 Executed 528 tests, with 3 tests skipped and 0 failures (0 unexpected) in 19.317 (23.620) seconds
Test session results, code coverage, and logs:
	/var/folders/.../OpenBurnBarMobileTests-attempt-1.xcresult

Failing tests:
	HermesServiceTests.testExplicitSelectedModelWithIneligibleLiveRouteStopsBeforeRelayRequest()
	MercuryPersonalizationTests.testWallpaperAccentSamplerReturnsAccentForRedSquare()

** TEST FAILED **
LOG
)"

xcode_exit65_final_green_after_stale_failures_log="$(write_fixture xcode-exit65-final-green-after-stale-failures <<'LOG'
Test Suite 'Selected tests' started at 2026-06-20 01:54:33.024.
Test Case '-[OpenBurnBarTests.MediaSessionCoordinatorTests testActiveScreenShareStopsWhenAdmissionIsRevoked]' failed (0.112 seconds).
Test Case '-[OpenBurnBarTests.ProjectionPipelineServiceMattersTests test_artifactReuseCopyFailure_reembedsChunks_neverLeavingThemUnsearchable]' failed (0.141 seconds).
Test Suite 'OpenBurnBarTests.xctest' passed at 2026-06-20 02:33:40.655.
	 Executed 1736 tests, with 0 failures (0 unexpected) in 124.034 (126.282) seconds
Test Suite 'Selected tests' passed at 2026-06-20 02:33:40.655.
	 Executed 1736 tests, with 0 failures (0 unexpected) in 124.034 (126.284) seconds
Test session results, code coverage, and logs:
	/var/folders/.../OpenBurnBarTests-attempt-1.xcresult

Failing tests:
	ChatSessionControllerSearchStateTests.test_performSearch_ignoresStaleOutOfOrderResults()
	MediaSessionCoordinatorTests.testActiveScreenShareStopsWhenAdmissionIsRevoked()
	ProjectionPipelineServiceMattersTests.test_artifactReuseCopyFailure_reembedsChunks_neverLeavingThemUnsearchable()

** TEST FAILED **
LOG
)"

restarted_final_green_with_stale_footer_log="$(write_fixture restarted-final-green-with-stale-footer <<'LOG'
Test Suite 'Selected tests' started at 2026-06-14 17:50:09.282.
Test Case '-[OpenBurnBarTests.CLIBridgeTests test_agentToolBroker_shellRunCannotWriteOutsideWorkspace]' failed (1.011 seconds).
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
Test Suite 'Selected tests' started at 2026-06-14 17:53:55.145.
Test Suite 'OpenBurnBarTests.xctest' passed at 2026-06-14 17:54:46.313.
	 Executed 1279 tests, with 0 failures (0 unexpected) in 49.338 (51.167) seconds
Test Suite 'Selected tests' passed at 2026-06-14 17:54:46.314.
	 Executed 1279 tests, with 0 failures (0 unexpected) in 49.338 (51.168) seconds
Failing tests:
	CLIBridgeTests.test_agentToolBroker_shellRunCannotWriteOutsideWorkspace()
** TEST FAILED **
LOG
)"

restarted_final_run_failure_log="$(write_fixture restarted-final-run-failure <<'LOG'
Test Suite 'Selected tests' started at 2026-06-14 17:50:09.282.
Test Case '-[OpenBurnBarTests.CLIBridgeTests test_agentToolBroker_shellRunCannotWriteOutsideWorkspace]' failed (1.011 seconds).
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
Test Suite 'Selected tests' started at 2026-06-14 17:53:55.145.
Test Case '-[OpenBurnBarTests.SomeTests test_realRegression]' failed (0.123 seconds).
Test Suite 'Selected tests' failed at 2026-06-14 17:54:46.314.
	 Executed 1279 tests, with 1 failure (0 unexpected) in 49.338 (51.168) seconds
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

timeout_restart_final_failure_summary_log="$(write_fixture timeout-restart-final-failure-summary <<'LOG'
Test Suite 'Selected tests' started at 2026-06-12 22:42:42.654.
Test Case '-[OpenBurnBarTests.SomeTests test_slowCleanup]' exceeded execution time allowance of 10 minutes. The test may have hung.
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
Test Suite 'Selected tests' failed at 2026-06-12 22:56:21.884.
     Executed 2032 tests, with 3 tests skipped and 1 failure (0 unexpected) in 194.596 (196.137) seconds
LOG
)"

timeout_restart_stale_green_then_failed_log="$(write_fixture timeout-restart-stale-green-then-failed <<'LOG'
Test Suite 'Selected tests' started at 2026-06-12 22:42:42.654.
Test Case '-[OpenBurnBarTests.SomeTests test_slowCleanup]' exceeded execution time allowance of 10 minutes. The test may have hung.
Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.
Test Suite 'Selected tests' passed at 2026-06-12 22:51:04.111.
     Executed 2032 tests, with 3 tests skipped and 0 failures (0 unexpected) in 194.596 (196.137) seconds
Test Suite 'Selected tests' failed at 2026-06-12 22:56:21.884.
     Executed 2032 tests, with 3 tests skipped and 1 failure (0 unexpected) in 194.596 (196.137) seconds
LOG
)"

unknown_failure_log="$(write_fixture unknown-failure <<'LOG'
** TEST FAILED **
LOG
)"

green_summary_then_build_error_log="$(write_fixture green-summary-then-build-error <<'LOG'
Test Suite 'Selected tests' started at 2026-06-21 21:30:00.000.
Test Suite 'OpenBurnBarTests.xctest' passed at 2026-06-21 21:31:00.000.
     Executed 21 tests, with 0 failures (0 unexpected) in 60.000 (60.000) seconds
Test Suite 'Selected tests' passed at 2026-06-21 21:31:00.000.
     Executed 21 tests, with 0 failures (0 unexpected) in 60.000 (60.000) seconds
xcodebuild: error: The workspace named "OpenBurnBar" does not contain a scheme named "OpenBurnBar".
LOG
)"

green_summary_then_codesign_error_log="$(write_fixture green-summary-then-codesign-error <<'LOG'
Test Suite 'Selected tests' started at 2026-06-21 21:30:00.000.
Test Suite 'OpenBurnBarTests.xctest' passed at 2026-06-21 21:31:00.000.
     Executed 21 tests, with 0 failures (0 unexpected) in 60.000 (60.000) seconds
Test Suite 'Selected tests' passed at 2026-06-21 21:31:00.000.
     Executed 21 tests, with 0 failures (0 unexpected) in 60.000 (60.000) seconds
Command CodeSign failed with a nonzero exit code
LOG
)"

swiftpm_dependency_timeout_log="$(write_fixture swiftpm-dependency-timeout <<'LOG'
failed downloading https://github.com/sqlcipher/SQLCipher.swift/releases/download/4.16.0/SQLCipher.xcframework.zip which is required by binary target SQLCipher: downloadError("The request timed out.")
failed downloading https://dl.google.com/firebase/ios/swiftpm/11.15.0/FirebaseAnalytics.zip which is required by binary target FirebaseAnalytics: downloadError("The request timed out.")
xcodebuild: error: Could not resolve package dependencies:
  failed downloading https://dl.google.com/firebase/ios/bin/grpc/1.69.1/rc0/grpc.zip which is required by binary target grpc: downloadError("The request timed out.")
LOG
)"

swiftpm_clone_timeout_log="$(write_fixture swiftpm-clone-timeout <<'LOG'
skipping cache due to an error: Failed to clone repository https://github.com/google/GoogleSignIn-iOS:
    fatal: unable to access https://github.com/google/GoogleSignIn-iOS/: Failed to connect to github.com port 443 after 25176 ms: Could not connect to server
LOG
)"

swiftpm_timeout_with_xctest_failure_log="$(write_fixture swiftpm-timeout-with-xctest-failure <<'LOG'
Executed 1 test, with 1 failure (0 unexpected) in 0.123 (0.124) seconds
failed downloading https://dl.google.com/firebase/ios/swiftpm/11.15.0/FirebaseAnalytics.zip which is required by binary target FirebaseAnalytics: downloadError("The request timed out.")
xcodebuild: error: Could not resolve package dependencies:
LOG
)"

swiftpm_cache_and_signal_ffi_mapping_log="$(write_fixture swiftpm-cache-and-signal-ffi-mapping <<'LOG'
Git command git -C /Users/runner/Library/Caches/org.swift.swiftpm/repositories/swift-testing-59a7fdfb config --get remote.origin.url failed: fatal: cannot change to /Users/runner/Library/Caches/org.swift.swiftpm/repositories/swift-testing-59a7fdfb: No such file or directory
binary target OpenBurnBarSignalFfi could not be mapped to an artifact with expected name OpenBurnBarSignalFfi
xcodebuild: error: Could not resolve package dependencies:
LOG
)"

swiftpm_xcode_internal_package_graph_crash_log="$(write_fixture swiftpm-xcode-internal-package-graph-crash <<'LOG'
Fetching from https://github.com/google/grpc-binary.git
Checking out 1.69.1 of package 'grpc-binary'
*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '*** -[NSMutableArray insertObjects:atIndexes:]: count of array (32) differs from count of index set (31)'
8   IDESwiftPackageCore                 0x0000000120da4830 IDESwiftWorkspace.DependencyPackagesGroup.sortedInsert(of:)
11  IDESwiftPackageCore                 0x0000000120cec4ac IDESPMWorkspaceDelegate.packageGraphDidFinishAction
23  SwiftPM                             0x0000000124fdf201 SPMWorkspace.packageGraphActionFinished
** INTERNAL ERROR: Uncaught exception **
Uncaught Exception: *** -[NSMutableArray insertObjects:atIndexes:]: count of array (32) differs from count of index set (31)
./scripts/test-openburnbar-app.sh: line 484: 94247 Abort trap: 6           xcodebuild test "${xcodebuild_args[@]}" 2>&1
LOG
)"

xcode_build_service_crash_log="$(write_fixture xcode-build-service-crash <<'LOG'
error: unexpected service error: The Xcode build system has crashed. Build again to continue.
Testing failed:
    unexpected service error: The Xcode build system has crashed. Build again to continue.
    Command SwiftCompile failed with a nonzero exit code
Testing cancelled because the build failed.
** TEST FAILED **
LOG
)"

xcode_build_service_crash_with_test_failure_log="$(write_fixture xcode-build-service-crash-with-test-failure <<'LOG'
Test Case '-[OpenBurnBarTests.SafariLearningTimelineViewModelTests testMutationFailurePreservesSelection]' failed (0.123 seconds).
Executed 1 test, with 1 failure (0 unexpected) in 0.123 (0.124) seconds
error: unexpected service error: The Xcode build system has crashed. Build again to continue.
** TEST FAILED **
LOG
)"

interleaved_security_failure_log="$(write_fixture interleaved-security-failure <<'LOG'
Test Suite 'Selected tests' started at 2026-06-19 03:17:42.489.
2026-06-19 03:20:49.210291+0000 OpenBurnBar[80/Users/runner/work/BurnBar/BurnBar/AgentLensTests/Active/ComputerUse/PhoneControlReceiverTests.swift:1449: error: -[OpenBurnBarTests.PhoneControlReceiverTests testStrictAttestationDeniesClipboardBeforePasteboardOrInputMutation] : XCTAssertEqual failed: ("accepted") is not equal to ("denied")
/Users/runner/work/BurnBar/BurnBar/AgentLensTests/Active/ComputerUse/PhoneControlReceiverTests.swift:1450: error: -[OpenBurnBarTests.PhoneControlReceiverTests testStrictAttestationDeniesClipboardBeforePasteboardOrInputMutation] : XCTAssertEqual failed: ("nil") is not equal to ("Optional("mac_attestation_unbound")")
Test Case '-[OpenBurnBarTests.PhoneControlReceiverTests testStrictAttestationDeniesClipboardBeforePasteboardOrInputMutation]' failed (0.068 seconds).
Test Suite 'PhoneControlReceiverTests' failed at 2026-06-19 03:20:49.246.
	 Executed 22 tests, with 6 failures (0 unexpected) in 2.059 (2.086) seconds
LOG
)"

assert_true "interleaved security assertion failure is concrete XCTest failure" openburnbar_app_test_has_concrete_xctest_failure "$interleaved_security_failure_log"
assert_true "interleaved security assertion failure is terminal concrete failure" openburnbar_app_test_has_terminal_concrete_xctest_failure "$interleaved_security_failure_log"
assert_true "green XCTest summary plus trailing Xcode failure is accepted" is_xcode_false_negative_pass "$false_negative_log"
assert_false "concrete XCTest failure is not accepted as a false-negative pass" is_xcode_false_negative_pass "$concrete_failure_log"
assert_true "concrete XCTest failure remains terminal after false-negative guard" openburnbar_app_test_has_terminal_concrete_xctest_failure "$concrete_failure_log"
assert_true "earlier Xcode retry failure is accepted only when final Selected tests summary is green" is_xcode_false_negative_pass "$recovered_retry_log"
assert_false "final failing-tests section is not hidden by a stale green summary" is_xcode_false_negative_pass "$final_failing_tests_log"
assert_false "final failing-tests footer is not hidden by green bundle and Selected tests summaries" is_xcode_false_negative_pass "$final_green_bundle_with_stale_footer_log"
assert_false "earlier failures plus final failing-tests footer are not hidden by green summaries" is_xcode_false_negative_pass "$xcode_exit65_final_green_after_stale_failures_log"
assert_true "earlier failures plus final failing-tests footer remain terminal" openburnbar_app_test_has_terminal_concrete_xctest_failure "$xcode_exit65_final_green_after_stale_failures_log"
assert_false "runner restart does not erase a final failing-tests footer" is_xcode_false_negative_pass "$restarted_final_green_with_stale_footer_log"
assert_true "runner-restart failing-tests footer remains terminal" openburnbar_app_test_has_terminal_concrete_xctest_failure "$restarted_final_green_with_stale_footer_log"
assert_false "runner-restart final-run assertion failure is not hidden" is_xcode_false_negative_pass "$restarted_final_run_failure_log"
assert_true "runner-restart final-run assertion failure remains terminal concrete failure" openburnbar_app_test_has_terminal_concrete_xctest_failure "$restarted_final_run_failure_log"
assert_true "runner crash without concrete XCTest failure is retryable" is_known_hang "$hang_log"
assert_false "runner crash with concrete XCTest failure is not hidden as infrastructure" is_known_hang "$hang_with_failure_log"
assert_false "test-host timeout relaunch is not accepted as false-negative pass" is_xcode_false_negative_pass "$timeout_restart_log"
assert_false "test-host timeout relaunch with stale failing footer is not terminal concrete failure" openburnbar_app_test_has_terminal_concrete_xctest_failure "$timeout_restart_log"
assert_true "test-host timeout relaunch with stale failing footer is retryable" is_known_hang "$timeout_restart_log"
assert_false "test-host timeout relaunch with stale failing footer is not terminal concrete failure" openburnbar_app_test_has_terminal_concrete_xctest_failure "$timeout_restart_log"
assert_false "test-host timeout relaunch with assertion failure is not hidden" is_known_hang "$timeout_restart_with_assertion_log"
assert_true "test-host timeout relaunch with final failure summary remains terminal" openburnbar_app_test_has_terminal_concrete_xctest_failure "$timeout_restart_final_failure_summary_log"
assert_false "test-host timeout relaunch with final failure summary is not retryable" is_known_hang "$timeout_restart_final_failure_summary_log"
assert_false "later failed Selected tests summary resets stale green state" openburnbar_app_test_final_selected_summary_is_green "$timeout_restart_stale_green_then_failed_log"
assert_true "later failed Selected tests summary remains terminal after stale green summary" openburnbar_app_test_has_terminal_concrete_xctest_failure "$timeout_restart_stale_green_then_failed_log"
assert_false "later failed Selected tests summary is not retryable after stale green summary" is_known_hang "$timeout_restart_stale_green_then_failed_log"
assert_false "unknown failure is not retryable" is_known_hang "$unknown_failure_log"
assert_false "green XCTest summary plus later xcodebuild error is not accepted without test-failed marker" is_xcode_false_negative_pass "$green_summary_then_build_error_log"
assert_false "green XCTest summary plus codesign error is not accepted without test-failed marker" is_xcode_false_negative_pass "$green_summary_then_codesign_error_log"
assert_true "SwiftPM binary artifact download timeout is retryable infrastructure" is_swiftpm_dependency_resolution_transient "$swiftpm_dependency_timeout_log"
assert_true "SwiftPM package clone network timeout is retryable infrastructure" is_swiftpm_dependency_resolution_transient "$swiftpm_clone_timeout_log"
assert_false "SwiftPM timeout does not hide concrete XCTest failure" is_swiftpm_dependency_resolution_transient "$swiftpm_timeout_with_xctest_failure_log"
assert_true "SwiftPM cache race plus Signal FFI mapping miss is retryable infrastructure" is_swiftpm_dependency_resolution_transient "$swiftpm_cache_and_signal_ffi_mapping_log"
assert_true "Xcode SwiftPM package graph internal crash is retryable infrastructure" is_swiftpm_dependency_resolution_transient "$swiftpm_xcode_internal_package_graph_crash_log"
assert_true "Xcode build-service crash without XCTest failure is retryable infrastructure" is_xcode_build_service_transient "$xcode_build_service_crash_log"
assert_false "Xcode build-service crash does not hide a concrete XCTest failure" is_xcode_build_service_transient "$xcode_build_service_crash_with_test_failure_log"
assert_false "unknown failure is not a SwiftPM dependency transient" is_swiftpm_dependency_resolution_transient "$unknown_failure_log"

timeout_log="$tmpdir/supervised-timeout.log"
timeout_receipt="$tmpdir/supervised-timeout.json"
set +e
OPENBURNBAR_APP_TEST_TIMEOUT_RESTART_GRACE_SECONDS=0.1 \
OPENBURNBAR_APP_TEST_TIMEOUT_INTERRUPT_GRACE_SECONDS=0.2 \
    python3 "$timeout_supervisor" \
        --log "$timeout_log" \
        --receipt "$timeout_receipt" \
        -- \
        python3 "$fake_xcodebuild" timeout-restart \
        >"$tmpdir/supervised-timeout.out" 2>&1
timeout_status=$?
set -e
assert_equals "timeout containment preserves the exact supervised command status" "130" "$timeout_status"
assert_true "timeout containment writes a durable receipt" test -s "$timeout_receipt"
assert_true "timeout containment records the explicit restart reason" \
    grep -Fq '"reason": "execution_timeout_restart"' "$timeout_receipt"
assert_equals "one timed-out test does not cascade into the remaining 22 methods" \
    "1" \
    "$(grep -c "Test Case .* started" "$timeout_log")"
assert_true "contained timeout remains retryable infrastructure" is_known_hang "$timeout_log"
assert_true "validated containment receipt makes timeout retryable" \
    openburnbar_app_test_timeout_containment_is_retryable \
    "$timeout_log" \
    "$timeout_receipt"
assert_false "containment receipt never hides a concrete assertion" \
    openburnbar_app_test_timeout_containment_is_retryable \
    "$timeout_restart_with_assertion_log" \
    "$timeout_receipt"

retry_log="$tmpdir/supervised-retry.log"
retry_receipt="$tmpdir/supervised-retry.json"
python3 "$timeout_supervisor" \
    --log "$retry_log" \
    --receipt "$retry_receipt" \
    -- \
    python3 "$fake_xcodebuild" pass \
    >"$tmpdir/supervised-retry.out" 2>&1
assert_false "normal retry completion does not emit a containment receipt" test -e "$retry_receipt"
assert_true "normal retry output remains an unmodified green XCTest log" \
    grep -Fq "Executed 1 test, with 0 failures" "$retry_log"

timeout_without_restart_log="$tmpdir/supervised-timeout-without-restart.log"
timeout_without_restart_receipt="$tmpdir/supervised-timeout-without-restart.json"
set +e
OPENBURNBAR_APP_TEST_TIMEOUT_RESTART_GRACE_SECONDS=0.1 \
OPENBURNBAR_APP_TEST_TIMEOUT_INTERRUPT_GRACE_SECONDS=0.2 \
    python3 "$timeout_supervisor" \
        --log "$timeout_without_restart_log" \
        --receipt "$timeout_without_restart_receipt" \
        -- \
        python3 "$fake_xcodebuild" timeout-without-restart \
        >"$tmpdir/supervised-timeout-without-restart.out" 2>&1
timeout_without_restart_status=$?
set -e
assert_equals "missing Xcode restart marker still has bounded containment" \
    "130" \
    "$timeout_without_restart_status"
assert_true "restart-grace fallback is explicit in the receipt" \
    grep -Fq '"reason": "execution_timeout_restart_grace_expired"' \
    "$timeout_without_restart_receipt"
assert_equals "restart-grace fallback also prevents a second method launch" \
    "1" \
    "$(grep -c "Test Case .* started" "$timeout_without_restart_log")"

reordered_markers_log="$tmpdir/supervised-reordered-markers.log"
reordered_markers_receipt="$tmpdir/supervised-reordered-markers.json"
set +e
OPENBURNBAR_APP_TEST_TIMEOUT_RESTART_GRACE_SECONDS=0.1 \
OPENBURNBAR_APP_TEST_TIMEOUT_INTERRUPT_GRACE_SECONDS=0.2 \
    python3 "$timeout_supervisor" \
        --log "$reordered_markers_log" \
        --receipt "$reordered_markers_receipt" \
        -- \
        python3 "$fake_xcodebuild" restart-before-timeout \
        >"$tmpdir/supervised-reordered-markers.out" 2>&1
reordered_markers_status=$?
set -e
assert_equals "buffer-reordered timeout and restart markers are still contained" \
    "130" \
    "$reordered_markers_status"
assert_true "buffer-reordered markers retain the explicit restart reason" \
    grep -Fq '"reason": "execution_timeout_restart"' "$reordered_markers_receipt"
assert_equals "buffer-reordered markers do not launch a second method" \
    "1" \
    "$(grep -c "Test Case .* started" "$reordered_markers_log")"

timeout_ignore_int_log="$tmpdir/supervised-timeout-ignore-int.log"
timeout_ignore_int_receipt="$tmpdir/supervised-timeout-ignore-int.json"
set +e
OPENBURNBAR_APP_TEST_TIMEOUT_RESTART_GRACE_SECONDS=0.1 \
OPENBURNBAR_APP_TEST_TIMEOUT_INTERRUPT_GRACE_SECONDS=0.1 \
OPENBURNBAR_APP_TEST_TIMEOUT_TERMINATE_GRACE_SECONDS=0.1 \
    python3 "$timeout_supervisor" \
        --log "$timeout_ignore_int_log" \
        --receipt "$timeout_ignore_int_receipt" \
        -- \
        python3 "$fake_xcodebuild" timeout-ignore-int \
        >"$tmpdir/supervised-timeout-ignore-int.out" 2>&1
timeout_ignore_int_status=$?
set -e
assert_equals "SIGINT-resistant command is terminated with its exact SIGTERM status" \
    "143" \
    "$timeout_ignore_int_status"
assert_true "SIGTERM escalation is recorded for diagnostics" \
    grep -Fq '"escalatedSignal": "SIGTERM"' "$timeout_ignore_int_receipt"
assert_equals "SIGTERM escalation still prevents timeout cascade" \
    "1" \
    "$(grep -c "Test Case .* started" "$timeout_ignore_int_log")"

timeout_ignore_signals_log="$tmpdir/supervised-timeout-ignore-signals.log"
timeout_ignore_signals_receipt="$tmpdir/supervised-timeout-ignore-signals.json"
set +e
OPENBURNBAR_APP_TEST_TIMEOUT_RESTART_GRACE_SECONDS=0.1 \
OPENBURNBAR_APP_TEST_TIMEOUT_INTERRUPT_GRACE_SECONDS=0.1 \
OPENBURNBAR_APP_TEST_TIMEOUT_TERMINATE_GRACE_SECONDS=0.1 \
    python3 "$timeout_supervisor" \
        --log "$timeout_ignore_signals_log" \
        --receipt "$timeout_ignore_signals_receipt" \
        -- \
        python3 "$fake_xcodebuild" timeout-ignore-int-term \
        >"$tmpdir/supervised-timeout-ignore-signals.out" 2>&1
timeout_ignore_signals_status=$?
set -e
assert_equals "SIGINT-and-SIGTERM-resistant command is force-killed exactly" \
    "137" \
    "$timeout_ignore_signals_status"
assert_true "SIGKILL fallback is recorded for diagnostics" \
    grep -Fq '"forcedSignal": "SIGKILL"' "$timeout_ignore_signals_receipt"
assert_equals "SIGKILL fallback prevents timeout cascade" \
    "1" \
    "$(grep -c "Test Case .* started" "$timeout_ignore_signals_log")"

assertion_log="$tmpdir/supervised-assertion.log"
assertion_receipt="$tmpdir/supervised-assertion.json"
set +e
python3 "$timeout_supervisor" \
    --log "$assertion_log" \
    --receipt "$assertion_receipt" \
    -- \
    python3 "$fake_xcodebuild" assertion \
    >"$tmpdir/supervised-assertion.out" 2>&1
assertion_status=$?
set -e
assert_equals "real XCTest assertion preserves its exact failing exit status" "65" "$assertion_status"
assert_false "real XCTest assertion is never relabeled as timeout containment" test -e "$assertion_receipt"
assert_true "real XCTest assertion remains terminal" \
    openburnbar_app_test_has_terminal_concrete_xctest_failure "$assertion_log"
assert_false "real XCTest assertion remains non-retryable" is_known_hang "$assertion_log"

normal_log="$tmpdir/supervised-normal.log"
normal_receipt="$tmpdir/supervised-normal.json"
python3 "$timeout_supervisor" \
    --log "$normal_log" \
    --receipt "$normal_receipt" \
    --wall-timeout-seconds 5 \
    -- \
    python3 "$fake_xcodebuild" pass \
    >"$tmpdir/supervised-normal.out" 2>&1
assert_false "normal passing invocation is unaffected by containment" test -e "$normal_receipt"
assert_true "normal passing invocation retains its green summary" \
    grep -Fq "Executed 1 test, with 0 failures" "$normal_log"

wall_timeout_log="$tmpdir/supervised-wall-timeout.log"
wall_timeout_receipt="$tmpdir/supervised-wall-timeout.json"
set +e
OPENBURNBAR_APP_TEST_TIMEOUT_INTERRUPT_GRACE_SECONDS=0.2 \
    python3 "$timeout_supervisor" \
        --log "$wall_timeout_log" \
        --receipt "$wall_timeout_receipt" \
        --wall-timeout-seconds 0.1 \
        -- \
        python3 "$fake_xcodebuild" silent-hang \
        >"$tmpdir/supervised-wall-timeout.out" 2>&1
wall_timeout_status=$?
set -e
assert_equals "silent wall timeout preserves the exact supervised command status" \
    "130" \
    "$wall_timeout_status"
assert_true "silent wall timeout writes a durable receipt" \
    test -s "$wall_timeout_receipt"
python3 - "$wall_timeout_receipt" <<'PY'
import json
from pathlib import Path
import sys

receipt_path = Path(sys.argv[1])
with receipt_path.open(encoding="utf-8") as handle:
    receipt = json.load(handle)

expected = {
    "assertionFailurePresent": False,
    "initialSignal": "SIGINT",
    "reason": "wall_timeout",
    "restartMarkerObserved": False,
    "schemaVersion": 1,
    "timeoutMarkerObserved": False,
    "wallTimeoutSeconds": 0.1,
}
for key, expected_value in expected.items():
    actual_value = receipt.get(key)
    if actual_value != expected_value:
        raise SystemExit(
            f"unexpected durable wall-timeout receipt field {key}: "
            f"expected {expected_value!r}, found {actual_value!r}"
        )
if not isinstance(receipt.get("commandPid"), int) or receipt["commandPid"] <= 0:
    raise SystemExit("wall-timeout receipt lacks a positive command PID")
if not receipt.get("detectedAt"):
    raise SystemExit("wall-timeout receipt lacks a detection timestamp")
PY
assert_false "wall timeout is never classified as retryable XCTest containment" \
    openburnbar_app_test_timeout_containment_is_retryable \
    "$wall_timeout_log" \
    "$wall_timeout_receipt"
assert_false "silent wall timeout does not invent an XCTest hang marker" \
    is_known_hang "$wall_timeout_log"

for invalid_wall_timeout in 0 -1 nan inf; do
    invalid_wall_timeout_slug="${invalid_wall_timeout//-/_}"
    set +e
    python3 "$timeout_supervisor" \
        --log "$tmpdir/invalid-wall-timeout-$invalid_wall_timeout_slug.log" \
        --receipt "$tmpdir/invalid-wall-timeout-$invalid_wall_timeout_slug.json" \
        --wall-timeout-seconds "$invalid_wall_timeout" \
        -- \
        python3 "$fake_xcodebuild" pass \
        >"$tmpdir/invalid-wall-timeout-$invalid_wall_timeout_slug.out" 2>&1
    invalid_wall_timeout_status=$?
    set -e
    assert_equals "invalid wall timeout $invalid_wall_timeout fails closed before launch" \
        "64" \
        "$invalid_wall_timeout_status"
    assert_true "invalid wall timeout $invalid_wall_timeout reports its contract" \
        grep -Fq "must be a positive number" \
        "$tmpdir/invalid-wall-timeout-$invalid_wall_timeout_slug.out"
    assert_false "invalid wall timeout $invalid_wall_timeout never launches the command" \
        test -e "$tmpdir/invalid-wall-timeout-$invalid_wall_timeout_slug.log"
done

set +e
OPENBURNBAR_APP_TEST_TIMEOUT_RESTART_GRACE_SECONDS=nan \
    python3 "$timeout_supervisor" \
        --log "$tmpdir/invalid-grace.log" \
        --receipt "$tmpdir/invalid-grace.json" \
        -- \
        python3 "$fake_xcodebuild" pass \
        >"$tmpdir/invalid-grace.out" 2>&1
invalid_grace_status=$?
set -e
assert_equals "non-finite timeout grace fails closed before launch" \
    "64" \
    "$invalid_grace_status"
assert_true "invalid timeout grace reports its contract" \
    grep -Fq "must be a positive number" "$tmpdir/invalid-grace.out"
assert_false "invalid timeout grace never launches the supervised command" \
    test -e "$tmpdir/invalid-grace.log"

set +e
python3 "$timeout_supervisor" \
    --log "$tmpdir/shared-output-path" \
    --receipt "$tmpdir/shared-output-path" \
    -- \
    python3 "$fake_xcodebuild" pass \
    >"$tmpdir/shared-output-path.out" 2>&1
shared_output_status=$?
set -e
assert_equals "shared log and receipt path fails closed before launch" \
    "64" \
    "$shared_output_status"
assert_true "shared output-path rejection is explicit" \
    grep -Fq -- "--log and --receipt must name different paths" \
    "$tmpdir/shared-output-path.out"
assert_false "shared output-path rejection creates no ambiguous artifact" \
    test -e "$tmpdir/shared-output-path"

media_admission_isolated_filter="OpenBurnBarTests/MediaSessionCoordinatorTests/testActiveScreenShareStopsWhenAdmissionIsRevoked"
media_retry_isolated_filter="OpenBurnBarTests/MediaSessionCoordinatorTests/testStartScreenShareRollsBackAfterCaptureStartFailureAndCanRetry"
memory_activation_isolated_filter="OpenBurnBarTests/MemoryActivationEndToEndTests"
memory_citation_jump_isolated_filter="OpenBurnBarTests/MemoryCitationJumpThreadResolutionTests"
memory_cloud_sync_isolated_filter="OpenBurnBarTests/MemoryCloudSyncDomainTests"
memory_drop_telemetry_isolated_filter="OpenBurnBarTests/MemoryDropTelemetryTests"
projection_chunker_isolated_filter="OpenBurnBarTests/ProjectionChunkerTests"
projection_service_isolated_filter="OpenBurnBarTests/ProjectionPipelineServiceTests"
projection_matters_isolated_filter="OpenBurnBarTests/ProjectionPipelineServiceMattersTests"
projection_lifecycle_isolated_filter="OpenBurnBarTests/ProjectionStoreLifecycleTests"
default_plan="$(
    env -u OPENBURNBAR_APP_TEST_FILTER -u OPENBURNBAR_APP_TEST_FILTERS \
        "$repo_root/scripts/test-openburnbar-app.sh" --print-xcodebuild-plan
)"
assert_equals "default app test plan preserves all sensitive tests in a fresh host" \
    $'main-only\tOpenBurnBarTests\nmain-skip\t'"$media_admission_isolated_filter"$'\nmain-skip\t'"$media_retry_isolated_filter"$'\nmain-skip\t'"$memory_activation_isolated_filter"$'\nmain-skip\t'"$memory_citation_jump_isolated_filter"$'\nmain-skip\t'"$memory_cloud_sync_isolated_filter"$'\nmain-skip\t'"$memory_drop_telemetry_isolated_filter"$'\nmain-skip\t'"$projection_chunker_isolated_filter"$'\nmain-skip\t'"$projection_service_isolated_filter"$'\nmain-skip\t'"$projection_matters_isolated_filter"$'\nmain-skip\t'"$projection_lifecycle_isolated_filter"$'\nfresh-host-only\t'"$media_admission_isolated_filter"$'\nfresh-host-only\t'"$media_retry_isolated_filter"$'\nfresh-host-only\t'"$memory_activation_isolated_filter"$'\nfresh-host-only\t'"$memory_citation_jump_isolated_filter"$'\nfresh-host-only\t'"$memory_cloud_sync_isolated_filter"$'\nfresh-host-only\t'"$memory_drop_telemetry_isolated_filter"$'\nfresh-host-only\t'"$projection_chunker_isolated_filter"$'\nfresh-host-only\t'"$projection_service_isolated_filter"$'\nfresh-host-only\t'"$projection_matters_isolated_filter"$'\nfresh-host-only\t'"$projection_lifecycle_isolated_filter"$'\nfresh-host-expected-count\t133' \
    "$default_plan"

memory_activation_test_count="$(
    grep -Ec '^    func test[^ (]*\(' \
        "$repo_root/AgentLensTests/Active/MemoryActivationEndToEndTests.swift"
)"
assert_true "memory activation suite stays in the fresh-host plan" \
    grep -Fqx $'fresh-host-only\t'"$memory_activation_isolated_filter" <<<"$default_plan"

memory_citation_jump_test_count="$(
    grep -Ec '^    func test[^ (]*\(' \
        "$repo_root/AgentLensTests/Active/MemoryCitationJumpThreadResolutionTests.swift"
)"
assert_true "memory citation jump suite stays in the fresh-host plan" \
    grep -Fqx $'fresh-host-only\t'"$memory_citation_jump_isolated_filter" <<<"$default_plan"

memory_cloud_sync_test_count="$(
    grep -Ec '^    func test[^ (]*\(' \
        "$repo_root/AgentLensTests/Active/MemoryCloudSyncDomainTests.swift"
)"
assert_true "memory cloud-sync suite stays in the fresh-host plan" \
    grep -Fqx $'fresh-host-only\t'"$memory_cloud_sync_isolated_filter" <<<"$default_plan"

memory_drop_telemetry_test_count="$(
    grep -Ec '^    func test[^ (]*\(' \
        "$repo_root/AgentLensTests/Active/MemoryDropTelemetryTests.swift"
)"
assert_true "memory drop-telemetry suite stays in the fresh-host plan" \
    grep -Fqx $'fresh-host-only\t'"$memory_drop_telemetry_isolated_filter" <<<"$default_plan"

projection_test_count=0
for projection_test_file in "$repo_root"/AgentLensTests/Active/Projection*Tests.swift; do
    projection_test_class="$(
        sed -nE 's/.*final class (Projection[^ :]+Tests).*/\1/p' "$projection_test_file" | head -1
    )"
    if [[ -z "$projection_test_class" ]]; then
        echo "FAIL: no projection XCTest class found in $projection_test_file" >&2
        exit 1
    fi
    assert_true "projection test class $projection_test_class stays in the fresh-host plan" \
        grep -Fqx $'fresh-host-only\tOpenBurnBarTests/'"$projection_test_class" <<<"$default_plan"
    projection_test_count=$((
        projection_test_count + $(grep -Ec '^    func test[^ (]*\(' "$projection_test_file")
    ))
done
declared_fresh_host_count="$(awk -F '\t' '$1 == "fresh-host-expected-count" { print $2 }' <<<"$default_plan")"
assert_equals "fresh-host count covers memory, citation jump, projection, and isolated media tests" \
    "$((memory_activation_test_count + memory_citation_jump_test_count + memory_cloud_sync_test_count + memory_drop_telemetry_test_count + projection_test_count + 2))" \
    "$declared_fresh_host_count"

custom_plan="$(
    env -u OPENBURNBAR_APP_TEST_FILTER -u OPENBURNBAR_APP_TEST_FILTERS \
        "$repo_root/scripts/test-openburnbar-app.sh" \
        -only-testing:OpenBurnBarTests/MediaSessionCoordinatorTests \
        --print-xcodebuild-plan
)"
assert_equals "focused app tests remain a single-host plan" \
    $'main-only\tOpenBurnBarTests/MediaSessionCoordinatorTests' \
    "$custom_plan"

single_job_plan="$(
    OPENBURNBAR_APP_TEST_XCODEBUILD_JOBS=1 \
        "$repo_root/scripts/test-openburnbar-app.sh" \
        -only-testing:OpenBurnBarTests/SafariLearningTimelineViewModelTests \
        --print-xcodebuild-plan
)"
assert_equals "explicit Xcode job limit is represented in the dry-run plan" \
    $'main-only\tOpenBurnBarTests/SafariLearningTimelineViewModelTests\nxcodebuild-jobs\t1' \
    "$single_job_plan"

snapshot_plan="$(
    OPENBURNBAR_SNAPSHOT_RECORD=all \
        "$repo_root/scripts/test-openburnbar-app.sh" \
        -only-testing:OpenBurnBarTests/AdaptiveColorSnapshotTests \
        --print-xcodebuild-plan
)"
assert_equals "validated snapshot record mode is represented in the dry-run plan" \
    $'main-only\tOpenBurnBarTests/AdaptiveColorSnapshotTests\nsnapshot-record-mode\tall' \
    "$snapshot_plan"

if OPENBURNBAR_SNAPSHOT_RECORD=invalid \
    "$repo_root/scripts/test-openburnbar-app.sh" \
    --print-xcodebuild-plan >"$tmpdir/invalid-snapshot-mode.out" 2>"$tmpdir/invalid-snapshot-mode.err"; then
    echo "FAIL: invalid snapshot record mode unexpectedly passed validation" >&2
    exit 1
fi
assert_true "invalid snapshot record mode reports the fail-closed contract" \
    grep -Fqx \
    "error: OPENBURNBAR_SNAPSHOT_RECORD must be one of: all, failed, missing, never" \
    "$tmpdir/invalid-snapshot-mode.err"

if OPENBURNBAR_APP_TEST_XCODEBUILD_JOBS=0 \
    "$repo_root/scripts/test-openburnbar-app.sh" \
    --print-xcodebuild-plan >"$tmpdir/invalid-jobs.out" 2>"$tmpdir/invalid-jobs.err"; then
    echo "FAIL: zero Xcode job limit unexpectedly passed validation" >&2
    exit 1
fi
assert_true "invalid Xcode job limit reports the fail-closed contract" \
    grep -Fqx "error: OPENBURNBAR_APP_TEST_XCODEBUILD_JOBS must be a positive integer" \
    "$tmpdir/invalid-jobs.err"

echo "OpenBurnBar app-test classifier fixtures passed."
