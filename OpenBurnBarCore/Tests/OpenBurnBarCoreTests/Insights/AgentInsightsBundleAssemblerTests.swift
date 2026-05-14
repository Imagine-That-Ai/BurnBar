import XCTest
@testable import OpenBurnBarCore

final class AgentInsightsBundleAssemblerTests: XCTestCase {

    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func interval(daysBack: Int) -> DateInterval {
        let end = now
        let start = now.addingTimeInterval(-Double(daysBack) * 86_400)
        return DateInterval(start: start, end: end)
    }

    private func usage(
        provider: AgentProvider,
        model: String,
        sessionID: String,
        endingDaysAgo: Double,
        cost: Double,
        tokens: Int
    ) -> InsightUsageRow {
        let end = now.addingTimeInterval(-endingDaysAgo * 86_400)
        return InsightUsageRow(
            sessionID: sessionID,
            provider: provider.rawValue,
            model: model,
            startTime: end.addingTimeInterval(-3600),
            endTime: end,
            totalTokens: tokens,
            costUSD: cost
        )
    }

    private func snapshot(_ usages: [InsightUsageRow]) -> InsightDataSnapshot {
        InsightDataSnapshot(window: interval(daysBack: 7), generatedAt: now, usages: usages)
    }

    private func emptyAnalysis(provider: AgentProvider) -> InsightAnalysisResult {
        InsightAnalysisResult(
            requestID: UUID(),
            platform: .iOS,
            timeWindow: .last7d,
            executiveSummary: "Test brief for \(provider.displayName)",
            modelTag: InsightModelTag(
                providerKey: "local-rules",
                modelID: "local-rules-v1",
                displayName: "Local rules",
                egressTier: .localOnly
            ),
            contextBudget: InsightContextBudgetReport(
                encodedBytes: 0,
                estimatedPromptTokens: 0,
                includedDataSources: []
            ),
            findings: [],
            anomalies: [],
            recommendations: [],
            missionCandidates: [],
            generatedWidgets: [],
            followUpQuestions: [],
            citations: []
        )
    }

    private func mission(
        title: String,
        priority: InsightMissionCandidate.Priority
    ) -> InsightMissionCandidate {
        InsightMissionCandidate(
            title: title,
            summary: "summary",
            lens: .accretion,
            priority: priority,
            confidence: .high,
            expectedImpact: "—",
            effort: .small,
            acceptanceCriteria: ["ship it"],
            evidence: []
        )
    }

    private func canvas(
        title: String,
        providers: Set<String>,
        sortIndex: Int = 0,
        updatedAt: Date? = nil
    ) -> InsightCanvas {
        InsightCanvas(
            title: title,
            filter: InsightFilter(window: .last7d, providers: providers),
            createdAt: now,
            updatedAt: updatedAt ?? now,
            sortIndex: sortIndex
        )
    }

    // MARK: - Header tests

