import XCTest
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

/// Behavioral coverage for the three `try?` error-swallows that were judged to
/// MATTER in `DownloadSyncService`:
///
///  - `updateLocalDeviceName` (was a fire-and-forget `try?` write): a write
///    failure must NOT crash and must NOT corrupt local state, while a healthy
///    write still lands in Firestore.
///  - usage download vault-key read (was `try? await keyForReading`): a real
///    provider FAULT (e.g. `vaultKeyMismatch`) must be caught and degrade to a
///    nil key — opening sealed project names FAIL-CLOSED to "" — without
///    aborting the rest of the download.
///  - conversation download vault-key read (was `try? await keyForReading`): a
///    real provider FAULT must be caught and leave the vault key nil so the
///    Signal/AES open FAILS CLOSED (peer doc skipped, never imported with
///    unverified content) and is resolved at most once per cycle.
@MainActor
final class DownloadSyncServiceMattersTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!

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
    }

    private func makeDownloadSync(
        provider: any ConversationCloudVaultKeyProviding = TestConversationVaultKeyProvider()
    ) -> DownloadSyncService {
        DownloadSyncService(context: context, conversationVaultKeyProvider: provider)
    }

    // MARK: - L91: device-name write

    func test_updateLocalDeviceName_writesToFirestore() async throws {
        let downloadSync = makeDownloadSync()

        await downloadSync.updateLocalDeviceName("Studio Mac")

        let doc = try XCTUnwrap(
            fakeGateway.documentData(at: "users/test-uid-1/devices/test-device-1"),
            "Device-name write should land in Firestore"
        )
        XCTAssertEqual(doc["deviceName"] as? String, "Studio Mac")
    }

    func test_updateLocalDeviceName_writeFailure_degradesGracefullyAndDoesNotCorrupt() async throws {
        let downloadSync = makeDownloadSync()

        // Terminal NSError => classified .terminal, thrown immediately (no backoff sleep).
        fakeGateway.nextError = NSError(domain: "UnitTest", code: 1)
        // Must not crash / must not throw out of the actor method.
        await downloadSync.updateLocalDeviceName("Studio Mac")
        fakeGateway.nextError = nil

        // Failure left no partial / corrupt document behind.
        XCTAssertNil(
            fakeGateway.documentData(at: "users/test-uid-1/devices/test-device-1"),
            "A failed write must not leave a partial device document"
        )

        // The next healthy call still lands — the failure was non-fatal and recoverable.
        await downloadSync.updateLocalDeviceName("Studio Mac")
        let doc = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/devices/test-device-1"))
        XCTAssertEqual(doc["deviceName"] as? String, "Studio Mac")
    }

    // MARK: - L330: usage vault-key read

    func test_usageDownload_vaultKeyProviderThrows_failsClosedAndStillImports() async throws {
        // A peer usage row whose project name is SEALED with the real vault key.
        let keyData = Data(repeating: 0x42, count: 32)
        let sealed = try CloudVaultCrypto.sealText("Top Secret Project", keyData: keyData)
        let sealedDict = try CloudVaultCrypto.firestoreDictionary(sealed)

        let remoteDeviceId = "remote-device-9"
        let remoteUsageId = UUID().uuidString
        let now = Date()
        fakeGateway.setDocumentData([
            "id": remoteUsageId,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sessionId": "sealed-usage-session",
            "sealedProjectName": sealedDict,
            "model": "gpt-4",
            "inputTokens": 10,
            "outputTokens": 5,
            "cost": 0.01,
            "startTime": Timestamp(date: now),
            "endTime": Timestamp(date: now.addingTimeInterval(1)),
            "updatedAt": Timestamp(date: now)
        ], at: "users/test-uid-1/usage/\(remoteDeviceId)_\(remoteUsageId)")

        // Provider THROWS (a real fault, e.g. vault-key rotation / state corruption).
        let throwingProvider = ThrowingVaultKeyProvider(
            error: CloudVaultAccessError.vaultKeyMismatch(expected: "vk-A", actual: "vk-B")
        )
        let downloadSync = makeDownloadSync(provider: throwingProvider)

        await downloadSync.sync()

        // The download still completed and imported the peer row (throw was caught,
        // not propagated up the download pipeline).
        let remoteUsages = try await dataStore.fetchAllUsage().filter { $0.isRemote }
        XCTAssertEqual(remoteUsages.count, 1, "Peer usage row must still import despite the key fault")

        // FAIL CLOSED: with no usable key, the sealed project name is NOT opened.
        // It must never leak ciphertext and must never fall back to plaintext.
        XCTAssertEqual(remoteUsages.first?.projectName, "", "Sealed project name must fail closed to empty")
    }

    func test_usageDownload_vaultKeyProviderSucceeds_opensSealedProjectName() async throws {
        let keyData = Data(repeating: 0x42, count: 32)
        let sealed = try CloudVaultCrypto.sealText("Top Secret Project", keyData: keyData)
        let sealedDict = try CloudVaultCrypto.firestoreDictionary(sealed)

        let remoteDeviceId = "remote-device-10"
        let remoteUsageId = UUID().uuidString
        let now = Date()
        fakeGateway.setDocumentData([
            "id": remoteUsageId,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sessionId": "sealed-usage-session-ok",
            "sealedProjectName": sealedDict,
            "model": "gpt-4",
            "inputTokens": 10,
            "outputTokens": 5,
            "cost": 0.01,
            "startTime": Timestamp(date: now),
            "endTime": Timestamp(date: now.addingTimeInterval(1)),
            "updatedAt": Timestamp(date: now)
        ], at: "users/test-uid-1/usage/\(remoteDeviceId)_\(remoteUsageId)")

        // Provider SUCCEEDS with the matching key — the control case.
        let downloadSync = makeDownloadSync(provider: TestConversationVaultKeyProvider(keyData: keyData))

        await downloadSync.sync()

        let remoteUsages = try await dataStore.fetchAllUsage().filter { $0.isRemote }
        XCTAssertEqual(remoteUsages.count, 1)
        XCTAssertEqual(remoteUsages.first?.projectName, "Top Secret Project")
    }

    // MARK: - L453: conversation vault-key read

    func test_conversationDownload_vaultKeyProviderThrows_skipsPeerDocAndResolvesKeyOnce() async throws {
        // Two peer conversation docs sealed with the real vault key (so a no-key
        // open MUST fail — proving fail-closed, not a plaintext leak).
        let keyData = Data(repeating: 0x42, count: 32)
        try seedSealedConversation(deviceId: "remote-device-11", docId: "conv-a", keyData: keyData, project: "Alpha")
        try seedSealedConversation(deviceId: "remote-device-11", docId: "conv-b", keyData: keyData, project: "Beta")

        let throwingProvider = ThrowingVaultKeyProvider(
            error: CloudVaultAccessError.vaultKeyMismatch(expected: "vk-A", actual: "vk-B")
        )
        let downloadSync = makeDownloadSync(provider: throwingProvider)

        await downloadSync.sync()

        // FAIL CLOSED: no peer conversation imported (open could not verify / decrypt).
        let conversations = try await dataStore.fetchConversations(limit: 100, offset: 0)
        XCTAssertTrue(
            conversations.filter { $0.isRemote }.isEmpty,
            "A vault-key fault must skip peer conversations, never import unverified content"
        )

        // Resolved at most once per cycle even though two peer docs were processed.
        // `sync()` runs two independent flows that each resolve the vault key at
        // most once (usage-sync + conversation-download), and the conversation
        // loop is guarded by a `vaultKeyResolved` flag — so the key is resolved
        // per FLOW, never per document. With two peer docs that bound is 2, not
        // the 2-per-doc a `try?`-in-the-loop would have produced.
        XCTAssertLessThanOrEqual(
            throwingProvider.callCount, 2,
            "keyForReading must be attempted at most once per sync flow, not once per document"
        )
        XCTAssertGreaterThanOrEqual(
            throwingProvider.callCount, 1,
            "the vault key resolution must actually be attempted"
        )
    }

    func test_conversationDownload_vaultKeyProviderSucceeds_importsPeerDoc() async throws {
        let keyData = Data(repeating: 0x42, count: 32)
        try seedSealedConversation(deviceId: "remote-device-12", docId: "conv-ok", keyData: keyData, project: "Gamma")

        let downloadSync = makeDownloadSync(provider: TestConversationVaultKeyProvider(keyData: keyData))

        await downloadSync.sync()

        let remote = try await dataStore.fetchConversations(limit: 100, offset: 0).filter { $0.isRemote }
        XCTAssertEqual(remote.count, 1, "Control case: a usable key imports the peer conversation")
        XCTAssertEqual(remote.first?.projectName, "Gamma")
    }

    // MARK: - Helpers

    private func seedSealedConversation(
        deviceId: String,
        docId: String,
        keyData: Data,
        project: String
    ) throws {
        let payload = ConversationCloudPrivatePayload(
            projectName: project,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "",
            lastAssistantMessage: "",
            workingDirectory: nil,
            summary: nil,
            summaryTitle: nil,
            summaryProvider: nil,
            summaryModel: nil
        )
        let key = CloudVaultResolvedKey(keyData: keyData, vaultKeyID: try CloudVaultCrypto.vaultKeyID(for: keyData))
        let docPath = "users/test-uid-1/conversations/\(docId)"
        // `seal` returns the sealed-payload dictionary; the producer writes it under
        // the `sealedPayload` key (ConversationSyncService), so mirror that shape.
        let sealedPayload = try ConversationCloudSealer.seal(
            payload, key: key, uid: "test-uid-1", docId: docId
        )

        let data: [String: Any] = [
            "id": docId,
            "deviceId": deviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sessionId": "session-\(docId)",
            "contentSealed": true,
            "sealedPayload": sealedPayload,
            "messageCount": 1,
            "startTime": Timestamp(date: Date()),
            "endTime": Timestamp(date: Date()),
            "updatedAt": Timestamp(date: Date())
        ]
        fakeGateway.setDocumentData(data, at: docPath)
    }
}

// MARK: - Test Doubles

/// A vault-key provider that always THROWS — models a real provider fault
/// (e.g. `vaultKeyMismatch` on rotation / state corruption) as distinct from
/// the expected nil "un-approved device" case. Records call count to prove the
/// once-per-cycle resolution guard.
private final class ThrowingVaultKeyProvider: ConversationCloudVaultKeyProviding, @unchecked Sendable {
    private let error: Error
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    init(error: Error) {
        self.error = error
    }

    func keyForWriting(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey {
        lock.withLock { calls += 1 }
        throw error
    }

    func keyForReading(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey? {
        lock.withLock { calls += 1 }
        throw error
    }
}
