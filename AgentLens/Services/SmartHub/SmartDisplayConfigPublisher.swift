import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

@MainActor
final class SmartDisplayConfigPublisher {
    private let accountManager: AccountManaging
    private let settingsManager: SettingsManager
    private let db: Firestore
    private var heartbeat: Task<Void, Never>?

    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager,
        db: Firestore = Firestore.firestore()
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.db = db
    }

    func start() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                await publishCurrent()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    func publishCurrent() async {
        guard let uid = accountManager.currentUID else { return }
        let data = smartHubPayload()
        do {
            try await db.collection("users").document(uid)
                .collection("smart_hub_config").document(accountManager.deviceId)
                .setData(data, merge: true)
        } catch {
            // Best-effort status publication; the UI keeps local settings truth.
        }
    }

    private func smartHubPayload() -> [String: Any] {
        [
            "enabled": settingsManager.smartHubQuotaDisplayEnabled || settingsManager.pixelClockConfig.enabled,
            "dashboardURL": settingsManager.smartHubQuotaDashboardURL,
            "refreshURL": settingsManager.smartHubQuotaRefreshURL,
            "voiceRefreshURL": settingsManager.smartHubQuotaVoiceRefreshURL,
            "sourceDeviceName": Host.current().localizedName ?? "OpenBurnBar Mac",
            "publishedAt": ISO8601DateFormatter().string(from: Date()),
            "timePeriod": settingsManager.smartHubQuotaTimePeriod.rawValue,
            "pixelClock": pixelClockPayload(settingsManager.pixelClockConfig),
            "displayConfig": SmartDisplayConfigCodec.encode(settingsManager.smartHubDisplayConfig),
            "displayOrder": settingsManager.smartDisplayOrder.kinds.map(\.rawValue),
            "schemaVersion": 3
        ]
    }

    private func pixelClockPayload(_ config: PixelClockConfig) -> [String: Any] {
        var payload: [String: Any] = [
            "enabled": config.enabled,
            "host": config.host,
            "port": config.clampedPort,
            "layout": config.layout.rawValue,
            "palette": config.palette.rawValue,
            "timePeriod": config.timePeriod.rawValue,
            "pageDurationSeconds": config.clampedPageDuration,
            "updateIntervalSeconds": config.clampedUpdateInterval,
            "scrollSpeedPercent": config.clampedScrollSpeed,
            "providerIDs": config.providerIDs,
            "updatedAt": ISO8601DateFormatter().string(from: config.updatedAt),
            "lastProbeStatus": config.lastProbeStatus.rawValue
        ]
        if let updatedByDeviceId = config.updatedByDeviceId {
            payload["updatedByDeviceId"] = updatedByDeviceId
        }
        if let brightness = config.clampedBrightness {
            payload["brightness"] = brightness
        }
        return payload
    }
}
