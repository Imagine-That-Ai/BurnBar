import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - UsageStore

/// Token-usage CRUD, sync helpers, refresh reads, and provider/model summary builders.
final class UsageStore: Sendable {
    let dbQueue: any DatabaseWriter
    /// New-event marker for the periodic refresh tick (see `UsageTableWriteMarker`).
    /// Every mutator below that can change `token_usage` content bumps it when
    /// SQLite reports at least one changed row for the committed transaction.
    let writeMarker: UsageTableWriteMarker

    /// In-process skip gate for idle refresh ticks. When a parse pass
    /// produces the same usage *content* as the last successful persist and
    /// `token_usage` has not been mutated since (write marker unchanged),
    /// skip the O(rows) upsert storm. Fail-closed: any marker bump or
    /// content change re-runs the upserts.
    private let persistSkipGate = Locked<(fingerprint: UInt64, marker: Int)?>(nil)

    init(dbQueue: any DatabaseWriter, writeMarker: UsageTableWriteMarker = UsageTableWriteMarker()) {
        self.dbQueue = dbQueue
        self.writeMarker = writeMarker
    }

    /// Bumps the write marker when a write closure actually changed rows.
    /// `changedRows` is a `db.totalChangesCount`/`db.changesCount` delta
    /// sampled inside the same write closure, so it is exact for that
    /// transaction.
    func noteUsageWrite(changedRows: Int) {
        guard changedRows > 0 else { return }
        writeMarker.bump()
    }

    // MARK: - Insert

    func insert(_ usage: TokenUsage) async throws {
        let changedRows = try await dbQueue.write { db -> Int in
            let before = db.totalChangesCount
            try self.deleteKimiRequestIDModelRows(replacedBy: usage, in: db)
            if try self.shouldSuppressFactoryRoutedMirror(usage, in: db) {
                return db.totalChangesCount - before
            }
            try self.deleteFactoryRoutedMirrorRows(replacedBy: usage, in: db)
            try self.deleteStaleLowerConfidenceModelRows(replacedBy: usage, in: db)
            try self.upsertUsage(usage, in: db)
            return db.totalChangesCount - before
        }
        noteUsageWrite(changedRows: changedRows)
        SearchQueryCache.shared.clear()
    }

    func insert(_ newUsages: [TokenUsage]) async throws {
        guard !newUsages.isEmpty else { return }
        let changedRows = try await dbQueue.write { db -> Int in
            let before = db.totalChangesCount
            for usage in newUsages {
                try self.deleteKimiRequestIDModelRows(replacedBy: usage, in: db)
                if try self.shouldSuppressFactoryRoutedMirror(usage, in: db) {
                    continue
                }
                try self.deleteFactoryRoutedMirrorRows(replacedBy: usage, in: db)
                try self.deleteStaleLowerConfidenceModelRows(replacedBy: usage, in: db)
                try self.upsertUsage(usage, in: db)
            }
            return db.totalChangesCount - before
        }
        noteUsageWrite(changedRows: changedRows)
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
        if shouldSkipUnchangedPersist(newUsages) {
            return
        }
        var index = 0
        while index < newUsages.count {
            let end = min(index + chunkSize, newUsages.count)
            let chunk = Array(newUsages[index..<end])
            try await insertChunkWithIOErrorRecovery(chunk)
            index = end
        }
        rememberPersist(newUsages)
    }

    /// True when this batch is content-identical to the last persist and
    /// nobody else has written `token_usage` in between.
    func shouldSkipUnchangedPersist(_ usages: [TokenUsage]) -> Bool {
        let fingerprint = Self.persistContentFingerprint(usages)
        return persistSkipGate.read().map {
            $0.fingerprint == fingerprint && $0.marker == writeMarker.value
        } ?? false
    }

    func rememberPersist(_ usages: [TokenUsage]) {
        persistSkipGate.write((Self.persistContentFingerprint(usages), writeMarker.value))
    }

    /// Content identity for idle-tick skip. Excludes `id` and `createdAt`
    /// because parsers mint new UUIDs/timestamps on every pass even when
    /// session totals are unchanged. Conflict key + token/cost/window fields
    /// are the upsert-visible surface.
    static func persistContentFingerprint(_ usages: [TokenUsage]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(usages.count)
        let ordered = usages.sorted { lhs, rhs in
            if lhs.provider.rawValue != rhs.provider.rawValue {
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
            if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            let lhsDevice = lhs.sourceDeviceId ?? ""
            let rhsDevice = rhs.sourceDeviceId ?? ""
            if lhsDevice != rhsDevice { return lhsDevice < rhsDevice }
            return (lhs.providerAccountID ?? "") < (rhs.providerAccountID ?? "")
        }
        for usage in ordered {
            hasher.combine(usage.provider)
            hasher.combine(usage.sessionId)
            hasher.combine(usage.projectName)
            hasher.combine(usage.model)
            hasher.combine(usage.inputTokens)
            hasher.combine(usage.outputTokens)
            hasher.combine(usage.cacheCreationTokens)
            hasher.combine(usage.cacheReadTokens)
            hasher.combine(usage.reasoningTokens)
            hasher.combine(usage.totalTokens)
            hasher.combine(usage.cost.bitPattern)
            hasher.combine(usage.startTime.timeIntervalSince1970)
            hasher.combine(usage.endTime.timeIntervalSince1970)
            hasher.combine(usage.usageSource)
            hasher.combine(usage.executionSourceID)
            hasher.combine(usage.provenanceMethod)
            hasher.combine(usage.provenanceConfidence)
            hasher.combine(usage.providerAccountID)
            hasher.combine(usage.sourceDeviceId)
            hasher.combine(usage.billingKind)
            hasher.combine(usage.parentRequestID)
        }
        return UInt64(truncatingIfNeeded: hasher.finalize())
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
