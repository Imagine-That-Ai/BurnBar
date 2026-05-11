import Foundation
@preconcurrency import FirebaseFirestore

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

@MainActor
final class CastActionsListener {

    private let accountManager: AccountManaging
    private let settingsManager: SettingsManager
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var attachTask: Task<Void, Never>?
    private var processingDocs = Set<String>()

    init(accountManager: AccountManaging, settingsManager: SettingsManager) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
    }

    func start() {
        if attachTask == nil {
            attachTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.attachIfPossible()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
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
        let data = document.data()
        guard let type = data["type"] as? String else {
            await fail(document: document, message: "missing type")
            return
        }
        switch type {
        case "test":
            await handleTest(document: document, uid: uid)
        case "save_selection":
            await handleSaveSelection(document: document, data: data)
        case "cast":
            await handleCast(document: document, data: data)
        case "stop":
            await handleStop(document: document)
        default:
            await fail(document: document, message: "unknown type: \(type)")
        }
    }

    private func handleTest(document: QueryDocumentSnapshot, uid: String) async {
        let devices = await collectDevicesOnce(duration: 12)
        if let selected = devices.first(where: { matchesSelectedDevice($0) }) {
            persistCastDevice(selected)
        }
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

        let db = Firestore.firestore()
        let resultsRef = db.collection("users").document(uid).collection("cast_discovery_results").document("latest")
        try? await resultsRef.setData([
            "devices": payload,
            "publishedAt": ISO8601DateFormatter().string(from: Date())
        ], merge: true)

        try? await document.reference.setData([
            "status": "completed",
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ], merge: true)
    }

    private func handleSaveSelection(document: QueryDocumentSnapshot, data: [String: Any]) async {
        guard let serviceName = data["deviceId"] as? String,
              let friendlyName = data["friendlyName"] as? String else {
            await fail(document: document, message: "missing deviceId/friendlyName")
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
        try? await document.reference.setData([
            "status": "completed",
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ], merge: true)
    }

    private func handleCast(document: QueryDocumentSnapshot, data: [String: Any]) async {
        guard let url = Self.castableDashboardURL(from: settingsManager.smartHubQuotaDashboardURL) else {
            await fail(document: document, message: "no dashboard URL configured")
            return
        }
        // Re-discover the device by serviceName so we have a current IP.
        let serviceName = (data["deviceId"] as? String)
            ?? settingsManager.castSelectedDeviceServiceName
        guard let device = await locateDevice(serviceName: serviceName) else {
            await fail(document: document, message: "device not on network; mDNS scan and cached endpoint both failed")
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
            try? await document.reference.setData([
                "status": "completed",
                "sessionId": sessionId,
                "completedAt": ISO8601DateFormatter().string(from: Date())
            ], merge: true)
        case .recoveredViaHomeAssistant(let message):
            try? await document.reference.setData([
                "status": "completed",
                "recovery": "home_assistant",
                "message": message,
                "completedAt": ISO8601DateFormatter().string(from: Date())
            ], merge: true)
        case .failure(let reason, let attempts):
            try? await document.reference.setData([
                "status": "failed",
                "errorMessage": reason,
                "attempts": attempts,
                "completedAt": ISO8601DateFormatter().string(from: Date())
            ], merge: true)
        }
    }

    private func homeAssistantRecoveryWebhookURL() -> URL? {
        let raw = settingsManager.smartHubHomeAssistantRecoveryWebhookURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func handleStop(document: QueryDocumentSnapshot) async {
        let serviceName = settingsManager.castSelectedDeviceServiceName
        guard let device = await locateDevice(serviceName: serviceName) else {
            await fail(document: document, message: "device not on network; mDNS scan and cached endpoint both failed")
            return
        }
        persistCastDevice(device)
        let client = CastChannelClient(device: device)
        await client.stop()
        try? await document.reference.setData([
            "status": "completed",
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ], merge: true)
    }

    private func fail(document: QueryDocumentSnapshot, message: String) async {
        try? await document.reference.setData([
            "status": "failed",
            "errorMessage": message,
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ], merge: true)
    }

    /// mDNS scan, returning whatever devices were resolved.
    private func collectDevicesOnce(duration: TimeInterval) async -> [CastDevice] {
        await withCheckedContinuation { continuation in
            var collected: [CastDevice] = []
            let scanner = CastDiscovery(onUpdate: { devices in
                collected = devices
            })
            scanner.start()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                scanner.stop()
                continuation.resume(returning: collected)
            }
        }
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
                try? await Task.sleep(nanoseconds: 12_000_000_000)
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
    static func castableDashboardURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        let host = url.host?.lowercased() ?? ""
        let needsRewrite = host.isEmpty
            || host == "localhost"
            || host == "127.0.0.1"
            || host == "0.0.0.0"
            || host == "::1"
        guard needsRewrite else { return url }
        guard let lan = LocalNetworkDiscovery.preferredLANIPv4Address() else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = lan
        return components?.url
    }
}
