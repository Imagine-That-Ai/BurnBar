import Foundation
import GRDB
import OpenBurnBarCore

extension UsageStore {
    // MARK: - Delete

    func deleteAll() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM token_usage")
        }
    }

    // VAL-PERSIST-013: Reconciliation cleanup is source-scoped.
    // Cleanup of prior API-reconciliation rows must be constrained by source semantics
    // (billing_api) in addition to identifier prefix policy, so non-reconciliation rows
    // are never deleted accidentally.
    func deleteUsage(sessionIDPrefix: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM token_usage
                    WHERE sessionId LIKE ?
                    AND COALESCE(sourceDeviceId, '') = ''
                    AND usageSource = 'billing_api'
                    """,
                arguments: ["\(sessionIDPrefix)%"]
            )
        }
    }

    /// Removes parser-invalidated rows by exact provider/session identity.
    /// The day-bucket namespace is included for compatibility with prior Codex imports.
    func deleteUsage(provider: AgentProvider, sessionIDs: [String]) async throws {
        let uniqueSessionIDs = Set(sessionIDs)
        guard !uniqueSessionIDs.isEmpty else { return }

        try await dbQueue.write { db in
            for sessionID in uniqueSessionIDs {
                try db.execute(
                    sql: """
                        DELETE FROM token_usage
                        WHERE provider = ?
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
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM token_usage WHERE syncedAt IS NULL AND isRemote = 0 ORDER BY startTime ASC LIMIT 400"
            )
            return rows.compactMap(Self.decodeUsage)
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
}
