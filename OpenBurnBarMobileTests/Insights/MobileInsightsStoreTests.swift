import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Smoke tests for the mobile `InsightsStore` orchestration on top of
/// the shared core types. Tests don't hit Firestore — they use the
/// in-memory data source the macOS core suite already covers, but
/// exercised through the mobile store's lifecycle.
@MainActor
final class MobileInsightsStoreTests: XCTestCase {

    func testInsightsStoreSeedsFromTemplateOnFirstRun() async throws {
        // Use an isolated working directory so tests don't share state
        // with each other or with the running app's Application Support.
        let isolated = makeIsolatedSupportDir()
        defer { try? FileManager.default.removeItem(at: isolated) }
        FileManager.default.changeCurrentDirectoryPath(isolated.path)

        // We can't override `applicationSupportDirectory()` directly, but
        // we can build an `InsightCanvasStore` rooted in the isolated dir
        // and assert template seeding via the public API.
        let store = try InsightCanvasStore(
            fileURL: isolated.appendingPathComponent("canvases.json")
        )
        let template = MobileInsightsTemplates.today
        let canvas = template.instantiate()
        try await store.upsert(canvas)
        let loaded = await store.allCanvases()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.origin, .template(id: "mobile-today"))
        XCTAssertGreaterThan(loaded.first?.widgets.count ?? 0, 0)
        XCTAssertGreaterThan(loaded.first?.layout.placements.count ?? 0, 0,
                              "Mobile template must have placements after instantiate")
    }

    func testMobileTemplatesAutoPlaceAllWidgets() {
        for template in MobileInsightsTemplates.all {
            let canvas = template.instantiate()
            XCTAssertEqual(canvas.widgets.count, canvas.layout.placements.count,
                           "Template '\(template.id)' must place every widget")
            for widget in canvas.widgets {
                let placement = canvas.layout.placements[widget.id]
                XCTAssertNotNil(placement, "Template '\(template.id)' widget '\(widget.title)' lacks placement")
            }
        }
    }

    func testMobileInsightDataSourceReturnsEmptySnapshotWhenStoreUnloaded() async throws {
        // Brand-new DashboardStore is empty; the data source must return
        // an empty (but non-throwing) snapshot rather than crashing.
        let dashboard = DashboardStore()
        let source = MobileInsightDataSource(dashboardStore: dashboard, usagePageLoader: { _ in [] })
        let snapshot = try await source.snapshot(window: InsightTimeWindow.last7d.interval())
        XCTAssertTrue(snapshot.usages.isEmpty)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testMobileInsightDataSourceUsesRequestedWindowRollup() async throws {
        let dashboard = DashboardStore(initialRollups: [
            makeRollup(window: .today, requests: 0, tokens: 0, cost: 0),
            makeRollup(window: .sevenDays, requests: 3, tokens: 900, cost: 4.2)
        ])
        dashboard.setWindow(.today)

        let source = MobileInsightDataSource(dashboardStore: dashboard, usagePageLoader: { _ in [] })
        let today = try await source.snapshot(for: .today)
        let week = try await source.snapshot(for: .last7d)

        XCTAssertTrue(today.usages.isEmpty)
        XCTAssertFalse(week.usages.isEmpty)
        XCTAssertEqual(Set(week.usages.map(\.provider)), ["claude"])
        XCTAssertEqual(Set(week.usages.map(\.model)), ["claude-sonnet"])
        XCTAssertEqual(week.usages.reduce(0) { $0 + $1.totalTokens }, 900)
        XCTAssertEqual(week.usages.reduce(0) { $0 + $1.costUSD }, 4.2, accuracy: 0.0001)
    }

    func testMobileInsightDataSourceFallsBackToRollupTotalsWhenSummariesAreMissing() async throws {
        let dashboard = DashboardStore(initialRollups: [
            UsageRollupDoc(
                windowKey: .thirtyDays,
                totals: RollupTotals(requests: 2, tokens: 240, costUsd: 0),
                providerSummaries: [],
                modelSummaries: [],
                deviceSummaries: [],
                dailyPoints: [],
                computedAt: Date(),
                schemaVersion: 3
            )
        ])

        let source = MobileInsightDataSource(dashboardStore: dashboard, usagePageLoader: { _ in [] })
        let snapshot = try await source.snapshot(for: .last30d)

        XCTAssertFalse(snapshot.usages.isEmpty)
        XCTAssertEqual(Set(snapshot.usages.map(\.provider)), ["All providers"])
        XCTAssertEqual(snapshot.usages.reduce(0) { $0 + $1.totalTokens }, 240)
    }

    func testMobileInsightDataSourceFallsBackToRawUsageWhenRollupIsEmpty() async throws {
        let dashboard = DashboardStore(initialRollups: [
            makeRollup(window: .sevenDays, requests: 0, tokens: 0, cost: 0)
        ])
        let source = MobileInsightDataSource(dashboardStore: dashboard) { interval in
            [
                self.makeUsage(
                    sessionId: "raw-week",
                    startTime: interval.start.addingTimeInterval(3600),
                    endTime: interval.start.addingTimeInterval(5400)
                )
            ]
        }

        let snapshot = try await source.snapshot(for: .last7d)

        XCTAssertEqual(snapshot.usages.count, 1)
        XCTAssertEqual(snapshot.usages.first?.sessionID, "raw-week")
        XCTAssertEqual(snapshot.usages.first?.provider, AgentProvider.codex.rawValue)
        XCTAssertEqual(snapshot.usages.first?.projectName, "BurnBar")
        XCTAssertEqual(snapshot.usages.first?.totalTokens, 175)
        XCTAssertEqual(snapshot.usages.first?.costUSD ?? 0, 0.42, accuracy: 0.0001)
    }

    private func makeIsolatedSupportDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileInsightsStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeRollup(
        window: RollupWindowKey,
        requests: Int,
        tokens: Int,
        cost: Double
    ) -> UsageRollupDoc {
        UsageRollupDoc(
            windowKey: window,
            totals: RollupTotals(requests: requests, tokens: tokens, costUsd: cost),
            providerSummaries: requests == 0 && tokens == 0 && cost == 0
                ? []
                : [
                    RollupProviderSummary(
                        provider: "claude",
                        totalRequests: requests,
                        totalTokens: tokens,
                        totalCost: cost
                    )
                ],
            modelSummaries: requests == 0 && tokens == 0 && cost == 0
                ? []
                : [
                    RollupModelSummary(
                        model: "claude-sonnet",
                        provider: "claude",
                        requests: requests,
                        tokens: tokens,
                        cost: cost
                    )
                ],
            deviceSummaries: [],
            dailyPoints: requests == 0 && tokens == 0 && cost == 0
                ? []
                : [RollupDailyPoint(date: Date(), value: max(cost, Double(tokens), Double(requests)))],
            computedAt: Date(),
            schemaVersion: 3
        )
    }

    private func makeUsage(
        sessionId: String,
        startTime: Date,
        endTime: Date
    ) -> TokenUsage {
        TokenUsage(
            provider: .codex,
            sessionId: sessionId,
            projectName: "BurnBar",
            model: "gpt-5",
            inputTokens: 100,
            outputTokens: 50,
            cacheCreationTokens: 10,
            cacheReadTokens: 5,
            reasoningTokens: 10,
            costUSD: 0.42,
            startTime: startTime,
            endTime: endTime,
            sourceDeviceId: "iphone",
            sourceDeviceName: "iPhone"
        )
    }
}
