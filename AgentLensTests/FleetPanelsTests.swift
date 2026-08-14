import BurnBarCore
import XCTest

@testable import BurnBar

// MARK: - Repo Grouping Tests

/// Per-repo grouping and collapse behavior (VAL-DASH-010/019): groups match
/// `snapshot.repos`, ungrouped agents land in the explicit "No repo" bucket,
/// collapse/expand toggles membership visibility without losing counts, and
/// collapse state survives snapshot polls with the count badge tracking the
/// latest snapshot.
@MainActor
final class FleetRepoGroupingTests: XCTestCase {

    private var socketURL: URL {
        URL(fileURLWithPath: "/tmp/burnbar-fleet-tests/daemon.sock")
    }

    private func makeViewModel(
        snapshot: BurnBarFleetSnapshot
    ) -> FleetViewModel {
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()
        return viewModel
    }

    func test_repoGroupRowsMatchSnapshotReposInPayloadOrder() {
        // VAL-DASH-010: grouping matches the repos payload, in payload order.
        let snapshot = FleetTestFixtures.makeMultiRepoSnapshot()
        let viewModel = makeViewModel(snapshot: snapshot)

        XCTAssertEqual(viewModel.repoGroupRows.count, snapshot.repos.count)
        XCTAssertEqual(
            viewModel.repoGroupRows.map(\.projectName),
            snapshot.repos.map(\.projectName)
        )
        for (row, group) in zip(viewModel.repoGroupRows, snapshot.repos) {
            XCTAssertEqual(row.agentIDs, group.agents)
            XCTAssertEqual(row.count, group.agents.count)
        }
    }

    func test_ungroupedAgentsAppearUnderNoRepoBucket() {
        // VAL-DASH-010: agents with nil projectName appear under the explicit
        // "No repo" bucket — never dropped, never misgrouped.
        let snapshot = FleetTestFixtures.makeMultiRepoSnapshot(includeUngrouped: true)
        let viewModel = makeViewModel(snapshot: snapshot)

        let noRepo = viewModel.repoGroupRows.first { $0.projectName == FleetViewModel.noRepoBucketName }
        XCTAssertNotNil(noRepo, "ungrouped agents must appear under the No repo bucket")
        XCTAssertEqual(noRepo?.agentIDs, [.grokBot, .kimi])
        XCTAssertEqual(noRepo?.count, 2)
    }

    func test_collapseToggleHidesMembershipWithoutLosingCount() {
        // VAL-DASH-010: collapse/expand toggles membership visibility without
        // losing the count.
        let snapshot = FleetTestFixtures.makeMultiRepoSnapshot()
        let viewModel = makeViewModel(snapshot: snapshot)
        let repoA = snapshot.repos[0].projectName

        XCTAssertFalse(viewModel.repoGroupRows[0].isCollapsed)
        viewModel.toggleRepoCollapse(repoA)
        XCTAssertTrue(viewModel.repoGroupRows[0].isCollapsed)
        XCTAssertEqual(viewModel.repoGroupRows[0].count, 2, "count survives collapse")

        viewModel.toggleRepoCollapse(repoA)
        XCTAssertFalse(viewModel.repoGroupRows[0].isCollapsed, "expand restores membership")
        XCTAssertEqual(viewModel.repoGroupRows[0].count, 2)
    }

    func test_collapseStateSurvivesSnapshotPolls() {
        // VAL-DASH-019: a collapsed group stays collapsed across ≥2 ticks
        // with changing data.
        var current = FleetTestFixtures.makeMultiRepoSnapshot()
        let service = FleetService(socketURL: socketURL) { _ in current }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        let repoA = current.repos[0].projectName
        viewModel.toggleRepoCollapse(repoA)
        XCTAssertTrue(viewModel.repoGroupRows[0].isCollapsed)

        // Tick 1: an agent flips status (extra agent joins repo A).
        current = FleetTestFixtures.makeMultiRepoSnapshot(extraRepoAgent: .pi)
        service.fetchOnce()
        XCTAssertTrue(
            viewModel.repoGroupRows[0].isCollapsed,
            "collapsed group must not re-expand on poll"
        )
        XCTAssertEqual(
            viewModel.repoGroupRows[0].count, 3,
            "count badge must track the latest snapshot while collapsed"
        )

        // Tick 2: another poll with the same data — still collapsed.
        service.fetchOnce()
        XCTAssertTrue(viewModel.repoGroupRows[0].isCollapsed)
        XCTAssertEqual(viewModel.repoGroupRows[0].count, 3)
    }

