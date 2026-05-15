import AppKit
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

    /// One-click repair for the Google Nest Hub / DashCast path.
    ///
    /// Success is proof-driven: a Cast receiver ACK alone is not enough.
    /// The Hub must load our page and poll `/state.json` after the cast
    /// command, otherwise the common "stuck on DashCast splash" state would
    /// be misreported as healthy.
    func repairNestHubDisplay(
        progress: ((SmartDisplayDeviceRepairStatus) -> Void)? = nil
    ) async -> SmartDisplayDeviceRepairStatus {
        func emit(
            _ phase: SmartDisplayRepairPhase,
            _ message: String,
            proof: String? = nil
        ) -> SmartDisplayDeviceRepairStatus {
            let status = SmartDisplayDeviceRepairStatus(
                kind: .nestHub,
                phase: phase,
                message: message,
                proof: proof
            )
            progress?(status)
            return status
        }

        _ = emit(.detecting, "Starting the Mac bridge and checking the saved Nest Hub.")
        settingsManager.smartHubQuotaDisplayEnabled = true
        applySettings()
        healServerIfNeeded()
        await waitForBridgeReady(timeout: 6)
        await pumpSnapshot()

        guard SmartHubBridgeServer.shared.isRunning else {
            return emit(
                .needsUserAction,
                "Mac bridge is not running. Check Local Network permission and retry.",
                proof: "bridge_not_running"
            )
        }
        guard let url = preferredCastURL() else {
            return emit(
                .needsUserAction,
                "OpenBurnBar could not build a LAN URL for this Mac. Connect the Mac to Wi-Fi and retry.",
                proof: "missing_lan_url"
            )
        }
        guard let device = await resolveCastDeviceForRepair() else {
            return emit(
                .needsUserAction,
                "No display-capable Google Cast device was found. Wake the Nest Hub and keep it on the same Wi-Fi.",
                proof: "cast_device_not_found"
            )
        }
        persistCastDevice(device)

        _ = emit(.repairing, "Casting OpenBurnBar to \(device.friendlyName).", proof: url.absoluteString)
        let pollBaseline = SmartHubBridgeServer.shared.lastClientPollAt
        let strategy = CastReconnectStrategy(
            device: device,
            homeAssistantWebhookURL: homeAssistantRecoveryWebhookURL()
        )
        let outcome = await strategy.castWithRecovery(url: url)
        switch outcome {
        case .success, .recoveredViaHomeAssistant:
            break
        case .failure(let reason, _):
            return emit(.failed, "Couldn't cast to \(device.friendlyName): \(reason)", proof: "cast_failed")
        }

        _ = emit(.waitingForProof, "Waiting for the Nest Hub page to prove it loaded.")
        if await waitForClientPoll(after: pollBaseline, timeout: 24) {
            return emit(.working, "\(device.friendlyName) is showing OpenBurnBar.", proof: "state_json_polled")
        }

        _ = emit(.repairing, "DashCast accepted the command but did not load the page. Recasting from a clean session.")
        let recastBaseline = SmartHubBridgeServer.shared.lastClientPollAt
        let recastClient = CastChannelClient(device: device)
        let recast = await recastClient.forceRecast(url: url)
        recastClient.disconnect()
        switch recast {
        case .success:
            if await waitForClientPoll(after: recastBaseline, timeout: 24) {
                return emit(.working, "\(device.friendlyName) recovered and is showing OpenBurnBar.", proof: "state_json_polled_after_recast")
            }
            return emit(
                .failed,
                "DashCast launched, but the Hub never loaded OpenBurnBar. Reboot the Hub or check Wi-Fi client isolation.",
                proof: "no_state_json_poll"
            )
        case .failure(let reason):
            return emit(.failed, "Recast failed: \(reason)", proof: "force_recast_failed")
        case .timeout:
            return emit(.failed, "Recast timed out while waiting for the Hub.", proof: "force_recast_timeout")
        }
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

    private func waitForBridgeReady(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SmartHubBridgeServer.shared.isRunning { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func waitForClientPoll(after baseline: Date, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SmartHubBridgeServer.shared.lastClientPollAt > baseline {
                return true
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func resolveCastDeviceForRepair() async -> CastDevice? {
        if let cached = cachedCastDevice() {
            let client = CastChannelClient(device: cached)
            let state = await client.queryReceiverState()
            client.disconnect()
            if state != nil {
                return cached
            }
        }

        let devices = await collectCastDevicesOnce(duration: 8)
            .filter(\.supportsDisplay)
        if let selected = devices.first(where: { matchesCachedCastDevice($0) }) {
            return selected
        }
        return Self.preferredRepairCastDevice(from: devices)
    }

    static func preferredRepairCastDevice(from devices: [CastDevice]) -> CastDevice? {
        devices
            .filter(\.supportsDisplay)
            .sorted { lhs, rhs in
                let lhsScore = repairDeviceScore(lhs)
                let rhsScore = repairDeviceScore(rhs)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.friendlyName.localizedCaseInsensitiveCompare(rhs.friendlyName) == .orderedAscending
            }
            .first
    }

    private static func repairDeviceScore(_ device: CastDevice) -> Int {
        let combined = "\(device.model) \(device.friendlyName) \(device.serviceName)".lowercased()
        var score = 0
        if combined.contains("nest hub max") {
            score += 90
        } else if combined.contains("nest hub") {
            score += 120
        }
        if combined.contains("display") { score += 20 }
        if combined.contains("chromecast") { score += 10 }
        if combined.contains("mini") || combined.contains("audio") || combined.contains("speaker") {
            score -= 100
        }
        return score
    }

    private func collectCastDevicesOnce(duration: TimeInterval) async -> [CastDevice] {
        await CastDiscovery.discoverOnce(duration: duration)
    }

    private func matchesCachedCastDevice(_ device: CastDevice) -> Bool {
        let serviceName = settingsManager.castSelectedDeviceServiceName
        let identifier = settingsManager.castSelectedDeviceIdentifier
        return (!serviceName.isEmpty && device.serviceName.caseInsensitiveCompare(serviceName) == .orderedSame)
            || (!identifier.isEmpty && device.identifier.caseInsensitiveCompare(identifier) == .orderedSame)
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

    private func homeAssistantRecoveryWebhookURL() -> URL? {
        let raw = settingsManager.smartHubHomeAssistantRecoveryWebhookURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
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
        let now = Date()
        let runCostTotals = runCostTotalsForPeriod(period, now: now)
        let quotaProviders = quotaProviders(period: period, runCostTotals: runCostTotals, now: now)
        let runCostTotals5h = runCostTotalsForPeriod(.rolling5h, now: now)
        let runCostTotals7d = runCostTotalsForPeriod(.rolling7d, now: now)
        let burnProviders = burnProviders(
            period: period,
            runCostTotals: runCostTotals,
            runCostTotals5h: runCostTotals5h,
            runCostTotals7d: runCostTotals7d,
            now: now
        )
        let providers = quotaProviders + burnProviders
        let aggregateSpend = runCostTotals.values.reduce(0.0) { $0 + $1.totalCost }
        let aggregateTokens = runCostTotals.values.reduce(0) { $0 + $1.totalTokens }

        let totalText: String
        if providers.isEmpty {
            totalText = "—"
        } else if aggregateSpend > 0 {
            totalText = Self.currencyFormatter.string(from: NSNumber(value: aggregateSpend))
                ?? "$\(Int(aggregateSpend))"
        } else {
            totalText = "\(providers.count) tracked"
        }

        let headerFormatter = DateFormatter()
        headerFormatter.dateFormat = "EEE, MMM d  h:mm a"
        let headerTimestamp = headerFormatter.string(from: now)

        let subFormatter = DateFormatter()
        subFormatter.timeStyle = .short

        let totalTokensText = aggregateTokens > 0
            ? Self.formatValueAbbreviation(Double(aggregateTokens), unit: .tokens)
            : ""

        return SmartHubBridgeSnapshot(
            totalSpend: totalText,
            totalTokens: totalTokensText,
            headline: providers.isEmpty
                ? "Waiting on the first refresh"
                : "Showing \(period.displayName.lowercased())",
            subheadline: "Updated at \(subFormatter.string(from: now))",
            providers: providers,
            headerTimestamp: headerTimestamp,
            headerStatus: providers.isEmpty ? "" : "live provider pressure"
        )
    }

    /// Pulls per-provider run/cost totals for the dashboard's active time
    /// period. Wrapped in a try? — the bridge can render without footer
    /// metrics if the DB read fails, so we don't take the whole pipeline
    /// down on a transient SQLite blip.
    private func runCostTotalsForPeriod(
        _ period: SmartHubTimePeriod,
        now: Date
    ) -> [AgentProvider: ProviderRunCostTotals] {
        guard let dataStore else { return [:] }
        let range = Self.dateRange(for: period, now: now)
        return (try? dataStore.usageStore.providerRunCostTotals(in: range)) ?? [:]
    }

    /// Iterate the providers OpenBurnBar tracks; for each, populate a
    /// full card payload (multiple buckets, account chips, run/cost
    /// footer, brand accent, freshness pill). Falls back to the legacy
    /// single-bucket shape when the rich data isn't available so the
    /// device never goes blank.
    private func quotaProviders(
        period: SmartHubTimePeriod,
        runCostTotals: [AgentProvider: ProviderRunCostTotals],
        now: Date
    ) -> [SmartHubBridgeSnapshot.Provider] {
        guard let quotaService else { return [] }

        return AgentProvider.allCases.compactMap { provider -> SmartHubBridgeSnapshot.Provider? in
            // We aggregate across all accounts. A provider with no account
            // snapshots at all is dropped — there's nothing meaningful to
            // render on its card.
            let accountSnapshots = quotaService.snapshots(for: provider)
            guard let primary = quotaService.snapshot(for: provider) ?? accountSnapshots.first else {
                return nil
            }

            // Primary bucket drives the legacy `percent` / `label` /
            // `windowLabel` fields so older readers (NestHubMiniPreview,
            // serialization tests) keep working.
            let primaryBucket = Self.bestBucket(in: primary, for: period) ?? primary.primaryDisplayableBucket
            let primaryPercent = primaryBucket.map { Int(($0.progressFraction * 100).rounded()) } ?? 0
            let primaryTone = Self.tone(for: primaryPercent)
            let primaryLabel = primaryBucket?.usageText ?? primary.statusMessage
            let primaryWindowLabel = primaryBucket.map(Self.windowLabel(for:)) ?? ""

            // Rich card pieces.
            let buckets = Self.bridgeBuckets(from: primary.displayableQuotaBuckets, tone: Self.tone)
            let accounts = Self.bridgeAccounts(
                for: provider,
                snapshots: accountSnapshots,
                primary: primary,
                routingState: quotaService.routingState(for: provider.providerID)
            )
            let tokenTotal = Self.bridgeTokenTotal(buckets: primary.displayableQuotaBuckets)
            let footer = runCostTotals[provider]
            let tokenTotalCurrency = Self.bridgeTokenTotalCurrency(totalCost: footer?.totalCost ?? 0)
            let statusPill = Self.bridgeStatusPill(snapshot: primary, now: now)
            let statusTone = Self.statusPillTone(snapshot: primary, now: now)
            let freshness = Self.bridgeFreshnessLabel(fetchedAt: primary.fetchedAt, now: now)
            let absoluteFetched = Self.bridgeAbsoluteTimestamp(primary.fetchedAt)
            let runsLabel = Self.bridgeRunsLabel(footer?.sessionCount ?? 0)
            let costLabel = Self.bridgeCostLabel(footer?.totalCost ?? 0)

            return SmartHubBridgeSnapshot.Provider(
                name: provider.displayName,
                percent: primaryPercent,
                label: primaryLabel,
                tone: primaryTone,
                windowLabel: primaryWindowLabel,
                slug: provider.persistedToken,
                accentHex: Self.accentHex(for: provider),
                logoSVG: Self.logoSVG(for: provider),
                tokenTotal: tokenTotal,
                tokenTotalCurrency: tokenTotalCurrency,
                tokenTotalLabel: "TOKENS",
                statusPill: statusPill,
                statusTone: statusTone,
                freshnessLabel: freshness,
                fetchedAtLabel: absoluteFetched,
                buckets: buckets,
                accounts: accounts,
                runsLabel: runsLabel,
                costLabel: costLabel,
                hasQuotaData: true,
                burnRates: []
            )
        }
    }

    /// Providers with no quota snapshots but with usage history. These render
    /// as burn-rate cards showing 5h and 7d token/cost/run totals instead of
    /// quota bucket bars.
    private func burnProviders(
        period: SmartHubTimePeriod,
        runCostTotals: [AgentProvider: ProviderRunCostTotals],
        runCostTotals5h: [AgentProvider: ProviderRunCostTotals],
        runCostTotals7d: [AgentProvider: ProviderRunCostTotals],
        now: Date
    ) -> [SmartHubBridgeSnapshot.Provider] {
        guard let quotaService else { return [] }

        let allTracked = Set(runCostTotals.keys)
            .union(runCostTotals5h.keys)
            .union(runCostTotals7d.keys)

        return AgentProvider.allCases.compactMap { provider -> SmartHubBridgeSnapshot.Provider? in
            // Skip providers that already have quota data.
            let accountSnapshots = quotaService.snapshots(for: provider)
            guard accountSnapshots.isEmpty else { return nil }

            // Skip providers with no usage at all.
            guard allTracked.contains(provider) else { return nil }

            let footer = runCostTotals[provider]
            let tokenTotal = Self.bridgeTokenTotal(from: footer)
            let tokenTotalCurrency = Self.bridgeTokenTotalCurrency(totalCost: footer?.totalCost ?? 0)
            let runsLabel = Self.bridgeRunsLabel(footer?.sessionCount ?? 0)
            let costLabel = Self.bridgeCostLabel(footer?.totalCost ?? 0)

            let burnRates: [SmartHubBridgeSnapshot.Provider.BurnRate] = [
                Self.burnRate(for: provider, totals: runCostTotals5h, windowLabel: "5h"),
                Self.burnRate(for: provider, totals: runCostTotals7d, windowLabel: "7d")
            ].compactMap { $0 }

            return SmartHubBridgeSnapshot.Provider(
                name: provider.displayName,
                percent: 0,
                label: "",
                tone: .mercury,
                windowLabel: "",
                slug: provider.persistedToken,
                accentHex: Self.accentHex(for: provider),
                logoSVG: Self.logoSVG(for: provider),
                tokenTotal: tokenTotal,
                tokenTotalCurrency: tokenTotalCurrency,
                tokenTotalLabel: "TOKENS",
                statusPill: "no quota",
                statusTone: .mercury,
                freshnessLabel: "",
                fetchedAtLabel: "",
                buckets: [],
                accounts: [],
                runsLabel: runsLabel,
                costLabel: costLabel,
                hasQuotaData: false,
                burnRates: burnRates
            )
        }
    }

    // MARK: - Rich snapshot helpers

    /// Maps `SmartHubTimePeriod` → a `ClosedRange<Date>` for the SQL
    /// query that powers the footer's run-count / cost numbers. Rolling
    /// windows anchor to `now` so the numbers move with the dashboard.
    private static func dateRange(for period: SmartHubTimePeriod, now: Date) -> ClosedRange<Date> {
        let hours = period.spanHours
        let start = now.addingTimeInterval(-hours * 3600)
        return start...now
    }

    private static func bridgeTokenTotalCurrency(totalCost: Double) -> String {
        guard totalCost > 0 else { return "" }
        return formatValueAbbreviation(totalCost, unit: .currency)
    }

    private static func bridgeTokenTotal(from totals: ProviderRunCostTotals?) -> String {
        guard let totals, totals.totalTokens > 0 else { return "" }
        return formatValueAbbreviation(Double(totals.totalTokens), unit: .tokens)
    }

    private static func burnRate(
        for provider: AgentProvider,
        totals: [AgentProvider: ProviderRunCostTotals],
        windowLabel: String
    ) -> SmartHubBridgeSnapshot.Provider.BurnRate? {
        guard let t = totals[provider], t.totalTokens > 0 || t.totalCost > 0 || t.sessionCount > 0 else {
            return nil
        }
        return SmartHubBridgeSnapshot.Provider.BurnRate(
            windowLabel: windowLabel,
            tokens: t.totalTokens > 0 ? formatValueAbbreviation(Double(t.totalTokens), unit: .tokens) : "—",
            cost: t.totalCost > 0 ? formatValueAbbreviation(t.totalCost, unit: .currency) : "—",
            runs: t.sessionCount > 0 ? "\(t.sessionCount) runs" : "0 runs"
        )
    }

    private static func bridgeBuckets(
        from buckets: [ProviderQuotaBucket],
        tone: (Int) -> SmartHubBridgeSnapshot.Provider.Tone
    ) -> [SmartHubBridgeSnapshot.Provider.Bucket] {
        buckets.prefix(4).map { bucket -> SmartHubBridgeSnapshot.Provider.Bucket in
            let percent = Int((bucket.progressFraction * 100).rounded())
            return SmartHubBridgeSnapshot.Provider.Bucket(
                name: bucket.label,
                percent: percent,
                headlineValue: bridgeBucketHeadline(bucket),
                subLabel: bridgeBucketSubLabel(bucket),
                resetsLabel: bridgeBucketResetsLabel(bucket),
                tone: tone(percent)
            )
        }
    }

    /// Right-hand value next to each bar (e.g. "33%", "350.8M", "$400.00").
    /// Mirrors the visual hierarchy of the mock: the *headline value* is
    /// the number the user actually cares about for that window, not the
    /// usage ratio.
    private static func bridgeBucketHeadline(_ bucket: ProviderQuotaBucket) -> String {
        // Tokens / requests bucket: surface the absolute used count when
        // we have it (e.g. "350.8M tokens"), otherwise the percent.
        switch bucket.unit {
        case .tokens, .requests, .currency:
            if let used = bucket.usedValue, used > 0 {
                return formatValueAbbreviation(used, unit: bucket.unit)
            }
            if let percent = bucket.usedPercent {
                return "\(Int(percent.rounded()))%"
            }
        case .percent:
            if let percent = bucket.usedPercent {
                return "\(Int(percent.rounded()))%"
            }
        case .sessions, .lines, .files, .count:
            if let used = bucket.usedValue {
                return formatValueAbbreviation(used, unit: bucket.unit)
            }
        }
        return ""
    }

    /// Sub-label rendered under each bar — now always the headroom
    /// summary ("67% left", "$0.00 left"). The reset moment got promoted
    /// to its own dedicated row (see `bridgeBucketResetsLabel`) because
    /// folding it into the sub-label cost too much glance-readability on
    /// the Nest Hub.
    private static func bridgeBucketSubLabel(_ bucket: ProviderQuotaBucket) -> String {
        if let remaining = bucket.remainingPercent {
            return "\(Int(remaining.rounded()))% left"
        }
        if let remainingValue = bucket.remainingValue, bucket.unit == .currency {
            return "$\(String(format: "%.2f", remainingValue)) left"
        }
        return ""
    }

    /// Combined relative+absolute reset string ("in 2h 14m · May 8, 3:35
    /// AM") rendered as its own row beneath each bucket bar on the Nest
    /// Hub. Empty string when the bucket has no `resetsAt` so the page
    /// can drop the row entirely.
    private static func bridgeBucketResetsLabel(_ bucket: ProviderQuotaBucket) -> String {
        guard let pair = bucket.resetsAtDisplay else { return "" }
        return "Resets \(pair.relative) · \(pair.absolute)"
    }

    /// Abbreviated number formatter that matches the visual style of the
    /// mock ("5.4B", "42.0B", "113.2M", "$400.00").
    private static func formatValueAbbreviation(_ value: Double, unit: ProviderQuotaUnit) -> String {
        if unit == .currency {
            return currencyFormatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
        }
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return "\(Int(value.rounded()))"
    }

    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static func bridgeAccounts(
        for provider: AgentProvider,
        snapshots: [ProviderQuotaSnapshot],
        primary: ProviderQuotaSnapshot,
        routingState: ProviderRoutingStateSnapshot?
    ) -> [SmartHubBridgeSnapshot.Provider.Account] {
        // Coalesce by accountID so a provider exposing the same account
        // twice (cloud + local mirror) only renders one chip.
        var seen: Set<String> = []
        let activeAccountID = routingState?.activeAccount?.accountID

        return snapshots.compactMap { snap -> SmartHubBridgeSnapshot.Provider.Account? in
            let id = snap.accountID ?? snap.accountLabel ?? snap.sourceId
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let label = snap.accountLabel ?? snap.accountID ?? "Default"
            let isActive = activeAccountID == snap.accountID
            let (badge, tone) = accountBadge(for: snap, isActive: isActive, primary: primary)
            let accountBuckets = Self.bridgeBuckets(from: snap.displayableQuotaBuckets, tone: Self.tone).prefix(2)
            let accountPercent = snap.primaryDisplayableBucket.map {
                Int(($0.progressFraction * 100).rounded())
            } ?? 0
            return SmartHubBridgeSnapshot.Provider.Account(
                label: label,
                badge: badge,
                tone: tone,
                isActive: isActive,
                buckets: Array(accountBuckets),
                percent: accountPercent
            )
        }
    }

    /// Compute the chip badge ("MAIN" / "ACTIVE" / "CLI" / "LOCAL") for
    /// one account snapshot. We mirror the on-Mac account-cockpit logic:
    /// the routing-active account wins; otherwise we badge by storage
    /// scope so the user can tell at a glance whether the account is a
    /// shared cloud credential or a local-only CLI handle.
    private static func accountBadge(
        for snap: ProviderQuotaSnapshot,
        isActive: Bool,
        primary: ProviderQuotaSnapshot
    ) -> (String, SmartHubBridgeSnapshot.Provider.Tone) {
        if isActive { return ("ACTIVE", .success) }
        switch snap.accountStorageScope {
        case .cloudRefreshable: return ("MAIN", .whimsy)
        case .deviceKeychain:   return ("CLI", .mercury)
        case .localOnly:        return ("LOCAL", .mercury)
        case .serverPrivate:    return ("SERVER", .ember)
        case .none:             return ("DEFAULT", .mercury)
        }
    }

    /// Build the short pill that appears under the provider name (e.g.
    /// "source 3h ago", "reset passed", "live local"). The pill is the
    /// fastest signal the user has that the card is healthy; tied to
    /// freshness + confidence + source kind.
    private static func bridgeStatusPill(snapshot: ProviderQuotaSnapshot, now: Date) -> String {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        if age < 60 { return "live" }
        if snapshot.confidence == .unavailable { return "unavailable" }
        if snapshot.confidence == .estimated { return "estimated" }
        switch snapshot.source {
        case .localCLI, .localSession: return "live local"
        case .officialAPI:
            return age > 6 * 3600 ? "source \(Int(age / 3600))h ago" : "source live"
        case .manualEstimate: return "manual"
        case .unavailable:    return "unavailable"
        }
    }

    private static func statusPillTone(
        snapshot: ProviderQuotaSnapshot,
        now: Date
    ) -> SmartHubBridgeSnapshot.Provider.Tone {
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        if snapshot.confidence == .unavailable { return .warning }
        if age < 5 * 60 { return .success }
        if age < 60 * 60 { return .whimsy }
        if age < 6 * 3600 { return .mercury }
        return .warning
    }

    /// Headline token count at the top of each card. Picks the biggest
    /// `usedValue` across token buckets so providers that expose multiple
    /// token windows ("5h" + "weekly") surface their dominant token number
    /// (matching how the mock renders "5.4B" for Claude, "42.0B" for Codex).
    /// Currency quota buckets intentionally do not feed this value; the page
    /// has a separate `tokenTotalCurrency` field for dollar mode.
    private static func bridgeTokenTotal(buckets: [ProviderQuotaBucket]) -> String {
        let tokenBuckets = buckets.filter { $0.unit == .tokens }
        let best = tokenBuckets.compactMap { bucket -> (Double, ProviderQuotaUnit)? in
            guard let used = bucket.usedValue, used > 0 else { return nil }
            return (used, bucket.unit)
        }.max { $0.0 < $1.0 }
        guard let best else { return "" }
        return formatValueAbbreviation(best.0, unit: best.1)
    }

    private static func bridgeFreshnessLabel(fetchedAt: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(fetchedAt))
        if elapsed < 60 { return "updated just now" }
        if elapsed < 3600 {
            return "updated \(Int(elapsed / 60))m ago"
        }
        if elapsed < 24 * 3600 {
            return "updated \(Int(elapsed / 3600))h ago"
        }
        return "updated \(Int(elapsed / 86_400))d ago"
    }

    private static func bridgeAbsoluteTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    private static func bridgeRunsLabel(_ count: Int) -> String {
        guard count > 0 else { return "" }
        if count >= 1000 {
            return "\(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)) runs"
        }
        return "\(count) runs"
    }

    private static func bridgeCostLabel(_ cost: Double) -> String {
        guard cost > 0 else { return "" }
        return currencyFormatter.string(from: NSNumber(value: cost)) ?? String(format: "$%.2f", cost)
    }

    /// Hex string (no leading `#`) for the provider's brand accent.
    /// Mirrors `DesignSystem.Colors.primary(for:)` — we keep the list
    /// inline rather than reaching into SwiftUI so this function is
    /// usable from non-UI contexts.
    private static func accentHex(for provider: AgentProvider) -> String {
        switch provider {
        case .factory:    return "8B5CF6"
        case .claudeCode: return "CC785C"
        case .copilot:    return "23EA3B"
        case .aider:      return "FF6B35"
        case .cursor:     return "AC8C57"
        case .openAI:     return "00A67E"
        case .codex:      return "00A67E"
        case .openCode:   return "00A67E"
        case .zai:        return "8B5CF6"
        case .minimax:    return "F59E0B"
        case .kimi:       return "6366F1"
        case .cline:      return "D4A373"
        case .kiloCode:   return "10B981"
        case .rooCode:    return "EC4899"
        case .forgeDev:   return "F97316"
        case .augment:    return "3B82F6"
        case .hermes:     return "A855F7"
        case .piAgent:    return "7C3AED"
        case .geminiCLI:  return "4285F4"
        case .goose:      return "0D9488"
        case .openClaw:   return "FF6B6B"
        case .ollama:     return "6B7280"
        case .windsurf:   return "06B6D4"
        case .warp:       return "DDE4EA"
        }
    }

    /// Inline HTML used as the provider logo on the Hub. We embed the
    /// bytes directly in the JSON (vs serving an asset endpoint) so the
    /// page renders without extra HTTP round-trips — the Nest Hub's
    /// DashCast surface caches the dashboard aggressively but not provider
    /// assets, so any external `<img src=…>` round-trip can fail silently.
    ///
    /// Preferred path: load the brand logo `*.imageset` already bundled
    /// with the app (e.g. `ClaudeCodeLogo`), render it to a 2x PNG, and
    /// inline as a `data:` URI. Falls back to the colored-monogram SVG
    /// for any provider that has no bundled asset.
    private static func logoSVG(for provider: AgentProvider) -> String {
        if let assetName = logoAssetName(for: provider),
           let dataURI = bundledLogoDataURI(named: assetName) {
            return "<img src='\(dataURI)' alt='' draggable='false' style='width:100%;height:100%;object-fit:contain;'/>"
        }
        return monogramSVG(for: provider)
    }

    private static func monogramSVG(for provider: AgentProvider) -> String {
        let initial = provider.displayName.first.map(String.init)?.uppercased() ?? "?"
        let hex = "#\(accentHex(for: provider))"
        return """
        <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 40 40' aria-hidden='true'><rect width='40' height='40' rx='10' fill='\(hex)'/><text x='50%' y='54%' text-anchor='middle' font-family='-apple-system,SF Pro Rounded,system-ui,sans-serif' font-size='22' font-weight='700' fill='white' dominant-baseline='middle'>\(initial)</text></svg>
        """
    }

    /// Map an `AgentProvider` to the imageset name already shipped in
    /// `AgentLens/Resources/Assets.xcassets/`. Keep Smart Hub aligned with
    /// the shared provider source of truth so provider-specific logos cannot
    /// drift from Settings, mobile, or dashboard surfaces.
    static func logoAssetName(for provider: AgentProvider) -> String? {
        provider.bundledLogoName
    }

    /// One-per-process cache so we only rasterize each bundled logo once.
    private static let logoDataURICache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 64
        return cache
    }()

    private static func bundledLogoDataURI(named name: String) -> String? {
        let key = name as NSString
        if let cached = logoDataURICache.object(forKey: key) {
            return cached as String
        }
        guard let image = NSImage(named: NSImage.Name(name)),
              let pngData = image.pngData(targetSize: NSSize(width: 80, height: 80))
        else {
            return nil
        }
        let dataURI = "data:image/png;base64," + pngData.base64EncodedString()
        logoDataURICache.setObject(dataURI as NSString, forKey: key)
        return dataURI
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

    private static func tone(for percent: Int) -> SmartHubBridgeSnapshot.Provider.Tone {
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
            probeClient.disconnect()
            return
        }
        Self.log.info("watchdog state appId=\(state.appId, privacy: .public) isDashCast=\(state.isDashCast)")

        // DashCast being the active receiver app is not enough to call
        // the display healthy. The common stuck state is exactly this:
        // the Hub sits on DashCast's splash after a dropped LOAD. Treat
        // the existing DashCast session as stale and do a STOP -> LAUNCH
        // -> LOAD recovery on the watchdog cadence.
        if state.isDashCast {
            probeClient.disconnect()

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
            refreshClient.disconnect()
            return
        }

        // Unhealthy case: another app is up (Backdrop, YouTube voice
        // shortcut, etc.) or nothing is running. Either way the Hub
        // isn't showing us — do a hard kick: STOP whatever's there and
        // launch DashCast fresh with force:true.
        probeClient.disconnect()
        lastCastReassertedAt = Date()

        Self.log.info("watchdog: hard kick (forceRecast) — current app is not DashCast")
        let kickClient = CastChannelClient(device: device)
        let outcome = await kickClient.forceRecast(url: url)
        if case .failure(let reason) = outcome {
            Self.log.error("watchdog: forceRecast failed: \(reason, privacy: .public). Falling back to reconnect strategy.")
            // If STOP→LAUNCH itself failed, fall through to the full
            // recovery strategy (4-attempt backoff + Home Assistant).
            kickClient.disconnect()
            _ = await CastReconnectStrategy(device: device).castWithRecovery(url: url)
        } else {
            Self.log.info("watchdog: forceRecast ok")
            kickClient.disconnect()
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

private extension NSImage {
    /// Rasterize this image into PNG bytes at the requested pixel size.
    /// Used by the SmartHub bridge to inline brand logos as `data:` URIs.
    func pngData(targetSize: NSSize) -> Data? {
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        guard width > 0, height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        return rep.representation(using: .png, properties: [:])
    }
}
