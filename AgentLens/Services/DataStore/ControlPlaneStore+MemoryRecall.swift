import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

extension ControlPlaneStore {
    func fetchChatMemoryAuthorityRecord(id: MemoryID) async throws -> Memory? {
        try await fetchMemoryAuthorityRecord(id: id, sourceKinds: [.chat])
    }

    /// Fetch one authority row by id, guarded to the caller's source kinds so
    /// chat/usage code paths can never touch daemon-owned `code` rows (or each
    /// other) by accident.
    func fetchMemoryAuthorityRecord(
        id: MemoryID,
        sourceKinds: Set<MemorySourceKind>
    ) async throws -> Memory? {
        let kindClause = Self.memorySourceKindInClause(column: "source_kind", kinds: sourceKinds)
        return try await dbQueue.read { db in
            var arguments: [any DatabaseValueConvertible] = [id]
            arguments.append(contentsOf: kindClause.arguments)
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM agent_memories
                WHERE id = ? AND \(kindClause.sql)
                LIMIT 1
                """,
                arguments: StatementArguments(arguments)
            ) else {
                return nil
            }

            let citationRows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM memory_provenance
                WHERE memory_id = ?
                ORDER BY authored_at ASC, occurrence ASC, id ASC
                """,
                arguments: [id]
            )
            let citations = citationRows.compactMap(Self.memoryCitation(from:))
            return Self.memory(from: row, citations: citations)
        }
    }

    /// Fetch the chat transcript for `threadID` as the lightweight provenance view the
    /// extractor reasons over and the worker cites. Reads `chat_messages` from the
    /// shared db queue (the control-plane store and the chat store share one queue), so
    /// the worker can recompute provenance without a second store handle. Tool/system
    /// rows are excluded: only user/assistant turns are citable provenance (G8).
    func fetchChatTranscriptForExtraction(threadID: String) async throws -> [ChatTranscriptMessage] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, role, content, timestamp
                FROM chat_messages
                WHERE threadId = ? AND role IN ('user', 'assistant')
                ORDER BY timestamp ASC, id ASC
                """,
                arguments: [threadID]
            )
            return rows.compactMap { row -> ChatTranscriptMessage? in
                guard let id = row["id"] as? String,
                      let role = row["role"] as? String,
                      let content = row["content"] as? String,
                      let authoredAt = OpenBurnBarDatabase.parseDateValue(row["timestamp"]) else {
                    return nil
                }
                return ChatTranscriptMessage(id: id, role: role, body: content, authoredAt: authoredAt)
            }
        }
    }

    /// Fetch a single citable source message by id, scoped to the job's thread, for
    /// worker-side provenance recomputation (PR-D1 must-fix #1/#3). Returns nil when the
    /// message is absent or not a user/assistant turn — the caller then drops the
    /// citation rather than fabricating provenance.
    func fetchChatProvenanceSourceMessage(
        threadID: String,
        messageID: String
    ) async throws -> ChatTranscriptMessage? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, role, content, timestamp
                FROM chat_messages
                WHERE threadId = ? AND id = ? AND role IN ('user', 'assistant')
                LIMIT 1
                """,
                arguments: [threadID, messageID]
            ),
                  let id = row["id"] as? String,
                  let role = row["role"] as? String,
                  let content = row["content"] as? String,
                  let authoredAt = OpenBurnBarDatabase.parseDateValue(row["timestamp"]) else {
                return nil
            }
            return ChatTranscriptMessage(id: id, role: role, body: content, authoredAt: authoredAt)
        }
    }

    func openChatMemoryBody(id: MemoryID) async throws -> String? {
        let snapshotSlug = Self.memorySnapshotSlug(id)
        return try await dbQueue.read { db in
            guard let snapshotJSON = try String.fetchOne(
                db,
                sql: "SELECT snapshot_json FROM memory_body_snapshots WHERE id = ? AND memory_id = ?",
                arguments: [snapshotSlug, id]
            ),
                  let data = snapshotJSON.data(using: .utf8)
            else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(MemoryBodySnapshot.self, from: data).body
        }
    }

    func fetchActiveChatMemoryAuthorityRecords(scope: MemoryScope? = nil, kind: MemoryKind? = nil) async throws -> [Memory] {
        try await fetchActiveMemoryAuthorityRecords(sourceKinds: [.chat], scope: scope, kind: kind)
    }

    func fetchActiveMemoryAuthorityRecords(
        sourceKinds: Set<MemorySourceKind>,
        scope: MemoryScope? = nil,
        kind: MemoryKind? = nil
    ) async throws -> [Memory] {
        let kindClause = Self.memorySourceKindInClause(column: "source_kind", kinds: sourceKinds)
        let partition = MemoryStoragePartition(sourceKinds)
        return try await dbQueue.read { db in
            var predicates = [kindClause.sql, "valid_to IS NULL"]
            var arguments: [any DatabaseValueConvertible] = kindClause.arguments
            if let kind {
                predicates.append("kind = ?")
                arguments.append(kind.rawValue)
            }
            if let scope {
                predicates.append("project_id = ?")
                arguments.append(Self.memoryStorageProjectID(for: scope, partition: partition))
                Self.appendScopePredicates(scope, to: &predicates, arguments: &arguments)
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM agent_memories
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY confidence DESC, valid_from ASC, id ASC
                """,
                arguments: StatementArguments(arguments)
            )
            return try rows.compactMap { row in
                guard let id: String = row["id"] else { return nil }
                let citationRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT *
                    FROM memory_provenance
                    WHERE memory_id = ?
                    ORDER BY authored_at ASC, occurrence ASC, id ASC
                    """,
                    arguments: [id]
                )
                return Self.memory(from: row, citations: citationRows.compactMap(Self.memoryCitation(from:)))
            }
        }
    }

    func chatMemoryPage(_ request: MemoryPageRequest) async throws -> MemoryPage {
        let records = try await fetchActiveChatMemoryAuthorityRecords(scope: request.scope)
            .filter { memory in
                if memory.reviewStatus == .rejected { return false }
                return request.includeQuarantined || memory.reviewStatus == .approved
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.id < rhs.id }
                return lhs.updatedAt > rhs.updatedAt
            }
        let pageSize = max(1, request.pageSize)
        let page = max(1, request.page)
        let start = max(0, (page - 1) * pageSize)
        return MemoryPage(
            items: Array(records.dropFirst(start).prefix(pageSize)),
            page: page,
            pageSize: pageSize,
            total: records.count
        )
    }

    func pendingChatMemoryReviewCount(scope: MemoryScope) async throws -> Int {
        try await fetchActiveChatMemoryAuthorityRecords(scope: scope)
            .filter { $0.reviewStatus == .quarantined }
            .count
    }

    func searchChatMemoryAuthorityRecords(_ query: MemoryQuery) async throws -> [Memory] {
        let records = try await fetchActiveChatMemoryAuthorityRecords(scope: query.scope)
            .filter { $0.reviewStatus != .rejected }
        // PR8 salience-aware ranking: `+ 0.3 · clamp(salience, 0, 1)` from the
        // sidecar (the LEFT JOIN surfaces as a batched map because scoring
        // happens in Swift). An absent row contributes exactly 0.0, keeping a
        // salience-free database's ordering byte-identical to pre-PR8.
        let salienceByID = try await memorySalienceValues(ids: records.map(\.id))
        var scored: [(memory: Memory, score: Double)] = []
        scored.reserveCapacity(records.count)
        for memory in records {
            guard try await memoryHasTombstonedSource(id: memory.id) == false else { continue }
            let body = try await openChatMemoryBody(id: memory.id) ?? ""
            let salienceBoost = Self.memorySalienceRecallWeight
                * min(max(salienceByID[memory.id] ?? 0, 0), 1)
            scored.append(
                (memory, Self.memoryTextScore(query: query.text, text: body) + memory.confidence + salienceBoost)
            )
        }
        return scored.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
            return lhs.score > rhs.score
        }
        .prefix(max(1, query.limit))
        .map(\.memory)
    }

    func recallChatMemorySnippets(_ request: MemoryRecallRequest) async throws -> [MemorySnippet] {
        guard request.tokenBudget > 0, request.limit > 0 else { return [] }
        let records = try await fetchActiveChatMemoryAuthorityRecords(scope: request.scope)
            .filter { $0.reviewStatus == .approved && $0.validTo == nil }
        // PR8 salience-aware ranking; see `searchChatMemoryAuthorityRecords`.
        // Absent sidecar rows contribute exactly 0.0 — a salience-free
        // database ranks byte-identically to pre-PR8 (regression-pinned).
        let salienceByID = try await memorySalienceValues(ids: records.map(\.id))
        var ranked: [(memory: Memory, text: String, tokenEstimate: Int, score: Double)] = []
        ranked.reserveCapacity(records.count)
        for memory in records {
            guard try await memoryHasTombstonedSource(id: memory.id) == false else { continue }
            guard let body = try await openChatMemoryBody(id: memory.id), body.isEmpty == false else {
                continue
            }
            let tokenEstimate = Self.memoryTokenEstimate(body)
            let salienceBoost = Self.memorySalienceRecallWeight
                * min(max(salienceByID[memory.id] ?? 0, 0), 1)
            let score = Self.memoryTextScore(query: request.query, text: body)
                + memory.confidence
                + salienceBoost
            ranked.append((memory, body, tokenEstimate, score))
        }

        var spent = 0
        var snippets: [MemorySnippet] = []
        // Each snippet is wrapped in the LLMSafeContent.wrapUntrusted envelope (open tag +
        // provenance + close tag + the multi-sentence CRITICAL RULE) before it reaches the
        // prompt. Charge that fixed per-snippet overhead here so the budget reflects the
        // WRAPPED size that the arbiter actually sees — otherwise the assembled `.memory`
        // section overflows the arbiter's memory cap and gets truncated (M2 audit finding).
        let wrapperOverhead = MemoryRecallBudget.wrapperTokenOverhead
        for item in ranked.sorted(by: { lhs, rhs in
            if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
            return lhs.score > rhs.score
        }) {
            guard snippets.count < request.limit else { break }
            // Cost the WRAPPED snippet in the arbiter's prose token units (chars/3.5),
            // matching how PromptTokenArbiter measures the .memory section, so a set that
            // fits this budget also fits the arbiter cap (request.tokenBudget IS that cap).
            let wrappedCost = PromptTokenArbiter.estimateProseTokens(item.text) + wrapperOverhead
            guard wrappedCost <= request.tokenBudget - spent else { continue }
            spent += wrappedCost
            snippets.append(
                MemorySnippet(
                    memoryID: item.memory.id,
                    text: item.text,
                    kind: item.memory.kind,
                    confidence: item.memory.confidence,
                    citations: item.memory.citations,
                    trustTier: .untrusted,
                    tokenCountEstimate: item.tokenEstimate
                )
            )
        }
        return snippets
    }

}
