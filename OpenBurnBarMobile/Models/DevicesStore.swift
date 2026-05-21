import Foundation
import OpenBurnBarCore

@Observable @MainActor
final class DevicesStore {
    private let reader: CloudReader
    private let trustGateway: DeviceTrustGateway
    private var rawDevices: [DeviceRecord] = []
    private(set) var isLoading = false
    private(set) var lastError: CloudErrorClassification?
    private(set) var actionInFlightFor: String?

    init(reader: CloudReader = LiveCloudReader(), trustGateway: DeviceTrustGateway = LiveDeviceTrustGateway()) {
        self.reader = reader; self.trustGateway = trustGateway
    }

    /// Display-ready devices. Raw Firestore device docs can include stale
    /// reinstall/re-pairing copies; keep those only for the cleanup action.
    var devices: [DeviceRecord] {
        Self.deduplicated(rawDevices)
    }

    var currentDevice: DeviceRecord? {
        devices.first(where: \.isCurrentDevice)
    }

    /// Distinct other devices, deduped by display-name + platform. When
    /// multiple Firestore docs map to the same physical device (e.g. the
    /// user reinstalled iOS and got fresh UUIDs before we anchored on
    /// `identifierForVendor`), we keep the most-recently-seen as the
    /// "primary" entry.
    var otherDevices: [DeviceRecord] {
        devices.filter { !$0.isCurrentDevice }
    }

    /// Stale duplicates that we hid from the main list. Surfaced in a
    /// "Cleanup" card so the user can revoke them in bulk.
    var staleDuplicates: [DeviceRecord] {
        let primaries = Set(devices.map(\.id))
        return rawDevices
            .filter { !primaries.contains($0.id) }
            .sorted { lhs, rhs in
                (lhs.lastSeen ?? .distantPast) > (rhs.lastSeen ?? .distantPast)
            }
    }

    var thisDeviceTrustState: DeviceTrustState { currentDevice?.trustState ?? .pending }
    var bootstrapEligible: Bool {
        let hasTrusted = rawDevices.contains { $0.trustState == .trusted && !$0.isCurrentDevice }
        return !hasTrusted && thisDeviceTrustState != .trusted
    }

    // MARK: - Dedup

    /// Group records by (lowercased display name, platform) and keep the
    /// most-recently-seen (or trusted, when last-seen is missing).
    private static func deduplicated(_ records: [DeviceRecord]) -> [DeviceRecord] {
        let groups = Dictionary(grouping: records) { record -> String in
            let name = record.displayName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name)\u{1F}\(record.platform.lowercased())"
        }
        let primaries = groups.values.map { bucket -> DeviceRecord in
            bucket.max(by: Self.staleness) ?? bucket[0]
        }
        return primaries.sorted { lhs, rhs in
            (lhs.lastSeen ?? .distantPast) > (rhs.lastSeen ?? .distantPast)
        }
    }

    /// Returns `true` when `lhs` is staler than `rhs` (so `max(by:)`
    /// picks the freshest record).
    private static func staleness(_ lhs: DeviceRecord, _ rhs: DeviceRecord) -> Bool {
        if lhs.trustState != rhs.trustState {
            return trustRank(lhs.trustState) < trustRank(rhs.trustState)
        }
        let lhsSeen = lhs.lastSeen ?? .distantPast
        let rhsSeen = rhs.lastSeen ?? .distantPast
        return lhsSeen < rhsSeen
    }

    private static func trustRank(_ state: DeviceTrustState) -> Int {
        switch state {
        case .current: return 3
        case .trusted: return 2
        case .pending: return 1
        case .revoked: return 0
        }
    }

    /// Revoke every record in `staleDuplicates`. Used by the "Clean up
    /// duplicates" button in the Devices view.
    func revokeStaleDuplicates() async {
        let stale = staleDuplicates
        for device in stale {
            actionInFlightFor = device.id
            do { try await trustGateway.revoke(deviceID: device.id) }
            catch let CloudGatewayError.classified(c) { lastError = c }
            catch { lastError = .other(message: error.localizedDescription) }
        }
        actionInFlightFor = nil
        await load()
    }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do { rawDevices = try await reader.loadDevices(); lastError = nil }
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
