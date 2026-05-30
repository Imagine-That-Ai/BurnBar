import XCTest

/// Documents post-P0 expectation: an unsigned console-user red-team probe must be rejected.
///
/// Pre-P0 the same probe would receive `ok: true` for arbitrary `"input"` / `type` — that regression
/// is locked by policy unit tests plus this integration gate when the bridge socket is live.
///
/// Opt-in: set `RUN_PRIVILEGED_SOCKET_REDTEAM=1` and restart privileged daemons from a P0+ build.
final class PrivilegedSocketRedTeamIntegrationTests: XCTestCase {
    private static let virtualHIDSocket = "/var/run/openburnbar-virtual-hid.sock"

    func test_redTeamProbe_rejectsVirtualHIDInput_whenSocketLive() throws {
        try runRedTeamProbeIfSocketLive(socket: Self.virtualHIDSocket)
    }

    private func runRedTeamProbeIfSocketLive(socket: String, operation: String = "input") throws {
        guard ProcessInfo.processInfo.environment["RUN_PRIVILEGED_SOCKET_REDTEAM"] == "1" else {
            throw XCTSkip("Set RUN_PRIVILEGED_SOCKET_REDTEAM=1 after rebuilding privileged daemons")
        }
        guard FileManager.default.fileExists(atPath: socket) else {
            throw XCTSkip("Privileged socket not present at \(socket)")
        }

        let probeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/OpenBurnBarPrivilegedSocketRedTeamProbe")

        guard FileManager.default.fileExists(atPath: probeURL.path) else {
            throw XCTSkip("Build OpenBurnBarPrivilegedSocketRedTeamProbe first (swift build in OpenBurnBarDaemon)")
        }

        let process = Process()
        process.executableURL = probeURL
        process.arguments = [socket, operation]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        // Exit 1 = server rejected (post-P0 expected). Exit 0 = accepted (pre-P0 vulnerability).
        XCTAssertEqual(
            process.terminationStatus,
            1,
            "Red-team probe must be rejected after P0 peer auth + input policy (got exit \(process.terminationStatus))"
        )
    }
}
