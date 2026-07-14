import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - UsageStore

/// Token-usage CRUD, sync helpers, refresh reads, and provider/model summary builders.
final class UsageStore: Sendable {
    let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Insert

    func insert(_ usage: TokenUsage) async throws {
        try await dbQueue.write { db in
            try self.deleteKimiRequestIDModelRows(replacedBy: usage, in: db)
            if try self.shouldSuppressFactoryRoutedMirror(usage, in: db) {
                return
            }
            try self.deleteFactoryRoutedMirrorRows(replacedBy: usage, in: db)
            try self.deleteStaleLowerConfidenceModelRows(replacedBy: usage, in: db)
            try self.upsertUsage(usage, in: db)
        }
        SearchQueryCache.shared.clear()
    }

    func insert(_ newUsages: [TokenUsage]) async throws {
        guard !newUsages.isEmpty else { return }
        try await dbQueue.write { db in
            for usage in newUsages {
                try self.deleteKimiRequestIDModelRows(replacedBy: usage, in: db)
                if try self.shouldSuppressFactoryRoutedMirror(usage, in: db) {
                    continue
                }
                try self.deleteFactoryRoutedMirrorRows(replacedBy: usage, in: db)
                try self.deleteStaleLowerConfidenceModelRows(replacedBy: usage, in: db)
                try self.upsertUsage(usage, in: db)
            }
        }
        SearchQueryCache.shared.clear()
    }

    /// Removes invalidated parser rows and their exact daily bucket namespace.
    /// The explicit `#day-` delimiter avoids deleting unrelated sessions that
    /// merely share a prefix.
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

    /// Inserts `newUsages` in fixed-size chunks, each in its own transaction.
    ///
    /// On a transient `SQLITE_IOERR` (commonly an APFS/WAL shared-memory hiccup
    /// during a large import), the failed chunk is retried once after running
    /// `PRAGMA wal_checkpoint(TRUNCATE)` to reset the WAL/SHM files. Successful
    /// chunks committed before the failure are preserved, so users don't lose
    /// progress on a long import to a single bad commit.
    ///
    /// `chunkSize` is a balance between transaction overhead and rollback blast
    /// radius. 100 keeps each commit small enough that even a worst-case retry
    /// reprocesses a small batch.
    func insertChunked(_ newUsages: [TokenUsage], chunkSize: Int = 100) async throws {
        guard !newUsages.isEmpty else { return }
        var index = 0
        while index < newUsages.count {
            let end = min(index + chunkSize, newUsages.count)
            let chunk = Array(newUsages[index..<end])
            try await insertChunkWithIOErrorRecovery(chunk)
            index = end
        }
    }

    private func insertChunkWithIOErrorRecovery(_ chunk: [TokenUsage]) async throws {
        do {
            try await insert(chunk)
        } catch let dbError as DatabaseError where dbError.resultCode == .SQLITE_IOERR {
            AppLogger.dataStore.error(
                "INSERT INTO token_usage hit SQLITE_IOERR; attempting WAL checkpoint truncate then retry",
                metadata: [
                    "resultCode": "\(dbError.resultCode.rawValue)",
                    "extendedResultCode": "\(dbError.extendedResultCode.rawValue)",
                    "chunkSize": "\(chunk.count)"
                ]
            )
            try await checkpointTruncate()
            try await insert(chunk)
        }
    }

    /// Forces SQLite to drain and truncate the WAL/SHM files. Used as a recovery
    /// step when an INSERT fails with `SQLITE_IOERR`, which on macOS is most
    /// commonly an APFS-level issue with the `-wal` / `-shm` sidecar files.
    func checkpointTruncate() async throws {
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
