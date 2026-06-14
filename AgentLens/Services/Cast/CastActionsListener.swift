import Foundation
@preconcurrency import FirebaseFirestore

// MARK: - Cast Action Ack Writer

/// Abstracts the Firestore writeback the Mac uses to tell the mobile
/// cast wizard how a request resolved. Pulling the write behind a
/// protocol keyed on the document *path* (rather than a live
/// `DocumentReference`) lets the fail-closed/observable behaviour of
/// `CastActionsListener` be exercised hermetically in tests, mirroring
/// the `CloudSyncFirestoreGateway` seam used elsewhere.
///
/// `@MainActor`-isolated so the `[String: Any]` payload never crosses an
/// actor boundary (the listener is already `@MainActor`); this keeps the
/// seam clean under `SWIFT_STRICT_CONCURRENCY: complete` without resorting
/// to `@preconcurrency` suppression.
@MainActor
protocol CastActionAckWriter {
    /// Merge-writes `payload` to the Firestore document at `path`.
    /// Throws on transport/permission failure so the caller can decide
    /// whether the loss is recoverable (log + skip) or correctness-bearing
    /// (fail closed: do not advance the wizard).
    func write(_ payload: [String: Any], toPath path: String, merge: Bool) async throws
}

/// Production writer that resolves the path against the live Firestore
/// instance and performs the merge write.
@MainActor
struct FirestoreCastActionAckWriter: CastActionAckWriter {
    func write(_ payload: [String: Any], toPath path: String, merge: Bool) async throws {
        try await Firestore.firestore().document(path).setData(payload, merge: merge)
    }
}

/// The pieces of a `cast_actions` document the writeback logic needs:
/// the document id (for re-discovery dedupe + telemetry) and its full
/// Firestore path (for the ack write). Decoupling the writeback handlers
/// from `QueryDocumentSnapshot` keeps the fail-closed paths unit-testable
/// without a live Firestore.
struct CastActionRef: Sendable {
    let documentID: String
    let path: String

    init(documentID: String, path: String) {
        self.documentID = documentID
        self.path = path
    }

    @MainActor
    init(snapshot: QueryDocumentSnapshot) {
        self.documentID = snapshot.documentID
        self.path = snapshot.reference.path
    }
}

// MARK: - Cast Actions Listener
//
// Mac-side Firestore listener. Watches `users/{uid}/cast_actions` for
// any pending request published by an iPhone/iPad. When one shows up
// we route it through `CastChannelClient` and write back the outcome
// so the mobile wizard can advance.
//
// Document shape (`type`):
//   - "test"           — discover devices and reply with the list
//   - "save_selection" — persist a deviceId as the primary device
//   - "cast"           — trigger Cast Now with the saved selection
//   - "stop"           — STOP the current cast session
//
// Writeback contract: every terminal write (completed / failed) is the
// *only* progress signal the mobile wizard polls. A silently-dropped
// writeback strands the action at `status=pending` and hangs the wizard
// forever, so each writeback is observable (logged on failure) and the
// `test` flow fails closed — it refuses to mark the action `completed`
// when the discovery result it advertises never reached Firestore.

@MainActor
final class CastActionsListener {

