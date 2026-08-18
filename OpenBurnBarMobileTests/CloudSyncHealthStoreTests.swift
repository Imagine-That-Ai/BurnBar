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

    func testCanceledRefreshDoesNotApplyLateResult() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = StubCloudReader(snapshot: CloudSyncStatusSnapshot(
            lastPublishedAt: now.addingTimeInterval(-5 * 60),
            lastReadAt: now
        ))
        let store = CloudSyncHealthStore(reader: reader)
        reader.onLoad = { store.cancelRefresh() }

        await store.refresh(now: now)

        XCTAssertEqual(store.health, .syncing)
        XCTAssertNil(store.lastPublishedAt)
        XCTAssertNotEqual(store.freshness, .live)
    }

    func testCacheClearDropsPreviousSnapshot() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = StubCloudReader(snapshot: CloudSyncStatusSnapshot(
            lastPublishedAt: now.addingTimeInterval(-5 * 60),
            lastReadAt: now
        ))
        let store = CloudSyncHealthStore(reader: reader)
        await store.refresh(now: now)
        XCTAssertEqual(store.health, .healthy)

        store.clearCache()

        XCTAssertEqual(store.health, .unknown)
        XCTAssertEqual(store.freshness, .empty)
        XCTAssertNil(store.lastPublishedAt)
    }

    func testEmptyAndFailedLoadsAreDistinct() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let empty = CloudSyncHealthStore(reader: StubCloudReader(snapshot: CloudSyncStatusSnapshot(
            lastPublishedAt: nil,
            lastReadAt: now
        )))
        await empty.refresh(now: now)
        XCTAssertEqual(empty.freshness, .empty)

        let failed = CloudSyncHealthStore(
            reader: StubCloudReader(error: CloudGatewayError.classified(.networkUnavailable))
        )
        await failed.refresh(now: now)
        XCTAssertEqual(failed.health, .offline)
        XCTAssertEqual(failed.freshness, .offline)
        XCTAssertNotEqual(empty.freshness, failed.freshness)
    }

    func testAppCheckFailureStillShowsAppCheckBlocked() async {
        let reader = StubCloudReader(error: CloudGatewayError.classified(.appCheckBlocked))
        let store = CloudSyncHealthStore(reader: reader)

        await store.refresh()

        XCTAssertEqual(store.health, .appCheckBlocked)
        XCTAssertTrue(store.health.isDegraded)
    }

    // MARK: - Kill-switch honesty

    /// With Firestore's network deliberately off, every read silently answers
    /// from an empty cache — which used to render as "$0.00" and "Mac last
    /// seen: never". The store must say what is actually happening and must
    /// not consult the reader at all.
    func testNetworkDisabledOnThisDeviceIsSurfacedInsteadOfFakedEmptyData() async {
        let reader = StubCloudReader(snapshot: CloudSyncStatusSnapshot())
        let store = CloudSyncHealthStore(reader: reader, isNetworkDisabledOnThisDevice: { true })

        await store.refresh()

        XCTAssertEqual(store.health, .networkDisabledOnThisDevice)
        XCTAssertTrue(store.health.isDegraded)
        XCTAssertEqual(reader.loadSyncStatusCallCount, 0, "no point reading a dead network")
    }

    // MARK: - Mac-reported blocked reason

    /// A Mac whose upload is blocked (e.g. vault key unavailable) now reports a
    /// bounded `lastErrorCode`; the phone must surface the human explanation
    /// rather than a generic "degraded".
    func testMacReportedBlockedReasonIsSurfaced() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reason = CloudErrorClassification.other(
            message: "Your Mac is waiting for cloud-vault approval from another signed-in device."
        )
        let reader = StubCloudReader(snapshot: CloudSyncStatusSnapshot(
            lastPublishedAt: nil,
            lastReadAt: now,
            publisher: CloudPublisherDevice(
                deviceID: "mac-1",
                displayName: "Alberto's MacBook Pro",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-2 * 60)
            ),
            lastErrorClassification: reason
        ))
        let store = CloudSyncHealthStore(reader: reader)

        await store.refresh(now: now)

        XCTAssertEqual(store.health, .degraded(reason: reason))
        XCTAssertEqual(
            store.statusLabel(now: now),
            "Your Mac is waiting for cloud-vault approval from another signed-in device."
        )
    }

    // MARK: - Truly-never copy is actionable

    func testNoMacEverRegisteredGetsActionableCopyNotBareNever() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reader = StubCloudReader(snapshot: CloudSyncStatusSnapshot(
            lastPublishedAt: nil,
            lastReadAt: now
        ))
        let store = CloudSyncHealthStore(reader: reader)

        await store.refresh(now: now)

        XCTAssertEqual(store.health, .macNotSyncing)
        let label = store.statusLabel(now: now)
        XCTAssertTrue(label.contains("No Mac has synced"), "got: \(label)")
        XCTAssertTrue(label.contains("same sign-in"), "the copy must point at the account-fork cause; got: \(label)")
    }

}

@MainActor
private final class StubCloudReader: CloudReader {
    private let snapshot: CloudSyncStatusSnapshot?
    private let error: Error?
    private(set) var loadSyncStatusCallCount = 0
    var onLoad: (() -> Void)?

    init(snapshot: CloudSyncStatusSnapshot? = nil, error: Error? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    func loadSyncStatus() async throws -> CloudSyncStatusSnapshot {
        loadSyncStatusCallCount += 1
        onLoad?()
        if let error { throw error }
        return snapshot ?? CloudSyncStatusSnapshot()
    }

    func loadProviderSummaries() async throws -> [ProviderConnectionDoc] { [] }
    func loadDevices() async throws -> [DeviceRecord] { [] }
    func loadAvailableEnvelopes() async throws -> [AvailableEnvelope] { [] }
    func loadUnsupportedEnvelopes() async throws -> [UnsupportedEnvelope] { [] }
    func loadImportHistory() async throws -> [ImportHistoryEntry] { [] }
}
