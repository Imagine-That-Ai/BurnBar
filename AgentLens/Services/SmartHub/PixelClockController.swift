import Foundation
import Network
import OpenBurnBarCore
import OSLog

@MainActor
final class PixelClockAgentStatusStore {
    static let shared = PixelClockAgentStatusStore()
    static let didChangeNotification = Notification.Name("PixelClockAgentStatusStore.didChange")

    private struct Entry {
        var runningCount: Int = 0
        var lastTerminalStatus: PixelClockAgentStatus?
        var terminalAt: Date?
    }

    private var entries: [String: Entry] = [:]
    private let terminalTTL: TimeInterval = 5 * 60

    func markRunning(provider: AgentProvider) {
        let key = provider.persistedToken
        var entry = entries[key] ?? Entry()
        entry.runningCount += 1
        entry.lastTerminalStatus = nil
        entry.terminalAt = nil
        entries[key] = entry
        notifyChanged()
    }

    func markCompleted(providerID: String) {
        markTerminal(providerID: providerID, status: .completed)
    }

    func markFailed(providerID: String) {
        markTerminal(providerID: providerID, status: .failed)
    }

    func markFinished(provider: AgentProvider, failed: Bool) {
        let key = provider.persistedToken
        var entry = entries[key] ?? Entry()
        entry.runningCount = max(0, entry.runningCount - 1)
        if entry.runningCount == 0 {
            entry.lastTerminalStatus = failed ? .failed : .completed
            entry.terminalAt = Date()
        }
        entries[key] = entry
        notifyChanged()
    }

    func snapshot(now: Date = Date()) -> [String: PixelClockAgentStatus] {
        entries.compactMapValues { entry in
            if entry.runningCount > 0 { return .running }
            guard let status = entry.lastTerminalStatus,
                  let terminalAt = entry.terminalAt,
                  now.timeIntervalSince(terminalAt) <= terminalTTL else {
                return nil
            }
            return status
        }
    }

    func snapshotIncludingExternalProcesses(now: Date = Date()) async -> [String: PixelClockAgentStatus] {
        var statuses = snapshot(now: now)
        for (providerID, status) in await PixelClockExternalAgentActivityScanner.runningStatuses() {
            statuses[providerID] = status
        }
        return statuses
    }

