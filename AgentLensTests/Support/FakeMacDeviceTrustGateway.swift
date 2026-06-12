@testable import OpenBurnBar

@MainActor
final class FakeMacDeviceTrustGateway: MacDeviceTrustGateway {
    var devices: [MacTrustedDevice]
    var approvedDeviceIDs: [String] = []
    var revokedDeviceIDs: [String] = []
    var revocationResult = ComputerUseSecurityCallableClient.EscrowDeviceTrustRevocationResult(
        revokedCloudVaultWrappers: 0,
        cloudVaultRotationRequired: false,
        cloudVaultRotationRequirementId: nil,
        cloudVaultRotationBlockedReason: nil
    )

    init(devices: [MacTrustedDevice]) {
        self.devices = devices
    }

    func trustedDevices() async throws -> [MacTrustedDevice] {
        devices
    }

    func approve(deviceID: String) async throws {
        approvedDeviceIDs.append(deviceID)
    }

    func revoke(deviceID: String) async throws -> ComputerUseSecurityCallableClient.EscrowDeviceTrustRevocationResult {
        revokedDeviceIDs.append(deviceID)
        devices.removeAll { $0.id == deviceID }
        return revocationResult
    }
}
