import XCTest
import GRDB
@testable import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - ReceiptBuilder tests
//
// Drives the conversations × token_usage join through a real migrated store
// (same fixture style as ProjectionPipelineServiceTests) and pins the
// honesty rules: cluster only on strong evidence, never estimate a dollar,
// and always prefer an undercount to an overclaim.

@MainActor
final class ReceiptBuilderTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_742_000_000)

    // MARK: (a) Same title, same project → one cluster, waste = total minus cheapest

    func test_sameTitleSameProject_clusters_wasteIsTotalMinusCheapest() async throws {
        let store = try makeStore()
        let title = "Fix flaky auth token refresh test"
        try await store.upsertConversation(makeConversation(
            id: "conv-a", provider: .claudeCode, sessionId: "session-a",
            title: title, startTime: base
        ))
        try await store.upsertConversation(makeConversation(
            id: "conv-b", provider: .codex, sessionId: "session-b",
            title: title, startTime: base.addingTimeInterval(2 * 3_600)
        ))
        try await store.insert(makeUsage(
            provider: .claudeCode, sessionId: "session-a", cost: 2.0, startTime: base
        ))
        try await store.insert(makeUsage(
            provider: .codex, sessionId: "session-b", cost: 5.0,
            startTime: base.addingTimeInterval(2 * 3_600)
        ))

        let snapshot = try await ReceiptBuilder.build(dataStore: store, window: nil, now: base)

        XCTAssertEqual(snapshot.clusters.count, 1)
        let cluster = try XCTUnwrap(snapshot.clusters.first)
        XCTAssertEqual(cluster.solveCount, 2)
        XCTAssertEqual(cluster.representativeTitle, title)
        XCTAssertEqual(cluster.conversations.map(\.id), ["conv-a", "conv-b"], "Members must stay chronological — first solve first.")
        // Total $7 minus the cheapest member ($2): only the repeat was waste.
        XCTAssertEqual(cluster.rederivedCostUSD, 5.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.totalRederivedCostUSD, 5.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.distinctAgentCount, 2)
        XCTAssertFalse(snapshot.costIsPartial)
        XCTAssertNil(snapshot.windowDays)
    }

    // MARK: (b) Same title, different projects → never clusters

    func test_similarTitles_inDifferentProjects_doNotCluster() async throws {
        let store = try makeStore()
        let title = "Fix flaky auth token refresh test"
        try await store.upsertConversation(makeConversation(
            id: "conv-alpha", sessionId: "session-alpha", projectName: "Alpha",
            title: title, startTime: base
        ))
        try await store.upsertConversation(makeConversation(
            id: "conv-beta", sessionId: "session-beta", projectName: "Beta",
            title: title, startTime: base.addingTimeInterval(2 * 3_600)
        ))

        let snapshot = try await ReceiptBuilder.build(dataStore: store, window: nil, now: base)

        XCTAssertTrue(snapshot.isEmpty, "The same words in two repos are two different problems.")
    }

    // MARK: (c) Below-threshold similarity → never clusters

    func test_belowThresholdTitleSimilarity_doesNotCluster() async throws {
        let store = try makeStore()
        // Shared token "fix" only: Jaccard = 1/5 = 0.2, far below 0.6.
        try await store.upsertConversation(makeConversation(
            id: "conv-1", sessionId: "session-1",
            title: "Fix auth login", startTime: base
        ))
        try await store.upsertConversation(makeConversation(
            id: "conv-2", sessionId: "session-2",
            title: "Fix database migration", startTime: base.addingTimeInterval(2 * 3_600)
        ))

        let snapshot = try await ReceiptBuilder.build(dataStore: store, window: nil, now: base)

        XCTAssertTrue(snapshot.isEmpty, "Weak title overlap must not become a re-derivation claim.")
    }

    // MARK: (d) Missing usage → $0 contribution, flagged, never estimated

    func test_missingUsage_contributesZeroCost_andFlagsPartial() async throws {
        let store = try makeStore()
        let title = "Debug xcodegen membership drift"
        try await store.upsertConversation(makeConversation(
            id: "conv-priced", sessionId: "session-priced",
            title: title, startTime: base
        ))
        try await store.upsertConversation(makeConversation(
            id: "conv-unpriced", sessionId: "session-unpriced",
            title: title, startTime: base.addingTimeInterval(2 * 3_600)
        ))
        // Usage exists only for the first solve.
        try await store.insert(makeUsage(sessionId: "session-priced", cost: 4.0, startTime: base))

        let snapshot = try await ReceiptBuilder.build(dataStore: store, window: nil, now: base)

        XCTAssertEqual(snapshot.clusters.count, 1)
        let cluster = try XCTUnwrap(snapshot.clusters.first)
        let unpriced = try XCTUnwrap(cluster.conversations.first { $0.id == "conv-unpriced" })
        XCTAssertEqual(unpriced.costUSD, 0, "No usage rows means $0 — never an estimate.")
        XCTAssertFalse(unpriced.hasUsage)
        XCTAssertTrue(snapshot.costIsPartial)
        // The one priced member is credited as the legitimate solve; the
        // unpriced repeat adds no *claimed* waste. Undercount, never overclaim.
        XCTAssertEqual(cluster.rederivedCostUSD, 0, accuracy: 0.0001)
    }

    // MARK: (e) Empty store → empty snapshot

    func test_emptyStore_returnsEmptySnapshot() async throws {
        let store = try makeStore()

        let snapshot = try await ReceiptBuilder.build(dataStore: store, window: nil, now: base)

        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.problemCount, 0)
        XCTAssertEqual(snapshot.distinctAgentCount, 0)
        XCTAssertEqual(snapshot.totalRederivedCostUSD, 0, accuracy: 0.0001)
        XCTAssertFalse(snapshot.costIsPartial)
    }

    // MARK: Sessions under 30 minutes apart are one sitting, not a re-solve

    func test_sessionsWithinThirtyMinutes_doNotCluster() async throws {
        let store = try makeStore()
        let title = "Fix flaky auth token refresh test"
        try await store.upsertConversation(makeConversation(
            id: "conv-first", sessionId: "session-first",
            title: title, startTime: base
        ))
        try await store.upsertConversation(makeConversation(
            id: "conv-resumed", sessionId: "session-resumed",
            title: title, startTime: base.addingTimeInterval(10 * 60)
        ))

        let snapshot = try await ReceiptBuilder.build(dataStore: store, window: nil, now: base)

        XCTAssertTrue(snapshot.isEmpty, "A session resumed minutes later is a continuation, not re-derived work.")
    }

    // MARK: Sub-agent usage rows ("root/sub") roll up to the conversation's root session

    func test_subSessionUsageRows_rollUpToRootSession() async throws {
        let store = try makeStore()
        let title = "Fix flaky auth token refresh test"
        try await store.upsertConversation(makeConversation(
            id: "conv-root", sessionId: "root-1",
            title: title, startTime: base
        ))
        try await store.upsertConversation(makeConversation(
            id: "conv-repeat", sessionId: "root-2",
            title: title, startTime: base.addingTimeInterval(2 * 3_600)
        ))
        // Root row + a sub-agent row under the same root session. Distinct
        // models keep the (provider, sessionId, model) unique index happy.
        try await store.insert(makeUsage(sessionId: "root-1", model: "model-a", cost: 1.0, startTime: base))
        try await store.insert(makeUsage(sessionId: "root-1/sub-agent", model: "model-b", cost: 2.0, startTime: base))
        try await store.insert(makeUsage(
            sessionId: "root-2", model: "model-a", cost: 1.0,
            startTime: base.addingTimeInterval(2 * 3_600)
        ))

        let snapshot = try await ReceiptBuilder.build(dataStore: store, window: nil, now: base)

        let cluster = try XCTUnwrap(snapshot.clusters.first)
        let rootMember = try XCTUnwrap(cluster.conversations.first { $0.id == "conv-root" })
        XCTAssertEqual(rootMember.costUSD, 3.0, accuracy: 0.0001, "Sub-agent spend belongs to the root session.")
        // Total $4 minus cheapest member ($1).
        XCTAssertEqual(cluster.rederivedCostUSD, 3.0, accuracy: 0.0001)
        XCTAssertFalse(snapshot.costIsPartial)
    }

    // MARK: Window filtering

    func test_windowExcludesConversationsOutsideIt() async throws {
        let store = try makeStore()
        let title = "Fix flaky auth token refresh test"
        let now = base.addingTimeInterval(40 * 86_400)
        try await store.upsertConversation(makeConversation(
            id: "conv-old", sessionId: "session-old",
            title: title, startTime: base
        ))
        try await store.upsertConversation(makeConversation(
            id: "conv-recent", sessionId: "session-recent",
            title: title, startTime: now.addingTimeInterval(-86_400)
        ))

        let window = now.addingTimeInterval(-7 * 86_400)...now
        let snapshot = try await ReceiptBuilder.build(dataStore: store, window: window, now: now)

        XCTAssertTrue(snapshot.isEmpty, "Only one solve is inside the window — no repeat, no claim.")
        XCTAssertEqual(snapshot.windowDays, 7)
    }

    // MARK: - Fixtures

    private func makeStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeConversation(
        id: String,
        provider: AgentProvider = .claudeCode,
        sessionId: String,
        projectName: String = "OpenBurnBar",
        title: String,
        startTime: Date
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(300),
            messageCount: 4,
            userWordCount: 20,
            assistantWordCount: 40,
            keyFiles: ["DataStore.swift"],
            keyCommands: ["swift test"],
            keyTools: ["Read"],
            inferredTaskTitle: title,
            lastAssistantMessage: "Done.",
            fullText: "transcript body",
            indexedAt: startTime.addingTimeInterval(600),
            fileModifiedAt: startTime.addingTimeInterval(600),
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: .providerLog
        )
    }

    private func makeUsage(
        provider: AgentProvider = .claudeCode,
        sessionId: String,
        projectName: String = "OpenBurnBar",
        model: String = "model-a",
        cost: Double,
        startTime: Date
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            model: model,
            inputTokens: 1_000,
            outputTokens: 500,
            costUSD: cost,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(60)
        )
    }
}
