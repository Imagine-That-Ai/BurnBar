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
        try await seedThread()

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
        try await seedThread()

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
        let aadContext = try chatThreadAADContext(docId: "test-device-1_thread-1")
        XCTAssertEqual(envelope.aad, aadContext.stringValue)
        let opened = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKeyProvider.keyData, aadContext: aadContext)
        let payload = try Self.sealedPayloadDecoder.decode(DecodedChatThreadPayload.self, from: opened)
        XCTAssertEqual(payload.threadId, "thread-1")
        XCTAssertEqual(payload.messages.count, 2)
        XCTAssertEqual(payload.messages.first?.content, "secret prompt")
        XCTAssertEqual(payload.messages.last?.content, "secret response")

        let relocatedContext = try chatThreadAADContext(docId: "test-device-1_thread-relocated")
        XCTAssertThrowsError(
            try CloudVaultCrypto.openPayload(envelope, keyData: vaultKeyProvider.keyData, aadContext: relocatedContext)
        )
    }

    func test_syncAfterChatContentConsentRevokedDeletesCloudContentFields() async throws {
        settingsManager.chatThreadContentCloudBackupEnabled = true
        settingsManager.chatThreadContentCloudBackupConsentShown = true
        try await seedThread()

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

    // MARK: - Fail-closed: a DB read failure must not masquerade as an empty thread

    /// When content backup is enabled and the per-thread message fetch THROWS, the service
    /// must skip that thread entirely (fail closed) rather than seal-and-upload an empty
    /// payload that would overwrite the prior good cloud record. A previously uploaded
    /// sealed record for that thread must survive the failed sync untouched.
    func test_messageFetchFailurePreservesPriorRecordInsteadOfWipingItWithEmptyContent() async throws {
        settingsManager.chatThreadContentCloudBackupEnabled = true
        settingsManager.chatThreadContentCloudBackupConsentShown = true
        try await seedThread()

        // First sync succeeds and writes the real sealed payload.
        await chatThreadSync.sync()
        let path = "users/test-uid-1/chat_threads/test-device-1_thread-1"
        let priorData = try XCTUnwrap(fakeGateway.documentData(at: path))
        let priorSealed = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: priorData["sealedPayload"]))
        let aadContext = try chatThreadAADContext(docId: "test-device-1_thread-1")
        let priorOpened = try CloudVaultCrypto.openPayload(priorSealed, keyData: vaultKeyProvider.keyData, aadContext: aadContext)
        let priorPayload = try Self.sealedPayloadDecoder.decode(DecodedChatThreadPayload.self, from: priorOpened)
        XCTAssertEqual(priorPayload.messages.count, 2)

        // Second sync: the message fetch now FAILS for this thread.
        let failingSync = ChatThreadSyncService(
            context: context,
            vaultKeyProvider: vaultKeyProvider,
            messageFetcher: { _ in throw ChatMessageFetchTestError.simulatedReadFault }
        )
        await failingSync.sync()

        // The prior good record must be intact — NOT replaced by an empty-content payload.
        let afterData = try XCTUnwrap(fakeGateway.documentData(at: path))
        let afterSealed = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: afterData["sealedPayload"]))
        let afterOpened = try CloudVaultCrypto.openPayload(afterSealed, keyData: vaultKeyProvider.keyData, aadContext: aadContext)
        let afterPayload = try Self.sealedPayloadDecoder.decode(DecodedChatThreadPayload.self, from: afterOpened)
        XCTAssertEqual(afterPayload.messages.count, 2, "failed fetch must not overwrite prior content with an empty payload")
        XCTAssertEqual(afterPayload.messages.first?.content, "secret prompt")
        XCTAssertEqual(afterPayload.messages.last?.content, "secret response")
        XCTAssertEqual(afterData["contentIncluded"] as? Bool, true)
        XCTAssertEqual(afterData["contentSealed"] as? Bool, true)
    }

    /// A first-ever upload whose message fetch fails must write NO sealed record at all,
    /// rather than seal an empty (content-claiming) payload.
    func test_messageFetchFailureOnFirstUploadWritesNoSealedRecord() async throws {
        settingsManager.chatThreadContentCloudBackupEnabled = true
        settingsManager.chatThreadContentCloudBackupConsentShown = true
        try await seedThread()

        let failingSync = ChatThreadSyncService(
            context: context,
            vaultKeyProvider: vaultKeyProvider,
            messageFetcher: { _ in throw ChatMessageFetchTestError.simulatedReadFault }
        )
        await failingSync.sync()

        let path = "users/test-uid-1/chat_threads/test-device-1_thread-1"
        XCTAssertNil(
            fakeGateway.documentData(at: path),
            "a failed message fetch must not write a thread record claiming content with an empty payload"
        )
    }

    /// A fetch failure on ONE thread must not poison the others: a healthy thread still
    /// uploads its real sealed payload, and the failing thread is silently skipped.
    func test_messageFetchFailureOnOneThreadDoesNotBlockHealthyThreads() async throws {
        settingsManager.chatThreadContentCloudBackupEnabled = true
        settingsManager.chatThreadContentCloudBackupConsentShown = true
        try await seedThread()
        try await seedSecondThread()

        // Throw only for thread-1; thread-2 reads succeed (delegate to the real store).
        let realStore = try XCTUnwrap(dataStore)
        let selectiveSync = ChatThreadSyncService(
            context: context,
            vaultKeyProvider: vaultKeyProvider,
            messageFetcher: { threadID in
                if threadID == "thread-1" {
                    throw ChatMessageFetchTestError.simulatedReadFault
                }
                return try await realStore.fetchChatMessages(threadID: threadID)
            }
        )
        await selectiveSync.sync()

        // Failing thread: no record written.
        XCTAssertNil(fakeGateway.documentData(at: "users/test-uid-1/chat_threads/test-device-1_thread-1"))

        // Healthy thread: real sealed content present.
        let healthyData = try XCTUnwrap(
            fakeGateway.documentData(at: "users/test-uid-1/chat_threads/test-device-1_thread-2")
        )
        XCTAssertEqual(healthyData["contentIncluded"] as? Bool, true)
        let healthySealed = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: healthyData["sealedPayload"]))
        let healthyOpened = try CloudVaultCrypto.openPayload(
            healthySealed,
            keyData: vaultKeyProvider.keyData,
            aadContext: chatThreadAADContext(docId: "test-device-1_thread-2")
        )
        let healthyPayload = try Self.sealedPayloadDecoder.decode(DecodedChatThreadPayload.self, from: healthyOpened)
        XCTAssertEqual(healthyPayload.threadId, "thread-2")
        XCTAssertEqual(healthyPayload.messages.first?.content, "second secret")

        // The whole sync still counts as a success — a per-thread skip is graceful, not fatal.
        XCTAssertNil(selectiveSync.lastSyncError)
        XCTAssertNotNil(selectiveSync.lastSyncDate)
    }

    private static var sealedPayloadDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func chatThreadAADContext(docId: String) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: "test-uid-1",
            collection: "chat_threads",
            docID: docId,
            field: "sealedPayload"
        )
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

    private func seedThread() async throws {
        _ = try await dataStore.createChatThread(id: "thread-1", at: Date(timeIntervalSince1970: 1_700_000_000))
        try await dataStore.saveChatMessage(
            ChatMessageRecord(
                id: "msg-1",
                role: .user,
                content: "secret prompt",
                timestamp: Date(timeIntervalSince1970: 1_700_000_010)
            ),
            threadID: "thread-1"
        )
        try await dataStore.saveChatMessage(
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

    private func seedSecondThread() async throws {
        _ = try await dataStore.createChatThread(id: "thread-2", at: Date(timeIntervalSince1970: 1_700_000_100))
        try await dataStore.saveChatMessage(
            ChatMessageRecord(
                id: "msg-2-1",
                role: .user,
                content: "second secret",
                timestamp: Date(timeIntervalSince1970: 1_700_000_110)
            ),
            threadID: "thread-2"
        )
    }
}

private enum ChatMessageFetchTestError: Error {
    case simulatedReadFault
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
