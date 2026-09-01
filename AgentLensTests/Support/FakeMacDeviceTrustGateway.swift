@testable import OpenBurnBar

@MainActor
final class FakeMacDeviceTrustGateway: MacDeviceTrustGateway {
    var devices: [MacTrustedDevice]
    var approvedDeviceIDs: [String] = []
    var revokedDeviceIDs: [String] = []
    var approveError: Error?
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
        if let approveError {
            throw approveError
        }
        approvedDeviceIDs.append(deviceID)
        devices = devices.map { device in
            guard device.id == deviceID else { return device }
            return MacTrustedDevice(
                id: device.id,
                displayName: device.displayName,
                platform: device.platform,
                trustState: .trusted,
                isCurrentDevice: device.isCurrentDevice,
                registrationUpdatedAt: device.registrationUpdatedAt,
                publicKeyFingerprint: device.publicKeyFingerprint,
                publicKeyData: device.publicKeyData
            )
        }
    }

    func revoke(deviceID: String) async throws -> ComputerUseSecurityCallableClient.EscrowDeviceTrustRevocationResult {
        revokedDeviceIDs.append(deviceID)
        devices.removeAll { $0.id == deviceID }
        return revocationResult
    }
}
