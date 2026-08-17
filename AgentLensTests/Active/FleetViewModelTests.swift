import OpenBurnBarKernel
import XCTest

@testable import OpenBurnBar

@MainActor
final class FleetViewModelTests: XCTestCase {
    private var socketURL: URL {
        URL(fileURLWithPath: "/tmp/openburnbar-fleet-tests/daemon.sock")
    }

    func test_headerNeverShowsZeroRunningBeforeSnapshot() {
        let service = FleetService(socketURL: socketURL) { _ in
            throw BurnBarFleetClientError.notReady
        }
        let viewModel = FleetViewModel(service: service)
        XCTAssertEqual(viewModel.headerRunningReadout, .checking)
        service.fetchOnce()
        XCTAssertEqual(viewModel.headerRunningReadout, .checking)
        XCTAssertEqual(viewModel.runningCount, 0)
    }

    func test_emptySnapshotShowsHonestZeroRunning() {
        let snapshot = FleetTestFixtures.makeEmptySnapshot()
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()
        XCTAssertEqual(viewModel.headerRunningReadout, .running(0))
        XCTAssertEqual(viewModel.agents.count, 10)
        XCTAssertEqual(Set(viewModel.agents.map(\.id)), Set(BurnBarFleetAgentID.declaredRoster))
    }

    func test_countsByProviderFollowsDeclaredRosterWithExplicitZeros() {
        let snapshot = FleetTestFixtures.makeSnapshot()
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        let counts = viewModel.countsByProvider
        XCTAssertEqual(counts.map(\.agentID), BurnBarFleetAgentID.declaredRoster)
        XCTAssertEqual(counts.first { $0.agentID == .claudeCode }?.count, 1)
        XCTAssertEqual(counts.first { $0.agentID == .grokBot }?.count, 0)
        XCTAssertEqual(viewModel.headerRunningReadout, .running(1))
    }

    func test_daemonDownHeaderIsUnavailableNotZero() {
        let service = FleetService(socketURL: socketURL) { _ in
            throw BurnBarFleetClientError.daemonUnavailable("connect failed")
        }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()
        XCTAssertEqual(viewModel.headerRunningReadout, .unavailable)
    }

    func test_providerMappingResolvesEveryDeclaredRosterID() {
        for id in BurnBarFleetAgentID.declaredRoster {
            XCTAssertNotNil(AgentProvider(fleetAgentID: id), "\(id.wireValue) must map")
        }
    }

    func test_headerCopyForCheckingIsNotZeroRunning() {
        let service = FleetService(socketURL: socketURL) { _ in
            throw BurnBarFleetClientError.notReady
        }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()
        XCTAssertEqual(
            FleetHeaderCopy.runningReadout(viewModel.headerRunningReadout),
            "Checking…"
        )
        XCTAssertFalse(
            FleetHeaderCopy.runningReadout(viewModel.headerRunningReadout).contains("0")
        )
    }

    func test_staleSnapshotKeepsLastHonestCount() {
        let now = Date()
        let snapshot = FleetTestFixtures.makeSnapshot(
            generatedAt: now.addingTimeInterval(-31),
            cadenceSeconds: 15
        )
        let service = FleetService(socketURL: socketURL, fetchSnapshot: { _ in snapshot }, now: { now })
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()
        XCTAssertTrue(viewModel.isStale)
        XCTAssertEqual(viewModel.headerRunningReadout, .running(1))
        XCTAssertEqual(FleetHeaderCopy.runningReadout(viewModel.headerRunningReadout), "1 running")
    }

    func test_designationUnavailableUntilAckThenRetainedOnRefreshFailure() {
        let acknowledged = BurnBarOrchestratorState(
            designation: .agent(id: .hermes, sessionRef: .absent),
            setAt: Date(timeIntervalSince1970: 1_752_000_000),
            pendingDirectives: 0
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
        let viewModel = FleetViewModel(service: service)
        XCTAssertTrue(viewModel.isDesignationUnavailable)

        viewModel.refreshOrchestratorState()
        XCTAssertFalse(viewModel.isDesignationUnavailable)
        XCTAssertEqual(viewModel.designationKind, acknowledged.designation)

        shouldFail = true
        viewModel.refreshOrchestratorState()
        XCTAssertTrue(viewModel.isDesignationUnavailable)
        XCTAssertEqual(viewModel.designationKind, acknowledged.designation)
    }

    func test_refreshNowPullsSnapshotAndOrchestrator() {
        let snapshot = FleetTestFixtures.makeSnapshot()
        let state = BurnBarOrchestratorState(designation: .burnBarManaged)
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in snapshot },
            fetchOrchestratorState: { _ in state }
        )
        let viewModel = FleetViewModel(service: service)
        viewModel.refreshNow()
        XCTAssertEqual(viewModel.headerRunningReadout, .running(1))
        XCTAssertEqual(viewModel.orchestratorState, state)
        XCTAssertFalse(viewModel.isDesignationUnavailable)
    }
}
