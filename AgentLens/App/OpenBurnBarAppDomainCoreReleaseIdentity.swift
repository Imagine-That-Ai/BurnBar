import Foundation
import OpenBurnBarCore

/// Pure decision helper extracted from `OpenBurnBarApp.runDomainCoreReleaseIdentityModeIfRequested()`.
///
/// The app's `init()` fast-paths into the domain-core release-identity CLI hook when invoked with
/// `--domain-core-release-identity-report <reportPath>`. The original entrypoint mixes argument/env
/// validation, the reporter `write` call, `stderr` writes, and `exit(EXIT_*)` — none of which can be
/// exercised from an in-process XCTest without terminating the host.
///
/// This helper owns the deterministic, side-effect-free policy: it inspects the invocation inputs,
/// runs the reporter write (injectable so tests can drive the success/throw branches), and returns
/// an outcome describing what the caller should do. The caller (`runDomainCoreReleaseIdentityModeIfRequested`)
/// performs the irreversible side effects (`stderr` writes + `exit`) from that outcome, preserving the
/// exact runtime behavior and process-exit semantics of the production path.
extension OpenBurnBarApp {

    /// The resolved outcome of a domain-core release-identity CLI invocation. Carries only the
    /// data the caller needs to emit the correct `stderr` line and exit code; never performs I/O.
    enum DomainCoreReleaseIdentityOutcome: Equatable {
        /// The release-identity argument was absent; the app should continue its normal startup.
        case notRequested
        /// The invocation shape was wrong (wrong arg count, missing `DOMAIN_CORE_CANDIDATE_COMMIT`,
        /// or missing the main executable URL). Maps to `"invalid … invocation"` on `stderr` + `EXIT_FAILURE`.
        case invalidInvocation
        /// The identity report was written successfully. Maps to `EXIT_SUCCESS`.
        case success
        /// `DomainCoreReleaseIdentityReporter.write` threw. Carries the error's localized description
        /// so the caller can reproduce the exact `"… failed: <description>"` `stderr` line. The error
        /// type itself is deliberately not surfaced — only the human-readable description is emitted.
        case failure(errorDescription: String)
    }

    /// Resolves a domain-core release-identity request against the given invocation inputs.
    ///
    /// - Parameters:
    ///   - arguments: Process arguments. The hook fires when `arguments.contains(DomainCoreReleaseIdentityReporter.argument)`.
    ///   - environment: Process environment; must carry `DOMAIN_CORE_CANDIDATE_COMMIT` for a valid invocation.
    ///   - executableURL: The host executable URL (`Bundle.main.executableURL` in production).
    ///   - write: The reporter write function. Defaults to wrapping
    ///     `DomainCoreReleaseIdentityReporter.write` so production wiring is unchanged; tests inject a
    ///     closure to drive the success/throw branches without requiring the native core FFI or a real
    ///     executable on disk. The returned `DomainCoreReleaseIdentity` is discarded — only the
    ///     success/throw outcome matters.
    /// - Returns: The outcome the caller should act on. This function never calls `exit` or writes to
    ///   `stderr`; it only inspects inputs and invokes `write`.
    static func domainCoreReleaseIdentityRequest(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
        write: (String, URL, URL) throws -> Void = { candidate, report, exec in _ = try DomainCoreReleaseIdentityReporter.write(candidateCommit: candidate, reportURL: report, executableURL: exec) }
    ) -> DomainCoreReleaseIdentityOutcome {
        guard arguments.contains(DomainCoreReleaseIdentityReporter.argument) else {
            return .notRequested
        }
        guard arguments.count == 3,
              arguments[1] == DomainCoreReleaseIdentityReporter.argument,
              let candidateCommit = environment["DOMAIN_CORE_CANDIDATE_COMMIT"],
              let executableURL else {
            return .invalidInvocation
        }
        do {
            try write(
                candidateCommit,
                URL(fileURLWithPath: arguments[2]),
                executableURL
            )
            return .success
        } catch {
            return .failure(errorDescription: error.localizedDescription)
        }
    }
}
