import CryptoKit
import Foundation
import OpenBurnBarCore

enum LinuxAppCheckDeviceTrustState: String, Codable, Sendable, Equatable {
    case pending
    case approved
    case revoked
}

struct LinuxAppCheckDeviceRecord: Identifiable, Decodable, Sendable, Equatable {
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deviceId = try container.decode(String.self, forKey: .deviceId)
        let deviceName = try container.decode(String.self, forKey: .deviceName)
        let platform = try container.decode(String.self, forKey: .platform)
        let publicKeyBase64 = try container.decode(String.self, forKey: .publicKeyBase64)
        let claimedSafetyFingerprint = try container.decode(String.self, forKey: .safetyFingerprint)
        let trustState = try container.decode(LinuxAppCheckDeviceTrustState.self, forKey: .trustState)
        let createdAtMillis = try container.decode(Int64.self, forKey: .createdAtMillis)
        let approvedAtMillis = try container.decodeIfPresent(Int64.self, forKey: .approvedAtMillis)
        let revokedAtMillis = try container.decodeIfPresent(Int64.self, forKey: .revokedAtMillis)
        guard !deviceId.isEmpty,
              !deviceName.isEmpty,
              platform == "Linux",
              let publicKey = Data(base64Encoded: publicKeyBase64),
              publicKey.count == 32 else {
            throw DecodingError.dataCorruptedError(
                forKey: .deviceId,
                in: container,
                debugDescription: "A Linux App Check device record was invalid."
            )
        }
        let digestHex = SHA256.hash(data: publicKey)
            .map { String(format: "%02x", $0) }
            .joined()
        let safetyFingerprint = Self.groupedFingerprint(digestHex.uppercased())
        guard deviceId == "linux_\(digestHex)",
              claimedSafetyFingerprint == safetyFingerprint
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .safetyFingerprint,
                in: container,
                debugDescription: "A Linux device safety fingerprint did not match its public key."
            )
        }
        self.init(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform,
            safetyFingerprint: safetyFingerprint,
            trustState: trustState,
            createdAtMillis: createdAtMillis,
            approvedAtMillis: approvedAtMillis,
            revokedAtMillis: revokedAtMillis
        )
    }

    private enum CodingKeys: String, CodingKey {
        case deviceId
        case deviceName
        case platform
        case publicKeyBase64
        case safetyFingerprint
        case trustState
        case createdAtMillis
        case approvedAtMillis
        case revokedAtMillis
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
        linuxAppCheckManager: any LinuxAppCheckDeviceManaging = LiveLinuxAppCheckDeviceManager(),
        scopedCaches: MobileUIDScopedCacheRegistry = .shared
    ) {
        self.reader = reader
        self.trustGateway = trustGateway
        self.linuxAppCheckManager = linuxAppCheckManager
        scopedCaches.register { [weak self] in self?.clearCache() }
    }

    func clearCache() {
        rawDevices = []
        linuxAppCheckDevices = []
        lastError = nil
        linuxAppCheckError = nil
        actionInFlightFor = nil
        linuxAppCheckActionInFlightFor = nil
        linuxAppCheckLoadGeneration += 1
    }

    /// Display-ready registrations keyed only by their durable Firestore device identity.
    /// Friendly names and platforms are intentionally not identity: a user can own multiple
    /// iPhones, iPads, or Android devices with the same model/name.
    var devices: [DeviceRecord] {
        Self.uniqueRegistrations(rawDevices)
    }

    var currentDevice: DeviceRecord? {
        devices.first(where: \.isCurrentDevice)
    }

    var otherDevices: [DeviceRecord] {
        devices.filter { !$0.isCurrentDevice }
    }

    var thisDeviceTrustState: DeviceTrustState { currentDevice?.trustState ?? .pending }
    var bootstrapEligible: Bool {
        let hasTrusted = rawDevices.contains { $0.trustState == .trusted && !$0.isCurrentDevice }
        return !hasTrusted && thisDeviceTrustState != .trusted
    }

    // MARK: - Stable identity

    private static func uniqueRegistrations(_ records: [DeviceRecord]) -> [DeviceRecord] {
        let groups = Dictionary(grouping: records, by: \.id)
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

    func approve(_ device: DeviceRecord) async {
        guard !device.isCurrentDevice, device.trustState == .pending else {
            lastError = .other(message: "Only a different pending device can be approved.")
            return
        }
        guard device.hasVerifiedSafetyCode else {
            lastError = .other(
                message: "This device has not published a verified safety code yet."
            )
            return
        }
        actionInFlightFor = device.id
        defer { actionInFlightFor = nil }
        do {
            try await trustGateway.approve(deviceID: device.id)
            await load()
        } catch let CloudGatewayError.classified(classification) {
            lastError = classification
        } catch {
            lastError = .other(message: error.localizedDescription)
        }
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
