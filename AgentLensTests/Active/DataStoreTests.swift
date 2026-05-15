import XCTest
import GRDB
@testable import OpenBurnBar

@MainActor
final class DataStoreTests: XCTestCase {

    // MARK: - Rolling Daily Average Tests

    func test_rollingDailyAverage_sevenDays() throws {
        let store = try DataStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var usages: [TokenUsage] = []
        for d in 1...7 {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            usages.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 100,
                    outputTokens: 100,
                    costUSD: Double(d),
                    startTime: day.addingTimeInterval(3600),
                    endTime: day.addingTimeInterval(7200)
                )
            )
        }
        store.replaceUsages(usages)
        let expected = (1.0 + 2.0 + 3.0 + 4.0 + 5.0 + 6.0 + 7.0) / 7.0
        XCTAssertEqual(store.rollingDailyAverage, expected, accuracy: 0.0001)
    }

    func test_rollingDailyAverage_zeroFillsMissingDays() throws {
        let store = try DataStore()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var usages: [TokenUsage] = []
        for d in [1, 3, 5] {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            usages.append(
                TokenUsage(
                    provider: .factory,
                    sessionId: "s\(d)",
                    projectName: "p",
                    model: "m",
                    inputTokens: 10,
                    outputTokens: 10,
                    costUSD: 10,
                    startTime: day.addingTimeInterval(100),
                    endTime: day.addingTimeInterval(200)
                )
            )
        }
        store.replaceUsages(usages)
        XCTAssertEqual(store.rollingDailyAverage, 30.0 / 7.0, accuracy: 0.0001)
    }

    // MARK: - Mood Band Tests

    func test_moodBand_light() throws {
        let store = try DataStore()
        store.replaceUsages(moodFixture(today: 0.5, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .light)
    }

    func test_moodBand_onPace() throws {
        let store = try DataStore()
        store.replaceUsages(moodFixture(today: 1.0, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .onPace)
    }

    func test_moodBand_heavy() throws {
        let store = try DataStore()
        store.replaceUsages(moodFixture(today: 2.0, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .heavy)
    }

    func test_moodBand_baseline() throws {
        let store = try DataStore()
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let u = TokenUsage(
            provider: .factory,
            sessionId: "a",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 1,
            startTime: day.addingTimeInterval(10),
            endTime: day.addingTimeInterval(20)
        )
        store.replaceUsages([u])
        XCTAssertEqual(store.moodBand, .baseline)
    }

    func test_moodBand_quiet() throws {
        let store = try DataStore()
        store.replaceUsages(moodFixture(today: 0, rollingAvg: 5))
        XCTAssertEqual(store.moodBand, .quiet)
    }

    func test_moodBand_zeroAverage() throws {
        let store = try DataStore()
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: Date())
        let d1 = cal.date(byAdding: .day, value: -1, to: d0)!
        let older = TokenUsage(
            provider: .factory,
            sessionId: "old",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0,
            startTime: d1.addingTimeInterval(10),
            endTime: d1.addingTimeInterval(20)
        )
        let today = TokenUsage(
            provider: .factory,
            sessionId: "new",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 3,
            startTime: d0.addingTimeInterval(10),
            endTime: d0.addingTimeInterval(20)
        )
        store.replaceUsages([older, today])
        XCTAssertEqual(store.rollingDailyAverage, 0, accuracy: 0.0001)
        XCTAssertEqual(store.moodBand, .onPace)
    }

    // MARK: - Token Usage Tests

    func test_cacheRatio_aboveThreshold() {
        let u = TokenUsage(
            provider: .factory,
            sessionId: "c",
            projectName: "p",
            model: "m",
            inputTokens: 10,
            outputTokens: 10,
            cacheCreationTokens: 0,
            cacheReadTokens: 25,
            costUSD: 1,
            startTime: Date(),
            endTime: Date()
        )
        XCTAssertTrue(u.totalTokens > 0)
        XCTAssertGreaterThan(Double(u.cacheReadTokens) / Double(u.totalTokens), 0.5)
    }

    func test_cacheRatio_zeroTotal() {
        let u = TokenUsage(
            provider: .factory,
            sessionId: "z",
            projectName: "p",
            model: "m",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            costUSD: 0,
            startTime: Date(),
            endTime: Date()
        )
        XCTAssertEqual(u.totalTokens, 0)
    }

    // MARK: - Local Authority Snapshot Tests

    func test_dataStoreLocalAuthoritySnapshot_reportsCountsAndControllerMirrorPresence() throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        try store.insert(
            TokenUsage(
                provider: .factory,
                sessionId: "authority-1",
                projectName: "Apollo",
                model: "glm-5",
                inputTokens: 10,
                outputTokens: 12,
                costUSD: 0.12,
                startTime: Date(),
                endTime: Date()
            )
        )
        try store.saveControllerRuntimeMirror(OpenBurnBarControllerRuntimeSnapshot.empty)

        let snapshot = try store.localAuthoritySnapshot()

        XCTAssertEqual(snapshot.usageRowCount, 1)
        XCTAssertEqual(snapshot.conversationRowCount, 0)
        XCTAssertEqual(snapshot.sharedArtifactCount, 0)
        XCTAssertTrue(snapshot.controllerRuntimeCached)
    }

    func test_refresh_keepsAggregateStatsUncappedWhileLazyLoadingRows() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let now = Date()
        let rows = (0..<5_001).map { index in
            TokenUsage(
                provider: .factory,
                sessionId: "unbounded-refresh-\(index)",
                projectName: "Scale",
                model: "droid",
                inputTokens: 1,
                outputTokens: 1,
                costUSD: 0.01,
                startTime: now.addingTimeInterval(-Double(index)),
                endTime: now.addingTimeInterval(-Double(index) + 1)
            )
        }
        try store.insert(rows)

        await store.refresh()

        XCTAssertEqual(store.usages.count, 5_000)
        XCTAssertEqual(store.totalTokensAllTime, 10_002)
        XCTAssertFalse(store.usages.contains { $0.sessionId == "unbounded-refresh-5000" })

        let allTime = store.usageWindowSummary(for: .allTime)
        XCTAssertEqual(allTime.sessionCount, 5_001)
        XCTAssertEqual(allTime.totalTokens, 10_002)
        XCTAssertEqual(allTime.providerSummaries.first?.sessionCount, 5_001)
        XCTAssertEqual(allTime.providerSummaries.first?.totalTokens, 10_002)

        let last7Days = store.usageWindowSummary(for: .last7Days)
        XCTAssertEqual(last7Days.sessionCount, 5_001)
        XCTAssertEqual(last7Days.totalTokens, 10_002)
    }

    // MARK: - Project Memory Persistence Tests

    func test_projectMemorySnapshot_roundTripsThroughControlPlaneStore() throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let now = Date()
        let snapshot = ProjectMemorySnapshot(
            projectSlug: "apollo",
            projectDisplayName: "Apollo",
            generatedAt: now,
            sourceSessionIDs: ["Claude Code:s-1"],
            sourceConversationIDs: ["conv-1"],
            sourceWindowStart: now.addingTimeInterval(-3600),
            sourceWindowEnd: now,
            keyFiles: ["Sources/App.swift"],
            keyCommands: ["swift test"],
            usageSummary: "1 usage session · 1 cited transcript · 2,400 tokens · $1.20 spend · providers: Claude Code",
            freshness: .fresh,
            contentHash: "hash-1",
            schemaVersion: ProjectMemorySnapshot.currentSchemaVersion,
            pages: [
                ProjectMemoryPage(
                    title: "Project Memory",
                    summary: "Snapshot summary",
                    sections: [
                        ProjectMemorySection(
                            title: "Executive Brief",
                            body: "Apollo summary",
                            citations: [
                                ProjectMemoryCitation(
                                    sourceID: "conv-1",
                                    sourceKind: .conversation,
                                    title: "Session one",
                                    snippet: "Source snippet",
                                    createdAt: now
                                )
                            ]
                        )
                    ],
                    visualIDs: ["cover"]
                )
            ],
            visuals: [
                ProjectMemoryVisual(
                    id: "cover",
                    kind: .cover,
                    title: "Apollo",
                    subtitle: "Cover",
                    points: [ProjectMemoryVisualPoint(label: "Sessions", value: 1)]
                )
            ]
        )

        try store.upsertProjectMemorySnapshot(snapshot)

        let fetched = try store.fetchProjectMemorySnapshot(projectSlug: "apollo")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.projectSlug, snapshot.projectSlug)
        XCTAssertEqual(fetched?.projectDisplayName, snapshot.projectDisplayName)
        XCTAssertEqual(fetched?.contentHash, snapshot.contentHash)
        XCTAssertEqual(fetched?.pages.first?.sections.first?.citations.first?.sourceID, "conv-1")
    }

    func test_projectMemorySnapshot_deleteRemovesSnapshot() throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let snapshot = ProjectMemorySnapshot(
            projectSlug: "remove-me",
            projectDisplayName: "Remove Me",
            generatedAt: Date(),
            sourceSessionIDs: [],
            sourceConversationIDs: [],
            sourceWindowStart: nil,
            sourceWindowEnd: nil,
            keyFiles: [],
            keyCommands: [],
            usageSummary: "empty",
            freshness: .evidenceThin,
            contentHash: "hash-2",
            schemaVersion: ProjectMemorySnapshot.currentSchemaVersion,
            pages: [],
            visuals: []
        )

        try store.upsertProjectMemorySnapshot(snapshot)
        XCTAssertNotNil(try store.fetchProjectMemorySnapshot(projectSlug: "remove-me"))

        try store.deleteProjectMemorySnapshot(projectSlug: "remove-me")
        XCTAssertNil(try store.fetchProjectMemorySnapshot(projectSlug: "remove-me"))
    }

    // MARK: - Helper Methods

    private var pastDayUsage: TokenUsage {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -1, to: Date())!
        return TokenUsage(
            provider: .factory,
            sessionId: "past",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 0.05,
            startTime: day.addingTimeInterval(100),
            endTime: day.addingTimeInterval(200)
        )
    }

    private func moodFixture(today: Double, rollingAvg: Double) -> [TokenUsage] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let older = cal.date(byAdding: .day, value: -2, to: todayStart)!

        var usages: [TokenUsage] = []

        // Today's usage
        usages.append(TokenUsage(
            provider: .factory,
            sessionId: "today",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: today,
            startTime: todayStart.addingTimeInterval(100),
            endTime: todayStart.addingTimeInterval(200)
        ))

        // Yesterday's usage
        usages.append(TokenUsage(
            provider: .factory,
            sessionId: "yesterday",
            projectName: "p",
            model: "m",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: rollingAvg,
            startTime: yesterday.addingTimeInterval(100),
            endTime: yesterday.addingTimeInterval(200)
        ))

        // Add older days with rolling average cost
        for i in 2...7 {
            let day = cal.date(byAdding: .day, value: -i, to: todayStart)!
            usages.append(TokenUsage(
                provider: .factory,
                sessionId: "d\(i)",
                projectName: "p",
                model: "m",
                inputTokens: 1,
                outputTokens: 1,
                costUSD: rollingAvg,
                startTime: day.addingTimeInterval(100),
                endTime: day.addingTimeInterval(200)
            ))
        }

        return usages
    }
}
