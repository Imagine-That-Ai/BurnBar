import Foundation
import Observation
import OpenBurnBarKernel
@preconcurrency import FirebaseFirestore

/// A rendered HermesBody row: one machine-bound Hermes (§2 identity law).
/// Presence is derived from heartbeat age on the read side — the publisher
/// only ever asserts "online now"; staleness is the reader's honest verdict.
struct HermesBodyRecord: Identifiable, Equatable, Sendable {
    enum PresenceState: String, Sendable {
        case online
        case offline
    }

    var id: String
    var deviceID: String
    var displayName: String
    var machineName: String
    var hardwareModel: String?
    var chipBrand: String?
    var coresPerformance: Int?
    var coresEfficiency: Int?
    var memBytes: Int64?
    var hermesInstalled: Bool
    var hermesGatewayReachable: Bool
    var botCount: Int?
    var irohNodeID: String?
    var lastHeartbeatAt: Date?
    var wireReachable: Bool
    var capabilities: [String]

    func presence(
        now: Date = Date(),
        freshness: TimeInterval = HermesBodyPublisher.presenceFreshnessSeconds
    ) -> PresenceState {
        guard let lastHeartbeatAt else { return .offline }
        return now.timeIntervalSince(lastHeartbeatAt) <= freshness ? .online : .offline
    }

    /// "Apple M4 Pro · 64 GB" with em-dashes for the unknowable — the
    /// fountains never invent hardware.
    var hardwareSummary: String {
        let chip = chipBrand ?? hardwareModel ?? "—"
        guard let memBytes, memBytes > 0 else { return chip }
        let gigabytes = Double(memBytes) / 1_073_741_824
        return "\(chip) · \(Int(gigabytes.rounded())) GB"
    }

    static func fromFirestore(id: String, data: [String: Any]) -> HermesBodyRecord? {
        guard let deviceID = data["deviceID"] as? String else { return nil }
        let hardware = data["hardware"] as? [String: Any] ?? [:]
        let hermes = data["hermes"] as? [String: Any] ?? [:]
        let endpoints = data["endpoints"] as? [String: Any] ?? [:]
        let presence = data["presence"] as? [String: Any] ?? [:]
        let machineName = data["machineName"] as? String ?? ""
        return HermesBodyRecord(
            id: id,
            deviceID: deviceID,
            displayName: (data["displayName"] as? String)?.nonEmpty
                ?? HermesBodyPublisher.defaultDisplayName(machineName: machineName),
            machineName: machineName,
            hardwareModel: hardware["hardwareModel"] as? String,
            chipBrand: hardware["chipBrand"] as? String,
            coresPerformance: (hardware["coresPerformance"] as? NSNumber)?.intValue,
            coresEfficiency: (hardware["coresEfficiency"] as? NSNumber)?.intValue,
            memBytes: (hardware["memBytes"] as? NSNumber)?.int64Value,
            hermesInstalled: hermes["installed"] as? Bool ?? false,
            hermesGatewayReachable: hermes["gatewayReachable"] as? Bool ?? false,
            botCount: (hermes["botCount"] as? NSNumber)?.intValue,
            irohNodeID: endpoints["irohNodeId"] as? String,
            lastHeartbeatAt: (presence["lastHeartbeatAt"] as? String)
                .flatMap(ThreadSafeISO8601DateFormatter.parse),
            wireReachable: presence["wireReachable"] as? Bool ?? false,
            capabilities: data["capabilities"] as? [String] ?? []
        )
    }
}

/// Live directory of the account's HermesBodies — the single data source for
/// the computer-swap control, Devices & Sync, and Face B headers. The swap
/// control reads exactly this and nothing else (§2.4: machines, never bots).
@MainActor
@Observable
final class HermesBodyDirectory {
    private(set) var bodies: [HermesBodyRecord] = []
    private(set) var hasLoaded = false

    private let accountManager: AccountManaging
    @ObservationIgnored private var listener: ListenerRegistration?
    @ObservationIgnored private var listenerUID: String?

    init(accountManager: AccountManaging) {
        self.accountManager = accountManager
    }

    /// The body owned by this Mac, matched on device identity.
    var localBody: HermesBodyRecord? {
        bodies.first { $0.deviceID == accountManager.deviceId }
    }

    func isLocal(_ record: HermesBodyRecord) -> Bool {
        record.deviceID == accountManager.deviceId
    }

    /// The roster in the Kernel's fleet vocabulary, so the Hermes Room, the
    /// Flame, and the Wire all reason about the same shape. `activeRunCount` is
    /// zero here: the directory publishes machines, not workloads, and a made-up
    /// load figure would silently steer routing.
    func fleetSnapshot(now: Date = Date()) -> FleetSnapshot {
        FleetSnapshot(
            bodies: bodies.map { record in
                FleetBodySnapshot(
                    bodyID: record.id,
                    displayName: record.displayName,
                    isLocal: isLocal(record),
                    isOnline: record.presence(now: now) == .online,
                    hermesGatewayReachable: record.hermesGatewayReachable,
                    wireReachable: record.wireReachable,
                    capabilities: Set(record.capabilities),
                    activeRunCount: 0
                )
            }
        )
    }

    func start() {
        guard accountManager.isFirebaseAvailable,
              let uid = accountManager.currentUID else {
            stop()
            return
        }
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        listener = WarRoomFirestoreGateway.bodies(uid: uid)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor [weak self] in
                    guard let self, self.listenerUID == uid else { return }
                    if let error {
                        AppLogger.network.silentFailure("hermes_body_directory_listen_failed", error: error)
                        return
                    }
                    let records = (snapshot?.documents ?? []).compactMap { document in
                        HermesBodyRecord.fromFirestore(id: document.documentID, data: document.data())
                    }
                    let sortedRecords = records.sorted { lhs, rhs in
                        // Local body first, then stable name order.
                        let lhsLocal = self.isLocal(lhs)
                        let rhsLocal = self.isLocal(rhs)
                        if lhsLocal != rhsLocal { return lhsLocal }
                        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                    }
                    if self.bodies != sortedRecords {
                        self.bodies = sortedRecords
                    }
                    if !self.hasLoaded {
                        self.hasLoaded = true
                    }
                }
            }
    }

    func stop() {
        listener?.remove()
        listener = nil
        listenerUID = nil
        if !bodies.isEmpty {
            bodies.removeAll()
        }
        hasLoaded = false
    }

    func rename(bodyID: String, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120,
              accountManager.isFirebaseAvailable,
              let uid = accountManager.currentUID else { return }
        let now = ThreadSafeISO8601DateFormatter.formatBasic(Date())
        do {
            try await WarRoomFirestoreGateway.body(uid: uid, bodyID: bodyID)
                .setData(["displayName": trimmed, "updatedAt": now], merge: true)
        } catch {
            AppLogger.network.silentFailure("hermes_body_rename_failed", error: error)
        }
    }

    /// Remove a body record (a decommissioned machine). The owning Mac
    /// republishes its own record on its next heartbeat, so removing the
    /// local body is self-healing rather than destructive.
    func remove(bodyID: String) async {
        guard accountManager.isFirebaseAvailable,
              let uid = accountManager.currentUID else { return }
        do {
            try await WarRoomFirestoreGateway.body(uid: uid, bodyID: bodyID)
                .delete()
        } catch {
            AppLogger.network.silentFailure("hermes_body_remove_failed", error: error)
        }
    }
}
