import XCTest
import GRDB
@testable import OpenBurnBar

/// Tests for remote sync watermark and correction convergence semantics.
///
/// Verifies:
/// - VAL-TOKEN-012: Remote re-ingest behavior is explicit and tested
/// - VAL-PERSIST-009: Remote correction convergence is enforced
/// - VAL-PERSIST-010: Remote download watermark advances only after durable success
/// - VAL-PERSIST-011: Watermark scope is account-aware and collection-safe
@MainActor
final class RemoteSyncWatermarkTests: XCTestCase {
    private struct RemoteSyncWatermarkStoreHarness {
        let dataStore: DataStore

        func fetchWatermark(
            accountUid: String,
            collectionKind: RemoteSyncCollectionKind
        ) async throws -> RemoteSyncWatermarkRecord? {
            try await dataStore.fetchRemoteSyncWatermark(accountUid: accountUid, collectionKind: collectionKind)
        }

        func fetchAllWatermarks(accountUid: String) async throws -> [RemoteSyncWatermarkRecord] {
            try await dataStore.fetchAllRemoteSyncWatermarks(accountUid: accountUid)
        }

        func fetchWatermarkOrDefault(
            accountUid: String,
            collectionKind: RemoteSyncCollectionKind
        ) async throws -> Date {
            try await dataStore.fetchRemoteSyncWatermarkOrDefault(
                accountUid: accountUid,
                collectionKind: collectionKind
            )
        }

        func clearAllWatermarks(accountUid: String) async throws {
            try await dataStore.clearAllRemoteSyncWatermarks(accountUid: accountUid)
        }

        func makeTransaction(
            accountUid: String,
            collectionKind: RemoteSyncCollectionKind
        ) -> AtomicRemoteSyncTransaction {
            dataStore.makeRemoteSyncTransaction(accountUid: accountUid, collectionKind: collectionKind)
        }
    }

    private func makeWatermarkStore(_ dataStore: DataStore) -> RemoteSyncWatermarkStoreHarness {
        RemoteSyncWatermarkStoreHarness(dataStore: dataStore)
    }

    // MARK: - VAL-PERSIST-010: Watermark advances only after durable success

    func test_watermark_doesNotAdvance_whenTransactionNotCommitted() async throws {
        // Given: a watermark store
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let watermarkStore = makeWatermarkStore(dataStore)
        let accountUid = "test-account-uid"
        let collectionKind = RemoteSyncCollectionKind.usage

        // Create an atomic transaction but DON'T commit it
        let tx = watermarkStore.makeTransaction(
            accountUid: accountUid,
            collectionKind: collectionKind
        )
        tx.recordProcessedItem(remoteUpdatedAt: Date())

        // Verify: no watermark exists yet (not committed)
        let watermark = try await watermarkStore.fetchWatermark(accountUid: accountUid, collectionKind: collectionKind)
        XCTAssertNil(watermark, "Watermark must not exist before commit")
    }

    func test_watermark_advances_onlyAfterCommit() async throws {
        // Given: a watermark store with no existing watermark
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let watermarkStore = makeWatermarkStore(dataStore)
        let accountUid = "test-account-uid-2"
        let collectionKind = RemoteSyncCollectionKind.usage

        // When: we create and commit a transaction
        let tx = watermarkStore.makeTransaction(
            accountUid: accountUid,
            collectionKind: collectionKind
        )

        let processedDate = Date()
        tx.recordProcessedItem(remoteUpdatedAt: processedDate)
        try await tx.commit()

        // Then: watermark exists and is advanced
        let watermark = try await watermarkStore.fetchWatermark(accountUid: accountUid, collectionKind: collectionKind)
        XCTAssertNotNil(watermark, "Watermark must exist after commit")
        // Use approximate comparison for dates since there might be small timing differences
        if let watermarkDate = watermark?.lastProcessedRemoteUpdateAt {
            XCTAssertLessThan(abs(watermarkDate.timeIntervalSince(processedDate)), 1.0, "Watermark date should be close to processed date")
        }
        XCTAssertEqual(watermark?.version, 1)
    }

