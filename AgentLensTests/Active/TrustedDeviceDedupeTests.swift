import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// The Trusted Devices list collapses duplicate registrations of the same
/// physical device (same display name + platform). That collapse must NEVER
/// hide a pending registration behind a trusted one: device identities rotate
/// (vendor-ID reset, app reinstall), so a user's real phone re-registers as a
/// PENDING device under the same generic name ("iPhone") as its stale trusted
/// identity — and with the old name+platform key there was no row left to
/// approve, breaking mirroring/computer-control onboarding with no visible
/// error. Regression pin for the 2026-07-03 incident.
final class TrustedDeviceDedupeTests: XCTestCase {

    private func device(
        id: String,
        name: String = "iPhone",
        platform: String = "iOS",
        trust: EscrowDeviceTrustState
    ) -> MacTrustedDevice {
        MacTrustedDevice(
            id: id,
            displayName: name,
            platform: platform,
            trustState: trust
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

    func test_duplicateRegistrationsWithinSameTrustStateStillCollapse() {
        let rows = DeviceTrustViewModel.deduplicatedDevices([
            device(id: "CCCC", trust: .pending),
            device(id: "DDDD", trust: .pending),
            device(id: "EEEE", trust: .trusted)
        ])

        XCTAssertEqual(rows.count, 2, "same-state duplicates collapse; distinct states never merge")
        XCTAssertEqual(rows.filter { $0.trustState == .pending }.count, 1)
        XCTAssertEqual(rows.filter { $0.trustState == .trusted }.count, 1)
    }

    func test_distinctNamesNeverCollapse() {
        let rows = DeviceTrustViewModel.deduplicatedDevices([
            device(id: "FFFF", name: "iPhone 17 Pro Max (this phone)", trust: .pending),
            device(id: "GGGG", name: "iPhone", trust: .pending)
        ])

        XCTAssertEqual(rows.count, 2)
    }
}
