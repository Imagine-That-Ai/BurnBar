import Foundation
import OpenBurnBarCore

extension DataStore {
    nonisolated func fetchDevices() throws -> [DeviceRecord] {
        try deviceStore.fetchDevices()
    }

    nonisolated func upsertDevice(_ device: DeviceRecord) throws {
        try deviceStore.upsertDevice(device)
    }

    nonisolated func deviceUsageSummaries() throws -> [DeviceUsageSummary] {
        try deviceStore.deviceUsageSummaries()
    }

    nonisolated func updateDeviceIcon(deviceId: String, customIcon: String?) throws {
        try deviceStore.updateDeviceIcon(deviceId: deviceId, customIcon: customIcon)
    }
}
