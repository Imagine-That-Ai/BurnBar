import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Remote Sync Watermark Record

/// A database record representing remote sync watermark state for a specific
/// account and collection scope.
///
/// Used for tracking incremental sync progress and enabling durable,
/// account-safe watermark behavior.
///
/// VAL-PERSIST-010: Watermark advances only after successful commit.
/// VAL-PERSIST-011: Watermark scope is account-aware and collection-safe.
struct RemoteSyncWatermarkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "remote_sync_watermarks"

    /// The Firebase auth UID of the account.
    let accountUid: String

    /// The collection kind this watermark tracks: "usage", "conversations", "chat_threads".
    let collectionKind: String

    /// The last successful sync timestamp - watermark for next query.
    var lastSyncedAt: Date

    /// The most recent `updatedAt` from remote that was successfully processed.
    /// Used to resume without missing rows after partial failures.
    var lastProcessedRemoteUpdateAt: Date?

    /// Monotonically increasing version for optimistic concurrency.
    var version: Int

    enum CodingKeys: String, CodingKey {
        case accountUid
        case collectionKind
        case lastSyncedAt
        case lastProcessedRemoteUpdateAt
        case version
    }
}

// MARK: - Remote Sync Collection Kind

/// Kinds of collections that have independent watermark tracking.
enum RemoteSyncCollectionKind: String, CaseIterable {
    case usage = "usage"
    case conversations = "conversations"
    case chatThreads = "chat_threads"

    /// All collection kinds for iteration.
    static var allCases: [RemoteSyncCollectionKind] {
        [.usage, .conversations, .chatThreads]
    }
}

// MARK: - Remote Sync Watermark Store

/// Stores durable remote sync watermark state per account and collection scope.
///
/// Watermark advancement semantics:
/// - Advances ONLY after successful sync transaction commit (VAL-PERSIST-010)
/// - Per-account scope prevents cross-account pollution (VAL-PERSIST-011)
/// - Per-collection kind allows independent sync cursors
final class RemoteSyncWatermarkStore: Sendable {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Read

    /// Fetches the current watermark for a specific account and collection.
    /// Returns nil if no watermark exists yet (fresh sync).
    func fetchWatermark(accountUid: String, collectionKind: RemoteSyncCollectionKind) throws -> RemoteSyncWatermarkRecord? {
        try dbQueue.read { db in
            try RemoteSyncWatermarkRecord.fetchOne(db, sql: """
                SELECT * FROM remote_sync_watermarks
                WHERE accountUid = ? AND collectionKind = ?
                """, arguments: [accountUid, collectionKind.rawValue])
        }
    }

    /// Fetches all watermarks for a specific account.
    func fetchAllWatermarks(accountUid: String) throws -> [RemoteSyncWatermarkRecord] {
        try dbQueue.read { db in
            try RemoteSyncWatermarkRecord.fetchAll(db, sql: """
                SELECT * FROM remote_sync_watermarks
                WHERE accountUid = ?
                """, arguments: [accountUid])
        }
    }

    /// Fetches the watermark value for a collection, or a default cutoff date if none exists.
    /// The default is 90 days ago (matches CloudSyncService cutoff).
    func fetchWatermarkOrDefault(accountUid: String, collectionKind: RemoteSyncCollectionKind) throws -> Date {
        if let watermark = try fetchWatermark(accountUid: accountUid, collectionKind: collectionKind) {
            return watermark.lastProcessedRemoteUpdateAt ?? watermark.lastSyncedAt
        }
        // Default cutoff: 90 days ago
        return Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
    }

    // MARK: - Write

