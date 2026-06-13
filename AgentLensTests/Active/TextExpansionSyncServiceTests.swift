import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class TextExpansionSyncServiceTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var vaultKeyStore: StaticSessionLogVaultKeyStore!
    private var vaultKeyPublisher: FakeTextExpansionVaultKeyPublisher!
    private var originalSharedCloudSyncEnabled = true

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        fakeGateway = CloudSyncFirestoreFakeGateway()
        vaultKeyStore = StaticSessionLogVaultKeyStore(keyData: Data(repeating: 0x33, count: 32))
        vaultKeyPublisher = FakeTextExpansionVaultKeyPublisher()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
        originalSharedCloudSyncEnabled = SettingsManager.shared.textExpansion.cloudSyncEnabled
        SettingsManager.shared.textExpansion.cloudSyncEnabled = true
    }

    override func tearDown() {
        SettingsManager.shared.textExpansion.cloudSyncEnabled = originalSharedCloudSyncEnabled
        dataStore = nil
        accountManager = nil
        settingsManager = nil
        fakeGateway = nil
        context = nil
        vaultKeyStore = nil
        vaultKeyPublisher = nil
        super.tearDown()
    }

    func testSyncUploadsTextExpansionSnippetAndMarksLocalRowSynced() async throws {
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let snippet = TextExpansionSnippet(
            id: "snippet-1",
            title: "Greeting",
            trigger: "hello",
            body: "Hi there",
            mode: .staticText,
            scope: TextExpansionScope(surfaces: [.inAppThread]),
            revision: 3,
            createdAt: updatedAt.addingTimeInterval(-60),
            updatedAt: updatedAt
        )
        try dataStore.upsertTextExpansionSnippet(snippet)

        let service = TextExpansionSyncService(
            context: context,
            vaultKeyStore: vaultKeyStore,
            vaultKeyPublisher: vaultKeyPublisher
        )

        await service.sync()

        XCTAssertFalse(service.isSyncing)
        XCTAssertNil(service.lastSyncError)
        XCTAssertNotNil(service.lastSyncDate)
        XCTAssertEqual(vaultKeyPublisher.publishedKeys.map(\.uid), ["test-uid-1"])
        XCTAssertEqual(fakeGateway.batchCommitCount, 1)

        let doc = try XCTUnwrap(fakeGateway.documentData(at: "users/test-uid-1/text_snippets/snippet-1"))
        XCTAssertEqual(doc["id"] as? String, "snippet-1")
        XCTAssertEqual(doc["uid"] as? String, "test-uid-1")
        XCTAssertEqual(doc["sourceDeviceID"] as? String, "test-device-1")
        XCTAssertNotNil(doc["triggerHash"])
        XCTAssertNotNil(doc["sealedTitle"])
        XCTAssertNotNil(doc["sealedTrigger"])
        XCTAssertNotNil(doc["sealedBody"])
        XCTAssertNil(doc["title"])
        XCTAssertNil(doc["trigger"])
        XCTAssertNil(doc["body"])

        let unsynced = try dataStore.fetchUnsyncedTextExpansionSnippets()
        XCTAssertTrue(unsynced.isEmpty)
    }
}

@MainActor
private final class FakeTextExpansionVaultKeyPublisher: SessionLogVaultKeyPublishing {
    private(set) var publishedKeys: [(uid: String, key: Data)] = []

    func publishCloudVaultKey(uid: String, vaultKey: Data, context: CloudSyncContext) async throws {
        publishedKeys.append((uid, vaultKey))
    }
}
