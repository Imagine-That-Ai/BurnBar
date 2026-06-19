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

unknown_failure_log="$(write_fixture unknown-failure <<'LOG'
** TEST FAILED **
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
assert_true "final green bundle and Selected tests summaries override a stale failing-tests footer" is_xcode_false_negative_pass "$final_green_bundle_with_stale_footer_log"
assert_true "runner-restart stale failing footer is accepted when final Selected tests run is green" is_xcode_false_negative_pass "$restarted_final_green_with_stale_footer_log"
assert_false "runner-restart stale failing footer is not terminal concrete failure when final run is green" openburnbar_app_test_has_terminal_concrete_xctest_failure "$restarted_final_green_with_stale_footer_log"
assert_false "runner-restart final-run assertion failure is not hidden" is_xcode_false_negative_pass "$restarted_final_run_failure_log"
assert_true "runner-restart final-run assertion failure remains terminal concrete failure" openburnbar_app_test_has_terminal_concrete_xctest_failure "$restarted_final_run_failure_log"
assert_true "runner crash without concrete XCTest failure is retryable" is_known_hang "$hang_log"
assert_false "runner crash with concrete XCTest failure is not hidden as infrastructure" is_known_hang "$hang_with_failure_log"
assert_false "test-host timeout relaunch is not accepted as false-negative pass" is_xcode_false_negative_pass "$timeout_restart_log"
assert_false "test-host timeout relaunch with stale failing footer is not terminal concrete failure" openburnbar_app_test_has_terminal_concrete_xctest_failure "$timeout_restart_log"
assert_true "test-host timeout relaunch with stale failing footer is retryable" is_known_hang "$timeout_restart_log"
assert_false "test-host timeout relaunch with assertion failure is not hidden" is_known_hang "$timeout_restart_with_assertion_log"
assert_false "unknown failure is not retryable" is_known_hang "$unknown_failure_log"
assert_true "SwiftPM binary artifact download timeout is retryable infrastructure" is_swiftpm_dependency_resolution_transient "$swiftpm_dependency_timeout_log"
assert_true "SwiftPM package clone network timeout is retryable infrastructure" is_swiftpm_dependency_resolution_transient "$swiftpm_clone_timeout_log"
assert_false "SwiftPM timeout does not hide concrete XCTest failure" is_swiftpm_dependency_resolution_transient "$swiftpm_timeout_with_xctest_failure_log"
assert_true "SwiftPM cache race plus Signal FFI mapping miss is retryable infrastructure" is_swiftpm_dependency_resolution_transient "$swiftpm_cache_and_signal_ffi_mapping_log"
assert_false "unknown failure is not a SwiftPM dependency transient" is_swiftpm_dependency_resolution_transient "$unknown_failure_log"

echo "OpenBurnBar app-test classifier fixtures passed."
