#if canImport(AppKit)
import ViewInspector
import XCTest
@testable import OpenBurnBar

@MainActor
final class PendingDeviceApprovalModelTests: XCTestCase {

    func test_refreshListsEveryPendingDeviceIncludingThisMac() async {
        let gateway = FakeMacDeviceTrustGateway(devices: [
            MacTrustedDevice(id: "mini", displayName: "Tikka Mac mini", platform: "macOS", isCurrentDevice: true),
            MacTrustedDevice(id: "web-1", displayName: "Chrome on Mac", platform: "web"),
            MacTrustedDevice(id: "web-2", displayName: "Safari on iPhone", platform: "web"),
            MacTrustedDevice(id: "phone", displayName: "iPhone", platform: "iOS", trustState: .trusted),
            MacTrustedDevice(id: "ipad", displayName: "iPad", platform: "iPadOS")
        ])
        let model = PendingDeviceApprovalModel(gateway: gateway)

        await model.refresh()

        XCTAssertEqual(model.pendingDevices.count, 4)
        XCTAssertEqual(Set(model.pendingDevices.map(\.id)), ["mini", "web-1", "web-2", "ipad"])
        XCTAssertFalse(model.canApproveFromThisDevice)
        XCTAssertTrue(model.pendingDevices.contains { $0.isCurrentDevice })
    }

    func test_untrustedMacCannotApproveOtherDevices() async {
        let gateway = FakeMacDeviceTrustGateway(devices: [
            MacTrustedDevice(id: "mini", displayName: "Mac mini", platform: "macOS", isCurrentDevice: true),
            MacTrustedDevice(id: "web", displayName: "Chrome", platform: "web"),
            MacTrustedDevice(id: "phone", displayName: "iPhone", platform: "iOS", trustState: .trusted)
        ])
        let model = PendingDeviceApprovalModel(gateway: gateway)
        await model.refresh()

        await model.approve(device: gateway.devices.first { $0.id == "web" }!)

        XCTAssertTrue(gateway.approvedDeviceIDs.isEmpty)
        XCTAssertEqual(model.lastErrorMessage, MacCopy.pendingApprovalNeedsTrustedApprover)
    }

    func test_trustedMacApprovesOtherPendingDevicesAndSurfacesServerErrors() async {
        let gateway = FakeMacDeviceTrustGateway(devices: [
            MacTrustedDevice(
                id: "mac",
                displayName: "MacBook",
                platform: "macOS",
                trustState: .trusted,
                isCurrentDevice: true
            ),
            MacTrustedDevice(id: "mini", displayName: "Mac mini", platform: "macOS")
        ])
        let model = PendingDeviceApprovalModel(gateway: gateway)
        await model.refresh()
        XCTAssertTrue(model.canApproveFromThisDevice)

        await model.approve(device: gateway.devices.first { $0.id == "mini" }!)
        XCTAssertEqual(gateway.approvedDeviceIDs, ["mini"])
        XCTAssertFalse(model.pendingDevices.contains { $0.id == "mini" })

        gateway.approveError = FakeLocalizedError(
            "A distinct trusted native device must approve this escrow device."
        )
        gateway.devices.append(MacTrustedDevice(id: "web", displayName: "Chrome", platform: "web"))
        await model.refresh()
        await model.approve(device: gateway.devices.first { $0.id == "web" }!)
        XCTAssertEqual(model.lastErrorMessage, MacCopy.pendingApprovalNeedsTrustedApprover)
    }

