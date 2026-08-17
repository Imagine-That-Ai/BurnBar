import BurnBarCore
import XCTest

@testable import BurnBar

// MARK: - Fleet Service Tests

/// M3 polling contract tests (VAL-DASH-015/018/026/028, VAL-CROSS-002):
/// exactly one active poller, ≤1 request per cadence interval after the
/// initial request, typed load-state transitions (loading → ready/empty/
/// daemonDown), the documented 2×cadence staleness threshold, and lifecycle
/// correctness across start/stop cycles.
@MainActor
final class FleetServiceTests: XCTestCase {

    private var socketURL: URL {
        URL(fileURLWithPath: "/tmp/burnbar-fleet-tests/daemon.sock")
    }

    // MARK: - Typed load states

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
            return XCTFail("expected daemonDown, got \(service.loadState)")
        }
        XCTAssertTrue(reason.contains("unreachable"))
    }

    func test_notReadyKeepsLoading() {
        // The daemon is alive but its first tick has not completed: the app
        // stays in the explicit loading state, never a fabricated empty board
        // (VAL-DASH-028).
        let service = FleetService(socketURL: socketURL) { _ in
            throw BurnBarFleetClientError.notReady
        }
        service.fetchOnce()
        XCTAssertEqual(service.loadState, .loading)
    }

    func test_protocolMismatchMapsToDaemonDown() {
        // Old daemon vs new app (VAL-CROSS-007): typed degrade, never a
        // fabricated snapshot.
        let service = FleetService(socketURL: socketURL) { _ in
            throw BurnBarFleetClientError.protocolMismatch(reason: "unknown method")
        }
        service.fetchOnce()
        guard case .daemonDown(let reason) = service.loadState else {
            return XCTFail("expected daemonDown, got \(service.loadState)")
        }
        XCTAssertTrue(reason.contains("protocol mismatch"))
    }

    // MARK: - Staleness threshold (VAL-DASH-006/009)

    func test_stalenessThresholdUsesTwoTimesCadence() {
        let now = Date()
        let fresh = FleetTestFixtures.makeSnapshot(generatedAt: now, cadenceSeconds: 15)
        let service = FleetService(socketURL: socketURL, fetchSnapshot: { _ in fresh }, now: { now })
        service.fetchOnce()
        XCTAssertFalse(service.isStale, "a just-fetched snapshot must not be stale")

        // Age exactly at the threshold boundary: not stale (strict >).
        let boundary = FleetTestFixtures.makeSnapshot(
            generatedAt: now.addingTimeInterval(-30),
            cadenceSeconds: 15
        )
        let boundaryService = FleetService(socketURL: socketURL, fetchSnapshot: { _ in boundary }, now: { now })
        boundaryService.fetchOnce()
        XCTAssertFalse(boundaryService.isStale, "age == 2×cadence is not stale (strict >)")

        // Age beyond the threshold: stale.
        let stale = FleetTestFixtures.makeSnapshot(
            generatedAt: now.addingTimeInterval(-31),
            cadenceSeconds: 15
        )
        let staleService = FleetService(socketURL: socketURL, fetchSnapshot: { _ in stale }, now: { now })
        staleService.fetchOnce()
        XCTAssertTrue(staleService.isStale, "age > 2×cadence must be stale")
    }

    func test_stalenessUsesSnapshotCadenceNotDefault() {
        let now = Date()
        let snapshot = FleetTestFixtures.makeSnapshot(
            generatedAt: now.addingTimeInterval(-25),
            cadenceSeconds: 10
        )
        let service = FleetService(socketURL: socketURL, fetchSnapshot: { _ in snapshot }, now: { now })
        service.fetchOnce()
        XCTAssertTrue(service.isStale, "25s > 2×10s must be stale with cadence 10")
        XCTAssertEqual(service.cadenceSeconds, 10)
    }

    // MARK: - Polling lifecycle (VAL-DASH-015/018)

    func test_startIsIdempotent_singlePoller() async throws {
        let service = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeSnapshot()
        }
        service.start()
        service.start()
        service.start()
        XCTAssertTrue(service.isPolling)
        XCTAssertEqual(service.requestCount, 1, "exactly one initial request")
        // Wait for the poll loop to be alive; no second request should appear
        // before a full cadence elapses.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.requestCount, 1, "no request before the cadence interval")
        service.stop()
        XCTAssertFalse(service.isPolling)
    }

    func test_stopCancelsPoller() async throws {
        let service = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeSnapshot()
        }
        service.start()
        XCTAssertTrue(service.isPolling)
        service.stop()
        XCTAssertFalse(service.isPolling)
        let countAfterStop = service.requestCount
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.requestCount, countAfterStop, "no requests after stop")
    }

    func test_closeReopenCyclesNeverAccumulatePollers() async throws {
        // N ≥ 3 close/reopen cycles: exactly one poller and one initial
        // request per cycle, never more (VAL-DASH-015/018).
        let service = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeSnapshot()
        }
        for cycle in 1...3 {
            service.start()
            XCTAssertTrue(service.isPolling, "cycle \(cycle): poller active")
            XCTAssertEqual(service.requestCount, 1, "cycle \(cycle): one initial request")
            try await Task.sleep(nanoseconds: 50_000_000)
            service.stop()
            XCTAssertFalse(service.isPolling, "cycle \(cycle): poller stopped")
        }
        XCTAssertEqual(service.requestCount, 1, "counters reset per start; last cycle has one request")
    }

    func test_requestsBoundedPerCadenceInterval() async throws {
        // With a 1-second cadence snapshot, over ~2.5 intervals the request
        // count must stay ≤ 1 (initial) + 2 (one per interval).
        let snapshot = FleetTestFixtures.makeSnapshot(cadenceSeconds: 1)
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        service.start()
        try await Task.sleep(nanoseconds: 2_600_000_000)
        service.stop()
        XCTAssertLessThanOrEqual(service.requestCount, 3, "≤1 request per cadence interval plus initial")
        XCTAssertGreaterThanOrEqual(service.requestCount, 2, "the poller must advance at cadence")
    }

    func test_daemonDownThenRecovery() async throws {
        // VAL-CROSS-002: kill → typed degrade → restart → automatic recovery
        // to a newer generation.
        var daemonUp = false
        let service = FleetService(socketURL: socketURL) { _ in
            guard daemonUp else {
                throw BurnBarFleetClientError.daemonUnavailable("connect failed")
            }
            return FleetTestFixtures.makeSnapshot()
        }
        service.fetchOnce()
        guard case .daemonDown = service.loadState else {
            return XCTFail("expected daemonDown while daemon is down")
        }

        daemonUp = true
        service.fetchOnce()
        guard case .ready = service.loadState else {
            return XCTFail("expected ready after recovery")
        }
    }

    func test_daemonDownThenPollRecoveryReauthorizesDesignationFromSnapshot() {
        let acknowledged = BurnBarOrchestratorState(
            designation: .agent(id: .hermes, sessionRef: .absent),
            setAt: Date(timeIntervalSince1970: 1_752_000_000),
            pendingDirectives: 1
        )
        let recoveredSnapshot = FleetTestFixtures.makeSnapshot()
        var daemonUp = true
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in
                guard daemonUp else {
                    throw BurnBarFleetClientError.daemonUnavailable("connect failed")
                }
                return recoveredSnapshot
            },
            fetchOrchestratorState: { _ in
                guard daemonUp else {
                    throw BurnBarFleetClientError.daemonUnavailable("connect failed")
                }
                return acknowledged
            }
        )
        let viewModel = FleetViewModel(service: service)

        service.refreshOrchestratorState()
        XCTAssertEqual(service.orchestratorState, acknowledged)

        daemonUp = false
        service.refreshOrchestratorState()
        XCTAssertEqual(service.orchestratorState, acknowledged)
        XCTAssertNotNil(service.orchestratorStateError)

        daemonUp = true
        service.fetchOnce()

        XCTAssertEqual(service.orchestratorState, recoveredSnapshot.orchestrator)
        XCTAssertNil(service.orchestratorStateError)
        XCTAssertFalse(
            service.orchestratorState == acknowledged,
            "a recovered authoritative poll must not retain the stale designation"
        )
        XCTAssertFalse(viewModel.isDesignationUnavailable)
    }

    // MARK: - Orchestrator designation (VAL-ORCH-034)

    func test_refreshOrchestratorStateFetchesDaemonState() {
        let state = BurnBarOrchestratorState(
            designation: .agent(id: .claudeCode, sessionRef: .present("sess-1")),
            setAt: Date(timeIntervalSince1970: 1_752_000_000),
            pendingDirectives: 2
        )
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in state }
        )
        XCTAssertNil(service.orchestratorState)
        service.refreshOrchestratorState()
        XCTAssertEqual(service.orchestratorState, state)
        XCTAssertNil(service.orchestratorStateError)
    }

    func test_refreshOrchestratorStateFailureIsTyped() {
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
                if !shouldFail {
                    return acknowledged
                }
                throw BurnBarFleetClientError.daemonUnavailable("connect failed")
            }
        )
        service.refreshOrchestratorState()
        XCTAssertEqual(service.orchestratorState, acknowledged)
        shouldFail = true
        service.refreshOrchestratorState()
        XCTAssertEqual(
            service.orchestratorState,
            acknowledged,
            "a refresh failure must retain the last daemon-acknowledged state"
        )
        XCTAssertNotNil(service.orchestratorStateError)
        XCTAssertTrue(service.orchestratorStateError?.contains("unreachable") == true)
    }

    func test_setDesignationChangesOnlyAfterDaemonAck() async {
        // The control changes only after daemon acknowledgement: the set
        // closure returns the updated state, which is stored. No optimistic
        // local state (VAL-ORCH-034).
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in
                BurnBarOrchestratorState(designation: .none)
            },
            setOrchestratorState: { designation, _ in
                BurnBarOrchestratorState(designation: designation, setAt: Date(), pendingDirectives: 0)
            }
        )
        service.refreshOrchestratorState()
        XCTAssertEqual(service.orchestratorState?.designation, BurnBarOrchestratorDesignation.none)

        await service.setDesignation(.burnBarManaged)
        XCTAssertEqual(service.orchestratorState?.designation, .burnBarManaged)
        XCTAssertNil(service.orchestratorStateError)
    }

    func test_setDesignationRejectionPreservesPriorState() async {
        // A rejected set preserves the prior acknowledged state and surfaces
        // a typed error (VAL-ORCH-034).
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in
                BurnBarOrchestratorState(designation: .burnBarManaged, setAt: Date(), pendingDirectives: 0)
            },
            setOrchestratorState: { _, _ in
                throw BurnBarFleetClientError.rpcError(code: -32603, message: "invalid designation")
            }
        )
        service.refreshOrchestratorState()
        XCTAssertEqual(service.orchestratorState?.designation, .burnBarManaged)

        await service.setDesignation(.agent(id: .claudeCode, sessionRef: .absent))
        XCTAssertEqual(
            service.orchestratorState?.designation,
            .burnBarManaged,
            "a rejected set must preserve the prior acknowledged state"
        )
        XCTAssertNotNil(service.orchestratorStateError)
        XCTAssertTrue(service.orchestratorStateError?.contains("invalid designation") == true)
    }

    func test_setDesignationWhileInFlightIsSerialized() async {
        // Concurrent set requests serialize: the second is a no-op while the
        // first is in flight (single-writer discipline, VAL-ORCH-034).
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in BurnBarOrchestratorState(designation: .none) },
            setOrchestratorState: { designation, _ in
                BurnBarOrchestratorState(designation: designation, setAt: Date(), pendingDirectives: 0)
            }
        )
        let first = Task { await service.setDesignation(.burnBarManaged) }
        let second = Task { await service.setDesignation(.agent(id: .hermes, sessionRef: .absent)) }
        await first.value
        await second.value
        // Both requests complete; the final state is one complete accepted
        // payload (never torn/merged).
        let final = service.orchestratorState?.designation
        XCTAssertTrue(
            final == .burnBarManaged || final == .agent(id: .hermes, sessionRef: .absent),
            "final state must be one complete accepted payload, got \(String(describing: final))"
        )
    }

    func test_contextFetchWhilePollingDoesNotClobberBoardOrAck() async {
        let ready = FleetTestFixtures.makeSnapshot()
        let lagging = FleetTestFixtures.makeSnapshot()
        let laggingNone = BurnBarFleetSnapshot(
            schemaVersion: lagging.schemaVersion,
            generatedAt: lagging.generatedAt.addingTimeInterval(-60),
            cadenceSeconds: lagging.cadenceSeconds,
            machine: lagging.machine,
            agents: lagging.agents,
            repos: lagging.repos,
            runningCount: lagging.runningCount,
            countsByAgent: lagging.countsByAgent,
            orchestrator: BurnBarOrchestratorState(designation: .none),
            probeHealth: lagging.probeHealth,
            persistenceHealth: lagging.persistenceHealth
        )
        var nextSnapshot = ready
        var shouldFail = false
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in
                if shouldFail {
                    throw BurnBarFleetClientError.daemonUnavailable("connect failed")
                }
                return nextSnapshot
            },
            setOrchestratorState: { designation, _ in
                BurnBarOrchestratorState(
                    designation: designation,
                    setAt: Date(timeIntervalSince1970: 1_752_000_100),
                    pendingDirectives: 0
                )
            }
        )
        service.start()
        XCTAssertEqual(service.loadState, .ready(ready))
        let requestsAfterStart = service.requestCount

        await service.setDesignation(.agent(id: .hermes, sessionRef: .absent))
        let acknowledged = service.orchestratorState

        nextSnapshot = laggingNone
        shouldFail = true
        XCTAssertEqual(service.fetchSnapshotForContext(), ready)
        XCTAssertEqual(service.requestCount, requestsAfterStart)
        XCTAssertEqual(service.loadState, .ready(ready))
        XCTAssertEqual(service.orchestratorState, acknowledged)
        XCTAssertTrue(service.isPolling)

        shouldFail = false
        _ = service.fetchSnapshotForContext()
        XCTAssertEqual(service.loadState, .ready(ready))
        XCTAssertEqual(service.orchestratorState, acknowledged)
        XCTAssertTrue(service.isPolling)

        service.stop()
    }

    func test_contextFetchAfterStopDoesNotStartPollerOrBlankHealthyBoard() {
        let ready = FleetTestFixtures.makeSnapshot()
        var shouldFail = false
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in
                if shouldFail {
                    throw BurnBarFleetClientError.daemonUnavailable("connect failed")
                }
                return ready
            }
        )
        service.fetchOnce()
        XCTAssertEqual(service.loadState, .ready(ready))
        shouldFail = true
        XCTAssertEqual(service.fetchSnapshotForContext(), ready)
        XCTAssertEqual(service.loadState, .ready(ready))
        XCTAssertFalse(service.isPolling)
    }

    func test_fetchOnceKeepsNewerSetAckAgainstLaggingEmbed() async {
        let ready = FleetTestFixtures.makeSnapshot()
        let olderNone = snapshot(
            from: ready,
            orchestrator: BurnBarOrchestratorState(
                designation: .none,
                setAt: Date(timeIntervalSince1970: 1_752_000_000)
            )
        )
        var next = ready
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in next },
            fetchOrchestratorState: { _ in
                throw BurnBarFleetClientError.daemonUnavailable("connect failed")
            },
            setOrchestratorState: { designation, _ in
                BurnBarOrchestratorState(
                    designation: designation,
                    setAt: Date(timeIntervalSince1970: 1_752_000_100),
                    pendingDirectives: 0
                )
            }
        )
        service.fetchOnce()
        await service.setDesignation(.agent(id: .hermes, sessionRef: .absent))
        let acknowledged = service.orchestratorState
        service.refreshOrchestratorState()
        XCTAssertNotNil(service.orchestratorStateError)

        next = olderNone
        service.fetchOnce()
        XCTAssertEqual(service.orchestratorState, acknowledged)
        XCTAssertNil(service.orchestratorStateError, "successful snapshot must unhide the designation picker")
        XCTAssertFalse(service.isPolling)
    }

    func test_fetchOnceAdoptsEqualOrNewerSnapshotSetAt() async {
        let ready = FleetTestFixtures.makeSnapshot()
        let newer = snapshot(
            from: ready,
            orchestrator: BurnBarOrchestratorState(
                designation: .burnBarManaged,
                setAt: Date(timeIntervalSince1970: 1_752_000_200),
                pendingDirectives: 0
            )
        )
        var next = ready
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in next },
            setOrchestratorState: { designation, _ in
                BurnBarOrchestratorState(
                    designation: designation,
                    setAt: Date(timeIntervalSince1970: 1_752_000_100),
                    pendingDirectives: 0
                )
            }
        )
        service.fetchOnce()
        await service.setDesignation(.agent(id: .hermes, sessionRef: .absent))
        next = newer
        service.fetchOnce()
        XCTAssertEqual(service.orchestratorState, newer.orchestrator)
        XCTAssertFalse(service.isPolling)
    }

    private func snapshot(
        from base: BurnBarFleetSnapshot,
        orchestrator: BurnBarOrchestratorState
    ) -> BurnBarFleetSnapshot {
        BurnBarFleetSnapshot(
            schemaVersion: base.schemaVersion,
            generatedAt: base.generatedAt,
            cadenceSeconds: base.cadenceSeconds,
            machine: base.machine,
            agents: base.agents,
            repos: base.repos,
            runningCount: base.runningCount,
            countsByAgent: base.countsByAgent,
            orchestrator: orchestrator,
            probeHealth: base.probeHealth,
            persistenceHealth: base.persistenceHealth
        )
    }
}
