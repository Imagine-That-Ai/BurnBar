import Foundation
import FirebaseFirestore
import FirebaseAuth
import FirebaseCore
import OpenBurnBarCore

// MARK: - Smart Hub Store
//
// Reads `users/{uid}/smart_hub_config/*` from Firestore and exposes the
// freshest enabled config to the UI. The Cast Now button uses
// `cast()` to POST the refresh URL on the Mac's local DashCast bridge.

@Observable @MainActor
final class SmartHubStore {
    private static let liveBridgeMaxAge: TimeInterval = 60

    enum CastState: Equatable {
        case idle
        case casting
        case success(at: Date)
        case failure(message: String)
    }

    private(set) var config: SmartHubConfig?
    private(set) var castState: CastState = .idle
    private(set) var isLoading = false
    private(set) var lastPublishedActionData: [String: Any] = [:]

    private let injectedDB: Firestore?
    private var db: Firestore { injectedDB ?? Firestore.firestore() }
    private var mobileConfigDocumentID: String {
        "mobile-\(MobileDeviceIdentity.loadOrCreateDeviceId())"
    }

    init(db: Firestore? = nil) {
        self.injectedDB = db
    }

    /// `true` when a Mac in the user's account has published an enabled
    /// smart-hub config with at least a refresh URL we can hit.
    var canCast: Bool {
        guard let config, config.enabled else { return false }
        return config.refreshURL != nil && hasLiveMacBridge
    }

    var hasLiveMacBridge: Bool {
        guard let config else { return false }
        return Date().timeIntervalSince(config.publishedAt) <= Self.liveBridgeMaxAge
    }

    var bridgeFreshnessMessage: String {
        guard let config else {
            return "Open BurnBar on your Mac to connect smart displays."
        }
        let age = Date().timeIntervalSince(config.publishedAt)
        guard age <= Self.liveBridgeMaxAge else {
            return "Mac bridge is offline. Last heartbeat was \(Self.relativeAge(age)) ago from \(config.sourceDeviceName ?? "your Mac")."
        }
        return "Mac bridge is live on \(config.sourceDeviceName ?? "your Mac")."
    }

    var dashboardURL: URL? {
        config?.dashboardURL.flatMap(URL.init(string:))
    }

    var pixelClockConfig: PixelClockConfig {
        config?.pixelClock ?? .disabled
    }

