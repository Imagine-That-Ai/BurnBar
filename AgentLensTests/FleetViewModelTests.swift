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

    func test_providerIconMatchesUsageSurfaceIdentity() {
        // VAL-CROSS-003: the fleet card icon for an agent is the same SF
        // Symbol the usage surface renders for the same provider.
        for id in BurnBarFleetAgentID.declaredRoster {
            guard let provider = AgentProvider(fleetAgentID: id) else {
                return XCTFail("\(id.wireValue) must map to a provider")
            }
            let viewModel = FleetViewModel(
                service: FleetService(socketURL: socketURL) { _ in
                    FleetTestFixtures.makeSnapshot()
                }
            )
            XCTAssertEqual(
                viewModel.providerIconName(for: id),
                provider.iconName,
                "fleet icon for \(id.wireValue) must match the usage surface icon"
            )
            XCTAssertEqual(
                viewModel.providerName(for: id),
                provider.displayName,
                "fleet name for \(id.wireValue) must match the usage surface name"
            )
        }
    }

    func test_unsupportedRosterRowsAreDetectedAndExcludedFromRunningTotals() {
        // VAL-DASH-031: kimi/gemini-cli rows are present, labeled unsupported,
        // and excluded from running/resource totals.
        let snapshot = FleetTestFixtures.makeEmptySnapshot()
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        let kimi = viewModel.agents.first { $0.id == .kimi }
        let gemini = viewModel.agents.first { $0.id == .geminiCLI }
        XCTAssertNotNil(kimi, "kimi row must be present")
        XCTAssertNotNil(gemini, "gemini-cli row must be present")
        XCTAssertTrue(viewModel.isUnsupportedRosterRow(kimi!))
        XCTAssertTrue(viewModel.isUnsupportedRosterRow(gemini!))
        XCTAssertEqual(kimi?.status, .unknown)
        XCTAssertEqual(gemini?.status, .unknown)
        XCTAssertEqual(viewModel.runningCount, 0, "unsupported rows never count as running")
        XCTAssertEqual(viewModel.countsByProvider.first { $0.agentID == .kimi }?.count, 0)
        XCTAssertEqual(viewModel.countsByProvider.first { $0.agentID == .geminiCLI }?.count, 0)
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

    func test_headerMachineMetricsAreTheFourCostRows() {
        let service = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeSnapshot()
        }
        let viewModel = FleetViewModel(service: service)
        XCTAssertTrue(viewModel.headerMachineMetrics.isEmpty, "no fabricated machine cost before a snapshot")
        service.fetchOnce()

        XCTAssertEqual(
            viewModel.headerMachineMetrics.map(\.label),
            ["CPU", "Memory", "Load", "Disk free"]
        )
        XCTAssertFalse(viewModel.headerMachineMetrics.contains { $0.label == "Thermal" })
        XCTAssertFalse(viewModel.headerMachineMetrics.contains { $0.label == "Power" })
        XCTAssertEqual(viewModel.headerMachineMetrics.first { $0.label == "CPU" }?.value, "12.5%")
    }

    func test_headerRunningReadoutIsNeverZeroBeforeSnapshot() {
        let service = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeSnapshot()
        }
        let viewModel = FleetViewModel(service: service)
        XCTAssertEqual(viewModel.headerRunningReadout, .checking)
        XCTAssertEqual(viewModel.runningCount, 0)

        service.fetchOnce()
        XCTAssertEqual(viewModel.headerRunningReadout, .running(1))

        let emptyService = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeEmptySnapshot()
        }
        let emptyModel = FleetViewModel(service: emptyService)
        emptyService.fetchOnce()
        XCTAssertEqual(emptyModel.headerRunningReadout, .running(0))

        let down = FleetService(socketURL: socketURL) { _ in
            throw BurnBarFleetClientError.daemonUnavailable("connect failed")
        }
        let downModel = FleetViewModel(service: down)
        down.fetchOnce()
        XCTAssertEqual(downModel.headerRunningReadout, .unavailable)
    }

    func test_headerMachineMetricsOmitThermalEvenWhenSensorsAvailable() {
        let service = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeSnapshot(machine: FleetTestFixtures.makeMachineSensorsAvailable())
        }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        XCTAssertEqual(
            viewModel.headerMachineMetrics.map(\.label),
            ["CPU", "Memory", "Load", "Disk free"]
        )
        XCTAssertTrue(viewModel.machineRows.contains { $0.label == "Thermal" })
        XCTAssertFalse(viewModel.headerMachineMetrics.contains { $0.label == "Thermal" })
        XCTAssertFalse(viewModel.headerMachineMetrics.contains { $0.label == "Power" })
    }

    func test_headerMachineMetricsPreserveUnavailableHonesty() {
        let service = FleetService(socketURL: socketURL) { _ in
            FleetTestFixtures.makeSnapshot(machine: FleetTestFixtures.makeMachineAllOptionalAbsent())
        }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        XCTAssertEqual(viewModel.headerMachineMetrics.count, 4)
        XCTAssertTrue(viewModel.headerMachineMetrics.allSatisfy(\.isUnavailable))
        XCTAssertTrue(viewModel.headerMachineMetrics.allSatisfy { $0.value == nil })
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

    // MARK: - Orchestrator designation + badge (VAL-ORCH-005/034)

    func test_designationKindDerivesFromDaemonState() {
        let state = BurnBarOrchestratorState(
            designation: .agent(id: .claudeCode, sessionRef: .present("sess-1")),
            setAt: Date(timeIntervalSince1970: 1_752_000_000),
            pendingDirectives: 1
        )
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in state }
        )
        let viewModel = FleetViewModel(service: service)
        XCTAssertNil(viewModel.designationKind, "unread daemon state must be explicit unavailable, not None")
        viewModel.refreshOrchestratorState()
        XCTAssertEqual(viewModel.designationKind, state.designation)
        XCTAssertTrue(viewModel.isDesignatedAgent(.claudeCode))
        XCTAssertFalse(viewModel.isDesignatedAgent(.hermes))
    }

    func test_refreshFailureRetainsAcknowledgedDesignationAndDoesNotFabricateNone() {
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
        let viewModel = FleetViewModel(service: service)
        viewModel.refreshOrchestratorState()
        shouldFail = true
        viewModel.refreshOrchestratorState()

        XCTAssertEqual(viewModel.designationKind, acknowledged.designation)
        XCTAssertFalse(viewModel.isDesignatedAgent(.claudeCode), "badge is suppressed while refresh is unavailable")
        XCTAssertNotNil(viewModel.orchestratorStateError)
    }

    func test_unavailableDesignationHasNoControlStateOrAgentBadge() {
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in
                throw BurnBarFleetClientError.daemonUnavailable("connect failed")
            }
        )
        let viewModel = FleetViewModel(service: service)
        viewModel.refreshOrchestratorState()

        XCTAssertNil(viewModel.designationKind)
        XCTAssertFalse(viewModel.isDesignatedAgent(.claudeCode))
        XCTAssertTrue(viewModel.isDesignationUnavailable)
    }

    func test_burnBarManagedDesignationHasNoAgentBadge() {
        let state = BurnBarOrchestratorState(
            designation: .burnBarManaged,
            setAt: Date(timeIntervalSince1970: 1_752_000_000),
            pendingDirectives: 0
        )
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in state }
        )
        let viewModel = FleetViewModel(service: service)
        viewModel.refreshOrchestratorState()
        XCTAssertEqual(viewModel.designationKind, .burnBarManaged)
        for agentID in BurnBarFleetAgentID.declaredRoster {
            XCTAssertFalse(viewModel.isDesignatedAgent(agentID), "no agent badge for burnBarManaged")
        }
    }

    func test_clearedDesignationRemovesBadge() {
        // Clearing the designation removes the mark (VAL-ORCH-005): the
        // badge derives from daemon state, so a cleared state has no badge.
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in
                BurnBarOrchestratorState(designation: .none, setAt: Date(), pendingDirectives: 0)
            }
        )
        let viewModel = FleetViewModel(service: service)
        viewModel.refreshOrchestratorState()
        XCTAssertEqual(viewModel.designationKind, BurnBarOrchestratorDesignation.none)
        XCTAssertFalse(viewModel.isDesignatedAgent(.claudeCode))
    }

    func test_viewAppearedFetchesOrchestratorState() {
        let state = BurnBarOrchestratorState(
            designation: .burnBarManaged,
            setAt: Date(timeIntervalSince1970: 1_752_000_000),
            pendingDirectives: 0
        )
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in state }
        )
        let viewModel = FleetViewModel(service: service)
        viewModel.viewAppeared()
        XCTAssertEqual(viewModel.orchestratorState, state, "the designation control loads on appear")
        viewModel.viewDisappeared()
    }

    func test_setDesignationUpdatesOnlyAfterDaemonAck() async {
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in FleetTestFixtures.makeSnapshot() },
            fetchOrchestratorState: { _ in BurnBarOrchestratorState(designation: .none) },
            setOrchestratorState: { designation, _ in
                BurnBarOrchestratorState(designation: designation, setAt: Date(), pendingDirectives: 0)
            }
        )
        let viewModel = FleetViewModel(service: service)
        viewModel.refreshOrchestratorState()
        XCTAssertEqual(viewModel.designationKind, BurnBarOrchestratorDesignation.none)

        await viewModel.setDesignation(.burnBarManaged)
        XCTAssertEqual(viewModel.designationKind, .burnBarManaged)
        XCTAssertNil(viewModel.orchestratorStateError)
    }

    func test_setDesignationRejectionPreservesPriorState() async {
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
        let viewModel = FleetViewModel(service: service)
        viewModel.refreshOrchestratorState()
        XCTAssertEqual(viewModel.designationKind, .burnBarManaged)

        await viewModel.setDesignation(.agent(id: .claudeCode, sessionRef: .absent))
        XCTAssertEqual(
            viewModel.designationKind,
            .burnBarManaged,
            "a rejected set preserves the prior acknowledged state"
        )
        XCTAssertNotNil(viewModel.orchestratorStateError)
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

/// Confidence level → label/color mapping (VAL-DASH-024/027): every level is
/// textually labeled, the five level colors are pairwise distinct in both
/// appearances, and provenance includes a signal kind when present.
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

    func test_allFiveLevelsHaveDistinctShortLabels() {
        let labels = BurnBarFleetConfidence.allCases.map {
            FleetConfidencePresentation.shortLabel(for: $0)
        }
        XCTAssertEqual(Set(labels).count, 5, "all five badge labels must be textually distinct")
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

    func test_provenanceLabelSurfacesPerCardAndNeverBearsPaths() {
        // VAL-DASH-027: the visible provenance label carries the confidence
        // label plus the signal KIND — never the path or detail (which could
        // bear secret material).
        let agent = FleetTestFixtures.makeAgent(
            signals: [
                BurnBarFleetSignalSource(
                    kind: "heartbeat-file",
                    path: "/Users/albertonunez/.hermes/state/gateway.heartbeat",
                    detail: "token=SECRET"
                )
            ]
        )
        let label = FleetConfidencePresentation.provenanceLabel(for: agent)
        XCTAssertTrue(label.contains("Exact process"))
        XCTAssertTrue(label.contains("heartbeat-file"))
        XCTAssertFalse(label.contains("gateway.heartbeat"), "path must never appear")
        XCTAssertFalse(label.contains("SECRET"), "detail must never appear")
    }

    func test_provenanceLabelForUnsupportedStatesNoLiveSignal() {
        // Unsupported rows say that no live signal is available (VAL-DASH-027).
        let agent = FleetTestFixtures.makeAgent(
            status: .unknown,
            confidence: .unsupported,
            signals: [
                BurnBarFleetSignalSource(
                    kind: "root-presence",
                    path: "/fixtures/kimi"
                )
            ]
        )
        XCTAssertEqual(
            FleetConfidencePresentation.provenanceLabel(for: agent),
            "No live signal"
        )
    }

    func test_fiveLevelColorsArePairwiseDistinctInBothAppearances() {
        // VAL-DASH-024: all five levels render distinctly. The color mapping
        // is deterministic; the textual label is the primary carrier of
        // meaning (colorblind-safe, VAL-DASH-004).
        let colors = BurnBarFleetConfidence.allCases.map {
            FleetConfidencePresentation.color(for: $0)
        }
        XCTAssertEqual(Set(colors).count, 5, "five distinct level colors")
    }

    func test_levelColorsMeetUIComponentContrastAgainstSurface() {
        // VAL-DASH-021: status dots/badges meet WCAG AA 3:1 for UI components
        // against the card surface in both appearances. The mapping is
        // appearance-adaptive, so the test asserts the documented token
        // values (pinned in docs/fleet/BURNBAR_FLEET_SIGNALS.md) rather than
        // resolved NSColors.
        let expected: [BurnBarFleetConfidence: (light: String, dark: String)] = [
            .exactProcess: ("3A7835", "38D898"),       // success
            .activeSessionFile: ("6A5ACD", "8B7FE8"),  // whimsy
            .logHeartbeat: ("C47800", "FFA800"),       // warning
            .estimated: ("D45800", "E86100"),          // blaze
            .unsupported: ("9A8B7A", "7A6E62")         // textMuted
        ]
        for (level, pair) in expected {
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(light: pair.light, dark: pair.dark),
                3.0,
                "\(level) level color must meet the 3:1 UI boundary"
            )
        }
    }

    /// WCAG relative-luminance contrast ratio of the two pinned token values
    /// against the card surface token in the same appearance.
    static func contrastRatio(light: String, dark: String) -> Double {
        let surfaceLight = "FAF7F0"
        let surfaceDark = "1D1914"
        return min(
            Self.ratio(light, surfaceLight),
            Self.ratio(dark, surfaceDark)
        )
    }

    private static func ratio(_ first: String, _ second: String) -> Double {
        let firstLuminance = luminance(first)
        let secondLuminance = luminance(second)
        let high = max(firstLuminance, secondLuminance)
        let low = min(firstLuminance, secondLuminance)
        return (high + 0.05) / (low + 0.05)
    }

    private static func luminance(_ hex: String) -> Double {
        let red = Double(Int(hex.prefix(2), radix: 16) ?? 0) / 255
        let green = Double(Int(hex.dropFirst(2).prefix(2), radix: 16) ?? 0) / 255
        let blue = Double(Int(hex.dropFirst(4).prefix(2), radix: 16) ?? 0) / 255
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

// MARK: - Status Presentation Tests

/// Status → label/color mapping (VAL-DASH-005/025): `unknown` has its own
/// treatment, distinct from `idle` and from the empty-fleet state.
final class FleetStatusPresentationTests: XCTestCase {

    func test_allFourStatusesHaveDistinctLabels() {
        let labels = BurnBarFleetAgentStatus.allCases.map {
            FleetStatusPresentation.label(for: $0)
        }
        XCTAssertEqual(Set(labels).count, 4, "all four statuses must be textually distinct")
        XCTAssertEqual(FleetStatusPresentation.label(for: .running), "Running")
        XCTAssertEqual(FleetStatusPresentation.label(for: .idle), "Idle")
        XCTAssertEqual(FleetStatusPresentation.label(for: .stale), "Stale")
        XCTAssertEqual(FleetStatusPresentation.label(for: .unknown), "Unknown")
    }

    func test_unknownStatusIsDistinctFromIdle() {
        // VAL-DASH-025: unknown renders its own treatment — neither idle nor
        // omitted. The label and the color both differ from idle.
        XCTAssertNotEqual(
            FleetStatusPresentation.label(for: .unknown),
            FleetStatusPresentation.label(for: .idle)
        )
        XCTAssertNotEqual(
            FleetStatusPresentation.color(for: .unknown),
            FleetStatusPresentation.color(for: .idle)
        )
    }

    func test_statusColorsMeetUIComponentContrastAgainstSurface() {
        let expected: [BurnBarFleetAgentStatus: (light: String, dark: String)] = [
            .running: ("3A7835", "38D898"),      // success
            .idle: ("9A8B7A", "7A6E62"),         // textMuted
            .stale: ("C47800", "FFA800"),        // warning
            .unknown: ("6B5D4E", "A89A8A")       // textSecondary
        ]
        for (status, pair) in expected {
            XCTAssertGreaterThanOrEqual(
                FleetConfidencePresentationTests.contrastRatio(light: pair.light, dark: pair.dark),
                3.0,
                "\(status) status color must meet the 3:1 UI boundary"
            )
        }
    }
}
