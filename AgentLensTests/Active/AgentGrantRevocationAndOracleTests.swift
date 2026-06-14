import Foundation
import XCTest
@testable import OpenBurnBar

/// T-AI-02 (oracle body wrapped as untrusted, "authoritative" framing dropped)
/// and T-TOOL-03 (grant revocation terminates the in-flight spawned CLI process
/// via the runtime coordinator chokepoint).
final class AgentGrantRevocationAndOracleTests: XCTestCase {

    // MARK: - T-AI-02: oracle context wrapping

    func test_oracleContextSection_wrapsBodyAsUntrusted() {
        let section = ChatSessionController.buildOracleContextSection(
            contextBody: "matched session: thread-42 — user did X"
        )
        XCTAssertTrue(section.contains("<UNTRUSTED_CONTENT"))
        XCTAssertTrue(section.contains("local_index_oracle"))
        XCTAssertTrue(section.contains("matched session: thread-42"))
    }

    func test_oracleContextSection_dropsAuthoritativeFraming() {
        let section = ChatSessionController.buildOracleContextSection(
            contextBody: "some indexed finding"
        )
        XCTAssertFalse(
            section.lowercased().contains("authoritative"),
            "the oracle section must not frame untrusted indexed content as authoritative"
        )
    }

    func test_oracleContextSection_emptyBodyProducesNothing() {
        XCTAssertEqual(ChatSessionController.buildOracleContextSection(contextBody: "   "), "")
    }

    // MARK: - T-TOOL-03: runtime coordinator terminates the in-flight process

    func test_runtimeCoordinator_terminateRunningProcessKillsSpawnedProcess() async throws {
        let coordinator = CLIBridgeStreamRuntimeCoordinator()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        XCTAssertTrue(process.isRunning)

        _ = await coordinator.registerRunningProcess(process)
        await coordinator.terminateRunningProcess()

        // Give the OS a brief moment to reap the terminated process.
        for _ in 0..<50 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(process.isRunning, "revocation must terminate the in-flight CLI process")
    }

    func test_spawnedCLIGrantPoll_isNilForUngrantedRun() {
        XCTAssertNil(CLIBridge.spawnedCLIGrantPoll(for: nil))
    }
}
