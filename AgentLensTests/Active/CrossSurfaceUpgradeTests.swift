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

    /// Helper: fetch all canonical token_usage rows
    private func fetchAllCanonicalRows(queue: DatabaseQueue) throws -> [Row] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM token_usage ORDER BY startTime DESC")
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

    // MARK: - VAL-CROSS-005: Provenance-aware reporting surface

    /// Verifies that provider summaries expose provenance/confidence metadata,
    /// distinguishing exact from fallback-derived values.
    func test_providerSummaries_exposeProvenanceAndConfidence() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_744_000_000)

        // Insert exact provider log usage
        let exactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "provenance-exact-1",
            projectName: "ExactProject",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 1000,
            costUSD: 0.10,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            usageSource: .providerLog,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exactUsage, store: store)

        // Insert heuristic estimate usage
        let estimateUsage = TokenUsage(
            provider: .cursor,
            sessionId: "provenance-estimate-1",
            projectName: "EstimateProject",
            model: "gpt-4",
            inputTokens: 3000,
            outputTokens: 1500,
            costUSD: 0.12,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            usageSource: .cursorBridge,
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try insertAndRefresh(usage: estimateUsage, store: store)

        // Verify provider summaries expose provenance
        let summaries = store.providerSummaries
        XCTAssertFalse(summaries.isEmpty, "Should have provider summaries")

        let claudeSummary = summaries.first(where: { $0.provider == .claudeCode })
        XCTAssertNotNil(claudeSummary, "Claude Code summary should exist")
        XCTAssertEqual(claudeSummary?.provenanceConfidence, .exact,
            "Claude Code should have exact provenance confidence")
        XCTAssertEqual(claudeSummary?.provenanceMethod, .providerLog,
            "Claude Code should have providerLog provenance method")
        XCTAssertFalse(claudeSummary?.hasEstimatedData ?? true,
            "Claude Code exact data should not be marked as estimated")

        let cursorSummary = summaries.first(where: { $0.provider == .cursor })
        XCTAssertNotNil(cursorSummary, "Cursor summary should exist")
        XCTAssertEqual(cursorSummary?.provenanceConfidence, .lowConfidenceEstimate,
            "Cursor estimate should have lowConfidenceEstimate provenance confidence")
        XCTAssertEqual(cursorSummary?.provenanceMethod, .heuristicEstimate,
            "Cursor estimate should have heuristicEstimate provenance method")
        XCTAssertTrue(cursorSummary?.hasEstimatedData ?? false,
            "Cursor estimate data should be marked as estimated")
    }

    /// Verifies that model breakdowns within provider summaries expose provenance.
    func test_modelBreakdown_exposesProvenancePerModel() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_744_100_000)

        // Insert exact and estimate usage for different models
        let exactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "model-prov-exact-1",
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 1000,
            costUSD: 0.10,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exactUsage, store: store)

        let estimateUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "model-prov-estimate-1",
            projectName: "Project",
            model: "claude-4-opus",
            inputTokens: 5000,
            outputTokens: 2500,
            costUSD: 0.30,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try insertAndRefresh(usage: estimateUsage, store: store)

        // Verify model breakdown exposes provenance
        let summaries = store.providerSummaries
        let claudeSummary = summaries.first(where: { $0.provider == .claudeCode })
        XCTAssertNotNil(claudeSummary)
        XCTAssertEqual(claudeSummary?.modelBreakdown.count, 2,
            "Should have breakdown for 2 models")

        let sonnetModel = claudeSummary?.modelBreakdown.first(where: { $0.modelName == "claude-4-sonnet" })
        XCTAssertNotNil(sonnetModel)
        XCTAssertEqual(sonnetModel?.provenanceConfidence, .exact,
            "Sonnet model should have exact confidence")
        XCTAssertEqual(sonnetModel?.provenanceMethod, .providerLog,
            "Sonnet model should have providerLog method")

        let opusModel = claudeSummary?.modelBreakdown.first(where: { $0.modelName == "claude-4-opus" })
        XCTAssertNotNil(opusModel)
        XCTAssertEqual(opusModel?.provenanceConfidence, .lowConfidenceEstimate,
            "Opus estimate should have lowConfidenceEstimate")
        XCTAssertEqual(opusModel?.provenanceMethod, .heuristicEstimate,
            "Opus estimate should have heuristicEstimate method")
    }

    // MARK: - VAL-CROSS-006: Confidence and precedence are auditable in datastore

    /// Verifies that for a fixed fixture set, datastore evidence demonstrates
    /// deterministic confidence ordering and canonical selection.
    func test_confidenceOrdering_deterministicSelection() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_744_200_000)

        // Insert multiple rows with different confidence levels for same session
        let lowEstimate = TokenUsage(
            provider: .claudeCode,
            sessionId: "confidence-ordering-test",
            projectName: "LowEstimate",
            model: "claude-4-sonnet",
            inputTokens: 500,
            outputTokens: 250,
            costUSD: 0.025,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try insertAndRefresh(usage: lowEstimate, store: store)

        let highEstimate = TokenUsage(
            provider: .claudeCode,
            sessionId: "confidence-ordering-test",
            projectName: "HighEstimate",
            model: "claude-4-sonnet",
            inputTokens: 800,
            outputTokens: 400,
            costUSD: 0.04,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .highConfidenceEstimate,
            estimatorVersion: "cjk-aware-v1"
        )
        try insertAndRefresh(usage: highEstimate, store: store)

        let exact = TokenUsage(
            provider: .claudeCode,
            sessionId: "confidence-ordering-test",
            projectName: "Exact",
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
        try insertAndRefresh(usage: exact, store: store)

        // Verify canonical row is exact (highest confidence wins)
        guard let canonicalRow = try fetchCanonicalRow(queue: store.dbQueue, sessionId: "confidence-ordering-test") else {
            XCTFail("Should have canonical row")
            return
        }

        XCTAssertEqual(canonicalRow["provenanceConfidence"] as? String, "exact",
            "Canonical row must have exact confidence (highest)")
        XCTAssertEqual(canonicalRow["provenanceMethod"] as? String, "provider_log",
            "Canonical row must have provider_log method")
        let inputTokens = extractInt(canonicalRow, column: "inputTokens")
        XCTAssertEqual(inputTokens, 1000,
            "Canonical row must have exact values")

        // Verify only one row exists
        let allRows = try fetchAllCanonicalRows(queue: store.dbQueue)
        let sameKeyRows = allRows.filter { $0["sessionId"] as? String == "confidence-ordering-test" }
        XCTAssertEqual(sameKeyRows.count, 1,
            "Exactly one canonical row must exist for the session")
    }

    /// Verifies that for non-upgraded rows, confidence ordering is preserved correctly.
    func test_confidenceOrdering_preservedForNonUpgradedRows() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_744_300_000)

        // Insert high confidence estimate (no exact arrives later)
        let highEstimate = TokenUsage(
            provider: .cursor,
            sessionId: "non-upgraded-session",
            projectName: "Project",
            model: "gpt-4",
            inputTokens: 2000,
            outputTokens: 800,
            costUSD: 0.08,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .highConfidenceEstimate,
            estimatorVersion: "cjk-aware-v2"
        )
        try insertAndRefresh(usage: highEstimate, store: store)

        // Insert another high confidence estimate (equal confidence, higher values)
        let anotherHighEstimate = TokenUsage(
            provider: .cursor,
            sessionId: "non-upgraded-session",
            projectName: "Project",
            model: "gpt-4",
            inputTokens: 2500,
            outputTokens: 1000,
            costUSD: 0.10,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .highConfidenceEstimate,
            estimatorVersion: "cjk-aware-v2"
        )
        try insertAndRefresh(usage: anotherHighEstimate, store: store)

        // Verify canonical row has the updated values (equal confidence allows update)
        guard let canonicalRow = try fetchCanonicalRow(queue: store.dbQueue, sessionId: "non-upgraded-session") else {
            XCTFail("Should have canonical row")
            return
        }

        XCTAssertEqual(canonicalRow["provenanceConfidence"] as? String, "high_confidence_estimate",
            "Confidence should remain highConfidenceEstimate (no exact arrived)")
        let inputTokens = extractInt(canonicalRow, column: "inputTokens")
        XCTAssertEqual(inputTokens, 2500,
            "Token values should be updated (equal confidence)")
    }

    // MARK: - VAL-CROSS-010: Filter/window parity after exact upgrades

    /// Verifies that provider-filtered summaries update correctly after exact upgrades.
    func test_filteredProviderSummary_parityAfterExactUpgrade() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_744_400_000)
        let calendar = Calendar.current
        let weekAhead = calendar.date(byAdding: .day, value: 7, to: baseDate) ?? baseDate
        let dateRange = baseDate...weekAhead

        // Insert estimate for claudeCode
        let estimateUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "filter-parity-estimate",
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

        // Get filtered summary before upgrade
        let summariesBefore = store.providerSummaries(in: dateRange)
        let claudeBefore = summariesBefore.first(where: { $0.provider == .claudeCode })
        XCTAssertEqual(claudeBefore?.totalCost ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(claudeBefore?.totalTokens ?? 0, 1500)

        // Upgrade to exact
        let exactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "filter-parity-estimate",
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 1000,
            costUSD: 0.10,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exactUsage, store: store)

        // Get filtered summary after upgrade
        let summariesAfter = store.providerSummaries(in: dateRange)
        let claudeAfter = summariesAfter.first(where: { $0.provider == .claudeCode })

        XCTAssertEqual(claudeAfter?.totalCost ?? 0, 0.10, accuracy: 0.001,
            "Filtered summary must reflect upgraded exact cost")
        XCTAssertEqual(claudeAfter?.totalTokens ?? 0, 3000,
            "Filtered summary must reflect upgraded exact tokens")
        XCTAssertEqual(claudeAfter?.provenanceConfidence ?? .unknown, .exact,
            "Filtered summary must show exact provenance after upgrade")
    }

    /// Verifies that time-window filtered summaries are parity-correct after exact upgrades.
    func test_timeWindowFilteredSummary_parityAfterExactUpgrade() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_744_500_000)
        let calendar = Calendar.current
        let windowStart = calendar.startOfDay(for: baseDate)
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: windowStart) ?? windowStart
        let dateRange = windowStart...windowEnd

        // Insert estimate
        let estimateUsage = TokenUsage(
            provider: .factory,
            sessionId: "window-parity-estimate",
            projectName: "Project",
            model: "glm-5",
            inputTokens: 1500,
            outputTokens: 750,
            costUSD: 0.06,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try insertAndRefresh(usage: estimateUsage, store: store)

        // Verify initial filtered summary
        let filteredBefore = store.providerSummaries(in: dateRange)
        let factoryBefore = filteredBefore.first(where: { $0.provider == .factory })
        XCTAssertEqual(factoryBefore?.totalCost ?? 0, 0.06, accuracy: 0.001)
        XCTAssertEqual(factoryBefore?.totalTokens ?? 0, 2250)

        // Upgrade to exact
        let exactUsage = TokenUsage(
            provider: .factory,
            sessionId: "window-parity-estimate",
            projectName: "Project",
            model: "glm-5",
            inputTokens: 3000,
            outputTokens: 1500,
            costUSD: 0.12,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exactUsage, store: store)

        // Verify filtered summary after upgrade
        let filteredAfter = store.providerSummaries(in: dateRange)
        let factoryAfter = filteredAfter.first(where: { $0.provider == .factory })

        XCTAssertEqual(factoryAfter?.totalCost ?? 0, 0.12, accuracy: 0.001,
            "Time-window filtered summary must reflect exact upgrade")
        XCTAssertEqual(factoryAfter?.totalTokens ?? 0, 4500,
            "Time-window filtered summary must reflect exact token counts")
        XCTAssertEqual(factoryAfter?.provenanceConfidence ?? .unknown, .exact,
            "Provenance must update to exact in filtered view")

        // Verify all-time summary also updated
        let allTimeSummaries = store.providerSummaries
        let factoryAllTime = allTimeSummaries.first(where: { $0.provider == .factory })
        XCTAssertEqual(factoryAllTime?.totalCost ?? 0, 0.12, accuracy: 0.001,
            "All-time summary must also reflect exact upgrade")
    }

    /// Verifies that after an exact upgrade, provider/project/time-window filtered outputs
    /// and retrieval summaries are consistent (VAL-CROSS-010).
    func test_filteredAndRetrievalSummaries_consistentAfterUpgrade() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_744_600_000)
        let calendar = Calendar.current
        let windowStart = calendar.startOfDay(for: baseDate)
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: windowStart) ?? windowStart
        let dateRange = windowStart...windowEnd

        // Mix of estimate and exact across providers
        let sessions: [(sessionId: String, provider: AgentProvider, exact: Bool, input: Int, output: Int, cost: Double)] = [
            ("multi-provider-1", AgentProvider.claudeCode, false, 500, 250, 0.025),
            ("multi-provider-2", AgentProvider.claudeCode, true, 2000, 1000, 0.10),
            ("multi-provider-3", AgentProvider.factory, false, 1000, 500, 0.04),
            ("multi-provider-4", AgentProvider.factory, true, 2000, 1000, 0.08),
        ]

        for s in sessions {
            let usage = TokenUsage(
                provider: s.provider,
                sessionId: s.sessionId,
                projectName: "Project",
                model: s.provider == .claudeCode ? "claude-4-sonnet" : "glm-5",
                inputTokens: s.input,
                outputTokens: s.output,
                costUSD: s.cost,
                startTime: baseDate,
                endTime: baseDate.addingTimeInterval(60),
                provenanceMethod: s.exact ? .providerLog : .heuristicEstimate,
                provenanceConfidence: s.exact ? .exact : .lowConfidenceEstimate,
                estimatorVersion: s.exact ? "" : "char-ratio-v1"
            )
            try insertAndRefresh(usage: usage, store: store)
        }

        // Get filtered summaries
        let filteredSummaries = store.providerSummaries(in: dateRange)
        let allTimeSummaries = store.providerSummaries

        // Both filtered and all-time should show same totals (all in same window)
        for provider in [AgentProvider.claudeCode, AgentProvider.factory] {
            let filtered = filteredSummaries.first(where: { $0.provider == provider })
            let allTime = allTimeSummaries.first(where: { $0.provider == provider })

            XCTAssertEqual(filtered?.totalCost ?? 0, allTime?.totalCost ?? 0, accuracy: 0.0001,
                "\(provider.rawValue): Filtered and all-time costs must match")
            XCTAssertEqual(filtered?.totalTokens ?? 0, allTime?.totalTokens ?? 0,
                "\(provider.rawValue): Filtered and all-time tokens must match")
            XCTAssertEqual(filtered?.provenanceConfidence ?? .unknown, allTime?.provenanceConfidence ?? .unknown,
                "\(provider.rawValue): Provenance confidence must match between filtered/all-time")
        }

        // Verify exact vs estimate markers are correct
        let claudeFiltered = filteredSummaries.first(where: { $0.provider == .claudeCode })
        XCTAssertEqual(claudeFiltered?.provenanceConfidence ?? .unknown, .exact,
            "Claude should show exact (session 2 was exact)")

        let factoryFiltered = filteredSummaries.first(where: { $0.provider == .factory })
        XCTAssertEqual(factoryFiltered?.provenanceConfidence ?? .unknown, .exact,
            "Factory should show exact (session 4 was exact)")
    }

    // MARK: - VAL-CROSS-005 / Mixed-Confidence Aggregate Semantics

    /// Verifies that provider summaries with mixed exact + estimated rows correctly
    /// report hasEstimatedContributions=true rather than using dominant-row confidence.
    /// This is the core fix for m4-fix-provider-summary-mixed-provenance-semantics.
    func test_mixedConfidenceAggregate_hasEstimatedContributions_reflectsMixedComposition() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_745_000_000)

        // Session 1: exact data
        let exact1 = TokenUsage(
            provider: .claudeCode,
            sessionId: "mixed-conf-exact-1",
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 5000,
            outputTokens: 2500,
            costUSD: 0.25,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exact1, store: store)

        // Session 2: estimated data (same provider, same model)
        let estimate1 = TokenUsage(
            provider: .claudeCode,
            sessionId: "mixed-conf-estimate-1",
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
        try insertAndRefresh(usage: estimate1, store: store)

        // Get provider summary
        let summaries = store.providerSummaries
        let claudeSummary = summaries.first(where: { $0.provider == .claudeCode })
        XCTAssertNotNil(claudeSummary, "Claude Code summary should exist")

        // The dominant confidence is exact (5000 tokens vs 1500 tokens, exact dominates)
        XCTAssertEqual(claudeSummary?.provenanceConfidence, .exact,
            "Dominant confidence should be exact (exact row has higher cost)")

        // But hasEstimatedContributions must be true because we have estimated rows
        XCTAssertTrue(claudeSummary?.hasEstimatedContributions ?? false,
            "hasEstimatedContributions must be true when aggregate includes estimated rows")
        XCTAssertTrue(claudeSummary?.hasEstimatedData ?? false,
            "hasEstimatedData must be true when aggregate includes estimated rows")

        // Model breakdown: same model has mixed exact + estimate
        let sonnetModel = claudeSummary?.modelBreakdown.first(where: { $0.modelName == "claude-4-sonnet" })
        XCTAssertNotNil(sonnetModel, "Sonnet model breakdown should exist")
        XCTAssertEqual(sonnetModel?.provenanceConfidence, .exact,
            "Model dominant confidence should be exact")
        XCTAssertTrue(sonnetModel?.hasEstimatedContributions ?? false,
            "Model hasEstimatedContributions must be true for mixed composition")
    }

    /// Verifies that a provider summary with only exact rows correctly reports
    /// hasEstimatedContributions=false.
    func test_allExactAggregate_hasEstimatedContributions_isFalse() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_745_100_000)

        // Two exact sessions
        let exact1 = TokenUsage(
            provider: .claudeCode,
            sessionId: "all-exact-1",
            projectName: "Project",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 1000,
            costUSD: 0.10,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exact1, store: store)

        let exact2 = TokenUsage(
            provider: .claudeCode,
            sessionId: "all-exact-2",
            projectName: "Project",
            model: "claude-4-opus",
            inputTokens: 10000,
            outputTokens: 5000,
            costUSD: 0.60,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exact2, store: store)

        let summaries = store.providerSummaries
        let claudeSummary = summaries.first(where: { $0.provider == .claudeCode })
        XCTAssertNotNil(claudeSummary)

        XCTAssertEqual(claudeSummary?.provenanceConfidence, .exact)
        XCTAssertFalse(claudeSummary?.hasEstimatedContributions ?? true,
            "hasEstimatedContributions must be false when all rows are exact")
        XCTAssertFalse(claudeSummary?.hasEstimatedData ?? false,
            "hasEstimatedData must be false when all rows are exact")

        // Both model breakdowns should also have hasEstimatedContributions=false
        let sonnetModel = claudeSummary?.modelBreakdown.first(where: { $0.modelName == "claude-4-sonnet" })
        let opusModel = claudeSummary?.modelBreakdown.first(where: { $0.modelName == "claude-4-opus" })
        XCTAssertFalse(sonnetModel?.hasEstimatedContributions ?? true)
        XCTAssertFalse(opusModel?.hasEstimatedContributions ?? true)
    }

    /// Verifies that derived-exact rows do not trigger hasEstimatedContributions=true.
    func test_derivedExactRows_doNotTrigger_hasEstimatedContributions() throws {
        let store = try makeInMemoryStore()
        let baseDate = Date(timeIntervalSince1970: 1_745_200_000)

        // One exact row and one derived-exact row (e.g., normalized from total_tokens)
        let exact = TokenUsage(
            provider: .cursor,
            sessionId: "derived-exact-1",
            projectName: "Project",
            model: "gpt-4",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.03,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .connectorBridge,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: exact, store: store)

        let derived = TokenUsage(
            provider: .cursor,
            sessionId: "derived-exact-2",
            projectName: "Project",
            model: "gpt-4",
            inputTokens: 2000,
            outputTokens: 1000,
            costUSD: 0.06,
            startTime: baseDate,
            endTime: baseDate.addingTimeInterval(60),
            provenanceMethod: .connectorBridge,
            provenanceConfidence: .derivedExact,
            estimatorVersion: ""
        )
        try insertAndRefresh(usage: derived, store: store)

        let summaries = store.providerSummaries
        let cursorSummary = summaries.first(where: { $0.provider == .cursor })
        XCTAssertNotNil(cursorSummary)

        // Both exact and derived-exact should NOT trigger hasEstimatedContributions
        XCTAssertFalse(cursorSummary?.hasEstimatedContributions ?? true,
            "hasEstimatedContributions must be false when all rows are exact or derived-exact")
        XCTAssertFalse(cursorSummary?.hasEstimatedData ?? false,
            "hasEstimatedData must be false when all rows are exact or derived-exact")
    }
}
