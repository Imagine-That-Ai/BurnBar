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

    func test_dashboardUsageRanking_treatsNonFiniteCostsAsZero() {
        let finite = makeProviderSummary(provider: .codex, cost: 2, tokens: 100)
        let malformed = makeProviderSummary(provider: .kimi, cost: .nan, tokens: 10_000)

        let currencyRanked = DashboardUsageRanking.sortedProviders(
            [malformed, finite],
            displayMode: .currency
        )

        XCTAssertEqual(currencyRanked.map(\.provider), [.codex, .kimi])

        let malformedModel = makeModelUsage(modelName: "malformed", cost: .infinity, tokens: 100)
        let finiteModel = makeModelUsage(modelName: "finite", cost: 2, tokens: 100)
        let summary = makeProviderSummary(
            provider: .factory,
            cost: 2,
            tokens: 200,
            modelBreakdown: [malformedModel, finiteModel]
        )

        XCTAssertEqual(
            DashboardUsageRanking.modelUsagePercentage(malformedModel, in: summary, displayMode: .currency),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardUsageRanking.modelUsagePercentage(finiteModel, in: summary, displayMode: .currency),
            100,
            accuracy: 0.001
        )
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

    func test_dashboardSnapshotTodayUsesLocalSQLiteDateWindow() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let earlyToday = todayStart.addingTimeInterval(60 * 60)
        let yesterday = todayStart.addingTimeInterval(-60 * 60)

        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "dashboard-local-today",
            model: "gpt-5",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 2,
            startTime: earlyToday,
            endTime: earlyToday.addingTimeInterval(60)
        ))
        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "dashboard-local-yesterday",
            model: "droid",
            inputTokens: 1_000,
            outputTokens: 1_000,
            costUSD: 20,
            startTime: yesterday,
            endTime: yesterday.addingTimeInterval(60)
        ))

        let snapshot = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
        let today = try XCTUnwrap(snapshot.windowSummaries[.today])

        XCTAssertEqual(today.sessionCount, 1)
        XCTAssertEqual(today.totalCost, 2, accuracy: 0.001)
        XCTAssertEqual(today.totalTokens, 150)
        XCTAssertEqual(today.providerSummaries.map(\.provider), [.codex])
    }

    func test_usageTotals_fetchesOnlyScalarTotalsForAnArbitraryWindow() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()

        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "comparison-current",
            model: "gpt-5",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: 2,
            startTime: now,
            endTime: now.addingTimeInterval(60)
        ))
        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "comparison-previous",
            model: "gpt-5",
            inputTokens: 40,
            outputTokens: 10,
            costUSD: 1,
            startTime: now.addingTimeInterval(-86_400),
            endTime: now.addingTimeInterval(-86_340)
        ))

        let previousTotals = try await usageStore.fetchUsageTotals(
            in: now.addingTimeInterval(-86_460)...now.addingTimeInterval(-86_300)
        )

        XCTAssertEqual(previousTotals.sessionCount, 1)
        XCTAssertEqual(previousTotals.tokens, 50)
        XCTAssertEqual(previousTotals.cost, 1, accuracy: 0.001)
    }

    func test_dashboardSnapshotSplitsModelUsageByExecutionSource() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()

        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "codex-cli-source",
            model: "gpt-5.6-codex",
            inputTokens: 100,
            outputTokens: 20,
            costUSD: 1.25,
            startTime: now,
            endTime: now.addingTimeInterval(30),
            executionSourceID: "codex-cli",
            executionSourceName: "Codex CLI",
            executionSourceKind: .cli,
            executionSourceConfidence: .exact
        ))
        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "codex-desktop-source",
            model: "gpt-5.6-codex",
            inputTokens: 60,
            outputTokens: 20,
            costUSD: 0.75,
            startTime: now,
            endTime: now.addingTimeInterval(30),
            executionSourceID: "codex-desktop",
            executionSourceName: "Codex Desktop",
            executionSourceKind: .desktopApp,
            executionSourceConfidence: .exact
        ))

        let snapshot = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
        let today = try XCTUnwrap(snapshot.windowSummaries[.today])
        let model = try XCTUnwrap(today.modelSummaries.first { $0.modelName == "gpt-5.6-codex" })

        XCTAssertEqual(model.totalTokens, 200)
        XCTAssertEqual(model.totalCost, 2, accuracy: 0.001)
        XCTAssertEqual(model.executionSourceBreakdown.map(\.executionSourceID), ["codex-cli", "codex-desktop"])
        XCTAssertEqual(model.executionSourceBreakdown.map(\.totalTokens), [120, 80])
    }

    func test_dashboardSnapshotQueryCount_isIndependentOfRowCount() async throws {
        let queue = try DatabaseQueue(configuration: .withQueryTracing())
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let tracer = OpenBurnBarQueryTracer.shared
        let now = Date()

        func insertUsages(count: Int, idPrefix: String) async throws {
            for index in 0..<count {
                let start = now.addingTimeInterval(Double(-index) * 3_600)
                try await usageStore.insert(ViewTestFixtures.makeUsage(
                    provider: .codex,
                    sessionId: "\(idPrefix)-\(index)",
                    model: "gpt-5",
                    inputTokens: 100,
                    outputTokens: 50,
                    costUSD: 1,
                    startTime: start,
                    endTime: start.addingTimeInterval(60)
                ))
            }
        }

        try await insertUsages(count: 6, idPrefix: "tracer-baseline")
        // Warm-up absorbs GRDB's one-time schema introspection statements.
        _ = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)

        tracer.resetLog()
        _ = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
        let baseline = tracer.queryLog.count { event in
            event.sql.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("select")
        }
        XCTAssertGreaterThan(baseline, 0, "Query tracer recorded nothing — tracing is not installed")

        try await insertUsages(count: 40, idPrefix: "tracer-scaled")
        tracer.resetLog()
        _ = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
        let scaled = tracer.queryLog.count { event in
            event.sql.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("select")
        }

        XCTAssertEqual(
            scaled,
            baseline,
            "Dashboard snapshot must run a constant number of data queries — growth with row count is an N+1 regression"
        )
        tracer.assertMaxQueries(count: 12)
    }

    func test_dashboardSnapshot_usesOneCoveringScanAndFiltersWindowsInMemory() async throws {
        let queue = try DatabaseQueue(configuration: .withQueryTracing())
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let tracer = OpenBurnBarQueryTracer.shared
        // Keep insertion, SQL windows, and in-memory windows on one
        // millisecond-exact clock. GRDB persists Date values with millisecond
        // precision, so a live sub-millisecond boundary can round past an
        // independently captured upper bound.
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "covering-today",
            model: "gpt-5",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 1,
            startTime: now,
            endTime: now.addingTimeInterval(30)
        ))
        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .claudeCode,
            sessionId: "covering-week-ago",
            model: "sonnet",
            inputTokens: 20,
            outputTokens: 10,
            costUSD: 2,
            startTime: now.addingTimeInterval(-8 * 24 * 3600),
            endTime: now.addingTimeInterval(-8 * 24 * 3600 + 30)
        ))

        _ = try await usageStore.fetchDashboardUsageSnapshot(
            loadedUsageLimit: 100,
            now: now
        )
        tracer.resetLog()
        let snapshot = try await usageStore.fetchDashboardUsageSnapshot(
            loadedUsageLimit: 100,
            now: now
        )

        let coveringSelects = tracer.queryLog.filter { event in
            let sql = event.sql
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return sql.contains("from token_usage")
                && sql.contains("order by starttime desc limit")
                && !sql.contains("group by")
        }
        XCTAssertEqual(
            coveringSelects.count,
            1,
            "Dashboard snapshot must decode covering rows once, not once per TimeRange"
        )
        XCTAssertFalse(
            coveringSelects.contains { $0.sql.lowercased().contains("select * from token_usage") },
            "Covering scan must name decodeUsage columns instead of SELECT *"
        )
        XCTAssertTrue(
            coveringSelects.contains { event in
                let sql = event.sql.lowercased()
                return sql.contains("billingkind") && sql.contains("parentrequestid")
            },
            "Covering scan must include decodeUsage identity columns"
        )

        let todayRange = try XCTUnwrap(TimeRange.today.dateRange(now: now))
        let today = try XCTUnwrap(snapshot.windowSummaries[.today])
        XCTAssertEqual(today.usages.map(\.sessionId), ["covering-today"])
        XCTAssertEqual(
            snapshot.loadedUsages.filter { $0.intersects(dateRange: todayRange) }.map(\.sessionId),
            today.usages.map(\.sessionId)
        )
        XCTAssertEqual(Set(snapshot.loadedUsages.map(\.sessionId)), [
            "covering-today",
            "covering-week-ago"
        ])
    }

    func test_dashboardSnapshot_credentialAndProjectSummariesIncludeLongRunnerOutsideCoveringLimit() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        let longStart = now.addingTimeInterval(-45 * 86_400)

        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "long-runner",
            projectName: "marathon",
            model: "test-model",
            inputTokens: 50_000,
            outputTokens: 25_000,
            costUSD: 12.5,
            startTime: longStart,
            endTime: now,
            providerAccountID: "acct-long",
            providerAccountLabel: "Factory · long"
        ))
        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "recent",
            projectName: "today-proj",
            model: "gpt-5",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 1,
            startTime: now,
            endTime: now.addingTimeInterval(30)
        ))

        let snapshot = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 1)
        let today = try XCTUnwrap(snapshot.windowSummaries[.today])
        XCTAssertEqual(today.usages.map(\.sessionId), ["recent"])
        XCTAssertFalse(today.usages.contains { $0.sessionId == "long-runner" })

        let marathon = try XCTUnwrap(today.projectSpendSummaries.first { $0.projectName == "marathon" })
        XCTAssertEqual(marathon.sessionCount, 1)
        XCTAssertEqual(marathon.totalCost, 12.5, accuracy: 0.0001)
        XCTAssertEqual(marathon.totalTokens, 75_000)

        let accountID = try XCTUnwrap(
            TokenUsage.providerAccountIdentityPartition(from: "acct-long")
        )
        let longCred = try XCTUnwrap(
            today.credentialSummaries.first { $0.stableKey == "Factory#\(accountID)" }
        )
        XCTAssertEqual(longCred.sessionCount, 1)
        XCTAssertEqual(longCred.totalCost, 12.5, accuracy: 0.0001)
        XCTAssertEqual(longCred.totalTokens, 75_000)
        XCTAssertEqual(longCred.accountLabel, "Factory · long")
    }

    func test_dashboardSnapshot_credentialSummaryUsesNewestAccountMetadata() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()
        let older = TokenUsage(
            provider: .factory,
            sessionId: "before-rename",
            projectName: "alpha",
            model: "test-model",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 1,
            startTime: now.addingTimeInterval(-3600),
            endTime: now.addingTimeInterval(-3500),
            providerAccountID: "renamed-account",
            providerAccountLabel: "Old account",
            providerAccountSource: .localOnly
        )
        let newer = TokenUsage(
            provider: .factory,
            sessionId: "after-rename",
            projectName: "alpha",
            model: "test-model",
            inputTokens: 20,
            outputTokens: 10,
            costUSD: 2,
            startTime: now,
            endTime: now.addingTimeInterval(100),
            providerAccountID: "renamed-account",
            providerAccountLabel: "Current account",
            providerAccountSource: .deviceKeychain
        )
        try await usageStore.insert([older, newer])

        let snapshot = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
        let allTime = try XCTUnwrap(snapshot.windowSummaries[.allTime])
        let aggregateSummary = try XCTUnwrap(allTime.credentialSummaries.first)
        XCTAssertEqual(aggregateSummary.accountLabel, "Current account")
        XCTAssertEqual(aggregateSummary.accountSource, .deviceKeychain)

        let inMemorySummary = try XCTUnwrap(
            UsageStore.makeCredentialSummaries(from: [older, newer]).first
        )
        XCTAssertEqual(inMemorySummary.accountLabel, aggregateSummary.accountLabel)
        XCTAssertEqual(inMemorySummary.accountSource, aggregateSummary.accountSource)
    }

    func test_credentialSummary_equalStartTimeUsesLexicalMetadataTieBreakRegardlessOfOrder() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let alphaLabel = TokenUsage(
            provider: .factory,
            sessionId: "alpha-label",
            projectName: "alpha",
            model: "test-model",
            inputTokens: 10,
            outputTokens: 5,
            costUSD: 1,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            providerAccountID: "shared-account",
            providerAccountLabel: "Alpha account",
            providerAccountSource: .localOnly
        )
        let deviceSource = TokenUsage(
            provider: .factory,
            sessionId: "device-source",
            projectName: "alpha",
            model: "test-model",
            inputTokens: 20,
            outputTokens: 10,
            costUSD: 2,
            startTime: start,
            endTime: start.addingTimeInterval(60),
            providerAccountID: "shared-account",
            providerAccountLabel: "Zulu account",
            providerAccountSource: .deviceKeychain
        )

        for usages in [[alphaLabel, deviceSource], [deviceSource, alphaLabel]] {
            let queue = try DatabaseQueue()
            _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
            let usageStore = UsageStore(dbQueue: queue)
            try await usageStore.insert(usages)

            let snapshot = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
            let allTime = try XCTUnwrap(snapshot.windowSummaries[.allTime])
            let aggregateSummary = try XCTUnwrap(allTime.credentialSummaries.first)
            let inMemorySummary = try XCTUnwrap(
                UsageStore.makeCredentialSummaries(from: usages).first
            )

            XCTAssertEqual(aggregateSummary.accountLabel, "Alpha account")
            XCTAssertEqual(aggregateSummary.accountSource, .deviceKeychain)
            XCTAssertEqual(inMemorySummary.accountLabel, aggregateSummary.accountLabel)
            XCTAssertEqual(inMemorySummary.accountSource, aggregateSummary.accountSource)
        }
    }

    func test_dashboardSnapshot_credentialAndProjectSummariesMatchTokenUsageFoldWhenCoveringIsComplete() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()

        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "a",
            projectName: "alpha",
            costUSD: 3,
            startTime: now.addingTimeInterval(-120),
            endTime: now.addingTimeInterval(-60),
            providerAccountID: "acct-a",
            providerAccountLabel: "Key A"
        ))
        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .factory,
            sessionId: "b",
            projectName: "",
            costUSD: 1,
            startTime: now.addingTimeInterval(-30),
            endTime: now,
            providerAccountID: nil
        ))

        let snapshot = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
        let allTime = try XCTUnwrap(snapshot.windowSummaries[.allTime])
        let fromUsages = UsageStore.makeCredentialSummaries(from: snapshot.loadedUsages)
        XCTAssertEqual(
            Set(allTime.credentialSummaries.map(\.stableKey)),
            Set(fromUsages.map(\.stableKey))
        )
        for expected in fromUsages {
            let actual = try XCTUnwrap(allTime.credentialSummaries.first { $0.stableKey == expected.stableKey })
            XCTAssertEqual(actual.totalCost, expected.totalCost, accuracy: 0.0001, expected.stableKey)
            XCTAssertEqual(actual.totalTokens, expected.totalTokens, expected.stableKey)
            XCTAssertEqual(actual.sessionCount, expected.sessionCount, expected.stableKey)
            XCTAssertEqual(actual.accountLabel, expected.accountLabel, expected.stableKey)
        }

        let fromUsageProjects = UsageStore.makeProjectSpendSummaries(from: snapshot.loadedUsages)
        XCTAssertEqual(
            Set(allTime.projectSpendSummaries.map(\.projectName)),
            Set(fromUsageProjects.map(\.projectName))
        )
        for expected in fromUsageProjects {
            let actual = try XCTUnwrap(
                allTime.projectSpendSummaries.first { $0.projectName == expected.projectName }
            )
            XCTAssertEqual(actual.totalCost, expected.totalCost, accuracy: 0.0001, expected.projectName)
            XCTAssertEqual(actual.totalTokens, expected.totalTokens, expected.projectName)
            XCTAssertEqual(actual.sessionCount, expected.sessionCount, expected.projectName)
        }
        XCTAssertTrue(allTime.projectSpendSummaries.contains { $0.projectName == "Unattributed" })
    }

    func test_dashboardSnapshot_last7DaySeriesMatchesPerDayTotals() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())

        for offset in 0...7 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -offset, to: todayStart))
            let start = day.addingTimeInterval(3_600)
            try await usageStore.insert(ViewTestFixtures.makeUsage(
                provider: .codex,
                sessionId: "day-\(offset)",
                model: "gpt-5",
                inputTokens: 100 * (offset + 1),
                outputTokens: 50,
                costUSD: Double(offset + 1),
                startTime: start,
                endTime: start.addingTimeInterval(60)
            ))
        }

        let snapshot = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
        XCTAssertEqual(snapshot.last7DayCosts.count, 7)
        XCTAssertEqual(snapshot.last7DayTokenTotals.count, 7)

        for (index, offset) in (0..<7).reversed().enumerated() {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -offset, to: todayStart))
            let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
            let totals = try await usageStore.fetchUsageTotals(in: day...nextDay)
            XCTAssertEqual(
                snapshot.last7DayCosts[index],
                totals.cost,
                accuracy: 0.0001,
                "last7DayCosts[\(index)] (offset \(offset)) must match the intersection-day total"
            )
            XCTAssertEqual(snapshot.last7DayTokenTotals[index], totals.tokens)
        }

        var expectedRolling = 0.0
        for offset in 1...7 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -offset, to: todayStart))
            let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
            expectedRolling += try await usageStore.fetchUsageTotals(in: day...nextDay).cost
        }
        XCTAssertEqual(snapshot.rollingDailyAverage, expectedRolling / 7, accuracy: 0.0001)
    }

    func test_dashboardSnapshot_windowTotalsMatchPerWindowAggregateQueries() async throws {
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let usageStore = UsageStore(dbQueue: queue)
        let now = Date()

        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .codex,
            sessionId: "today",
            model: "gpt-5",
            inputTokens: 100,
            outputTokens: 20,
            costUSD: 2,
            startTime: now,
            endTime: now.addingTimeInterval(30)
        ))
        try await usageStore.insert(ViewTestFixtures.makeUsage(
            provider: .claudeCode,
            sessionId: "week-ago",
            model: "sonnet",
            inputTokens: 50,
            outputTokens: 10,
            costUSD: 1,
            startTime: now.addingTimeInterval(-8 * 24 * 3600),
            endTime: now.addingTimeInterval(-8 * 24 * 3600 + 30)
        ))

        let snapshot = try await usageStore.fetchDashboardUsageSnapshot(loadedUsageLimit: 100)
        for timeRange in TimeRange.allCases {
            let expected = try await usageStore.fetchUsageTotals(in: timeRange.dateRange(now: now))
            let summary = try XCTUnwrap(snapshot.windowSummaries[timeRange])
            XCTAssertEqual(summary.totalCost, expected.cost, accuracy: 0.0001, timeRange.rawValue)
            XCTAssertEqual(summary.totalTokens, expected.tokens, timeRange.rawValue)
            XCTAssertEqual(summary.sessionCount, expected.sessionCount, timeRange.rawValue)
        }
    }

    func test_sqliteDateStringFormatsCanonicalUTCForDashboardWindows() {
        let utcMidnight = Date(timeIntervalSince1970: 1_779_580_800)
        let rendered = OpenBurnBarDatabase.sqliteDateString(utcMidnight)

        XCTAssertEqual(rendered, "2026-05-24 00:00:00.000")
    }

    func test_makeProviderSummaries_groupsProvidersAndModelsInOneDerivedSnapshot() async throws {
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
