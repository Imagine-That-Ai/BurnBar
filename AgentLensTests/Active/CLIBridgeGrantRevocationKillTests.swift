import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import XCTest
@testable import OpenBurnBar

/// T-TOOL-03: when a desktop-control capability grant is revoked or expires
/// mid-run, the in-flight spawned external-CLI `Process` must be *terminated*,
/// not merely flagged. These tests pin the two halves of that machinery:
///   1. the runtime coordinator chokepoint actually kills a live process, and
///   2. `CLIBridge.spawnedCLIGrantPoll` reports grant liveness honestly so the
///      stream runner can fire the kill the moment the operator pulls the grant
///      (covering both explicit revocation and natural expiry).
final class CLIBridgeGrantRevocationKillTests: XCTestCase {

    // MARK: - Runtime coordinator terminates the in-flight process

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

    // MARK: - Grant poll closure

    func test_spawnedCLIGrantPoll_isNilForUngrantedRun() {
        XCTAssertNil(CLIBridge.spawnedCLIGrantPoll(for: nil))
    }

    @MainActor
    func test_spawnedCLIGrantPoll_tracksLiveGrantThenReportsFalseAfterRevocation() async {
        let store = AgentCapabilityGrantStore.shared
        let runtimeID = AssistantRuntimeID.claude
        let threadID = "ttool03-revoke-\(UUID().uuidString)"

        let grant = AgentCapabilityGrant.sessionGrant(
            runtimeID: runtimeID,
            threadID: threadID,
            capabilities: [.shell]
        )
        store.activate(grant)

        guard let poll = CLIBridge.spawnedCLIGrantPoll(for: grant) else {
            XCTFail("an active grant must produce a non-nil poll closure")
            return
        }

        let activeBeforeRevocation = await poll()
        XCTAssertTrue(activeBeforeRevocation, "poll must report the grant active while it is live in the store")

        store.revoke(runtimeID: runtimeID, threadID: threadID)

        let activeAfterRevocation = await poll()
        XCTAssertFalse(
            activeAfterRevocation,
            "poll must report the grant inactive once it is revoked, so the runner terminates the process"
        )
    }
}