    func test_watermark_idempotent_commitAfterNoItems() async throws {
        // Given: a committed transaction
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let watermarkStore = makeWatermarkStore(dataStore)
        let accountUid = "test-account-uid-3"
        let collectionKind = RemoteSyncCollectionKind.conversations

        let tx1 = watermarkStore.makeTransaction(
            accountUid: accountUid,
            collectionKind: collectionKind
        )
        tx1.recordProcessedItem(remoteUpdatedAt: Date())
        try await tx1.commit()

        // When: we create another transaction with no items and commit
        let tx2 = watermarkStore.makeTransaction(
            accountUid: accountUid,
            collectionKind: collectionKind
        )
        // No items recorded
        try await tx2.commit()

        // Then: watermark unchanged (no items to advance)
        let watermark = try await watermarkStore.fetchWatermark(accountUid: accountUid, collectionKind: collectionKind)
        XCTAssertNotNil(watermark)
        XCTAssertEqual(watermark?.version, 1, "Version must not increment when no items processed")
    }

    func test_watermark_versionIncrements_onSubsequentCommit() async throws {
        // Given: a committed transaction
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let watermarkStore = makeWatermarkStore(dataStore)
        let accountUid = "test-account-uid-4"
        let collectionKind = RemoteSyncCollectionKind.usage

        let tx1 = watermarkStore.makeTransaction(
            accountUid: accountUid,
            collectionKind: collectionKind
        )
        tx1.recordProcessedItem(remoteUpdatedAt: Date())
        try await tx1.commit()

        // When: we commit another transaction
        let tx2 = watermarkStore.makeTransaction(
            accountUid: accountUid,
            collectionKind: collectionKind
        )
        tx2.recordProcessedItem(remoteUpdatedAt: Date())
        try await tx2.commit()

        // Then: version incremented
        let watermark = try await watermarkStore.fetchWatermark(accountUid: accountUid, collectionKind: collectionKind)
        XCTAssertEqual(watermark?.version, 2)
    }

    // MARK: - VAL-PERSIST-011: Watermark scope is account-aware and collection-safe

    func test_watermark_perAccountIsolation() async throws {
        // Given: watermarks for different accounts
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let watermarkStore = makeWatermarkStore(dataStore)
        let account1 = "account-1"
        let account2 = "account-2"
        let collectionKind = RemoteSyncCollectionKind.usage

        // Create watermarks for account 1
        let tx1 = watermarkStore.makeTransaction(
            accountUid: account1,
            collectionKind: collectionKind
        )
        tx1.recordProcessedItem(remoteUpdatedAt: Date())
        try await tx1.commit()

        // Create watermarks for account 2
        let tx2 = watermarkStore.makeTransaction(
            accountUid: account2,
            collectionKind: collectionKind
        )
        tx2.recordProcessedItem(remoteUpdatedAt: Date())
        try await tx2.commit()

        // Then: both watermarks exist independently
        let watermark1 = try await watermarkStore.fetchWatermark(accountUid: account1, collectionKind: collectionKind)
        let watermark2 = try await watermarkStore.fetchWatermark(accountUid: account2, collectionKind: collectionKind)

        XCTAssertNotNil(watermark1)
        XCTAssertNotNil(watermark2)
        XCTAssertEqual(watermark1?.accountUid, account1)
        XCTAssertEqual(watermark2?.accountUid, account2)
    }

    func test_watermark_perCollectionIsolation() async throws {
        // Given: watermarks for different collections in the same account
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let watermarkStore = makeWatermarkStore(dataStore)
        let accountUid = "shared-account"
        let usageKind = RemoteSyncCollectionKind.usage
        let convKind = RemoteSyncCollectionKind.conversations

        // Create watermark for usage
        let tx1 = watermarkStore.makeTransaction(
            accountUid: accountUid,
            collectionKind: usageKind
        )
        let usageDate = Date()
        tx1.recordProcessedItem(remoteUpdatedAt: usageDate)
        try await tx1.commit()

        // Create watermark for conversations
        let tx2 = watermarkStore.makeTransaction(
            accountUid: accountUid,
            collectionKind: convKind
        )
        let convDate = Date()
        tx2.recordProcessedItem(remoteUpdatedAt: convDate)
        try await tx2.commit()

        // Then: both watermarks exist independently
        let usageWatermark = try await watermarkStore.fetchWatermark(accountUid: accountUid, collectionKind: usageKind)
        let convWatermark = try await watermarkStore.fetchWatermark(accountUid: accountUid, collectionKind: convKind)

        XCTAssertNotNil(usageWatermark)
        XCTAssertNotNil(convWatermark)
        // Use approximate comparison for dates since there might be small timing differences
        if let usageWatermarkDate = usageWatermark?.lastProcessedRemoteUpdateAt {
            XCTAssertLessThan(abs(usageWatermarkDate.timeIntervalSince(usageDate)), 1.0)
        }
        if let convWatermarkDate = convWatermark?.lastProcessedRemoteUpdateAt {
            XCTAssertLessThan(abs(convWatermarkDate.timeIntervalSince(convDate)), 1.0)
        }
    }

