import OpenBurnBarKernel
import XCTest

@testable import OpenBurnBar

@MainActor
final class FleetServiceTests: XCTestCase {
    private var socketURL: URL {
        URL(fileURLWithPath: "/tmp/openburnbar-fleet-tests/daemon.sock")
    }

    func test_initialStateIsLoading() {
        let service = FleetService(socketURL: socketURL) { _ in
            throw BurnBarFleetClientError.daemonUnavailable("no socket")
        }
        XCTAssertEqual(service.loadState, .loading)
        XCTAssertFalse(service.isPolling)
    }

    func test_readySnapshotMapsToReady() {
        let snapshot = FleetTestFixtures.makeSnapshot()
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        service.fetchOnce()
        XCTAssertEqual(service.loadState, .ready(snapshot))
        XCTAssertEqual(service.requestCount, 1)
    }

    func test_zeroRunningSnapshotMapsToEmpty() {
        let snapshot = FleetTestFixtures.makeEmptySnapshot()
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        service.fetchOnce()
        XCTAssertEqual(service.loadState, .empty(snapshot))
        XCTAssertEqual(service.loadState.snapshot?.runningCount, 0)
    }

    func test_unreachableSocketMapsToDaemonDown() {
        let service = FleetService(socketURL: socketURL) { _ in
            throw BurnBarFleetClientError.daemonUnavailable("connect failed")
        }
        service.fetchOnce()
        guard case .daemonDown(let reason) = service.loadState else {
            XCTFail("expected daemonDown, got \(service.loadState)")
            return
        }
        XCTAssertTrue(reason.contains("unreachable"))
    }

    func test_notReadyKeepsLoading() {
        let service = FleetService(socketURL: socketURL) { _ in
            throw BurnBarFleetClientError.notReady
        }
        service.fetchOnce()
        XCTAssertEqual(service.loadState, .loading)
    }

    func test_protocolMismatchMapsToDaemonDown() {
        let service = FleetService(socketURL: socketURL) { _ in
            throw BurnBarFleetClientError.protocolMismatch(reason: "unknown method")
        }
        service.fetchOnce()
        guard case .daemonDown(let reason) = service.loadState else {
            XCTFail("expected daemonDown, got \(service.loadState)")
            return
        }
        XCTAssertTrue(reason.contains("protocol mismatch"))
    }

    func test_pollErrorDoesNotBlankHealthyBoard() {
        let snapshot = FleetTestFixtures.makeSnapshot()
        var shouldFail = false
        let service = FleetService(socketURL: socketURL) { _ in
            if shouldFail {
                throw BurnBarFleetClientError.daemonUnavailable("connect failed")
            }
            return snapshot
        }
        service.fetchOnce()
        XCTAssertEqual(service.loadState, .ready(snapshot))
        shouldFail = true
        service.fetchOnce()
        XCTAssertEqual(service.loadState, .ready(snapshot), "a transient poll miss must keep the last honest snapshot")
    }

    func test_stalenessThresholdUsesTwoTimesCadence() {
        let now = Date()
        let fresh = FleetTestFixtures.makeSnapshot(generatedAt: now, cadenceSeconds: 15)
        let service = FleetService(socketURL: socketURL, fetchSnapshot: { _ in fresh }, now: { now })
        service.fetchOnce()
        XCTAssertFalse(service.isStale)

        let stale = FleetTestFixtures.makeSnapshot(
            generatedAt: now.addingTimeInterval(-31),
            cadenceSeconds: 15
        )
        let staleService = FleetService(socketURL: socketURL, fetchSnapshot: { _ in stale }, now: { now })
        staleService.fetchOnce()
        XCTAssertTrue(staleService.isStale)
    }

    func test_startIsIdempotent_singlePoller() async throws {
        let service = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeSnapshot()
        }
        service.start()
        service.start()
        service.start()
        XCTAssertTrue(service.isPolling)
        XCTAssertEqual(service.requestCount, 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.requestCount, 1)
        service.stop()
        XCTAssertFalse(service.isPolling)
    }

    func test_refreshOrchestratorStateFailureRetainsAck() {
        let acknowledged = BurnBarOrchestratorState(
            designation: .agent(id: .claudeCode, sessionRef: .absent),
            setAt: Date(timeIntervalSince1970: 1_752_000_000),
            pendingDirectives: 1
        )
        var shouldFail = false
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in
                if shouldFail {
                    throw BurnBarFleetClientError.daemonUnavailable("connect failed")
                }
                return acknowledged
            }
        )
        service.refreshOrchestratorState()
        XCTAssertEqual(service.orchestratorState, acknowledged)
        shouldFail = true
        service.refreshOrchestratorState()
        XCTAssertEqual(service.orchestratorState, acknowledged)
        XCTAssertNotNil(service.orchestratorStateError)
    }

    func test_fileFallbackRecoversWhenRPCFails() throws {
        let snapshot = FleetTestFixtures.makeSnapshot()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-fallback-\(UUID().uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let recovered = try FleetService.fetchSnapshotWithFileFallback(
            at: socketURL,
            fileURL: fileURL
        )
        XCTAssertEqual(recovered.runningCount, snapshot.runningCount)
        XCTAssertEqual(recovered.generatedAt.timeIntervalSince1970, snapshot.generatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_fileFallbackAbsentKeepsRPCError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-missing-\(UUID().uuidString).json")
        XCTAssertThrowsError(
            try FleetService.fetchSnapshotWithFileFallback(at: socketURL, fileURL: missing)
        )
    }

    func test_snapshotFileRoundTrip() throws {
        let snapshot = FleetTestFixtures.makeSnapshot()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-file-\(UUID().uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let read = try XCTUnwrap(BurnBarFleetSnapshotFile.readIfPresent(at: fileURL))
        XCTAssertEqual(read.schemaVersion, snapshot.schemaVersion)
        XCTAssertEqual(read.runningCount, snapshot.runningCount)
        XCTAssertEqual(read.agents.count, snapshot.agents.count)
    }

    func test_setDesignationChangesOnlyAfterDaemonAck() async {
        let prior = BurnBarOrchestratorState(
            designation: .burnBarManaged,
            setAt: Date(timeIntervalSince1970: 1_752_000_000),
            pendingDirectives: 0
        )
        let acked = BurnBarOrchestratorState(
            designation: .none,
            setAt: Date(timeIntervalSince1970: 1_752_000_100),
            pendingDirectives: 0
        )
        var shouldFail = true
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in prior },
            setOrchestratorState: { designation, _ in
                if shouldFail {
                    throw BurnBarFleetClientError.rpcError(code: -32603, message: "rejected")
                }
                XCTAssertEqual(designation, .none)
                return acked
            }
        )
        service.refreshOrchestratorState()
        XCTAssertEqual(service.orchestratorState, prior)

        await service.setDesignation(.none)
        XCTAssertEqual(service.orchestratorState, prior, "a rejected set must not apply locally")
        XCTAssertNotNil(service.orchestratorStateError)

        shouldFail = false
        await service.setDesignation(.none)
        XCTAssertEqual(service.orchestratorState, acked)
        XCTAssertNil(service.orchestratorStateError)
    }
}