    func test_bannerRendersEveryPendingDeviceName() async throws {
        let gateway = FakeMacDeviceTrustGateway(devices: [
            MacTrustedDevice(id: "mini", displayName: "Tikka Mac mini", platform: "macOS", isCurrentDevice: true),
            MacTrustedDevice(id: "web-1", displayName: "Chrome on Mac", platform: "web"),
            MacTrustedDevice(id: "web-2", displayName: "Safari on iPhone", platform: "web")
        ])
        let model = PendingDeviceApprovalModel(gateway: gateway)
        await model.refresh()
        let view = PendingDeviceApprovalBanner(model: model)
        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(text: "3 devices waiting for approval"))
        XCTAssertNoThrow(try sut.find(text: "Tikka Mac mini (this Mac)"))
        XCTAssertNoThrow(try sut.find(text: "Chrome on Mac"))
        XCTAssertNoThrow(try sut.find(text: "Safari on iPhone"))
        XCTAssertNoThrow(try sut.find(text: MacCopy.pendingApprovalNeedsTrustedApprover))
        XCTAssertNoThrow(try sut.find(text: MacCopy.reviewPendingDevices))
    }

    func test_settingsBlocksApproveWhenThisMacIsStillPending() {
        let devices = [
            MacTrustedDevice(id: "mini", displayName: "Mac mini", platform: "macOS", isCurrentDevice: true),
            MacTrustedDevice(id: "phone", displayName: "iPhone", platform: "iOS", trustState: .trusted),
            MacTrustedDevice(id: "web", displayName: "Chrome", platform: "web")
        ]
        XCTAssertEqual(
            DeviceTrustViewModel.approvalBlockReason(deviceID: "web", devices: devices),
            MacCopy.pendingApprovalNeedsTrustedApprover
        )
        XCTAssertEqual(
            DeviceTrustViewModel.approvalBlockReason(deviceID: "mini", devices: devices),
            MacCopy.pendingApprovalNeedsTrustedApprover
        )
        let trustedMac = [
            MacTrustedDevice(
                id: "mac",
                displayName: "MacBook",
                platform: "macOS",
                trustState: .trusted,
                isCurrentDevice: true
            ),
            MacTrustedDevice(id: "web", displayName: "Chrome", platform: "web")
        ]
        XCTAssertNil(DeviceTrustViewModel.approvalBlockReason(deviceID: "web", devices: trustedMac))
    }

    func test_webOnlyTrustedRegistrationDoesNotBlockBootstrapSelfApprove() {
        let devices = [
            MacTrustedDevice(id: "mini", displayName: "Mac mini", platform: "macOS", isCurrentDevice: true),
            MacTrustedDevice(id: "web", displayName: "Chrome", platform: "web", trustState: .trusted)
        ]
        XCTAssertNil(DeviceTrustViewModel.approvalBlockReason(deviceID: "mini", devices: devices))
    }

    func test_refreshPrefersTrustedDuplicateOverOlderPendingRow() async {
        let older = Date(timeIntervalSince1970: 1)
        let newer = Date(timeIntervalSince1970: 2)
        let gateway = FakeMacDeviceTrustGateway(devices: [
            MacTrustedDevice(
                id: "mac",
                displayName: "MacBook",
                platform: "macOS",
                trustState: .pending,
                isCurrentDevice: true,
                registrationUpdatedAt: older
            ),
            MacTrustedDevice(
                id: "mac",
                displayName: "MacBook",
                platform: "macOS",
                trustState: .trusted,
                isCurrentDevice: true,
                registrationUpdatedAt: newer
            )
        ])
        let model = PendingDeviceApprovalModel(gateway: gateway)
        await model.refresh()
        XCTAssertTrue(model.canApproveFromThisDevice)
        XCTAssertTrue(model.pendingDevices.isEmpty)
    }

    func test_identityMismatchIsNotRewrittenAsWaitingForApproval() {
        let error = FakeLocalizedError("Trust-chain approver identity does not match the approver device.")
        XCTAssertEqual(
            PendingDeviceApprovalModel.userFacingApprovalError(error),
            "Trust-chain approver identity does not match the approver device."
        )
        let native = FakeLocalizedError("Trust-chain approver must be a trusted native device.")
        XCTAssertEqual(
            PendingDeviceApprovalModel.userFacingApprovalError(native),
            MacCopy.pendingApprovalNeedsTrustedApprover
        )
    }
}

private struct FakeLocalizedError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
#endif