    func test_collapseStateIsPerRepoNotGlobal() {
        // Collapsing one repo never collapses another (VAL-DASH-010/019).
        let snapshot = FleetTestFixtures.makeMultiRepoSnapshot()
        let viewModel = makeViewModel(snapshot: snapshot)
        let repoA = snapshot.repos[0].projectName
        let repoB = snapshot.repos[1].projectName

        viewModel.toggleRepoCollapse(repoA)
        XCTAssertTrue(viewModel.repoGroupRows[0].isCollapsed)
        XCTAssertFalse(viewModel.repoGroupRows[1].isCollapsed)
        XCTAssertEqual(viewModel.repoGroupRows[1].projectName, repoB)
    }

    func test_noRepoBucketCollapseStateSurvivesPolls() {
        // The No repo bucket is collapsible like any group and its state
        // survives polls (VAL-DASH-019).
        var current = FleetTestFixtures.makeMultiRepoSnapshot(includeUngrouped: true)
        let service = FleetService(socketURL: socketURL) { _ in current }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        viewModel.toggleRepoCollapse(FleetViewModel.noRepoBucketName)
        XCTAssertTrue(
            viewModel.repoGroupRows.last?.isCollapsed ?? false
        )

        current = FleetTestFixtures.makeMultiRepoSnapshot(includeUngrouped: true)
        service.fetchOnce()
        XCTAssertTrue(
            viewModel.repoGroupRows.last?.isCollapsed ?? false,
            "No repo bucket collapse must survive polls"
        )
        XCTAssertEqual(viewModel.repoGroupRows.last?.count, 2)
    }
}

// MARK: - Machine Panel Tests

/// Machine status panel formatting and honest unavailability
/// (VAL-DASH-011/022/030): units, thresholds, edge cases, and per-field
/// absence rendered as explicit unavailable — never 0/NaN/blank.
@MainActor
final class FleetMachinePanelTests: XCTestCase {

    private var socketURL: URL {
        URL(fileURLWithPath: "/tmp/burnbar-fleet-tests/daemon.sock")
    }

    private func makeViewModel(
        machine: BurnBarMachineStatus
    ) -> FleetViewModel {
        let snapshot = FleetTestFixtures.makeSnapshot()
        let service = FleetService(socketURL: socketURL) { _ in
            BurnBarFleetSnapshot(
                schemaVersion: snapshot.schemaVersion,
                generatedAt: snapshot.generatedAt,
                cadenceSeconds: snapshot.cadenceSeconds,
                machine: machine,
                agents: snapshot.agents,
                repos: snapshot.repos,
                runningCount: snapshot.runningCount,
                countsByAgent: snapshot.countsByAgent,
                orchestrator: snapshot.orchestrator,
                probeHealth: snapshot.probeHealth,
                persistenceHealth: snapshot.persistenceHealth
            )
        }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()
        return viewModel
    }

    private func row(_ rows: [FleetMachineRow], _ label: String) -> FleetMachineRow? {
        rows.first { $0.label == label }
    }

    func test_machineRowsFormatUnits() {
        // VAL-DASH-011: CPU %, memory used/total with units, load average
        // (three values), disk free with units — never raw bytes or
        // unitless doubles.
        let viewModel = makeViewModel(machine: FleetTestFixtures.makeMachine())
        let rows = viewModel.machineRows

        XCTAssertEqual(row(rows, "CPU")?.value, "12.5%")
        XCTAssertEqual(row(rows, "Memory")?.value, "8.0 GB / 48.0 GB")
        XCTAssertEqual(row(rows, "Load")?.value, "1.20, 1.00, 0.80")
        XCTAssertEqual(row(rows, "Disk free")?.value, "500.0 GB")
        XCTAssertEqual(row(rows, "Thermal")?.value, "Unavailable (pmset thermlog empty)")
        XCTAssertEqual(row(rows, "Power")?.value, "Unavailable (no cheap power API)")
    }

