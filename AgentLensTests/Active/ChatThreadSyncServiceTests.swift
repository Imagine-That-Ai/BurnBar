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
    private var vaultKeyProvider: TestConversationVaultKeyProvider!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        fakeGateway = CloudSyncFirestoreFakeGateway()
        vaultKeyProvider = TestConversationVaultKeyProvider()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
        chatThreadSync = ChatThreadSyncService(context: context, vaultKeyProvider: vaultKeyProvider)
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

    func test_syncWithChatContentConsentWritesSealedPayloadOnly() async throws {
        settingsManager.chatThreadContentCloudBackupEnabled = true
        settingsManager.chatThreadContentCloudBackupConsentShown = true
        try seedThread()

        await chatThreadSync.sync()

        let docData = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/chat_threads/test-device-1_thread-1"))
        XCTAssertEqual(docData["contentIncluded"] as? Bool, true)
        XCTAssertEqual(docData["contentSealed"] as? Bool, true)
        XCTAssertEqual(docData["sealedSchemaVersion"] as? Int, CloudVaultCrypto.currentSealedPayloadSchemaVersion)
        XCTAssertEqual(docData["vaultKeyID"] as? String, try vaultKeyProvider.resolvedKey().vaultKeyID)
        XCTAssertNil(docData["title"])
        XCTAssertNil(docData["preview"])
        XCTAssertNil(docData["messages"])
        assertNoPlaintextSecrets(in: docData)

        let envelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: docData["sealedPayload"]))
        XCTAssertEqual(envelope.aad, CloudVaultCrypto.sealedPayloadAADContext)
        let opened = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKeyProvider.keyData)
        let payload = try Self.sealedPayloadDecoder.decode(DecodedChatThreadPayload.self, from: opened)
        XCTAssertEqual(payload.threadId, "thread-1")
        XCTAssertEqual(payload.messages.count, 2)
        XCTAssertEqual(payload.messages.first?.content, "secret prompt")
        XCTAssertEqual(payload.messages.last?.content, "secret response")
    }

    func test_syncAfterChatContentConsentRevokedDeletesCloudContentFields() async throws {
        settingsManager.chatThreadContentCloudBackupEnabled = true
        settingsManager.chatThreadContentCloudBackupConsentShown = true
        try seedThread()

        await chatThreadSync.sync()

        var docData = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/chat_threads/test-device-1_thread-1"))
        XCTAssertEqual(docData["contentIncluded"] as? Bool, true)
        XCTAssertEqual(docData["contentSealed"] as? Bool, true)
        XCTAssertNotNil(docData["sealedPayload"])
        XCTAssertNil(docData["messages"])
        XCTAssertNil(docData["title"])
        XCTAssertNil(docData["preview"])

        settingsManager.chatThreadContentCloudBackupEnabled = false
        await chatThreadSync.sync()

        docData = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/chat_threads/test-device-1_thread-1"))
        XCTAssertEqual(docData["contentIncluded"] as? Bool, false)
        XCTAssertNil(docData["messages"])
        XCTAssertNil(docData["title"])
        XCTAssertNil(docData["preview"])
        XCTAssertNil(docData["sealedPayload"])
        XCTAssertNil(docData["vaultKeyID"])
        XCTAssertEqual(docData["contentSealed"] as? Bool, false)
        assertNoPlaintextSecrets(in: docData)
    }

    private static var sealedPayloadDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func assertNoPlaintextSecrets(in value: Any, file: StaticString = #filePath, line: UInt = #line) {
        if let string = value as? String {
            XCTAssertFalse(string.contains("secret prompt"), file: file, line: line)
            XCTAssertFalse(string.contains("secret response"), file: file, line: line)
            return
        }
        if let dictionary = value as? [String: Any] {
            dictionary.values.forEach { assertNoPlaintextSecrets(in: $0, file: file, line: line) }
            return
        }
        if let array = value as? [Any] {
            array.forEach { assertNoPlaintextSecrets(in: $0, file: file, line: line) }
        }
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

private struct DecodedChatThreadPayload: Decodable {
    struct Message: Decodable {
        let id: String
        let role: String
        let content: String
        let timestamp: Date
        let cliUsed: String?
    }

    let threadId: String
    let title: String
    let preview: String
    let messages: [Message]
}
