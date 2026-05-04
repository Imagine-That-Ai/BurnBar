import Foundation
import OpenBurnBarCore

@Observable @MainActor
final class DevicesStore {
    private let reader: CloudReader
    private let trustGateway: DeviceTrustGateway
    private(set) var devices: [DeviceRecord] = []
    private(set) var isLoading = false
    private(set) var lastError: CloudErrorClassification?
    private(set) var actionInFlightFor: String?

    init(reader: CloudReader = LiveCloudReader(), trustGateway: DeviceTrustGateway = LiveDeviceTrustGateway()) {
        self.reader = reader; self.trustGateway = trustGateway
    }

    var currentDevice: DeviceRecord? { devices.first { $0.isCurrentDevice } }
    var otherDevices: [DeviceRecord] { devices.filter { !$0.isCurrentDevice } }
    var thisDeviceTrustState: DeviceTrustState { currentDevice?.trustState ?? .pending }
    var bootstrapEligible: Bool {
        let hasTrusted = devices.contains { $0.trustState == .trusted && !$0.isCurrentDevice }
        return !hasTrusted && thisDeviceTrustState != .trusted
    }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do { devices = try await reader.loadDevices(); lastError = nil }
        catch let CloudGatewayError.classified(c) { lastError = c }
        catch { lastError = .other(message: error.localizedDescription) }
    }

    func bootstrapApproveSelf() async {
        actionInFlightFor = currentDevice?.id; defer { actionInFlightFor = nil }
        do { try await trustGateway.bootstrapApproveSelf(); await load() }
        catch let CloudGatewayError.classified(c) { lastError = c }
        catch { lastError = .other(message: error.localizedDescription) }
    }

    func renameSelf(_ newName: String) async {
        actionInFlightFor = currentDevice?.id; defer { actionInFlightFor = nil }
        do { try await trustGateway.renameSelf(newName); await load() }
        catch let CloudGatewayError.classified(c) { lastError = c }
        catch { lastError = .other(message: error.localizedDescription) }
    }

    func revoke(_ device: DeviceRecord) async {
        actionInFlightFor = device.id; defer { actionInFlightFor = nil }
        do { try await trustGateway.revoke(deviceID: device.id); await load() }
        catch let CloudGatewayError.classified(c) { lastError = c }
        catch { lastError = .other(message: error.localizedDescription) }
    }
}
