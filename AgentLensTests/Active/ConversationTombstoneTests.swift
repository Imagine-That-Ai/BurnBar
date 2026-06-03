import XCTest
import GRDB
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

/// B-DATA-2 — Cross-device delete propagation (tombstones).
///
/// Covers the four guarantees the feature must hold:
///  (a) the v47 migration adds `deletedAt` + `version` to `conversations`,
///  (b) a soft-deleted conversation is excluded from every user-facing read,
///  (c) a remote tombstone soft-deletes the matching local conversation,
///  (d) the GC sweep purges cloud bytes + the local row after the retention window.
@MainActor
final class ConversationTombstoneTests: XCTestCase {
    private var dataStore: DataStore!
    private var queue: DatabaseQueue!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!

    override func setUp() async throws {
        queue = try DatabaseQueue(path: ":memory:")
        dataStore = try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "tombstone-\(UUID().uuidString)")!)
        settingsManager.conversationCloudBackupEnabled = true
        fakeGateway = CloudSyncFirestoreFakeGateway()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
    }

    // MARK: - (a) Migration adds columns

    func test_v47Migration_addsDeletedAtAndVersionColumns() async throws {
        let columns = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(conversations)")
                .compactMap { $0["name"] as? String }
        }
        XCTAssertTrue(columns.contains("deletedAt"), "v47 must add a deletedAt tombstone column.")
        XCTAssertTrue(columns.contains("version"), "v47 must add a version counter column.")

        // The migration is the newest registered one (the backup gate keys off it).
        XCTAssertEqual(OpenBurnBarDatabase.migrator.migrations.last, "v47_conversation_tombstones")

        // Fresh rows default to version 1 with a null tombstone.
        try dataStore.upsertConversation(makeRecord(id: "conv-version-default"))
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT deletedAt, version FROM conversations WHERE id = ?", arguments: ["conv-version-default"])
        }
        XCTAssertNil(row?["deletedAt"])
        XCTAssertEqual(row?["version"] as? Int64, 1)
    }

    // MARK: - (b) Soft-delete excludes from reads

    func test_softDelete_excludesConversationFromReads_bumpsVersion_andClearsSyncFlags() async throws {
        let id = "conv-soft-delete"
        try dataStore.upsertConversation(makeRecord(id: id, fullText: "secret token sk-abcdef0123456789abcdef"))
        // Mark it synced so we can prove the soft-delete re-dirties it for upload.
        try dataStore.markConversationsSynced(ids: [id])

        XCTAssertNotNil(try dataStore.fetchConversation(id: id))
        XCTAssertEqual(try dataStore.fetchConversations().count, 1)
        XCTAssertEqual(try dataStore.countConversations(), 1)

        try dataStore.softDeleteConversation(id: id)

        // Every user-facing read now treats it as absent.
        XCTAssertNil(try dataStore.fetchConversation(id: id), "Soft-deleted conversation must read as absent by id.")
        XCTAssertTrue(try dataStore.fetchConversations().isEmpty, "Soft-deleted conversation must drop out of list reads.")
        XCTAssertEqual(try dataStore.countConversations(), 0)
        XCTAssertTrue(try dataStore.fetchSessionLogSummaries().isEmpty)
        XCTAssertTrue(try dataStore.fetchAllSessionLogs().isEmpty)
        XCTAssertEqual(
            try dataStore.fetchConversations(ids: [id]).count, 0,
            "Batch id fetch must exclude tombstones."
        )

        // FTS / full-text scans must not surface the tombstoned body.
        let ftsHits = try dataStore.searchConversationsFTS(query: "secret")
        XCTAssertFalse(ftsHits.contains { $0.conversation.id == id })
        let occurrences = try dataStore.countOccurrencesInConversationFullText(patterns: ["sk-abcdef"])
        XCTAssertEqual(occurrences, 0, "Credential scans must not count tombstoned bodies.")

        // The tombstone bumped version and re-dirtied the row for delete propagation.
        let row = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT deletedAt, version, conversationSyncedAt, logSyncedAt FROM conversations WHERE id = ?",
                arguments: [id]
            )
        }
        XCTAssertNotNil(row?["deletedAt"], "Soft-delete must stamp deletedAt.")
        XCTAssertEqual(row?["version"] as? Int64, 2, "Soft-delete must bump version.")
        XCTAssertNil(row?["conversationSyncedAt"], "Soft-delete must clear the metadata sync flag.")
        XCTAssertNil(row?["logSyncedAt"], "Soft-delete must clear the session-log sync flag.")

        // The tombstone resurfaces for upload (so the delete reaches other devices).
        let unsynced = try dataStore.fetchUnsyncedConversations(limit: 400)
        XCTAssertEqual(unsynced.count, 1)
        XCTAssertNotNil(unsynced.first?.deletedAt, "Unsynced upload set must carry the tombstone.")
    }

    func test_softDelete_payloadEmitsDeletedAtAndVersion() async throws {
        let id = "conv-upload-tombstone"
        try dataStore.upsertConversation(makeRecord(id: id))
        try dataStore.softDeleteConversation(id: id)

        let sync = ConversationSyncService(context: context, vaultKeyProvider: TestConversationVaultKeyProvider())
        await sync.sync()

        let docData = fakeGateway.documentData(at: "users/test-uid-1/conversations/test-device-1_\(id)")
        XCTAssertNotNil(docData?["deletedAt"], "Upload payload must include deletedAt for tombstone propagation.")
        XCTAssertEqual(docData?["version"] as? Int, 2)
    }

    // MARK: - (c) Remote tombstone soft-deletes locally

    func test_remoteTombstone_softDeletesExistingLocalConversation() async throws {
        let remoteDeviceId = "remote-device-2"
        let localId = "\(remoteDeviceId):conv-remote-tomb"
        let remoteUpdatedAt = Date().addingTimeInterval(-60)

        // Seed device + a live (non-deleted) remote conversation, then download it.
        fakeGateway.setDocumentData([
            "deviceName": "Remote Studio",
            "platform": "macOS",
            "lastActiveAt": Timestamp(date: remoteUpdatedAt)
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        let basePayload: [String: Any] = [
            "id": "conv-remote-tomb",
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sessionId": "remote-session-tomb",
            "projectName": "RemoteProject",
            "messageCount": 7,
            "userWordCount": 10,
            "assistantWordCount": 20,
            "keyFiles": [],
            "keyCommands": [],
            "keyTools": [],
            "inferredTaskTitle": "Remote Task",
            "lastAssistantMessage": "hello",
            "sourceType": ConversationSourceType.providerLog.rawValue,
            "version": 1,
            "updatedAt": Timestamp(date: remoteUpdatedAt),
            "startTime": Timestamp(date: remoteUpdatedAt),
            "endTime": Timestamp(date: remoteUpdatedAt.addingTimeInterval(100))
        ]
        let remoteDocPath = "users/test-uid-1/conversations/\(remoteDeviceId)_conv-remote-tomb"
        fakeGateway.setDocumentData(basePayload, at: remoteDocPath)

        let downloadSync = DownloadSyncService(context: context)
        await downloadSync.sync()
        XCTAssertNotNil(try dataStore.fetchConversation(id: localId), "Live remote conversation should land locally.")

        // Device A deletes it: the doc now carries a tombstone with a newer version.
        var tombstoned = basePayload
        tombstoned["deletedAt"] = Timestamp(date: remoteUpdatedAt.addingTimeInterval(10))
        tombstoned["version"] = 2
        tombstoned["updatedAt"] = Timestamp(date: Date())
        fakeGateway.setDocumentData(tombstoned, at: remoteDocPath)

        await downloadSync.sync()

        // The local copy is now tombstoned: invisible to reads, present on disk.
        XCTAssertNil(try dataStore.fetchConversation(id: localId), "Remote tombstone must soft-delete the local copy.")
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT deletedAt, version FROM conversations WHERE id = ?", arguments: [localId])
        }
        XCTAssertNotNil(row?["deletedAt"], "Remote tombstone must stamp the local deletedAt.")
        XCTAssertEqual(row?["version"] as? Int64, 2, "Remote tombstone must advance the local version.")
    }

    func test_remoteTombstone_insertsAlreadyDeletedConversationAsTombstone() async throws {
        let remoteDeviceId = "remote-device-3"
        let localId = "\(remoteDeviceId):conv-born-deleted"
        let remoteUpdatedAt = Date().addingTimeInterval(-60)

        fakeGateway.setDocumentData([
            "deviceName": "Remote Studio",
            "platform": "macOS",
            "lastActiveAt": Timestamp(date: remoteUpdatedAt)
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        fakeGateway.setDocumentData([
            "id": "conv-born-deleted",
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sessionId": "remote-session-born-deleted",
            "projectName": "RemoteProject",
            "messageCount": 3,
            "userWordCount": 1,
            "assistantWordCount": 1,
            "keyFiles": [],
            "keyCommands": [],
            "keyTools": [],
            "inferredTaskTitle": "Already Deleted",
            "lastAssistantMessage": "bye",
            "sourceType": ConversationSourceType.providerLog.rawValue,
            "deletedAt": Timestamp(date: remoteUpdatedAt),
            "version": 4,
            "updatedAt": Timestamp(date: remoteUpdatedAt),
            "startTime": Timestamp(date: remoteUpdatedAt),
            "endTime": Timestamp(date: remoteUpdatedAt.addingTimeInterval(50))
        ], at: "users/test-uid-1/conversations/\(remoteDeviceId)_conv-born-deleted")

        await DownloadSyncService(context: context).sync()

        XCTAssertNil(try dataStore.fetchConversation(id: localId), "A remote conversation that arrives already-deleted must not be visible.")
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT deletedAt, version FROM conversations WHERE id = ?", arguments: [localId])
        }
        XCTAssertNotNil(row?["deletedAt"])
        XCTAssertEqual(row?["version"] as? Int64, 4)
    }

    // MARK: - (d) GC purges after retention

    func test_gc_purgesCloudArtifactsAndLocalRow_afterRetentionWindow() async throws {
        let id = "conv-gc-target"
        try dataStore.upsertConversation(makeRecord(id: id))

        // Tombstone it 31 days ago — past the 30-day retention window.
        let deletedAt = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        try dataStore.softDeleteConversation(id: id, at: deletedAt)

        // Seed the cloud artifacts that GC must purge: manifest + chunks.
        let fetched = try await rawRecord(id: id)
        let record = try XCTUnwrap(fetched)
        let docId = SessionLogSyncService.cloudDocumentID(deviceId: "test-device-1", record: record)
        let storagePath = "users/test-uid-1/session_logs/\(docId)/bodies/deadbeef.json.aesgcm"
        let manifestPath = "users/test-uid-1/session_logs/\(docId)"
        fakeGateway.setDocumentData([
            "id": id,
            "deviceId": "test-device-1",
            "storagePath": storagePath,
            "bodyStorage": "firebase_storage_encrypted"
        ], at: manifestPath)
        fakeGateway.setDocumentData(["index": 0, "tokenHashes": ["h0"]], at: "\(manifestPath)/chunks/0")
        fakeGateway.setDocumentData(["index": 1, "tokenHashes": ["h1"]], at: "\(manifestPath)/chunks/1")

        let fakeCloudClient = FakeSessionLogEncryptedCloudClient()
        let gc = ConversationTombstoneGCService(context: context, encryptedCloudClient: fakeCloudClient)

        // Sanity: the row is still on disk before GC (tombstone, not hard delete).
        let beforeCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations WHERE id = ?", arguments: [id]) ?? 0
        }
        XCTAssertEqual(beforeCount, 1)

        await gc.sync()

        // Cloud body deleted via the encrypted client.
        XCTAssertEqual(fakeCloudClient.deletedBodies.count, 1)
        XCTAssertEqual(fakeCloudClient.deletedBodies.first?.documentID, docId)
        XCTAssertEqual(fakeCloudClient.deletedBodies.first?.storagePath, storagePath)

        // Search-index chunks and the manifest are gone.
        XCTAssertTrue(fakeGateway.documents(under: "\(manifestPath)/chunks").isEmpty, "GC must delete the search-index chunks.")
        XCTAssertNil(fakeGateway.documentData(at: manifestPath), "GC must delete the session-log manifest.")

        // The local row is hard-deleted once cloud cleanup succeeds.
        let afterCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations WHERE id = ?", arguments: [id]) ?? 0
        }
        XCTAssertEqual(afterCount, 0, "GC must hard-delete the local row after the retention window.")
    }

    func test_gc_leavesFreshTombstonesUntouched_beforeRetentionWindow() async throws {
        let id = "conv-gc-fresh"
        try dataStore.upsertConversation(makeRecord(id: id))
        // Deleted just now — well inside the retention window.
        try dataStore.softDeleteConversation(id: id, at: Date())

        let fakeCloudClient = FakeSessionLogEncryptedCloudClient()
        let gc = ConversationTombstoneGCService(context: context, encryptedCloudClient: fakeCloudClient)
        await gc.sync()

        XCTAssertTrue(fakeCloudClient.deletedBodies.isEmpty, "Fresh tombstones must survive the retention window.")
        let stillPresent = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations WHERE id = ?", arguments: [id]) ?? 0
        }
        XCTAssertEqual(stillPresent, 1, "Fresh tombstone must remain on disk for offline-device sync.")
    }

    // MARK: - Helpers

    private func makeRecord(id: String, fullText: String = "User\n\nAssistant") -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: .claudeCode,
            sessionId: "session-\(id)",
            projectName: "TombstoneProject",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            messageCount: 4,
            userWordCount: 2,
            assistantWordCount: 2,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Tombstone Task",
            lastAssistantMessage: "Done",
            fullText: fullText,
            fileModifiedAt: nil
        )
    }

    /// Reads the raw row (including tombstoned) so GC tests can rebuild the
    /// record used to compute the cloud document id.
    private func rawRecord(id: String) async throws -> ConversationRecord? {
        try await queue.read { db in
            try ConversationStore.fetchConversationRow(db, id: id)
        }
    }
}
