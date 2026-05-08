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
    private var processingDocs = Set<String>()

    init(accountManager: AccountManaging, settingsManager: SettingsManager) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
    }

    func start() {
        guard accountManager.isFirebaseAvailable, let uid = accountManager.currentUID else { return }
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
        let scanner = CastDiscovery(onUpdate: { _ in })
        scanner.start()
        // Let it scan for 6 seconds, then publish.
        try? await Task.sleep(nanoseconds: 6_000_000_000)

        // Snapshot via a fresh discovery hop into a published list.
        let devices = await collectDevicesOnce()
        let payload = devices.map { d in
            [
                "serviceName": d.serviceName,
                "friendlyName": d.friendlyName,
                "model": d.model,
                "host": d.host,
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
        settingsManager.smartHubQuotaDisplayEnabled = true
        try? await document.reference.setData([
            "status": "completed",
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ], merge: true)
    }

    private func handleCast(document: QueryDocumentSnapshot, data: [String: Any]) async {
        guard let url = URL(string: settingsManager.smartHubQuotaDashboardURL) else {
            await fail(document: document, message: "no dashboard URL configured")
            return
        }
        // Re-discover the device by serviceName so we have a current IP.
        let serviceName = (data["deviceId"] as? String)
            ?? settingsManager.castSelectedDeviceServiceName
        guard let device = await locateDevice(serviceName: serviceName) else {
            await fail(document: document, message: "device not on network")
            return
        }
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
            await fail(document: document, message: "device not on network")
            return
        }
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

    /// 6-second mDNS scan, returning whatever devices were resolved.
    private func collectDevicesOnce() async -> [CastDevice] {
        await withCheckedContinuation { continuation in
            var collected: [CastDevice] = []
            let scanner = CastDiscovery(onUpdate: { devices in
                collected = devices
            })
            scanner.start()
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                scanner.stop()
                continuation.resume(returning: collected)
            }
        }
    }

    private func locateDevice(serviceName: String) async -> CastDevice? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let scanner = CastDiscovery(onUpdate: { devices in
                if let match = devices.first(where: { $0.serviceName == serviceName }), !resumed {
                    resumed = true
                    continuation.resume(returning: match)
                }
            })
            scanner.start()
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                scanner.stop()
                if !resumed {
                    resumed = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
