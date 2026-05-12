import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

@MainActor
final class SmartDisplayActionsListener {
    private let accountManager: AccountManaging
    private let settingsManager: SettingsManager
    private let pixelClockController: PixelClockController
    private let repairCoordinator: SmartDisplayRepairCoordinator?
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var attachTask: Task<Void, Never>?
    private var processingDocs = Set<String>()

    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager,
        pixelClockController: PixelClockController,
        repairCoordinator: SmartDisplayRepairCoordinator? = nil
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.pixelClockController = pixelClockController
        self.repairCoordinator = repairCoordinator
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
        listener = Firestore.firestore().collection("users").document(uid)
            .collection("smart_display_actions")
            .whereField("status", isEqualTo: PixelClockActionStatus.pending.rawValue)
            .addSnapshotListener { [weak self] snapshot, error in
                guard error == nil, let docs = snapshot?.documents, !docs.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.processDocs(docs)
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

    private func processDocs(_ docs: [QueryDocumentSnapshot]) {
        for doc in docs where !processingDocs.contains(doc.documentID) {
            processingDocs.insert(doc.documentID)
            Task { @MainActor in
                defer { processingDocs.remove(doc.documentID) }
                await handle(document: doc)
            }
        }
    }

    private func handle(document: QueryDocumentSnapshot) async {
        let data = document.data()
        guard let type = data["type"] as? String else {
            await fail(document: document, message: "missing type")
            return
        }

        if let configData = data["pixelClock"] as? [String: Any],
           let config = decodePixelClockConfig(configData) {
            settingsManager.pixelClockConfig = config
        }

        if let displayData = data["displayConfig"] as? [String: Any],
           let display = SmartDisplayConfigCodec.decode(displayData) {
            settingsManager.smartHubDisplayConfig = display
        }

        if let orderRaw = data["displayOrder"] as? [String] {
            settingsManager.smartDisplayOrder = SmartDisplayConfigCodec.decodeOrder(orderRaw)
        }

        do {
            switch type {
            case "pixel_clock_probe":
                let result = await pixelClockController.probePixelClock()
                await complete(document: document, extra: [
                    "probeStatus": result.status.rawValue,
                    "message": result.message
                ])
            case "pixel_clock_prepare":
                let result = try await pixelClockController.preparePixelClock()
                var extra: [String: Any] = [
                    "probeStatus": result.probeStatus.rawValue,
                    "setupMode": result.mode.rawValue,
                    "message": result.message
                ]
                if let suggestedServerHost = result.suggestedServerHost {
                    extra["suggestedServerHost"] = suggestedServerHost
                }
                if let suggestedServerPort = result.suggestedServerPort {
                    extra["suggestedServerPort"] = suggestedServerPort
                }
                if let flasherURL = result.flasherURL {
                    extra["flasherURL"] = flasherURL
                }
                if let setupSSID = result.setupSSID {
                    extra["setupSSID"] = setupSSID
                }
                await complete(document: document, extra: extra)
            case "pixel_clock_test":
                try await pixelClockController.testPixelClock()
                await complete(document: document, extra: ["probeStatus": settingsManager.pixelClockConfig.lastProbeStatus.rawValue])
            case "pixel_clock_push":
                try await pixelClockController.pushPixelClockNow()
                await complete(document: document, extra: ["probeStatus": settingsManager.pixelClockConfig.lastProbeStatus.rawValue])
            case "pixel_clock_remove":
                try await pixelClockController.removePixelClockApp()
                await complete(document: document, extra: ["probeStatus": settingsManager.pixelClockConfig.lastProbeStatus.rawValue])
            case "pixel_clock_update_config":
                await complete(document: document, extra: ["probeStatus": settingsManager.pixelClockConfig.lastProbeStatus.rawValue])
            case "nest_hub_update_display_config", "nest_hub_update_order":
                // The display config / order is applied above; nothing
                // else to do — the next `SmartDisplayConfigPublisher`
                // heartbeat will mirror the new doc back so all clients
                // converge.
                await complete(document: document)
            case "nest_hub_refresh":
                if let bumped = await bumpHubRefresh() {
                    await complete(document: document, extra: ["refreshing": bumped])
                } else {
                    await fail(document: document, message: "bridge not running")
                }
            case "nest_hub_repair":
                guard let repairCoordinator else {
                    await fail(document: document, message: "Mac smart display repair service is not running.")
                    return
                }
                let status = await repairCoordinator.repairNestHub { status in
                    Task { @MainActor in
                        await self.updateProgress(document: document, key: "nestHub", status: status)
                    }
                }
                if status.isHealthy {
                    await complete(document: document, extra: ["nestHub": encode(status)])
                } else {
                    await fail(document: document, message: status.message, extra: ["nestHub": encode(status)])
                }
            case "pixel_clock_repair":
                guard let repairCoordinator else {
                    await fail(document: document, message: "Mac smart display repair service is not running.")
                    return
                }
                let status = await repairCoordinator.repairPixelClock { status in
                    Task { @MainActor in
                        await self.updateProgress(document: document, key: "pixelClock", status: status)
                    }
                }
                if status.isHealthy || status.phase == .skipped {
                    await complete(document: document, extra: ["pixelClock": encode(status)])
                } else {
                    await fail(document: document, message: status.message, extra: ["pixelClock": encode(status)])
                }
            case "smart_display_repair":
                guard let repairCoordinator else {
                    await fail(document: document, message: "Mac smart display repair service is not running.")
                    return
                }
                let report = await repairCoordinator.repairAll { report in
                    Task { @MainActor in
                        await self.updateProgress(document: document, report: report)
                    }
                }
                let payload = encode(report)
                if report.anyHealthy {
                    await complete(document: document, extra: ["repair": payload])
                } else {
                    await fail(document: document, message: "No smart display reached a working state.", extra: ["repair": payload])
                }
            case "nest_hub_identify":
                // No-op endpoint — the iOS-side adapter only uses this
                // as a "speak now" signal that we surface to future
                // voice integrations.
                await complete(document: document)
            case "nest_hub_stop":
                settingsManager.smartHubQuotaDisplayEnabled = false
                await complete(document: document)
            default:
                await fail(document: document, message: "unknown type: \(type)")
            }
        } catch {
            await fail(document: document, message: error.localizedDescription)
        }
    }

    /// Triggers a Mac-side hub refresh via the existing bridge server.
    /// Returns `true` if the bridge is running and the refresh was
    /// dispatched; `false` if the user disabled the bridge.
    private func bumpHubRefresh() async -> Bool? {
        guard SmartHubBridgeServer.shared.isRunning else { return nil }
        SmartHubBridgeServer.shared.bumpRefresh()
        return true
    }

    private func decodePixelClockConfig(_ data: [String: Any]) -> PixelClockConfig? {
        let updatedAt: Date = {
            if let raw = data["updatedAt"] as? String,
               let parsed = ISO8601DateFormatter().date(from: raw) {
                return parsed
            }
            return Date()
        }()
        let timePeriod: SmartHubTimePeriod = {
            if let raw = data["timePeriod"] as? String,
               let parsed = SmartHubTimePeriod(rawValue: raw) {
                return parsed
            }
            return .rolling5h
        }()
        return PixelClockConfig(
            enabled: data["enabled"] as? Bool ?? false,
            host: data["host"] as? String ?? "192.168.68.92",
            port: data["port"] as? Int ?? 80,
            layout: (data["layout"] as? String).flatMap(PixelClockLayout.init(rawValue:)) ?? .providerDashboard,
            palette: (data["palette"] as? String).flatMap(PixelClockPalette.init(rawValue:)) ?? .emberWhimsy,
            timePeriod: timePeriod,
            workingSpinnerStyle: (data["workingSpinnerStyle"] as? String).flatMap(PixelClockSpinnerStyle.init(rawValue:)) ?? .orbit,
            workingSpinnerPrimaryHex: data["workingSpinnerPrimaryHex"] as? String ?? "#52D6FF",
            workingSpinnerSecondaryHex: data["workingSpinnerSecondaryHex"] as? String ?? "#FFFFFF",
            completionClockSoundEnabled: data["completionClockSoundEnabled"] as? Bool ?? true,
            completionLocalNotificationsEnabled: data["completionLocalNotificationsEnabled"] as? Bool ?? true,
            pageDurationSeconds: data["pageDurationSeconds"] as? Int ?? 7,
            updateIntervalSeconds: data["updateIntervalSeconds"] as? Int ?? 60,
            scrollSpeedPercent: data["scrollSpeedPercent"] as? Int ?? 100,
            brightness: data["brightness"] as? Int,
            providerIDs: data["providerIDs"] as? [String] ?? [],
            updatedAt: updatedAt,
            updatedByDeviceId: data["updatedByDeviceId"] as? String,
            lastProbeStatus: (data["lastProbeStatus"] as? String).flatMap(PixelClockProbeStatus.init(rawValue:)) ?? .unknown
        )
    }

    private func complete(document: QueryDocumentSnapshot, extra: [String: Any] = [:]) async {
        var payload = extra
        payload["status"] = PixelClockActionStatus.completed.rawValue
        payload["completedAt"] = ISO8601DateFormatter().string(from: Date())
        try? await document.reference.setData(payload, merge: true)
    }

    private func fail(document: QueryDocumentSnapshot, message: String, extra: [String: Any] = [:]) async {
        var payload = extra
        payload.merge([
            "status": PixelClockActionStatus.failed.rawValue,
            "errorMessage": message,
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ]) { _, new in new }
        try? await document.reference.setData(payload, merge: true)
    }

    private func updateProgress(
        document: QueryDocumentSnapshot,
        key: String,
        status: SmartDisplayDeviceRepairStatus
    ) async {
        try? await document.reference.setData([
            key: encode(status),
            "phase": status.phase.rawValue,
            "message": status.message,
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ], merge: true)
    }

    private func updateProgress(
        document: QueryDocumentSnapshot,
        report: SmartDisplayRepairReport
    ) async {
        try? await document.reference.setData([
            "repair": encode(report),
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ], merge: true)
    }

    private func encode(_ report: SmartDisplayRepairReport) -> [String: Any] {
        var payload: [String: Any] = [
            "startedAt": ISO8601DateFormatter().string(from: report.startedAt)
        ]
        if let completedAt = report.completedAt {
            payload["completedAt"] = ISO8601DateFormatter().string(from: completedAt)
        }
        if let nestHub = report.nestHub {
            payload["nestHub"] = encode(nestHub)
        }
        if let pixelClock = report.pixelClock {
            payload["pixelClock"] = encode(pixelClock)
        }
        return payload
    }

    private func encode(_ status: SmartDisplayDeviceRepairStatus) -> [String: Any] {
        var payload: [String: Any] = [
            "kind": status.kind.rawValue,
            "phase": status.phase.rawValue,
            "message": status.message,
            "updatedAt": ISO8601DateFormatter().string(from: status.updatedAt)
        ]
        if let proof = status.proof {
            payload["proof"] = proof
        }
        return payload
    }
}
