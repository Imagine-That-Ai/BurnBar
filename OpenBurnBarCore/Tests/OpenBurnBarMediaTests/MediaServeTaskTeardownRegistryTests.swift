import XCTest
@testable import OpenBurnBarIrohRelay
@testable import OpenBurnBarMedia

/// RR-18 — the per-peer serve-task index that lets the host accept loop cancel
/// just the serve tasks belonging to a de-allowlisted / revoked peer on an
/// allowlist refresh, instead of only being able to cancel them all at stop().
final class MediaServeTaskTeardownRegistryTests: XCTestCase {
    func testCancelTasksTearsDownOnlyDeAllowlistedPeer() async {
        let registry = MediaServeTaskTeardownRegistry()
        let revokedRan = TaskFlag()
        let allowedRan = TaskFlag()

        let revokedID = UUID()
        let revokedTask = Task { await Self.runUntilCancelled(setting: revokedRan) }
        await registry.register(serveID: revokedID, remotePeerNodeId: "ios-revoked", task: revokedTask)

        let allowedID = UUID()
        let allowedTask = Task { await Self.runUntilCancelled(setting: allowedRan) }
        await registry.register(serveID: allowedID, remotePeerNodeId: "ios-allowed", task: allowedTask)

        let policy = IrohInboundPeerPolicy(allowedPeerNodeIds: ["ios-allowed"])
        let cancelled = await registry.cancelTasks { policy.allows(remotePeerNodeId: $0) }

        XCTAssertEqual(cancelled, [revokedID])
        let remaining = await registry.activeTaskCount()
        XCTAssertEqual(remaining, 1)
        // The revoked task observes cancellation; the allowed one keeps running.
        await revokedTask.value
        let revokedObservedCancel = await revokedRan.wasCancelled()
        XCTAssertTrue(revokedObservedCancel)
        XCTAssertFalse(allowedTask.isCancelled)

        allowedTask.cancel()
        await allowedTask.value
    }

    func testCancelTasksTearsDownUnknownPeerNodeId() async {
        let registry = MediaServeTaskTeardownRegistry()
        let id = UUID()
        let task = Task { await Self.runUntilCancelled(setting: TaskFlag()) }
        await registry.register(serveID: id, remotePeerNodeId: nil, task: task)

        let policy = IrohInboundPeerPolicy(allowedPeerNodeIds: ["ios-allowed"])
        let cancelled = await registry.cancelTasks { policy.allows(remotePeerNodeId: $0) }

        XCTAssertEqual(cancelled, [id])
        XCTAssertTrue(task.isCancelled)
        await task.value
    }

    func testReleaseStopsStaleEntryFromBeingCancelled() async {
        let registry = MediaServeTaskTeardownRegistry()
        let id = UUID()
        let task = Task<Void, Never> {}
        await registry.register(serveID: id, remotePeerNodeId: "ios-revoked", task: task)
        await task.value
        // Task finished and host released it before the refresh runs.
        await registry.release(serveID: id)

        let policy = IrohInboundPeerPolicy(allowedPeerNodeIds: [])
        let cancelled = await registry.cancelTasks { policy.allows(remotePeerNodeId: $0) }

        XCTAssertTrue(cancelled.isEmpty)
        let remaining = await registry.activeTaskCount()
        XCTAssertEqual(remaining, 0)
    }

    func testCancelAllTearsDownEveryTrackedTask() async {
        let registry = MediaServeTaskTeardownRegistry()
        let first = Task { await Self.runUntilCancelled(setting: TaskFlag()) }
        let second = Task { await Self.runUntilCancelled(setting: TaskFlag()) }
        await registry.register(serveID: UUID(), remotePeerNodeId: "a", task: first)
        await registry.register(serveID: UUID(), remotePeerNodeId: "b", task: second)

        await registry.cancelAll()

        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(second.isCancelled)
        let remaining = await registry.activeTaskCount()
        XCTAssertEqual(remaining, 0)
        await first.value
        await second.value
    }

    private static func runUntilCancelled(setting flag: TaskFlag) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await flag.markCancelled()
    }
}

private actor TaskFlag {
    private var cancelled = false
    func markCancelled() { cancelled = true }
    func wasCancelled() -> Bool { cancelled }
}
