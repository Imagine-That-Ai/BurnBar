import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// Device identities rotate after reinstalls and resets while preserving the
/// same generic display metadata. Every distinct server identity must remain
/// visible so stale trust and pairing authority can be revoked independently.
@MainActor
final class TrustedDeviceDedupeTests: XCTestCase {

    private func device(
        id: String,
        name: String = "iPhone",
        platform: String = "iOS",
        trust: EscrowDeviceTrustState,
        updatedAt: Date? = nil
    ) -> MacTrustedDevice {
        MacTrustedDevice(
            id: id,
            displayName: name,
            platform: platform,
            trustState: trust,
            registrationUpdatedAt: updatedAt
        )
    }

    func test_pendingDeviceIsNeverHiddenBehindTrustedSameNameDevice() {
        let rows = DeviceTrustViewModel.deduplicatedDevices([
            device(id: "AAAA-trusted-legacy", trust: .trusted),
            device(id: "BBBB-current-phone", trust: .pending)
        ])

        XCTAssertEqual(rows.count, 2, "a pending registration must stay visible next to the trusted row")
        XCTAssertTrue(rows.contains { $0.id == "BBBB-current-phone" && $0.trustState == .pending })
        XCTAssertTrue(rows.contains { $0.id == "AAAA-trusted-legacy" && $0.trustState == .trusted })
    }

    func test_distinctRegistrationsWithinSameTrustStateRemainVisible() {
        let rows = DeviceTrustViewModel.deduplicatedDevices([
            device(id: "CCCC", trust: .pending),
            device(id: "DDDD", trust: .pending),
            device(id: "EEEE", trust: .trusted)
        ])

        XCTAssertEqual(rows.count, 3, "distinct device IDs must remain independently revocable")
        XCTAssertEqual(rows.filter { $0.trustState == .pending }.count, 2)
        XCTAssertEqual(rows.filter { $0.trustState == .trusted }.count, 1)
    }

    func test_distinctNamesNeverCollapse() {
        let rows = DeviceTrustViewModel.deduplicatedDevices([
            device(id: "FFFF", name: "iPhone 17 Pro Max (this phone)", trust: .pending),
            device(id: "GGGG", name: "iPhone", trust: .pending)
        ])

        XCTAssertEqual(rows.count, 2)
    }

    func test_repeatedSnapshotForSameDevicePrefersNewestRegistration() {
        let stale = Date(timeIntervalSince1970: 1_700_000_000)
        let attached = stale.addingTimeInterval(60)
        let rows = DeviceTrustViewModel.deduplicatedDevices([
            device(id: "6566-attached-ipad", name: "iPad", platform: "iPadOS", trust: .pending, updatedAt: stale),
            device(id: "6566-attached-ipad", name: "iPad", platform: "iPadOS", trust: .pending, updatedAt: attached)
        ])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "6566-attached-ipad")
        XCTAssertEqual(rows.first?.registrationUpdatedAt, attached)
    }
}
