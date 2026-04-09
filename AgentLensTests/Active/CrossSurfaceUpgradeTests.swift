import XCTest
import GRDB
@testable import OpenBurnBar

/// Tests for cross-surface coherence between exact-first upgrade propagation,
/// repeated unchanged refresh cycles, and event/reconciliation path convergence.
///
/// VAL-CROSS-001: Exact-first upgrade propagates end-to-end.
/// When late exact data upgrades a prior estimate, corrected canonical values must
/// propagate through persistence and reporting surfaces; indexing artifacts must
/// remain consistent (updated only when an index-coupled source actually changed).
///
/// VAL-CROSS-002: Repeated refreshes remain low-cost when data is unchanged.
/// Across repeated refresh cycles with unchanged source content, checkpoint/hash skips
/// must keep incremental workload bounded with no redundant full scans/reindex.
///
/// VAL-CROSS-007: Event-path and reconciliation-path reporting totals converge.
/// For identical fixture windows, event-driven processing and scheduled
/// reconciliation/backfill processing must converge to the same reporting totals
/// and canonical row set.
@MainActor
final class CrossSurfaceUpgradeTests: XCTestCase {

    // MARK: - Helpers

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    /// Drains all pending projection jobs across multiple sweeps.
    /// Returns total completed jobs across all drain sweeps.
    private func drainProjectionJobs(_ service: ProjectionPipelineService, maxSweeps: Int = 10, maxPerSweep: Int = 50) async throws -> Int {
        var totalCompleted = 0
        for _ in 0..<maxSweeps {
            let report = try await service.runSweep(maxJobs: maxPerSweep)
            totalCompleted += report.completedJobs
            if report.leasedJobs == 0 { break }
        }
        return totalCompleted
    }

