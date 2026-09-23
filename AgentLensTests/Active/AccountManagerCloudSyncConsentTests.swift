import XCTest
import GRDB
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

/// Wave 0.5 consent: cloud sync is off until the user turns it on, the choice
/// persists across launches, and a closed gate means zero Firestore writes
/// through real sync code.
@MainActor
final class AccountManagerCloudSyncConsentTests: XCTestCase {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "test-cloudsync-consent-\(UUID().uuidString)")!
    }

    func test_freshInstallDefaultsCloudSyncOff() {
        XCTAssertFalse(AccountManager(userDefaults: freshSuite()).isCloudSyncEnabled)
    }

    func test_cloudSyncChoicePersistsAcrossLaunches() {
        let defaults = freshSuite()
        AccountManager(userDefaults: defaults).setCloudSyncEnabled(true)
        XCTAssertTrue(AccountManager(userDefaults: defaults).isCloudSyncEnabled)
        AccountManager(userDefaults: defaults).setCloudSyncEnabled(false)
        XCTAssertFalse(AccountManager(userDefaults: defaults).isCloudSyncEnabled)
    }

    func test_syncGateClosedWritesNothingToFirestore() async throws {
        let dataStore = try makeDiscoveryInMemoryStore()
        let accountManager = FakeAccountManager.makeSignedIn()
        // Fresh-install semantics: signed in, sync never enabled.
        accountManager.isCloudSyncEnabled = false
        let settingsManager = SettingsManager(defaults: freshSuite())
        let fakeGateway = CloudSyncFirestoreFakeGateway()
        let context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
        let usageSync = UsageSyncService(context: context, vaultKeyProvider: TestConversationVaultKeyProvider())
        // Mirror UsageSyncRoundTripTests: the reconciliation lifecycle is
        // durable and process-global, so pin a known idle state.
        UsageSyncService.orphanReconciliationState = .idle
        addTeardownBlock {
            UsageSyncService.orphanReconciliationState = .idle
            UserDefaults.standard.removeObject(forKey: UsageSyncService.orphanReconciliationDefaultsKey)
        }
        let consent = AnalyticsConsentStore(defaults: makeIsolatedAnalyticsDefaults())
        consent.grant()
        AnalyticsRuntime.configure(
            consentStore: consent,
            recorder: Analytics(consent: consent, transport: FakeAnalyticsTransport(), superProperties: { [:] })
        )

        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-consent",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try await dataStore.insert(usage)
        let docPath = "users/test-uid-1/usage/test-device-1_\(usage.id.uuidString)"

        await usageSync.sync()
        XCTAssertEqual(fakeGateway.batchCommitCount, 0)
        XCTAssertNil(fakeGateway.documentData(at: docPath))

        // Control: the same rows upload once consent is granted, proving the
        // zero above comes from the gate rather than a broken fixture.
        accountManager.isCloudSyncEnabled = true
        await usageSync.sync()
        XCTAssertGreaterThan(fakeGateway.batchCommitCount, 0)
        XCTAssertNotNil(fakeGateway.documentData(at: docPath))
    }
}
