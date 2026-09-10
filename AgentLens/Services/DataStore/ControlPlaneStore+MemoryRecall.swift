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
    ///
    /// `actingAccountUserID` is the signed-in member the caller acts for
    /// (review #2565): the agent partition is account-scoped, so a mirrored row
    /// is readable only while it is unclaimed or claimed by that account. Every
    /// agent-lane mutation goes through this fetch, so the one guard covers
    /// verdict, edit and forget alike.
    func fetchMemoryAuthorityRecord(
        id: MemoryID,
        sourceKinds: Set<MemorySourceKind>,
        actingAccountUserID: String? = nil
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
            guard let memory = Self.memory(from: row, citations: citations),
                  Self.isAgentRowVisibleToAccount(memory, actingAccountUserID: actingAccountUserID) else {
                return nil
            }
            return memory
        }
    }

    /// The agent-partition account rule (review #2565): a daemon-mirrored row
    /// is visible to the signed-in member while unclaimed (`user_id` NULL/'')
    /// or claimed by that member, and invisible to everyone else — including a
    /// signed-out inbox, which sees only rows no account has claimed.
    static func isAgentRowVisibleToAccount(_ memory: Memory, actingAccountUserID: String?) -> Bool {
        guard memory.sourceKind == .agent else { return true }
        let owner = memory.scope.userID ?? ""
        return owner.isEmpty || owner == (actingAccountUserID ?? "")
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
    ///
    /// A mirrored row that is still in review has no body there: since the wire
    /// default became `quarantined`, `remember` records the engine id with an
    /// EMPTY body in `agent_memory_bodies` (so the sealed cloud document keeps
    /// its key) and parks the content in `memory_quarantine_bodies` instead.
    /// The review inbox has to show that content to be a review surface at all,
    /// so the resolution is: approved body first, quarantined body second. The
    /// order matters — it is what keeps the sync lane on approved content, since
    /// an approved row's quarantine copy is deleted the moment it is published.
    ///
    /// `actingAccountUserID` carries the signed-in member the review surface
    /// acts for (review #2565): the account guard from
    /// `fetchMemoryAuthorityRecord` applies to the body too, so one member's
    /// quarantined plaintext is never served to another.
    func openAgentMemoryBody(id: MemoryID, actingAccountUserID: String? = nil) async throws -> String? {
        guard try await fetchMemoryAuthorityRecord(id: id, sourceKinds: [.agent], actingAccountUserID: actingAccountUserID) != nil else {
            return nil
        }
        return try await dbQueue.read { db -> String? in
            if let published = try String.fetchOne(
                db,
                sql: "SELECT body FROM agent_memory_bodies WHERE memory_id = ?",
                arguments: [id]
            ), published.isEmpty == false {
                return published
            }
            return try String.fetchOne(
                db,
                sql: "SELECT body FROM memory_quarantine_bodies WHERE memory_id = ?",
                arguments: [id]
            )
        }
    }

    /// The sync lane's opener — deliberately NOT `openAgentMemoryBody` (review
    /// #2565): a row awaiting daemon publication has an EMPTY
    /// `agent_memory_bodies` body and the plaintext parked in quarantine, and
    /// the quarantine fallback would seal and upload unreviewed content. Only
    /// a landed publication — a non-empty body carrying the engine's
    /// `body_hash` the convergence fold keys on — is syncable.
    func syncableAgentMemoryBody(id: MemoryID) async throws -> String? {
        try await dbQueue.read { db -> String? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT body, body_hash FROM agent_memory_bodies WHERE memory_id = ?",
                arguments: [id]
            ) else { return nil }
            let body: String = row["body"] ?? ""
            let bodyHash: String = row["body_hash"] ?? ""
            return (body.isEmpty || bodyHash.isEmpty) ? nil : body
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
    /// blind-sync design): the row's tags, the engine's body hash, and the engine's
    /// own `(project_id, scope)` — the three parts of `UNIQUE(project_id, scope,
    /// body_hash)`, which folds a fact learned independently on two devices into
    /// one row on arrival. The payload's `scope` field is the app's `MemoryScope`
    /// and names no engine project, so the identity has to travel separately.
    struct MemoryCloudFactAttributes: Equatable, Sendable {
        let tags: [String]
        let bodyHash: String?
        let projectID: String?
        let engineScope: String?
    }

    func memoryCloudFactAttributes(id: MemoryID) async throws -> MemoryCloudFactAttributes {
        try await dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT tags_json, project_id, scope FROM agent_memories WHERE id = ?",
                arguments: [id]
            )
            let tagsJSON: String? = row?["tags_json"]
            let projectID: String? = row?["project_id"]
            let engineScope: String? = row?["scope"]
            let bodyHash = try String.fetchOne(
                db,
                sql: "SELECT body_hash FROM agent_memory_bodies WHERE memory_id = ?",
                arguments: [id]
            )
            var tags: [String] = []
            if let tagsJSON, let data = tagsJSON.data(using: .utf8) {
                // try?-ok(a malformed tags blob degrades to no tags; it must not fail the memory's upload)
                tags = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            }
            return MemoryCloudFactAttributes(
                tags: tags,
                bodyHash: (bodyHash?.isEmpty == false) ? bodyHash : nil,
                projectID: (projectID?.isEmpty == false) ? projectID : nil,
                engineScope: (engineScope?.isEmpty == false) ? engineScope : nil
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
        kind: MemoryKind? = nil,
        actingAccountUserID: String? = nil
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
            // The agent partition keeps no app scope. Those rows are the
            // daemon's: it writes them under its own per-project `project_id`
            // (which is not an app bucket) and knows no Firebase identity, so
            // `user_id`/`app_id` are NULL until the sync lane claims them
            // (`claimUnownedAgentMemories`). Applying either predicate would
            // return nothing, which is exactly why the review inbox could not see
            // a quarantined agent memory.
            //
            // What it is NOT is unscoped across accounts (review #2565): a
            // mirrored row is visible while unclaimed or claimed by the signed-
            // in member — a row claimed by account A must not render, open or
            // be actionable in account B's inbox on the same profile.
            if partition == .agent {
                predicates.append("(user_id IS NULL OR user_id = '' OR user_id = ?)")
                arguments.append(actingAccountUserID ?? "")
            } else if let scope {
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
    ///
    /// `actingAccountUserID` is the member the surface acts for (review #2565):
    /// the agent partition applies its unclaimed-or-mine rule to it.
    func memoryPage(
        _ request: MemoryPageRequest,
        sourceKinds: Set<MemorySourceKind>,
        actingAccountUserID: String? = nil
    ) async throws -> MemoryPage {
        var fetched: [Memory] = []
        for partitionKinds in Self.memoryPartitionedSourceKinds(sourceKinds) {
            fetched += try await fetchActiveMemoryAuthorityRecords(
                sourceKinds: partitionKinds,
                scope: request.scope,
                actingAccountUserID: actingAccountUserID
            )
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

    /// Pending (quarantined) agent-lane rows — the agent share of the dashboard
    /// Memory badge, so the badge and the inbox's own pill count the same rows.
    /// It takes no scope on purpose: the daemon writes these rows under its own
    /// project id and no app scope columns.
    ///
    /// One `COUNT(*)` query (review #2565): the badge used to hydrate every
    /// mirrored row plus its provenance just to count it — the count is read on
    /// every dashboard render, so it pays the number only. `accountUserID`
    /// scopes the count the same way `fetchActiveMemoryAuthorityRecords` does —
    /// unclaimed or claimed by the signed-in member — so the badge never
    /// advertises rows this account cannot act on.
    func pendingAgentMemoryReviewCount(accountUserID: String?) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM agent_memories
                WHERE source_kind = ?
                  AND valid_to IS NULL
                  AND review_status = ?
                  AND (user_id IS NULL OR user_id = '' OR user_id = ?)
                """,
                arguments: [
                    MemorySourceKind.agent.rawValue,
                    MemoryReviewStatus.quarantined.rawValue,
                    accountUserID ?? ""
                ]
            ) ?? 0
        }
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
