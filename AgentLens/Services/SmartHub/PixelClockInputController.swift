import Foundation
import OpenBurnBarCore
import OSLog

/// Translates a Ulanzi/AWTRIX hardware-button press into a Mac-side action
/// while the BurnBar custom app is showing on the device.
///
/// Transport: the device exposes the active app name under `/api/stats.app`.
/// `PixelClockController`'s heartbeat polls that field at ~400 ms cadence and
/// hands each sample to `ingest(currentAppName:config:)` here. When the
/// active app is one of the OpenBurnBar sentinel apps
/// (`openburnbar_btn_left/select/right`), we infer the corresponding hardware
/// button was just pressed, look up the user's binding, run the action, and
/// switch the device back to `openburnbar0`.
@MainActor
final class PixelClockInputController {
    private static let logger = Logger(subsystem: "com.openburnbar.app", category: "PixelClockInput")
    private static let snoozeDuration: TimeInterval = 60 * 60

    private let settingsManager: SettingsManager
    private let quotaService: ProviderQuotaService?
    private let client: AWTRIXClient
    private let pushPixelClockNow: @MainActor () async -> Void
    private let returnToBurnBar: @MainActor (PixelClockConfig) async -> Void

    private var lastDispatchedSentinel: AWTRIXClient.SentinelApp?

    init(
        settingsManager: SettingsManager,
        quotaService: ProviderQuotaService?,
        client: AWTRIXClient,
        pushPixelClockNow: @escaping @MainActor () async -> Void,
        returnToBurnBar: @escaping @MainActor (PixelClockConfig) async -> Void
    ) {
        self.settingsManager = settingsManager
        self.quotaService = quotaService
        self.client = client
        self.pushPixelClockNow = pushPixelClockNow
        self.returnToBurnBar = returnToBurnBar
    }

    func ingest(currentAppName: String?, config: PixelClockConfig, now: Date = Date()) async {
        guard let currentAppName, let sentinel = AWTRIXClient.SentinelApp(appName: currentAppName) else {
            // BurnBar (or any other app) is showing — clear debounce so the
            // next genuine sentinel press fires.
            lastDispatchedSentinel = nil
            return
        }

        guard lastDispatchedSentinel == nil else {
            return
        }
        lastDispatchedSentinel = sentinel

        let action = action(for: sentinel, in: config)
        Self.logger.info("Sentinel \(sentinel.rawValue, privacy: .public) → action \(action.rawValue, privacy: .public)")
        await dispatch(action: action, now: now)
        await returnToBurnBar(settingsManager.pixelClockConfig)
    }

    private func action(for sentinel: AWTRIXClient.SentinelApp, in config: PixelClockConfig) -> PixelClockButtonAction {
        switch sentinel {
        case .left: return config.buttonBindings.left
        case .select: return config.buttonBindings.select
        case .right: return config.buttonBindings.right
        }
    }

    private func dispatch(action: PixelClockButtonAction, now: Date) async {
        var config = settingsManager.pixelClockConfig
        var configChanged = false

        switch action {
        case .none:
            return
        case .nextProvider:
            configChanged = rotateSelectedProvider(in: &config, by: 1)
        case .previousProvider:
            configChanged = rotateSelectedProvider(in: &config, by: -1)
        case .openHermes:
            postShowAssistantsTab()
        case .snoozeAlert:
            config.mutedUntil = now.addingTimeInterval(Self.snoozeDuration)
            configChanged = true
        case .cycleLayout:
            config.layout = nextLayout(after: config.layout)
            configChanged = true
        case .cycleTimePeriod:
            config.timePeriod = nextTimePeriod(after: config.timePeriod)
            configChanged = true
        }

        if configChanged {
            config.updatedAt = now
            settingsManager.pixelClockConfig = config
            await pushPixelClockNow()
        }
    }

    private func rotateSelectedProvider(in config: inout PixelClockConfig, by step: Int) -> Bool {
        let count = providerPageCount(for: config)
        guard count > 0 else { return false }
        let raw = config.selectedProviderIndex + step
        let normalized = ((raw % count) + count) % count
        guard normalized != config.selectedProviderIndex else { return false }
        config.selectedProviderIndex = normalized
        return true
    }

    private func providerPageCount(for config: PixelClockConfig) -> Int {
        let items = PixelClockSnapshotAdapter.quotaCycleItems(quotaService: quotaService)
        let normalized = Set(config.providerIDs.map { $0.lowercased() })
        guard !normalized.isEmpty else { return items.count }
        return items.filter { normalized.contains($0.providerID.lowercased()) }.count
    }

    private func postShowAssistantsTab() {
        NotificationCenter.default.post(
            name: Notification.Name("ShowAssistantsTab"),
            object: nil,
            userInfo: ["runtime": "hermes"]
        )
    }

    private func nextLayout(after current: PixelClockLayout) -> PixelClockLayout {
        let cycle: [PixelClockLayout] = [.providerDashboard, .quotaCarousel, .burnStatus]
        guard let index = cycle.firstIndex(of: current) else { return cycle[0] }
        return cycle[(index + 1) % cycle.count]
    }

    private func nextTimePeriod(after current: SmartHubTimePeriod) -> SmartHubTimePeriod {
        let cycle: [SmartHubTimePeriod] = [.rolling5h, .rolling24h, .rolling7d, .rolling30d]
        guard let index = cycle.firstIndex(of: current) else { return cycle[0] }
        return cycle[(index + 1) % cycle.count]
    }
}

extension AWTRIXClient.SentinelApp {
    init?(appName: String) {
        switch appName {
        case AWTRIXClient.SentinelApp.left.appName: self = .left
        case AWTRIXClient.SentinelApp.select.appName: self = .select
        case AWTRIXClient.SentinelApp.right.appName: self = .right
        default: return nil
        }
    }
}
