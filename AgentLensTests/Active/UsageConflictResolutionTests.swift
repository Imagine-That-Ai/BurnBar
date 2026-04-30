import XCTest
import GRDB
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class UsageConflictResolutionTests: XCTestCase {
    private var dataStore: DataStoreCoordinator!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var downloadSync: DownloadSyncService!

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
        downloadSync = DownloadSyncService(context: context)
    }

    // MARK: - Confidence-Gated Upsert

    func test_remoteExact_overwritesLocalHighConfidenceEstimate() async throws {
        let localUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "LocalProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(),
            endTime: Date().addingTimeInterval(100),
            sourceDeviceId: "remote-device",
            provenanceConfidence: .highConfidenceEstimate
        )
        try dataStore.insert(localUsage)

        // Simulate remote exact data
        let remoteDeviceId = "remote-device"
        let remoteDocPath = "users/test-uid-1/usage/\(remoteDeviceId)_\(UUID().uuidString)"
        let remoteUpdatedAt = Date().addingTimeInterval(-60) // recent enough to pass 90-day watermark
        fakeGateway.setDocumentData([
            "id": UUID().uuidString,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.claudeCode.rawValue,
            "sessionId": "session-1",
            "projectName": "RemoteProject",
            "model": "claude-3-5-sonnet",
            "inputTokens": 200,
            "outputTokens": 100,
            "usageSource": UsageSource.billingAPI.rawValue,
            "totalTokens": 300,
            "cost": 0.02,
            "startTime": Timestamp(date: remoteUpdatedAt),
            "endTime": Timestamp(date: remoteUpdatedAt.addingTimeInterval(100)),
            "updatedAt": Timestamp(date: remoteUpdatedAt)
        ], at: remoteDocPath)

        fakeGateway.setDocumentData([
            "deviceName": "Remote Mac",
            "platform": "macOS"
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        await downloadSync.sync()

        let allUsage = try dataStore.usageStore.fetchAllUsage()
        XCTAssertEqual(allUsage.count, 1)

        let result = allUsage.first!
        XCTAssertEqual(result.inputTokens, 200) // Updated
        XCTAssertEqual(result.outputTokens, 100) // Updated
        XCTAssertEqual(result.projectName, "RemoteProject") // Updated
        XCTAssertEqual(result.provenanceConfidence, UsageProvenanceConfidence.exact) // Promoted
        XCTAssertEqual(result.usageSource, UsageSource.billingAPI) // Changed because strictly higher confidence
    }

    /// When both local and remote have `.exact` confidence, the download service
    /// (which always marks remote as `.exact`) will update values because
    /// `excluded.provenanceConfidence >= token_usage.provenanceConfidence` is true.
    /// The `usageSource` is preserved because confidence is equal, not strictly higher.
    func test_remoteExact_overwritesLocalExact_valuesButPreservesUsageSource() async throws {
        let localUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "LocalProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(),
            endTime: Date().addingTimeInterval(100),
            sourceDeviceId: "remote-device",
            provenanceConfidence: .exact
        )
        try dataStore.insert(localUsage)

        let remoteDeviceId = "remote-device"
        let remoteDocPath = "users/test-uid-1/usage/\(remoteDeviceId)_\(UUID().uuidString)"
        let remoteUpdatedAt = Date().addingTimeInterval(-60) // recent enough to pass 90-day watermark
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
            "startTime": Timestamp(date: remoteUpdatedAt),
            "endTime": Timestamp(date: remoteUpdatedAt.addingTimeInterval(100)),
            "updatedAt": Timestamp(date: remoteUpdatedAt)
        ], at: remoteDocPath)

        fakeGateway.setDocumentData([
            "deviceName": "Remote Mac",
            "platform": "macOS"
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        await downloadSync.sync()

        let allUsage = try dataStore.usageStore.fetchAllUsage()
        XCTAssertEqual(allUsage.count, 1)

        let result = allUsage.first!
        XCTAssertEqual(result.inputTokens, 999) // Updated because equal confidence allows update
        XCTAssertEqual(result.outputTokens, 999) // Updated
        XCTAssertEqual(result.projectName, "RemoteProject") // Updated
        XCTAssertEqual(result.provenanceConfidence, UsageProvenanceConfidence.exact) // Preserved (both exact)
        XCTAssertEqual(result.usageSource, UsageSource.providerLog) // Preserved because not strictly higher
    }

    func test_remoteEqualConfidence_updatesValuesButPreservesUsageSource() async throws {
        let localUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "LocalProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(),
            endTime: Date().addingTimeInterval(100),
            usageSource: .providerLog,
            sourceDeviceId: "remote-device",
            provenanceConfidence: .exact
        )
        try dataStore.insert(localUsage)

        let remoteDeviceId = "remote-device"
        let remoteDocPath = "users/test-uid-1/usage/\(remoteDeviceId)_\(UUID().uuidString)"
        let remoteUpdatedAt = Date().addingTimeInterval(-60) // recent enough to pass 90-day watermark
        fakeGateway.setDocumentData([
            "id": UUID().uuidString,
            "deviceId": remoteDeviceId,
            "provider": AgentProvider.claudeCode.rawValue,
            "sessionId": "session-1",
            "projectName": "RemoteProject",
            "model": "claude-3-5-sonnet",
            "inputTokens": 200,
            "outputTokens": 100,
            "usageSource": UsageSource.billingAPI.rawValue,
            "totalTokens": 300,
            "cost": 0.02,
            "startTime": Timestamp(date: remoteUpdatedAt),
            "endTime": Timestamp(date: remoteUpdatedAt.addingTimeInterval(100)),
            "updatedAt": Timestamp(date: remoteUpdatedAt)
        ], at: remoteDocPath)

        fakeGateway.setDocumentData([
            "deviceName": "Remote Mac",
            "platform": "macOS"
        ], at: "users/test-uid-1/devices/\(remoteDeviceId)")

        await downloadSync.sync()

        let allUsage = try dataStore.usageStore.fetchAllUsage()
        XCTAssertEqual(allUsage.count, 1)

        let result = allUsage.first!
        XCTAssertEqual(result.inputTokens, 200) // Updated because equal confidence allows update
        XCTAssertEqual(result.outputTokens, 100) // Updated
        XCTAssertEqual(result.usageSource, UsageSource.providerLog) // Preserved because not strictly higher
    }
}
