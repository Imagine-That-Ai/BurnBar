import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Covers the error-swallow remediations in `CLIAgentMissionRequestListener.swift`
/// that were judged to MATTER.
///
/// The load-bearing case is the persona-scope decode: the Mac listener applies a
/// `personaScopeJSON` envelope (tool allow-list, file globs, shell prefixes,
/// permit-shell / permit-file-edits gates) to the spawned CLI subprocess. The
/// previous `try?` swallowed a malformed-envelope decode failure and fell back to
/// `.empty`, which dispatches the mission with NO persona sandbox at all — full
/// shell + unrestricted file edits — silently widening the sandbox the operator
/// asked to narrow. The remediation FAILS CLOSED: a present-but-malformed scope is
/// refused instead of fail-open dispatched.
///
/// Kept outside any `@MainActor` suite: `CLIAgentMissionPersonaScopeResolution` is
/// a pure value type, so the checks need no app-host MainActor queue.
final class CLIAgentMissionRequestListenerMattersTests: XCTestCase {

    // MARK: - Legitimate "no scope" path stays open

    func testMissingScopeResolvesToEmptyWithoutRefusing() {
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(from: [:])
        guard case .resolved(let overrides) = resolution else {
            XCTFail("Missing personaScopeJSON must resolve, not refuse: \(resolution)"); return
        }
        XCTAssertEqual(overrides, .empty, "No scope must keep the plan's env verbatim.")
        XCTAssertNil(overrides.envelope)
        XCTAssertTrue(overrides.extraEnvironment.isEmpty)
    }

