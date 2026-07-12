import CryptoKit
import Foundation
import OpenBurnBarCore

enum LinuxAppCheckDeviceTrustState: String, Sendable, Equatable {
    case pending
    case approved
    case revoked
}

struct LinuxAppCheckDeviceRecord: Identifiable, Sendable, Equatable {
    let deviceId: String
    let deviceName: String
    let platform: String
    let safetyFingerprint: String
    let trustState: LinuxAppCheckDeviceTrustState
    let createdAtMillis: Int64
    let approvedAtMillis: Int64?
    let revokedAtMillis: Int64?

    var id: String { deviceId }

    init(
        deviceId: String,
        deviceName: String,
        platform: String = "Linux",
        safetyFingerprint: String,
        trustState: LinuxAppCheckDeviceTrustState,
        createdAtMillis: Int64,
        approvedAtMillis: Int64? = nil,
        revokedAtMillis: Int64? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.safetyFingerprint = safetyFingerprint
        self.trustState = trustState
        self.createdAtMillis = createdAtMillis
        self.approvedAtMillis = approvedAtMillis
        self.revokedAtMillis = revokedAtMillis
    }

    init(callablePayload: [String: Any]) throws {
        guard let deviceId = callablePayload["deviceId"] as? String, !deviceId.isEmpty,
              let deviceName = callablePayload["deviceName"] as? String, !deviceName.isEmpty,
              let platform = callablePayload["platform"] as? String, platform == "Linux",
              let publicKeyBase64 = callablePayload["publicKeyBase64"] as? String,
              let publicKey = Data(base64Encoded: publicKeyBase64), publicKey.count == 32,
              let claimedSafetyFingerprint = callablePayload["safetyFingerprint"] as? String,
              let rawTrustState = callablePayload["trustState"] as? String,
              let trustState = LinuxAppCheckDeviceTrustState(rawValue: rawTrustState),
              let createdAtMillis = Self.int64(callablePayload["createdAtMillis"])
        else {
            throw ComputerUseSecurityCallableClient.ClientError.invalidResponse(
                "A Linux device record was invalid."
            )
        }
        let digestHex = SHA256.hash(data: publicKey)
            .map { String(format: "%02x", $0) }
            .joined()
        let safetyFingerprint = Self.groupedFingerprint(digestHex.uppercased())
        guard deviceId == "linux_\(digestHex)",
              claimedSafetyFingerprint == safetyFingerprint
        else {
            throw ComputerUseSecurityCallableClient.ClientError.invalidResponse(
                "A Linux device safety fingerprint did not match its public key."
            )
        }
        self.init(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform,
            safetyFingerprint: safetyFingerprint,
            trustState: trustState,
            createdAtMillis: createdAtMillis,
            approvedAtMillis: Self.int64(callablePayload["approvedAtMillis"]),
            revokedAtMillis: Self.int64(callablePayload["revokedAtMillis"])
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func groupedFingerprint(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: " ")
    }
}

protocol LinuxAppCheckDeviceManaging: Sendable {
    func list(approverDeviceId: String) async throws -> [LinuxAppCheckDeviceRecord]
    func approve(deviceId: String, approverDeviceId: String) async throws
    func revoke(deviceId: String, approverDeviceId: String) async throws
}

struct LiveLinuxAppCheckDeviceManager: LinuxAppCheckDeviceManaging {
    func list(approverDeviceId: String) async throws -> [LinuxAppCheckDeviceRecord] {
        try await ComputerUseSecurityCallableClient.listLinuxAppCheckDevices(
            approverDeviceId: approverDeviceId
        )
    }

    func approve(deviceId: String, approverDeviceId: String) async throws {
        try await ComputerUseSecurityCallableClient.setLinuxAppCheckDeviceTrust(
            deviceId: deviceId,
            approverDeviceId: approverDeviceId,
            approve: true
        )
    }

    func revoke(deviceId: String, approverDeviceId: String) async throws {
        try await ComputerUseSecurityCallableClient.setLinuxAppCheckDeviceTrust(
            deviceId: deviceId,
            approverDeviceId: approverDeviceId,
            approve: false
        )
    }
}

@Observable @MainActor
final class DevicesStore {
    private let reader: CloudReader
    private let trustGateway: DeviceTrustGateway
    private let linuxAppCheckManager: any LinuxAppCheckDeviceManaging
    private var rawDevices: [DeviceRecord] = []
    private(set) var isLoading = false
    private(set) var lastError: CloudErrorClassification?
    private(set) var actionInFlightFor: String?
    private(set) var linuxAppCheckDevices: [LinuxAppCheckDeviceRecord] = []
    private(set) var isLoadingLinuxAppCheckDevices = false
    private(set) var linuxAppCheckError: String?
    private(set) var linuxAppCheckActionInFlightFor: String?
    private var linuxAppCheckLoadGeneration = 0

