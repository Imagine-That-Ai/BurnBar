import Foundation
import Observation
import OpenBurnBarMedia

struct DataStoreStartupFailure: Identifiable, Equatable {
    let id: UUID
    let occurredAt: Date
    let errorSummary: String
    let technicalDetails: String
    let supportDirectory: URL
    let databaseURL: URL
    let archiveURL: URL?

    static func make(
        error: Error,
        paths: OpenBurnBarAppPaths = .live(),
        occurredAt: Date = Date(),
        archiveURL: URL? = nil,
        id: UUID = UUID()
    ) -> DataStoreStartupFailure {
        DataStoreStartupFailure(
            id: id,
            occurredAt: occurredAt,
            errorSummary: error.localizedDescription,
            technicalDetails: String(describing: error),
            supportDirectory: paths.supportDirectory,
            databaseURL: paths.databaseURL,
            archiveURL: archiveURL
        )
    }

    /// Zero-cost placeholder used by the XCTest host. No filesystem probing, no
    /// `OpenBurnBarAppPaths.live()` lookup — just enough to satisfy the
    /// `OpenBurnBarStartupState.failed` requirement so `OpenBurnBarApp.init` can
    /// short-circuit out of every real bootstrap path under `XCTest`. The test
    /// stub scene never reads this value; it exists only to keep the type system
    /// happy while we skip real startup.
    static func testStubPlaceholder() -> DataStoreStartupFailure {
        DataStoreStartupFailure(
            id: UUID(),
            occurredAt: Date(timeIntervalSinceReferenceDate: 0),
            errorSummary: "XCTest host bootstrap (no real startup performed)",
            technicalDetails: "OpenBurnBarRuntime.shouldUseTestStubScene == true",
            supportDirectory: URL(fileURLWithPath: "/dev/null/openburnbar-test-stub", isDirectory: true),
            databaseURL: URL(fileURLWithPath: "/dev/null/openburnbar-test-stub.sqlite"),
            archiveURL: nil
        )
    }