    func test_machineRowsEdgeCases() {
        // VAL-DASH-022: disk free <1 GB renders MB; load renders all three
        // values locale-stable; memory used/total renders with consistent
        // units.
        let viewModel = makeViewModel(machine: FleetTestFixtures.makeMachineEdgeCase())
        let rows = viewModel.machineRows

        XCTAssertEqual(row(rows, "CPU")?.value, "0.0%")
        XCTAssertEqual(row(rows, "Memory")?.value, "400 MB / 800 MB")
        XCTAssertEqual(row(rows, "Load")?.value, "0.00, 0.50, 1.00")
        XCTAssertEqual(row(rows, "Disk free")?.value, "500 MB")
    }

    func test_optionalMetricsAbsentRenderExplicitUnavailable() {
        // VAL-DASH-030: each absent optional metric renders an explicit
        // unavailable state — never 0, NaN, or a current-looking value.
        let viewModel = makeViewModel(machine: FleetTestFixtures.makeMachineAllOptionalAbsent())
        let rows = viewModel.machineRows

        for label in ["CPU", "Memory", "Load", "Disk free"] {
            let metricRow = row(rows, label)
            XCTAssertNotNil(metricRow, "\(label) row must be present")
            XCTAssertTrue(metricRow?.isUnavailable ?? false, "\(label) must be marked unavailable")
            XCTAssertNil(metricRow?.value, "\(label) must not render a fabricated value")
        }
        // Thermal/power stay typed unavailable with reasons.
        XCTAssertTrue(row(rows, "Thermal")?.isUnavailable ?? false)
        XCTAssertTrue(row(rows, "Power")?.isUnavailable ?? false)
        XCTAssertNotNil(row(rows, "Thermal")?.value)
        XCTAssertNotNil(row(rows, "Power")?.value)
    }

    func test_sensorsAvailableRenderValues() {
        // Available sensors render their numeric values (never unavailable).
        let viewModel = makeViewModel(machine: FleetTestFixtures.makeMachineSensorsAvailable())
        let rows = viewModel.machineRows

        XCTAssertEqual(row(rows, "Thermal")?.value, "68.4")
        XCTAssertEqual(row(rows, "Power")?.value, "12.3")
        XCTAssertFalse(row(rows, "Thermal")?.isUnavailable ?? true)
        XCTAssertFalse(row(rows, "Power")?.isUnavailable ?? true)
    }

    func test_machineRowsAccessibilityLabels() {
        // Every row carries an accessible label; absent metrics say
        // "unavailable" (VAL-DASH-030).
        let viewModel = makeViewModel(machine: FleetTestFixtures.makeMachineAllOptionalAbsent())
        for metricRow in viewModel.machineRows {
            XCTAssertFalse(metricRow.accessibilityLabel.isEmpty)
            if metricRow.isUnavailable {
                XCTAssertTrue(
                    metricRow.accessibilityLabel.contains("unavailable"),
                    "\(metricRow.label) accessibility label must state unavailability"
                )
            }
        }
    }
}

// MARK: - Resource Consumers Tests

/// Resource consumers list (VAL-DASH-012/023): exact per-pid numbers labeled
/// exact, token-burn proxy labeled proxy, deterministic documented ordering.
@MainActor
final class FleetResourceConsumersTests: XCTestCase {

    private var socketURL: URL {
        URL(fileURLWithPath: "/tmp/burnbar-fleet-tests/daemon.sock")
    }

    private func makeViewModel(
        snapshot: BurnBarFleetSnapshot,
        tokenBurn: @escaping (BurnBarFleetAgentID) -> Double? = { _ in nil }
    ) -> FleetViewModel {
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        let viewModel = FleetViewModel(
            service: service,
            tokenBurnProvider: tokenBurn
        )
        service.fetchOnce()
        return viewModel
    }

