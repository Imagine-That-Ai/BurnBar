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
    /// `processLines()` spawns `/bin/ps` and `waitUntilExit()`s, which
    /// blocks for tens of milliseconds. When that block lands on the
    /// MainActor (e.g. via a `PixelClockController` heartbeat tick), it
    /// halts *every* other `@MainActor` Task — including the SmartHub
    /// bridge listener's `.ready` callback and incoming HTTP connection
    /// handlers — and the Nest Hub silently fails to render.
    static func runningStatuses() async -> [String: PixelClockAgentStatus] {
        await cache.runningStatuses()
    }

    fileprivate static func scanRunningStatuses() async -> [String: PixelClockAgentStatus] {
        let lines = await Task.detached(priority: .utility) {
            processLines()
        }.value
        guard !lines.isEmpty else { return [:] }

        var statuses: [String: PixelClockAgentStatus] = [:]
        func mark(_ provider: AgentProvider) {
            statuses[provider.persistedToken] = .running
        }

        for rawLine in lines {
            let line = rawLine.lowercased()
            guard isLikelyAgentWorkProcess(line) else { continue }
            if line.contains("codex") {
                mark(.codex)
            }
            if line.contains("claude") {
                mark(.claudeCode)
            }
            if line.contains("opencode") || line.contains("open-code") {
                mark(.openClaw)
            }
            if line.contains("factory") || line.contains("droid") {
                mark(.factory)
            }
            if line.contains("cursor") {
                mark(.cursor)
            }
        }
        return statuses
    }

    private static func isLikelyAgentWorkProcess(_ line: String) -> Bool {
        guard !line.contains("openburnbar") else { return false }
        guard !line.contains("xcodebuild") else { return false }
        guard !line.contains("cursoruiviewservice") else { return false }
        guard !line.contains("chrome-native-host") else { return false }
        guard !line.contains("cmux-agent-mcp") else { return false }
        guard !line.contains("droid.real daemon") else { return false }
        guard !line.contains(" droid daemon") else { return false }
        guard !line.contains("/usr/bin/grep") else { return false }
        guard !line.contains(" rg ") else { return false }
        guard !line.contains("pixelclockexternalagentactivityscanner") else { return false }
        return line.contains("codex")
            || line.contains("claude")
            || line.contains("opencode")
            || line.contains("open-code")
            || line.contains("factory")
            || line.contains("droid")
            || line.contains("cursor")
    }

    private static func processLines() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(1.0)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                return []
            }
            process.waitUntilExit()
        } catch {
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output
            .split(separator: "\n")
            .map(String.init)
    }
}

private actor PixelClockExternalAgentActivityScanCache {
    private var lastScanAt: Date = .distantPast
    private var lastStatuses: [String: PixelClockAgentStatus] = [:]
    private var inFlight: Task<[String: PixelClockAgentStatus], Never>?
    private let minimumScanInterval: TimeInterval = 3

    func runningStatuses(now: Date = Date()) async -> [String: PixelClockAgentStatus] {
        if now.timeIntervalSince(lastScanAt) < minimumScanInterval {
            return lastStatuses
        }
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await PixelClockExternalAgentActivityScanner.scanRunningStatuses() }
        inFlight = task
        let statuses = await task.value
        lastStatuses = statuses
        lastScanAt = now
        inFlight = nil
        return statuses
    }
}

@MainActor
final class PixelClockController {
    static let awtrixLightFlasherURL = "https://blueforcer.github.io/awtrix3/#/flasher"
    private static let logger = Logger(subsystem: "com.openburnbar.app", category: "PixelClock")

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
        stockSimulator.start()
        heartbeatTask?.cancel()
        inputTask?.cancel()
        Self.logger.info("Pixel Clock controller started; enabled=\(self.settingsManager.pixelClockConfig.enabled, privacy: .public) host=\(self.settingsManager.pixelClockConfig.host, privacy: .public)")
        lastPushedConfig = nil
        lastPushedPayloadSignature = nil
        lastPushAt = .distantPast
        lastSentinelHostSignature = nil

