import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarKernel

/// Publishes this Mac's HermesBody — the joined machine-identity record the
/// War Room navigates by (`users/{uid}/hermes_bodies/{bodyId}`).
///
/// A "Hermes" in BurnBar is a name bound to a MACHINE (§2 of
/// `plans/2026-08-17-war-room-master-plan.md`). The body is the join of the
/// device doc, the Hermes relay connection, the iroh endpoint, and the
/// hardware — keyed by the existing `relay-host-<installationUUID>` connection
/// id so no new identity is minted. Written only by the owning Mac.
@MainActor
final class HermesBodyPublisher {
    struct HermesState: Sendable, Equatable {
        var installed: Bool
        var gatewayReachable: Bool
        var version: String?

        /// Live probe over the launcher's dependency surface: a gateway that
        /// answers at all (200, or 401/403 when a key is required) proves both
        /// install and reachability. Only when nothing answers do we pay for
        /// executable resolution, and then only to settle the install verdict.
        static func probeLive(
            baseURL: URL,
            bearerToken: String?,
            dependencies: HermesRuntimeLauncherDependencies = .live
        ) async -> HermesState {
            let probe = await dependencies.probeGateway(baseURL, bearerToken)
            if probe.available || probe.authRejected {
                return HermesState(installed: true, gatewayReachable: true, version: nil)
            }
            let executable = await dependencies.resolveHermesExecutable()
            return HermesState(installed: executable != nil, gatewayReachable: false, version: nil)
        }
    }

    struct PayloadInput: Sendable {
        var bodyID: String
        var deviceID: String
        var machineName: String
        var hardware: MacHardwareInventory
        var hermes: HermesState
        var irohNodeID: String?
        var now: String
    }

    nonisolated static let activeInterval: TimeInterval = 60
    nonisolated static let backgroundInterval: TimeInterval = 300
    /// Readers derive presence from heartbeat age: 3× the active cadence.
    /// `nonisolated` so `HermesBodyRecord` (a plain value type) can use it as a
    /// default argument without hopping to the main actor.
    nonisolated static let presenceFreshnessSeconds: TimeInterval = 180

    private static let cadenceID = "hermes-body-heartbeat"
    private static let fallbackGatewayURL = "http://127.0.0.1:8642"

    private let accountManager: AccountManaging
    private let settingsManager: SettingsManager
    private let bodyIDProvider: @MainActor () -> String
    private let hermesStateProvider: (@MainActor () async -> HermesState)?
    private let irohNodeIDProvider: @MainActor () -> String?
    private var started = false
    /// Set once the body doc is known to exist, so the steady-state heartbeat
    /// costs one write instead of a read plus a write. Any write failure clears
    /// it, which is also how a deleted body re-acquires its creation defaults.
    private var knownCreated = false

    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager = .shared,
        bodyIDProvider: @escaping @MainActor () -> String,
        hermesStateProvider: (@MainActor () async -> HermesState)? = nil,
        irohNodeIDProvider: @escaping @MainActor () -> String? = { nil }
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.bodyIDProvider = bodyIDProvider
        self.hermesStateProvider = hermesStateProvider
        self.irohNodeIDProvider = irohNodeIDProvider
    }

    func start() {
        guard !started else { return }
        started = true
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: Self.cadenceID,
                activeInterval: Self.activeInterval,
                backgroundInterval: Self.backgroundInterval,
                sleepInterval: nil,
                isEnabled: { [weak self] in
                    self?.accountManager.isCloudSyncEnabled ?? false
                },
                fireImmediately: true,
                cancellableInFlight: false,
                work: { [weak self] in
                    await self?.publishHeartbeat()
                }
            )
        )
    }

    func stop() {
        guard started else { return }
        started = false
        BackgroundCadenceCoordinator.shared.unregister(id: Self.cadenceID)
    }

    func publishHeartbeat() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              let uid = accountManager.currentUID else { return }
        let bodyID = bodyIDProvider()
        guard !bodyID.isEmpty else { return }
        let input = PayloadInput(
            bodyID: bodyID,
            deviceID: accountManager.deviceId,
            machineName: Host.current().localizedName ?? "OpenBurnBar Mac",
            hardware: MacHardwareInventory.probe(),
            hermes: await currentHermesState(),
            irohNodeID: irohNodeIDProvider(),
            now: ThreadSafeISO8601DateFormatter.formatBasic(Date())
        )
        let ref = WarRoomFirestoreGateway.body(uid: uid, bodyID: bodyID)
        do {
            if !knownCreated {
                let snapshot = try await ref.getDocument()
                knownCreated = snapshot.exists
            }
            try await ref.setData(Self.payload(input, includeCreationDefaults: !knownCreated), merge: true)
            knownCreated = true
        } catch {
            knownCreated = false
            AppLogger.network.silentFailure("hermes_body_publish_failed", error: error)
        }
    }

    private func currentHermesState() async -> HermesState {
        if let hermesStateProvider { return await hermesStateProvider() }
        let rawURL = settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        // No parseable address means no probe, and no probe means the body
        // reports its gateway as unreachable rather than inventing a result.
        guard let baseURL = URL(string: rawURL) ?? URL(string: Self.fallbackGatewayURL) else {
            return HermesState(installed: false, gatewayReachable: false, version: nil)
        }
        return await HermesState.probeLive(
            baseURL: baseURL,
            bearerToken: token.isEmpty ? nil : token
        )
    }

    /// Pure payload builder (unit-tested against the firestore.rules key
    /// allowlist). `displayName` is only written on create so a user rename
    /// from Devices & Sync is never clobbered by the heartbeat.
    nonisolated static func payload(_ input: PayloadInput, includeCreationDefaults: Bool) -> [String: Any] {
        var hardware: [String: Any] = [:]
        if let model = input.hardware.hardwareModel { hardware["hardwareModel"] = model }
        if let chip = input.hardware.chipBrand { hardware["chipBrand"] = chip }
        if let perf = input.hardware.coresPerformance { hardware["coresPerformance"] = perf }
        if let eff = input.hardware.coresEfficiency { hardware["coresEfficiency"] = eff }
        if let mem = input.hardware.memBytes { hardware["memBytes"] = mem }

        var hermes: [String: Any] = [
            "installed": input.hermes.installed,
            "gatewayReachable": input.hermes.gatewayReachable
        ]
        if let version = input.hermes.version { hermes["version"] = version }

        var endpoints: [String: Any] = [
            "pairingConnectionId": input.bodyID
        ]
        if let nodeID = input.irohNodeID { endpoints["irohNodeId"] = nodeID }

        var capabilities = ["fleet_probe"]
        if input.hermes.gatewayReachable {
            capabilities.append("hermes_chat")
        }
        if input.irohNodeID != nil {
            capabilities.append(WarWireFrameCodec.capability)
        }

        var data: [String: Any] = [
            "id": input.bodyID,
            "deviceID": input.deviceID,
            "machineName": input.machineName,
            "platform": "macos",
            "hardware": hardware,
            "hermes": hermes,
            "endpoints": endpoints,
            "presence": [
                "state": "online",
                "lastHeartbeatAt": input.now,
                "wireReachable": input.irohNodeID != nil
            ],
            "capabilities": capabilities,
            "schemaVersion": 1,
            "updatedAt": input.now
        ]
        if includeCreationDefaults {
            data["displayName"] = defaultDisplayName(machineName: input.machineName)
            data["createdAt"] = input.now
        }
        return data
    }

    nonisolated static func defaultDisplayName(machineName: String) -> String {
        let trimmed = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Mac Hermes" }
        return "\(trimmed) Hermes"
    }
}
