import CryptoKit
import Foundation
@preconcurrency import GRDB
import OpenBurnBarCore

extension ControlPlaneStore {
    struct MemorySourceTombstoneRecord: Equatable, Sendable {
        let id: String
        let userID: String?
        let threadLogicalID: String
        let messageID: String?
        let contentHash: String?
        let reason: String
        let createdAt: Date
    }

    struct MemoryFactTombstoneSourceRef: Codable, Equatable, Sendable {
        let threadLogicalID: String
        let messageID: String?
        let contentHash: String
    }

    struct MemoryFactTombstoneRecord: Equatable, Sendable {
        let id: String
        let userID: String
        let memoryID: MemoryID
        let sourceRefs: [MemoryFactTombstoneSourceRef]
        let reason: String
        let createdAt: Date
    }

    func recordMemorySourceTombstone(
        userID: String?,
        threadLogicalID: String,
        messageID: String?,
        contentHash: String?,
        reason: String,
        now: Date = Date()
    ) async throws -> String {
        let id = Self.memorySourceTombstoneID(
            threadLogicalID: threadLogicalID,
            messageID: messageID,
            contentHash: contentHash,
            reason: reason
        )
        try await dbQueue.write { db in
            try Self.insertMemorySourceTombstone(
                db: db,
                id: id,
                userID: userID,
                threadLogicalID: threadLogicalID,
                messageID: messageID,
                contentHash: contentHash,
                reason: reason,
                now: now
            )
        }
        return id
    }