        let client = self.client
        let pushNow: @MainActor () async -> Void = { [weak self] in
            self?.lastPushedPayloadSignature = nil
            await self?.pushIfNeeded(force: true)
        }
        let returnToBurnBar: @MainActor (PixelClockConfig) async -> Void = { config in
            try? await client.switchToApp(name: "\(PixelClockQuotaRenderer.appName)0", config: config)
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
                try? await Task.sleep(nanoseconds: sleep)
            }
        }

        // Input poll runs at 400 ms cadence so a hardware-button press feels
        // immediate. We only poll when AWTRIX is reachable; on stock Ulanzi
        // firmware (which lacks /api/stats.app semantics) and when the clock
        // is unreachable, the loop sleeps a full second to avoid pegging the
        // network on a device that can't answer.
        inputTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let config = self.settingsManager.pixelClockConfig
                guard config.enabled, config.lastProbeStatus == .awtrixReady else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                let appName = await self.client.currentAppName(config: config, timeout: 1.0)
                await self.inputController?.ingest(currentAppName: appName, config: config)
                try? await Task.sleep(nanoseconds: 400_000_000)
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
            if let setupSSID = await PixelClockNetworkProvisioner.visibleSetupSSID() {
                return PixelClockSetupResult(
                    mode: .needsWiFiProvisioning,
                    probeStatus: result.status,
                    message: "AWTRIX setup Wi-Fi \(setupSSID) is visible. OpenBurnBar can send your Wi-Fi settings and push the display.",
                    clockHost: config.host,
                    setupSSID: setupSSID
                )
            }
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
            return PixelClockSetupResult(
                mode: .unreachable,
                probeStatus: result.status,
                message: "No Pixel Clock found at \(config.host). \(serialDiagnostics.setupGuidance)",
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
        if let setupSSID = await PixelClockNetworkProvisioner.visibleSetupSSID() {
            guard let wifiCredentials else {
                return PixelClockSetupResult(
                    mode: .needsWiFiProvisioning,
                    probeStatus: .unreachable,
                    message: "AWTRIX setup Wi-Fi \(setupSSID) is visible. Enter Wi-Fi to finish setup.",
                    clockHost: settingsManager.pixelClockConfig.host,
                    setupSSID: setupSSID
                )
            }
            return try await provisionSetupNetworkAndFinish(
                setupSSID: setupSSID,
                firmwareVersion: nil,
                wifiCredentials: wifiCredentials
            )
        }

        let flashResult = try await flasher.flash()
        var provisionedHost: String?
        if let wifiCredentials {
            provisionedHost = try await PixelClockNetworkProvisioner(setupSSID: flashResult.setupSSID)
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

    private func provisionSetupNetworkAndFinish(
        setupSSID: String,
        firmwareVersion: String?,
        wifiCredentials: PixelClockWiFiCredentials
    ) async throws -> PixelClockSetupResult {
        let provisionedHost = try await PixelClockNetworkProvisioner(setupSSID: setupSSID)
            .provision(credentials: wifiCredentials)
        var config = settingsManager.pixelClockConfig
        config.host = provisionedHost
        config.updatedAt = Date()
        settingsManager.pixelClockConfig = config

        try await Task.sleep(nanoseconds: 5_000_000_000)
        let setup = try await preparePixelClock()
        if setup.probeStatus == .awtrixReady {
            try await pushPixelClockNow()
            let prefix = firmwareVersion.map { "Flashed AWTRIX \($0), " } ?? ""
            return PixelClockSetupResult(
                mode: .awtrixLightReady,
                probeStatus: .awtrixReady,
                message: "\(prefix)joined Wi-Fi, and pushed OpenBurnBar.",
                clockHost: setup.clockHost
            )
        }
        return PixelClockSetupResult(
            mode: .needsWiFiProvisioning,
            probeStatus: setup.probeStatus,
            message: "Sent Wi-Fi to AWTRIX setup network \(setupSSID), but the clock did not answer on \(provisionedHost) yet.",
            clockHost: provisionedHost,
            setupSSID: setupSSID
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
        try? await client.applyBrightnessIfNeeded(config: config)

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
        await publishSentinelAppsIfNeeded(config: config)
        let runningProviderTokens = statuses
            .filter { $0.value == .running }
            .keys
            .sorted()
            .joined(separator: ",")
        Self.logger.info("Pixel Clock pushed openburnbar0 page=\(activePageIndex, privacy: .public) count=\(payload.count, privacy: .public) working=\(hasRunningActivity, privacy: .public) running=[\(runningProviderTokens, privacy: .public)] layout=\(config.layout.rawValue, privacy: .public)")
        updateProbeStatus(.awtrixReady)
    }

    private func publishSentinelAppsIfNeeded(config: PixelClockConfig) async {
        let signature = "\(config.host.lowercased()):\(config.clampedPort)"
        guard signature != lastSentinelHostSignature else { return }
        do {
            try await client.pushSentinelApps(config: config)
            lastSentinelHostSignature = signature
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
        try? await client.testNotify(
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

    /// True whenever the agent-status store reports a running agent (either
    /// from OpenBurnBar's CLI bridge or the external `/bin/ps` scanner).
    /// Used by the heartbeat to decide between the fast spinner cadence and
    /// the idle five-second heartbeat.
    func hasWorkingActivity() async -> Bool {
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
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func resolveReachablePixelClockConfig() async -> AWTRIXClient.DiscoveryResult {
        let discovery = await client.discover(config: settingsManager.pixelClockConfig)
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
            return await resolveReachablePixelClockConfig()
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
        try? await client.applyBrightnessIfNeeded(config: config)
        try? await client.disableAwtrixNativeApps(config: config)
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

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
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
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 1) * 1_000_000_000))
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

enum PixelClockStockMQTT {
    static let matrixTopic = "awtrixmatrix/a"

    enum PacketType {
        case connect
        case publish
        case subscribe
        case pingreq
        case disconnect
        case unknown
    }

    struct Packet: Equatable {
        var type: PacketType
        var body: Data
        var packetIdentifier: UInt16?
    }

    static func nextPacket(from buffer: inout Data) -> Packet? {
        guard buffer.count >= 2 else { return nil }
        let firstByte = buffer[buffer.startIndex]
        var multiplier = 1
        var value = 0
        var cursor = buffer.index(after: buffer.startIndex)
        var encodedLengthBytes = 0

        while true {
            guard cursor < buffer.endIndex, encodedLengthBytes < 4 else { return nil }
            let byte = Int(buffer[cursor])
            value += (byte & 127) * multiplier
            encodedLengthBytes += 1
            cursor = buffer.index(after: cursor)
            if (byte & 128) == 0 { break }
            multiplier *= 128
        }

        let headerLength = 1 + encodedLengthBytes
        let totalLength = headerLength + value
        guard buffer.count >= totalLength else { return nil }

        let bodyStart = buffer.index(buffer.startIndex, offsetBy: headerLength)
        let bodyEnd = buffer.index(bodyStart, offsetBy: value)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        let typeNibble = firstByte >> 4
        let type: PacketType
        switch typeNibble {
        case 1: type = .connect
        case 3: type = .publish
        case 8: type = .subscribe
        case 12: type = .pingreq
        case 14: type = .disconnect
        default: type = .unknown
        }

        return Packet(
            type: type,
            body: body,
            packetIdentifier: packetIdentifier(for: type, body: body)
        )
    }

    static func connack() -> Data {
        Data([0x20, 0x02, 0x00, 0x00])
    }

    static func suback(packetIdentifier: UInt16) -> Data {
        Data([0x90, 0x03, UInt8(packetIdentifier >> 8), UInt8(packetIdentifier & 0xFF), 0x00])
    }

    static func pingresp() -> Data {
        Data([0xD0, 0x00])
    }

    static func publish(topic: String, payload: Data) -> Data {
        let topicBytes = Data(topic.utf8)
        var body = Data()
        body.append(UInt8((topicBytes.count >> 8) & 0xFF))
        body.append(UInt8(topicBytes.count & 0xFF))
        body.append(topicBytes)
        body.append(payload)

        var packet = Data([0x30])
        packet.append(remainingLength(body.count))
        packet.append(body)
        return packet
    }

    static func remainingLength(_ value: Int) -> Data {
        var x = max(value, 0)
        var output = Data()
        repeat {
            var encodedByte = UInt8(x % 128)
            x /= 128
            if x > 0 {
                encodedByte |= 128
            }
            output.append(encodedByte)
        } while x > 0
        return output
    }

    private static func packetIdentifier(for type: PacketType, body: Data) -> UInt16? {
        guard type == .subscribe, body.count >= 2 else { return nil }
        return UInt16(body[body.startIndex]) << 8 | UInt16(body[body.index(after: body.startIndex)])
    }
}

enum PixelClockStockSimulatorFrameEncoder {
    private static let columns = 32
    private static let rows = 8

    static func commands(for pages: [PixelClockRenderedPage], config: PixelClockConfig) -> [Data] {
        let page = pages.first ?? PixelClockRenderedPage(
            text: "OPENBURNBAR",
            color: config.palette.primaryHex,
            durationSeconds: config.clampedPageDuration,
            scrollSpeed: config.clampedScrollSpeed
        )

        var commands: [Data] = []
        if let brightness = config.clampedBrightness {
            commands.append(Data([0x0D, UInt8(brightness)]))
        }
        commands.append(Data([0x09]))

        if page.draw.isEmpty {
            commands.append(drawTextCommand(text: page.text, color: page.color))
        } else {
            commands.append(drawBMPCommand(page: page))
        }
        commands.append(Data([0x08]))
        return commands
    }

    static func commandSets(for pages: [PixelClockRenderedPage], config: PixelClockConfig) -> [[Data]] {
        let selectedPages = pages.isEmpty
            ? [
                PixelClockRenderedPage(
                    text: "OPENBURNBAR",
                    color: config.palette.primaryHex,
                    durationSeconds: config.clampedPageDuration,
                    scrollSpeed: config.clampedScrollSpeed
                )
            ]
            : pages
        return selectedPages.map { commands(for: [$0], config: config) }
    }

    static func blankFrameCommands() -> [Data] {
        [Data([0x09]), Data([0x08])]
    }

    private static func drawTextCommand(text: String, color: String) -> Data {
        let rgb = rgbComponents(hex: color) ?? RGB(r: 255, g: 255, b: 255)
        var command = Data([0x00, 0x00, 0x00, 0x00, 0x01, rgb.r, rgb.g, rgb.b])
        command.append(Data(text.prefix(48).utf8))
        return command
    }

    private static func drawBMPCommand(page: PixelClockRenderedPage) -> Data {
        var canvas = Array(
            repeating: Array(repeating: RGB(r: 0, g: 0, b: 0), count: columns),
            count: rows
        )
        for instruction in page.draw {
            apply(instruction, to: &canvas)
        }

        var command = Data([0x01, 0x00, 0x00, 0x00, 0x00, UInt8(columns), UInt8(rows)])
        for row in 0..<rows {
            for column in 0..<columns {
                let color = canvas[row][column].rgb565
                command.append(UInt8(color >> 8))
                command.append(UInt8(color & 0xFF))
            }
        }
        return command
    }

    private static func apply(_ instruction: PixelClockDrawInstruction, to canvas: inout [[RGB]]) {
        switch instruction.command {
        case .drawPixel:
            guard instruction.values.count >= 3,
                  let x = instruction.values[0].intValue,
                  let y = instruction.values[1].intValue,
                  let color = instruction.values[2].stringValue.flatMap(rgbComponents(hex:)) else {
                return
            }
            setPixel(x: x, y: y, color: color, canvas: &canvas)
        case .fillRect:
            guard instruction.values.count >= 5,
                  let x = instruction.values[0].intValue,
                  let y = instruction.values[1].intValue,
                  let width = instruction.values[2].intValue,
                  let height = instruction.values[3].intValue,
                  let color = instruction.values[4].stringValue.flatMap(rgbComponents(hex:)) else {
                return
            }
            for row in y..<(y + max(height, 0)) {
                for column in x..<(x + max(width, 0)) {
                    setPixel(x: column, y: row, color: color, canvas: &canvas)
                }
            }
        case .drawText:
            break
        case .drawBitmap:
            guard instruction.values.count >= 5,
                  let x = instruction.values[0].intValue,
                  let y = instruction.values[1].intValue,
                  let width = instruction.values[2].intValue,
                  let height = instruction.values[3].intValue,
                  let pixels = instruction.values[4].intsValue else {
                return
            }
            for row in 0..<max(height, 0) {
                for column in 0..<max(width, 0) {
                    let index = row * width + column
                    guard pixels.indices.contains(index) else { continue }
                    setPixel(
                        x: x + column,
                        y: y + row,
                        color: rgbComponents(int: pixels[index]),
                        canvas: &canvas
                    )
                }
            }
        }
    }

    private static func setPixel(x: Int, y: Int, color: RGB, canvas: inout [[RGB]]) {
        guard (0..<columns).contains(x), (0..<rows).contains(y) else { return }
        canvas[y][x] = color
    }

    private static func rgbComponents(hex: String) -> RGB? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let intValue = Int(value, radix: 16) else { return nil }
        return RGB(
            r: UInt8((intValue >> 16) & 0xFF),
            g: UInt8((intValue >> 8) & 0xFF),
            b: UInt8(intValue & 0xFF)
        )
    }

    private static func rgbComponents(int: Int) -> RGB {
        RGB(
            r: UInt8((int >> 16) & 0xFF),
            g: UInt8((int >> 8) & 0xFF),
            b: UInt8(int & 0xFF)
        )
    }

    struct RGB: Equatable {
        var r: UInt8
        var g: UInt8
        var b: UInt8

        var rgb565: UInt16 {
            let red = UInt16(r >> 3) << 11
            let green = UInt16(g >> 2) << 5
            let blue = UInt16(b >> 3)
            return red | green | blue
        }
    }
}

private extension PixelClockDrawValue {
    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intsValue: [Int]? {
        if case .ints(let value) = self { return value }
        return nil
    }
}