    func test_exactRowsOnlyForProcessCarryingAgents() {
        // VAL-DASH-012: per-pid CPU/memory rows appear only for agents whose
        // snapshot rows carry process info.
        let snapshot = FleetTestFixtures.makeMultiRepoSnapshot()
        let viewModel = makeViewModel(snapshot: snapshot)

        let exact = viewModel.resourceConsumers.filter { !$0.isProxy }
        XCTAssertEqual(exact.count, 1, "only claude-code carries a process block")
        XCTAssertEqual(exact.first?.agentID, .claudeCode)
        XCTAssertEqual(exact.first?.pid, 19_457)
        XCTAssertEqual(exact.first?.cpuPercent, 3.2)
        XCTAssertEqual(exact.first?.memoryBytes, 1_024_000_000)
        XCTAssertNil(exact.first?.tokensPerMinute)
    }

    func test_proxyRowsLabeledProxyAndNeverExact() {
        // VAL-DASH-012: token-burn-derived estimates are explicitly proxy —
        // never formatted identically to exact numbers without the label.
        let snapshot = FleetTestFixtures.makeMultiRepoSnapshot()
        let viewModel = makeViewModel(snapshot: snapshot) { agentID in
            switch agentID {
            case .codex:
                return 1_234.5
            case .hermes:
                return 500
            default:
                return nil
            }
        }

        let proxy = viewModel.resourceConsumers.filter { $0.isProxy }
        XCTAssertEqual(proxy.count, 2)
        XCTAssertTrue(proxy.allSatisfy { $0.isProxy })
        XCTAssertTrue(proxy.allSatisfy { $0.pid == nil && $0.cpuPercent == nil && $0.memoryBytes == nil })
        XCTAssertEqual(proxy.first { $0.agentID == .codex }?.tokensPerMinute, 1_234.5)
        XCTAssertEqual(proxy.first { $0.agentID == .hermes }?.tokensPerMinute, 500)
    }

    func test_agentsWithProcessInfoNeverGetProxyRows() {
        // An agent with a process block shows exact only — never a proxy row
        // for the same agent (one row per agent, exact wins).
        let snapshot = FleetTestFixtures.makeMultiRepoSnapshot()
        let viewModel = makeViewModel(snapshot: snapshot) { _ in 9_999 }
        let claudeRows = viewModel.resourceConsumers.filter { $0.agentID == .claudeCode }
        XCTAssertEqual(claudeRows.count, 1)
        XCTAssertFalse(claudeRows[0].isProxy)
    }

    func test_orderingDeterministicExactFirstThenProxy() {
        // VAL-DASH-023: documented ordering — exact rows first (CPU desc,
        // ties by pid asc), then proxy rows (tokens/min desc, ties by agent
        // id asc).
        let snapshot = FleetTestFixtures.makeMultiRepoSnapshot()
        let viewModel = makeViewModel(snapshot: snapshot) { agentID in
            switch agentID {
            case .codex:
                return 2_000
            case .hermes:
                return 1_000
            default:
                return nil
            }
        }

        let consumers = viewModel.resourceConsumers
        let exact = consumers.filter { !$0.isProxy }
        let proxy = consumers.filter { $0.isProxy }

        // Exact rows: CPU desc, ties by pid asc.
        let exactCPUs = exact.map { $0.cpuPercent ?? 0 }
        XCTAssertEqual(exactCPUs, exactCPUs.sorted(by: >), "exact rows sorted by CPU desc")
        for (lhs, rhs) in zip(exact, exact.dropFirst()) where lhs.cpuPercent == rhs.cpuPercent {
            XCTAssertLessThan(lhs.pid ?? 0, rhs.pid ?? 0, "ties broken by pid asc")
        }

        // Proxy rows: tokens/min desc, ties by agent id asc.
        let proxyBurns = proxy.map { $0.tokensPerMinute ?? 0 }
        XCTAssertEqual(proxyBurns, proxyBurns.sorted(by: >), "proxy rows sorted by tokens/min desc")
        let proxyIDs = proxy.map(\.agentID.wireValue)
        XCTAssertEqual(proxyIDs, proxyIDs.sorted(), "proxy ties broken by agent id asc")

        // Exact rows always precede proxy rows.
        let firstProxyIndex = consumers.firstIndex(where: \.isProxy)
        if let firstProxyIndex {
            XCTAssertTrue(
                consumers[..<firstProxyIndex].allSatisfy { !$0.isProxy },
                "exact rows must precede proxy rows"
            )
        }
    }

