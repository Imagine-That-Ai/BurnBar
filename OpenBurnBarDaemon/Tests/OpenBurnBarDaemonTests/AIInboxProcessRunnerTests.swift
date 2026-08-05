import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Behavior of the real subprocess spawner, exercised against tiny real
/// commands: exit codes, stdout/stderr capture, working directory, environment
/// overrides, executable resolution, launch failure, and the timeout watchdog.
///
/// Every command used here (`echo`, `true`, `false`, `pwd`, `sleep`, `env`) is
/// resolved through the runner's own `locate`, so the tests stay honest about
/// the LaunchAgent's minimal-PATH reality instead of assuming a shell.
final class AIInboxProcessRunnerTests: XCTestCase {
    private let runner = BurnBarAIInboxProcessRunner()

    // MARK: - Error surface

    func test_errorDescriptionsNameTheFailure() {
        XCTAssertEqual(
            BurnBarAIInboxProcessError.executableNotFound("gh").errorDescription,
            "Executable not found on PATH: gh"
        )
        XCTAssertEqual(
            BurnBarAIInboxProcessError.timedOut("git").errorDescription,
            "git timed out"
        )
        XCTAssertEqual(
            BurnBarAIInboxProcessError.launchFailed("gh", "denied").errorDescription,
            "Failed to launch gh: denied"
        )
    }

    // MARK: - Happy path

    /// Uses the protocol extension's defaulted arguments, which is how the
    /// availability probes call the runner.
    func test_defaultArgumentRunCapturesStandardOutput() async throws {
        let result = try await runner.run(executable: "echo", arguments: ["hello", "inbox"])

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "hello inbox")
        XCTAssertEqual(result.standardError, "")
    }

    func test_exitCodesAreReportedFaithfully() async throws {
        let succeeded = try await runner.run(
            executable: "true",
            arguments: [],
            workingDirectory: nil,
            timeout: 10,
            environmentOverrides: [:]
        )
        XCTAssertEqual(succeeded.exitCode, 0)
        XCTAssertTrue(succeeded.succeeded)

        let failed = try await runner.run(
            executable: "false",
            arguments: [],
            workingDirectory: nil,
            timeout: 10,
            environmentOverrides: [:]
        )
        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertFalse(failed.succeeded)
    }

    func test_workingDirectoryIsApplied() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await runner.run(
            executable: "pwd",
            arguments: [],
            workingDirectory: directory.path,
            timeout: 10,
            environmentOverrides: [:]
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(
            result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix(directory.lastPathComponent),
            "The child must run inside the requested directory: \(result.standardOutput)"
        )
    }

    func test_standardErrorIsCapturedSeparatelyFromStandardOutput() async throws {
        // `env <missing-command>` reports its failure on stderr and exits
        // non-zero, without needing a shell.
        let missing = "burnbar-inbox-no-such-command"
        let result = try await runner.run(
            executable: "env",
            arguments: [missing],
            workingDirectory: nil,
            timeout: 10,
            environmentOverrides: [:]
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.standardError.contains(missing), "stderr: \(result.standardError)")
        XCTAssertTrue(result.standardOutput.isEmpty)
    }

    func test_environmentOverridesReachTheChild() async throws {
        let result = try await runner.run(
            executable: "env",
            arguments: [],
            workingDirectory: nil,
            timeout: 10,
            environmentOverrides: ["BURNBAR_INBOX_COVERAGE_MARKER": "on"]
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.standardOutput.contains("BURNBAR_INBOX_COVERAGE_MARKER=on"))
    }

    // MARK: - Executable resolution

    func test_locateResolvesRealBinariesAndReportsMissingOnes() {
        let echo = BurnBarAIInboxProcessRunner.locate("echo")
        XCTAssertNotNil(echo)
        XCTAssertEqual(echo?.hasPrefix("/"), true, "Resolution must yield an absolute path")

        // A name found nowhere walks the search paths AND the PATH fallback
        // before reporting nil.
        XCTAssertNil(BurnBarAIInboxProcessRunner.locate("burnbar-inbox-missing-\(UUID().uuidString)"))
        XCTAssertNil(
            BurnBarAIInboxProcessRunner.locate("/nonexistent/burnbar-inbox-tool"),
            "An absolute path is honored only when it is actually executable"
        )
    }

    func test_missingExecutableThrowsBeforeSpawning() async {
        let missing = "burnbar-inbox-missing-\(UUID().uuidString)"
        do {
            _ = try await runner.run(
                executable: missing,
                arguments: [],
                workingDirectory: nil,
                timeout: 5,
                environmentOverrides: [:]
            )
            XCTFail("A missing executable must throw")
        } catch let error as BurnBarAIInboxProcessError {
            guard case .executableNotFound(let name) = error else {
                return XCTFail("Expected executableNotFound, got \(error)")
            }
            XCTAssertEqual(name, missing)
        } catch {
            XCTFail("Expected a process error, got \(error)")
        }
    }

    /// A directory passes the executable-bit check (search permission) but
    /// cannot be spawned, which is exactly the launch-failure path.
    func test_unspawnableExecutableSurfacesAsLaunchFailed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-inbox-not-a-binary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await runner.run(
                executable: directory.path,
                arguments: [],
                workingDirectory: nil,
                timeout: 5,
                environmentOverrides: [:]
            )
            XCTFail("Spawning a directory must throw")
        } catch let error as BurnBarAIInboxProcessError {
            switch error {
            case .launchFailed(let name, _):
                XCTAssertEqual(name, directory.path)
            case .executableNotFound:
                // Acceptable on a platform whose access(2) refuses directories;
                // the run must still fail closed.
                break
            case .timedOut:
                XCTFail("A launch failure must not be reported as a timeout")
            }
        } catch {
            XCTFail("Expected a process error, got \(error)")
        }
    }

    // MARK: - Timeout watchdog

    func test_slowCommandIsTerminatedAtTheTimeout() async {
        let started = Date()
        do {
            _ = try await runner.run(
                executable: "sleep",
                arguments: ["30"],
                workingDirectory: nil,
                timeout: 1,
                environmentOverrides: [:]
            )
            XCTFail("A command outliving its timeout must throw")
        } catch let error as BurnBarAIInboxProcessError {
            guard case .timedOut(let name) = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
            XCTAssertEqual(name, "sleep")
        } catch {
            XCTFail("Expected a process error, got \(error)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            15,
            "The watchdog must kill the child long before it would exit naturally"
        )
    }
}
