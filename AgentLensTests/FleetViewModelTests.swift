import BurnBarCore
import XCTest

@testable import BurnBar

// MARK: - Fleet View Model Tests

/// M3 view-model presentation tests (VAL-DASH-006/009/016, VAL-CROSS-001):
/// counts derive from the snapshot, per-provider chips follow the declared
/// roster with explicit zero counts, and the view-model lifecycle drives the
/// single poller.
@MainActor
final class FleetViewModelTests: XCTestCase {

    private var socketURL: URL {
        URL(fileURLWithPath: "/tmp/burnbar-fleet-tests/daemon.sock")
    }

    func test_countsMatchSnapshotExactly() {
        // VAL-CROSS-001: UI counts equal the last-completed RPC counts.
        let snapshot = FleetTestFixtures.makeSnapshot()
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        XCTAssertEqual(viewModel.runningCount, snapshot.runningCount)
        XCTAssertEqual(viewModel.runningCount, 1)
        XCTAssertEqual(viewModel.snapshot, snapshot)
    }

    func test_countsByProviderFollowsDeclaredRosterWithExplicitZeros() {
        let snapshot = FleetTestFixtures.makeSnapshot()
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        let counts = viewModel.countsByProvider
        XCTAssertEqual(counts.count, BurnBarFleetAgentID.declaredRoster.count)
        XCTAssertEqual(counts.map(\.agentID), BurnBarFleetAgentID.declaredRoster)
        let claude = counts.first { $0.agentID == .claudeCode }
        XCTAssertEqual(claude?.count, 1)
        let grokBot = counts.first { $0.agentID == .grokBot }
        XCTAssertEqual(grokBot?.count, 0, "zero-count chips render explicit 0")
        let kimi = counts.first { $0.agentID == .kimi }
        XCTAssertEqual(kimi?.count, 0)
    }

    func test_emptySnapshotExposesTenDeclaredRows() {
        // VAL-DASH-007/CROSS-010: the empty state is a healthy zero-running
        // snapshot with all ten declared rows — never an empty agents[].
        let snapshot = FleetTestFixtures.makeEmptySnapshot()
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        XCTAssertEqual(viewModel.runningCount, 0)
        XCTAssertEqual(viewModel.agents.count, 10)
        XCTAssertEqual(
            Set(viewModel.agents.map(\.id)),
            Set(BurnBarFleetAgentID.declaredRoster)
        )
        XCTAssertTrue(viewModel.agents.allSatisfy { $0.status != .running })
    }

    func test_providerMappingResolvesEveryDeclaredRosterID() {
        // VAL-CROSS-003: every declared roster id maps to a known provider.
        for id in BurnBarFleetAgentID.declaredRoster {
            XCTAssertNotNil(AgentProvider(fleetAgentID: id), "\(id.wireValue) must map")
        }
    }

    func test_viewAppearedStartsSinglePoller() {
        let service = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeSnapshot()
        }
        let viewModel = FleetViewModel(service: service)
        viewModel.viewAppeared()
        XCTAssertTrue(service.isPolling)
        XCTAssertTrue(viewModel.isVisible)
        viewModel.viewDisappeared()
        XCTAssertFalse(service.isPolling)
        XCTAssertFalse(viewModel.isVisible)
    }

    func test_viewDisappearedStopsPoller() {
        let service = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeSnapshot()
        }
        let viewModel = FleetViewModel(service: service)
        viewModel.viewAppeared()
        viewModel.viewDisappeared()
        XCTAssertFalse(service.isPolling)
        // Reappear restarts the single poller (close/reopen cycle).
        viewModel.viewAppeared()
        XCTAssertTrue(service.isPolling)
        XCTAssertEqual(service.requestCount, 1, "one initial request per cycle")
    }

    func test_staleStateExposedThroughViewModel() {
        let now = Date()
        let stale = FleetTestFixtures.makeSnapshot(
            generatedAt: now.addingTimeInterval(-31),
            cadenceSeconds: 15
        )
        let service = FleetService(socketURL: socketURL, fetchSnapshot: { _ in stale }, now: { now })
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()
        XCTAssertTrue(viewModel.isStale)
        XCTAssertNotNil(viewModel.snapshotAgeSeconds)
    }
}

// MARK: - Fleet Formatting Tests

/// Deterministic formatting rules (VAL-DASH-011/022): units, thresholds, and
/// edge cases are fixed-DTO testable.
final class FleetFormattingTests: XCTestCase {

