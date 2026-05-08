import Foundation
import FirebaseFirestore
import FirebaseAuth
import OpenBurnBarCore

// MARK: - Smart Hub Store
//
// Reads `users/{uid}/smart_hub_config/*` from Firestore and exposes the
// freshest enabled config to the UI. The Cast Now button uses
// `cast()` to POST the refresh URL on the Mac's local DashCast bridge.

@Observable @MainActor
final class SmartHubStore {

    enum CastState: Equatable {
        case idle
        case casting
        case success(at: Date)
        case failure(message: String)
    }

    private(set) var config: SmartHubConfig?
    private(set) var castState: CastState = .idle
    private(set) var isLoading = false

    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    /// `true` when a Mac in the user's account has published an enabled
    /// smart-hub config with at least a refresh URL we can hit.
    var canCast: Bool {
        guard let config, config.enabled else { return false }
        return config.refreshURL != nil
    }

    var dashboardURL: URL? {
        config?.dashboardURL.flatMap(URL.init(string:))
    }

    /// Loads the freshest published smart-hub config across all Macs the
    /// user has signed into. We pick the most-recently-`publishedAt` doc
    /// so that only one Cast button shows even if two Macs are paired.
    func load() async {
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
            timePeriod: timePeriod
        )
    }

    /// Persists the chosen time period on the most-recently-published
    /// `smart_hub_config` doc. The Mac picks it up via `applySettings`
    /// → bridge controller → device segmented control.
    func updateTimePeriod(_ period: SmartHubTimePeriod) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let snapshot = try await db.collection("users").document(uid)
                .collection("smart_hub_config").getDocuments()
            guard let target = snapshot.documents
                .max(by: { ($0.data()["publishedAt"] as? String ?? "") < ($1.data()["publishedAt"] as? String ?? "") })
            else { return }

            try await target.reference.setData(
                [
                    "timePeriod": period.rawValue,
                    "publishedAt": ISO8601DateFormatter().string(from: Date())
                ],
                merge: true
            )
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
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "SmartHubStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        let actionId = UUID().uuidString
        let actionsRef = db.collection("users").document(uid).collection("cast_actions").document(actionId)
        try await actionsRef.setData([
            "type": "test",
            "status": "pending",
            "requestedAt": ISO8601DateFormatter().string(from: Date())
        ])
        // Poll for completion (up to 25 seconds).
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 800_000_000)
            let snap = try await actionsRef.getDocument()
            if let status = snap.data()?["status"] as? String, status != "pending" { break }
        }
        // Read whatever the Mac published.
        let resultsRef = db.collection("users").document(uid)
            .collection("cast_discovery_results").document("latest")
        let resultsSnap = try await resultsRef.getDocument()
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

    private func publishAction(_ payload: [String: Any]) async throws -> WizardActionStatus {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "SmartHubStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        let actionId = UUID().uuidString
        let actionsRef = db.collection("users").document(uid).collection("cast_actions").document(actionId)
        var data = payload
        data["status"] = "pending"
        data["requestedAt"] = ISO8601DateFormatter().string(from: Date())
        try await actionsRef.setData(data)

        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 700_000_000)
            let snap = try await actionsRef.getDocument()
            if let status = snap.data()?["status"] as? String {
                switch status {
                case "completed": return .completed
                case "failed":
                    let message = (snap.data()?["errorMessage"] as? String) ?? "Failed."
                    return .failed(message)
                default: continue
                }
            }
        }
        return .failed("Timed out waiting for the Mac.")
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
