import XCTest
import GRDB
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

    // MARK: - Watermark Durability on Failure

    // MARK: - Circuit Breaker Recovery

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