    init(
        reader: CloudReader = LiveCloudReader(),
        trustGateway: DeviceTrustGateway = LiveDeviceTrustGateway(),
        linuxAppCheckManager: any LinuxAppCheckDeviceManaging = LiveLinuxAppCheckDeviceManager()
    ) {
        self.reader = reader
        self.trustGateway = trustGateway
        self.linuxAppCheckManager = linuxAppCheckManager
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
            do { try await trustGateway.revoke(deviceID: device.id) } catch let CloudGatewayError.classified(c) { lastError = c } catch { lastError = .other(message: error.localizedDescription) }
        }
        actionInFlightFor = nil
        await load()
    }

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            rawDevices = try await reader.loadDevices()
            lastError = nil
            await loadLinuxAppCheckDevices()
        } catch let CloudGatewayError.classified(c) {
            lastError = c
        } catch {
            lastError = .other(message: error.localizedDescription)
        }
    }

    func loadLinuxAppCheckDevices() async {
        linuxAppCheckLoadGeneration += 1
        let generation = linuxAppCheckLoadGeneration
        guard let approverDeviceId = currentDevice?.id else {
            linuxAppCheckDevices = []
            linuxAppCheckError = "This device must finish registration before it can manage Linux devices."
            isLoadingLinuxAppCheckDevices = false
            return
        }
        isLoadingLinuxAppCheckDevices = true
        do {
            let devices = try await linuxAppCheckManager.list(
                approverDeviceId: approverDeviceId
            )
            guard generation == linuxAppCheckLoadGeneration,
                  currentDevice?.id == approverDeviceId
            else { return }
            linuxAppCheckDevices = devices.sorted(by: Self.linuxDeviceOrder)
            linuxAppCheckError = nil
        } catch {
            guard generation == linuxAppCheckLoadGeneration,
                  currentDevice?.id == approverDeviceId
            else { return }
            linuxAppCheckError = error.localizedDescription
        }
        if generation == linuxAppCheckLoadGeneration {
            isLoadingLinuxAppCheckDevices = false
        }
    }

    func approveLinuxAppCheckDevice(_ device: LinuxAppCheckDeviceRecord) async {
        await mutateLinuxAppCheckDevice(device, approve: true)
    }

    func revokeLinuxAppCheckDevice(_ device: LinuxAppCheckDeviceRecord) async {
        await mutateLinuxAppCheckDevice(device, approve: false)
    }

    private func mutateLinuxAppCheckDevice(_ device: LinuxAppCheckDeviceRecord, approve: Bool) async {
        guard linuxAppCheckActionInFlightFor == nil else {
            linuxAppCheckError = "Finish the current Linux device update before starting another."
            return
        }
        guard let approverDeviceId = currentDevice?.id else {
            linuxAppCheckError = "This device must finish registration before it can manage Linux devices."
            return
        }
        linuxAppCheckLoadGeneration += 1
        isLoadingLinuxAppCheckDevices = false
        linuxAppCheckActionInFlightFor = device.id
        defer {
            if linuxAppCheckActionInFlightFor == device.id {
                linuxAppCheckActionInFlightFor = nil
            }
        }
        do {
            if approve {
                try await linuxAppCheckManager.approve(
                    deviceId: device.id,
                    approverDeviceId: approverDeviceId
                )
            } else {
                try await linuxAppCheckManager.revoke(
                    deviceId: device.id,
                    approverDeviceId: approverDeviceId
                )
            }
            guard currentDevice?.id == approverDeviceId else { return }
            await loadLinuxAppCheckDevices()
        } catch {
            guard currentDevice?.id == approverDeviceId else { return }
            linuxAppCheckError = error.localizedDescription
        }
    }

    private static func linuxDeviceOrder(
        _ lhs: LinuxAppCheckDeviceRecord,
        _ rhs: LinuxAppCheckDeviceRecord
    ) -> Bool {
        let rank: [LinuxAppCheckDeviceTrustState: Int] = [.pending: 0, .approved: 1, .revoked: 2]
        let lhsRank = rank[lhs.trustState] ?? 3
        let rhsRank = rank[rhs.trustState] ?? 3
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.createdAtMillis > rhs.createdAtMillis
    }

    func bootstrapApproveSelf() async {
        actionInFlightFor = currentDevice?.id; defer { actionInFlightFor = nil }
        do { try await trustGateway.bootstrapApproveSelf(); await load() } catch let CloudGatewayError.classified(c) { lastError = c } catch { lastError = .other(message: error.localizedDescription) }
    }

    func renameSelf(_ newName: String) async {
        actionInFlightFor = currentDevice?.id; defer { actionInFlightFor = nil }
        do { try await trustGateway.renameSelf(newName); await load() } catch let CloudGatewayError.classified(c) { lastError = c } catch { lastError = .other(message: error.localizedDescription) }
    }

    func revoke(_ device: DeviceRecord) async {
        actionInFlightFor = device.id; defer { actionInFlightFor = nil }
        do { try await trustGateway.revoke(deviceID: device.id); await load() } catch let CloudGatewayError.classified(c) { lastError = c } catch { lastError = .other(message: error.localizedDescription) }
    }
}