    /// Loads the freshest published smart-hub config across all Macs the
    /// user has signed into. We pick the most-recently-`publishedAt` doc
    /// so that only one Cast button shows even if two Macs are paired.
    func load() async {
        guard FirebaseApp.app() != nil else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await db.collection("users").document(uid)
                .collection("smart_hub_config").getDocuments()

            let freshest = snapshot.documents
                .compactMap { Self.decode(doc: $0.data()) }
                .max(by: { $0.publishedAt < $1.publishedAt })

            self.config = freshest
        } catch {
            // Firestore offline / not signed in — leave previous value.
        }
    }

    /// POST the configured refresh URL. The Mac-side DashCast bridge
    /// receives the ping and re-renders the dashboard onto the Nest Hub.
    func cast() async {
        guard hasLiveMacBridge else {
            castState = .failure(message: bridgeFreshnessMessage)
            return
        }
        guard let config, config.enabled,
              let raw = config.refreshURL,
              let url = URL(string: raw) else {
            castState = .failure(message: "No refresh URL configured.")
            return
        }
        castState = .casting

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                castState = .failure(message: "Bridge returned HTTP \(http.statusCode).")
                return
            }
            castState = .success(at: Date())
        } catch {
            castState = .failure(message: "Couldn't reach the Mac bridge. Make sure your iPhone and Mac are on the same Wi-Fi.")
        }
    }

    func clearCastFeedback() {
        castState = .idle
    }

    // MARK: - Decoding

    private static func decode(doc data: [String: Any]) -> SmartHubConfig? {
        let enabled = data["enabled"] as? Bool ?? false
        let publishedRaw = data["publishedAt"] as? String
        let publishedAt = publishedRaw.flatMap(ISO8601DateFormatter().date(from:)) ?? Date.distantPast
        let timePeriod: SmartHubTimePeriod = {
            if let raw = data["timePeriod"] as? String,
               let parsed = SmartHubTimePeriod(rawValue: raw) {
                return parsed
            }
            return .rolling5h
        }()
        return SmartHubConfig(
            enabled: enabled,
            dashboardURL: data["dashboardURL"] as? String,
            refreshURL: data["refreshURL"] as? String,
            voiceRefreshURL: data["voiceRefreshURL"] as? String,
            sourceDeviceName: data["sourceDeviceName"] as? String,
            publishedAt: publishedAt,
            timePeriod: timePeriod,
            pixelClock: decodePixelClock(data["pixelClock"] as? [String: Any]),
            displayConfig: SmartDisplayConfigCodec.decode(data["displayConfig"] as? [String: Any]),
            displayOrder: SmartDisplayConfigCodec.decodeOrder(data["displayOrder"] as? [String]),
            schemaVersion: data["schemaVersion"] as? Int ?? 1
        )
    }

    private static func decodePixelClock(_ data: [String: Any]?) -> PixelClockConfig? {
        guard let data else { return nil }
        let updatedAt: Date = {
            if let raw = data["updatedAt"] as? String,
               let parsed = ISO8601DateFormatter().date(from: raw) {
                return parsed
            }
            return Date.distantPast
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

    /// Persists the chosen time period on the most-recently-published
    /// `smart_hub_config` doc. The Mac picks it up via `applySettings`
    /// → bridge controller → device segmented control.
    func updateTimePeriod(_ period: SmartHubTimePeriod) async {
        guard FirebaseApp.app() != nil else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let target = try await targetConfigReference(uid: uid)
            try await target.setData(smartHubPayload(timePeriod: period), merge: true)
            // Optimistic local update so the picker doesn't snap back
            // before the next load() returns.
            if var current = self.config {
                current.timePeriod = period
                self.config = current
            }
        } catch {
            // Offline / not signed in — local picker already updated.
        }
    }

    func updatePixelClockConfig(_ pixelClock: PixelClockConfig) async {
        guard FirebaseApp.app() != nil else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let target = try await targetConfigReference(uid: uid)
            try await target.setData(smartHubPayload(pixelClock: pixelClock), merge: true)
            if var current = self.config {
                current.pixelClock = pixelClock
                current.schemaVersion = 3
                self.config = current
            }
            _ = try? await publishPixelClockAction(type: "pixel_clock_update_config", pixelClock: pixelClock)
        } catch {
            // Offline / not signed in — leave optimistic state to caller-owned UI.
        }
    }

    // MARK: - Nest Hub Display Config

    /// Computed view of the Nest Hub display config — defaults when no
    /// Mac has published one yet.
    var displayConfig: SmartHubDisplayConfig {
        config?.displayConfig ?? .default
    }

    /// Computed view of the Smart Display order — defaults when no Mac
    /// has published one yet.
    var displayOrder: SmartDisplayOrder {
        config?.displayOrder ?? .default
    }

    /// Persist a new Nest Hub display config. Mirrors `updatePixelClockConfig`
    /// — same Firestore doc, same publish-then-listen pattern. Mac listener
    /// applies the change to its bridge HTML.
    func updateDisplayConfig(_ display: SmartHubDisplayConfig) async {
        guard FirebaseApp.app() != nil else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let target = try await targetConfigReference(uid: uid)
            try await target.setData(smartHubPayload(displayConfig: display), merge: true)
            if var current = self.config {
                current.displayConfig = display
                current.schemaVersion = 3
                self.config = current
            }
            _ = try? await publishNestHubAction(type: "nest_hub_update_display_config", display: display)
        } catch {
            // Offline — the optimistic in-memory update keeps the UI fresh.
        }
    }

    /// Persist a new Smart Display order so both Mac and iOS render the
    /// same arrangement.
    func updateDisplayOrder(_ order: SmartDisplayOrder) async {
        guard FirebaseApp.app() != nil else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let target = try await targetConfigReference(uid: uid)
            try await target.setData(smartHubPayload(displayOrder: order), merge: true)
            if var current = self.config {
                current.displayOrder = order
                current.schemaVersion = 3
                self.config = current
            }
            _ = try? await publishNestHubAction(type: "nest_hub_update_order", display: nil, extra: ["displayOrder": order.kinds.map(\.rawValue)])
        } catch {
            // Offline — local order stays put until the next load() reconciles.
        }
    }

    func refreshNestHub() async throws -> WizardActionStatus {
        try await publishNestHubAction(type: "nest_hub_refresh", display: nil)
    }

    func repairNestHub() async throws -> WizardActionStatus {
        try await publishNestHubAction(type: "nest_hub_repair", display: nil, timeout: 180)
    }

    func repairSmartDisplays() async throws -> WizardActionStatus {
        try await publishNestHubAction(type: "smart_display_repair", display: nil, timeout: 300)
    }

    func identifyNestHub() async throws -> WizardActionStatus {
        try await publishNestHubAction(type: "nest_hub_identify", display: nil)
    }

    func stopNestHub() async throws -> WizardActionStatus {
        try await publishNestHubAction(type: "nest_hub_stop", display: nil)
    }

    private func publishNestHubAction(
        type: String,
        display: SmartHubDisplayConfig?,
        extra: [String: Any] = [:],
        timeout: TimeInterval = 45
    ) async throws -> WizardActionStatus {
        var payload: [String: Any] = ["type": type]
        if let display {
            payload["displayConfig"] = SmartDisplayConfigCodec.encode(display)
        }
        for (key, value) in extra {
            payload[key] = value
        }
        return try await publishAction(payload, collection: "smart_display_actions", timeout: timeout)
    }

    func probePixelClock() async throws -> WizardActionStatus {
        try await publishPixelClockAction(type: "pixel_clock_probe", pixelClock: config?.pixelClock)
    }

    func preparePixelClock() async throws -> WizardActionStatus {
        try await publishPixelClockAction(type: "pixel_clock_prepare", pixelClock: config?.pixelClock)
    }

    func testPixelClock() async throws -> WizardActionStatus {
        try await publishPixelClockAction(type: "pixel_clock_test", pixelClock: config?.pixelClock)
    }

    func pushPixelClockNow() async throws -> WizardActionStatus {
        try await publishPixelClockAction(type: "pixel_clock_push", pixelClock: config?.pixelClock)
    }

    func removePixelClockApp() async throws -> WizardActionStatus {
        try await publishPixelClockAction(type: "pixel_clock_remove", pixelClock: config?.pixelClock)
    }

    private func publishPixelClockAction(type: String, pixelClock: PixelClockConfig?) async throws -> WizardActionStatus {
        var payload: [String: Any] = ["type": type]
        if let pixelClock {
            payload["pixelClock"] = Self.encodePixelClock(pixelClock)
        }
        return try await publishAction(payload, collection: "smart_display_actions")
    }

    private func targetConfigReference(uid: String) async throws -> DocumentReference {
        let collection = db.collection("users").document(uid).collection("smart_hub_config")
        let snapshot = try await collection.getDocuments()
        if let target = snapshot.documents
            .max(by: { ($0.data()["publishedAt"] as? String ?? "") < ($1.data()["publishedAt"] as? String ?? "") }) {
            return target.reference
        }
        return collection.document(mobileConfigDocumentID)
    }

    private func smartHubPayload(
        timePeriod: SmartHubTimePeriod? = nil,
        pixelClock: PixelClockConfig? = nil,
        displayConfig: SmartHubDisplayConfig? = nil,
        displayOrder: SmartDisplayOrder? = nil
    ) -> [String: Any] {
        let resolvedPixelClock = pixelClock ?? config?.pixelClock ?? .disabled
        let resolvedDisplay = displayConfig ?? config?.displayConfig ?? .default
        let resolvedOrder = displayOrder ?? config?.displayOrder ?? .default
        let resolvedPeriod = timePeriod ?? config?.timePeriod ?? .rolling5h
        let enabled = (config?.enabled ?? false) || resolvedPixelClock.enabled

        var payload: [String: Any] = [
            "enabled": enabled,
            "sourceDeviceName": config?.sourceDeviceName ?? "OpenBurnBar Mobile",
            "publishedAt": ISO8601DateFormatter().string(from: Date()),
            "timePeriod": resolvedPeriod.rawValue,
            "pixelClock": Self.encodePixelClock(resolvedPixelClock),
            "displayConfig": SmartDisplayConfigCodec.encode(resolvedDisplay),
            "displayOrder": SmartDisplayConfigCodec.encodeOrder(resolvedOrder),
            "schemaVersion": 3
        ]
        if let dashboardURL = config?.dashboardURL { payload["dashboardURL"] = dashboardURL }
        if let refreshURL = config?.refreshURL { payload["refreshURL"] = refreshURL }
        if let voiceRefreshURL = config?.voiceRefreshURL { payload["voiceRefreshURL"] = voiceRefreshURL }
        return payload
    }

    private static func encodePixelClock(_ config: PixelClockConfig) -> [String: Any] {
        var payload: [String: Any] = [
            "enabled": config.enabled,
            "host": config.host,
            "port": config.clampedPort,
            "layout": config.layout.rawValue,
            "palette": config.palette.rawValue,
            "timePeriod": config.timePeriod.rawValue,
            "workingSpinnerStyle": config.workingSpinnerStyle.rawValue,
            "workingSpinnerPrimaryHex": config.workingSpinnerPrimaryHex,
            "workingSpinnerSecondaryHex": config.workingSpinnerSecondaryHex,
            "completionClockSoundEnabled": config.completionClockSoundEnabled,
            "completionLocalNotificationsEnabled": config.completionLocalNotificationsEnabled,
            "pageDurationSeconds": config.clampedPageDuration,
            "updateIntervalSeconds": config.clampedUpdateInterval,
            "scrollSpeedPercent": config.clampedScrollSpeed,
            "providerIDs": config.providerIDs,
            "updatedAt": ISO8601DateFormatter().string(from: config.updatedAt),
            "lastProbeStatus": config.lastProbeStatus.rawValue
        ]
        if let brightness = config.clampedBrightness {
            payload["brightness"] = brightness
        }
        if let updatedByDeviceId = config.updatedByDeviceId {
            payload["updatedByDeviceId"] = updatedByDeviceId
        }
        return payload
    }

    // MARK: - Cast Wizard (Firestore-proxied)
    //
    // The iPhone wizard publishes `cast_actions/{uuid}` documents that
    // the Mac listens for. We get back status + device list via two
    // companion collections.

    enum WizardActionStatus: Equatable {
        case pending
        case completed
        case failed(String)
    }

    /// Publish a `test` action and wait for the Mac to populate
    /// `cast_discovery_results/latest`. Returns the device list.
    func runDiscovery() async throws -> [WizardCastDevice] {
        guard FirebaseApp.app() != nil else {
            throw NSError(domain: "SmartHubStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Firebase is not configured."])
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "SmartHubStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        try requireLiveMacBridge()
        let actionId = UUID().uuidString
        let actionsRef = db.collection("users").document(uid).collection("cast_actions").document(actionId)
        try await actionsRef.setData([
            "type": "test",
            "status": "pending",
            "requestedAt": ISO8601DateFormatter().string(from: Date())
        ])
        // Poll for completion (up to 25 seconds).
        let deadline = Date().addingTimeInterval(25)
        var terminalStatus: String?
        var terminalData: [String: Any] = [:]
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 800_000_000)
            let snap = try await actionsRef.getDocument()
            let data = snap.data() ?? [:]
            if let status = data["status"] as? String, status != "pending" {
                terminalStatus = status
                terminalData = data
                break
            }
        }
        if terminalStatus == "failed" {
            let message = (terminalData["errorMessage"] as? String) ?? "Mac discovery failed."
            throw NSError(domain: "SmartHubStore", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard terminalStatus == "completed" else {
            throw NSError(domain: "SmartHubStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the Mac to scan Google smart displays."])
        }
        // Read whatever the Mac published.
        let resultsRef = db.collection("users").document(uid)
            .collection("cast_discovery_results").document("latest")
        let resultsSnap = try await resultsRef.getDocument()
        if let resultActionId = resultsSnap.data()?["actionId"] as? String,
           resultActionId != actionId {
            throw NSError(domain: "SmartHubStore", code: 5, userInfo: [NSLocalizedDescriptionKey: "Mac returned stale discovery results. Run Find again."])
        }
        guard let raw = resultsSnap.data()?["devices"] as? [[String: Any]] else { return [] }
        return raw.compactMap(WizardCastDevice.init(data:))
    }

    /// Asks the Mac to perform a test cast to the given device.
    func runTestCast(deviceId: String) async throws -> WizardActionStatus {
        try await publishAction(["type": "cast", "deviceId": deviceId])
    }

    /// Persists the chosen device on the Mac.
    func saveSelection(device: WizardCastDevice) async throws -> WizardActionStatus {
        try await publishAction([
            "type": "save_selection",
            "deviceId": device.serviceName,
            "friendlyName": device.friendlyName,
            "model": device.model
        ])
    }

    private func publishAction(
        _ payload: [String: Any],
        collection: String = "cast_actions",
        timeout: TimeInterval = 45
    ) async throws -> WizardActionStatus {
        guard FirebaseApp.app() != nil else {
            throw NSError(domain: "SmartHubStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Firebase is not configured."])
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "SmartHubStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        try requireLiveMacBridge()
        let actionId = UUID().uuidString
        let actionsRef = db.collection("users").document(uid).collection(collection).document(actionId)
        var data = payload
        data["status"] = "pending"
        data["requestedAt"] = ISO8601DateFormatter().string(from: Date())
        lastPublishedActionData = data
        try await actionsRef.setData(data)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 700_000_000)
            let snap = try await actionsRef.getDocument()
            let actionData = snap.data() ?? [:]
            lastPublishedActionData = actionData
            if let status = actionData["status"] as? String {
                switch status {
                case "completed": return .completed
                case "failed":
                    let message = (actionData["errorMessage"] as? String) ?? "Failed."
                    return .failed(message)
                default: continue
                }
            }
        }
        return .failed("Timed out waiting for the Mac.")
    }

    private func requireLiveMacBridge() throws {
        guard hasLiveMacBridge else {
            throw NSError(
                domain: "SmartHubStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: bridgeFreshnessMessage]
            )
        }
    }

    private static func relativeAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}

// MARK: - Mobile-side Cast Device
//
// We can't import `CastDevice` from AgentLens (Mac-only target). Wizard
// uses this lightweight mirror that decodes the Firestore payload.

struct WizardCastDevice: Hashable, Identifiable {
    let serviceName: String
    let friendlyName: String
    let model: String
    let host: String
    let iconKind: String
    let supportsDisplay: Bool

    var id: String { serviceName }

    init?(data: [String: Any]) {
        guard let serviceName = data["serviceName"] as? String,
              let friendlyName = data["friendlyName"] as? String else { return nil }
        self.serviceName = serviceName
        self.friendlyName = friendlyName
        self.model = (data["model"] as? String) ?? "Cast Device"
        self.host = (data["host"] as? String) ?? ""
        self.iconKind = (data["iconKind"] as? String) ?? "generic"
        self.supportsDisplay = (data["supportsDisplay"] as? Bool) ?? true
    }

    init(serviceName: String, friendlyName: String, model: String, host: String = "", iconKind: String = "generic", supportsDisplay: Bool = true) {
        self.serviceName = serviceName
        self.friendlyName = friendlyName
        self.model = model
        self.host = host
        self.iconKind = iconKind
        self.supportsDisplay = supportsDisplay
    }
}