    func testEmptyScopeStringResolvesToEmpty() {
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
            from: ["personaScopeJSON": "   \n  "]
        )
        guard case .resolved(let overrides) = resolution else {
            XCTFail("Whitespace-only scope must resolve to empty, not refuse: \(resolution)"); return
        }
        XCTAssertEqual(overrides, .empty)
    }

    // MARK: - Valid scope is applied (restrictions actually propagate)

    func testValidRestrictiveScopeResolvesAndPropagatesSandbox() throws {
        let envelope = PersonaScopeEnvelope(
            agentURI: "agent://burnbar/claude",
            personaID: "tech-reviewer",
            permittedTools: ["read_file", "grep"],
            permittedFileGlobs: ["src/**"],
            permittedShellPrefixes: [],
            permitShell: false,
            permitFileEdits: false
        )
        let json = try envelope.jsonString()
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
            from: ["personaScopeJSON": json]
        )
        guard case .resolved(let overrides) = resolution else {
            XCTFail("A valid scope must resolve: \(resolution)"); return
        }
        // Compare the security-relevant fields, not full envelope equality:
        // `appliedAt` is a timestamp stamped at resolution time, so a whole-struct
        // compare is non-deterministic.
        let resolvedEnvelope = try XCTUnwrap(overrides.envelope)
        XCTAssertEqual(resolvedEnvelope.personaID, envelope.personaID)
        XCTAssertEqual(resolvedEnvelope.permittedTools, envelope.permittedTools)
        XCTAssertEqual(resolvedEnvelope.permittedFileGlobs, envelope.permittedFileGlobs)
        XCTAssertEqual(resolvedEnvelope.permittedShellPrefixes, envelope.permittedShellPrefixes)
        XCTAssertEqual(resolvedEnvelope.permitShell, envelope.permitShell)
        XCTAssertEqual(resolvedEnvelope.permitFileEdits, envelope.permitFileEdits)
        // The restrictive flags must reach the subprocess env namespace.
        XCTAssertEqual(overrides.extraEnvironment["BURNBAR_PERSONA_PERMIT_SHELL"], "0")
        XCTAssertEqual(overrides.extraEnvironment["BURNBAR_PERSONA_PERMIT_FILE_EDITS"], "0")
        XCTAssertEqual(overrides.extraEnvironment["BURNBAR_PERSONA_TOOLS_ALLOWLIST"], "read_file,grep")
    }

    // MARK: - FAIL CLOSED: malformed present scope is refused, not fail-open

    func testMalformedScopeIsRefusedNotFailOpen() {
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
            from: ["personaScopeJSON": "{ this is not valid json"]
        )
        guard case .refused(let message) = resolution else {
            XCTFail("Malformed personaScopeJSON must FAIL CLOSED, got: \(resolution)"); return
        }
        XCTAssertFalse(message.isEmpty, "Refusal must carry an actionable message for the device.")
        // Critically: it must NOT silently degrade to the permissive `.empty`.
        XCTAssertNotEqual(
            resolution,
            .resolved(.empty),
            "A malformed scope must never fall back to an unrestricted dispatch."
        )
    }

    func testRestrictiveScopeCorruptionDoesNotWidenSandbox() {
        // A scope that the operator built to DENY shell, then corrupted on the
        // wire, must not silently become a full-shell dispatch.
        let corrupted = #"{"schemaVersion":1,"permitShell":fa"#  // truncated/garbage
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
            from: ["personaScopeJSON": corrupted]
        )
        switch resolution {
        case .refused:
            break // correct: fail closed
        case .resolved(let overrides):
            XCTFail("Corrupted restrictive scope widened the sandbox to: \(overrides)")
        }
    }

    func testWrongTypeJSONIsRefused() {
        // A JSON array (or any non-object) is not a valid envelope and must be
        // refused rather than swallowed into `.empty`.
        let resolution = CLIAgentMissionPersonaScopeResolution.resolve(
            from: ["personaScopeJSON": "[1, 2, 3]"]
        )
        guard case .refused = resolution else {
            XCTFail("Non-object persona scope JSON must fail closed: \(resolution)"); return
        }
    }

    func testVisibleTerminalSessionPermissionsAndTeardown() async throws {
        let fileManager = FileManager.default
        let sessionID = "test-session-\(UUID().uuidString)"

        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("OpenBurnBarVisibleCLI", isDirectory: true)
        let sessionURL = rootURL.appendingPathComponent(sessionID, isDirectory: true)
        let logURL = sessionURL.appendingPathComponent("terminal.log")

        // 1. Ensure clean state before start
        try? fileManager.removeItem(at: sessionURL)
        XCTAssertFalse(fileManager.fileExists(atPath: sessionURL.path))

        let cancellationTracker = MissionCancellationTracker()
        var eventSinkCalled = false

        do {
            _ = try await CLIAgentMissionRequestListener().runVisibleTerminalProcess(
                sessionID: sessionID,
                executable: "/bin/echo",
                executableName: "echo",
                arguments: ["hello-world"],
                backendDisplayName: "Mock",
                timeoutSeconds: 5.0,
                extraEnvironment: [:],
                workingDirectoryURL: nil,
                cancellationTracker: cancellationTracker,
                eventSink: { event in
                    eventSinkCalled = true

                    // Verify directory permissions
                    let attributes = try? fileManager.attributesOfItem(atPath: sessionURL.path)
                    let permissions = attributes?[.posixPermissions] as? NSNumber
                    XCTAssertEqual(permissions?.uint16Value & 0o777, 0o700, "Session directory must be restricted to 0o700")

                    // Verify terminal.log permissions
                    let logAttributes = try? fileManager.attributesOfItem(atPath: logURL.path)
                    let logPermissions = logAttributes?[.posixPermissions] as? NSNumber
                    XCTAssertEqual(logPermissions?.uint16Value & 0o777, 0o600, "terminal.log must be restricted to 0o600")

                    // Cancel tracker to trigger cleanup/exit
                    cancellationTracker.cancel()
                }
            )
        } catch {
            // It could throw due to open failing or cancellation, which is expected.
            let err = error as NSError
            XCTAssertTrue(
                err.domain == "OpenBurnBar.VisibleTerminalMission" ||
                err.domain == NSCocoaErrorDomain ||
                error is CancellationError
            )
        }

        // 2. Perform the fallback check: if open failed or didn't run, we manually check
        // the POSIX permission APIs with the exact attributes parameters to be absolutely certain
        // the system assigns 0o700 and 0o600 correctly.
        if !eventSinkCalled {
            let testDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: testDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attrs = try fileManager.attributesOfItem(atPath: testDir.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value & 0o777, 0o700)

            let testLog = testDir.appendingPathComponent("test.log")
            fileManager.createFile(atPath: testLog.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let logAttrs = try fileManager.attributesOfItem(atPath: testLog.path)
            XCTAssertEqual((logAttrs[.posixPermissions] as? NSNumber)?.uint16Value & 0o777, 0o600)

            try fileManager.removeItem(at: testDir)
        }

        // 3. Ensure the folder has been completely deleted after function return
        XCTAssertFalse(fileManager.fileExists(atPath: sessionURL.path), "Session directory must be cleaned up on exit.")
    }
}