    func reconcileMemorySourceTombstones(now: Date = Date()) async throws -> Int {
        let nowString = Self.iso8601String(now)
        return try await dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT m.id, m.project_id
                FROM agent_memories m
                JOIN memory_provenance p
                  ON p.memory_id = m.id
                JOIN memory_source_tombstones t
                  ON t.thread_logical_id = p.thread_logical_id
                 AND (t.message_id IS NULL OR t.message_id = p.message_id)
                 AND (t.content_hash IS NULL OR t.content_hash = p.content_hash)
                WHERE m.source_kind = ?
                  AND m.valid_to IS NULL
                """,
                arguments: [MemorySourceKind.chat.rawValue]
            )
            var suppressed = 0
            for row in rows {
                guard let memoryID: String = row["id"],
                      let projectID: String = row["project_id"] else {
                    continue
                }
                try db.execute(
                    sql: """
                    UPDATE agent_memories
                    SET valid_to = ?,
                        updated_at = ?
                    WHERE id = ?
                      AND source_kind = ?
                      AND valid_to IS NULL
                    """,
                    arguments: [now, now, memoryID, MemorySourceKind.chat.rawValue]
                )
                let auditLabels = [
                    "memory_id:\(memoryID)",
                    "reason:source_tombstone",
                    "source_kind:\(MemorySourceKind.chat.rawValue)"
                ]
                try Self.insertMemoryAuditEvent(
                    db: db,
                    action: "memory.source_tombstone_suppressed",
                    projectID: projectID,
                    subjectID: memoryID,
                    labels: auditLabels,
                    nowString: nowString
                )
                suppressed += 1
            }
            return suppressed
        }
    }

    /// The daemon writes mirrored rows with no `user_id`: it has no Firebase
    /// identity and cannot know who is signed in. The engine store is per-macOS-user,
    /// so the first signed-in member to sync claims those rows; a row already owned
    /// by a different account is left alone and never replicated under this one.
    @discardableResult
    func claimUnownedAgentMemories(userID: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE agent_memories SET user_id = ?
                WHERE source_kind = ? AND (user_id IS NULL OR user_id = '')
                """,
                arguments: [userID, MemorySourceKind.agent.rawValue]
            )
            return db.changesCount
        }
    }

    /// The daemon marks a forgotten mirrored memory `forgotten` in the shared
    /// database, but it cannot write a fact tombstone: that table is keyed by the
    /// signed-in member, whom the daemon does not know. Without one, nothing ever
    /// deletes the sealed cloud copy of a memory the member removed. The sync lane
    /// therefore enqueues the missing tombstones itself, once, before it drains them.
    ///
    /// Two properties of mirrored rows shape the query and the tombstone id:
    ///
    /// * The cloud document is keyed on the engine's memory id, not the local one.
    ///   The local id (`projectID:scope:bodyHash`) is stable when the engine
    ///   re-learns the same text, but the engine id is fresh each time, so a
    ///   re-learned memory is a *new* document. A tombstone keyed only on the local
    ///   id would collide with the drained one from the first forget and the second
    ///   document would never be deleted. The tombstone id therefore includes the
    ///   engine id the mapping holds at enqueue time.
    /// * A memory can leave the uploadable set without being forgotten: the daemon
    ///   may remirror an approved, already uploaded memory as quarantined or
    ///   rejected. The daemon keeps the engine-id mapping in that case, so any
    ///   mapped row that is no longer approved gets a tombstone, mirroring what
    ///   `setMemoryReviewStatus` does for chat memories.
    ///
    /// The drain resolves the cloud identity from the *current* mapping. If the
    /// engine re-learns and the member forgets again before a single sync runs,
    /// the earlier document is left behind; closing that needs the tombstone to
    /// carry its own cloud identity, which is a schema change reserved for the
    /// pull half (see docs/superpowers/plans/2026-09-03-memory-blind-sync.md).
    @discardableResult
    func enqueueTombstonesForUnsyncableAgentMemories(userID: String, now: Date = Date()) async throws -> Int {
        let timestamp = ISO8601DateFormatter().string(from: now)
        return try await dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.id AS id, b.engine_memory_id AS engine_memory_id
                FROM agent_memories m
                LEFT JOIN agent_memory_bodies b ON b.memory_id = m.id
                WHERE m.source_kind = ? AND m.user_id = ?
                  AND (
                    m.review_status = ?
                    OR (b.memory_id IS NOT NULL AND m.review_status != ?)
                  )
                """,
                arguments: [
                    MemorySourceKind.agent.rawValue,
                    userID,
                    MemoryReviewStatus.forgotten.rawValue,
                    MemoryReviewStatus.approved.rawValue
                ]
            )
            var enqueued = 0
            for row in rows {
                guard let memoryID: String = row["id"] else { continue }
                let engineMemoryID: String? = row["engine_memory_id"]
                // A mirrored memory has no chat citations, so the receipt carries no
                // source hashes — only the opaque memory label and a coarse reason.
                try db.execute(
                    sql: """
                    INSERT INTO memory_fact_tombstones (
                        id, user_id, memory_id, source_refs_json, reason, created_at, replicated_at
                    ) VALUES (?, ?, ?, '[]', 'user_delete', ?, NULL)
                    ON CONFLICT(id) DO NOTHING
                    """,
                    arguments: [
                        Self.agentMemoryFactTombstoneID(memoryID: memoryID, engineMemoryID: engineMemoryID),
                        userID,
                        memoryID,
                        timestamp
                    ]
                )
                enqueued += db.changesCount
            }
            return enqueued
        }
    }

    /// One tombstone per (memory, engine generation). A row that was never mapped
    /// (forgotten before it was ever approved, or a pre-mapping legacy row) falls
    /// back to the plain memory id, which is also the id the chat path uses.
    static func agentMemoryFactTombstoneID(memoryID: MemoryID, engineMemoryID: String?) -> String {
        guard let engineMemoryID, engineMemoryID.isEmpty == false else {
            return memoryFactTombstoneID(memoryID: memoryID)
        }
        return memoryFactTombstoneID(memoryID: "\(memoryID)#engine:\(engineMemoryID)")
    }

    /// Rows the cloud lane may replicate: member-authored chat memories and the
    /// memories the Memory MCP engine mirrored (`agent`). Repository knowledge
    /// (`code`) and the passive usage kinds never leave the device.
    func cloudSyncCandidateChatMemories(userID: String) async throws -> [Memory] {
        try await claimUnownedAgentMemories(userID: userID)
        return try await fetchActiveMemoryAuthorityRecords(sourceKinds: [.chat, .agent])
            .filter { memory in
                memory.reviewStatus == .approved &&
                memory.validTo == nil &&
                memory.scope.userID == userID
            }
    }

    func cloudSyncEligibleChatMemories(userID: String) async throws -> [Memory] {
        var eligible: [Memory] = []
        for memory in try await cloudSyncCandidateChatMemories(userID: userID) {
            guard try await memoryHasTombstonedSource(id: memory.id) == false else { continue }
            eligible.append(memory)
        }
        return eligible
    }

    func fetchPendingMemorySourceTombstones(userID: String) async throws -> [MemorySourceTombstoneRecord] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM memory_source_tombstones
                WHERE user_id = ?
                  AND replicated_at IS NULL
                ORDER BY created_at ASC, id ASC
                """,
                arguments: [userID]
            )
            return rows.compactMap(Self.memorySourceTombstone(from:))
        }
    }

    func fetchPendingMemoryFactTombstones(userID: String) async throws -> [MemoryFactTombstoneRecord] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM memory_fact_tombstones
                WHERE user_id = ?
                  AND replicated_at IS NULL
                ORDER BY created_at ASC, id ASC
                """,
                arguments: [userID]
            )
            return rows.compactMap(Self.memoryFactTombstone(from:))
        }
    }

    func fetchMemorySourceReferences(matching tombstone: MemorySourceTombstoneRecord) async throws -> [MemoryFactTombstoneSourceRef] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT p.thread_logical_id, p.message_id, p.content_hash
                FROM memory_provenance p
                WHERE p.thread_logical_id = ?
                  AND (? IS NULL OR p.message_id = ?)
                  AND (? IS NULL OR p.content_hash = ?)
                ORDER BY p.thread_logical_id ASC, p.message_id ASC, p.content_hash ASC
                """,
                arguments: [
                    tombstone.threadLogicalID,
                    tombstone.messageID,
                    tombstone.messageID,
                    tombstone.contentHash,
                    tombstone.contentHash
                ]
            )
            return rows.compactMap(Self.memorySourceReference(from:))
        }
    }

    func markMemorySourceTombstoneReplicated(id: String, now: Date = Date()) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE memory_source_tombstones SET replicated_at = ? WHERE id = ?",
                arguments: [now, id]
            )
        }
    }

    func markMemoryFactTombstoneReplicated(id: String, now: Date = Date()) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE memory_fact_tombstones SET replicated_at = ? WHERE id = ?",
                arguments: [now, id]
            )
        }
    }

    func memoryHasTombstonedSource(id: MemoryID) async throws -> Bool {
        try await dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_provenance p
                JOIN memory_source_tombstones t
                  ON t.thread_logical_id = p.thread_logical_id
                 AND (t.message_id IS NULL OR t.message_id = p.message_id)
                 AND (t.content_hash IS NULL OR t.content_hash = p.content_hash)
                WHERE p.memory_id = ?
                """,
                arguments: [id]
            ) ?? 0
            return count > 0
        }
    }

    func chatMemoryAuthorityDeletionIDs(scope: MemoryScope) async throws -> [MemoryID] {
        try await memoryAuthorityDeletionIDs(scope: scope, sourceKinds: [.chat])
    }

    func memoryAuthorityDeletionIDs(
        scope: MemoryScope,
        sourceKinds: Set<MemorySourceKind>
    ) async throws -> [MemoryID] {
        let kindClause = Self.memorySourceKindInClause(column: "source_kind", kinds: sourceKinds)
        let partition = MemoryStoragePartition(sourceKinds)
        return try await dbQueue.read { db in
            var ids: [MemoryID] = []
            var seen = Set<MemoryID>()

            func appendIDs(matching targetScope: MemoryScope) throws {
                var predicates = [
                    kindClause.sql,
                    "project_id = ?"
                ]
                var arguments: [any DatabaseValueConvertible] = kindClause.arguments
                arguments.append(
                    Self.memoryStorageProjectID(for: targetScope, partition: partition)
                )
                Self.appendMemoryExtractionScopePredicates(targetScope, to: &predicates, arguments: &arguments)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id
                    FROM agent_memories
                    WHERE \(predicates.joined(separator: " AND "))
                    ORDER BY updated_at DESC, id ASC
                    """,
                    arguments: StatementArguments(arguments)
                )
                for row in rows {
                    guard let id: String = row["id"], seen.insert(id).inserted else { continue }
                    ids.append(id)
                }
            }

            try appendIDs(matching: scope)

            // Chat memory v1 was initially same-device scoped by app only. When
            // a signed-in user resets the app's memories, clear those local rows
            // too so the reset cannot leave pre-auth memories stranded.
            if scope.userID != nil,
               scope.agentID == nil,
               scope.runID == nil,
               scope.projectID == nil,
               let appID = scope.appID {
                try appendIDs(matching: MemoryScope(appID: appID))
            }

            return ids
        }
    }

    static func insertMemorySourceTombstone(
        db: Database,
        id: String,
        userID: String?,
        threadLogicalID: String,
        messageID: String?,
        contentHash: String?,
        reason: String,
        now: Date
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO memory_source_tombstones (
                id, user_id, thread_logical_id, message_id, content_hash, reason, created_at, replicated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                reason = excluded.reason,
                created_at = excluded.created_at,
                replicated_at = NULL
            """,
            arguments: [
                id,
                userID,
                threadLogicalID,
                messageID,
                contentHash,
                normalizedMemoryForgetReason(reason),
                now
            ]
        )
    }

    static func insertMemoryFactTombstone(
        db: Database,
        memory: Memory,
        reason: String,
        now: Date
    ) throws {
        guard let userID = memory.scope.userID else { return }
        let sourceRefs = memory.citations.map {
            MemoryFactTombstoneSourceRef(
                threadLogicalID: $0.threadLogicalID,
                messageID: $0.messageID,
                contentHash: $0.contentHash
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sourceRefsData = try encoder.encode(sourceRefs)
        let sourceRefsJSON = String(decoding: sourceRefsData, as: UTF8.self)
        try db.execute(
            sql: """
            INSERT INTO memory_fact_tombstones (
                id, user_id, memory_id, source_refs_json, reason, created_at, replicated_at
            ) VALUES (?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                source_refs_json = excluded.source_refs_json,
                reason = excluded.reason,
                created_at = excluded.created_at,
                replicated_at = NULL
            """,
            arguments: [
                memoryFactTombstoneID(memoryID: memory.id),
                userID,
                memory.id,
                sourceRefsJSON,
                normalizedMemoryForgetReason(reason),
                now
            ]
        )
    }

    private static func memorySourceTombstoneID(
        threadLogicalID: String,
        messageID: String?,
        contentHash: String?,
        reason: String
    ) -> String {
        let material = [
            threadLogicalID,
            messageID ?? "",
            contentHash ?? "",
            reason
        ].joined(separator: "|")
        return "memory-source-tombstone-\(sha256HexForTombstone(material))"
    }

    private static func sha256HexForTombstone(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func memorySourceTombstone(from row: Row) -> MemorySourceTombstoneRecord? {
        guard let id: String = row["id"],
              let threadLogicalID: String = row["thread_logical_id"],
              let reason: String = row["reason"],
              let createdAt = OpenBurnBarDatabase.parseDateValue(row["created_at"])
        else {
            return nil
        }
        return MemorySourceTombstoneRecord(
            id: id,
            userID: row["user_id"],
            threadLogicalID: threadLogicalID,
            messageID: row["message_id"],
            contentHash: row["content_hash"],
            reason: reason,
            createdAt: createdAt
        )
    }

    static func memoryFactTombstoneID(memoryID: MemoryID) -> String {
        "memory-fact-tombstone-\(sha256HexForTombstone(memoryID))"
    }

    private static func memoryFactTombstone(from row: Row) -> MemoryFactTombstoneRecord? {
        guard let id: String = row["id"],
              let userID: String = row["user_id"],
              let memoryID: String = row["memory_id"],
              let sourceRefsJSON: String = row["source_refs_json"],
              let reason: String = row["reason"],
              let createdAt = OpenBurnBarDatabase.parseDateValue(row["created_at"]),
              let data = sourceRefsJSON.data(using: .utf8)
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sourceRefs: [MemoryFactTombstoneSourceRef]
        do {
            sourceRefs = try decoder.decode([MemoryFactTombstoneSourceRef].self, from: data)
        } catch {
            return nil
        }
        return MemoryFactTombstoneRecord(
            id: id,
            userID: userID,
            memoryID: memoryID,
            sourceRefs: sourceRefs,
            reason: reason,
            createdAt: createdAt
        )
    }

    private static func memorySourceReference(from row: Row) -> MemoryFactTombstoneSourceRef? {
        guard let threadLogicalID: String = row["thread_logical_id"],
              let contentHash: String = row["content_hash"] else {
            return nil
        }
        return MemoryFactTombstoneSourceRef(
            threadLogicalID: threadLogicalID,
            messageID: row["message_id"],
            contentHash: contentHash
        )
    }

    private static func normalizedMemoryForgetReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "user_delete", "review_status_quarantined", "review_status_rejected", "clear_history", "gc_30d":
            return trimmed
        default:
            return "unknown"
        }
    }
}