    /// Advances the watermark after successful sync.
    /// This MUST be called only after all items for this collection have been
    /// successfully persisted.
    ///
    /// VAL-PERSIST-010: Watermark advances only after successful commit.
    ///
    /// - Parameters:
    ///   - accountUid: The account UID
    ///   - collectionKind: The collection kind
    ///   - lastProcessedRemoteUpdateAt: The most recent remote `updatedAt` that was processed
    func advanceWatermark(
        accountUid: String,
        collectionKind: RemoteSyncCollectionKind,
        lastProcessedRemoteUpdateAt: Date
    ) throws {
        let now = Date()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO remote_sync_watermarks (accountUid, collectionKind, lastSyncedAt, lastProcessedRemoteUpdateAt, version)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(accountUid, collectionKind) DO UPDATE SET
                    lastSyncedAt = excluded.lastSyncedAt,
                    lastProcessedRemoteUpdateAt = excluded.lastProcessedRemoteUpdateAt,
                    version = version + 1
                """, arguments: [
                    accountUid,
                    collectionKind.rawValue,
                    now,
                    lastProcessedRemoteUpdateAt
                ])
        }
    }

    /// Clears the watermark for a specific account and collection (forces full re-sync).
    func clearWatermark(accountUid: String, collectionKind: RemoteSyncCollectionKind) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM remote_sync_watermarks
                WHERE accountUid = ? AND collectionKind = ?
                """, arguments: [accountUid, collectionKind.rawValue])
        }
    }

    /// Clears all watermarks for a specific account (e.g., on account switch).
    func clearAllWatermarks(accountUid: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM remote_sync_watermarks
                WHERE accountUid = ?
                """, arguments: [accountUid])
        }
    }

    /// Clears all watermarks for all accounts (full reset).
    func clearAllWatermarks() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM remote_sync_watermarks")
        }
    }
}

// MARK: - Atomic Remote Sync Transaction

/// Represents an atomic remote sync operation that couples sync work with
/// durable watermark advancement.
///
/// VAL-PERSIST-010: Watermark advances only after successful commit.
final class AtomicRemoteSyncTransaction {
    private let dbQueue: any DatabaseWriter
    private let watermarkStore: RemoteSyncWatermarkStore
    private let accountUid: String
    private let collectionKind: RemoteSyncCollectionKind

    private var processedItems: Int = 0
    private var latestRemoteUpdateAt: Date?
    private var isCommitted: Bool = false

    init(
        dbQueue: any DatabaseWriter,
        watermarkStore: RemoteSyncWatermarkStore,
        accountUid: String,
        collectionKind: RemoteSyncCollectionKind
    ) {
        self.dbQueue = dbQueue
        self.watermarkStore = watermarkStore
        self.accountUid = accountUid
        self.collectionKind = collectionKind
    }

    /// Records that an item was successfully processed.
    /// Tracks the latest remote `updatedAt` seen.
    func recordProcessedItem(remoteUpdatedAt: Date) {
        processedItems += 1
        if latestRemoteUpdateAt == nil || remoteUpdatedAt > latestRemoteUpdateAt! {
            latestRemoteUpdateAt = remoteUpdatedAt
        }
    }

    /// Commits the transaction and advances the watermark.
    /// This is the ONLY place where watermark advances.
    ///
    /// VAL-PERSIST-010: Watermark advances only after successful commit.
    func commit() throws {
        guard !isCommitted else { return }
        guard let latestUpdate = latestRemoteUpdateAt else {
            // No items processed - still commit but don't advance watermark
            isCommitted = true
            return
        }

        try watermarkStore.advanceWatermark(
            accountUid: accountUid,
            collectionKind: collectionKind,
            lastProcessedRemoteUpdateAt: latestUpdate
        )
        isCommitted = true
    }

    /// Abandons the transaction without advancing the watermark.
    /// On next sync, we'll re-fetch from the previous watermark.
    func rollback() {
        guard !isCommitted else { return }
        processedItems = 0
        latestRemoteUpdateAt = nil
    }

    var wasCommitted: Bool { isCommitted }
    var processedCount: Int { processedItems }
    var latestUpdate: Date? { latestRemoteUpdateAt }
}