    func test_proxyTieBreakByAgentID() {
        // VAL-DASH-023: equal token-burn values order by agent id asc.
        let snapshot = FleetTestFixtures.makeEmptySnapshot()
        let viewModel = makeViewModel(snapshot: snapshot) { agentID in
            switch agentID {
            case .grokBot, .kimi, .geminiCLI, .pi:
                return 1_000
            default:
                return nil
            }
        }
        let proxy = viewModel.resourceConsumers.filter { $0.isProxy }
        XCTAssertEqual(proxy.map(\.agentID.wireValue), ["grok-bot", "kimi", "pi", "gemini-cli"].sorted())
    }

    func test_identicalPayloadsProduceIdenticalOrdering() {
        // VAL-DASH-023: two identical-payload renders produce identical
        // ordering (stable across identical polls).
        let snapshot = FleetTestFixtures.makeMultiRepoSnapshot()
        let burn: (BurnBarFleetAgentID) -> Double? = { agentID in
            switch agentID {
            case .codex:
                return 2_000
            case .hermes:
                return 1_000
            default:
                return nil
            }
        }
        let first = makeViewModel(snapshot: snapshot, tokenBurn: burn)
        let second = makeViewModel(snapshot: snapshot, tokenBurn: burn)

        XCTAssertEqual(
            first.resourceConsumers.map(\.id),
            second.resourceConsumers.map(\.id)
        )
        XCTAssertEqual(first.resourceConsumers, second.resourceConsumers)
    }

    func test_proxyFormattingHasUnitsAndLabel() {
        // Proxy numbers render with units (tok/min) — never unitless.
        XCTAssertEqual(FleetFormatting.formatTokensPerMinute(1_234.5), "1.2K tok/min")
        XCTAssertEqual(FleetFormatting.formatTokensPerMinute(500), "500 tok/min")
        XCTAssertEqual(FleetFormatting.formatTokensPerMinute(0), "0 tok/min")
        XCTAssertEqual(FleetFormatting.formatTokensPerMinute(1_500_000), "1.5M tok/min")
    }

    func test_emptyConsumersWhenNoProcessAndNoBurn() {
        // No process info and no token-burn data → empty list, honest.
        let snapshot = FleetTestFixtures.makeEmptySnapshot()
        let viewModel = makeViewModel(snapshot: snapshot)
        XCTAssertTrue(viewModel.resourceConsumers.isEmpty)
    }
}

// MARK: - Token Burn Estimator Tests

/// Token-burn proxy estimator (VAL-DASH-012): derives a tokens/minute rate
/// from usage history, returns nil without history, and never fabricates a
/// rate for an unmapped agent.
final class FleetTokenBurnEstimatorTests: XCTestCase {

