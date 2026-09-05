import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
    // MARK: - Delete

    func deleteAll() async throws {
        let changedRows = try await dbQueue.write { db -> Int in
            try db.execute(sql: "DELETE FROM token_usage")
            return db.changesCount
        }
        noteUsageWrite(changedRows: changedRows)
    }

    // VAL-PERSIST-013: Reconciliation cleanup is source-scoped.
    // Cleanup of prior API-reconciliation rows must be constrained by source semantics
    // (billing_api) in addition to identifier prefix policy, so non-reconciliation rows
    // are never deleted accidentally.
    /// Returns the number of rows deleted so callers (billing reconcile) can
    /// tell a no-op cleanup from a content change without refetching the table.
    @discardableResult
    func deleteUsage(sessionIDPrefix: String) async throws -> Int {
        let deletedRows = try await dbQueue.write { db -> Int in
            try db.execute(
                sql: """
                    DELETE FROM token_usage
                    WHERE sessionId LIKE ?
                    AND COALESCE(sourceDeviceId, '') = ''
                    AND usageSource = 'billing_api'
                    """,
                arguments: ["\(sessionIDPrefix)%"]
            )
            return db.changesCount
        }
        noteUsageWrite(changedRows: deletedRows)
        return deletedRows
    }

    /// Removes parser-invalidated rows by exact provider/session identity.
    /// Day buckets are namespaced from the base session ID and are deleted
    /// together so a corrected parse cannot overlap a legacy lifetime row.
    func deleteUsage(provider: AgentProvider, sessionIDs: [String]) async throws {
        let uniqueSessionIDs = Set(sessionIDs)
        guard !uniqueSessionIDs.isEmpty else { return }

        try await dbQueue.write { db in
            for sessionID in uniqueSessionIDs {
                try db.execute(
                    sql: """
                        DELETE FROM token_usage
                        WHERE provider = ?
                          AND COALESCE(sourceDeviceId, '') = ''
                          AND (
                              sessionId = ?
                              OR substr(sessionId, 1, length(?) + 5) = ? || '#day-'
                          )
                        """,
                    arguments: [provider.rawValue, sessionID, sessionID, sessionID]
                )
            }
        }
        SearchQueryCache.shared.clear()
    }

    // MARK: - Sync

    func fetchUnsynced() async throws -> [TokenUsage] {
        try await dbQueue.read { db -> [TokenUsage] in
            try Self.compactMapCachedRows(
                db: db,
                sql: """
                    SELECT \(Self.usageDecodeSelectColumns.joined(separator: ", "))
                    FROM token_usage
                    WHERE syncedAt IS NULL AND isRemote = 0
                    ORDER BY startTime ASC LIMIT 400
                    """,
                transform: Self.decodeUsage
            )
        }
    }

    func fetchUsageIdStrings() async throws -> Set<String> {
        try await dbQueue.read { db -> Set<String> in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM token_usage")
            return Set(ids)
        }
    }

    func markSynced(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let idStrings: [String] = ids.map { $0.uuidString }
        try await dbQueue.write { db in
            var args = StatementArguments([Date()])
            args += StatementArguments(idStrings)
            try db.execute(
                sql: "UPDATE token_usage SET syncedAt = ? WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
    }

    func resetSyncStatusForAllLocalUsage() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE token_usage SET syncedAt = NULL WHERE isRemote = 0")
        }
    }
}
