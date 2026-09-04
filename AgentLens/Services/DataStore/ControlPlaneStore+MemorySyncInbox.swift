import Foundation
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - Remote memory-fact inbox (Memory Blind Sync, pull half)

/// One opened, verified memory fact pulled down from the member's own cloud
/// vault and parked for the Memory MCP engine to merge.
///
/// Rows deliberately do NOT land in `agent_memories`: that table is this
/// device's own *upload* source, so a remote row written there would be
/// re-sealed and re-uploaded by this device's push lane in a loop. The inbox is
/// a one-way landing zone the engine drains through the daemon.
struct MemoryCloudInboxRecord: Equatable, Sendable {
    let docID: String
    let userID: String
    let engineMemoryID: String
    let payloadJSON: String
    let remoteUpdatedAt: Date
    let receivedAt: Date
    let appliedAt: Date?
}

/// What an inbox upsert actually did, so the pull service can report honest
/// counters instead of claiming work it skipped.
enum MemoryCloudInboxUpsertOutcome: String, Equatable, Sendable {
    /// A document this device had never seen.
    case inserted
    /// A strictly newer revision of a document already parked here; the row is
    /// replaced and `applied_at` cleared so the engine merges the new revision.
    case replaced
    /// The same (or an older) revision arrived again — a no-op, which is what
    /// makes re-applying a whole batch cost nothing.
    case unchanged
}

extension ControlPlaneStore {
    /// Parks one verified remote memory fact.
    ///
    /// Idempotence is keyed on `(doc_id, remote_updated_at)` exactly as §5 of the
    /// design requires: an identical or stale revision is dropped, a newer one
    /// replaces the row and resets `applied_at` so the engine re-merges it.
    @discardableResult
    func upsertRemoteMemoryFact(
        docID: String,
        userID: String,
        engineMemoryID: String,
        payloadJSON: String,
        remoteUpdatedAt: Date,
        now: Date = Date()
    ) async throws -> MemoryCloudInboxUpsertOutcome {
        let remoteStamp = Self.iso8601String(remoteUpdatedAt)
        let receivedStamp = Self.iso8601String(now)
        return try await dbQueue.write { db -> MemoryCloudInboxUpsertOutcome in
            let existing = try String.fetchOne(
                db,
                sql: "SELECT remote_updated_at FROM agent_memory_inbox WHERE doc_id = ?",
                arguments: [docID]
            )
            if let existing {
                // Fixed-width ISO-8601 UTC stamps, so lexicographic order is
                // chronological order and the comparison needs no date parse.
                guard existing < remoteStamp else { return .unchanged }
                try db.execute(
                    sql: """
                    UPDATE agent_memory_inbox
                    SET user_id = ?, engine_memory_id = ?, payload_json = ?,
                        remote_updated_at = ?, received_at = ?, applied_at = NULL
                    WHERE doc_id = ?
                    """,
                    arguments: [userID, engineMemoryID, payloadJSON, remoteStamp, receivedStamp, docID]
                )
                return .replaced
            }
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """,
                arguments: [docID, userID, engineMemoryID, payloadJSON, remoteStamp, receivedStamp]
            )
            return .inserted
        }
    }

    /// Drops every UNMERGED inbox row that belongs to some other account.
    ///
    /// The inbox is user-scoped, but neither party downstream can enforce that:
    /// the daemon holds no Firebase identity and the Memory MCP engine has no
    /// uid at all, so the drain they share (`daemon.memory.sync.inbox.list`) can
    /// only ever hand over "whatever is unmerged". The app is the one process
    /// that knows which member is signed in, so it owns the scoping — the pull
    /// runs this before it writes anything, and the invariant the daemon then
    /// relies on is exactly its postcondition: only the signed-in member's rows
    /// are unmerged.
    ///
    /// Merged rows are deliberately untouched. The engine already holds those
    /// facts; deleting them here would erase the audit trail of what it merged,
    /// and the daemon's retention sweep already owns their disposal.
    ///
    /// - Returns: how many rows were dropped, so an account switch is visible in
    ///   the pull result rather than silent.
    @discardableResult
    func purgeUnappliedRemoteMemoryFacts(otherThanUserID userID: String) async throws -> Int {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM agent_memory_inbox WHERE user_id <> ? AND applied_at IS NULL",
                arguments: [userID]
            )
            return db.changesCount
        }
    }

    /// Remote facts the engine has not merged yet, oldest first so a partial
    /// drain still applies updates in `updatedAt` order.
    func fetchUnappliedRemoteMemoryFacts(userID: String, limit: Int = 200) async throws -> [MemoryCloudInboxRecord] {
        let cappedLimit = max(1, min(limit, 1000))
        return try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at
                FROM agent_memory_inbox
                WHERE user_id = ? AND applied_at IS NULL
                ORDER BY remote_updated_at ASC, doc_id ASC
                LIMIT ?
                """,
                arguments: [userID, cappedLimit]
            ).compactMap(Self.memoryCloudInboxRecord(from:))
        }
    }

    private static func memoryCloudInboxRecord(from row: Row) -> MemoryCloudInboxRecord? {
        guard let docID = row["doc_id"] as? String,
              let userID = row["user_id"] as? String,
              let engineMemoryID = row["engine_memory_id"] as? String,
              let payloadJSON = row["payload_json"] as? String,
              let remoteUpdatedAt = OpenBurnBarDatabase.parseDateValue(row["remote_updated_at"]),
              let receivedAt = OpenBurnBarDatabase.parseDateValue(row["received_at"]) else {
            return nil
        }
        return MemoryCloudInboxRecord(
            docID: docID,
            userID: userID,
            engineMemoryID: engineMemoryID,
            payloadJSON: payloadJSON,
            remoteUpdatedAt: remoteUpdatedAt,
            receivedAt: receivedAt,
            appliedAt: OpenBurnBarDatabase.parseDateValue(row["applied_at"])
        )
    }
}
