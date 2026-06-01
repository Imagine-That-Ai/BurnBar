import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class CloudSyncHealthStoreTests: XCTestCase {

    func testStaleMacHeartbeatShowsMacNotSyncingInsteadOfDegradedCloud() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = StubCloudReader(snapshot: CloudSyncStatusSnapshot(
            lastPublishedAt: now.addingTimeInterval(-31 * 60),
            lastReadAt: now,
            publisher: CloudPublisherDevice(
                deviceID: "mac-1",
                displayName: "Alberto's MacBook Pro",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-31 * 60)
            )
        ))
        let store = CloudSyncHealthStore(reader: reader)

        await store.refresh(now: now)

        XCTAssertEqual(store.health, .macNotSyncing)
        XCTAssertEqual(store.statusLabel(now: now), "Mac last seen: 31 mins ago")
        XCTAssertFalse(store.health.isDegraded)
    }

    func testMacLastSeenUsesHoursForOlderHeartbeat() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = StubCloudReader(snapshot: CloudSyncStatusSnapshot(
            lastPublishedAt: now.addingTimeInterval(-2.4 * 60 * 60),
            lastReadAt: now,
            publisher: CloudPublisherDevice(
                deviceID: "mac-1",
                displayName: "Alberto's MacBook Pro",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-2.4 * 60 * 60)
            )
        ))
        let store = CloudSyncHealthStore(reader: reader)

        await store.refresh(now: now)

        XCTAssertEqual(store.statusLabel(now: now), "Mac last seen: 2 hours ago")
    }

    func testFreshMacHeartbeatShowsHealthyCloudSync() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = StubCloudReader(snapshot: CloudSyncStatusSnapshot(
            lastPublishedAt: now.addingTimeInterval(-5 * 60),
            lastReadAt: now
        ))
        let store = CloudSyncHealthStore(reader: reader)

        await store.refresh(now: now)

        XCTAssertEqual(store.health, .healthy)
    }

    func testAppCheckFailureStillShowsAppCheckBlocked() async {
        let reader = StubCloudReader(error: CloudGatewayError.classified(.appCheckBlocked))
        let store = CloudSyncHealthStore(reader: reader)

        await store.refresh()

        XCTAssertEqual(store.health, .appCheckBlocked)
        XCTAssertTrue(store.health.isDegraded)
    }
}

@MainActor
private final class StubCloudReader: CloudReader {
    private let snapshot: CloudSyncStatusSnapshot?
    private let error: Error?

    init(snapshot: CloudSyncStatusSnapshot? = nil, error: Error? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    func loadSyncStatus() async throws -> CloudSyncStatusSnapshot {
        if let error { throw error }
        return snapshot ?? CloudSyncStatusSnapshot()
    }

    func loadProviderSummaries() async throws -> [ProviderConnectionDoc] { [] }
    func loadDevices() async throws -> [DeviceRecord] { [] }
    func loadAvailableEnvelopes() async throws -> [AvailableEnvelope] { [] }
    func loadUnsupportedEnvelopes() async throws -> [UnsupportedEnvelope] { [] }
    func loadImportHistory() async throws -> [ImportHistoryEntry] { [] }
}
