import XCTest
import GRDB
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class SessionLogSyncRoundTripTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var sessionLogSync: SessionLogSyncService!
    private var downloadSync: DownloadSyncService!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        settingsManager.sessionLogCloudBackupEnabled = true
        fakeGateway = CloudSyncFirestoreFakeGateway()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
        sessionLogSync = SessionLogSyncService(context: context)
        downloadSync = DownloadSyncService(context: context)
    }

    // MARK: - Upload

    func test_sessionLogUpload_writesCheapSearchMetadataOnExistingChunks() async throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .kimi, sessionId: "session-kimi-1"),
            provider: .kimi,
            sessionId: "session-kimi-1",
            projectName: "MobileSearch",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_120),
            messageCount: 2,
            userWordCount: 5,
            assistantWordCount: 8,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Find firebase search path",
            lastAssistantMessage: "Use existing chunks.",
            fullText: "How do we search previous streams cheaply?\nReuse the opt-in Firebase session log chunk path.",
            fileModifiedAt: nil,
            summaryTitle: "Cheap Firebase Search"
        )
        try dataStore.upsertConversation(record)

        await sessionLogSync.sync()

        let safeId = record.id.replacingOccurrences(of: ":", with: "_")
        let docId = "test-device-1_\(safeId)"
        let manifest = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/session_logs/\(docId)"))
        XCTAssertEqual(manifest["sessionId"] as? String, "session-kimi-1")
        XCTAssertEqual(manifest["model"] as? String, "unknown")
        XCTAssertNotNil(manifest["bodyHash"] as? String)
        XCTAssertEqual(manifest["chunkMetadataVersion"] as? Int, 1)

        let chunk = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/session_logs/\(docId)/chunks/0"))
        XCTAssertEqual(chunk["uid"] as? String, "test-uid-1")
        XCTAssertEqual(chunk["sessionId"] as? String, "session-kimi-1")
        XCTAssertEqual(chunk["deviceId"] as? String, "test-device-1")
        XCTAssertEqual(chunk["docId"] as? String, docId)
        XCTAssertEqual(chunk["schemaVersion"] as? Int, 1)
        let terms = try XCTUnwrap(chunk["terms"] as? [String])
        XCTAssertTrue(terms.contains("firebase"))
        XCTAssertTrue(terms.contains("search"))
    }

    func test_sessionLogUpload_skipsUnchangedBodyToAvoidExtraWrites() async throws {
        let record = ConversationRecord(
            id: ConversationRecord.stableId(provider: .factory, sessionId: "unchanged-session"),
            provider: .factory,
            sessionId: "unchanged-session",
            projectName: "CheapSync",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_120),
            messageCount: 1,
            userWordCount: 4,
            assistantWordCount: 4,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Avoid duplicate chunk writes",
            lastAssistantMessage: "Done.",
            fullText: "Stable transcript body.",
            fileModifiedAt: nil
        )
        try dataStore.upsertConversation(record)

        await sessionLogSync.sync()
        let commitsAfterFirstSync = fakeGateway.batchCommitCount
        XCTAssertGreaterThan(commitsAfterFirstSync, 0)

        try await dataStore.dbQueue.write { db in
            try db.execute(sql: "UPDATE conversations SET logSyncedAt = NULL WHERE id = ?", arguments: [record.id])
        }

        await sessionLogSync.sync()
        XCTAssertEqual(fakeGateway.batchCommitCount, commitsAfterFirstSync)
        XCTAssertTrue(try dataStore.fetchUnsyncedSessionLogs().isEmpty)
    }

    // MARK: - Download

    func test_sessionLogDownload_reassemblesBody() async throws {
        let docId = "remote-device-2_session-log-remote"
        let manifestPath = "users/test-uid-1/session_logs/\(docId)"
        let chunkPrefix = "\(manifestPath)/chunks"

        let largeBody = String(repeating: "B", count: 1_000_000)
        let chunks = SessionLogSyncService.chunkUTF8String(largeBody, maxBytes: 900_000)
        XCTAssertGreaterThanOrEqual(chunks.count, 2)

        fakeGateway.setDocumentData([
            "id": "session-log-remote",
            "deviceId": "remote-device-2",
            "provider": AgentProvider.cursor.rawValue,
            "sourceType": ConversationSourceType.providerLog.rawValue,
            "projectName": "RemoteProject",
            "inferredTaskTitle": "Remote Task",
            "messageCount": 5,
            "chunkCount": chunks.count,
            "byteCount": largeBody.utf8.count
        ], at: manifestPath)

        for (idx, chunk) in chunks.enumerated() {
            fakeGateway.setDocumentData([
                "index": idx,
                "body": chunk
            ], at: "\(chunkPrefix)/\(idx)")
        }

        let body = try await downloadSync.fetchCloudSessionLogBody(docId: docId)
        XCTAssertEqual(body, largeBody)
    }

    func test_sessionLogDownload_viaFullSync_populatesConversationFullText() async throws {
        let remoteDeviceId = "remote-device-2"
        let remoteConvId = "conv-remote-log"
        let docId = "\(remoteDeviceId)_\(remoteConvId)"
        let manifestPath = "users/test-uid-1/session_logs/\(docId)"
        let updatedAt = Date().addingTimeInterval(-60) // recent enough to pass 90-day watermark

        let body = "# Remote Session Log\n\nThis is the full markdown body."

        // Seed conversation metadata
        let convDocPath = "users/test-uid-1/conversations/\(remoteDeviceId)_\(remoteConvId)"
        fakeGateway.setDocumentData([
            "id": remoteConvId,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sessionId": "remote-session",
            "projectName": "RemoteProject",
            "messageCount": 3,
            "userWordCount": 10,
            "assistantWordCount": 20,
            "keyFiles": [],
            "keyCommands": [],
            "keyTools": [],
            "inferredTaskTitle": "Remote Task",
            "lastAssistantMessage": "Remote msg",
            "sourceType": ConversationSourceType.providerLog.rawValue,
            "updatedAt": Timestamp(date: updatedAt),
            "startTime": Timestamp(date: updatedAt),
            "endTime": Timestamp(date: updatedAt.addingTimeInterval(100))
        ], at: convDocPath)

        // Seed session log manifest and chunk
        fakeGateway.setDocumentData([
            "id": remoteConvId,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sourceType": ConversationSourceType.providerLog.rawValue,
            "projectName": "RemoteProject",
            "inferredTaskTitle": "Remote Task",
            "messageCount": 3,
            "chunkCount": 1,
            "byteCount": body.utf8.count
        ], at: manifestPath)

        fakeGateway.setDocumentData([
            "index": 0,
            "body": body
        ], at: "\(manifestPath)/chunks/0")

        // Seed device registry
        fakeGateway.setDocumentData([
            "deviceName": "Remote Studio",
            "platform": "macOS",
            "lastActiveAt": updatedAt
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        await downloadSync.sync()

        let conversations = try await dataStore.fetchConversations()
        let remoteConversations = conversations.filter { $0.isRemote }
        XCTAssertEqual(remoteConversations.count, 1)

        let remote = remoteConversations.first!
        XCTAssertEqual(remote.fullText, body)
    }
}