    func test_watermark_fetchAllForAccount() async throws {
        // Given: watermarks for multiple collections in one account
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let watermarkStore = makeWatermarkStore(dataStore)
        let accountUid = "multi-collection-account"

        for kind in RemoteSyncCollectionKind.allCases {
            let tx = watermarkStore.makeTransaction(
                accountUid: accountUid,
                collectionKind: kind
            )
            tx.recordProcessedItem(remoteUpdatedAt: Date())
            try await tx.commit()
        }

        // When: we fetch all watermarks for the account
        let allWatermarks = try await watermarkStore.fetchAllWatermarks(accountUid: accountUid)

        // Then: we get one watermark per collection
        XCTAssertEqual(allWatermarks.count, RemoteSyncCollectionKind.allCases.count)
    }

    func test_watermark_clearForAccount() async throws {
        // Given: watermarks for an account
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let watermarkStore = makeWatermarkStore(dataStore)
        let accountUid = "account-to-clear"
        let collectionKind = RemoteSyncCollectionKind.usage

        let tx = watermarkStore.makeTransaction(
            accountUid: accountUid,
            collectionKind: collectionKind
        )
        tx.recordProcessedItem(remoteUpdatedAt: Date())
        try await tx.commit()

        // When: we clear all watermarks for the account
        try await watermarkStore.clearAllWatermarks(accountUid: accountUid)

        // Then: no watermarks remain for that account
        let watermarks = try await watermarkStore.fetchAllWatermarks(accountUid: accountUid)
        XCTAssertTrue(watermarks.isEmpty)
    }

    func test_watermark_fetchOrDefault_returnsDefaultWhenNone() async throws {
        // Given: no watermark exists
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let watermarkStore = makeWatermarkStore(dataStore)
        let accountUid = "fresh-account"
        let collectionKind = RemoteSyncCollectionKind.usage

        // When: we fetch with default
        let result = try await watermarkStore.fetchWatermarkOrDefault(
            accountUid: accountUid,
            collectionKind: collectionKind
        )

        // Then: we get a date approximately 90 days ago
        let expectedDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let difference = abs(result.timeIntervalSince(expectedDate))
        XCTAssertLessThan(difference, 60, "Default should be ~90 days ago")
    }

