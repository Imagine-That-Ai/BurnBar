import Foundation
import os
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

    private static let log = Logger(subsystem: "com.openburnbar.app", category: "SmartHubBridge")

    private let settingsManager: SettingsManager
    private let quotaService: ProviderQuotaService?
    private let dataStore: DataStore?

    private var heartbeat: Task<Void, Never>?
    private var settingsObserver: Task<Void, Never>?
    private var castWatchdog: Task<Void, Never>?
    private var lastEnabledState: Bool = false
    private var lastConfiguredPort: UInt16 = 8787
    private var lastTimePeriod: SmartHubTimePeriod = .rolling5h
    private var lastDisplayConfig: SmartHubDisplayConfig?
    private var lastCastReassertedAt: Date = .distantPast

    /// Auto-refresh cadence for provider quota while the bridge is running.
    /// 60s keeps Claude (and other providers) fresh on the Nest Hub
    /// without hammering remote APIs.
    private let autoRefreshIntervalSeconds: TimeInterval = 60

    /// Re-pump cadence for the on-device snapshot (no network fetch). Cheap.
    private let snapshotPumpIntervalSeconds: TimeInterval = 5

    /// How often the cast watchdog verifies the Nest Hub is still
    /// rendering OpenBurnBar. The Hub can silently drop the DashCast
    /// session (Wi-Fi blip, ambient mode timer, "Hey Google" interrupt)
    /// and we have no signal otherwise — without this loop, the user
    /// has to manually re-cast.
    private let castWatchdogIntervalSeconds: TimeInterval = 30

    /// Minimum spacing between two soft re-LOAD attempts (when DashCast
    /// is already up and we just want to nudge the page). Hard kicks
    /// (STOP→LAUNCH for a wrong-app / Backdrop state) bypass this.
    private let castReassertCooldownSeconds: TimeInterval = 45

    /// How recently the embedded dashboard page must have polled
    /// `/state.json` for us to consider DashCast healthy. The page polls
    /// every ~2 s, so 20 s is a comfortable buffer that survives a single
    /// Wi-Fi blip without false-positives. Bigger than this means the
    /// page is no longer running JS (DashCast splash, blank tab, etc.)
    /// and we should re-cast.
    private let castClientHealthyPollWindowSeconds: TimeInterval = 20

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
        startCastWatchdog()
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        settingsObserver?.cancel()
        settingsObserver = nil
        castWatchdog?.cancel()
        castWatchdog = nil
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
        let currentDisplay = settingsManager.smartHubDisplayConfig

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

        if currentDisplay != lastDisplayConfig {
            SmartHubBridgeServer.shared.updateDisplayConfig(currentDisplay)
            lastDisplayConfig = currentDisplay
        }

        lastEnabledState = enabled
    }

    /// Returns the URL the dashboard is actually listening on. Falls
    /// back to the user-configured URL when the bridge hasn't started.
    /// macOS uses this for the "Open in browser" action so port
    /// fallback (8787 → 8788, …) opens the right page.
    func resolvedDashboardURL() -> URL? {
        if SmartHubBridgeServer.shared.isRunning,
           let boundPort = SmartHubBridgeServer.shared.boundPort {
            return URL(string: "http://127.0.0.1:\(boundPort)/render.html")
        }
        return URL(string: settingsManager.smartHubQuotaDashboardURL)
    }

    /// Returns the bridge probe status — bound / waiting / unreachable.
    /// `nil` is treated as `.unknown` by the model.
    func bridgeProbeStatus() -> SmartHubBridgeProbeStatus {
        guard SmartHubBridgeServer.shared.isRunning else { return .unreachable }
        return SmartHubBridgeServer.shared.snapshot.providers.isEmpty
            ? .waitingForData
            : .bound
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
                healServerIfNeeded()
                await refreshIfStale()
                await pumpSnapshot()
                let nanos = UInt64(snapshotPumpIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// Self-heal: when the user has the bridge enabled but the underlying
    /// listener is no longer running (port collision, transient bind
    /// failure, sandbox revocation), restart it. Without this, a single
    /// listener crash leaves the Nest Hub stuck on a blank page forever
    /// because nothing else in the pipeline ever notices.
    ///
    /// `start()` is itself idempotent (no-op when an existing listener is
    /// in the middle of coming up), so we don't pre-call `stop()` here.
    /// That `stop()` was the bug: applySettings()'s synchronous
    /// `stop()+start()` enqueues a `.ready` task; before that task can
    /// run, the heartbeat's first tick fires this self-heal seeing
    /// `isRunning=false`, cancels the in-flight listener, and races a
    /// second listener that fails with EADDRINUSE.
    private func healServerIfNeeded() {
        guard settingsManager.smartHubQuotaDisplayEnabled else { return }
        guard !SmartHubBridgeServer.shared.isRunning else { return }
        let port = portFromConfiguredURL()
        SmartHubBridgeServer.shared.start(port: port)
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
        PixelClockSnapshotAdapter.bestBucket(in: snapshot, for: period)
    }

    /// Best-effort estimate of a bucket's window length in hours. Reads
    /// the `windowKind` enum first, then falls back to text in `key` /
    /// `label` (e.g. "5-hour window", "7-day window") so we cover Claude
    /// statusline + heuristic-built MiniMax/Cursor buckets.
    private static func approximateBucketHours(_ bucket: ProviderQuotaBucket) -> Double? {
        PixelClockSnapshotAdapter.approximateBucketHours(bucket)
    }

    /// Compact label rendered next to each provider on the Nest Hub
    /// (e.g. "5h", "7d") so it's visually clear which window the row
    /// reflects when the user selects "Last 24 hours" but a provider
    /// only exposes a 5-hour bucket.
    private static func windowLabel(for bucket: ProviderQuotaBucket) -> String {
        PixelClockSnapshotAdapter.windowLabel(for: bucket)
    }

    private func tone(for percent: Int) -> SmartHubBridgeSnapshot.Provider.Tone {
        switch percent {
        case 0..<60:    return .success
        case 60..<85:   return .ember
        case 85..<100:  return .warning
        default:        return .ember
        }
    }

    // MARK: - Cast watchdog
    //
    // The Nest Hub is not reliable on its own — DashCast sessions get
    // evicted by ambient mode, "Hey Google", Wi-Fi roams, or device
    // reboots, with no signal back to the Mac. The watchdog probes the
    // device on a slow cadence and silently re-casts the dashboard when
    // it looks gone, so the Hub recovers without user action.

    private func startCastWatchdog() {
        castWatchdog?.cancel()
        castWatchdog = Task { @MainActor in
            while !Task.isCancelled {
                await runCastWatchdogTick()
                let nanos = UInt64(castWatchdogIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    private func runCastWatchdogTick() async {
        guard settingsManager.smartHubQuotaDisplayEnabled else { return }
        guard SmartHubBridgeServer.shared.isRunning else {
            Self.log.info("watchdog skipped: bridge not running")
            return
        }
        guard let device = cachedCastDevice() else {
            Self.log.info("watchdog skipped: no cached cast device")
            return
        }
        guard let url = preferredCastURL() else {
            Self.log.info("watchdog skipped: no castable URL")
            return
        }

        Self.log.info("watchdog tick host=\(device.host, privacy: .public) url=\(url.absoluteString, privacy: .public)")

        // Cheap liveness probe — if we can't even open the Cast channel,
        // the Hub is unreachable and re-casting won't help. Skip and
        // try again next tick.
        let probeClient = CastChannelClient(device: device)
        guard let state = await probeClient.queryReceiverState() else {
            Self.log.error("watchdog: probe could not reach \(device.host, privacy: .public)")
            await probeClient.stop()
            return
        }
        Self.log.info("watchdog state appId=\(state.appId, privacy: .public) isDashCast=\(state.isDashCast)")

        // DashCast being the active receiver app is not enough to call
        // the display healthy. The common stuck state is exactly this:
        // the Hub sits on DashCast's splash after a dropped LOAD. Treat
        // the existing DashCast session as stale and do a STOP -> LAUNCH
        // -> LOAD recovery on the watchdog cadence.
        if state.isDashCast {
            await probeClient.stop()

            // Proof-of-life: if the Nest Hub's embedded page has polled
            // `/state.json` recently, DashCast is not stuck — it's
            // actively rendering OpenBurnBar. Hard-refreshing every 45 s
            // on a healthy display is exactly the "stuck cycling on burn
            // bar status" failure mode (every refresh flashes DashCast's
            // splash). Skip the hard refresh while the client is alive.
            let timeSincePoll = Date().timeIntervalSince(SmartHubBridgeServer.shared.lastClientPollAt)
            let healthyPollWindow = castClientHealthyPollWindowSeconds
            if timeSincePoll <= healthyPollWindow {
                Self.log.info(
                    "watchdog: DashCast active + recent client poll \(Int(timeSincePoll), privacy: .public)s ago; skipping hard refresh"
                )
                return
            }

            let elapsed = Date().timeIntervalSince(lastCastReassertedAt)
            guard elapsed >= castReassertCooldownSeconds else {
                Self.log.info("watchdog: DashCast hard-refresh cooldown active, skipping")
                return
            }
            lastCastReassertedAt = Date()

            Self.log.info(
                "watchdog: DashCast active but no client poll in \(Int(timeSincePoll), privacy: .public)s — page looks stuck; hard refresh"
            )
            let refreshClient = CastChannelClient(device: device)
            let outcome = await refreshClient.forceRecast(url: url)
            if case .failure(let reason) = outcome {
                Self.log.error("watchdog: DashCast hard refresh failed: \(reason, privacy: .public)")
            }
            await refreshClient.stop()
            return
        }

        // Unhealthy case: another app is up (Backdrop, YouTube voice
        // shortcut, etc.) or nothing is running. Either way the Hub
        // isn't showing us — do a hard kick: STOP whatever's there and
        // launch DashCast fresh with force:true.
        await probeClient.stop()
        lastCastReassertedAt = Date()

        Self.log.info("watchdog: hard kick (forceRecast) — current app is not DashCast")
        let kickClient = CastChannelClient(device: device)
        let outcome = await kickClient.forceRecast(url: url)
        if case .failure(let reason) = outcome {
            Self.log.error("watchdog: forceRecast failed: \(reason, privacy: .public). Falling back to reconnect strategy.")
            // If STOP→LAUNCH itself failed, fall through to the full
            // recovery strategy (4-attempt backoff + Home Assistant).
            await kickClient.stop()
            _ = await CastReconnectStrategy(device: device).castWithRecovery(url: url)
        } else {
            Self.log.info("watchdog: forceRecast ok")
            await kickClient.stop()
        }
    }

    private func cachedCastDevice() -> CastDevice? {
        let serviceName = settingsManager.castSelectedDeviceServiceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let host = settingsManager.castSelectedDeviceHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceName.isEmpty, !host.isEmpty else { return nil }
        guard settingsManager.castSelectedDeviceSupportsDisplay else { return nil }
        return CastDevice(
            serviceName: serviceName,
            friendlyName: settingsManager.castSelectedDeviceFriendlyName.isEmpty
                ? serviceName
                : settingsManager.castSelectedDeviceFriendlyName,
            host: host,
            port: settingsManager.castSelectedDevicePort > 0
                ? settingsManager.castSelectedDevicePort
                : 8009,
            model: settingsManager.castSelectedDeviceModel.isEmpty
                ? "Cast Device"
                : settingsManager.castSelectedDeviceModel,
            identifier: settingsManager.castSelectedDeviceIdentifier.isEmpty
                ? serviceName
                : settingsManager.castSelectedDeviceIdentifier,
            supportsDisplay: true
        )
    }

    /// The URL the watchdog asks the Hub to load. Prefer the live
    /// bridge URL (which already incorporates port fallback) and rewrite
    /// loopback to LAN so the Hub can actually reach it. Falls back to
    /// the persisted dashboard URL.
    ///
    /// Whenever we resolve to a different URL than what's persisted —
    /// usually because the Mac's DHCP lease shifted and the stored host
    /// is stale — we update settings so the iPhone / Settings UI / next
    /// app launch all see the correct value. This is the recovery path
    /// for the "stuck on DashCast splash" failure mode where the Hub is
    /// loading a URL that no longer resolves to this Mac.
    private func preferredCastURL() -> URL? {
        let resolved: URL?
        if let live = resolvedDashboardURL() {
            resolved = CastActionsListener.castableDashboardURL(from: live.absoluteString)
        } else {
            resolved = CastActionsListener.castableDashboardURL(from: settingsManager.smartHubQuotaDashboardURL)
        }
        guard let resolved else { return nil }
        let persisted = settingsManager.smartHubQuotaDashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if persisted != resolved.absoluteString {
            Self.log.info(
                "preferredCastURL: rewriting persisted dashboard URL \(persisted, privacy: .public) -> \(resolved.absoluteString, privacy: .public)"
            )
            settingsManager.smartHubQuotaDashboardURL = resolved.absoluteString
            // Keep companion endpoints (refresh hook, voice-refresh) in
            // sync with the new host so the iPhone "Speak Now" /
            // "Refresh Now" buttons hit this Mac instead of a stale IP.
            if var base = URLComponents(url: resolved, resolvingAgainstBaseURL: false) {
                base.path = "/refresh"
                if let refreshURL = base.url {
                    settingsManager.smartHubQuotaRefreshURL = refreshURL.absoluteString
                }
                base.path = "/voice-refresh"
                if let voiceURL = base.url {
                    settingsManager.smartHubQuotaVoiceRefreshURL = voiceURL.absoluteString
                }
            }
        }
        return resolved
    }
}
