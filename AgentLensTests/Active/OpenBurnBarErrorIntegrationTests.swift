import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

@MainActor
final class OpenBurnBarErrorIntegrationTests: XCTestCase {
    func test_daemonManagerErrorMapsToTypedTaxonomy() {
        let typed = OpenBurnBarError.fromDaemonManager(.rpcTimedOut(seconds: 30))
        XCTAssertEqual(typed.domain, .daemon)
        XCTAssertEqual(typed.code, "rpc_timeout")
        XCTAssertEqual(typed.metricKey, "daemon_rpc_timeout")
    }

    func test_cloudSyncCoordinator_clearsTypedErrorOnSuccessfulUsageSync() async throws {
        let store = try makeInMemoryDataStore()
        let settings = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        let coordinator = CloudSyncCoordinator(
            dataStore: store,
            accountManager: FakeAccountManager.makeSignedIn(),
            settingsManager: settings,
            firestoreGateway: CloudSyncFirestoreFakeGateway(),
            conversationVaultKeyProvider: TestConversationVaultKeyProvider(),
            sessionLogEncryptedCloudClient: FakeSessionLogEncryptedCloudClient(),
            sessionLogVaultKeyStore: StaticSessionLogVaultKeyStore(),
            sessionLogVaultKeyPublisher: NoopSessionLogVaultKeyPublisher()
        )

        await coordinator.syncUsage()

        XCTAssertNil(coordinator.lastSyncError)
        XCTAssertNil(coordinator.lastTypedSyncError)
    }

    func test_openBurnBarErrorSearchMetricKeyUsesSearchDomain() {
        let typed = OpenBurnBarError.search("health_write_failed", message: "Failed to persist retrieval health.")
        XCTAssertEqual(typed.domain, .search)
        XCTAssertEqual(typed.metricKey, "search_health_write_failed")
    }

    private func makeInMemoryDataStore() throws -> DataStore {
        let queue = try DatabaseQueue()
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }
}
