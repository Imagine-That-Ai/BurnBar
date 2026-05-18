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
    /// scene root via `MercuryGlobalChrome`.
    var mercuryPeerSource: MercuryPeerSource?
    var mercurySessionCoordinator: MediaSessionCoordinator?
    var mercuryRouter: MercuryRouter?
    var mercuryCallHUDState: CallHUDState?
    var mercuryConsentStore: MercuryConsentStore?
    var voipCallTrigger: VoIPCallTrigger?

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
        controller.startPanicMonitoring()
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
