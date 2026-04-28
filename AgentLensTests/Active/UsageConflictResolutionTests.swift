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
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            provenanceConfidence: .highConfidenceEstimate
        )
        try dataStore.insert(localUsage)

        // Simulate remote exact data
        let remoteDeviceId = "remote-device"
        let remoteDocPath = "users/test-uid-1/usage/\(remoteDeviceId)_\(UUID().uuidString)"
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
            "startTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)),
            "endTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_100)),
            "updatedAt": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000))
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
        try dataStore.insert(localUsage)

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

        let allUsage = try dataStore.usageStore.fetchAllUsage()
        XCTAssertEqual(allUsage.count, 1)

        let result = allUsage.first!
        XCTAssertEqual(result.inputTokens, 100) // Preserved
        XCTAssertEqual(result.outputTokens, 50) // Preserved
        XCTAssertEqual(result.projectName, "LocalProject") // Preserved
        XCTAssertEqual(result.provenanceConfidence, UsageProvenanceConfidence.exact) // Preserved
    }

    func test_remoteEqualConfidence_updatesValuesButPreservesUsageSource() async throws {
        let localUsage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-1",
            projectName: "LocalProject",
            model: "claude-3-5-sonnet",
            inputTokens: 100,
            outputTokens: 50,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            usageSource: .providerLog,
            provenanceConfidence: .exact
        )
        try dataStore.insert(localUsage)

        let remoteDeviceId = "remote-device"
        let remoteDocPath = "users/test-uid-1/usage/\(remoteDeviceId)_\(UUID().uuidString)"
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
            "startTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)),
            "endTime": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_100)),
            "updatedAt": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000))
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