    private func fetchCanonicalRow(queue: DatabaseQueue, sessionId: String) throws -> Row? {
        try queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM token_usage
                WHERE sessionId = ?
                ORDER BY startTime DESC LIMIT 1
                """, arguments: [sessionId])
        }
    }

    private func countCanonicalRows(queue: DatabaseQueue) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token_usage") ?? 0
        }
    }

    private func extractInt(_ row: Row, column: String) -> Int {
        (row[column] as? Int) ?? Int(row[column] as? Int64 ?? 0)
    }

    private func allUsageSummaries(_ store: DataStore) -> (totalCost: Double, totalTokens: Int) {
        let usages = store.usages
        let totalCost = usages.reduce(0) { $0 + $1.cost }
        let totalTokens = usages.reduce(0) { $0 + $1.totalTokens }
        return (totalCost, totalTokens)
    }

    private func makeConversation(
        id: String,
        provider: AgentProvider = .claudeCode,
        fullText: String,
        indexedAt: Date
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: provider,
            sessionId: "session-\(id)",
            projectName: "OpenBurnBar",
            startTime: indexedAt.addingTimeInterval(-60),
            endTime: indexedAt,
            messageCount: 4,
            userWordCount: 20,
            assistantWordCount: 40,
            keyFiles: ["DataStore.swift"],
            keyCommands: ["swift test"],
            keyTools: ["Read"],
            inferredTaskTitle: "CrossSurface Test",
            lastAssistantMessage: "Done.",
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: indexedAt,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: .providerLog
        )
    }

    /// Inserts a usage row directly and refreshes the DataStore in-memory array.
    private func insertAndRefresh(usage: TokenUsage, store: DataStore) throws {
        try store.insert(usage)
        store.refresh()
    }

    // MARK: - VAL-CROSS-001: Exact-first upgrade propagates end-to-end

    /// Verifies that when a late exact usage row upgrades a prior estimate,
    /// the reporting surfaces (computed properties on DataStore) reflect the
    /// corrected values after refresh.
    func test_lateExactUpgrade_propagatesToReportingSurfaces() throws {
        let store = try makeInMemoryStore()
        let sessionId = "cross-surface-upgrade-1"
        let baseDate = Date(timeIntervalSince1970: 1_743_000_000)

        // Step 1: Insert an estimated row
        let estimateUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try insertAndRefresh(usage: estimateUsage, store: store)

        // Verify reporting reflects estimated values
        let estimateSummary = allUsageSummaries(store)
        XCTAssertEqual(estimateSummary.totalTokens, 1500)
        XCTAssertEqual(estimateSummary.totalCost, 0.05, accuracy: 0.001)

        // Step 2: Insert exact data for the same canonical key — should upgrade
        let exactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "ProjectUpdated",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 800,
            costUSD: 0.09,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exactUsage, store: store)

        // Verify reporting now reflects exact values
        let exactSummary = allUsageSummaries(store)
        XCTAssertEqual(exactSummary.totalTokens, 2800, "Reporting must reflect upgraded exact tokens")
        XCTAssertEqual(exactSummary.totalCost, 0.09, accuracy: 0.001, "Reporting must reflect upgraded exact cost")

        // Verify canonical row was upgraded
        let row = try fetchCanonicalRow(queue: store.dbQueue, sessionId: sessionId)
        XCTAssertNotNil(row)
        XCTAssertEqual(extractInt(row!, column: "inputTokens"), 2000)
        XCTAssertEqual(row?["provenanceConfidence"] as? String, "exact")
        XCTAssertEqual(row?["projectName"] as? String, "ProjectUpdated")
    }

    /// Verifies that upgrading a usage row from estimate to exact does NOT cause
    /// unnecessary projection/indexing work when the conversation content itself
    /// has not changed. Token_usage changes are not index-coupled — only
    /// conversation content changes drive indexing.
    func test_lateExactUpgrade_doesNotTriggerUnnecessaryIndexing() async throws {
        let store = try makeInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "cross-v1", seed: "cross-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-cross-surface-1",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_743_100_000)

        // Step 1: Create and project a conversation, draining all initial jobs
        let conversation = makeConversation(
            id: "conv-cross-idx-1",
            fullText: String(repeating: "Test content for indexing. ", count: 50),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try await drainProjectionJobs(service)

        // Step 2: Record the projection state
        let documentsBefore = try store.fetchSearchDocuments(limit: 20)
        XCTAssertEqual(documentsBefore.count, 1)
        let chunksBefore = try store.fetchSearchChunks(documentID: documentsBefore[0].id)

        // Step 3: Insert an estimated usage row, then upgrade to exact
        let sessionId = "session-conv-cross-idx-1"
        let estimateUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 500,
            outputTokens: 200,
            costUSD: 0.02,
            startTime: base,
            endTime: base.addingTimeInterval(60),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try insertAndRefresh(usage: estimateUsage, store: store)

        let exactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "ProjectUpdated",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 400,
            costUSD: 0.04,
            startTime: base,
            endTime: base.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exactUsage, store: store)

        // Step 4: Run a sweep — should complete zero jobs since conversation content didn't change
        let secondReport = try await service.runSweep(maxJobs: 20)
        XCTAssertEqual(secondReport.completedJobs, 0,
            "Usage-only upgrades must not trigger projection rework when conversation content is unchanged")

        // Step 5: Verify indexing artifacts are unchanged
        let documentsAfter = try store.fetchSearchDocuments(limit: 20)
        XCTAssertEqual(documentsAfter.count, 1)
        let chunksAfter = try store.fetchSearchChunks(documentID: documentsAfter[0].id)
        XCTAssertEqual(chunksAfter.count, chunksBefore.count,
            "Chunk count must not change from usage-only upgrade")
    }

    /// Verifies that after an exact upgrade, provider summaries reflect the corrected data.
    func test_lateExactUpgrade_propagatesToProviderSummaries() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_743_200_000)

        // Insert estimated row for claudeCode
        let estimate1 = TokenUsage(
            provider: .claudeCode,
            sessionId: "cross-provider-1",
            projectName: "P1",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try insertAndRefresh(usage: estimate1, store: store)

        // Insert another session for same provider
        let estimate2 = TokenUsage(
            provider: .claudeCode,
            sessionId: "cross-provider-2",
            projectName: "P2",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 1000,
            costUSD: 0.10,
            startTime: baseDate.addingTimeInterval(120),
            endTime: baseDate.addingTimeInterval(180),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try insertAndRefresh(usage: estimate2, store: store)

        let summariesBefore = store.providerSummaries
        let claudeBefore = summariesBefore.first(where: { $0.provider == .claudeCode })
        XCTAssertEqual(claudeBefore?.totalCost ?? 0, 0.15, accuracy: 0.001)
        XCTAssertEqual(claudeBefore?.totalTokens, 4500)
        XCTAssertEqual(claudeBefore?.sessionCount, 2)

        // Upgrade session 1 to exact
        let exact1 = TokenUsage(
            provider: .claudeCode,
            sessionId: "cross-provider-1",
            projectName: "P1-Updated",
            model: "claude-4-sonnet",
            inputTokens: 3000,
            outputTokens: 1500,
            costUSD: 0.15,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exact1, store: store)

        let summariesAfter = store.providerSummaries
        let claudeAfter = summariesAfter.first(where: { $0.provider == .claudeCode })
        XCTAssertEqual(claudeAfter?.totalCost ?? 0, 0.25, accuracy: 0.001,
            "Provider summary must reflect upgraded exact cost")
        XCTAssertEqual(claudeAfter?.totalTokens, 7500,
            "Provider summary must reflect upgraded exact tokens")
        XCTAssertEqual(claudeAfter?.sessionCount, 2,
            "Session count must not change from upgrade")
    }

    // MARK: - VAL-CROSS-002: Repeated refreshes remain low-cost when data is unchanged

    /// Verifies that repeated projection sweeps on unchanged data complete zero jobs
    /// after draining the initial projection, demonstrating bounded incremental work.
    func test_repeatedProjectionSweeps_onUnchangedData_completeZeroAdditionalJobs() async throws {
        let store = try makeInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "refresh-v1", seed: "refresh-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-refresh-bounded",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_743_300_000)

        // Create and project a conversation, draining all initial jobs
        let conversation = makeConversation(
            id: "conv-refresh-1",
            fullText: String(repeating: "Refresh test content. ", count: 60),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        let initialCompleted = try await drainProjectionJobs(service)
        XCTAssertGreaterThan(initialCompleted, 0, "Initial drain must complete at least one job")

        // Subsequent sweeps: should complete zero jobs (no new work enqueued)
        let secondReport = try await service.runSweep(maxJobs: 20)
        XCTAssertEqual(secondReport.completedJobs, 0, "Second sweep must complete zero jobs")

        let thirdReport = try await service.runSweep(maxJobs: 20)
        XCTAssertEqual(thirdReport.completedJobs, 0, "Third sweep must complete zero jobs")
    }

    /// Verifies that conversation re-indexing (via ConversationIndexer) skips unchanged
    /// conversations and does not enqueue new projection work.
    func test_conversationReindex_onUnchangedContent_skipsAllRecords() async throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_743_400_000)

        // Insert conversation first (simulating prior index pass)
        let conversation = makeConversation(
            id: "conv-reindex-skip",
            fullText: "Stable content for re-index test.",
            indexedAt: base
        )
        try store.upsertConversation(conversation)

        // Re-index the same content — should be skipped
        let report1 = try await ConversationIndexer.shared.index([conversation], in: store)
        XCTAssertEqual(report1.skippedRecordCount, 1,
            "Re-indexing identical content must be skipped by ConversationIndexer")
        XCTAssertEqual(report1.changedRecordCount, 0)
        XCTAssertEqual(report1.enqueuedProjectionJobCount, 0)
    }

    /// Verifies that a full sweep after initial projection produces zero new embeddings
    /// when content is unchanged, proving embedding reuse works end-to-end.
    func test_repeatedSweeps_doNotRegenerateEmbeddings_forUnchangedContent() async throws {
        let store = try makeInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "embed-reuse-v1", seed: "embed-reuse-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-embed-reuse",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_743_500_000)

        let conversation = makeConversation(
            id: "conv-embed-reuse",
            fullText: String(repeating: "Embedding reuse test content. ", count: 40),
            indexedAt: base
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)

        // Drain initial projection
        _ = try await drainProjectionJobs(service)

        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        let embeddingsAfterFirst = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        let embeddingCountAfterFirst = embeddingsAfterFirst.count
        XCTAssertGreaterThan(embeddingCountAfterFirst, 0)

        // Subsequent sweeps: no new content, should not create additional embeddings
        let secondReport = try await service.runSweep(maxJobs: 20)
        XCTAssertEqual(secondReport.completedJobs, 0)

        let embeddingsAfterSecond = try store.fetchChunkEmbeddings(embeddingVersionID: versionID)
        XCTAssertEqual(embeddingsAfterSecond.count, embeddingCountAfterFirst,
            "Embedding count must not grow on repeated sweep with unchanged content")
    }

    /// Verifies the full pipeline remains bounded across multiple refresh-like cycles
    /// that include gap repair checks.
    func test_multipleGapRepairSweeps_onUnchangedData_performZeroReprojects() async throws {
        let store = try makeInMemoryStore()
        let embedder = DeterministicFakeEmbeddingProvider(versionTag: "gap-v1", seed: "gap-seed")
        let service = ProjectionPipelineService(
            dataStore: store,
            leaseOwner: "worker-gap-refresh",
            chunkEmbedder: embedder
        )
        let base = Date(timeIntervalSince1970: 1_743_600_000)

        // Create two conversations and project them, draining all initial jobs
        let conv1 = makeConversation(id: "conv-gap-1", fullText: "First conversation content.", indexedAt: base)
        let conv2 = makeConversation(id: "conv-gap-2", fullText: "Second conversation content.", indexedAt: base)
        try store.upsertConversation(conv1)
        try store.upsertConversation(conv2)
        try store.enqueueConversationProjectionJob(conversationID: conv1.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: conv2.id, jobType: .project, now: base)

        let initialCompleted = try await drainProjectionJobs(service)
        XCTAssertGreaterThanOrEqual(initialCompleted, 2, "Must complete both initial projection jobs")

        // Multiple gap repair sweeps — all should find no stale content
        for i in 1...3 {
            let report = try await service.runSweep(maxJobs: 20)
            XCTAssertEqual(report.completedJobs, 0,
                "Gap repair sweep \(i) must complete zero jobs when content is unchanged")
        }
    }

    // MARK: - VAL-CROSS-007: Event-path and reconciliation-path convergence

    /// Verifies that event-driven indexing (direct enqueue) and reconciliation-path
    /// indexing (gap repair detection) produce the same search document state for
    /// identical conversation content.
    func test_eventPath_and_reconciliationPath_produceConvergentResults() async throws {
        let base = Date(timeIntervalSince1970: 1_743_700_000)

        // --- Path A: Event-driven (direct enqueue) ---
        let storeA = try makeInMemoryStore()
        let embedderA = DeterministicFakeEmbeddingProvider(versionTag: "converge-v1", seed: "converge-seed-a")
        let serviceA = ProjectionPipelineService(
            dataStore: storeA,
            leaseOwner: "worker-event-path",
            chunkEmbedder: embedderA
        )

        let conversationA = makeConversation(
            id: "conv-converge",
            fullText: "Convergence test conversation content for both paths.",
            indexedAt: base
        )
        try storeA.upsertConversation(conversationA)
        try storeA.enqueueConversationProjectionJob(conversationID: conversationA.id, jobType: .project, now: base)

        _ = try await drainProjectionJobs(serviceA)

        // --- Path B: Reconciliation path (gap repair after initial projection with different content) ---
        let storeB = try makeInMemoryStore()
        let embedderB = DeterministicFakeEmbeddingProvider(versionTag: "converge-v1", seed: "converge-seed-b")
        let serviceB = ProjectionPipelineService(
            dataStore: storeB,
            leaseOwner: "worker-reconcile-path",
            chunkEmbedder: embedderB
        )

        // Insert initial content and project it
        let conversationBv1 = makeConversation(
            id: "conv-converge",
            fullText: "OLD content that will be updated.",
            indexedAt: base
        )
        try storeB.upsertConversation(conversationBv1)
        try storeB.enqueueConversationProjectionJob(conversationID: conversationBv1.id, jobType: .project, now: base)
        _ = try await drainProjectionJobs(serviceB)

        // Now update the conversation (simulating missed event) and trigger gap repair.
        // Preserve the same timestamps as Path A so the content hashes converge exactly.
        let conversationBv2 = ConversationRecord(
            id: "conv-converge",
            provider: conversationBv1.provider,
            sessionId: conversationBv1.sessionId,
            projectName: conversationBv1.projectName,
            startTime: conversationBv1.startTime,
            endTime: conversationBv1.endTime,
            messageCount: conversationBv1.messageCount,
            userWordCount: conversationBv1.userWordCount,
            assistantWordCount: conversationBv1.assistantWordCount,
            keyFiles: conversationBv1.keyFiles,
            keyCommands: conversationBv1.keyCommands,
            keyTools: conversationBv1.keyTools,
            inferredTaskTitle: conversationBv1.inferredTaskTitle,
            lastAssistantMessage: conversationBv1.lastAssistantMessage,
            fullText: "Convergence test conversation content for both paths.",
            indexedAt: base,
            fileModifiedAt: base,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: conversationBv1.sourceType
        )
        try storeB.upsertConversation(conversationBv2)

        // Gap repair should detect the stale hash and enqueue reproject
        let reconcileReport = try await drainProjectionJobs(serviceB)
        XCTAssertGreaterThanOrEqual(reconcileReport, 1,
            "Gap repair must enqueue and complete reproject for stale conversation")

        // --- Convergence check ---
        // Both paths should produce the same search document content hash
        let documentsA = try storeA.fetchSearchDocuments(limit: 20)
        let documentsB = try storeB.fetchSearchDocuments(limit: 20)
        XCTAssertEqual(documentsA.count, 1)
        XCTAssertEqual(documentsB.count, 1)

        let contentHashA = documentsA.first?.contentHash
        let contentHashB = documentsB.first?.contentHash
        XCTAssertEqual(contentHashA, contentHashB,
            "Event-path and reconciliation-path must produce identical content hashes")

        // Both paths should produce the same chunk count
        let chunksA = try storeA.fetchSearchChunks(documentID: documentsA[0].id)
        let chunksB = try storeB.fetchSearchChunks(documentID: documentsB[0].id)
        XCTAssertEqual(chunksA.count, chunksB.count,
            "Event-path and reconciliation-path must produce same chunk count")

        // Full text in the conversation record must match
        let finalConversationsA = try storeA.fetchConversations(ids: ["conv-converge"])
        let finalConversationsB = try storeB.fetchConversations(ids: ["conv-converge"])
        XCTAssertEqual(finalConversationsA.first?.fullText, finalConversationsB.first?.fullText,
            "Conversation fullText must converge between event and reconciliation paths")
    }

    /// Verifies that both event and reconciliation paths produce the same canonical
    /// usage row totals when the same usage data flows through each path.
    func test_eventPath_and_reconciliationPath_usageTotalsConverge() throws {
        let baseDate = Date(timeIntervalSince1970: 1_743_800_000)

        // --- Path A: Event-driven (direct insert) ---
        let storeA = try makeInMemoryStore()
        let usage1 = TokenUsage(
            provider: .claudeCode,
            sessionId: "converge-session-1",
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: usage1, store: storeA)

        // --- Path B: Reconciliation (insert estimate, then upgrade via reconciliation) ---
        let storeB = try makeInMemoryStore()
        let estimate = TokenUsage(
            provider: .claudeCode,
            sessionId: "converge-session-1",
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 800,  // Different estimate
            outputTokens: 400,
            costUSD: 0.04,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try insertAndRefresh(usage: estimate, store: storeB)

        // Reconciliation arrives with exact data
        let exact = TokenUsage(
            provider: .claudeCode,
            sessionId: "converge-session-1",
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exact, store: storeB)

        // --- Convergence check ---
        let summaryA = allUsageSummaries(storeA)
        let summaryB = allUsageSummaries(storeB)
        XCTAssertEqual(summaryA.totalTokens, summaryB.totalTokens,
            "Usage totals must converge between event-driven and reconciliation paths")
        XCTAssertEqual(summaryA.totalCost, summaryB.totalCost, accuracy: 0.0001,
            "Cost totals must converge between event-driven and reconciliation paths")

        // Canonical rows must have identical confidence after convergence
        let rowA = try fetchCanonicalRow(queue: storeA.dbQueue, sessionId: "converge-session-1")
        let rowB = try fetchCanonicalRow(queue: storeB.dbQueue, sessionId: "converge-session-1")
        XCTAssertEqual(rowA?["provenanceConfidence"] as? String, rowB?["provenanceConfidence"] as? String,
            "Both paths must converge to same provenance confidence")
        XCTAssertEqual(rowA?["provenanceConfidence"] as? String, "exact",
            "Both paths must converge to exact confidence")
    }

    /// Verifies that event-driven and reconciliation paths converge for multiple
    /// sessions with mixed exact/estimate provenance.
    func test_multiSession_eventAndReconciliation_convergeToIdenticalTotals() throws {
        let baseDate = Date(timeIntervalSince1970: 1_743_900_000)

        let sessions: [(sessionId: String, provider: AgentProvider, model: String,
                         input: Int, output: Int, cost: Double)] = [
            ("multi-conv-1", .claudeCode, "claude-4-sonnet", 2000, 1000, 0.10),
            ("multi-conv-2", .claudeCode, "claude-4-sonnet", 3000, 1500, 0.15),
            ("multi-conv-3", .factory, "glm-5", 4000, 2000, 0.08),
        ]

        // Path A: direct exact insert
        let storeA = try makeInMemoryStore()
        for s in sessions {
            let usage = TokenUsage(
                provider: s.provider,
                sessionId: s.sessionId,
                projectName: "Project",
                model: s.model,
                inputTokens: s.input,
                outputTokens: s.output,
                costUSD: s.cost,
                startTime: baseDate,
                endTime: baseDate.addingTimeInterval(60),
                provenanceMethod: .providerLog,
                provenanceConfidence: .exact,
                estimatorVersion: ""
            )
            try insertAndRefresh(usage: usage, store: storeA)
        }

        // Path B: estimate then exact reconciliation
        let storeB = try makeInMemoryStore()
        for s in sessions {
            let estimate = TokenUsage(
                provider: s.provider,
                sessionId: s.sessionId,
                projectName: "Project",
                model: s.model,
                inputTokens: s.input / 2,
                outputTokens: s.output / 2,
                costUSD: s.cost / 2,
                startTime: baseDate,
                endTime: baseDate.addingTimeInterval(60),
                provenanceMethod: .heuristicEstimate,
                provenanceConfidence: .lowConfidenceEstimate,
                estimatorVersion: "char-ratio-v1"
            )
            try insertAndRefresh(usage: estimate, store: storeB)
        }
        for s in sessions {
            let exact = TokenUsage(
                provider: s.provider,
                sessionId: s.sessionId,
                projectName: "Project",
                model: s.model,
                inputTokens: s.input,
                outputTokens: s.output,
                costUSD: s.cost,
                startTime: baseDate,
                endTime: baseDate.addingTimeInterval(60),
                provenanceMethod: .providerLog,
                provenanceConfidence: .exact,
                estimatorVersion: ""
            )
            try insertAndRefresh(usage: exact, store: storeB)
        }

        // Convergence check
        let summaryA = allUsageSummaries(storeA)
        let summaryB = allUsageSummaries(storeB)
        XCTAssertEqual(summaryA.totalTokens, summaryB.totalTokens,
            "Multi-session totals must converge between paths")
        XCTAssertEqual(summaryA.totalCost, summaryB.totalCost, accuracy: 0.0001,
            "Multi-session costs must converge between paths")

        // Row counts must be identical
        let countA = try countCanonicalRows(queue: storeA.dbQueue)
        let countB = try countCanonicalRows(queue: storeB.dbQueue)
        XCTAssertEqual(countA, countB,
            "Canonical row counts must converge")

        // Provider summaries must converge
        let providersA = storeA.providerSummaries
        let providersB = storeB.providerSummaries
        XCTAssertEqual(providersA.count, providersB.count,
            "Provider summary count must converge")
        for (pA, pB) in zip(providersA, providersB) {
            XCTAssertEqual(pA.totalTokens, pB.totalTokens,
                "Provider \(pA.provider.rawValue) token totals must converge")
            XCTAssertEqual(pA.totalCost, pB.totalCost, accuracy: 0.0001,
                "Provider \(pA.provider.rawValue) costs must converge")
        }
    }
}
