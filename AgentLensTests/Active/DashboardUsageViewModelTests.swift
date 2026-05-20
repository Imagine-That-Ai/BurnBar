import XCTest
import GRDB
@testable import OpenBurnBar

// MARK: - DashboardUsageViewModelTests

@MainActor
final class DashboardUsageViewModelTests: XCTestCase {

    func test_initialState_isEmpty() {
        let vm = DashboardUsageViewModel()
        XCTAssertEqual(vm.usages.count, 0)
        XCTAssertEqual(vm.totalCostToday, 0)
        XCTAssertEqual(vm.totalCostThisWeek, 0)
        XCTAssertEqual(vm.totalCostThisMonth, 0)
        XCTAssertEqual(vm.totalCostAllTime, 0)
        XCTAssertEqual(vm.totalTokensToday, 0)
        XCTAssertEqual(vm.totalTokensThisWeek, 0)
        XCTAssertEqual(vm.totalTokensThisMonth, 0)
        XCTAssertEqual(vm.totalTokensAllTime, 0)
        XCTAssertEqual(vm.rollingDailyAverage, 0)
        XCTAssertTrue(vm.providerSummaries.isEmpty)
        XCTAssertTrue(vm.modelSummaries.isEmpty)
        XCTAssertTrue(vm.last7DayCosts.allSatisfy { $0 == 0 })
        XCTAssertTrue(vm.last7DayTokenTotals.allSatisfy { $0 == 0 })
    }

    func test_moodBand_withEmptyUsages_isBaseline() {
        let vm = DashboardUsageViewModel()
        XCTAssertEqual(vm.moodBand, .baseline)
    }

    func test_hasEstimatedProviders_withEmptySummaries_isFalse() {
        let vm = DashboardUsageViewModel()
        XCTAssertFalse(vm.hasEstimatedProviders)
    }

    func test_providerSummaries_inDateRange_withEmptyUsages_isEmpty() {
        let vm = DashboardUsageViewModel()
        XCTAssertTrue(vm.providerSummaries(in: nil).isEmpty)
    }

    func test_modelSummaries_inDateRange_withEmptyUsages_isEmpty() {
        let vm = DashboardUsageViewModel()
        XCTAssertTrue(vm.modelSummaries(in: nil).isEmpty)
    }

    func test_topProviderToday_withEmptyUsages_isNil() {
        let vm = DashboardUsageViewModel()
        XCTAssertNil(vm.topProviderToday())
    }

    func test_dashboardUsageRanking_tokensModeRanksProvidersByTokens() {
        let expensiveLowVolume = makeProviderSummary(provider: .kimi, cost: 100, tokens: 100)
        let cheapHighVolume = makeProviderSummary(provider: .codex, cost: 1, tokens: 1_000)

        let tokenRanked = DashboardUsageRanking.sortedProviders(
            [expensiveLowVolume, cheapHighVolume],
            displayMode: .tokens
        )
        let currencyRanked = DashboardUsageRanking.sortedProviders(
            [expensiveLowVolume, cheapHighVolume],
            displayMode: .currency
        )

        XCTAssertEqual(tokenRanked.map(\.provider), [.codex, .kimi])
        XCTAssertEqual(currencyRanked.map(\.provider), [.kimi, .codex])
    }

    func test_dashboardUsageRanking_tokensModeRanksModelsAndPercentagesByTokens() {
        let highCostLowVolume = makeModelUsage(modelName: "premium-model", cost: 90, tokens: 100)
        let lowCostHighVolume = makeModelUsage(modelName: "bulk-model", cost: 10, tokens: 900)
        let summary = makeProviderSummary(
            provider: .factory,
            cost: 100,
            tokens: 1_000,
            modelBreakdown: [highCostLowVolume, lowCostHighVolume]
        )

        let tokenRanked = DashboardUsageRanking.sortedModelUsages(
            summary.modelBreakdown,
            displayMode: .tokens
        )
        let tokenShare = DashboardUsageRanking.modelUsagePercentage(
            lowCostHighVolume,
            in: summary,
            displayMode: .tokens
        )
        let currencyShare = DashboardUsageRanking.modelUsagePercentage(
            lowCostHighVolume,
            in: summary,
            displayMode: .currency
        )

        XCTAssertEqual(tokenRanked.map(\.modelName), ["bulk-model", "premium-model"])
        XCTAssertEqual(tokenShare, 90, accuracy: 0.001)
        XCTAssertEqual(currencyShare, 10, accuracy: 0.001)
    }

