import Foundation
import OpenBurnBarCore

// MARK: - Smart Hub Bridge Controller
//
// Glue between `SettingsManager` (the toggle + URL fields), the
// `SmartHubBridgeServer` (the actual HTTP listener), and a periodic
// snapshot pump that pulls quota / spend data from
// `ProviderQuotaService` so the Nest Hub display has something to
// render.
//
// Owned by `OpenBurnBarRuntimeContext`. Stays alive for the app lifetime.

@MainActor
final class SmartHubBridgeController {

    private let settingsManager: SettingsManager
    private let quotaService: ProviderQuotaService?
    private let dataStore: DataStore?

    private var heartbeat: Task<Void, Never>?
    private var settingsObserver: Task<Void, Never>?
    private var lastEnabledState: Bool = false
    private var lastConfiguredPort: UInt16 = 8787
    private var lastTimePeriod: SmartHubTimePeriod = .rolling5h

    /// Auto-refresh cadence for provider quota while the bridge is running.
    /// 60s keeps Claude (and other providers) fresh on the Nest Hub
    /// without hammering remote APIs.
    private let autoRefreshIntervalSeconds: TimeInterval = 60

    /// Re-pump cadence for the on-device snapshot (no network fetch). Cheap.
    private let snapshotPumpIntervalSeconds: TimeInterval = 5

    private var lastAutoRefreshAt: Date = .distantPast

    init(
        settingsManager: SettingsManager,
        quotaService: ProviderQuotaService?,
        dataStore: DataStore? = nil
    ) {
        self.settingsManager = settingsManager
        self.quotaService = quotaService
        self.dataStore = dataStore
    }

    /// Reads the current toggle state and starts/stops the bridge to match.
    /// Begins a fast snapshot pump and an auto-refresh that keeps data
    /// (especially Claude) under 60s old while the Nest is showing the
    /// dashboard.
    func start() {
        wireBridgeHandlers()
        applySettings()
        observeSettings()
        startHeartbeat()
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        settingsObserver?.cancel()
        settingsObserver = nil
        SmartHubBridgeServer.shared.stop()
        lastEnabledState = false
    }

    // MARK: - Bridge handlers

    /// Wires the server's POST /refresh and POST /period endpoints back
    /// into the controller so the device can drive real refreshes and
    /// time-period changes without round-tripping through Firestore.
    private func wireBridgeHandlers() {
        SmartHubBridgeServer.shared.setRefreshHandler { [weak self] in
            await self?.performForcedRefresh() ?? false
        }
        SmartHubBridgeServer.shared.setPeriodChangeHandler { [weak self] period in
            self?.applyTimePeriod(period)
        }
    }

    /// Persists the user's chosen time period and re-pumps the snapshot
    /// so the on-device picker shows the updated bucket immediately.
    private func applyTimePeriod(_ period: SmartHubTimePeriod) {
        if settingsManager.smartHubQuotaTimePeriod != period {
            settingsManager.smartHubQuotaTimePeriod = period
        }
        lastTimePeriod = period
        SmartHubBridgeServer.shared.updateTimePeriod(period)
        Task { @MainActor in
            await pumpSnapshot()
        }
    }

    /// Triggers an actual quota refetch (not just a version bump). Used
    /// by the on-device refresh button + the "Refresh Hub" Mac action.
    /// Returns `true` when the underlying refresh succeeded.
    func performForcedRefresh() async -> Bool {
        guard let quotaService else {
            await pumpSnapshot()
            return false
        }
        if let dataStore {
            await quotaService.refreshAll(dataStore: dataStore)
            lastAutoRefreshAt = Date()
        }
        await pumpSnapshot()
        return true
    }

    // MARK: - Settings observation

