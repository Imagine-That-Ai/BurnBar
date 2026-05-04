@testable import OpenBurnBar

@MainActor
final class FakeMacDeviceTrustGateway: MacDeviceTrustGateway {
    var devices: [MacTrustedDevice]
    var approvedDeviceIDs: [String] = []
    var revokedDeviceIDs: [String] = []

    init(devices: [MacTrustedDevice]) {
        self.devices = devices
    }

    func trustedDevices() async throws -> [MacTrustedDevice] {
        devices
    }

    func approve(deviceID: String) async throws {
        approvedDeviceIDs.append(deviceID)
    }

    func revoke(deviceID: String) async throws {
        revokedDeviceIDs.append(deviceID)
        devices.removeAll { $0.id == deviceID }
    }
}
