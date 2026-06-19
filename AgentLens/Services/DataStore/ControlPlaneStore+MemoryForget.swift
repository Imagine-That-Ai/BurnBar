import CryptoKit
import Foundation
@preconcurrency import GRDB
import OpenBurnBarCore

extension ControlPlaneStore {
    struct MemoryFactTombstoneRecord: Sendable, Equatable {
        let id: String
        let memoryID: MemoryID
        let userID: String?
        let reason: String
        let createdAt: Date
    }

    func recordMemorySourceTombstone(
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
                threadLogicalID: threadLogicalID,
                messageID: messageID,
                contentHash: contentHash,
                reason: reason,
                now: now
            )
        }
        return id
    }

    func recordMemoryFactTombstone(
        memoryID: MemoryID,
        userID: String? = nil,
        reason: String,
        now: Date = Date()
    ) async throws -> String {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : reason
        let id = Self.memoryFactTombstoneID(memoryID: memoryID, reason: normalizedReason)
        try await dbQueue.write { db in
            try Self.insertMemoryFactTombstone(
                db: db,
                memoryID: memoryID,
                userID: userID,
                reason: normalizedReason,
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

    func fetchMemorySourceTombstones() async throws -> [MemorySourceTombstoneRecord] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM memory_source_tombstones
                ORDER BY created_at ASC, id ASC
                """
            )
            return rows.compactMap(Self.memorySourceTombstone(from:))
        }
    }

    func fetchMemoryFactTombstones(userID: String? = nil) async throws -> [MemoryFactTombstoneRecord] {
        try await dbQueue.read { db in
            var predicates: [String] = []
            var arguments: [any DatabaseValueConvertible] = []
            if let userID {
                predicates.append("user_id = ?")
                arguments.append(userID)
            }
            let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM memory_fact_tombstones
                \(whereClause)
                ORDER BY created_at ASC, id ASC
                """,
                arguments: StatementArguments(arguments)
            )
            return rows.compactMap(Self.memoryFactTombstone(from:))
        }
    }

    func deleteChatMemoryAuthorityRecords(scope: MemoryScope, now: Date = Date()) async throws -> Int {
        let ids = try await dbQueue.read { db in
            var predicates = ["source_kind = ?", "project_id = ?"]
            var arguments: [any DatabaseValueConvertible] = [
                MemorySourceKind.chat.rawValue,
                Self.memoryStorageProjectID(for: scope)
            ]
            Self.appendScopePredicates(scope, to: &predicates, arguments: &arguments)
            return try String.fetchAll(
                db,
                sql: """
                SELECT id
                FROM agent_memories
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY valid_from ASC, id ASC
                """,
                arguments: StatementArguments(arguments)
            )
        }
        var deleted = 0
        for id in ids where try await deleteChatMemoryAuthorityRecord(id: id, now: now) {
            deleted += 1
        }
        return deleted
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

    static func insertMemorySourceTombstone(
        db: Database,
        id: String,
        threadLogicalID: String,
        messageID: String?,
        contentHash: String?,
        reason: String,
        now: Date
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO memory_source_tombstones (
                id, thread_logical_id, message_id, content_hash, reason, created_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            arguments: [
                id,
                threadLogicalID,
                messageID,
                contentHash,
                reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : reason,
                now
            ]
        )
    }

    static func insertMemoryFactTombstone(
        db: Database,
        memoryID: MemoryID,
        userID: String?,
        reason: String,
        now: Date
    ) throws {
        let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : reason
        try db.execute(
            sql: """
            INSERT INTO memory_fact_tombstones (
                id, memory_id, user_id, reason, created_at
            ) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            arguments: [
                memoryFactTombstoneID(memoryID: memoryID, reason: normalizedReason),
                memoryID,
                userID,
                normalizedReason,
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

    private static func memoryFactTombstoneID(memoryID: MemoryID, reason: String) -> String {
        "memory-fact-tombstone-\(sha256HexForTombstone("\(memoryID)|\(reason)"))"
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
            threadLogicalID: threadLogicalID,
            messageID: row["message_id"],
            contentHash: row["content_hash"],
            reason: reason,
            createdAt: createdAt
        )
    }

    private static func memoryFactTombstone(from row: Row) -> MemoryFactTombstoneRecord? {
        guard let id: String = row["id"],
              let memoryID: String = row["memory_id"],
              let reason: String = row["reason"],
              let createdAt = OpenBurnBarDatabase.parseDateValue(row["created_at"])
        else {
            return nil
        }
        return MemoryFactTombstoneRecord(
            id: id,
            memoryID: memoryID,
            userID: row["user_id"],
            reason: reason,
            createdAt: createdAt
        )
    }
}