    var diagnostics: String {
        var lines = [
            "\(OpenBurnBarIdentity.productName) could not open its local database.",
            "Occurred: \(Self.formatDiagnosticsDate(occurredAt))",
            "Error: \(errorSummary)",
            "Details: \(technicalDetails)",
            "Support directory: \(supportDirectory.path)",
            "Database: \(databaseURL.path)",
        ]
        if let archiveURL {
            lines.append("Recovery archive: \(archiveURL.path)")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatDiagnosticsDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct DataStoreRecoveryArchiveResult: Equatable {
    let archiveDirectory: URL
    let archivedFiles: [URL]
}

enum OpenBurnBarStartupRecovery {
    /// Launch must stay interactive. Full parser refreshes can traverse large
    /// local agent histories, so automatic refreshes are paced like background
    /// sync work instead of firing during the first dashboard render.
    static let minimumAutomaticUsageRefreshInterval: TimeInterval = 15 * 60

    static func archiveDatabaseSidecars(
        paths: OpenBurnBarAppPaths = .live(),
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> DataStoreRecoveryArchiveResult {
        let timestamp = archiveTimestamp(for: now)
        let archiveDirectory = try uniqueArchiveDirectory(
            paths: paths,
            fileManager: fileManager,
            timestamp: timestamp
        )
        let existingSidecars = paths.databaseSidecarURLs.filter {
            fileManager.fileExists(atPath: $0.path)
        }

        try fileManager.createDirectory(
            at: archiveDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archiveDirectory.path)

        var archivedFiles: [URL] = []
        do {
            for sourceURL in existingSidecars {
                let destinationURL = archiveDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                archivedFiles.append(destinationURL)
            }
        } catch {
            for copiedURL in archivedFiles where fileManager.fileExists(atPath: copiedURL.path) {
                try? fileManager.removeItem(at: copiedURL)
            }
            if (try? fileManager.contentsOfDirectory(atPath: archiveDirectory.path).isEmpty) == true {
                try? fileManager.removeItem(at: archiveDirectory)
            }
            throw error
        }

        for sourceURL in existingSidecars where fileManager.fileExists(atPath: sourceURL.path) {
            try fileManager.removeItem(at: sourceURL)
        }

        return DataStoreRecoveryArchiveResult(
            archiveDirectory: archiveDirectory,
            archivedFiles: archivedFiles
        )
    }

    static func archiveTimestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func uniqueArchiveDirectory(
        paths: OpenBurnBarAppPaths,
        fileManager: FileManager,
        timestamp: String
    ) throws -> URL {
        let baseURL = paths.startupRecoveryArchiveDirectory(timestamp: timestamp)
        guard fileManager.fileExists(atPath: baseURL.path) else { return baseURL }

        for attempt in 2...100 {
            let candidate = paths.startupRecoveryArchiveDirectory(timestamp: "\(timestamp)-\(attempt)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw CocoaError(.fileWriteFileExists, userInfo: [
            NSFilePathErrorKey: baseURL.path,
            NSLocalizedDescriptionKey: "Could not create a unique startup recovery archive directory."
        ])
    }
}

enum OpenBurnBarStartupState {
    case ready(OpenBurnBarRuntimeContext)
    case failed(DataStoreStartupFailure)

    var runtimeContext: OpenBurnBarRuntimeContext? {
        guard case let .ready(context) = self else { return nil }
        return context
    }

    var failure: DataStoreStartupFailure? {
        guard case let .failed(failure) = self else { return nil }
        return failure
    }
}

@MainActor
@Observable
final class OpenBurnBarRuntimeContext {
    let dataStore: DataStore
    let settingsManager: SettingsManager
    var aggregator: UsageAggregator?
    let accountManager: AccountManager
    let quotaService: ProviderQuotaService
    let daemonManager: OpenBurnBarDaemonManager
    let cursorConnectorManager: CursorConnectorManager
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    var hermesRelayHostService: HermesRelayHostService?
    var piAgentRelayHostService: PiAgentCloudRelayHostService?
    var smartHubBridgeController: SmartHubBridgeController?
    var pixelClockController: PixelClockController?
    var smartDisplayRepairCoordinator: SmartDisplayRepairCoordinator?
    var smartDisplayConfigPublisher: SmartDisplayConfigPublisher?
    var smartDisplayActionsListener: SmartDisplayActionsListener?
    var castActionsListener: CastActionsListener?
    var cliAgentMissionRequestListener: CLIAgentMissionRequestListener?
    var agentHarnessImportJobListener: AgentHarnessImportJobListener?
    var routedClientWiringSentry: RoutedClientWiringSentry?
    #if canImport(AppKit) && !DISTRIBUTION_MAS
    var computerUseRuntimeController: ComputerUseRuntimeController?
    #endif
    let chatController: ChatSessionController
    let operatingLayer: OpenBurnBarOperatingLayer

    // MARK: - Mercury Phase 8 — user-facing surfaces

    /// Live-share / file-transfer / call brain. Mounted into the
    /// menu-bar popover via `MercuryTraySection` and into the app
    /// scene root via a `WindowGroup` hosting `MercuryChromeRoot`.
    var mercuryPeerSource: MercuryPeerSource?
    var mercurySessionCoordinator: MediaSessionCoordinator?
    var mercuryRouter: MercuryRouter?
    var mercuryCallHUDState: CallHUDState?
    var mercuryConsentStore: MercuryConsentStore?
    var mercuryIncomingPanelPresenter: MercuryIncomingPanelPresenter?
    var voipCallTrigger: VoIPCallTrigger?
    private var didStartForegroundRuntimeServices = false
    private var managedRuntimeProbeTask: Task<Void, Never>?
    private var startupScanTask: Task<Void, Never>?
    private var periodicRefreshTask: Task<Void, Never>?

    init(
        dataStore: DataStore,
        settingsManager: SettingsManager,
        aggregator: UsageAggregator? = nil,
        accountManager: AccountManager,
        quotaService: ProviderQuotaService,
        daemonManager: OpenBurnBarDaemonManager,
        cursorConnectorManager: CursorConnectorManager,
        cloudSyncService: CloudSyncService? = nil,
        iCloudSessionMirrorService: ICloudSessionMirrorService? = nil,
        chatController: ChatSessionController,
        operatingLayer: OpenBurnBarOperatingLayer
    ) {
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.aggregator = aggregator
        self.accountManager = accountManager
        self.quotaService = quotaService
        self.daemonManager = daemonManager
        self.cursorConnectorManager = cursorConnectorManager
        self.cloudSyncService = cloudSyncService
        self.iCloudSessionMirrorService = iCloudSessionMirrorService
        self.chatController = chatController
        self.operatingLayer = operatingLayer
    }

    func startRelayServices() {
        let hermesRelayHost: HermesRelayHostService
        if let existingRelayHost = hermesRelayHostService {
            hermesRelayHost = existingRelayHost
        } else {
            let cliRelayExecutor = ChatSessionControllerCLIAgentRelayChatExecutor(chatController: chatController)
            hermesRelayHost = HermesRelayHostService(
                accountManager: accountManager,
                settingsManager: settingsManager,
                cliChatDispatcher: { request, eventSender in
                    try await cliRelayExecutor.streamChat(request: request, onEvent: eventSender)
                }
            )
            hermesRelayHostService = hermesRelayHost
        }
        hermesRelayHost.start()
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        startComputerUseServices(relayHostService: hermesRelayHost)
        #endif

        startRoutedClientWiringSentry()

        let piRelayHost: PiAgentCloudRelayHostService
        if let existingPiRelayHost = piAgentRelayHostService {
            piRelayHost = existingPiRelayHost
        } else {
            piRelayHost = PiAgentCloudRelayHostService(
                accountManager: accountManager,
                settingsManager: settingsManager
            )
            piAgentRelayHostService = piRelayHost
        }
        piRelayHost.start()
    }

    /// Starts the app-level runtime services that must be alive even when no
    /// SwiftUI menu-bar popover has ever been opened. This keeps phone-facing
    /// relay, Mercury, daemon approval, quota refresh, and cloud-sync work tied
    /// to application startup rather than to a particular status-item view.
    func startForegroundRuntimeServices() {
        guard !didStartForegroundRuntimeServices else { return }
        didStartForegroundRuntimeServices = true

        let sync: CloudSyncService
        if let existingSync = cloudSyncService {
            sync = existingSync
        } else {
            sync = CloudSyncService(
                dataStore: dataStore,
                accountManager: accountManager,
                settingsManager: settingsManager
            )
            cloudSyncService = sync
        }

        startRelayServices()
        startSmartDisplayServices()
        startMercuryServices()

        let mirror: ICloudSessionMirrorService
        if let existingMirror = iCloudSessionMirrorService {
            mirror = existingMirror
        } else {
            mirror = ICloudSessionMirrorService(settingsManager: settingsManager)
            iCloudSessionMirrorService = mirror
        }

        let usageAggregator: UsageAggregator
        if let existingAggregator = aggregator {
            usageAggregator = existingAggregator
        } else {
            usageAggregator = UsageAggregator(
                dataStore: dataStore,
                cloudSync: sync,
                sessionMirror: mirror,
                settingsManager: settingsManager,
                quotaService: quotaService
            )
            aggregator = usageAggregator
        }

        operatingLayer.aggregator = usageAggregator
        operatingLayer.chatController = chatController
        daemonManager.attach(dataStore: dataStore, cloudSyncService: sync)
        #if !DISTRIBUTION_MAS
        ComputerUseDaemonApprovalPresenter.shared.start(daemonManager: daemonManager)
        #endif
        cursorConnectorManager.attach(dataStore: dataStore)
        quotaService.startAutomaticRefresh(dataStore: dataStore)

        managedRuntimeProbeTask?.cancel()
        managedRuntimeProbeTask = Task {
            if self.settingsManager.launchHermesWithOpenBurnBar {
                let baseURL = URL(string: self.settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                    ?? URL(string: "http://127.0.0.1:8642")!
                let bearerToken = self.settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = await HermesRuntimeLauncher().openHermesAndGateway(
                    baseURL: baseURL,
                    bearerToken: bearerToken.isEmpty ? nil : bearerToken,
                    launchDashboard: false
                )
            }
            if self.settingsManager.launchPiAgentsWithOpenBurnBar {
                let baseURL = URL(string: self.settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                    ?? URL(string: "http://127.0.0.1:8765")!
                let bearerToken = self.settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
                let preferred = self.settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
                let redisRaw = self.settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let piAdapter = PiAgentRuntimeAdapter(
                    preferredInstanceID: preferred.isEmpty ? nil : preferred,
                    redisURL: redisRaw.isEmpty ? nil : URL(string: redisRaw)
                )
                _ = await piAdapter.openManagedRuntime(
                    baseURL: baseURL,
                    bearerToken: bearerToken.isEmpty ? nil : bearerToken
                )
            }
            let enabledBackends = Set(self.settingsManager.enabledChatBackends)
            if enabledBackends.contains(.hermes) || self.chatController.chatBackend == .hermes {
                await self.chatController.probeHermesAvailability()
            } else {
                self.chatController.hermesAvailable = false
            }
            if enabledBackends.contains(.openclaw) || self.chatController.chatBackend == .openclaw {
                await self.chatController.probeOpenClawAvailability()
            } else {
                self.chatController.openClawAvailable = false
            }
            if enabledBackends.contains(.piAgent) || self.chatController.chatBackend == .piAgent {
                await self.chatController.probePiAgentAvailability()
            } else {
                self.chatController.piAgentAvailable = false
            }
            await self.daemonManager.refreshHealth()
            await self.operatingLayer.refreshControllerRuntime()
        }

        startupScanTask?.cancel()
        startupScanTask = Task(priority: .utility) {
            for _ in 0..<30 where !self.accountManager.isSignedIn {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            await sync.uploadPending()
            await sync.uploadPendingConversations()
            await sync.uploadPendingChatThreads()
            if self.settingsManager.dailyDigestEnabled {
                await DailyDigestManager.shared.requestAuthorization()
                DailyDigestManager.shared.scheduleDigest(
                    from: self.dataStore,
                    at: self.settingsManager.dailyDigestHour
                )
            }
        }

        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task(priority: .utility) {
            while !Task.isCancelled {
                let minimumRefreshInterval = OpenBurnBarStartupRecovery.minimumAutomaticUsageRefreshInterval
                let seconds = max(self.settingsManager.refreshInterval, minimumRefreshInterval)
                let nanos = UInt64(seconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                await usageAggregator.refreshAll()
                await self.daemonManager.refreshHealth()
                await self.operatingLayer.refreshControllerRuntime()
            }
        }
    }

    #if canImport(AppKit) && !DISTRIBUTION_MAS
    func startComputerUseServices(relayHostService explicitRelayHostService: HermesRelayHostService? = nil) {
        let controller: ComputerUseRuntimeController
        if let existing = computerUseRuntimeController {
            controller = existing
        } else {
            controller = ComputerUseRuntimeController(
                accountManager: accountManager,
                settingsManager: settingsManager,
                relayHostService: explicitRelayHostService ?? hermesRelayHostService
            )
            computerUseRuntimeController = controller
        }

        if let relayHost = explicitRelayHostService ?? hermesRelayHostService {
            controller.attach(relayHostService: relayHost)
        }
        #if DEBUG
        controller.startE2EProofSessionIfRequested()
        #endif
    }
    #endif

    func startSmartDisplayServices() {
        let smartHubBridge: SmartHubBridgeController
        if let existingSmartHubBridge = smartHubBridgeController {
            smartHubBridge = existingSmartHubBridge
        } else {
            smartHubBridge = SmartHubBridgeController(
                settingsManager: settingsManager,
                quotaService: quotaService,
                dataStore: dataStore
            )
            smartHubBridgeController = smartHubBridge
        }
        smartHubBridge.start()

        let pixelClock: PixelClockController
        if let existing = pixelClockController {
            pixelClock = existing
        } else {
            pixelClock = PixelClockController(
                settingsManager: settingsManager,
                quotaService: quotaService
            )
            pixelClockController = pixelClock
        }
        pixelClock.start()

        let repairCoordinator: SmartDisplayRepairCoordinator
        if let existing = smartDisplayRepairCoordinator {
            repairCoordinator = existing
        } else {
            repairCoordinator = SmartDisplayRepairCoordinator(
                smartHubBridgeController: smartHubBridge,
                pixelClockController: pixelClock
            )
            smartDisplayRepairCoordinator = repairCoordinator
        }

        let publisher: SmartDisplayConfigPublisher
        if let existing = smartDisplayConfigPublisher {
            publisher = existing
        } else {
            publisher = SmartDisplayConfigPublisher(
                accountManager: accountManager,
                settingsManager: settingsManager
            )
            smartDisplayConfigPublisher = publisher
        }
        publisher.start()

        let displayListener: SmartDisplayActionsListener
        if let existing = smartDisplayActionsListener {
            displayListener = existing
        } else {
            displayListener = SmartDisplayActionsListener(
                accountManager: accountManager,
                settingsManager: settingsManager,
                pixelClockController: pixelClock,
                repairCoordinator: repairCoordinator
            )
            smartDisplayActionsListener = displayListener
        }
        displayListener.start()

        let castListener: CastActionsListener
        if let existing = castActionsListener {
            castListener = existing
        } else {
            castListener = CastActionsListener(
                accountManager: accountManager,
                settingsManager: settingsManager,
                repairCoordinator: repairCoordinator
            )
            castActionsListener = castListener
        }
        castListener.start()

        let missionListener: CLIAgentMissionRequestListener
        if let existing = cliAgentMissionRequestListener {
            missionListener = existing
        } else {
            missionListener = CLIAgentMissionRequestListener(
                accountManager: accountManager,
                settingsManager: settingsManager,
                chatController: chatController
            )
            cliAgentMissionRequestListener = missionListener
        }
        missionListener.start()

        let importListener: AgentHarnessImportJobListener
        if let existing = agentHarnessImportJobListener {
            importListener = existing
        } else {
            importListener = AgentHarnessImportJobListener(
                accountManager: accountManager,
                settingsManager: settingsManager,
                dataStore: dataStore,
                cloudSyncService: cloudSyncService
            )
            agentHarnessImportJobListener = importListener
        }
        importListener.start()
    }

    /// Boot the durability sentry that keeps Claude Code / Codex / Forge /
    /// OpenCode / Droid wired through the local BurnBar gateway after
    /// external rewrites (Claude Code's atomic settings.json save, plugin
    /// installs, dotfile syncs). The sentry is a no-op until at least one CLI
    /// has been Connected; it picks up the persisted intent automatically.
    func startRoutedClientWiringSentry() {
        let sentry: RoutedClientWiringSentry
        if let existing = routedClientWiringSentry {
            sentry = existing
        } else {
            sentry = RoutedClientWiringSentry()
            routedClientWiringSentry = sentry
        }
        sentry.start(settingsManager: settingsManager)
    }

    /// Mercury Phase 8 — construct the user-facing service stack:
    /// peer source, session coordinator, consent store, router. The
    /// router is attached to the CloudSync iroh client's control
    /// stream dispatcher so inbound `media.mirror.request` /
    /// `media.presence.heartbeat` frames flow into it. The popover
    /// section + scene-root chrome read state off these published
    /// objects.
    ///
    /// Idempotent: calling more than once does nothing.
    func startMercuryServices() {
        guard mercuryRouter == nil else { return }
        let consent = MercuryConsentStore()
        let peerSource = makeMercuryPeerSource()
        let session = MediaSessionCoordinator(capabilityGate: MacMediaCapabilityGate.shared)
        let hud = CallHUDState()
        let router = MercuryRouter(
            sessionCoordinator: session,
            peerSource: peerSource,
            consentStore: consent
        )

        self.mercuryConsentStore = consent
        self.mercuryPeerSource = peerSource
        self.mercurySessionCoordinator = session
        self.mercuryCallHUDState = hud
        self.mercuryRouter = router
        self.mercuryIncomingPanelPresenter = MercuryIncomingPanelPresenter(
            router: router,
            peerSource: peerSource,
            hudState: hud
        )
        if let registry = hermesRelayHostService?.mercuryControlStreamRegistry {
            router.setMirrorSinkFactory { request, frame in
                try await MercuryControlStreamMediaSink.make(
                    registry: registry,
                    uid: frame.uid,
                    connectionID: frame.connectionId,
                    streamClass: MediaStreamClass(rawValue: request.streamClass)
                )
            }
        }
        self.voipCallTrigger = VoIPCallTrigger()

        peerSource.start()

        // Attach to the live iroh host's control stream. The relay host
        // owns the persistent `media.control` registry; CloudSyncService
        // only owns Firestore sync.
        hermesRelayHostService?.attachMercuryRouter(router)
    }

    private func makeMercuryPeerSource() -> MercuryPeerSource {
        let registry = hermesRelayHostService?.mercuryControlStreamRegistry
            ?? MediaControlStreamRegistry()
        let manager = accountManager
        return MercuryPeerSource(
            registry: registry,
            uidProvider: { manager.userID }
        )
    }
}
