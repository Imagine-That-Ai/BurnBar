import XCTest
import OpenBurnBarCore

final class CloudModelCodableTests: XCTestCase {

    func testCloudProfileCodable() throws {
        let profile = CloudProfile(
            uid: "test-uid",
            displayName: "Test User",
            preferences: ["theme": "dark"],
            sourceDeviceId: "device-1"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CloudProfile.self, from: data)
        XCTAssertEqual(decoded.uid, "test-uid")
        XCTAssertEqual(decoded.displayName, "Test User")
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testCloudDeviceCodable() throws {
        let device = CloudDevice(
            deviceId: "ios-1",
            deviceName: "iPhone 16",
            platform: "iOS",
            trustState: .pending
        )
        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(CloudDevice.self, from: data)
        XCTAssertEqual(decoded.deviceId, "ios-1")
        XCTAssertEqual(decoded.trustState, .pending)
    }

    func testSyncWatermarkCodable() throws {
        let wm = SyncWatermark(accountUid: "uid-1", collectionKind: .usage)
        let data = try JSONEncoder().encode(wm)
        let decoded = try JSONDecoder().decode(SyncWatermark.self, from: data)
        XCTAssertEqual(decoded.accountUid, "uid-1")
        XCTAssertEqual(decoded.collectionKind, .usage)
    }

    func testSyncStatusCodable() throws {
        let status = SyncStatus(deviceId: "mac-1", isOnline: true, collectionsInSync: ["usage", "conversations"])
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(SyncStatus.self, from: data)
        XCTAssertTrue(decoded.isOnline)
        XCTAssertEqual(decoded.collectionsInSync, ["usage", "conversations"])
    }

    func testRecentUsageSummaryCodable() throws {
        let summary = RecentUsageSummary(
            totalCost30d: 42.50,
            totalTokens30d: 1_000_000,
            totalRequests30d: 150,
            topProviders: [ProviderCostSummary(provider: "claudecode", cost: 25.0, tokens: 500_000, requests: 80)],
            topModels: [ModelCostSummary(provider: "claudecode", model: "claude-sonnet-4-20250514", cost: 25.0, tokens: 500_000)]
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(RecentUsageSummary.self, from: data)
        XCTAssertEqual(decoded.totalCost30d, 42.50)
        XCTAssertEqual(decoded.topProviders.count, 1)
    }

    func testEscrowEnvelopeCodable() throws {
        let envelope = EscrowSecretEnvelope(
            grantId: "grant-1",
            sourceDeviceId: "mac-1",
            targetDeviceId: "ios-1",
            providerId: "claudecode",
            credentialKind: .apiKey,
            accountLabel: "Work Account",
            ciphertext: "base64encryptedpayload"
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(EscrowSecretEnvelope.self, from: data)
        XCTAssertEqual(decoded.grantId, "grant-1")
        XCTAssertEqual(decoded.credentialKind, .apiKey)
        XCTAssertEqual(decoded.ciphertext, "base64encryptedpayload")
    }

    func testEscrowAuditEventCodable() throws {
        let event = EscrowAuditEvent(
            eventType: .envelopeCreated,
            actorDeviceId: "mac-1",
            targetDeviceId: "ios-1",
            providerId: "claudecode",
            grantId: "grant-1"
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(EscrowAuditEvent.self, from: data)
        XCTAssertEqual(decoded.eventType, .envelopeCreated)
    }
}