    func test_formatBytesUnits() {
        XCTAssertEqual(FleetFormatting.formatBytes(0), "0 B")
        XCTAssertEqual(FleetFormatting.formatBytes(999), "999 B")
        XCTAssertEqual(FleetFormatting.formatBytes(1_000), "1.0 KB")
        XCTAssertEqual(FleetFormatting.formatBytes(1_500_000), "1.5 MB")
        XCTAssertEqual(FleetFormatting.formatBytes(2_000_000_000), "2.0 GB")
        XCTAssertEqual(FleetFormatting.formatBytes(3_000_000_000_000), "3.00 TB")
    }

    func test_formatBytesClampsNegative() {
        XCTAssertEqual(FleetFormatting.formatBytes(-5), "0 B")
    }

    func test_formatCPU() {
        XCTAssertEqual(FleetFormatting.formatCPU(12.34), "12.3%")
        XCTAssertEqual(FleetFormatting.formatCPU(0), "0.0%")
    }

    func test_formatLoadAverage() {
        XCTAssertEqual(FleetFormatting.formatLoadAverage([1.234, 1.0, 0.8]), "1.23, 1.00, 0.80")
        XCTAssertEqual(FleetFormatting.formatLoadAverage([]), "")
    }

    func test_formatDiskFreeThreshold() {
        // Below 1 GB: MB. At/above 1 GB: GB.
        XCTAssertEqual(FleetFormatting.formatDiskFree(500_000_000), "500 MB")
        XCTAssertEqual(FleetFormatting.formatDiskFree(1_000_000_000), "1.0 GB")
        XCTAssertEqual(FleetFormatting.formatDiskFree(500_000_000_000), "500.0 GB")
    }

    func test_formatMemoryConsistentUnits() {
        XCTAssertEqual(
            FleetFormatting.formatMemory(used: 400_000_000, total: 800_000_000),
            "400 MB / 800 MB"
        )
        XCTAssertEqual(
            FleetFormatting.formatMemory(used: 8_000_000_000, total: 48_000_000_000),
            "8.0 GB / 48.0 GB"
        )
    }

    func test_formatRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        XCTAssertEqual(FleetFormatting.formatRelativeTime(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(FleetFormatting.formatRelativeTime(now.addingTimeInterval(-120), now: now), "2m ago")
        XCTAssertEqual(FleetFormatting.formatRelativeTime(now.addingTimeInterval(-7_200), now: now), "2h ago")
        XCTAssertEqual(FleetFormatting.formatRelativeTime(now.addingTimeInterval(-172_800), now: now), "2d ago")
    }

    func test_formatAge() {
        XCTAssertEqual(FleetFormatting.formatAge(12), "12s")
        XCTAssertEqual(FleetFormatting.formatAge(185), "3m 5s")
        XCTAssertEqual(FleetFormatting.formatAge(3_720), "1h 2m")
    }
}

// MARK: - Confidence Presentation Tests

/// Confidence level → label mapping (VAL-DASH-024/027): every level is
/// textually labeled and provenance includes a signal kind when present.
final class FleetConfidencePresentationTests: XCTestCase {

    func test_allFiveLevelsHaveDistinctLabels() {
        let labels = BurnBarFleetConfidence.allCases.map {
            FleetConfidencePresentation.label(for: $0)
        }
        XCTAssertEqual(Set(labels).count, 5, "all five levels must be textually distinct")
        XCTAssertEqual(
            FleetConfidencePresentation.label(for: .exactProcess),
            "Exact process"
        )
        XCTAssertEqual(
            FleetConfidencePresentation.label(for: .unsupported),
            "No live signal"
        )
    }

    func test_provenanceIncludesSignalKindWhenPresent() {
        let agent = FleetTestFixtures.makeAgent(
            signals: [
                BurnBarFleetSignalSource(
                    kind: "session-registry",
                    path: "/fixtures/claude/sessions/1.json"
                )
            ]
        )
        let provenance = FleetConfidencePresentation.provenance(for: agent)
        XCTAssertTrue(provenance.contains("Exact process"))
        XCTAssertTrue(provenance.contains("session-registry"))
    }

    func test_provenanceFallsBackToConfidenceLabelWithoutSignals() {
        let agent = FleetTestFixtures.makeAgent(signals: [])
        XCTAssertEqual(
            FleetConfidencePresentation.provenance(for: agent),
            "Exact process"
        )
    }
}