    private func markTerminal(providerID: String, status: PixelClockAgentStatus) {
        let key = providerID.lowercased().replacingOccurrences(of: " ", with: "")
        var entry = entries[key] ?? Entry()
        entry.runningCount = 0
        entry.lastTerminalStatus = status
        entry.terminalAt = Date()
        entries[key] = entry
        notifyChanged()
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

private enum PixelClockExternalAgentActivityScanner {
    private static let cache = PixelClockExternalAgentActivityScanCache()

    /// Scans the `ps` table to detect when external coding agents are
    /// running so the pixel clock can flash their lane indicators.
    ///
    /// IMPORTANT: must NEVER be called from the main thread synchronously.
    /// `AgentCLIProcessClassifier.liveProcessLines()` spawns `/bin/ps`
    /// and `waitUntilExit()`s, which blocks for tens of milliseconds.
    /// When that block lands on the MainActor (e.g. via a
    /// `PixelClockController` heartbeat tick), it halts *every* other
    /// `@MainActor` Task — including the SmartHub bridge listener's
    /// `.ready` callback and incoming HTTP connection handlers — and
    /// the Nest Hub silently fails to render.
    static func runningStatuses() async -> [String: PixelClockAgentStatus] {
        await cache.runningStatuses()
    }

    fileprivate static func scanRunningStatuses() async -> [String: PixelClockAgentStatus]? {
        // House `/bin/ps` (blocking) runs off the main actor here:
        // `scanRunningStatuses` is `nonisolated` `async`, so awaiting it leaves
        // the caller's actor onto the generic executor (SE-0338). See the
        // off-main warning on `runningStatuses()` above.
        let lines = AgentCLIProcessClassifier.liveProcessLines()
        return PixelClockAgentProcessDetector.statusesOrUnknown(fromProcessLines: lines)
    }
}

private actor PixelClockExternalAgentActivityScanCache {
    private var lastScanAt: Date = .distantPast
    private var lastStatuses: [String: PixelClockAgentStatus] = [:]
    private var inFlight: Task<[String: PixelClockAgentStatus]?, Never>?
    private let minimumScanInterval: TimeInterval = 3

    func runningStatuses(now: Date = Date()) async -> [String: PixelClockAgentStatus] {
        if now.timeIntervalSince(lastScanAt) < minimumScanInterval {
            return lastStatuses
        }
        if let inFlight {
            return await inFlight.value ?? lastStatuses
        }
        let task = Task { await PixelClockExternalAgentActivityScanner.scanRunningStatuses() }
        inFlight = task
        let statuses = await task.value
        if let statuses {
            lastStatuses = statuses
        }
        lastScanAt = now
        inFlight = nil
        return lastStatuses
    }
}

enum PixelClockAgentProcessDetector {
    /// Blocking `/bin/ps` work runs off the main actor (`nonisolated` `async`, SE-0338).
    static func runningStatuses() async -> [String: PixelClockAgentStatus] {
        statuses(fromProcessLines: AgentCLIProcessClassifier.liveProcessLines())
    }

    static func statuses(fromPSOutput output: String) -> [String: PixelClockAgentStatus] {
        statuses(fromProcessLines: AgentCLIProcessClassifier.processLines(fromPSOutput: output))
    }

    static func statuses(fromProcessLines lines: [String]) -> [String: PixelClockAgentStatus] {
        lines.reduce(into: [:]) { statuses, line in
            guard let provider = AgentCLIProcessClassifier.provider(forProcessLine: line) else { return }
            statuses[provider.persistedToken] = .running
        }
    }

    /// `nil` means `/bin/ps` failed or timed out — keep the last
    /// Pixel Clock snapshot instead of painting every lane idle.
    static func statusesOrUnknown(fromProcessLines lines: [String]) -> [String: PixelClockAgentStatus]? {
        if AgentCLIProcessClassifier.isUnknownProcessSnapshot(lines) { return nil }
        return statuses(fromProcessLines: lines)
    }
}

@MainActor
final class PixelClockController {
    static let awtrixLightFlasherURL = PixelClockSetupResult.awtrixLightFlasherURL
    private static let logger = Logger(subsystem: "com.openburnbar.app", category: "PixelClock")
    private static let sentinelRepublishInterval: TimeInterval = 5 * 60

    private let settingsManager: SettingsManager
    private let quotaService: ProviderQuotaService?
    private let client: AWTRIXClient
    private let flasher: PixelClockFirmwareFlasher
    private let stockSimulator: PixelClockStockSimulatorServer

    private var heartbeatTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputController: PixelClockInputController?
    private var statusObserver: NSObjectProtocol?
    private var lastPushedConfig: PixelClockConfig?
    private var lastPushedPayloadSignature: String?
    private var lastPushAt: Date = .distantPast
    private var lastAppliedDeviceSettingsSignature: String?
    private var lastAppliedDeviceSettingsAt: Date = .distantPast
    private var lastBackgroundDiscoverySweepAt: Date = .distantPast
    /// Tracks the host/port we last published the input sentinel apps to so a
    /// host change (DHCP shuffle, manual reconfig) re-publishes them; otherwise
    /// the device would still answer Left/Right with stale openburnbar_btn_*
    /// pages from a previous run.
    private var lastSentinelHostSignature: String?
    private var lastSentinelPublishedAt: Date = .distantPast
    /// Bumped each time a heartbeat push throws so diagnostics can distinguish
    /// a single reboot miss from a persistent connectivity failure.
    private var consecutivePushFailures: Int = 0

    init(
        settingsManager: SettingsManager,
        quotaService: ProviderQuotaService?,
        client: AWTRIXClient = AWTRIXClient(),
        flasher: PixelClockFirmwareFlasher = PixelClockFirmwareFlasher(),
        stockSimulator: PixelClockStockSimulatorServer = .shared
    ) {
        self.settingsManager = settingsManager
        self.quotaService = quotaService
        self.client = client
        self.flasher = flasher
        self.stockSimulator = stockSimulator
    }

    func start() {
        guard !OpenBurnBarRuntime.isRunningTests else {
            Self.logger.info("Pixel Clock controller start skipped under XCTest")
            return
        }
        // Only bind the LAN listener when Pixel Clock is actually set up.
        //
        // This used to run unconditionally, so every launch opened an
        // all-interfaces NWListener on :7001 and macOS raised the Local Network
        // permission dialog at users who had never touched Pixel Clock. The
        // stock-firmware path still starts the server on demand in
        // `configureStockSimulator` (below), which is the only moment a real
        // Ulanzi device has been pointed at this Mac.
        if settingsManager.pixelClockConfig.enabled {
            stockSimulator.start()
        } else {
            stockSimulator.stop()
        }
        heartbeatTask?.cancel()
        inputTask?.cancel()
        Self.logger.info("Pixel Clock controller started; enabled=\(self.settingsManager.pixelClockConfig.enabled, privacy: .public) host=\(self.settingsManager.pixelClockConfig.host, privacy: .public)")
        lastPushedConfig = nil
        lastPushedPayloadSignature = nil
        lastPushAt = .distantPast
        lastSentinelHostSignature = nil
        lastSentinelPublishedAt = .distantPast

        let client = self.client
        let pushNow: @MainActor () async -> Void = { [weak self] in
            self?.lastPushedPayloadSignature = nil
            await self?.pushIfNeeded(force: true)
        }
        let returnToBurnBar: @MainActor (PixelClockConfig) async -> Void = { config in
            try? await client.switchToApp(name: "\(PixelClockQuotaRenderer.appName)0", config: config) // try?-ok(device display switch)
        }
        inputController = PixelClockInputController(
            settingsManager: settingsManager,
            quotaService: quotaService,
            client: client,
            pushPixelClockNow: pushNow,
            returnToBurnBar: returnToBurnBar
        )

        heartbeatTask = Task { [weak self] in
            var forceNextPush = true
            while !Task.isCancelled {
                guard let self else { return }
                guard self.settingsManager.pixelClockConfig.enabled else {
                    // Disabled: make sure we are not holding the :7001 LAN
                    // listener open, so a user who turns Pixel Clock off stops
                    // being a local-network listener too.
                    self.stockSimulator.stop()
                    try? await Task.sleep(nanoseconds: 60_000_000_000) // try?-ok(sleep cancellation)
                    forceNextPush = true
                    continue
                }
                // `start()` binds the listener only when Pixel Clock was already
                // enabled at launch, and nothing re-invokes it when the user flips
                // the toggle later. Reconciling here keeps enabling-after-launch
                // working without putting the bind back on the cold path.
                self.stockSimulator.start()
                await self.pushIfNeeded(force: forceNextPush)
                forceNextPush = false
                // After a successful push we normally tick every 5 s, but
                // accelerate to a 1.5 s cadence whenever an agent is running
                // so the working spinner animates instead of freezing on a
                // single frame for the full heartbeat. After failures we
                // apply a short exponential backoff (starting at 1.5 s) so a
                // clock that just rebooted or briefly dropped wifi recovers
                // in seconds — without pegging the loop when the device is
                // genuinely gone.
                let working = await self.hasWorkingActivity()
                let sleep = self.heartbeatSleepNanoseconds(working: working)
                try? await Task.sleep(nanoseconds: sleep) // try?-ok(sleep cancellation)
            }
        }

        // A one-second healthy poll keeps hardware-button sentinels responsive
        // without maintaining the former 400 ms HTTP hot loop. Nil app names
        // back off further so stock firmware and offline clocks stay quiet.
        inputTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let config = self.settingsManager.pixelClockConfig
                guard config.enabled else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // try?-ok(sleep cancellation)
                    continue
                }
                if self.shouldBackOffInputPolling(for: config) {
                    try? await Task.sleep(nanoseconds: self.offlineInputPollNanoseconds()) // try?-ok(sleep cancellation)
                    continue
                }
                let appName = await self.client.currentAppName(
                    config: config,
                    timeout: config.lastProbeStatus == .awtrixReady ? 1.0 : 2.0
                )
                if appName != nil, config.lastProbeStatus != .awtrixReady {
                    self.updateProbeStatus(.awtrixReady)
                }
                await self.inputController?.ingest(currentAppName: appName, config: config)
                // try?-ok(sleep cancellation)
                try? await Task.sleep(
                    nanoseconds: Self.inputPollNanoseconds(hasAppName: appName != nil)
                )
            }
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: PixelClockAgentStatusStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastPushedPayloadSignature = nil
                await self?.pushIfNeeded(force: true)
            }
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        inputTask?.cancel()
        inputTask = nil
        inputController = nil
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
            self.statusObserver = nil
        }
    }

    @discardableResult
    func probePixelClock() async -> AWTRIXClient.ProbeResult {
        let discovery = await resolveReachablePixelClockConfig()
        return discovery.probe
    }

    func testPixelClock() async throws {
        let discovery = await resolveReachablePixelClockConfig()
        let config = discovery.config
        let result = discovery.probe
        if result.status == .stockUlanziFirmware {
            let page = PixelClockRenderedPage(
                text: "OPENBURNBAR READY",
                color: config.palette.primaryHex,
                durationSeconds: config.clampedPageDuration,
                progress: 12,
                scrollSpeed: config.clampedScrollSpeed
            )
            stockSimulator.update(pages: [page], config: config)
            updateProbeStatus(.stockUlanziFirmware)
            return
        }
        guard result.status == .awtrixReady else {
            updateProbeStatus(result.status)
            throw NSError(domain: "PixelClockController", code: 1, userInfo: [
                NSLocalizedDescriptionKey: result.message
            ])
        }
        let page = PixelClockRenderedPage(
            text: "OPENBURNBAR READY",
            color: config.palette.primaryHex,
            durationSeconds: config.clampedPageDuration,
            progress: 12,
            scrollSpeed: config.clampedScrollSpeed
        )
        // Keep Test fail-visible. `/api/notify` is transient; disabling
        // native apps here can leave the physical clock blank after the
        // notification expires. Native apps are suppressed only after the
        // persistent OpenBurnBar custom page lands in `pushPixelClockNow`.
        try await client.testNotify(page: page, config: config)
        updateProbeStatus(.awtrixReady)
    }

    func preparePixelClock() async throws -> PixelClockSetupResult {
        let discovery = await resolveReachablePixelClockConfig()
        var config = discovery.config
        let result = discovery.probe

        switch result.status {
        case .awtrixReady:
            try await client.applyBrightnessIfNeeded(config: config)
            updateProbeStatus(.awtrixReady)
            return PixelClockSetupResult(
                mode: .awtrixLightReady,
                probeStatus: .awtrixReady,
                message: "AWTRIX Light is ready. OpenBurnBar can push directly to \(config.host).",
                clockHost: config.host
            )
        case .stockUlanziFirmware:
            guard let macHost = LocalNetworkDiscovery.preferredLANIPv4Address() else {
                updateProbeStatus(.stockUlanziFirmware)
                return PixelClockSetupResult(
                    mode: .needsAwtrixLightFlash,
                    probeStatus: .stockUlanziFirmware,
                    message: "Stock Ulanzi firmware is reachable, but this Mac does not have a LAN IPv4 address to use for Awtrix Simulator. Flash AWTRIX Light for direct OpenBurnBar control.",
                    clockHost: config.host,
                    flasherURL: Self.awtrixLightFlasherURL
                )
            }
            try await client.configureStockSimulator(config: config, serverHost: macHost, serverPort: 7001)
            config.lastProbeStatus = .stockUlanziFirmware
            config.updatedAt = Date()
            settingsManager.pixelClockConfig = config
            stockSimulator.start(port: 7001)
            await updateStockSimulatorPages(config: config)
            return PixelClockSetupResult(
                mode: .stockSimulatorConfigured,
                probeStatus: .stockUlanziFirmware,
                message: "Stock Ulanzi firmware is ready. OpenBurnBar is serving Pixel Clock frames from this Mac at \(macHost):7001.",
                clockHost: config.host,
                suggestedServerHost: macHost,
                suggestedServerPort: 7001
            )
        case .unknown, .unreachable:
            updateProbeStatus(result.status)
            let serialDiagnostics = await flasher.serialDiagnostics()
            if serialDiagnostics.hasClockCandidate {
                return PixelClockSetupResult(
                    mode: .needsAwtrixLightFlash,
                    probeStatus: result.status,
                    message: "Pixel Clock is not on Wi-Fi yet. OpenBurnBar found a USB setup port and can flash AWTRIX, send Wi-Fi, and push the display.",
                    clockHost: config.host,
                    flasherURL: Self.awtrixLightFlasherURL
                )
            }
            if let setupSSID = await PixelClockNetworkProvisioner.visibleSetupSSID() {
                return PixelClockSetupResult(
                    mode: .needsAwtrixLightFlash,
                    probeStatus: result.status,
                    message: "AWTRIX setup Wi-Fi \(setupSSID) is visible, but OpenBurnBar will not send Wi-Fi credentials to an unverified setup network. Connect the Pixel Clock over USB and run Flash and Finish Setup, or use the manual flasher.",
                    clockHost: config.host,
                    flasherURL: Self.awtrixLightFlasherURL,
                    setupSSID: setupSSID
                )
            }
            return PixelClockSetupResult(
                mode: .unreachable,
                probeStatus: result.status,
                message: result.message == AWTRIXClient.localNetworkBlockedMessage
                    ? result.message
                    : "No Pixel Clock found at \(config.host). \(serialDiagnostics.setupGuidance)",
                clockHost: config.host
            )
        case .unsupported, .error:
            updateProbeStatus(result.status)
            return PixelClockSetupResult(
                mode: .unreachable,
                probeStatus: result.status,
                message: result.message,
                clockHost: config.host,
                flasherURL: Self.awtrixLightFlasherURL
            )
        }
    }

    func flashPixelClockFirmware(wifiCredentials: PixelClockWiFiCredentials? = nil) async throws -> PixelClockSetupResult {
        let flashResult = try await flasher.flash()
        var provisionedHost: String?
        if let wifiCredentials {
            provisionedHost = try await PixelClockNetworkProvisioner(
                setupSSID: flashResult.setupSSID,
                setupNetworkTrust: .usbFlashDerived
            )
                .provision(credentials: wifiCredentials)
            var config = settingsManager.pixelClockConfig
            config.host = provisionedHost ?? config.host
            config.updatedAt = Date()
            settingsManager.pixelClockConfig = config
        }
        try await Task.sleep(nanoseconds: 5_000_000_000)
        let setup = try await preparePixelClock()
        if setup.probeStatus == .awtrixReady {
            try await pushPixelClockNow()
            return PixelClockSetupResult(
                mode: .awtrixLightReady,
                probeStatus: .awtrixReady,
                message: "Flashed AWTRIX \(flashResult.firmwareVersion), joined Wi-Fi, and pushed OpenBurnBar.",
                clockHost: setup.clockHost
            )
        }
        return PixelClockSetupResult(
            mode: .needsAwtrixLightFlash,
            probeStatus: setup.probeStatus,
            message: provisionedHost == nil
                ? "Flashed AWTRIX \(flashResult.firmwareVersion). Enter Wi-Fi to finish setup."
                : "Flashed AWTRIX \(flashResult.firmwareVersion) and sent Wi-Fi, but the clock did not answer on \(provisionedHost ?? setup.clockHost) yet.",
            clockHost: provisionedHost ?? setup.clockHost
        )
    }

    func pushPixelClockNow(force: Bool = true) async throws {
        var config = settingsManager.pixelClockConfig
        guard config.enabled else { return }

        let now = Date()
        let statuses = await PixelClockAgentStatusStore.shared.snapshotIncludingExternalProcesses(now: now)
        let hasRunningActivity = statuses.values.contains(.running)
        let items = PixelClockSnapshotAdapter.quotaCycleItems(
            quotaService: quotaService,
            statuses: statuses
        )
        let pages: [PixelClockRenderedPage]
        if config.isMuted(at: now) {
            // Snooze gesture from the device's Select button — show a single
            // dim "muted" pixel until mutedUntil expires so the device is
            // visibly silenced without us pushing fresh quota frames.
            pages = [
                PixelClockRenderedPage(
                    text: "",
                    color: "#202020",
                    durationSeconds: max(3, config.clampedPageDuration),
                    scrollSpeed: config.clampedScrollSpeed,
                    draw: [.fillRect(x: 15, y: 3, width: 2, height: 2, color: "#202020")]
                )
            ]
        } else {
            pages = PixelClockQuotaRenderer.renderPages(
                items: items,
                config: config,
                now: now,
                isWorking: hasRunningActivity
            )
        }
        let payload = PixelClockQuotaRenderer.awtrixPayload(pages: pages, config: config)
        let activePageIndex = Self.activePageIndex(
            pageCount: payload.count,
            at: now,
            pageDuration: config.clampedPageDuration
        )
        let activePayload = payload.indices.contains(activePageIndex) ? [payload[activePageIndex]] : payload
        let activePayloadBody = try Self.payloadBody(activePayload)
        let payloadSignature = String(data: activePayloadBody, encoding: .utf8)
        let activeAppName = await client.currentAppName(config: config)
        let clockNeedsRepush = activeAppName.map { !Self.isManagedPixelClockAppName($0) } ?? true
        // When an agent is running we want each heartbeat to land on the
        // clock so the spinner can advance frames. The dedupe below would
        // otherwise hold off pushes whenever the spinner tick produced the
        // same signature as the previous push, which kept the spinner
        // frozen on stale pixels for the entire `pageDuration` window.
        let minimumRepeatInterval = hasRunningActivity
            ? 0
            : TimeInterval(max(3, config.clampedPageDuration))
        if !force,
           !hasRunningActivity,
           !clockNeedsRepush,
           config == lastPushedConfig,
           payloadSignature == lastPushedPayloadSignature,
           Date().timeIntervalSince(lastPushAt) < minimumRepeatInterval {
            return
        }

        // Lower LED draw before sending a rendered frame. The TC001 can
        // brown out or reboot when it receives a dense custom bitmap while
        // brightness is still high, especially from marginal USB power. This
        // preflight is intentionally brightness-only; native app disablement
        // still happens after a successful frame lands so the hardware never
        // goes blank because a settings write failed.
        try? await client.applyBrightnessIfNeeded(config: config) // try?-ok(best-effort brightness preflight)

        do {
            try await client.pushCustomApp(body: activePayloadBody, config: config)
        } catch {
            // Push to the stored host failed. Try full discovery (configured
            // host retry -> Bonjour -> active LAN netmask sweep). If we find
            // the clock at a new address, persist the new host and re-push so
            // the user sees content within the same heartbeat tick instead of
            // waiting for the next cycle. This is the recovery path that
            // matters when DHCP shuffles the clock, the clock reboots, or the
            // user power-cycles via USB.
            let discovery = await resolvePixelClockConfigAfterPushFailure(forceFullDiscovery: force)
            config = discovery.config
            if discovery.probe.status == .stockUlanziFirmware {
                config.lastProbeStatus = .stockUlanziFirmware
                config.updatedAt = Date()
                settingsManager.pixelClockConfig = config
                await updateStockSimulatorPages(config: config)
                lastPushAt = Date()
                lastPushedConfig = config
                lastPushedPayloadSignature = nil
                return
            }
            guard discovery.probe.status == .awtrixReady else { throw error }
            Self.logger.info(
                "Pixel Clock recovered via discovery at host=\(config.host, privacy: .public); retrying push"
            )
            try await client.pushCustomApp(body: activePayloadBody, config: config)
        }

        // Keep the clock fail-visible. Native AWTRIX apps are disabled only
        // after OpenBurnBar has successfully landed a custom frame; otherwise a
        // transient HTTP 500 can leave the hardware with every visible app off.
        await applyDeviceSettingsIfNeeded(
            config: config,
            activeAppName: activeAppName,
            now: now
        )

        lastPushAt = now
        lastPushedConfig = config
        lastPushedPayloadSignature = payloadSignature
        await publishSentinelAppsIfNeeded(config: config, now: now)
        try? await client.switchToApp(name: "\(PixelClockQuotaRenderer.appName)0", config: config) // try?-ok(device display switch)
        let runningProviderTokens = statuses
            .filter { $0.value == .running }
            .keys
            .sorted()
            .joined(separator: ",")
        Self.logger.info("Pixel Clock pushed openburnbar0 page=\(activePageIndex, privacy: .public) count=\(payload.count, privacy: .public) working=\(hasRunningActivity, privacy: .public) running=[\(runningProviderTokens, privacy: .public)] layout=\(config.layout.rawValue, privacy: .public)")
        updateProbeStatus(.awtrixReady)
    }

    private func publishSentinelAppsIfNeeded(config: PixelClockConfig, now: Date = Date()) async {
        let signature = "\(config.host.lowercased()):\(config.clampedPort)"
        let stale = now.timeIntervalSince(lastSentinelPublishedAt) >= Self.sentinelRepublishInterval
        guard signature != lastSentinelHostSignature || stale else { return }
        do {
            try await client.pushSentinelApps(config: config)
            lastSentinelHostSignature = signature
            lastSentinelPublishedAt = now
        } catch {
            Self.logger.error("Failed to publish Pixel Clock sentinel apps: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removePixelClockApp() async throws {
        let discovery = await resolveReachablePixelClockConfig()
        let config = discovery.config
        let result = discovery.probe
        if result.status == .stockUlanziFirmware {
            stockSimulator.clear()
            lastPushedConfig = nil
            updateProbeStatus(.stockUlanziFirmware)
            return
        }
        guard result.status == .awtrixReady else {
            updateProbeStatus(result.status)
            throw NSError(domain: "PixelClockController", code: 3, userInfo: [
                NSLocalizedDescriptionKey: result.message
            ])
        }
        try await client.removeCustomApp(config: config)
        lastPushedConfig = nil
    }

    func notifyAgentCompletion(providerID: String, providerName: String, modelName: String? = nil) async {
        let current = settingsManager.pixelClockConfig
        guard current.enabled else { return }
        guard current.completionClockSoundEnabled || current.completionLocalNotificationsEnabled else { return }
        PixelClockAgentStatusStore.shared.markCompleted(providerID: providerID)
        let completionLabel = Self.completionLabel(providerName: providerName, modelName: modelName)

        let item = PixelClockQuotaItem(
            providerID: providerID,
            providerName: providerName,
            percentUsed: 100,
            usageText: "done",
            windowLabel: "ok",
            agentStatus: .completed
        )
        let renderedDraw = PixelClockQuotaRenderer.renderPages(
            items: [item],
            config: current,
            isWorking: false
        ).first?.draw ?? []
        let page = PixelClockRenderedPage(
            text: "\(completionLabel) DONE",
            color: current.palette.primaryHex,
            durationSeconds: 4,
            progress: 100,
            scrollSpeed: current.clampedScrollSpeed,
            draw: renderedDraw
        )

        let discovery = await resolveReachablePixelClockConfig()
        let config = discovery.config
        if discovery.probe.status == .stockUlanziFirmware {
            stockSimulator.update(pages: [page], config: config)
            lastPushAt = Date()
            lastPushedConfig = config
            return
        }

        guard discovery.probe.status == .awtrixReady else { return }
        try? await client.testNotify( // try?-ok(fire-and-forget notification)
            page: page,
            config: config,
            sound: current.completionClockSoundEnabled
                ? PixelClockCompletionSoundResolver.soundName(
                    providerID: providerID,
                    providerName: providerName,
                    modelName: modelName
                )
                : nil
        )
    }

    /// One-click repair for the physical Pixel Clock.
    ///
    /// This intentionally does not flash firmware or join the AWTRIX setup
    /// Wi-Fi in the background. Those steps can temporarily disconnect the
    /// Mac from the network, so repair reports `needsUserAction` with the
    /// exact setup path instead of surprising the user.
    func repairPixelClockDisplay(
        progress: ((SmartDisplayDeviceRepairStatus) -> Void)? = nil
    ) async -> SmartDisplayDeviceRepairStatus {
        func emit(
            _ phase: SmartDisplayRepairPhase,
            _ message: String,
            proof: String? = nil
        ) -> SmartDisplayDeviceRepairStatus {
            let status = SmartDisplayDeviceRepairStatus(
                kind: .pixelClock,
                phase: phase,
                message: message,
                proof: proof
            )
            progress?(status)
            return status
        }

        let current = settingsManager.pixelClockConfig
        guard current.enabled else {
            return emit(.skipped, "Pixel Clock is turned off in OpenBurnBar.", proof: "disabled")
        }

        do {
            _ = emit(.detecting, "Finding the Pixel Clock on Wi-Fi, Bonjour, or the saved host.")
            let setup = try await preparePixelClock()
            switch setup.mode {
            case .awtrixLightReady:
                _ = emit(.repairing, "Pushing the latest OpenBurnBar frame to AWTRIX.", proof: setup.clockHost)
                try await pushPixelClockNow(force: true)
                return emit(.working, "Pixel Clock is showing OpenBurnBar.", proof: setup.clockHost)

            case .stockSimulatorConfigured:
                _ = emit(.waitingForProof, "Waiting for the stock Ulanzi clock to connect to the Mac simulator.", proof: "\(setup.suggestedServerHost ?? ""):\(setup.suggestedServerPort ?? 7001)")
                await updateStockSimulatorPages(config: settingsManager.pixelClockConfig)
                if await waitForStockSimulatorClient(timeout: 18) {
                    return emit(.working, "Stock Ulanzi clock is connected to the OpenBurnBar simulator.", proof: "stock_simulator_client_connected")
                }
                return emit(
                    .needsUserAction,
                    "OpenBurnBar configured the simulator, but the clock has not connected. Keep the clock on wall power and confirm Awtrix Simulator points to this Mac.",
                    proof: "stock_simulator_no_client"
                )

            case .needsAwtrixLightFlash, .needsWiFiProvisioning:
                return emit(.needsUserAction, setup.message, proof: setup.mode.rawValue)

            case .unreachable:
                return emit(.needsUserAction, setup.message, proof: "clock_unreachable")
            }
        } catch {
            return emit(.failed, error.localizedDescription, proof: "pixel_clock_repair_error")
        }
    }

    private func pushIfNeeded(force: Bool = false) async {
        let config = settingsManager.pixelClockConfig
        guard config.enabled else {
            Self.logger.info("Pixel Clock heartbeat skipped because integration is disabled")
            return
        }
        let interval = TimeInterval(min(config.clampedUpdateInterval, max(3, config.clampedPageDuration)))
        let configChanged = config != lastPushedConfig
        let hasExternalAgentWork = !(await PixelClockExternalAgentActivityScanner.runningStatuses()).isEmpty
        guard force || hasExternalAgentWork || configChanged || Date().timeIntervalSince(lastPushAt) >= interval else { return }
        Self.logger.info("Pixel Clock push tick force=\(force, privacy: .public) configChanged=\(configChanged, privacy: .public) externalWork=\(hasExternalAgentWork, privacy: .public)")
        do {
            try await pushPixelClockNow(force: force)
            consecutivePushFailures = 0
        } catch {
            consecutivePushFailures = min(consecutivePushFailures + 1, 16)
            Self.logger.error(
                "Pixel Clock push failed (failure #\(self.consecutivePushFailures, privacy: .public)) host=\(self.settingsManager.pixelClockConfig.host, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Heartbeat sleep budget. Healthy clocks tick every 5 s, or every 1.5 s
    /// when an agent is currently working so the spinner can animate. After
    /// failures (clock rebooting, wifi dropped, DHCP shuffle) we use
    /// exponential backoff from 1.5 s up to 30 s so recovery is fast when
    /// the device returns.
    func heartbeatSleepNanoseconds(working: Bool = false) -> UInt64 {
        if consecutivePushFailures > 0 {
            let exponent = Double(min(consecutivePushFailures - 1, 4))
            let seconds = max(1.5, min(pow(2.0, exponent), 30.0))
            return UInt64(seconds * 1_000_000_000)
        }
        return working ? 1_500_000_000 : 5_000_000_000
    }

    private func shouldBackOffInputPolling(for config: PixelClockConfig) -> Bool {
        switch config.lastProbeStatus {
        case .awtrixReady:
            return false
        case .stockUlanziFirmware:
            return true
        case .unknown, .unreachable, .unsupported, .error:
            return consecutivePushFailures > 0
        }
    }

    static func inputPollNanoseconds(hasAppName: Bool) -> UInt64 {
        hasAppName ? 1_000_000_000 : 2_000_000_000
    }

    private func offlineInputPollNanoseconds() -> UInt64 {
        let exponent = Double(min(max(consecutivePushFailures - 1, 0), 4))
        let seconds = max(5.0, min(pow(2.0, exponent) * 5.0, 60.0))
        return UInt64(seconds * 1_000_000_000)
    }

    /// True whenever the agent-status store reports a running agent (either
    /// from OpenBurnBar's CLI bridge or the external `/bin/ps` scanner).
    /// Used by the heartbeat to decide between the fast spinner cadence and
    /// the idle five-second heartbeat.
    func hasWorkingActivity() async -> Bool {
        guard settingsManager.pixelClockConfig.enabled else { return false }
        let statuses = await PixelClockAgentStatusStore.shared.snapshotIncludingExternalProcesses()
        return statuses.values.contains(.running)
    }

    private func updateStockSimulatorPages(config: PixelClockConfig) async {
        let statuses = await PixelClockAgentStatusStore.shared.snapshotIncludingExternalProcesses()
        let hasRunningActivity = statuses.values.contains(.running)
        let items = PixelClockSnapshotAdapter.quotaCycleItems(
            quotaService: quotaService,
            statuses: statuses
        )
        let pages = PixelClockQuotaRenderer.renderPages(
            items: items,
            config: config,
            now: Date(),
            isWorking: hasRunningActivity
        )
        stockSimulator.update(pages: pages, config: config)
    }

    private func waitForStockSimulatorClient(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stockSimulator.connectedClientCount > 0 {
                return true
            }
            try? await Task.sleep(nanoseconds: 300_000_000) // try?-ok(sleep cancellation)
        }
        return false
    }

    private func resolveReachablePixelClockConfig(
        scope: AWTRIXClient.DiscoveryScope = .fullSubnet
    ) async -> AWTRIXClient.DiscoveryResult {
        let discovery = await client.discover(
            config: settingsManager.pixelClockConfig,
            scope: scope
        )
        var config = discovery.config
        config.lastProbeStatus = discovery.probe.status
        config.updatedAt = Date()
        settingsManager.pixelClockConfig = config
        return AWTRIXClient.DiscoveryResult(config: config, probe: discovery.probe)
    }

    private func resolvePixelClockConfigAfterPushFailure(forceFullDiscovery: Bool) async -> AWTRIXClient.DiscoveryResult {
        let now = Date()
        let discoveryCooldown: TimeInterval = 90
        if forceFullDiscovery || now.timeIntervalSince(lastBackgroundDiscoverySweepAt) >= discoveryCooldown {
            lastBackgroundDiscoverySweepAt = now
            return await resolveReachablePixelClockConfig(scope: .configuredAndBonjour)
        }
        return await resolveConfiguredPixelClockConfig()
    }

    private func resolveConfiguredPixelClockConfig() async -> AWTRIXClient.DiscoveryResult {
        var config = settingsManager.pixelClockConfig
        Self.logger.info("Pixel Clock probing configured host \(config.host, privacy: .public):\(config.clampedPort, privacy: .public)")
        let probe = await client.probe(config: config)
        Self.logger.info("Pixel Clock configured probe status=\(probe.status.rawValue, privacy: .public)")
        config.lastProbeStatus = probe.status
        config.updatedAt = Date()
        settingsManager.pixelClockConfig = config
        return AWTRIXClient.DiscoveryResult(config: config, probe: probe)
    }

    private func updateProbeStatus(_ status: PixelClockProbeStatus) {
        var config = settingsManager.pixelClockConfig
        config.lastProbeStatus = status
        config.updatedAt = Date()
        settingsManager.pixelClockConfig = config
    }

    private func applyDeviceSettingsIfNeeded(
        config: PixelClockConfig,
        activeAppName: String?,
        now: Date
    ) async {
        let signature = Self.deviceSettingsSignature(config)
        let activeAppNeedsTakeover = activeAppName.map { !Self.isManagedPixelClockAppName($0) } ?? false
        let settingsAreStale = now.timeIntervalSince(lastAppliedDeviceSettingsAt) > 900
        guard activeAppNeedsTakeover ||
              signature != lastAppliedDeviceSettingsSignature ||
              settingsAreStale else {
            return
        }

        // AWTRIX settings can transiently return HTTP 500 while custom app
        // pushes still work. Treat settings as best-effort so the clock never
        // stays blank just because brightness/native-app cleanup failed.
        try? await client.applyBrightnessIfNeeded(config: config) // try?-ok(best-effort device settings)
        try? await client.disableAwtrixNativeApps(config: config) // try?-ok(best-effort device settings)
        lastAppliedDeviceSettingsSignature = signature
        lastAppliedDeviceSettingsAt = now
    }

    private static func completionLabel(providerName: String, modelName: String?) -> String {
        guard let modelName = modelName?.trimmingCharacters(in: .whitespacesAndNewlines), !modelName.isEmpty else {
            return providerName
        }
        return modelName
    }

    private static func isManagedPixelClockAppName(_ appName: String) -> Bool {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(PixelClockQuotaRenderer.appName) else { return false }
        let suffix = trimmed.dropFirst(PixelClockQuotaRenderer.appName.count)
        return suffix.isEmpty || suffix.allSatisfy(\.isNumber)
    }

    private static func deviceSettingsSignature(_ config: PixelClockConfig) -> String {
        [
            config.host.trimmingCharacters(in: .whitespacesAndNewlines),
            "\(config.clampedPort)",
            config.clampedBrightness.map(String.init) ?? "auto"
        ].joined(separator: "|")
    }

    private static func activePageIndex(pageCount: Int, at date: Date, pageDuration: Int) -> Int {
        guard pageCount > 1 else { return 0 }
        let duration = max(pageDuration, 1)
        let tick = Int(date.timeIntervalSince1970) / duration
        return tick % pageCount
    }

    private static func payloadBody(_ payload: [[String: Any]]) throws -> Data {
        let activePage = payload.first ?? [:]
        guard JSONSerialization.isValidJSONObject(activePage) else {
            throw AWTRIXClient.ClientError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: activePage, options: [.sortedKeys])
    }
}

enum PixelClockCompletionSoundResolver {
    static func soundName(providerID: String, providerName: String, modelName: String? = nil) -> String {
        if let modelSound = soundName(forModelName: modelName) {
            return modelSound
        }
        let token = normalize("\(providerID) \(providerName)")
        if containsAny(token, ["factory", "droid"]) { return "droid" }
        if containsAny(token, ["codex", "openai", "open-ai"]) { return "codex" }
        if token.contains("claude") { return "claude" }
        if token.contains("cursor") { return "cursor" }
        if containsAny(token, ["minimax", "mini-max"]) { return "minimax" }
        if containsAny(token, ["z.ai", "zai", "z-ai"]) { return "zai" }
        return "notify"
    }

    static func provider(forModelName modelName: String?) -> AgentProvider? {
        guard let modelName = modelName?.trimmingCharacters(in: .whitespacesAndNewlines), !modelName.isEmpty else {
            return nil
        }
        let token = normalize(modelName)
        if containsAny(token, ["gpt", "o1", "o3", "o4", "codex"]) { return .codex }
        if containsAny(token, ["claude", "sonnet", "opus", "haiku"]) { return .claudeCode }
        if containsAny(token, ["minimax", "mini-max", "m2.7", "abab"]) { return .minimax }
        if containsAny(token, ["glm", "zai", "z.ai", "z-ai", "zhipu", "bigmodel"]) { return .zai }
        if containsAny(token, ["kimi", "moonshot", "k2"]) { return .kimi }
        if containsAny(token, ["ollama", "llama", "qwen", "mistral"]) { return .ollama }
        return nil
    }

    private static func soundName(forModelName modelName: String?) -> String? {
        guard let provider = provider(forModelName: modelName) else { return nil }
        switch provider {
        case .codex, .openAI:
            return "codex"
        case .claudeCode:
            return "claude"
        case .minimax:
            return "minimax"
        case .zai:
            return "zai"
        case .factory:
            return "droid"
        case .cursor:
            return "cursor"
        default:
            return nil
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ token: String, _ needles: [String]) -> Bool {
        needles.contains { token.contains($0) }
    }
}

// MARK: - Stock Ulanzi AWTRIX Simulator

@MainActor
final class PixelClockStockSimulatorServer {
    static let shared = PixelClockStockSimulatorServer()

    private(set) var isRunning = false
    private(set) var boundPort: UInt16?
    private(set) var connectedClientCount = 0

    private var listener: NWListener?
    private var sessions: [UUID: PixelClockStockSimulatorSession] = [:]
    private var latestFrameCommandSets: [[Data]] = [PixelClockStockSimulatorFrameEncoder.blankFrameCommands()]
    private var latestPageDurations: [TimeInterval] = [5]
    private var currentPageIndex = 0
    private var pageCycler: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.openburnbar.pixelclock.stock-simulator")

    func start(port: UInt16 = 7001) {
        if isRunning, boundPort == port { return }
        stop()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            isRunning = false
            boundPort = nil
            listener = nil
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { @MainActor in
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.boundPort = port
                    case .failed, .cancelled:
                        self.isRunning = false
                        self.boundPort = nil
                        self.listener = nil
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            isRunning = false
            boundPort = nil
            listener = nil
        }
    }

    func stop() {
        pageCycler?.cancel()
        pageCycler = nil
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
        connectedClientCount = 0
        listener?.cancel()
        listener = nil
        isRunning = false
        boundPort = nil
    }

    func update(pages: [PixelClockRenderedPage], config: PixelClockConfig) {
        latestFrameCommandSets = PixelClockStockSimulatorFrameEncoder.commandSets(for: pages, config: config)
        latestPageDurations = pages.isEmpty ? [5] : pages.map { TimeInterval(max($0.durationSeconds, 1)) }
        currentPageIndex = 0
        publishLatestFrame()
        restartPageCyclerIfNeeded()
    }

    func clear() {
        pageCycler?.cancel()
        pageCycler = nil
        latestFrameCommandSets = [PixelClockStockSimulatorFrameEncoder.blankFrameCommands()]
        latestPageDurations = [5]
        currentPageIndex = 0
        publishLatestFrame()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let session = PixelClockStockSimulatorSession(
            id: id,
            connection: connection,
            queue: queue,
            onClose: { [weak self] closedID in
                Task { @MainActor in
                    self?.removeSession(id: closedID)
                }
            },
            onSubscribe: { [weak self] subscribedID in
                Task { @MainActor in
                    self?.publishLatestFrame(to: subscribedID)
                }
            }
        )
        sessions[id] = session
        connectedClientCount = sessions.count
        session.start()
    }

    private func removeSession(id: UUID) {
        sessions[id] = nil
        connectedClientCount = sessions.count
    }

    private func publishLatestFrame(to id: UUID? = nil) {
        let targets: [PixelClockStockSimulatorSession]
        if let id, let session = sessions[id] {
            targets = [session]
        } else {
            targets = Array(sessions.values)
        }
        for session in targets where session.isSubscribed {
            let commands = latestFrameCommandSets.indices.contains(currentPageIndex)
                ? latestFrameCommandSets[currentPageIndex]
                : PixelClockStockSimulatorFrameEncoder.blankFrameCommands()
            for command in commands {
                session.publish(topic: PixelClockStockMQTT.matrixTopic, payload: command)
            }
        }
    }

    private func restartPageCyclerIfNeeded() {
        pageCycler?.cancel()
        guard latestFrameCommandSets.count > 1 else {
            pageCycler = nil
            return
        }
        pageCycler = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.latestPageDurations.indices.contains(self.currentPageIndex)
                    ? self.latestPageDurations[self.currentPageIndex]
                    : 5
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 1) * 1_000_000_000)) // try?-ok(sleep cancellation)
                guard !Task.isCancelled else { return }
                self.currentPageIndex = (self.currentPageIndex + 1) % max(self.latestFrameCommandSets.count, 1)
                self.publishLatestFrame()
            }
        }
    }
}