    /// Memory facts are STATE, not events. A memory's `updatedAt` is when it was
    /// last touched, not when it stopped being true, so the conversation
    /// collections' 90-day cutoff silently delivered a brand-new device only the
    /// memories that happened to have been edited recently — the opposite of
    /// what "your memories follow you to your other Mac" promises, with no error
    /// and no counter to notice it by.
    func test_watermark_fetchOrDefault_backfillsTheWholeStoreForMemoryFacts() async throws {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let watermarkStore = makeWatermarkStore(dataStore)

        let floor = try await watermarkStore.fetchWatermarkOrDefault(
            accountUid: "fresh-account",
            collectionKind: .memoryFacts
        )

        let tenYearsAgo = Calendar.current.date(byAdding: .year, value: -10, to: Date())!
        XCTAssertLessThan(floor, tenYearsAgo, "a first sync of memory_facts reaches back past any plausible store")
        XCTAssertEqual(floor, RemoteSyncCollectionKind.memoryFacts.firstSyncFloor)

        // The conversation-shaped collections keep the cutoff they have always had.
        for kind in [RemoteSyncCollectionKind.usage, .conversations, .chatThreads] {
            let ninetyDaysAgo = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
            XCTAssertLessThan(abs(kind.firstSyncFloor.timeIntervalSince(ninetyDaysAgo)), 60, "\(kind)")
        }

        // A stored watermark still governs every later sync, for every kind.
        let stored = Date(timeIntervalSince1970: 1_800_000_000)
        try await dataStore.advanceRemoteSyncWatermark(
            accountUid: "fresh-account",
            collectionKind: .memoryFacts,
            lastProcessedRemoteUpdateAt: stored
        )
        let resumed = try await watermarkStore.fetchWatermarkOrDefault(
            accountUid: "fresh-account",
            collectionKind: .memoryFacts
        )
        XCTAssertEqual(resumed.timeIntervalSince1970, stored.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - VAL-TOKEN-012: Remote re-ingest behavior is explicit and tested

    func test_remoteInsert_allowsReinsertOfSameKey() async throws {
        // Given: a remote usage already exists
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let sessionId = "remote-reingest-test-1"
        let remoteUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "RemoteProject",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            usageSource: .billingAPI,
            sourceDeviceId: "device-remote-A",
            sourceDeviceName: "Remote Mac A",
            isRemote: true,
            provenanceMethod: .cloudSync,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try await dataStore.insertRemoteUsage(remoteUsage)

        // When: we re-insert the same data
        try await dataStore.insertRemoteUsage(remoteUsage)

        // Then: still one row (idempotent - no duplicates)
        let rows = try await queue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token_usage WHERE sessionId = ?", arguments: [sessionId]) ?? 0
        }
        XCTAssertEqual(rows, 1, "Re-ingest must not create duplicate rows")
    }

    func test_remoteInsert_updatesWhenCorrected() async throws {
        // Given: a remote usage exists
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let sessionId = "remote-correction-test-1"
        let originalUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "OriginalProject",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            usageSource: .billingAPI,
            sourceDeviceId: "device-remote-B",
            sourceDeviceName: "Remote Mac B",
            isRemote: true,
            provenanceMethod: .cloudSync,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try await dataStore.insertRemoteUsage(originalUsage)

        // When: remote provides corrected data for same key
        let correctedUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "CorrectedProject",
            model: "claude-4-sonnet",
            inputTokens: 2000, // corrected value
            outputTokens: 1000, // corrected value
            costUSD: 0.10, // corrected value
            startTime: Date(),
            endTime: Date(),
            usageSource: .billingAPI,
            sourceDeviceId: "device-remote-B",
            sourceDeviceName: "Remote Mac B",
            isRemote: true,
            provenanceMethod: .cloudSync,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try await dataStore.insertRemoteUsage(correctedUsage)

        // Then: row is updated (correction convergence)
        let rows = try await queue.read { db -> [Row] in
            try Row.fetchAll(db, sql: "SELECT * FROM token_usage WHERE sessionId = ?", arguments: [sessionId])
        }
        XCTAssertEqual(rows.count, 1, "Should still have one canonical row")
        let inputTokens: Int = rows[0]["inputTokens"] ?? 0
        XCTAssertEqual(inputTokens, 2000, "Corrected values should be persisted")
        XCTAssertEqual(rows[0]["projectName"] as? String, "CorrectedProject")
    }

    // MARK: - VAL-PERSIST-009: Remote correction convergence is enforced

    func test_remoteCorrection_updatesExistingLowerConfidenceRow() async throws {
        // Given: an existing row with lower confidence (e.g., from heuristic) from same device
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let sessionId = "convergence-test-1"
        let sharedDeviceId = "shared-device"
        let lowerConfidenceUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "LowerProject",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            usageSource: .providerLog,
            sourceDeviceId: sharedDeviceId,
            provenanceMethod: .heuristicEstimate,
            provenanceConfidence: .lowConfidenceEstimate,
            estimatorVersion: "char-ratio-v1"
        )
        try await dataStore.insert(lowerConfidenceUsage)

        // When: remote with exact confidence provides data for the same key and device
        let remoteExactUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "HigherProject",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 800,
            costUSD: 0.10,
            startTime: Date(),
            endTime: Date(),
            usageSource: .billingAPI,
            sourceDeviceId: sharedDeviceId,  // Same device ID for correction convergence
            sourceDeviceName: "Shared Device",
            isRemote: true,
            provenanceMethod: .cloudSync,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try await dataStore.insertRemoteUsage(remoteExactUsage)

        // Then: row is updated to exact confidence
        let rows = try await queue.read { db -> [Row] in
            try Row.fetchAll(db, sql: "SELECT * FROM token_usage WHERE sessionId = ?", arguments: [sessionId])
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["provenanceConfidence"] as? String, "exact")
        let inputTokens: Int = rows[0]["inputTokens"] ?? 0
        XCTAssertEqual(inputTokens, 2000, "Exact remote should override lower confidence")
    }

