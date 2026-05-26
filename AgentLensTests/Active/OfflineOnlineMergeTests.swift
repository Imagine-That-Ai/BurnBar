import XCTest
import GRDB
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

private typealias AppAgentProvider = OpenBurnBar.AgentProvider
private typealias AppTokenUsage = OpenBurnBar.TokenUsage
private typealias AppUsageSource = OpenBurnBar.UsageSource

@MainActor
final class OfflineOnlineMergeTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var usageSync: UsageSyncService!
    private var downloadSync: DownloadSyncService!
    private var circuitBreaker: CloudSyncCircuitBreaker!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        fakeGateway = CloudSyncFirestoreFakeGateway()
        circuitBreaker = CloudSyncCircuitBreaker()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway,
            circuitBreaker: circuitBreaker
        )
        usageSync = UsageSyncService(context: context)
        downloadSync = DownloadSyncService(context: context)
    }

    // MARK: - Backoff Recovery

    func test_backoff_recovery_whenFirebaseBecomesAvailable() async throws {
        accountManager.isFirebaseAvailable = false

        let usage = AppTokenUsage(
            provider: AppAgentProvider.claudeCode,
            sessionId: "session-1",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try dataStore.insert(usage)

        await usageSync.sync()

        // No writes should occur when Firebase is unavailable
        let docs = fakeGateway.documents(under: "users/test-uid-1/usage")
        XCTAssertTrue(docs.isEmpty)

        // Re-enable Firebase and sync again
        accountManager.isFirebaseAvailable = true
        await usageSync.sync()

        let docsAfter = fakeGateway.documents(under: "users/test-uid-1/usage")
        XCTAssertEqual(docsAfter.count, 1)
    }

    // MARK: - Backoff Suppression

    func test_backoff_suppression_onPermissionDenied() async throws {
        fakeGateway.nextError = NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.permissionDenied.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )

        let usage = AppTokenUsage(
            provider: AppAgentProvider.claudeCode,
            sessionId: "session-1",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try dataStore.insert(usage)

        await usageSync.sync()

        XCTAssertTrue(context.syncIsSuppressed())
        XCTAssertNotNil(context.suppressedSyncUntil)

        context.suppressedSyncUntil = nil
        XCTAssertFalse(context.syncIsSuppressed())

        fakeGateway.nextError = nil
        await usageSync.sync()

        let docs = fakeGateway.documents(under: "users/test-uid-1/usage")
        XCTAssertEqual(docs.count, 1)
    }

    // MARK: - Watermark Durability on Failure

    func test_watermark_doesNotAdvanceOnFailure() async throws {
        let remoteDeviceId = "remote-device"
        let remoteUsageId = UUID().uuidString
        let remoteTimestamp = Date().addingTimeInterval(-3600)
        let start = remoteTimestamp
        let end = remoteTimestamp.addingTimeInterval(100)

        fakeGateway.setDocumentData([
            "id": remoteUsageId,
            "deviceId": remoteDeviceId,
            "provider": AppAgentProvider.claudeCode.rawValue,
            "sessionId": "session-1",
            "projectName": "RemoteProject",
            "model": "claude-3-5-sonnet",
            "inputTokens": 100,
            "outputTokens": 50,
            "usageSource": AppUsageSource.providerLog.rawValue,
            "totalTokens": 150,
            "cost": 0.005,
            "startTime": Timestamp(date: start),
            "endTime": Timestamp(date: end),
            "updatedAt": Timestamp(date: remoteTimestamp)
        ], at: "users/test-uid-1/usage/\(remoteDeviceId)_\(remoteUsageId)")

        fakeGateway.setDocumentData([
            "deviceName": "Remote Mac",
            "platform": "macOS",
            "lastActiveAt": Timestamp(date: remoteTimestamp)
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        let initialWatermark = try dataStore.remoteSyncWatermarkStore.fetchWatermark(
            accountUid: "test-uid-1",
            collectionKind: .usage
        )

        fakeGateway.nextError = NSError(
            domain: "FakeFirestore",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Network error"]
        )

        await downloadSync.sync()

        let watermarkAfterFailure = try dataStore.remoteSyncWatermarkStore.fetchWatermark(
            accountUid: "test-uid-1",
            collectionKind: .usage
        )
        XCTAssertEqual(initialWatermark?.lastProcessedRemoteUpdateAt, watermarkAfterFailure?.lastProcessedRemoteUpdateAt)
        XCTAssertEqual(initialWatermark?.lastSyncedAt, watermarkAfterFailure?.lastSyncedAt)

        fakeGateway.nextError = nil
        await downloadSync.sync()

        let watermarkAfterSuccess = try dataStore.remoteSyncWatermarkStore.fetchWatermark(
            accountUid: "test-uid-1",
            collectionKind: .usage
        )
        XCTAssertNotNil(watermarkAfterSuccess)
        XCTAssertEqual(
            watermarkAfterSuccess?.lastProcessedRemoteUpdateAt?.timeIntervalSince1970 ?? 0,
            remoteTimestamp.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: - Circuit Breaker Recovery

    func test_circuitBreaker_halfOpenToClosed_recovery() async throws {
        try XCTSkip("FakeFirestore errors do not trip CloudSyncCircuitBreaker through UsageSyncService yet; revive after retry harness exposes failure counts.")
    }

    // MARK: - Buffered Local Upload on Reconnect

    func test_bufferedLocalUpload_drainedOnReconnect() async throws {
        accountManager.isFirebaseAvailable = false

        // Insert multiple unsynced rows while offline
        for i in 0..<5 {
            let usage = AppTokenUsage(
                provider: AppAgentProvider.claudeCode,
                sessionId: "session-\(i)",
                projectName: "TestProject",
                model: "claude-3-5-sonnet",
                inputTokens: 100 + i,
                outputTokens: 50 + i,
                startTime: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i)),
                endTime: Date(timeIntervalSince1970: 1_700_000_100 + TimeInterval(i))
            )
            try dataStore.insert(usage)
        }

        // Sync while offline - nothing should upload
        await usageSync.sync()
        var docs = fakeGateway.documents(under: "users/test-uid-1/usage")
        XCTAssertTrue(docs.isEmpty)

        // Re-enable and sync
        accountManager.isFirebaseAvailable = true
        await usageSync.sync()

        // All buffered rows should be written
        docs = fakeGateway.documents(under: "users/test-uid-1/usage")
        XCTAssertEqual(docs.count, 5)

        // All local rows should be marked synced
        let unsynced = try dataStore.fetchUnsynced()
        XCTAssertTrue(unsynced.isEmpty)
    }

    func test_bufferedLocalUpload_singleBatch() async throws {
        accountManager.isFirebaseAvailable = false

        // Insert multiple unsynced rows while offline
        for i in 0..<3 {
            let usage = AppTokenUsage(
                provider: AppAgentProvider.claudeCode,
                sessionId: "batch-\(i)",
                projectName: "TestProject",
                model: "claude-3-5-sonnet",
                inputTokens: 100,
                outputTokens: 50,
                startTime: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i)),
                endTime: Date(timeIntervalSince1970: 1_700_000_100 + TimeInterval(i))
            )
            try dataStore.insert(usage)
        }

        accountManager.isFirebaseAvailable = true

        // Track batch count
        let initialBatchCount = fakeGateway.batchCommitCount
        await usageSync.sync()
        let finalBatchCount = fakeGateway.batchCommitCount

        // Should have committed at least one batch
        XCTAssertGreaterThan(finalBatchCount, initialBatchCount)

        // All should be uploaded
        let docs = fakeGateway.documents(under: "users/test-uid-1/usage")
        XCTAssertEqual(docs.count, 3)
    }
}
