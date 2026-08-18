import Foundation
import Combine
import Observation
import OpenBurnBarCore
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
        paths: OpenBurnBarCore.OpenBurnBarAppPaths = .live(),
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
            "\(OpenBurnBarCore.OpenBurnBarIdentity.productName) could not open its local database.",
            "Occurred: \(Self.formatDiagnosticsDate(occurredAt))",
            "Error: \(errorSummary)",
            "Details: \(technicalDetails)",
            "Support directory: \(supportDirectory.path)",
            "Database: \(databaseURL.path)"
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
        paths: OpenBurnBarCore.OpenBurnBarAppPaths = .live(),
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
                try? fileManager.removeItem(at: copiedURL) // try?-ok(best-effort failure cleanup)
            }
            if (try? fileManager.contentsOfDirectory(atPath: archiveDirectory.path).isEmpty) == true { // try?-ok(skip cleanup on list fail)
                try? fileManager.removeItem(at: archiveDirectory) // try?-ok(best-effort failure cleanup)
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
        paths: OpenBurnBarCore.OpenBurnBarAppPaths,
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
    let memoryFootprintWatchdog = MemoryFootprintWatchdog()
    var cloudSyncService: CloudSyncService?
    var iCloudSessionMirrorService: ICloudSessionMirrorService?
    var hermesRelayHostService: HermesRelayHostService?
    var hermesBodyPublisher: HermesBodyPublisher?
    var piAgentRelayHostService: PiAgentCloudRelayHostService?
    var smartHubBridgeController: SmartHubBridgeController?
    var pixelClockController: PixelClockController?
    var smartDisplayRepairCoordinator: SmartDisplayRepairCoordinator?
    var smartDisplayConfigPublisher: SmartDisplayConfigPublisher?
    var smartDisplayActionsListener: SmartDisplayActionsListener?
    var castActionsListener: CastActionsListener?
    var cliAgentMissionRequestListener: CLIAgentMissionRequestListener?
    var agentHarnessImportJobListener: AgentHarnessImportJobListener?
    /// The War Room rhythm (W6). Fires due standing orders at the machine the
    /// Flame picks; without it the `standing_orders` table is a table nobody reads.
    var standingOrderRuntimeHost: StandingOrderRuntimeHost?
    /// The War Room Wire (W1). Keeps Mac-to-Mac lanes open where consent and
    /// entitlement allow, and closes them when either is withdrawn.
    var warWireHost: WarWireHost?
    /// One fleet listener shared by every War Room surface. Two listeners on the
    /// same collection would double the Firestore reads and could disagree about
    /// the fleet for a beat.
    var hermesBodyDirectory: HermesBodyDirectory?
    /// Shared for the same reason as the directory: the Hermes Room reads the
    /// grants the Wire is acting on, so a second listener could show a lane as
    /// open that the Wire had already closed.
    var warWireGrantStore: WarWireGrantStore?
    var routedClientWiringSentry: RoutedClientWiringSentry?
    #if canImport(AppKit) && !DISTRIBUTION_MAS
    var computerUseRuntimeController: ComputerUseRuntimeController?
    var textExpansionRuntimeController: TextExpansionRuntimeController?
    #endif
    let chatController: ChatSessionController
    let operatingLayer: OpenBurnBarOperatingLayer

    // MARK: - Semantic memory (PR-D3 app wiring)
    //
    // The SINGLE shared `ControlPlaneStore` the chat-memory subsystem reads from and
    // writes to (PR-D3 must-fix #1). The same instance backs `OpenBurnBarMemoryService`
    // (the transactional enqueue path) AND `memoryExtractionEngine` (the drain loop), so
    // the worker is the sole provenance authority over one store — never two scopes over
    // the same queue. Assigned post-construction in `makeRuntimeContext` (mirrors the
    // existing `textExpansionRuntimeController` injection), so the init signature stays
    // unchanged.
    var chatMemoryStore: ControlPlaneStore?

    /// The `@MainActor` scheduler that drains the extraction outbox (PR-D2). Owned here
    /// so the start-site (`startLiveServicesIfNeeded`) and the post-commit drain hook
    /// (`ChatSessionController`) share one engine. The combined kill switch
    /// (`memoryExtractionEnabled`) defaults false because user consent (G0) is off until
    /// opt-in, so out of the box nothing reads transcripts or calls the LLM. Durable writes
    /// are additionally AND-ed with `chatMemoryAuthorityWritesEnabledByDefault` in the
    /// worker's authority closure (PR-D FIX #1).
    var memoryExtractionEngine: MemoryExtractionEngine?

    /// PR-E2 approved-memory cloud-replication scheduler over the SAME shared store as the
    /// engine. Assigned post-construction via `applyMemoryServices` (mirrors the engine
    /// injection). Ships DORMANT: `RefreshOrchestrator` schedules its `sync()` in the
    /// post-persistence cadence, but it replicates nothing unless the user opted in
    /// (`memoryApprovedCloudBackupEnabled`, default OFF), the Remote Config fleet ceiling
    /// allows, and the account is cloud-sync-ready. Constructing it flips nothing on.
    var memoryCloudSyncDomain: MemoryCloudSyncDomain?

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
    #if canImport(AppKit) && !DISTRIBUTION_MAS
    var smartZoomContextProvider: SmartZoomContextProvider?
    private var mercurySmartZoomPhaseCancellable: AnyCancellable?
    #endif
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
        CLIAgentSessionMirror.configureShared(accountManager: accountManager)
    }

    func startRelayServices() {
        startRoutedClientWiringSentry()

        guard accountManager.isFirebaseAvailable else {
            hermesRelayHostService?.stop()
            hermesBodyPublisher?.stop()
            piAgentRelayHostService?.stop()
            return
        }

        let hermesRelayHost: HermesRelayHostService
        if let existingRelayHost = hermesRelayHostService {
            hermesRelayHost = existingRelayHost
        } else {
            let cliRelayExecutor = ChatSessionControllerCLIAgentRelayChatExecutor(chatController: chatController)
            let cliModelCatalogDiscovery = CLIRuntimeModelCatalogDiscovery(settingsManager: settingsManager)
            #if canImport(AppKit) && !DISTRIBUTION_MAS
            let cliSessionActionDispatcher = CLIAgentSessionActionDaemonDispatcher(
                daemonManager: daemonManager,
                approvalPresenter: { request in
                    await ComputerUseRuntimeController.presentApproval(request, screenshot: nil)
                },
                haltHandler: { [weak self] in
                    await self?.computerUseRuntimeController?.coordinator.panicHalt(source: .phoneGesture)
                }
            )
            let cliSessionActionRelayDispatcher: CLIAgentSessionActionDispatcher? = { request, requestStillActive in
                try await cliSessionActionDispatcher.perform(request, requestStillActive: requestStillActive)
            }
            #else
            let cliSessionActionRelayDispatcher: CLIAgentSessionActionDispatcher?
            cliSessionActionRelayDispatcher = nil
            #endif
            hermesRelayHost = HermesRelayHostService(
                accountManager: accountManager,
                settingsManager: settingsManager,
                cliChatDispatcher: { request, eventSender in
                    try await cliRelayExecutor.streamChat(request: request, onEvent: eventSender)
                },
                cliModelCatalogDispatcher: { request in
                    try await cliModelCatalogDiscovery.modelCatalog(for: request)
                },
                cliSessionActionDispatcher: cliSessionActionRelayDispatcher
            )
            hermesRelayHostService = hermesRelayHost
        }
        hermesRelayHost.start()
        // War Room W0: this Mac's HermesBody rides the relay host's identity —
        // same connection id, published for as long as the host is up.
        if hermesBodyPublisher == nil {
            hermesBodyPublisher = HermesBodyPublisher(
                accountManager: accountManager,
                settingsManager: settingsManager,
                bodyIDProvider: { hermesRelayHost.connectionID }
            )
        }
        hermesBodyPublisher?.start()
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        startComputerUseServices(relayHostService: hermesRelayHost)
        #endif

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
                quotaService: quotaService,
                memoryCloudSyncDomain: memoryCloudSyncDomain
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
                try? await Task.sleep(for: .seconds(1)) // try?-ok(cancellation only)
                guard !Task.isCancelled else { return }
            }
            await sync.uploadPending()
            await sync.uploadPendingConversations()
            await sync.uploadPendingChatThreads()
            await sync.syncTextExpansionSnippets()
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
                try? await Task.sleep(nanoseconds: nanos) // try?-ok(cancellation only)
                if Task.isCancelled { break }
                await usageAggregator.refreshAll()
                await self.daemonManager.refreshHealth()
                await self.operatingLayer.refreshControllerRuntime()
            }
        }
    }

    #if canImport(AppKit) && !DISTRIBUTION_MAS
    func startComputerUseServices(relayHostService explicitRelayHostService: HermesRelayHostService? = nil) {
        // cov:ignore-start -- live app bootstrap wiring; runtime controller behavior is covered by Computer Use coordinator and daemon manager tests.
        let controller: ComputerUseRuntimeController
        if let existing = computerUseRuntimeController {
            controller = existing
        } else {
            controller = ComputerUseRuntimeController(
                accountManager: accountManager,
                settingsManager: settingsManager,
                daemonManager: daemonManager,
                relayHostService: explicitRelayHostService ?? hermesRelayHostService,
                chatController: chatController
            )
            computerUseRuntimeController = controller
        }
        chatController.computerUseRuntimeController = controller

        if let relayHost = explicitRelayHostService ?? hermesRelayHostService {
            controller.attach(relayHostService: relayHost)
        }
        AgentCapabilityGrantQueueListener.shared.start()
        controller.startEscrowRevocationWatching()
        #if DEBUG
        controller.startE2EProofSessionIfRequested()
        #endif
        // cov:ignore-end
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

        guard accountManager.isFirebaseAvailable else {
            smartDisplayConfigPublisher?.stop()
            smartDisplayActionsListener?.stop()
            castActionsListener?.stop()
            cliAgentMissionRequestListener?.stop()
            agentHarnessImportJobListener?.stop()
            standingOrderRuntimeHost?.stop()
            warWireHost?.stop()
            hermesBodyDirectory?.stop()
            return
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

        let fleetDirectory: HermesBodyDirectory
        if let existing = hermesBodyDirectory {
            fleetDirectory = existing
        } else {
            fleetDirectory = HermesBodyDirectory(accountManager: accountManager)
            hermesBodyDirectory = fleetDirectory
        }
        fleetDirectory.start()

        let standingOrders: StandingOrderRuntimeHost
        if let existing = standingOrderRuntimeHost {
            standingOrders = existing
        } else {
            standingOrders = StandingOrderRuntimeHost(
                store: StandingOrderStore(dbQueue: dataStore.actor.dbQueue),
                directory: fleetDirectory,
                dispatcher: MacWandMissionDispatcher(accountManager: accountManager)
            )
            standingOrderRuntimeHost = standingOrders
        }
        standingOrders.start()

        let grants: WarWireGrantStore
        if let existing = warWireGrantStore {
            grants = existing
        } else {
            grants = WarWireGrantStore(
                accountManager: accountManager,
                settingsManager: settingsManager
            )
            warWireGrantStore = grants
        }

        let wire: WarWireHost
        if let existing = warWireHost {
            wire = existing
        } else {
            wire = WarWireHost(
                directory: fleetDirectory,
                grantStore: grants,
                accountManager: accountManager,
                tierProvider: { MacCloudEntitlementStore.shared.cloudTier },
                killSwitchProvider: { [settingsManager] in settingsManager.warRoomKillSwitch },
                transportProvider: { [weak self] in self?.hermesRelayHostService?.activeIrohTransport }
            )
            warWireHost = wire
        }
        wire.start()
    }

    /// Boot the durability sentry that keeps Codex / Forge / OpenCode / Droid
    /// wired through the local BurnBar gateway after external rewrites (plugin
    /// installs, dotfile syncs). Claude Code is excluded from unattended repair
    /// because its global Anthropic override disables claude.ai connector
    /// fallback when the daemon is off. The sentry follows persisted Connect
    /// intent and adopts already-wired configs for supported durable targets so
    /// stale client catalogs can self-heal after upgrades.
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
        let mediaCapabilityGate = MacMediaCapabilityGate.live(settingsManager: settingsManager)
        let session = MediaSessionCoordinator(capabilityGate: mediaCapabilityGate)
        let hud = CallHUDState()
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        let router = MercuryRouter(
            sessionCoordinator: session,
            peerSource: peerSource,
            consentStore: consent,
            ensureComputerUseSession: { [weak self] in
                guard let self else { return }
                self.startComputerUseServices()
                self.computerUseRuntimeController?.setPhoneControlAuthorizedPeerNodeProvider { [weak self] in
                    self?.mercuryRouter?.activeMirrorControlAuthorityPeerNodeID
                }
                self.computerUseRuntimeController?.setPhoneControlKeyboardTargetWindowProvider { [weak self] in
                    self?.mercuryRouter?.activeMirrorControlTerminalWindowID
                }
                self.computerUseRuntimeController?.setRemoteUnlockResultHandler { [weak self] result in
                    self?.mercuryRouter?.handleRemoteUnlockCredentialResult(result)
                }
                self.computerUseRuntimeController?.attachFocusFollow(mediaSessionCoordinator: session)
                _ = try await self.computerUseRuntimeController?.ensureSystemSession(trustMode: .manual)
            },
            applyFocusFollowMode: { [weak self] mode in
                self?.computerUseRuntimeController?.setFocusFollowMode(mode)
            },
            phoneControlAuthorityValidatorProvider: { [weak self] in
                guard let self else { return nil }
                self.startComputerUseServices()
                return self.computerUseRuntimeController?.coordinator.phoneValidator
            },
            // cov:ignore-start -- app bootstrap wiring to the live Firebase enrollment-grant callable; the router-side grant decision and failure handling are unit-tested with injected issuers in MercuryRouterTests
            phoneControlEnrollmentGrantIssuer: { connectionID, controllerDeviceID, controllerPeerNodeID in
                try await ComputerUseSecurityCallableClient.issuePhoneControlEnrollmentGrant(
                    hostDeviceId: MacLiveDeviceTrustGateway.loadOrCreateDeviceId(),
                    connectionId: connectionID,
                    controllerDeviceId: controllerDeviceID,
                    controllerPeerNodeId: controllerPeerNodeID
                )
            }
            // cov:ignore-end
        )
        #else
        let router = MercuryRouter(
            sessionCoordinator: session,
            peerSource: peerSource,
            consentStore: consent
        )
        #endif

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
        router.setMirrorSinkFactory { request, frame, replySender in
            // F7: no-wrap requests keep the legacy app-layer lane; offered
            // media-seal wraps must open or the sink fails closed.
            let frameSealKey = try await MacMediaSealKeyOpener.requireFrameSealKeyIfOffered(
                for: request,
                frame: frame
            )
            return MercuryControlStreamMediaSink(
                sender: replySender,
                uid: frame.uid,
                connectionID: frame.connectionId,
                streamClass: MediaStreamClass(rawValue: request.streamClass),
                extraHeartbeatCapabilities: [],
                frameSealKey: frameSealKey
            )
        }
        self.voipCallTrigger = VoIPCallTrigger()

        peerSource.start()

        // Attach to the live iroh host's control stream. The relay host
        // owns the persistent `media.control` registry; CloudSyncService
        // only owns Firestore sync.
        hermesRelayHostService?.attachMercuryRouter(router)

        #if canImport(AppKit) && !DISTRIBUTION_MAS
        attachSmartZoomToRouter(router)
        #endif
    }

    #if canImport(AppKit) && !DISTRIBUTION_MAS
    @MainActor
    private func attachSmartZoomToRouter(_ router: MercuryRouter) {
        let provider = SmartZoomContextProvider(
            inputsProvider: { @MainActor in
                SmartZoomSystemSampler.sample()
            },
            sink: { [weak router] context in
                await router?.sendFocusContextOnActiveMirror(context)
            }
        )
        smartZoomContextProvider = provider
        mercurySmartZoomPhaseCancellable = router.$phase
            .removeDuplicates()
            .sink { phase in
                Task { @MainActor in
                    switch phase {
                    case .streaming:
                        provider.start()
                    default:
                        provider.stop()
                    }
                }
            }
    }
    #endif

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