@MainActor
private final class PixelClockStockSimulatorSession {
    let id: UUID
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onClose: @Sendable (UUID) -> Void
    private let onSubscribe: @Sendable (UUID) -> Void
    private var buffer = Data()
    private(set) var isSubscribed = false
    private var isClosed = false

    init(
        id: UUID,
        connection: NWConnection,
        queue: DispatchQueue,
        onClose: @escaping @Sendable (UUID) -> Void,
        onSubscribe: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.connection = connection
        self.queue = queue
        self.onClose = onClose
        self.onSubscribe = onSubscribe
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self.close() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func stop() {
        close()
    }

    func publish(topic: String, payload: Data) {
        send(PixelClockStockMQTT.publish(topic: topic, payload: payload))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.consumeBufferedPackets()
                }
                if isComplete || error != nil {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func consumeBufferedPackets() {
        while let packet = PixelClockStockMQTT.nextPacket(from: &buffer) {
            handle(packet)
        }
    }

    private func handle(_ packet: PixelClockStockMQTT.Packet) {
        switch packet.type {
        case .connect:
            send(PixelClockStockMQTT.connack())
        case .subscribe:
            isSubscribed = true
            send(PixelClockStockMQTT.suback(packetIdentifier: packet.packetIdentifier ?? 1))
            onSubscribe(id)
        case .pingreq:
            send(PixelClockStockMQTT.pingresp())
        case .disconnect:
            close()
        case .publish, .unknown:
            break
        }
    }

    private func send(_ data: Data) {
        guard !isClosed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error != nil else { return }
            Task { @MainActor in self.close() }
        })
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose(id)
    }
}