    func testAggregateHeaderTitleIsAllAgents() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .aggregate,
            snapshot: snapshot([]),
            now: now
        )
        XCTAssertEqual(bundle.header.title, "All agents")
        XCTAssertNil(bundle.header.provider)
        XCTAssertEqual(bundle.header.symbolName, "rectangle.stack.fill")
    }

    func testAgentHeaderTitleIsProviderDisplayName() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([]),
            now: now
        )
        XCTAssertEqual(bundle.header.title, "Codex")
        XCTAssertEqual(bundle.header.provider, .codex)
        XCTAssertEqual(bundle.header.symbolName, AgentProvider.codex.iconName)
    }

    func testHeaderStatusActiveWhenLastUsageWithin24h() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([usage(provider: .codex, model: "gpt-5", sessionID: "s1",
                                     endingDaysAgo: 0.2, cost: 1.0, tokens: 1_000)]),
            now: now
        )
        XCTAssertEqual(bundle.header.status, .active)
    }

    func testHeaderStatusIdleWhenLastUsageWithin7Days() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([usage(provider: .codex, model: "gpt-5", sessionID: "s1",
                                     endingDaysAgo: 3, cost: 1.0, tokens: 1_000)]),
            now: now
        )
        XCTAssertEqual(bundle.header.status, .idle)
    }

    func testHeaderStatusDormantWhenLastUsageOlderThan7Days() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([usage(provider: .codex, model: "gpt-5", sessionID: "s1",
                                     endingDaysAgo: 14, cost: 1.0, tokens: 1_000)]),
            now: now
        )
        XCTAssertEqual(bundle.header.status, .dormant)
    }

    func testHeaderStatusUnconfiguredWhenNoData() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([]),
            now: now
        )
        XCTAssertEqual(bundle.header.status, .unconfigured)
    }

    func testHeaderModelLineupRanksByTokenVolume() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([
                usage(provider: .codex, model: "gpt-5",   sessionID: "s1", endingDaysAgo: 0.2, cost: 0, tokens: 5_000),
                usage(provider: .codex, model: "gpt-mini", sessionID: "s2", endingDaysAgo: 0.2, cost: 0, tokens: 1_000),
                usage(provider: .codex, model: "gpt-pro",  sessionID: "s3", endingDaysAgo: 0.2, cost: 0, tokens: 3_000)
            ]),
            now: now
        )
        XCTAssertEqual(bundle.header.modelLineup, ["gpt-5", "gpt-pro", "gpt-mini"])
    }

    // MARK: - KPI tests

    func testKPIsFilterByProviderInScope() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([
                usage(provider: .codex,      model: "x", sessionID: "a", endingDaysAgo: 1, cost: 10, tokens: 1_000),
                usage(provider: .claudeCode, model: "y", sessionID: "b", endingDaysAgo: 1, cost: 99, tokens: 99_000)
            ]),
            now: now
        )
        XCTAssertEqual(bundle.kpis.spend.raw, 10, accuracy: 0.0001)
        XCTAssertEqual(bundle.kpis.tokens.raw, 1_000)
        XCTAssertEqual(bundle.kpis.sessions.raw, 1)
    }

    func testKPIsAggregateAcrossAllProvidersWhenAggregate() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .aggregate,
            snapshot: snapshot([
                usage(provider: .codex,      model: "x", sessionID: "a", endingDaysAgo: 1, cost: 10, tokens: 1_000),
                usage(provider: .claudeCode, model: "y", sessionID: "b", endingDaysAgo: 1, cost: 5,  tokens: 2_000)
            ]),
            now: now
        )
        XCTAssertEqual(bundle.kpis.spend.raw, 15, accuracy: 0.0001)
        XCTAssertEqual(bundle.kpis.tokens.raw, 3_000)
        XCTAssertEqual(bundle.kpis.sessions.raw, 2)
    }

    func testKPIsTrendUpWhenPreviousLower() {
        let curr = snapshot([usage(provider: .codex, model: "x", sessionID: "a",
                                   endingDaysAgo: 1, cost: 20, tokens: 2_000)])
        let prev = snapshot([usage(provider: .codex, model: "x", sessionID: "p1",
                                   endingDaysAgo: 10, cost: 10, tokens: 1_000)])
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: curr,
            previousWindowSnapshot: prev,
            now: now
        )
        XCTAssertEqual(bundle.kpis.spend.trendDirection, .up)
        XCTAssertNotNil(bundle.kpis.spend.trendText)
    }

    func testKPIsTrendDownWhenPreviousHigher() {
        let curr = snapshot([usage(provider: .codex, model: "x", sessionID: "a",
                                   endingDaysAgo: 1, cost: 5, tokens: 500)])
        let prev = snapshot([usage(provider: .codex, model: "x", sessionID: "p1",
                                   endingDaysAgo: 10, cost: 20, tokens: 2_000)])
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: curr,
            previousWindowSnapshot: prev,
            now: now
        )
        XCTAssertEqual(bundle.kpis.spend.trendDirection, .down)
    }

    func testKPIsTrendNewActivityWhenPreviousZero() {
        let curr = snapshot([usage(provider: .codex, model: "x", sessionID: "a",
                                   endingDaysAgo: 1, cost: 5, tokens: 500)])
        let prev = snapshot([])
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: curr,
            previousWindowSnapshot: prev,
            now: now
        )
        XCTAssertEqual(bundle.kpis.spend.trendDirection, .flat)
        XCTAssertEqual(bundle.kpis.spend.trendText, "New activity")
    }

    // MARK: - Canvas tests

    func testCanvasesFilteredByProviderToken() {
        let codexCanvas = canvas(title: "Codex spend", providers: ["Codex"])
        let claudeCanvas = canvas(title: "Claude spend", providers: ["Claude Code"])
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([]),
            canvases: [codexCanvas, claudeCanvas],
            now: now
        )
        XCTAssertEqual(bundle.canvases.map(\.title), ["Codex spend"])
    }

    func testCanvasesFallbackToSharedWhenNoneScoped() {
        let shared = canvas(title: "Shared", providers: [])
        let codexCanvas = canvas(title: "Codex", providers: ["Codex"])
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.claudeCode),  // no Claude-scoped canvas
            snapshot: snapshot([]),
            canvases: [shared, codexCanvas],
            now: now
        )
        XCTAssertEqual(bundle.canvases.map(\.title), ["Shared"])
    }

    func testAggregateScopeSurfacesEveryCanvas() {
        let a = canvas(title: "A", providers: ["Codex"], sortIndex: 1)
        let b = canvas(title: "B", providers: [], sortIndex: 0)
        let c = canvas(title: "C", providers: ["Claude Code"], sortIndex: 2)
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .aggregate,
            snapshot: snapshot([]),
            canvases: [a, b, c],
            now: now
        )
        // Sorted by sortIndex ascending.
        XCTAssertEqual(bundle.canvases.map(\.title), ["B", "A", "C"])
    }

    // MARK: - Mission ranking

    func testMissionsRankedCriticalFirstLowLast() {
        var analysis = emptyAnalysis(provider: .codex)
        analysis.missionCandidates = [
            mission(title: "low",      priority: .low),
            mission(title: "high",     priority: .high),
            mission(title: "critical", priority: .critical),
            mission(title: "medium",   priority: .medium)
        ]
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([]),
            analysis: analysis,
            now: now
        )
        XCTAssertEqual(bundle.missions.map(\.title), ["critical", "high", "medium", "low"])
    }

    // MARK: - Empty / bundle invariants

    func testBundleIsEmptyWhenNoSignals() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([]),
            now: now
        )
        XCTAssertTrue(bundle.isEmpty)
    }

    func testBundleIsNotEmptyWhenAnalysisPresent() {
        let bundle = AgentInsightsBundleAssembler.assemble(
            scope: .agent(.codex),
            snapshot: snapshot([]),
            analysis: emptyAnalysis(provider: .codex),
            now: now
        )
        XCTAssertFalse(bundle.isEmpty)
    }

    // MARK: - Coverage: every agent assembles successfully

    func testEveryAgentProviderAssemblesABundle() {
        for provider in AgentProvider.allCases {
            let usages = [
                usage(provider: provider, model: "model-a", sessionID: "s-\(provider.rawValue)-1",
                      endingDaysAgo: 0.5, cost: 2.5, tokens: 2_500)
            ]
            let bundle = AgentInsightsBundleAssembler.assemble(
                scope: .agent(provider),
                snapshot: snapshot(usages),
                now: now
            )
            XCTAssertEqual(bundle.scope.provider, provider, "Bundle scope must match for \(provider.rawValue)")
            XCTAssertEqual(bundle.header.title, provider.displayName, "Header title for \(provider.rawValue)")
            XCTAssertEqual(bundle.header.status, .active, "Status for \(provider.rawValue) with fresh usage")
            XCTAssertEqual(bundle.kpis.sessions.raw, 1, "Session count for \(provider.rawValue)")
            XCTAssertEqual(bundle.kpis.spend.raw, 2.5, accuracy: 0.0001, "Spend for \(provider.rawValue)")
            XCTAssertEqual(bundle.kpis.tokens.raw, 2_500, "Tokens for \(provider.rawValue)")
            XCTAssertEqual(bundle.kpis.ordered.count, 4, "Four KPIs always for \(provider.rawValue)")
        }
    }
}
