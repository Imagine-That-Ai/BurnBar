import XCTest
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class ChatThreadSyncServiceTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var chatThreadSync: ChatThreadSyncService!

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
        chatThreadSync = ChatThreadSyncService(context: context)
    }

    func test_syncWithoutChatContentConsentWritesMetadataOnly() async throws {
        try seedThread()

        await chatThreadSync.sync()

        let docData = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/chat_threads/test-device-1_thread-1"))
        XCTAssertEqual(docData["threadId"] as? String, "thread-1")
        XCTAssertEqual(docData["messageCount"] as? Int, 2)
        XCTAssertEqual(docData["deviceId"] as? String, "test-device-1")
        XCTAssertEqual(docData["contentIncluded"] as? Bool, false)
        XCTAssertFalse(docData.values.contains { value in
            String(describing: value).contains("secret prompt")
        })
        XCTAssertFalse(docData.values.contains { value in
            String(describing: value).contains("secret response")
        })
    }

    func test_syncWithChatContentConsentWritesMessages() async throws {
        settingsManager.chatThreadContentCloudBackupEnabled = true
        settingsManager.chatThreadContentCloudBackupConsentShown = true
        try seedThread()

        await chatThreadSync.sync()

        let docData = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/chat_threads/test-device-1_thread-1"))
        XCTAssertEqual(docData["contentIncluded"] as? Bool, true)
        XCTAssertNotNil(docData["title"])
        XCTAssertNotNil(docData["preview"])
        let messages = try XCTUnwrap(docData["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?["content"] as? String, "secret prompt")
    }

    func test_syncAfterChatContentConsentRevokedDeletesCloudContentFields() async throws {
        settingsManager.chatThreadContentCloudBackupEnabled = true
        settingsManager.chatThreadContentCloudBackupConsentShown = true
        try seedThread()

        await chatThreadSync.sync()

        var docData = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/chat_threads/test-device-1_thread-1"))
        XCTAssertEqual(docData["contentIncluded"] as? Bool, true)
        XCTAssertNotNil(docData["messages"])
        XCTAssertNotNil(docData["title"])
        XCTAssertNotNil(docData["preview"])

        settingsManager.chatThreadContentCloudBackupEnabled = false
        await chatThreadSync.sync()

        docData = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/chat_threads/test-device-1_thread-1"))
        XCTAssertEqual(docData["contentIncluded"] as? Bool, false)
        XCTAssertNil(docData["messages"])
        XCTAssertNil(docData["title"])
        XCTAssertNil(docData["preview"])
        XCTAssertFalse(docData.values.contains { value in
            String(describing: value).contains("secret prompt")
        })
        XCTAssertFalse(docData.values.contains { value in
            String(describing: value).contains("secret response")
        })
    }

    private func seedThread() throws {
        _ = try dataStore.createChatThread(id: "thread-1", at: Date(timeIntervalSince1970: 1_700_000_000))
        try dataStore.saveChatMessage(
            ChatMessageRecord(
                id: "msg-1",
                role: .user,
                content: "secret prompt",
                timestamp: Date(timeIntervalSince1970: 1_700_000_010)
            ),
            threadID: "thread-1"
        )
        try dataStore.saveChatMessage(
            ChatMessageRecord(
                id: "msg-2",
                role: .assistant,
                content: "secret response",
                timestamp: Date(timeIntervalSince1970: 1_700_000_020),
                cliUsed: "codex"
            ),
            threadID: "thread-1"
        )
    }
}