    func test_windowSummary_reusesFilteredTotalsAndSummaries() {
        let vm = DashboardUsageViewModel()
        let now = Date()
        let inWindow = ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "codex-window",
            model: "gpt-5",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 2,
            startTime: now,
            endTime: now.addingTimeInterval(60)
        )
        let secondInWindow = ViewTestFixtures.makeUsage(
            provider: .kimi,
            sessionId: "kimi-window",
            model: "kimi-for-coding",
            inputTokens: 20,
            outputTokens: 10,
            costUSD: 1,
            startTime: now.addingTimeInterval(-60),
            endTime: now
        )
        let outOfWindow = ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "factory-old",
            model: "droid",
            inputTokens: 500,
            outputTokens: 500,
            costUSD: 10,
            startTime: now.addingTimeInterval(-86_400),
            endTime: now.addingTimeInterval(-86_300)
        )

        vm.replaceUsages([outOfWindow, inWindow, secondInWindow])

        let summary = vm.windowSummary(in: now.addingTimeInterval(-120)...now.addingTimeInterval(120))
        XCTAssertEqual(summary.usages.map(\.sessionId), ["codex-window", "kimi-window"])
        XCTAssertEqual(summary.totalCost, 3, accuracy: 0.001)
        XCTAssertEqual(summary.totalTokens, 180)
        XCTAssertEqual(summary.activeProviderCount, 2)
        XCTAssertEqual(Set(summary.providerSummaries.map(\.provider)), [.codex, .kimi])
        XCTAssertEqual(Set(summary.modelSummaries.map(\.modelName)), ["gpt-5", "kimi-for-coding"])
    }

    func test_dashboardSnapshotTodayUsesLocalSQLiteDateWindow() throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let earlyToday = todayStart.addingTimeInterval(60 * 60)
        let yesterday = todayStart.addingTimeInterval(-60 * 60)

        try usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "dashboard-local-today",
            model: "gpt-5",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 2,
            startTime: earlyToday,
            endTime: earlyToday.addingTimeInterval(60)
        ))
        try usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "dashboard-local-yesterday",
            model: "droid",
            inputTokens: 1_000,
            outputTokens: 1_000,
            costUSD: 20,
            startTime: yesterday,
            endTime: yesterday.addingTimeInterval(60)
        ))

        let snapshot = try usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
        let today = try XCTUnwrap(snapshot.windowSummaries[.today])

        XCTAssertEqual(today.sessionCount, 1)
        XCTAssertEqual(today.totalCost, 2, accuracy: 0.001)
        XCTAssertEqual(today.totalTokens, 150)
        XCTAssertEqual(today.providerSummaries.map(\.provider), [.codex])
    }

    func test_sqliteDateStringFormatsLocalWallTimeForDashboardWindows() {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let rendered = OpenBurnBarDatabase.sqliteDateString(startOfToday)

        XCTAssertTrue(rendered.hasSuffix("00:00:00.000"))
    }

    func test_makeProviderSummaries_groupsProvidersAndModelsInOneDerivedSnapshot() throws {
        let usages = [
            ViewTestFixtures.makeUsage(
                provider: .codex,
                sessionId: "codex-a",
                model: "gpt-5",
                inputTokens: 100,
                outputTokens: 50,
                costUSD: 2
            ),
            ViewTestFixtures.makeUsage(
                provider: .codex,
                sessionId: "codex-b",
                model: "gpt-5-mini",
                inputTokens: 75,
                outputTokens: 25,
                costUSD: 1
            ),
            ViewTestFixtures.makeUsage(
                provider: .kimi,
                sessionId: "kimi-a",
                model: "kimi-for-coding",
                inputTokens: 10,
                outputTokens: 10,
                costUSD: 0.25
            )
        ]

        let summaries = DashboardUsageViewModel.makeProviderSummaries(from: usages)
        let codex = try XCTUnwrap(summaries.first { $0.provider == .codex })

        XCTAssertEqual(summaries.map(\.provider).first, .codex)
        XCTAssertEqual(codex.totalCost, 3, accuracy: 0.001)
        XCTAssertEqual(codex.totalTokens, 250)
        XCTAssertEqual(codex.sessionCount, 2)
        XCTAssertEqual(codex.modelBreakdown.map(\.modelName), ["gpt-5", "gpt-5-mini"])
    }

    private func makeProviderSummary(
        provider: AgentProvider,
        cost: Double,
        tokens: Int,
        modelBreakdown: [ModelUsage] = []
    ) -> ProviderSummary {
        ProviderSummary(
            provider: provider,
            totalCost: cost,
            totalTokens: tokens,
            totalInputTokens: tokens,
            totalOutputTokens: 0,
            sessionCount: 1,
            modelBreakdown: modelBreakdown,
            provenanceConfidence: .exact,
            provenanceMethod: .providerLog,
            hasEstimatedContributions: false,
            cacheEfficiency: .zero
        )
    }

    private func makeModelUsage(modelName: String, cost: Double, tokens: Int) -> ModelUsage {
        ModelUsage(
            modelName: modelName,
            inputTokens: tokens,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            totalTokens: tokens,
            cost: cost,
            percentage: cost,
            provenanceConfidence: .exact,
            provenanceMethod: .providerLog,
            hasEstimatedContributions: false
        )
    }
}
