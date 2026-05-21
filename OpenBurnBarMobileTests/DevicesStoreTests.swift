import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class DevicesStoreTests: XCTestCase {
    func testDisplayDevicesCollapseStaleCopiesAndKeepCleanupRecords() async {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let reader = FakeDevicesCloudReader(devices: [
            DeviceRecord(
                id: "iphone-current",
                displayName: "Alberto iPhone",
                platform: "iOS",
                lastSeen: now,
                trustState: .current,
                isCurrentDevice: true
            ),
            DeviceRecord(
                id: "iphone-old",
                displayName: "Alberto iPhone",
                platform: "iOS",
                lastSeen: now.addingTimeInterval(-600),
                trustState: .trusted
            ),
            DeviceRecord(
                id: "macbook-old",
                displayName: "Alberto MacBook",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-3_600),
                trustState: .trusted
            ),
            DeviceRecord(
                id: "macbook-new",
                displayName: "Alberto MacBook",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-60),
                trustState: .pending
            ),
            DeviceRecord(
                id: "mac-mini",
                displayName: "Alberto Mac mini",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-120),
                trustState: .trusted
            ),
            DeviceRecord(
                id: "samsung",
                displayName: "Samsung",
                platform: "Android",
                lastSeen: now.addingTimeInterval(-180),
                trustState: .trusted
            )
        ])
        let store = DevicesStore(reader: reader, trustGateway: FakeDeviceTrustGateway())

        await store.load()

        XCTAssertEqual(store.devices.map(\.id), ["iphone-current", "mac-mini", "samsung", "macbook-old"])
        XCTAssertEqual(store.devices.count, 4)
        XCTAssertEqual(store.otherDevices.map(\.id), ["mac-mini", "samsung", "macbook-old"])
        XCTAssertEqual(store.staleDuplicates.map(\.id), ["macbook-new", "iphone-old"])
    }

    func testTrustedDeviceWinsOverNewerPendingDuplicate() async {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let reader = FakeDevicesCloudReader(devices: [
            DeviceRecord(
                id: "trusted-mac",
                displayName: "Alberto MacBook",
                platform: "macOS",
                lastSeen: now.addingTimeInterval(-3_600),
                trustState: .trusted
            ),
            DeviceRecord(
                id: "pending-mac",
                displayName: "Alberto MacBook",
                platform: "macOS",
                lastSeen: now,
                trustState: .pending
            )
        ])
        let store = DevicesStore(reader: reader, trustGateway: FakeDeviceTrustGateway())

        await store.load()

        XCTAssertEqual(store.devices.map(\.id), ["trusted-mac"])
        XCTAssertEqual(store.staleDuplicates.map(\.id), ["pending-mac"])
    }
}

@MainActor
private final class FakeDevicesCloudReader: CloudReader {
    private let devices: [DeviceRecord]

    init(devices: [DeviceRecord]) {
        self.devices = devices
    }

    func loadSyncStatus() async throws -> CloudSyncStatusSnapshot {
        CloudSyncStatusSnapshot()
    }

    func loadProviderSummaries() async throws -> [ProviderConnectionDoc] {
        []
    }

    func loadDevices() async throws -> [DeviceRecord] {
        devices
    }

    func loadAvailableEnvelopes() async throws -> [AvailableEnvelope] {
        []
    }

    func loadUnsupportedEnvelopes() async throws -> [UnsupportedEnvelope] {
        []
    }

    func loadImportHistory() async throws -> [ImportHistoryEntry] {
        []
    }
}

@MainActor
private final class FakeDeviceTrustGateway: DeviceTrustGateway {
    func bootstrapApproveSelf() async throws {}
    func renameSelf(_ newName: String) async throws {}
    func revoke(deviceID: String) async throws {}
}
