import XCTest
import GRDB
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class UsageConflictResolutionTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var downloadSync: DownloadSyncService!
    private var vaultKeyProvider: TestConversationVaultKeyProvider!

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
        vaultKeyProvider = TestConversationVaultKeyProvider()
        downloadSync = DownloadSyncService(context: context, conversationVaultKeyProvider: vaultKeyProvider)
    }

    // MARK: - Confidence-Gated Upsert

    func test_remoteHighConfidenceEstimate_doesNotOverwriteLocalExact() async throws {
        let localUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "LocalProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            provenanceConfidence: .exact
        )
        try await dataStore.insert(localUsage)

        let remoteDeviceId = "remote-device"
        let remoteDocPath = "users/test-uid-1/usage/\(remoteDeviceId)_\(UUID().uuidString)"
        fakeGateway.setDocumentData([
            "id": UUID().uuidString,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.claudeCode.rawValue,
            "sessionId": "session-1",
            "projectName": "RemoteProject",
            "model": "claude-3-5-sonnet",
            "inputTokens": 999,
            "outputTokens": 999,
            "usageSource": UsageSource.billingAPI.rawValue,
            "totalTokens": 1998,
            "cost": 0.1,
            "startTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)),
            "endTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_100)),
            "updatedAt": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000))
        ], at: remoteDocPath)

        fakeGateway.setDocumentData([
            "deviceName": "Remote Mac",
            "platform": "macOS"
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        await downloadSync.sync()

        let allUsage = try await dataStore.fetchAllUsage()
        XCTAssertEqual(allUsage.count, 1)

        let result = allUsage.first!
        XCTAssertEqual(result.inputTokens, 100) // Preserved
        XCTAssertEqual(result.outputTokens, 50) // Preserved
        XCTAssertEqual(result.projectName, "LocalProject") // Preserved
        XCTAssertEqual(result.provenanceConfidence, UsageProvenanceConfidence.exact) // Preserved
    }

    // MARK: - Billing Provenance Precedence

    /// Same natural key, same confidence, different source: the upsert already
    /// preserves `usageSource` here, so `billingKind` — which describes that
    /// very source — must be preserved with it. Otherwise a confirmed wallet
    /// charge silently becomes plan value while the row still says
    /// `usageSource = billing_api`.
    func test_equalConfidenceCorrection_preservesEstablishedBillingKind() async throws {
        try await dataStore.insert(makeUsage(
            usageSource: .billingAPI,
            confidence: .exact,
            billingKind: .api,
            cost: 1.0
        ))

        try await dataStore.insert(makeUsage(
            usageSource: .providerLog,
            confidence: .exact,
            billingKind: .subscription,
            cost: 2.0
        ))

        let rows = try await dataStore.fetchAllUsage()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        // The correction still lands on the numbers…
        XCTAssertEqual(row.cost, 2.0)
        // …but neither provenance dimension flips on equal confidence.
        XCTAssertEqual(row.usageSource, .billingAPI)
        XCTAssertEqual(row.billingKind, .api)
    }

    /// A strictly higher-confidence source still re-classifies: it also wins
    /// `usageSource`, so the two dimensions stay consistent.
    func test_higherConfidenceCorrection_replacesBillingKind() async throws {
        try await dataStore.insert(makeUsage(
            usageSource: .providerLog,
            confidence: .highConfidenceEstimate,
            billingKind: .subscription,
            cost: 1.0
        ))

        try await dataStore.insert(makeUsage(
            usageSource: .billingAPI,
            confidence: .exact,
            billingKind: .api,
            cost: 2.0
        ))

        let rows = try await dataStore.fetchAllUsage()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.usageSource, .billingAPI)
        XCTAssertEqual(row.billingKind, .api)
    }

    /// The same source correcting itself keeps converging (a re-import that now
    /// carries a stamp must be able to fix a row the backfill guessed).
    func test_sameSourceCorrection_replacesBillingKind() async throws {
        try await dataStore.insert(makeUsage(
            usageSource: .daemon,
            confidence: .exact,
            billingKind: .api,
            cost: 1.0
        ))

        try await dataStore.insert(makeUsage(
            usageSource: .daemon,
            confidence: .exact,
            billingKind: .subscription,
            cost: 2.0
        ))

        let rows = try await dataStore.fetchAllUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.billingKind, .subscription)
    }

    /// An unclassified incoming row never erases an established kind — even
    /// when the rest of the correction is accepted.
    func test_unknownIncomingBillingKind_neverOverwritesEstablishedKind() async throws {
        try await dataStore.insert(makeUsage(
            usageSource: .billingAPI,
            confidence: .exact,
            billingKind: .api,
            cost: 1.0
        ))

        // `.inAppChat` classifies to `.unknown`, so the write-time fallback
        // cannot rescue this row: it genuinely arrives unclassified.
        try await dataStore.insert(makeUsage(
            usageSource: .inAppChat,
            confidence: .exact,
            billingKind: .unknown,
            cost: 2.0
        ))

        let rows = try await dataStore.fetchAllUsage()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.cost, 2.0, "the correction itself must still apply")
        XCTAssertEqual(row.billingKind, .api)
    }

    /// A stale `unknown` stays improvable: any classified row may claim it.
    func test_unknownStoredBillingKind_isClaimedByEqualConfidenceCorrection() async throws {
        try await dataStore.insert(makeUsage(
            usageSource: .inAppChat,
            confidence: .exact,
            billingKind: .unknown,
            cost: 1.0
        ))

        try await dataStore.insert(makeUsage(
            usageSource: .providerLog,
            confidence: .exact,
            billingKind: .subscription,
            cost: 2.0
        ))

        let rows = try await dataStore.fetchAllUsage()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.billingKind, .subscription)
    }

    private func makeUsage(
        usageSource: UsageSource,
        confidence: UsageProvenanceConfidence,
        billingKind: BurnBarBillingKind,
        cost: Double
    ) -> TokenUsage {
        TokenUsage(
            provider: .codex,
            sessionId: "billing-precedence-session",
            projectName: "BillingPrecedence",
            model: "gpt-5.6-codex",
            inputTokens: 100,
            outputTokens: 50,
            costUSD: cost,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            usageSource: usageSource,
            provenanceConfidence: confidence,
            billingKind: billingKind
        )
    }
}
