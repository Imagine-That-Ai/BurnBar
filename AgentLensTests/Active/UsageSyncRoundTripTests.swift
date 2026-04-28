import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class UsageSyncRoundTripTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: FakeSettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var usageSync: UsageSyncService!
    private var downloadSync: DownloadSyncService!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = FakeSettingsManager()
        fakeGateway = CloudSyncFirestoreFakeGateway()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
        usageSync = UsageSyncService(context: context)
        downloadSync = DownloadSyncService(context: context)
    }

    // MARK: - Write → Read Round Trip

    func test_usageUpload_writesToFirestoreAndMarksSynced() async throws {
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "TestProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try dataStore.insert(usage)

        // Precondition: one unsynced row
        let unsyncedBefore = try dataStore.fetchUnsynced()
        XCTAssertEqual(unsyncedBefore.count, 1)

        await usageSync.sync()

        // Postcondition: Firestore contains the document
        let docPath = "users/test-uid-1/usage/test-device-1_\(usage.id.uuidString)"
        let docData = fakeGateway.documentData(at: docPath)
        XCTAssertNotNil(docData)
        XCTAssertEqual(docData?["provider"] as? String, AgentProvider.claudeCode.rawValue)
        XCTAssertEqual(docData?["model"] as? String, "claude-3-5-sonnet")
        XCTAssertEqual(docData?["inputTokens"] as? Int, 100)
        XCTAssertEqual(docData?["outputTokens"] as? Int, 50)
        XCTAssertEqual(docData?["deviceId"] as? String, "test-device-1")

        // Postcondition: local row is marked synced
        let unsyncedAfter = try dataStore.fetchUnsynced()
        XCTAssertTrue(unsyncedAfter.isEmpty)
    }

    func test_usageDownload_readsRemoteUsageIntoLocalStore() async throws {
        // Seed fake Firestore with a remote usage document from another device
        let remoteDeviceId = "remote-device-2"
        let remoteUsageId = UUID().uuidString
        let remoteDocPath = "users/test-uid-1/usage/\(remoteDeviceId)_\(remoteUsageId)"
        let remoteUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        fakeGateway.setDocumentData([
            "id": remoteUsageId,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.cursor.rawValue,
            "sessionId": "remote-session-1",
            "projectName": "RemoteProject",
            "model": "gpt-4",
            "inputTokens": 200,
            "outputTokens": 100,
            "cacheCreationTokens": 0,
            "cacheReadTokens": 0,
            "reasoningTokens": 0,
            "usageSource": UsageSource.providerLog.rawValue,
            "totalTokens": 300,
            "cost": 0.015,
            "startTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)),
            "endTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_100)),
            "updatedAt": Timestamp(date: remoteUpdatedAt)
        ], at: remoteDocPath)

        // Also seed the device registry so the downloader can resolve the device name
        fakeGateway.setDocumentData([
            "deviceName": "Remote MacBook",
            "platform": "macOS",
            "lastActiveAt": Timestamp(date: remoteUpdatedAt)
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        await downloadSync.sync()

        // Verify local store contains the remote usage
        let allUsage = try dataStore.dbQueue.read { db in
            try TokenUsage.fetchAll(db)
        }
        let remoteUsages = allUsage.filter { $0.isRemote }
        XCTAssertEqual(remoteUsages.count, 1)

        let remote = remoteUsages.first!
        XCTAssertEqual(remote.provider, .cursor)
        XCTAssertEqual(remote.sessionId, "remote-session-1")
        XCTAssertEqual(remote.model, "gpt-4")
        XCTAssertEqual(remote.inputTokens, 200)
        XCTAssertEqual(remote.outputTokens, 100)
        XCTAssertEqual(remote.sourceDeviceId, remoteDeviceId)
        XCTAssertEqual(remote.sourceDeviceName, "Remote MacBook")
        XCTAssertTrue(remote.isRemote)
        XCTAssertEqual(remote.provenanceMethod, .cloudSync)
        XCTAssertEqual(remote.provenanceConfidence, .exact)
    }

    func test_usageRoundTrip_uploadThenDownload_doesNotReImportOwnData() async throws {
        let usage = TokenUsage(
            provider: .factory,
            sessionId: "session-own",
            projectName: "OwnProject",
            model: "test-model",
            inputTokens: 10,
            outputTokens: 5,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try dataStore.insert(usage)

        await usageSync.sync()
        await downloadSync.sync()

        // Should not create a duplicate of our own data
        let allUsage = try dataStore.dbQueue.read { db in
            try TokenUsage.fetchAll(db)
        }
        XCTAssertEqual(allUsage.count, 1)
        XCTAssertFalse(allUsage[0].isRemote)
    }
}