    private let accountManager: AccountManaging
    private let settingsManager: SettingsManager
    private let repairCoordinator: SmartDisplayRepairCoordinator?
    private let ackWriter: CastActionAckWriter
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var attachTask: Task<Void, Never>?
    private var processingDocs = Set<String>()

    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager,
        repairCoordinator: SmartDisplayRepairCoordinator? = nil,
        ackWriter: CastActionAckWriter = FirestoreCastActionAckWriter()
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.repairCoordinator = repairCoordinator
        self.ackWriter = ackWriter
    }

    func start() {
        if attachTask == nil {
            attachTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.attachIfPossible()
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // try?-ok(sleep cancellation only)
                }
            }
        }
        attachIfPossible()
    }

    private func attachIfPossible() {
        guard accountManager.isFirebaseAvailable, let uid = accountManager.currentUID else {
            listener?.remove()
            listener = nil
            listenerUID = nil
            return
        }
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        let db = Firestore.firestore()
        listener = db.collection("users").document(uid)
            .collection("cast_actions")
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snapshot, error in
                guard error == nil, let docs = snapshot?.documents, !docs.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.processDocs(docs, uid: uid)
                }
            }
    }

    func stop() {
        attachTask?.cancel()
        attachTask = nil
        listener?.remove()
        listener = nil
        listenerUID = nil
        processingDocs.removeAll()
    }

    // MARK: - Internal

    private func processDocs(_ docs: [QueryDocumentSnapshot], uid: String) {
        for doc in docs where !processingDocs.contains(doc.documentID) {
            processingDocs.insert(doc.documentID)
            Task { @MainActor in
                defer { processingDocs.remove(doc.documentID) }
                await handle(document: doc, uid: uid)
            }
        }
    }

    private func handle(document: QueryDocumentSnapshot, uid: String) async {
        let ref = CastActionRef(snapshot: document)
        let data = document.data()
        guard let type = data["type"] as? String else {
            await fail(ref, message: "missing type")
            return
        }
        switch type {
        case "test":
            await handleTest(ref, uid: uid)
        case "save_selection":
            await handleSaveSelection(ref, data: data)
        case "cast":
            await handleCast(ref, data: data)
        case "stop":
            await handleStop(ref)
        default:
            await fail(ref, message: "unknown type: \(type)")
        }
    }

    /// Writes a terminal/intermediate ack back to a `cast_actions` doc.
    /// Returns `true` on success. A failure is logged (never silently
    /// swallowed) and surfaced to the caller so correctness-bearing flows
    /// can fail closed instead of advancing the wizard on a lost write.
    @discardableResult
    private func writeAck(
        to ref: CastActionRef,
        _ payload: [String: Any],
        event: String
    ) async -> Bool {
        do {
            try await ackWriter.write(payload, toPath: ref.path, merge: true)
            return true
        } catch {
            AppLogger.sync.error(event, metadata: [
                "actionId": ref.documentID,
                "errorClass": "\(String(describing: type(of: error)))"
            ])
            return false
        }
    }

    private func handleTest(_ ref: CastActionRef, uid: String) async {
        let devices = await collectDevicesOnce(duration: 12)
        if let selected = devices.first(where: { matchesSelectedDevice($0) }) {
            persistCastDevice(selected)
        }
        await publishDiscoveryAndComplete(ref, uid: uid, devices: devices)
    }

    /// Publishes the discovered device list to
    /// `cast_discovery_results/latest`, then marks the action `completed`.
    ///
    /// Fail-closed contract: the discovery result drives the wizard's
    /// device picker, so if that write is lost the wizard would render an
    /// empty/stale list. We therefore must NOT advance the action to
    /// `completed` on a lost result — instead we report the action as
    /// `failed` so the wizard surfaces the error rather than silently
    /// showing nothing. Extracted (device list passed in) so the gating
    /// is exercised hermetically without an mDNS scan.
    func publishDiscoveryAndComplete(_ ref: CastActionRef, uid: String, devices: [CastDevice]) async {
        let payload = devices.map { d in
            [
                "serviceName": d.serviceName,
                "friendlyName": d.friendlyName,
                "model": d.model,
                "host": d.host,
                "port": d.port,
                "identifier": d.identifier,
                "iconKind": d.iconKind.rawValue,
                "supportsDisplay": d.supportsDisplay
            ] as [String: Any]
        }

        let resultsPath = "users/\(uid)/cast_discovery_results/latest"
        do {
            try await ackWriter.write([
                "actionId": ref.documentID,
                "devices": payload,
                "publishedAt": ISO8601DateFormatter().string(from: Date())
            ], toPath: resultsPath, merge: true)
        } catch {
            AppLogger.sync.error("cast discovery results write failed", metadata: [
                "actionId": ref.documentID,
                "errorClass": "\(String(describing: type(of: error)))"
            ])
            await fail(ref, message: "discovery results could not be published")
            return
        }

        await writeAck(to: ref, [
            "status": "completed",
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ], event: "cast test completion write failed")
    }

    /// Persists the selection locally (lines below) then acks the wizard.
    /// Local state is already durable before the ack, so a lost ack is
    /// observable (logged) rather than fail-closed — but it must never be
    /// silent, else the wizard hangs even though the save succeeded.
    /// Internal so the ack-on-failure path is testable.
    func handleSaveSelection(_ ref: CastActionRef, data: [String: Any]) async {
        guard let serviceName = data["deviceId"] as? String,
              let friendlyName = data["friendlyName"] as? String else {
            await fail(ref, message: "missing deviceId/friendlyName")
            return
        }
        settingsManager.castSelectedDeviceServiceName = serviceName
        settingsManager.castSelectedDeviceFriendlyName = friendlyName
        if let model = data["model"] as? String {
            settingsManager.castSelectedDeviceModel = model
        }
        if let host = data["host"] as? String {
            settingsManager.castSelectedDeviceHost = host
        }
        if let port = data["port"] as? Int, port > 0 {
            settingsManager.castSelectedDevicePort = port
        }
        if let identifier = data["identifier"] as? String {
            settingsManager.castSelectedDeviceIdentifier = identifier
        }
        if let supportsDisplay = data["supportsDisplay"] as? Bool {
            settingsManager.castSelectedDeviceSupportsDisplay = supportsDisplay
        }
        settingsManager.smartHubQuotaDisplayEnabled = true
        await writeAck(to: ref, [
            "status": "completed",
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ], event: "cast save_selection ack failed")
    }

    private func handleCast(_ ref: CastActionRef, data: [String: Any]) async {
        if let repairCoordinator {
            let status = await repairCoordinator.repairNestHub()
            if status.isHealthy {
                await writeAck(to: ref, [
                    "status": "completed",
                    "message": status.message,
                    "proof": status.proof ?? "",
                    "completedAt": ISO8601DateFormatter().string(from: Date())
                ], event: "cast repair completion write failed")
            } else {
                await writeAck(to: ref, [
                    "status": "failed",
                    "errorMessage": status.message,
                    "proof": status.proof ?? "",
                    "completedAt": ISO8601DateFormatter().string(from: Date())
                ], event: "cast repair failure write failed")
            }
            return
        }

        guard let url = Self.castableDashboardURL(from: settingsManager.smartHubQuotaDashboardURL) else {
            await fail(ref, message: "no dashboard URL configured")
            return
        }
        // Re-discover the device by serviceName so we have a current IP.
        let serviceName = (data["deviceId"] as? String)
            ?? settingsManager.castSelectedDeviceServiceName
        guard let device = await locateDevice(serviceName: serviceName) else {
            await fail(ref, message: "device not on network; mDNS scan and cached endpoint both failed")
            return
        }
        persistCastDevice(device)
        let strategy = CastReconnectStrategy(
            device: device,
            homeAssistantWebhookURL: homeAssistantRecoveryWebhookURL()
        )
        let result = await strategy.castWithRecovery(url: url)
        switch result {
        case .success(let sessionId):
            await writeAck(to: ref, [
                "status": "completed",
                "sessionId": sessionId,
                "completedAt": ISO8601DateFormatter().string(from: Date())
            ], event: "cast session writeback failed")
        case .recoveredViaHomeAssistant(let message):
            await writeAck(to: ref, [
                "status": "completed",
                "recovery": "home_assistant",
                "message": message,
                "completedAt": ISO8601DateFormatter().string(from: Date())
            ], event: "cast home-assistant recovery writeback failed")
        case .failure(let reason, let attempts):
            await writeAck(to: ref, [
                "status": "failed",
                "errorMessage": reason,
                "attempts": attempts,
                "completedAt": ISO8601DateFormatter().string(from: Date())
            ], event: "cast failure writeback failed")
        }
    }

    private func homeAssistantRecoveryWebhookURL() -> URL? {
        let raw = settingsManager.smartHubHomeAssistantRecoveryWebhookURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func handleStop(_ ref: CastActionRef) async {
        let serviceName = settingsManager.castSelectedDeviceServiceName
        guard let device = await locateDevice(serviceName: serviceName) else {
            await fail(ref, message: "device not on network; mDNS scan and cached endpoint both failed")
            return
        }
        persistCastDevice(device)
        let client = CastChannelClient(device: device)
        await client.stop()
        await writeAck(to: ref, [
            "status": "completed",
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ], event: "cast stop ack failed")
    }

    /// Central failure writeback used by every error path (missing type,
    /// unknown type, device not on network, no dashboard URL, lost
    /// discovery result). This is the *only* signal the wizard polls to
    /// surface an error, so a lost write here hangs the wizard on a
    /// `pending` action forever — `writeAck` therefore logs the loss
    /// rather than swallowing it. Internal so the contract is testable.
    func fail(_ ref: CastActionRef, message: String) async {
        await writeAck(to: ref, [
            "status": "failed",
            "errorMessage": message,
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ], event: "cast fail() writeback failed")
    }

    /// mDNS scan, returning whatever devices were resolved.
    private func collectDevicesOnce(duration: TimeInterval) async -> [CastDevice] {
        await CastDiscovery.discoverOnce(duration: duration)
    }

    private func locateDevice(serviceName: String) async -> CastDevice? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let scanner = CastDiscovery(onUpdate: { devices in
                if let match = devices.first(where: { $0.serviceName.caseInsensitiveCompare(serviceName) == .orderedSame }), !resumed {
                    resumed = true
                    continuation.resume(returning: match)
                }
            })
            scanner.start()
            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000) // try?-ok(sleep cancellation only)
                scanner.stop()
                if !resumed {
                    resumed = true
                    continuation.resume(returning: cachedSelectedDevice(matching: serviceName))
                }
            }
        }
    }

    private func matchesSelectedDevice(_ device: CastDevice) -> Bool {
        device.serviceName.caseInsensitiveCompare(settingsManager.castSelectedDeviceServiceName) == .orderedSame
            || (!settingsManager.castSelectedDeviceIdentifier.isEmpty
                && device.identifier.caseInsensitiveCompare(settingsManager.castSelectedDeviceIdentifier) == .orderedSame)
    }

    private func cachedSelectedDevice(matching serviceName: String) -> CastDevice? {
        let cachedServiceName = settingsManager.castSelectedDeviceServiceName
        guard !cachedServiceName.isEmpty,
              cachedServiceName.caseInsensitiveCompare(serviceName) == .orderedSame else {
            return nil
        }
        let host = settingsManager.castSelectedDeviceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        return CastDevice(
            serviceName: cachedServiceName,
            friendlyName: settingsManager.castSelectedDeviceFriendlyName.isEmpty
                ? cachedServiceName
                : settingsManager.castSelectedDeviceFriendlyName,
            host: host,
            port: settingsManager.castSelectedDevicePort > 0 ? settingsManager.castSelectedDevicePort : 8009,
            model: settingsManager.castSelectedDeviceModel.isEmpty
                ? "Cast Device"
                : settingsManager.castSelectedDeviceModel,
            identifier: settingsManager.castSelectedDeviceIdentifier.isEmpty
                ? cachedServiceName
                : settingsManager.castSelectedDeviceIdentifier,
            supportsDisplay: settingsManager.castSelectedDeviceSupportsDisplay
        )
    }

    private func persistCastDevice(_ device: CastDevice) {
        settingsManager.castSelectedDeviceServiceName = device.serviceName
        settingsManager.castSelectedDeviceFriendlyName = device.friendlyName
        settingsManager.castSelectedDeviceModel = device.model
        settingsManager.castSelectedDeviceHost = device.host
        settingsManager.castSelectedDevicePort = device.port
        settingsManager.castSelectedDeviceIdentifier = device.identifier
        settingsManager.castSelectedDeviceSupportsDisplay = device.supportsDisplay
    }

    /// Rewrites a configured dashboard URL into one a Cast device can
    /// actually load. The stored default is `http://127.0.0.1:8787/render.html`,
    /// which resolves to the Nest Hub's *own* loopback — so DashCast
    /// renders an error / cached surface instead of OpenBurnBar. We swap
    /// loopback (and empty hosts) for the Mac's preferred LAN IPv4 so the
    /// Hub fetches from this machine over Wi-Fi.
    ///
    /// We also rewrite the host when it is a *stale* LAN IPv4 — i.e. it
    /// doesn't match any of the Mac's current local IPs. This is the
    /// "DashCast stuck on splash" failure mode in the wild: the user
    /// configured `http://192.168.68.87:8787/...` when the Mac was on
    /// `.87`, the router handed out a new lease, the Mac is now `.93`,
    /// and the Nest Hub spends forever trying to fetch a host that no
    /// longer exists. The page never loads → DashCast splash.
    static func castableDashboardURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        let host = url.host?.lowercased() ?? ""
        let loopback = host.isEmpty
            || host == "localhost"
            || host == "127.0.0.1"
            || host == "0.0.0.0"
            || host == "::1"

        let localIPs = Set(LocalNetworkDiscovery.localIPv4Addresses())
        let looksLikeIPv4 = host.split(separator: ".").count == 4
            && host.allSatisfy { $0.isNumber || $0 == "." }
        let isStaleLANIP = looksLikeIPv4 && !localIPs.isEmpty && !localIPs.contains(host)

        guard loopback || isStaleLANIP else { return url }
        guard let lan = LocalNetworkDiscovery.preferredLANIPv4Address() else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = lan
        return components?.url
    }
}