    private func observeSettings() {
        settingsObserver = Task { @MainActor in
            // Poll the toggle every 2s — cheap and avoids depending on a
            // particular reactive plumbing in SettingsManager.
            while !Task.isCancelled {
                applySettings()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func applySettings() {
        let enabled = settingsManager.smartHubQuotaDisplayEnabled
        let port = portFromConfiguredURL()
        let currentPeriod = settingsManager.smartHubQuotaTimePeriod

        if enabled {
            // Restart on port change.
            if !lastEnabledState || port != lastConfiguredPort {
                SmartHubBridgeServer.shared.stop()
                SmartHubBridgeServer.shared.start(port: port)
                lastConfiguredPort = port
            }
        } else if lastEnabledState {
            SmartHubBridgeServer.shared.stop()
        }

        // Mirror the user-selected period into the bridge whenever it
        // changes (Mac picker, iOS picker via Firestore, or device toggle).
        if currentPeriod != lastTimePeriod {
            SmartHubBridgeServer.shared.updateTimePeriod(currentPeriod)
            lastTimePeriod = currentPeriod
            // Re-pump snapshot so the new period's bucket renders right away.
            Task { @MainActor in
                await pumpSnapshot()
            }
        }

        lastEnabledState = enabled
    }

    /// Attempts to extract a port from `smartHubQuotaDashboardURL`. Falls
    /// back to 8787 — the documented default.
    private func portFromConfiguredURL() -> UInt16 {
        let raw = settingsManager.smartHubQuotaDashboardURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let port = url.port,
              (1024...65_535).contains(port) else {
            return 8787
        }
        return UInt16(port)
    }

    // MARK: - Heartbeat snapshot pump

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                await refreshIfStale()
                await pumpSnapshot()
                let nanos = UInt64(snapshotPumpIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// Fires `quotaService.refreshAll` when the cached snapshot is older
    /// than `autoRefreshIntervalSeconds`. Without this, the Mac dashboard
    /// (and the Nest Hub) would only refresh when the user clicked the
    /// refresh button — Claude in particular goes 2h+ stale.
    private func refreshIfStale() async {
        guard let quotaService, let dataStore else { return }
        guard SmartHubBridgeServer.shared.isRunning else { return }

        let elapsed = Date().timeIntervalSince(lastAutoRefreshAt)
        if elapsed < autoRefreshIntervalSeconds { return }

        lastAutoRefreshAt = Date()
        await quotaService.refreshIfNeeded(dataStore: dataStore, maxAge: autoRefreshIntervalSeconds)
    }

    private func pumpSnapshot() async {
        guard SmartHubBridgeServer.shared.isRunning else { return }
        let snapshot = buildSnapshot()
        SmartHubBridgeServer.shared.updateSnapshot(snapshot)
    }

    private func buildSnapshot() -> SmartHubBridgeSnapshot {
        let period = settingsManager.smartHubQuotaTimePeriod
        let providers = quotaProviders(period: period)
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        let now = timeFormatter.string(from: Date())
        let totalText = providers.isEmpty ? "—" : "\(providers.count) tracked"

        return SmartHubBridgeSnapshot(
            totalSpend: totalText,
            headline: providers.isEmpty
                ? "Waiting on the first refresh"
                : "Showing \(period.displayName.lowercased())",
            subheadline: "Updated at \(now)",
            providers: providers
        )
    }

    /// Iterate the providers OpenBurnBar tracks; for each, ask the existing
    /// `ProviderQuotaService` for a snapshot and surface the bucket whose
    /// rolling window best matches the user-selected period.
    private func quotaProviders(period: SmartHubTimePeriod) -> [SmartHubBridgeSnapshot.Provider] {
        guard let quotaService else { return [] }
        return AgentProvider.allCases.compactMap { provider -> SmartHubBridgeSnapshot.Provider? in
            guard let snapshot = quotaService.snapshot(for: provider) else { return nil }
            guard let bucket = Self.bestBucket(in: snapshot, for: period) else { return nil }
            let percent = Int((bucket.progressFraction * 100).rounded())
            return SmartHubBridgeSnapshot.Provider(
                name: provider.displayName,
                percent: percent,
                label: bucket.usageText,
                tone: tone(for: percent),
                windowLabel: Self.windowLabel(for: bucket)
            )
        }
    }

    /// Pick the bucket whose rolling window most closely matches the
    /// user-selected period. Falls back to the legacy "primary"/"monthly"
    /// heuristic when no bucket carries a usable window length so we
    /// still render something instead of going blank.
    static func bestBucket(
        in snapshot: ProviderQuotaSnapshot,
        for period: SmartHubTimePeriod
    ) -> ProviderQuotaBucket? {
        let buckets = snapshot.buckets
        if buckets.isEmpty { return nil }

        let target = period.spanHours
        var bestBucket: ProviderQuotaBucket?
        var bestScore = Double.infinity

        for bucket in buckets {
            guard let hours = approximateBucketHours(bucket) else { continue }
            let score = abs(log(max(hours, 0.5)) - log(max(target, 0.5)))
            if score < bestScore {
                bestScore = score
                bestBucket = bucket
            }
        }
        if let bestBucket {
            return bestBucket
        }

        let preferredPriorities = ["primary", "month", "monthly", "weekly", "daily"]
        for hint in preferredPriorities {
            if let match = buckets.first(where: { $0.key.lowercased().contains(hint) || $0.label.lowercased().contains(hint) }) {
                return match
            }
        }
        return buckets.first
    }

    /// Best-effort estimate of a bucket's window length in hours. Reads
    /// the `windowKind` enum first, then falls back to text in `key` /
    /// `label` (e.g. "5-hour window", "7-day window") so we cover Claude
    /// statusline + heuristic-built MiniMax/Cursor buckets.
    private static func approximateBucketHours(_ bucket: ProviderQuotaBucket) -> Double? {
        let key = bucket.key.lowercased()
        let label = bucket.label.lowercased()

        if key.contains("five_hour") || label.contains("5-hour") || label.contains("5 hour") || key.contains("five-hour") {
            return 5
        }
        if key.contains("seven_day") || label.contains("7-day") || label.contains("7 day") || key.contains("seven-day") {
            return 24 * 7
        }
        if label.contains("daily") || key.contains("daily") || label.contains("24h") || label.contains("24 hour") {
            return 24
        }
        if label.contains("monthly") || key.contains("month") {
            return 24 * 30
        }
        if label.contains("weekly") || key.contains("weekly") {
            return 24 * 7
        }

        switch bucket.windowKind {
        case .rollingHours:
            return 5
        case .rollingDays:
            return 24 * 7
        case .daily:
            return 24
        case .weekly:
            return 24 * 7
        case .monthly:
            return 24 * 30
        case .lifetime:
            return nil
        case .custom:
            return nil
        }
    }

    /// Compact label rendered next to each provider on the Nest Hub
    /// (e.g. "5h", "7d") so it's visually clear which window the row
    /// reflects when the user selects "Last 24 hours" but a provider
    /// only exposes a 5-hour bucket.
    private static func windowLabel(for bucket: ProviderQuotaBucket) -> String {
        guard let hours = approximateBucketHours(bucket) else { return "" }
        if hours <= 24 { return "\(Int(hours))h" }
        let days = Int((hours / 24).rounded())
        return "\(days)d"
    }

    private func tone(for percent: Int) -> SmartHubBridgeSnapshot.Provider.Tone {
        switch percent {
        case 0..<60:    return .success
        case 60..<85:   return .ember
        case 85..<100:  return .warning
        default:        return .ember
        }
    }
}
