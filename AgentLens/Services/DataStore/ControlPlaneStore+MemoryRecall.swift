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
        // The agent-corpus branch: a prefixed thread id reads the indexed
        // `conversations` row (28 providers' sessions) and splits it into
        // deterministic citable turns. Same seam, second source — the extractor
        // and the provenance-recomputing worker stay source-agnostic.
        if let conversationID = AgentConversationExtractionSource.conversationID(fromThreadID: threadID) {
            return try await fetchAgentConversationTranscriptForExtraction(conversationID: conversationID)
        }
        return try await dbQueue.read { db in
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

    /// Fetch an indexed agent conversation as extraction turns. Empty when the
    /// conversation is missing, tombstoned, or has no extractable text.
    func fetchAgentConversationTranscriptForExtraction(conversationID: String) async throws -> [ChatTranscriptMessage] {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, fullText, startTime, endTime
                FROM conversations
                WHERE id = ? AND deletedAt IS NULL
                LIMIT 1
                """,
                arguments: [conversationID]
            ),
                  let id = row["id"] as? String,
                  let fullText = row["fullText"] as? String else {
                return []
            }
            let anchor = OpenBurnBarDatabase.parseDateValue(row["endTime"])
                ?? OpenBurnBarDatabase.parseDateValue(row["startTime"])
                ?? Date(timeIntervalSince1970: 0)
            return AgentConversationExtractionSource.splitTranscript(
                conversationID: id,
                fullText: fullText,
                anchoredAt: anchor
            )
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
        // Conversation-sourced citations resolve against the same deterministic
        // turn split the extractor prompted with; an id the split no longer
        // produces (the session file grew mid-job) returns nil and the caller
        // drops the citation — never fabricates provenance.
        if AgentConversationExtractionSource.conversationID(fromThreadID: threadID) != nil {
            let transcript = try await fetchChatTranscriptForExtraction(threadID: threadID)
            return transcript.first { $0.id == messageID }
        }
        return try await dbQueue.read { db in
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

    /// Memories the Memory MCP engine mirrored keep their approved body in
    /// `agent_memory_bodies` (written by the daemon) rather than in the app's
    /// snapshot table, so the sync lane resolves a body from either home.
    func openAgentMemoryBody(id: MemoryID) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT body FROM agent_memory_bodies WHERE memory_id = ?", arguments: [id])
        }
    }

    /// The id a memory's blinded cloud document is keyed on: the engine's own
    /// 128-bit id for a mirrored row, the local id otherwise. Upload and delete
    /// must agree on this or a forget cannot reach the sealed copy. The mapping
    /// survives a forget — the body is purged, the label is not.
    func cloudFactIdentity(for id: MemoryID) async throws -> String {
        try await engineMemoryID(for: id) ?? id
    }

    /// The engine's own 128-bit memory id for a mirrored row. The daemon id is
    /// derived from `projectID:bodyHash` and differs between a member's devices;
    /// the engine id is what a blinded sync document keys on.
    func engineMemoryID(for id: MemoryID) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT engine_memory_id FROM agent_memory_bodies WHERE memory_id = ?",
                arguments: [id]
            )
        }
    }

    /// Convergence metadata a mirrored memory's sealed payload carries (§5 of the
    /// blind-sync design): the row's tags and the engine's body hash, which
    /// `UNIQUE(project_id, scope, body_hash)` uses to fold a fact learned
    /// independently on two devices into one row on arrival.
    struct MemoryCloudFactAttributes: Equatable, Sendable {
        let tags: [String]
        let bodyHash: String?
    }

    func memoryCloudFactAttributes(id: MemoryID) async throws -> MemoryCloudFactAttributes {
        try await dbQueue.read { db in
            let tagsJSON = try String.fetchOne(
                db,
                sql: "SELECT tags_json FROM agent_memories WHERE id = ?",
                arguments: [id]
            )
            let bodyHash = try String.fetchOne(
                db,
                sql: "SELECT body_hash FROM agent_memory_bodies WHERE memory_id = ?",
                arguments: [id]
            )
            var tags: [String] = []
            if let tagsJSON, let data = tagsJSON.data(using: .utf8) {
                tags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            }
            return MemoryCloudFactAttributes(
                tags: tags,
                bodyHash: (bodyHash?.isEmpty == false) ? bodyHash : nil
            )
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
        try await memoryPage(request, sourceKinds: [.chat])
    }

    /// Review-inbox page across source kinds (U7). Chat and usage rows live in
    /// different storage partitions (`chat:` vs `usage:` project buckets), so a
    /// scoped fetch must run once per partition; the union then goes through the
    /// exact filter/sort/paginate pipeline `chatMemoryPage` shipped with. With
    /// `[.chat]` this is a single chat-partition fetch — byte-identical to the
    /// pre-U7 `chatMemoryPage`.
    func memoryPage(
        _ request: MemoryPageRequest,
        sourceKinds: Set<MemorySourceKind>
    ) async throws -> MemoryPage {
        var fetched: [Memory] = []
        for partitionKinds in Self.memoryPartitionedSourceKinds(sourceKinds) {
            fetched += try await fetchActiveMemoryAuthorityRecords(sourceKinds: partitionKinds, scope: request.scope)
        }
        let records = fetched
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

    /// Pending (quarantined) usage-kind rows for `scope` — the count behind the
    /// "Usage memory proposals: N pending" link-outs and the usage share of the
    /// dashboard Memory badge. Mirrors `pendingChatMemoryReviewCount` over the
    /// `usage:` partition.
    func pendingUsageMemoryReviewCount(scope: MemoryScope) async throws -> Int {
        try await fetchActiveMemoryAuthorityRecords(sourceKinds: MemorySourceKind.usageKinds, scope: scope)
            .filter { $0.reviewStatus == .quarantined }
            .count
    }

    func searchChatMemoryAuthorityRecords(_ query: MemoryQuery) async throws -> [Memory] {
        let records = try await fetchActiveChatMemoryAuthorityRecords(scope: query.scope)
            .filter { $0.reviewStatus != .rejected }
        var scored: [(memory: Memory, score: Double)] = []
        scored.reserveCapacity(records.count)
        for memory in records {
            guard try await memoryHasTombstonedSource(id: memory.id) == false else { continue }
            let body = try await openChatMemoryBody(id: memory.id) ?? ""
            scored.append((memory, Self.memoryTextScore(query: query.text, text: body) + memory.confidence))
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
        var ranked: [(memory: Memory, text: String, tokenEstimate: Int, score: Double)] = []
        ranked.reserveCapacity(records.count)
        for memory in records {
            guard try await memoryHasTombstonedSource(id: memory.id) == false else { continue }
            guard let body = try await openChatMemoryBody(id: memory.id), body.isEmpty == false else {
                continue
            }
            let tokenEstimate = Self.memoryTokenEstimate(body)
            let score = Self.memoryTextScore(query: request.query, text: body) + memory.confidence
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
