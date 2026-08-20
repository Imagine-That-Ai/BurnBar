import XCTest
import GRDB
@testable import OpenBurnBar

@MainActor
final class DataStoreTests: XCTestCase {

    func test_parseDateValue_acceptsSqliteSecondsPrecisionDates() {
        let parsed = OpenBurnBarDatabase.parseDateValue("2026-07-03 02:48:41")

        XCTAssertNotNil(parsed)
        XCTAssertEqual(OpenBurnBarDatabase.sqliteDateString(parsed!), "2026-07-03 02:48:41.000")
    }

    func test_parseDateValue_acceptsISO8601AndUnixSeconds() throws {
        XCTAssertEqual(
            try XCTUnwrap(OpenBurnBarDatabase.parseDateValue("2026-05-24T00:00:00Z")).timeIntervalSince1970,
            1_779_580_800,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(OpenBurnBarDatabase.parseDateValue(1_779_580_800)).timeIntervalSince1970,
            1_779_580_800,
            accuracy: 0.001
        )
        XCTAssertNotNil(OpenBurnBarDatabase.parseDateValue("2026-05-24"))
    }

    func test_parseDateValue_isSafeUnderConcurrentReaderLoad() {
        let samples: [Any] = [
            "2026-07-03 02:48:41",
            "2026-07-03 02:48:41.123",
            "2026-05-24 00:00:00.000",
            "2026-05-04T08:00:00Z",
            1_779_580_800
        ]
        let expected = samples.map { OpenBurnBarDatabase.parseDateValue($0)?.timeIntervalSince1970 }
        XCTAssertTrue(expected.allSatisfy { $0 != nil })

        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            let sample = samples[index % samples.count]
            let parsed = OpenBurnBarDatabase.parseDateValue(sample)?.timeIntervalSince1970
            XCTAssertEqual(parsed ?? -1, expected[index % samples.count] ?? -2, accuracy: 0.001)
            if let date = OpenBurnBarDatabase.parseDateValue(sample) {
                let rendered = OpenBurnBarDatabase.sqliteDateString(date)
                XCTAssertNotNil(OpenBurnBarDatabase.parseDateValue(rendered))
            }
        }
    }

    func test_prepareForTermination_closesWriterSoLaterReadsFail() async throws {
        let store = try DataStore.makeInMemoryForTesting()
        await store.prepareForTermination()
        await store.prepareForTermination()

        do {
            _ = try await store.actor.fetchUsageTotals(in: nil)
            XCTFail("A closed database must reject later reads.")
        } catch let error as DatabaseError {
            XCTAssertTrue(
                [.SQLITE_MISUSE, .SQLITE_INTERRUPT].contains(error.resultCode),
                "Unexpected result code \(error.resultCode)"
            )
        }
    }

    func test_unmigratedStoreDoesNotAutoRefreshOnInit() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: false)

        for _ in 0..<3 {
            await Task.yield()
        }

        XCTAssertEqual(store.debugRefreshGenerationForTesting, 0)
        XCTAssertFalse(store.isLoading)
    }

    // MARK: - Rolling Daily Average Tests

    func test_rollingDailyAverage_sevenDays() async throws {
        let store = try DataStore.makeInMemoryForTesting()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var usages: [TokenUsage] = []
        for d in 1...7 {
            let day = cal.date(byAdding: Calendar.Component.day, value: -d, to: today)!
            let usage = makeUsage(
                sessionId: "s\(d)",
                costUSD: Double(d),
                startTime: day.addingTimeInterval(3600),
                endTime: day.addingTimeInterval(7200),
                inputTokens: 100,
                outputTokens: 100
            )
            usages.append(usage)
        }
        store.replaceUsages(usages)
        let expected: Double = 4.0
        XCTAssertEqual(store.rollingDailyAverage, expected, accuracy: 0.0001)
    }

    func test_rollingDailyAverage_zeroFillsMissingDays() async throws {
        let store = try DataStore.makeInMemoryForTesting()
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

    func test_moodBand_light() async throws {
        let store = try DataStore.makeInMemoryForTesting()
        store.replaceUsages(moodFixture(today: 0.5, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .light)
    }

    func test_moodBand_onPace() async throws {
        let store = try DataStore.makeInMemoryForTesting()
        store.replaceUsages(moodFixture(today: 1.0, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .onPace)
    }

    func test_moodBand_heavy() async throws {
        let store = try DataStore.makeInMemoryForTesting()
        store.replaceUsages(moodFixture(today: 2.0, rollingAvg: 1.0))
        XCTAssertEqual(store.moodBand, .heavy)
    }

    func test_moodBand_baseline() async throws {
        let store = try DataStore.makeInMemoryForTesting()
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

    func test_moodBand_quiet() async throws {
        let store = try DataStore.makeInMemoryForTesting()
        store.replaceUsages(moodFixture(today: 0, rollingAvg: 5))
        XCTAssertEqual(store.moodBand, .quiet)
    }

    func test_moodBand_zeroAverage() async throws {
        let store = try DataStore.makeInMemoryForTesting()
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

    func test_dataStoreLocalAuthoritySnapshot_reportsCountsAndControllerMirrorPresence() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        try await store.insert(
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
        try await store.saveControllerRuntimeMirror(OpenBurnBarControllerRuntimeSnapshot.empty)

        let snapshot = try await store.localAuthoritySnapshot()

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
        try await store.insert(rows)

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

    func test_contextBuilderWeeklySpendUsesExhaustiveAggregateBeyondPromptRowLimit() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let now = Date()
        let cheapRows = (0..<200).map { index in
            TokenUsage(
                provider: .factory,
                sessionId: "cheap-\(index)",
                projectName: "CheapProject",
                model: "cheap-model",
                inputTokens: 1,
                outputTokens: 1,
                costUSD: 1,
                startTime: now.addingTimeInterval(-Double(index)),
                endTime: now.addingTimeInterval(-Double(index) + 1)
            )
        }
        let expensiveExcludedFromPromptSample = TokenUsage(
            provider: .codex,
            sessionId: "older-expensive",
            projectName: "ExpensiveProject",
            model: "expensive-model",
            inputTokens: 1,
            outputTokens: 1,
            costUSD: 300,
            startTime: now.addingTimeInterval(-10_000),
            endTime: now.addingTimeInterval(-9_999)
        )
        try await store.insert(cheapRows + [expensiveExcludedFromPromptSample])

        let prompt = await ContextBuilder.buildSystemPrompt(from: store)

        XCTAssertTrue(prompt.contains("expensive-model"), "weekly spend must include rows outside the 200-row recent-work sample")
        XCTAssertTrue(prompt.contains("Top project: ExpensiveProject ($300.00)"))
    }

    // MARK: - Project Memory Persistence Tests

    func test_projectMemorySnapshot_roundTripsThroughControlPlaneStore() async throws {
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

        try await store.upsertProjectMemorySnapshot(snapshot)

        let fetched = try await store.fetchProjectMemorySnapshot(projectSlug: "apollo")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.projectSlug, snapshot.projectSlug)
        XCTAssertEqual(fetched?.projectDisplayName, snapshot.projectDisplayName)
        XCTAssertEqual(fetched?.contentHash, snapshot.contentHash)
        XCTAssertEqual(fetched?.pages.first?.sections.first?.citations.first?.sourceID, "conv-1")
    }

    func test_projectMemorySnapshot_deleteRemovesSnapshot() async throws {
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

        try await store.upsertProjectMemorySnapshot(snapshot)
        let savedSnapshot = try await store.fetchProjectMemorySnapshot(projectSlug: "remove-me")
        XCTAssertNotNil(savedSnapshot)

        try await store.deleteProjectMemorySnapshot(projectSlug: "remove-me")
        let deletedSnapshot = try await store.fetchProjectMemorySnapshot(projectSlug: "remove-me")
        XCTAssertNil(deletedSnapshot)
    }

    func test_deleteAllIndexedConversationsClearsDerivedProjectMemorySnapshots() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let now = Date()
        let snapshot = ProjectMemorySnapshot(
            projectSlug: "privacy-reset",
            projectDisplayName: "Privacy Reset",
            generatedAt: now,
            sourceSessionIDs: ["session-sensitive"],
            sourceConversationIDs: ["conversation-sensitive"],
            sourceWindowStart: now.addingTimeInterval(-600),
            sourceWindowEnd: now,
            keyFiles: ["Sources/Private.swift"],
            keyCommands: ["private command"],
            usageSummary: "transcript-derived private usage summary",
            freshness: .fresh,
            contentHash: "privacy-reset-hash",
            schemaVersion: ProjectMemorySnapshot.currentSchemaVersion,
            pages: [
                ProjectMemoryPage(
                    title: "Derived Memory",
                    summary: "Transcript-derived summary",
                    sections: [
                        ProjectMemorySection(
                            title: "Sensitive Context",
                            body: "Transcript-derived detail that must not survive the indexed-data wipe.",
                            citations: [
                                ProjectMemoryCitation(
                                    sourceID: "conversation-sensitive",
                                    sourceKind: .conversation,
                                    title: "Conversation source",
                                    snippet: "Private transcript snippet",
                                    createdAt: now
                                )
                            ]
                        )
                    ],
                    visualIDs: []
                )
            ],
            visuals: []
        )

        try await store.upsertProjectMemorySnapshot(snapshot)
        let seededSnapshot = try await store.fetchProjectMemorySnapshot(projectSlug: "privacy-reset")
        XCTAssertNotNil(seededSnapshot)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO search_documents (
                    id, sourceKind, sourceID, sourceVersionID, provider, projectName, title,
                    bodyPreview, indexedAt, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "doc-conversation-sensitive",
                    "conversation",
                    "conversation-sensitive",
                    "v1",
                    "codex",
                    "BurnBar",
                    "Private conversation",
                    "private body preview",
                    now,
                    now,
                    now
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO search_chunks (
                    id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                    startOffset, endOffset, text, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "chunk-conversation-sensitive",
                    "doc-conversation-sensitive",
                    "conversation",
                    "conversation-sensitive",
                    "v1",
                    0,
                    0,
                    29,
                    "private transcript chunk text",
                    now,
                    now
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    "chunk-conversation-sensitive",
                    "doc-conversation-sensitive",
                    "Private conversation",
                    "private transcript chunk text"
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO embedding_models (id, provider, modelName, dimensions, distanceMetric, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["model-conversation-sensitive", "test", "test-embedding", 1, "cosine", now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO embedding_versions (
                    id, modelID, versionTag, chunkerVersion, normalizationVersion, promptVersion,
                    isActive, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "version-conversation-sensitive",
                    "model-conversation-sensitive",
                    "v1",
                    "chunker",
                    "normalizer",
                    "prompt",
                    true,
                    now,
                    now
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO chunk_embeddings (chunkID, embeddingVersionID, vectorBlob, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    "chunk-conversation-sensitive",
                    "version-conversation-sensitive",
                    Data([0, 0, 0, 0]),
                    now,
                    now
                ]
            )
        }

        try await store.deleteAllIndexedConversations()

        let deletedSnapshot = try await store.fetchProjectMemorySnapshot(projectSlug: "privacy-reset")
        XCTAssertNil(deletedSnapshot)
        let remainingSnapshots = try await store.fetchProjectMemorySnapshots()
        XCTAssertTrue(remainingSnapshots.isEmpty)
        try await queue.read { db in
            let tableCounts = try [
                "search_documents",
                "search_chunks",
                "search_chunks_fts",
                "chunk_embeddings"
            ].map { table in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            XCTAssertEqual(tableCounts, [0, 0, 0, 0])
        }
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
        let yesterday = cal.date(byAdding: Calendar.Component.day, value: -1, to: todayStart)!

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

    private func makeUsage(
        sessionId: String,
        costUSD: Double,
        startTime: Date,
        endTime: Date,
        inputTokens: Int = 1,
        outputTokens: Int = 1
    ) -> TokenUsage {
        TokenUsage(
            provider: .factory,
            sessionId: sessionId,
            projectName: "p",
            model: "m",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costUSD: costUSD,
            startTime: startTime,
            endTime: endTime
        )
    }
}
