import XCTest

/// Documents post-P0 expectation: an unsigned console-user red-team probe must be rejected.
///
/// Pre-P0 the same probe would receive `ok: true` for arbitrary `"input"` / `type` — that regression
/// is locked by policy unit tests plus this integration gate when the bridge socket is live.
///
/// Opt-in: set `RUN_PRIVILEGED_SOCKET_REDTEAM=1` and restart privileged daemons from a P0+ build.
final class PrivilegedSocketRedTeamIntegrationTests: XCTestCase {
    private static let virtualHIDSocket = "/var/run/openburnbar-virtual-hid.sock"

    private enum RedTeamSetupError: Error {
        case socketMissing(String)
        case probeMissing(String)
    }

    func test_redTeamProbe_rejectsVirtualHIDInput_whenSocketLive() throws {
        try runRedTeamProbeIfSocketLive(socket: Self.virtualHIDSocket)
    }

    private func runRedTeamProbeIfSocketLive(socket: String, operation: String = "input") throws {
        guard ProcessInfo.processInfo.environment["RUN_PRIVILEGED_SOCKET_REDTEAM"] == "1" else {
            throw XCTSkip("Set RUN_PRIVILEGED_SOCKET_REDTEAM=1 after rebuilding privileged daemons") // env-guard: RUN_PRIVILEGED_SOCKET_REDTEAM=1
        }
        // Past the opt-in gate the operator asserted the environment is ready
        // (the nightly CI job boots the bridge and builds the probe first), so
        // a missing socket/probe is a broken setup that must fail loudly with
        // an actionable message, never a silent skip.
        guard FileManager.default.fileExists(atPath: socket) else {
            XCTFail("RUN_PRIVILEGED_SOCKET_REDTEAM=1 is set but the privileged socket is not present at \(socket) — rebuild privileged daemons from a P0+ build and restart them")
            throw RedTeamSetupError.socketMissing(socket)
        }

        let probeURL: URL
        if let probePath = ProcessInfo.processInfo.environment["OPENBURNBAR_REDTEAM_PROBE_PATH"],
           !probePath.isEmpty {
            probeURL = URL(fileURLWithPath: probePath)
        } else {
            probeURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".build/debug/OpenBurnBarPrivilegedSocketRedTeamProbe")
        }

        guard FileManager.default.isExecutableFile(atPath: probeURL.path) else {
            XCTFail("RUN_PRIVILEGED_SOCKET_REDTEAM=1 is set but the red-team probe is not built; expected executable at \(probeURL.path)")
            throw RedTeamSetupError.probeMissing(probeURL.path)
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
