import XCTest
import GRDB
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class ConversationSyncRoundTripTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var conversationSync: ConversationSyncService!
    private var downloadSync: DownloadSyncService!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        fakeGateway = CloudSyncFirestoreFakeGateway()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
        conversationSync = ConversationSyncService(context: context)
        downloadSync = DownloadSyncService(context: context)
    }

    // MARK: - Write → Read Round Trip

    func test_conversationUpload_writesToFirestoreAndMarksSynced() async throws {
        let now = Date()
        let record = ConversationRecord(
            id: "conv-1",
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "TestProject",
            startTime: now,
            endTime: now.addingTimeInterval(100),
            messageCount: 10,
            userWordCount: 100,
            assistantWordCount: 200,
            keyFiles: ["file1.swift"],
            keyCommands: ["git status"],
            keyTools: [],
            inferredTaskTitle: "Test Task",
            lastAssistantMessage: "Hello world",
            fullText: "Full text here",
            fileModifiedAt: nil
        )
        try dataStore.upsertConversation(record)

        let unsyncedBefore = try dataStore.fetchUnsyncedConversations(limit: 400)
        XCTAssertEqual(unsyncedBefore.count, 1)

        await conversationSync.sync()

        let docPath = "users/test-uid-1/conversations/test-device-1_conv-1"
        let docData = fakeGateway.documentData(at: docPath)
        XCTAssertNotNil(docData)
        XCTAssertEqual(docData?["provider"] as? String, AgentProvider.claudeCode.rawValue)
        XCTAssertEqual(docData?["sessionId"] as? String, "session-1")
        XCTAssertEqual(docData?["messageCount"] as? Int, 10)
        XCTAssertEqual(docData?["deviceId"] as? String, "test-device-1")

        let unsyncedAfter = try dataStore.fetchUnsyncedConversations(limit: 400)
        XCTAssertTrue(unsyncedAfter.isEmpty)
    }

    func test_conversationDownload_readsRemoteConversationIntoLocalStore() async throws {
        let remoteDeviceId = "remote-device-2"
        let remoteDocPath = "users/test-uid-1/conversations/\(remoteDeviceId)_conv-remote-1"
        let remoteUpdatedAt = Date().addingTimeInterval(-60) // recent enough to pass 90-day watermark

        fakeGateway.setDocumentData([
            "id": "conv-remote-1",
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sessionId": "remote-session-1",
            "projectName": "RemoteProject",
            "messageCount": 42,
            "userWordCount": 500,
            "assistantWordCount": 1000,
            "keyFiles": ["remote.swift"],
            "keyCommands": [],
            "keyTools": [],
            "inferredTaskTitle": "Remote Task",
            "lastAssistantMessage": "Remote hello",
            "sourceType": ConversationSourceType.providerLog.rawValue,
            "updatedAt": Timestamp(date: remoteUpdatedAt),
            "startTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)),
            "endTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_100))
        ], at: remoteDocPath)

        fakeGateway.setDocumentData([
            "deviceName": "Remote Studio",
            "platform": "macOS",
            "lastActiveAt": Timestamp(date: remoteUpdatedAt)
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        await downloadSync.sync()

        let conversations = try dataStore.fetchConversations()
        let remoteConversations = conversations.filter { $0.isRemote }
        XCTAssertEqual(remoteConversations.count, 1)

        let remote = remoteConversations.first!
        XCTAssertEqual(remote.id, "\(remoteDeviceId):conv-remote-1")
        XCTAssertEqual(remote.provider, AgentProvider.cursor)
        XCTAssertEqual(remote.sessionId, "remote-session-1")
        XCTAssertEqual(remote.messageCount, 42)
        XCTAssertEqual(remote.sourceDeviceId, remoteDeviceId)
        XCTAssertEqual(remote.sourceDeviceName, "Remote Studio")
        XCTAssertTrue(remote.isRemote)
    }

    func test_conversationRoundTrip_downloadDoesNotOverwriteLocal() async throws {
        let now = Date()
        // Insert a local conversation
        try dataStore.upsertConversation(ConversationRecord(
            id: "conv-1",
            provider: .factory,
            sessionId: "local-session",
            projectName: "LocalProject",
            startTime: now,
            endTime: now.addingTimeInterval(100),
            messageCount: 5,
            userWordCount: 50,
            assistantWordCount: 100,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Local Task",
            lastAssistantMessage: "Local hello",
            fullText: "Local full text",
            fileModifiedAt: nil
        ))

        // Upload it
        await conversationSync.sync()

        // Now simulate the same conversation coming back from remote with different data
        // Because local uses INSERT OR IGNORE, it should NOT overwrite
        let remoteDocPath = "users/test-uid-1/conversations/remote-device-2_conv-1"
        let remoteUpdatedAt = now.addingTimeInterval(-60)
        fakeGateway.setDocumentData([
            "id": "conv-1",
            "deviceId": "remote-device-2",
            "provider": AgentProvider.aider.rawValue,
            "sessionId": "remote-session",
            "projectName": "ChangedProject",
            "messageCount": 99,
            "userWordCount": 999,
            "assistantWordCount": 9999,
            "keyFiles": [],
            "keyCommands": [],
            "keyTools": [],
            "inferredTaskTitle": "Changed Task",
            "lastAssistantMessage": "Changed hello",
            "sourceType": ConversationSourceType.providerLog.rawValue,
            "updatedAt": Timestamp(date: remoteUpdatedAt),
            "startTime": Timestamp(date: remoteUpdatedAt),
            "endTime": Timestamp(date: remoteUpdatedAt.addingTimeInterval(100))
        ], at: remoteDocPath)

        fakeGateway.setDocumentData([
            "deviceName": "Remote Studio",
            "platform": "macOS",
            "lastActiveAt": Timestamp(date: remoteUpdatedAt)
        ], at: "users/test-uid-1/devices/remote-device-2")

        await downloadSync.sync()

        let conversations = try dataStore.fetchConversations()
        // Should have both local and remote (remote gets stableId "remote-device-2:conv-1")
        XCTAssertEqual(conversations.count, 2)

        let local = conversations.first { $0.id == "conv-1" }
        XCTAssertNotNil(local)
        XCTAssertEqual(local?.provider, AgentProvider.factory)
        XCTAssertEqual(local?.messageCount, 5)
    }
}