    private func makeUsage(
        provider: AgentProvider,
        totalTokens: Int,
        startTime: Date
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: UUID().uuidString,
            projectName: "p",
            model: "m",
            inputTokens: totalTokens / 2,
            outputTokens: totalTokens / 2,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(60)
        )
    }

    func test_estimatesRateFromRecentUsage() {
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        let usages = [
            makeUsage(provider: .claudeCode, totalTokens: 1_000, startTime: now.addingTimeInterval(-300)),
            makeUsage(provider: .claudeCode, totalTokens: 2_000, startTime: now.addingTimeInterval(-120))
        ]
        // 3000 tokens over 300s elapsed → 600 tok/min.
        let rate = FleetTokenBurnEstimator.estimateTokensPerMinute(
            usages: usages,
            agentID: .claudeCode,
            now: now
        )
        XCTAssertEqual(rate ?? 0, 600, accuracy: 0.01)
    }

    func test_returnsNilWithoutRecentUsage() {
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        let usages = [
            makeUsage(provider: .claudeCode, totalTokens: 1_000, startTime: now.addingTimeInterval(-3_600))
        ]
        XCTAssertNil(
            FleetTokenBurnEstimator.estimateTokensPerMinute(
                usages: usages,
                agentID: .claudeCode,
                now: now
            )
        )
    }

    func test_returnsNilForUnmappedAgent() {
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        let usages = [
            makeUsage(provider: .claudeCode, totalTokens: 1_000, startTime: now.addingTimeInterval(-120))
        ]
        XCTAssertNil(
            FleetTokenBurnEstimator.estimateTokensPerMinute(
                usages: usages,
                agentID: .unknown("aider"),
                now: now
            )
        )
    }

    func test_returnsNilForOtherProviderRows() {
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        let usages = [
            makeUsage(provider: .codex, totalTokens: 1_000, startTime: now.addingTimeInterval(-120))
        ]
        XCTAssertNil(
            FleetTokenBurnEstimator.estimateTokensPerMinute(
                usages: usages,
                agentID: .claudeCode,
                now: now
            )
        )
    }

    func test_minimumElapsedClampsRate() {
        // A single row written seconds ago must not blow up the rate.
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        let usages = [
            makeUsage(provider: .claudeCode, totalTokens: 1_000, startTime: now.addingTimeInterval(-5))
        ]
        let rate = FleetTokenBurnEstimator.estimateTokensPerMinute(
            usages: usages,
            agentID: .claudeCode,
            now: now
        )
        // 1000 tokens / 60s (clamped) = 1000 tok/min.
        XCTAssertEqual(rate ?? 0, 1_000, accuracy: 0.01)
    }
}

// MARK: - Layout Integrity Tests

/// Adversarial layout fixture assertions (VAL-DASH-020): long names and many
/// agents preserve observable layout integrity. The view-model half asserts
/// the data the layout renders (full names preserved, counts correct,
/// ungrouped bucket present); the desktop-control capture asserts the
/// visual half (no overlap, ellipsis, reachable header/badge).
@MainActor
final class FleetLayoutIntegrityTests: XCTestCase {

    private var socketURL: URL {
        URL(fileURLWithPath: "/tmp/burnbar-fleet-tests/daemon.sock")
    }

    func test_adversarialSnapshotHas20PlusAgentsAndLongNames() {
        let snapshot = FleetTestFixtures.makeAdversarialLayoutSnapshot()
        XCTAssertGreaterThanOrEqual(snapshot.agents.count, 20)
        XCTAssertTrue(
            snapshot.repos.contains { $0.projectName.count >= 120 },
            "fixture must include a 120+ character projectName"
        )
        XCTAssertTrue(
            snapshot.repos.contains { $0.projectName.contains("🚀") },
            "fixture must include a CJK/emoji repo name"
        )
    }

    func test_repoRowsPreserveFullNamesAndCounts() {
        // The view model never truncates data — truncation is a view concern
        // (lineLimit + truncationMode); the full name must be preserved for
        // accessibility and the count must be exact.
        let snapshot = FleetTestFixtures.makeAdversarialLayoutSnapshot()
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        XCTAssertEqual(
            viewModel.repoGroupRows.map(\.projectName),
            snapshot.repos.map(\.projectName) + [FleetViewModel.noRepoBucketName]
        )
        for (row, group) in zip(viewModel.repoGroupRows, snapshot.repos) {
            XCTAssertEqual(row.count, group.agents.count)
        }
        // The No repo bucket holds the 4 ungrouped agents.
        let noRepo = viewModel.repoGroupRows.first { $0.projectName == FleetViewModel.noRepoBucketName }
        XCTAssertEqual(noRepo?.count, 4)
    }

    func test_runningCountHeaderDataSurvivesAdversarialFixture() {
        // The running-count header derives from the snapshot even with 20+
        // agents (reachable header data, VAL-DASH-020).
        let snapshot = FleetTestFixtures.makeAdversarialLayoutSnapshot()
        let service = FleetService(socketURL: socketURL) { _ in snapshot }
        let viewModel = FleetViewModel(service: service)
        service.fetchOnce()

        XCTAssertEqual(viewModel.runningCount, snapshot.runningCount)
        XCTAssertEqual(
            viewModel.runningCount,
            snapshot.agents.filter { $0.status == .running }.count
        )
    }
}
