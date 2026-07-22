import Foundation
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Behavior coverage for the domain-core release-identity CLI hook extracted from
/// `OpenBurnBarApp.runDomainCoreReleaseIdentityModeIfRequested()`.
///
/// The app entrypoint mixes argument/env validation, the `DomainCoreReleaseIdentityReporter`
/// write, `stderr` writes, and `exit(EXIT_*)`. Those irreversible process side effects cannot
/// be exercised from an in-process XCTest host without terminating the runner, so the
/// deterministic policy lives in `OpenBurnBarApp.domainCoreReleaseIdentityRequest(...)` and
/// returns an outcome describing what the caller should do. These tests pin that policy:
/// the not-requested fast path, the invalid-invocation guard (each failing input shape), and
/// the success/throw dispatch through the injected write closure. The injected write avoids
/// the native FFI and a real executable, so the tests run hermetically and deterministically.
final class OpenBurnBarAppDomainCoreReleaseIdentityTests: XCTestCase {

    private let argument = DomainCoreReleaseIdentityReporter.argument

    // MARK: - Not requested

    func test_request_returnsNotRequestedWhenArgumentAbsent() {
        XCTAssertEqual(
            OpenBurnBarApp.domainCoreReleaseIdentityRequest(
                arguments: [],
                environment: [:],
                executableURL: URL(fileURLWithPath: "/tmp/obb"),
                write: { _, _, _ in }
            ),
            .notRequested
        )
    }

    func test_request_returnsNotRequestedForUnrelatedArguments() {
        // A normal app launch carries many args; none equal the hook argument, so the
        // app must continue its regular startup rather than entering the identity mode.
        XCTAssertEqual(
            OpenBurnBarApp.domainCoreReleaseIdentityRequest(
                arguments: ["/Applications/OpenBurnBar.app/Contents/MacOS/OpenBurnBar"],
                environment: ["DOMAIN_CORE_CANDIDATE_COMMIT": "a"],
                executableURL: URL(fileURLWithPath: "/tmp/obb"),
                write: { _, _, _ in XCTFail("write must not run when hook arg absent") }
            ),
            .notRequested
        )
    }

    // MARK: - Invalid invocation guard

    func test_invalidInvocation_rejectsWrongArgumentCount() {
        // Only two args (program + hook flag) — the report path is missing.
        XCTAssertEqual(
            OpenBurnBarApp.domainCoreReleaseIdentityRequest(
                arguments: ["/tmp/obb", argument],
                environment: ["DOMAIN_CORE_CANDIDATE_COMMIT": String(repeating: "a", count: 40)],
                executableURL: URL(fileURLWithPath: "/tmp/obb"),
                write: { _, _, _ in XCTFail("write must not run on invalid invocation") }
            ),
            .invalidInvocation
        )
    }

    func test_invalidInvocation_rejectsHookArgNotInPositionOne() {
        // The hook arg must be argv[1] exactly; here it is argv[2] so a stray
        // leading positional must not be silently accepted.
        XCTAssertEqual(
            OpenBurnBarApp.domainCoreReleaseIdentityRequest(
                arguments: ["/tmp/obb", "/tmp/report.json", argument],
                environment: ["DOMAIN_CORE_CANDIDATE_COMMIT": String(repeating: "a", count: 40)],
                executableURL: URL(fileURLWithPath: "/tmp/obb"),
                write: { _, _, _ in XCTFail("write must not run on invalid invocation") }
            ),
            .invalidInvocation
        )
    }

    func test_invalidInvocation_rejectsMissingCandidateCommitEnv() {
        XCTAssertEqual(
            OpenBurnBarApp.domainCoreReleaseIdentityRequest(
                arguments: ["/tmp/obb", argument, "/tmp/report.json"],
                environment: [:],
                executableURL: URL(fileURLWithPath: "/tmp/obb"),
                write: { _, _, _ in XCTFail("write must not run on invalid invocation") }
            ),
            .invalidInvocation
        )
    }

    func test_invalidInvocation_rejectsNilExecutableURL() {
        XCTAssertEqual(
            OpenBurnBarApp.domainCoreReleaseIdentityRequest(
                arguments: ["/tmp/obb", argument, "/tmp/report.json"],
                environment: ["DOMAIN_CORE_CANDIDATE_COMMIT": String(repeating: "a", count: 40)],
                executableURL: nil,
                write: { _, _, _ in XCTFail("write must not run on invalid invocation") }
            ),
            .invalidInvocation
        )
    }

    // MARK: - Success / failure dispatch

    func test_success_returnsSuccessAndForwardsParsedInvocationToWrite() {
        // Happy path: write throws nothing. Assert the reporter is called with the
        // exact candidate commit, report path, and executable URL parsed from argv/env.
        let candidate = String(repeating: "a", count: 40)
        let executable = URL(fileURLWithPath: "/tmp/obb-executable")
        var capturedCandidate: String?
        var capturedReport: URL?
        var capturedExecutable: URL?

        let outcome = OpenBurnBarApp.domainCoreReleaseIdentityRequest(
            arguments: ["/tmp/obb", argument, "/tmp/report.json"],
            environment: ["DOMAIN_CORE_CANDIDATE_COMMIT": candidate],
            executableURL: executable,
            write: { commit, report, exec in
                capturedCandidate = commit
                capturedReport = report
                capturedExecutable = exec
            }
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(capturedCandidate, candidate)
        XCTAssertEqual(capturedReport, URL(fileURLWithPath: "/tmp/report.json"))
        XCTAssertEqual(capturedExecutable, executable)
    }

    func test_failure_surfacesErrorDescriptionWhenWriteThrows() {
        // The reporter throws a LocalizedError; the helper must surface its
        // localizedDescription so the app's stderr line stays human-readable.
        struct ReporterError: LocalizedError {
            let errorDescription: String? = "candidate commit mismatch"
        }

        let outcome = OpenBurnBarApp.domainCoreReleaseIdentityRequest(
            arguments: ["/tmp/obb", argument, "/tmp/report.json"],
            environment: ["DOMAIN_CORE_CANDIDATE_COMMIT": String(repeating: "a", count: 40)],
            executableURL: URL(fileURLWithPath: "/tmp/obb"),
            write: { _, _, _ in throw ReporterError() }
        )

        XCTAssertEqual(
            outcome,
            .failure(errorDescription: "candidate commit mismatch")
        )
    }

    func test_failure_distinctForDifferentErrors() {
        // Pins that the description is carried verbatim, not a constant; a different
        // thrown error must produce a distinct outcome so the stderr line reflects it.
        struct OtherError: LocalizedError {
            let errorDescription: String? = "unsafe executable"
        }

        let outcome = OpenBurnBarApp.domainCoreReleaseIdentityRequest(
            arguments: ["/tmp/obb", argument, "/tmp/report.json"],
            environment: ["DOMAIN_CORE_CANDIDATE_COMMIT": String(repeating: "a", count: 40)],
            executableURL: URL(fileURLWithPath: "/tmp/obb"),
            write: { _, _, _ in throw OtherError() }
        )

        XCTAssertEqual(outcome, .failure(errorDescription: "unsafe executable"))
    }
}
