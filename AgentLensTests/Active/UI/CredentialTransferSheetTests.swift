import XCTest
import SwiftUI
import ViewInspector
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class CredentialTransferSheetTests: XCTestCase {

    func test_rendersWithoutCrash() throws {
        let deviceTrust = DeviceTrustViewModel(gateway: FakeMacDeviceTrustGateway(devices: []))
        let exportVM = CredentialTransferExportViewModel(gateway: FakeExportGateway())
        let sheet = CredentialTransferSheet(
            provider: .minimax,
            deviceTrust: deviceTrust,
            exportViewModel: exportVM
        )
        XCTAssertNoThrow(try sheet.inspect())
    }

    func test_classifyProviderUsesCachedValue() async {
        let gateway = FakeExportGateway()
        let vm = CredentialTransferExportViewModel(gateway: gateway)
        let first = await vm.classifyProvider(.minimax, accountLabel: "primary")
        let second = await vm.classifyProvider(.minimax, accountLabel: "primary")
        XCTAssertEqual(first.transferability, second.transferability)
        XCTAssertEqual(gateway.classifyCallCount, 1)
    }

    func test_apiKeyTransferabilityIsTransferable() {
        XCTAssertTrue(MacCredentialTransferability.apiKey.isTransferable)
        XCTAssertTrue(MacCredentialTransferability.oauthToken.isTransferable)
        XCTAssertTrue(MacCredentialTransferability.bearerToken.isTransferable)
        XCTAssertFalse(MacCredentialTransferability.browserSession.isTransferable)
        XCTAssertFalse(MacCredentialTransferability.providerDoesNotAllowPortable.isTransferable)
        XCTAssertFalse(MacCredentialTransferability.noExportFromSource.isTransferable)
        XCTAssertFalse(MacCredentialTransferability.unsupportedKind.isTransferable)
    }

    func test_exportFailureCarriesMessage() async {
        let gateway = FakeExportGateway()
        gateway.failureMessage = "denied"
        let vm = CredentialTransferExportViewModel(gateway: gateway)
        await vm.startExport(provider: .minimax, destinationDeviceID: "iphone")

        if case .failed(let message) = vm.exportStage {
            XCTAssertEqual(message, "denied")
        } else {
            XCTFail("Expected failed stage, got \(vm.exportStage)")
        }
    }

    func test_defaultMacCredentialExportGatewayFailsClosed() async {
        let gateway = DefaultMacCredentialTransferGateway()
        var stages: [MacExportStage] = []

        await gateway.startExport(provider: .minimax, destinationDeviceID: "iphone") { stage in
            stages.append(stage)
        }

        XCTAssertEqual(stages.count, 1)
        if case .failed(let message) = stages.first {
            XCTAssertTrue(message.contains("No credential was read"))
        } else {
            XCTFail("Expected fail-closed export stage, got \(String(describing: stages.first))")
        }
    }

    func test_deviceTrustViewModelDeduplicatesRepeatedPhysicalDevices() async {
        let gateway = FakeMacDeviceTrustGateway(devices: [
            MacTrustedDevice(id: "iphone-old", displayName: "Alberto’s iPhone", platform: "iOS"),
            MacTrustedDevice(id: "iphone-new", displayName: "Alberto’s iPhone", platform: "iOS"),
            MacTrustedDevice(id: "mac", displayName: "MacBook Pro", platform: "macOS", isCurrentDevice: true)
        ])
        let vm = DeviceTrustViewModel(gateway: gateway)

        await vm.load()

        XCTAssertEqual(vm.trustedDevices.count, 2)
        XCTAssertEqual(vm.trustedDevices.map(\.displayName), ["MacBook Pro", "Alberto’s iPhone"])
    }

    func test_deviceTrustRevokeReportsCompletedCloudVaultRotation() async {
        let gateway = FakeMacDeviceTrustGateway(devices: [
            MacTrustedDevice(id: "iphone", displayName: "iPhone", platform: "iOS")
        ])
        gateway.revocationResult = ComputerUseSecurityCallableClient.EscrowDeviceTrustRevocationResult(
            revokedCloudVaultWrappers: 1,
            cloudVaultRotationRequired: true,
            cloudVaultRotationRequirementId: "revoke_1",
            cloudVaultRotationBlockedReason: nil,
            cloudVaultRotationJobId: "cvr_1",
            cloudVaultRotationCompleted: true,
            cloudVaultRotationFailureMessage: nil,
            cloudVaultRotationRewrappedDocuments: 2,
            cloudVaultRotationRewrappedStorageBlobs: 1
        )
        let vm = DeviceTrustViewModel(gateway: gateway)

        await vm.revoke(deviceID: "iphone")

        XCTAssertEqual(gateway.revokedDeviceIDs, ["iphone"])
        XCTAssertEqual(vm.trustedDevices, [])
        XCTAssertEqual(vm.lastStatusMessage?.contains("Cloud Vault rotated"), true)
        XCTAssertEqual(vm.lastStatusMessage?.contains("2 documents"), true)
        XCTAssertEqual(vm.lastStatusMessage?.contains("1 encrypted blob"), true)
        XCTAssertNil(vm.lastErrorMessage)
    }

    func test_deviceTrustRevokeReportsRotationFailureWithoutMaskingRevocation() async {
        let gateway = FakeMacDeviceTrustGateway(devices: [
            MacTrustedDevice(id: "iphone", displayName: "iPhone", platform: "iOS")
        ])
        gateway.revocationResult = ComputerUseSecurityCallableClient.EscrowDeviceTrustRevocationResult(
            revokedCloudVaultWrappers: 1,
            cloudVaultRotationRequired: true,
            cloudVaultRotationRequirementId: "revoke_1",
            cloudVaultRotationBlockedReason: nil,
            cloudVaultRotationFailureMessage: "Cloud Vault key is unavailable on this device."
        )
        let vm = DeviceTrustViewModel(gateway: gateway)

        await vm.revoke(deviceID: "iphone")

        XCTAssertEqual(gateway.revokedDeviceIDs, ["iphone"])
        XCTAssertEqual(vm.trustedDevices, [])
        XCTAssertEqual(vm.lastStatusMessage?.contains("Device revoked"), true)
        XCTAssertEqual(vm.lastStatusMessage?.contains("still needs attention"), true)
        XCTAssertEqual(vm.lastStatusMessage?.contains("Cloud Vault key is unavailable"), true)
        XCTAssertNil(vm.lastErrorMessage)
    }

    func test_devicesSettingsExposeNestHubControls() throws {
        let deviceTrust = DeviceTrustViewModel(gateway: FakeMacDeviceTrustGateway(devices: []))
        let view = DevicesAndSyncSettingsView(
            settingsManager: SettingsManager(),
            deviceTrust: deviceTrust,
            exportViewModel: CredentialTransferExportViewModel(gateway: FakeExportGateway())
        )
        let sut = try view.inspect()

        // The Devices landing exposes a Smart Displays drill-down row.
        XCTAssertNoThrow(try sut.find(text: MacCopy.smartDisplaysSectionTitle))

        // Drilling into Smart Displays shows the Nest Hub controls.
        let detail = SmartDisplaysDetailView(
            settingsManager: SettingsManager(),
            runtimeContext: nil
        )
        let detailSUT = try detail.inspect()
        XCTAssertNoThrow(try detailSUT.find(text: MacCopy.googleNestHubSectionTitle))
        XCTAssertNoThrow(try detailSUT.find(text: "Nest Hub quota display"))
    }
}

@MainActor
final class FakeExportGateway: MacCredentialTransferGateway {
    var classifyCallCount = 0
    var transferabilityResult: MacCredentialTransferability = .apiKey
    var failureMessage: String?

    func transferability(for provider: AgentProvider) async -> MacCredentialTransferability {
        classifyCallCount += 1
        return transferabilityResult
    }

    func activeGrants() async throws -> [MacEscrowGrantSummary] { [] }

    func startExport(
        provider: AgentProvider,
        destinationDeviceID: String,
        onStage: @escaping @MainActor (MacExportStage) -> Void
    ) async {
        onStage(.encrypting)
        if let failureMessage {
            onStage(.failed(message: failureMessage))
        } else {
            onStage(.uploading)
            onStage(.waitingReadback)
            onStage(.done)
        }
    }

    func revoke(grantID: String) async throws {}
}
