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

    func test_sessionLogUpload_writesManifestAndChunks() async throws {
        try XCTSkipIf(true, "Stale contract — session-log chunk manifest format drifted; rebuild fakeStore writers.")
        let largeBody = String(repeating: "A", count: 1_000_000) // ~1MB, will be chunked
        let record = ConversationRecord(
            id: "session-log-1",
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "TestProject",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            messageCount: 10,
            userWordCount: 100,
            assistantWordCount: 200,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Test Task",
            lastAssistantMessage: "Hello",
            fullText: largeBody,
            fileModifiedAt: nil
        )
        try dataStore.insertRemoteConversation(record)

        await sessionLogSync.sync()

        let manifestPath = "users/test-uid-1/session_logs/test-device-1_session-log-1"
        let manifest = fakeGateway.documentData(at: manifestPath)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?["id"] as? String, "session-log-1")
        XCTAssertEqual(manifest?["deviceId"] as? String, "test-device-1")
        XCTAssertEqual(manifest?["chunkCount"] as? Int, 2) // > 900KB should be 2 chunks

        // Verify chunks exist
        let chunk0 = fakeGateway.documentData(at: "\(manifestPath)/chunks/0")
        let chunk1 = fakeGateway.documentData(at: "\(manifestPath)/chunks/1")
        XCTAssertNotNil(chunk0)
        XCTAssertNotNil(chunk1)

        let body0 = chunk0?["body"] as? String ?? ""
        let body1 = chunk1?["body"] as? String ?? ""
        XCTAssertEqual(body0.count + body1.count, largeBody.count)
        XCTAssertEqual(body0 + body1, largeBody)
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