    func test_remoteCorrection_doesNotDowngradeExactToEstimate() async throws {
        // Given: an existing exact row from same device
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let sessionId = "no-downgrade-test-1"
        let sharedDeviceId = "shared-device-2"
        let exactLocalUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "LocalProject",
            model: "claude-4-sonnet",
            inputTokens: 5000,
            outputTokens: 2000,
            costUSD: 0.25,
            startTime: Date(),
            endTime: Date(),
            usageSource: .providerLog,
            sourceDeviceId: sharedDeviceId,
            provenanceMethod: .providerLog,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try await dataStore.insert(exactLocalUsage)

        // When: remote with lower confidence provides data for the same key and device
        let remoteEstimateUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "RemoteEstimate",
            model: "claude-4-sonnet",
            inputTokens: 3000,
            outputTokens: 1000,
            costUSD: 0.15,
            startTime: Date(),
            endTime: Date(),
            usageSource: .billingAPI,
            sourceDeviceId: sharedDeviceId,  // Same device ID - same canonical key
            sourceDeviceName: "Shared Device 2",
            isRemote: true,
            provenanceMethod: .cloudSync,
            provenanceConfidence: .highConfidenceEstimate, // lower than exact
            estimatorVersion: ""
        )
        try await dataStore.insertRemoteUsage(remoteEstimateUsage)

        // Then: exact local row is preserved (not downgraded)
        let rows = try await queue.read { db -> [Row] in
            try Row.fetchAll(db, sql: "SELECT * FROM token_usage WHERE sessionId = ?", arguments: [sessionId])
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["provenanceConfidence"] as? String, "exact")
        let inputTokens: Int = rows[0]["inputTokens"] ?? 0
        XCTAssertEqual(inputTokens, 5000, "Exact local must not be downgraded by remote estimate")
    }

    func test_remoteCorrection_convergesFromDifferentRemoteDevice() async throws {
        // Given: remote usage from device A
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        let sessionId = "multi-device-correction"
        let deviceAUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "DeviceAProject",
            model: "claude-4-sonnet",
            inputTokens: 1000,
            outputTokens: 500,
            costUSD: 0.05,
            startTime: Date(),
            endTime: Date(),
            usageSource: .billingAPI,
            sourceDeviceId: "device-A",
            sourceDeviceName: "Mac A",
            isRemote: true,
            provenanceMethod: .cloudSync,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try await dataStore.insertRemoteUsage(deviceAUsage)

        // When: remote usage from device B provides corrected data (different sourceDeviceId = different key)
        let deviceBUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: sessionId,
            projectName: "DeviceBProject",
            model: "claude-4-sonnet",
            inputTokens: 2000,
            outputTokens: 800,
            costUSD: 0.10,
            startTime: Date(),
            endTime: Date(),
            usageSource: .billingAPI,
            sourceDeviceId: "device-B", // different device
            sourceDeviceName: "Mac B",
            isRemote: true,
            provenanceMethod: .cloudSync,
            provenanceConfidence: .exact,
            estimatorVersion: ""
        )
        try await dataStore.insertRemoteUsage(deviceBUsage)

        // Then: both rows exist (different sourceDeviceId = different canonical key)
        let rows = try await queue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token_usage WHERE sessionId = ?", arguments: [sessionId]) ?? 0
        }
        XCTAssertEqual(rows, 2, "Different sourceDeviceId creates separate rows")
    }

    // MARK: - Schema Validation

    func test_migration_v30_createsRemoteSyncWatermarksTable() async throws {
        // Given: migrations have run
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let columns = try await queue.read { db -> [String] in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(remote_sync_watermarks)")
            return rows.compactMap { $0["name"] as? String }
        }

        // Then: required columns exist
        XCTAssertTrue(columns.contains("accountUid"))
        XCTAssertTrue(columns.contains("collectionKind"))
        XCTAssertTrue(columns.contains("lastSyncedAt"))
        XCTAssertTrue(columns.contains("lastProcessedRemoteUpdateAt"))
        XCTAssertTrue(columns.contains("version"))
    }

    func test_migration_v30_createsPrimaryKey() async throws {
        // Given: migrations have run
        let queue = try DatabaseQueue()
        _ = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)

        let indexes = try await queue.read { db -> [Row] in
            try Row.fetchAll(db, sql: "PRAGMA index_list(remote_sync_watermarks)")
        }

        // Then: primary key index exists
        let primaryKeyIndex = indexes.first { row in
            (row["name"] as? String)?.contains("sqlite_autoindex") == true
        }
        XCTAssertNotNil(primaryKeyIndex, "Primary key should create an auto-index")
    }
}
