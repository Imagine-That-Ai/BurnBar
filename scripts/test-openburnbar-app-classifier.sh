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
assert_false "unknown failure is not a SwiftPM dependency transient" is_swiftpm_dependency_resolution_transient "$unknown_failure_log"

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
    $'main-only\tOpenBurnBarTests\nmain-skip\t'"$media_admission_isolated_filter"$'\nmain-skip\t'"$media_retry_isolated_filter"$'\nmain-skip\t'"$memory_activation_isolated_filter"$'\nmain-skip\t'"$memory_citation_jump_isolated_filter"$'\nmain-skip\t'"$memory_cloud_sync_isolated_filter"$'\nmain-skip\t'"$memory_drop_telemetry_isolated_filter"$'\nmain-skip\t'"$projection_chunker_isolated_filter"$'\nmain-skip\t'"$projection_service_isolated_filter"$'\nmain-skip\t'"$projection_matters_isolated_filter"$'\nmain-skip\t'"$projection_lifecycle_isolated_filter"$'\nfresh-host-only\t'"$media_admission_isolated_filter"$'\nfresh-host-only\t'"$media_retry_isolated_filter"$'\nfresh-host-only\t'"$memory_activation_isolated_filter"$'\nfresh-host-only\t'"$memory_citation_jump_isolated_filter"$'\nfresh-host-only\t'"$memory_cloud_sync_isolated_filter"$'\nfresh-host-only\t'"$memory_drop_telemetry_isolated_filter"$'\nfresh-host-only\t'"$projection_chunker_isolated_filter"$'\nfresh-host-only\t'"$projection_service_isolated_filter"$'\nfresh-host-only\t'"$projection_matters_isolated_filter"$'\nfresh-host-only\t'"$projection_lifecycle_isolated_filter"$'\nfresh-host-expected-count\t138' \
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

echo "OpenBurnBar app-test classifier fixtures passed."
