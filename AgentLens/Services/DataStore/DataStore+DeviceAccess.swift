import Foundation
import OpenBurnBarCore

extension DataStore {
    func fetchDevices() async throws -> [DeviceRecord] {
        try await actor.deviceStore.fetchDevices()
    }

    func upsertDevice(_ device: DeviceRecord) async throws {
        try await actor.deviceStore.upsertDevice(device)
    }

    func deviceUsageSummaries() async throws -> [DeviceUsageSummary] {
        try await actor.deviceStore.deviceUsageSummaries()
    }

    func updateDeviceIcon(deviceId: String, customIcon: String?) async throws {
        try await actor.deviceStore.updateDeviceIcon(deviceId: deviceId, customIcon: customIcon)
    }
}
