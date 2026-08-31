import AppKit
import OpenBurnBarCore
import OSLog
import SwiftUI

/// Single source of truth for "this process is hosting XCTest, not a real user."
/// Keeps test hosts from starting heavyweight scene/bootstrap work before XCTest connects.
enum OpenBurnBarRuntime {
    @MainActor private static var applicationHostActivity: NSObjectProtocol?

    /// True when the current process is an XCTest host. Detected via the well-known
    /// XCTest environment variables that Apple injects into the test runner.
    static var isRunningTests: Bool {
        isRunningTests(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments,
            parentProcessPath: nil, // We don't easily have the parent process path here
            loadedBundlePaths: Bundle.allBundles.map(\.bundlePath)
        )
    }

    static func isRunningTests(
        environment: [String: String],
        arguments: [String] = [],
        parentProcessPath: String? = nil,
        loadedBundlePaths: [String] = [],
        loadedImagePaths: [String] = [],
        xCTestFrameworkLoaded: Bool? = nil
    ) -> Bool {
        if let xCTestFrameworkLoaded, xCTestFrameworkLoaded {
            return true
        }

        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["TEST_RUNNER_CI"] == "true"
            || environment["TEST_RUNNER_GITHUB_ACTIONS"] == "true"
            || environment["TEST_RUNNER_RUNNER_OS"] != nil
            || environment["__XPC_DYLD_LIBRARY_PATH"]?.contains(".xctest") ?? false
            || arguments.contains { $0.hasSuffix(".xctestconfiguration") }
            || parentProcessPath.map { URL(fileURLWithPath: $0).lastPathComponent == "xcodebuild" } ?? false
            || loadedBundlePaths.contains { $0.hasSuffix(".xctest") }
            || loadedImagePaths.contains { $0.contains("libXCTestBundleInject.dylib") }
    }

    /// Allows tests / harnesses to opt **in** to the live menu-bar scene by setting
    /// `OPENBURNBAR_FORCE_LIVE_SCENE=1`. Default is opt-out (skip the live scene under tests).
    static var forceLiveScene: Bool {
        ProcessInfo.processInfo.environment["OPENBURNBAR_FORCE_LIVE_SCENE"] == "1"
            || isUITestLaunch
    }

    static var isUITestLaunch: Bool {
        isUITestLaunch(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func isUITestLaunch(environment: [String: String], arguments: [String]) -> Bool {
        #if DEBUG
        environment["OPENBURNBAR_UITEST"] == "1" || arguments.contains("--uitest")
        #else
        false
        #endif
    }

    /// Limits the window-visibility control channel to the DEBUG real-process
    /// performance harness. Production launches never register the channel.
    static var isPerformanceGateLaunch: Bool {
        isPerformanceGateLaunch(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func isPerformanceGateLaunch(
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        #if DEBUG
        environment["OPENBURNBAR_PERFORMANCE_GATE"] == "1"
            && isUITestLaunch(environment: environment, arguments: arguments)
        #else
        false
        #endif
    }

    /// The real-process backdrop gate must measure window rendering, not
    /// unrelated updater, wallpaper, or cloud-maintenance work. Keep the
    /// status item and dashboard alive, but suppress those background services
    /// for this dedicated harness launch only.
    static func shouldStartBackgroundApplicationServices(
        isPerformanceGateLaunch: Bool
    ) -> Bool {
        !isPerformanceGateLaunch
    }

    /// Shared contract for the DEBUG performance harness. The native helper
    /// cannot import the app module, so its notification string must match this
    /// value exactly.
    static let performanceGateVisibilityNotification = Notification.Name(
        "com.openburnbar.performance-gate.window-visibility"
    )
    static var performanceGateBackdropStateNotification: Notification.Name {
        Notification.Name("com.openburnbar.performance-gate.backdrop-state")
    }

    static var currentPerformanceGateNotificationObject: String {
        performanceGateNotificationObject(
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
    }

    static func performanceGateNotificationObject(processIdentifier: Int32) -> String {
        String(processIdentifier)
    }

    static func performanceGateBackdropKernelOverride(
        isPerformanceGateLaunch: Bool,
        arguments: [String]
    ) -> String? {
        guard isPerformanceGateLaunch,
              let keyIndex = arguments.firstIndex(of: "-backdropKernel"),
              arguments.indices.contains(keyIndex + 1) else { return nil }
        let kernel = arguments[keyIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return kernel.isEmpty ? nil : kernel
    }

    static var shouldOpenSettingsForUITest: Bool {
        ProcessInfo.processInfo.environment["OPENBURNBAR_UITEST_OPEN_SETTINGS"] == "1"
    }

    /// OpenBurnBar is a menu-bar and background-service host, so closing its
    /// last visible window must not terminate the process. The XCTest stub scene
    /// is the only exception: keeping that host alive would outlive the runner.
    static var shouldDisableAutomaticTerminationForApplication: Bool {
        shouldDisableAutomaticTerminationForApplication(
            shouldUseTestStubScene: shouldUseTestStubScene
        )
    }

    static func shouldDisableAutomaticTerminationForApplication(
        shouldUseTestStubScene: Bool
    ) -> Bool {
        !shouldUseTestStubScene
    }

    @MainActor
    static func beginApplicationHostActivityIfNeeded() {
        guard shouldDisableAutomaticTerminationForApplication,
              applicationHostActivity == nil else { return }
        // cov:ignore-start -- process-lifetime NSProcessInfo activity: the guard above keeps this from running under the XCTest stub scene, so these lines only execute in a real app process; the gating decision is unit-tested via shouldDisableAutomaticTerminationForApplication(shouldUseTestStubScene:)
        let processInfo = ProcessInfo.processInfo
        processInfo.disableSuddenTermination()
        processInfo.disableAutomaticTermination("OpenBurnBar background services are active")
        applicationHostActivity = processInfo.beginActivity(
            options: [.automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "OpenBurnBar background services are active"
        )
        // cov:ignore-end
    }

    /// Protects the XCTest runner-connect window by bypassing the live menu-bar scene.
    static var shouldUseTestStubScene: Bool {
        shouldUseTestStubScene(isRunningTests: isRunningTests, forceLiveScene: forceLiveScene)
    }

    static func shouldUseTestStubScene(isRunningTests: Bool, forceLiveScene: Bool) -> Bool {
        isRunningTests && !forceLiveScene
    }
}

enum StartupProfiler {
    private static let log = OSLog(subsystem: "com.openburnbar.app", category: "Startup")

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }

    @discardableResult
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try body()
    }
}

/// Closes SwiftUI's auto-opened background `Window` so the menu-bar icon is the
/// only idle OpenBurnBar surface.
private struct BackgroundSceneSentinel: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(BackgroundSceneWindowDismisser())
    }
}

private struct BackgroundSceneWindowDismisser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.close()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.close()
        }
    }
}

// MARK: - App Entry Point

@main
struct OpenBurnBarApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hasShownInitialDashboard") var hasShownInitialDashboard = false
    @StateObject var windowManager = WindowManager.shared
    @State var startupState: OpenBurnBarStartupState
    @State var isRetryingStartup = false
    @State var isArchivingReset = false
    @State var startupRecoveryActionError: String?
    @State var hasPresentedStartupRecoveryWindow = false
    @State var periodicRefreshTask: Task<Void, Never>?
    @State var navigationCoordinator = NavigationCoordinator()
    @State var didOpenUITestDashboard = false

    init() {
        Self.runDomainCoreReleaseIdentityModeIfRequested()
        StartupProfiler.event("app_init_start")
        if OpenBurnBarRuntime.shouldUseTestStubScene {
            // XCTest host fast path. The developer's real `OpenBurnBar` support
            // directory frequently grows past several GB; opening the canonical
            // on-disk SQLite database from `App.init` synchronously can take
            // long enough to race the XCTest runner-connect handshake (the
            // opaque `"test runner hung before establishing connection"`
            // failure mode). We therefore skip every form of synchronous boot:
            //   - No Firebase / Sentry / Google Sign-In configuration.
            //   - No `OpenBurnBarCore.OpenBurnBarMigration.migrateUserDefaults()` (the legacy-
            //     domain scan can stall briefly under XCTest sandboxing).
            //   - No `DataStore` open. The live menu-bar scene is short-
            //     circuited to `EmptyView` for both content and label by
            //     `OpenBurnBarRuntime.shouldUseTestStubScene` so `startupState`
            //     is never read in this branch. Tests open their own isolated
            //     `DataStore`s in `setUp`; the placeholder below exists only
            //     to satisfy `_startupState`'s non-optional initial value.
            _startupState = State(initialValue: .failed(
                DataStoreStartupFailure.testStubPlaceholder()
            ))
            return
        }

        Self.seedUITestDefaultsIfNeeded()

        StartupProfiler.interval("configure_firebase") {
            Self.configureFirebaseIfAvailable(accountManager: .shared)
        }
        StartupProfiler.interval("domain_core_shadow_evidence_init") {
            ProviderQuotaMacPlatform.installDomainCoreShadowEvidenceRecorder()
        }
        StartupProfiler.interval("configure_sentry") {
            Self.configureSentryIfAvailable()
        }
        StartupProfiler.interval("configure_analytics") {
            Self.configureAnalytics()
        }
        StartupProfiler.interval("migrate_user_defaults") {
            OpenBurnBarCore.OpenBurnBarMigration.migrateUserDefaults()
        }

        _startupState = State(initialValue: StartupProfiler.interval("make_startup_state") {
            Self.makeStartupState()
        })
        StartupProfiler.event("app_init_end")
    }

    private static func runDomainCoreReleaseIdentityModeIfRequested() {
        // The irreversible side effects (stderr writes + process exit) live here; the
        // deterministic argument/env validation and the reporter dispatch are resolved
        // by the testable `domainCoreReleaseIdentityRequest` helper, which mirrors this
        // exact policy without touching the process lifecycle.
        switch domainCoreReleaseIdentityRequest(executableURL: Bundle.main.executableURL) {
        case .notRequested:
            return
        case .invalidInvocation:
            FileHandle.standardError.write(Data("invalid domain-core release identity invocation\n".utf8))
            exit(EXIT_FAILURE)
        case .success:
            exit(EXIT_SUCCESS)
        case .failure(let errorDescription):
            FileHandle.standardError.write(
                Data("domain-core release identity failed: \(errorDescription)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func seedUITestDefaultsIfNeeded() {
        guard OpenBurnBarRuntime.isUITestLaunch else { return }
        UserDefaults.standard.set(true, forKey: "hasOnboarded")
        UserDefaults.standard.set(true, forKey: "hasShownInitialDashboard")
        UserDefaults.standard.set(true, forKey: "conversationIndexingConsentShown")
        UserDefaults.standard.set(true, forKey: "cliAssistantConsentShown")
        UserDefaults.standard.removeObject(forKey: SettingsDeepLinkRouting.pendingTabKey)
        UserDefaults.standard.removeObject(forKey: SettingsDeepLinkRouting.pendingItemKey)
    }

    @MainActor
    static func makeStartupState(archiveURL: URL? = nil) -> OpenBurnBarStartupState {
        do {
            return .ready(try makeRuntimeContext())
        } catch {
            AppLogger.dataStore.error(
                "startup_datastore_open_failed",
                metadata: ["error": String(describing: error)]
            )
            Analytics.shared.track(.appStartupFailed, [
                "error_type": .string(String(describing: type(of: error)))
            ])
            return .failed(DataStoreStartupFailure.make(error: error, archiveURL: archiveURL))
        }
    }

    @MainActor
    private static func makeRuntimeContext() throws -> OpenBurnBarRuntimeContext {
        let initializedStore = try StartupProfiler.interval("datastore_open") {
            try DataStoreCoordinator()
        }
        let settings = StartupProfiler.interval("settings_init") {
            SettingsManager.shared
        }
        let accountManager = AccountManager.shared
        let quotaService = StartupProfiler.interval("quota_service_init") {
            ProviderQuotaService(settingsManager: settings)
        }
        let daemonManager = StartupProfiler.interval("daemon_manager_init") {
            OpenBurnBarDaemonManager.shared // cov:ignore -- app composition root: singleton graph initialization is covered by app startup smoke tests.
        }
        let cursorConnectorManager = StartupProfiler.interval("cursor_connector_init") {
            CursorConnectorManager(settingsManager: settings)
        }

        // Phase 4 — wire BudgetSettings + BudgetGate so `BudgetEnforcement.shared.evaluate`
        // returns real decisions for AgentLens-plane requests. The daemon plane reads the
        // same `budget_rules` table directly (Phase 4 Part B).
        let budgetRulesStore = BudgetRulesStore(dbQueue: initializedStore.actor.dbQueue)
        let budgetSettings = BudgetSettings(
            store: budgetRulesStore,
            alertSettings: settings.alerts,
            deviceID: ProcessInfo.processInfo.globallyUniqueString
        )
        let budgetLedger = BudgetLedger(dbQueue: initializedStore.actor.dbQueue)
        let budgetGate = BudgetGate(settings: budgetSettings, ledger: budgetLedger)
        let budgetNotifications = BudgetNotificationCenter()
        let budgetForecast = BudgetForecast(dbQueue: initializedStore.actor.dbQueue)
        StartupProfiler.interval("budget_enforcement_configure") {
            BudgetEnforcement.shared.configure(
                gate: budgetGate,
                notifications: budgetNotifications,
                forecast: budgetForecast
            )
        }

        // PR-D3: one shared store backs the recall service + drain engine (built pre-controller).
        let memoryServices = StartupProfiler.interval("memory_services_init") {
            makeMemoryServices(dataStore: initializedStore, settingsManager: settings, accountManager: accountManager)
        }
        let controller = StartupProfiler.interval("chat_controller_init") {
            ChatSessionController(
                dataStore: initializedStore,
                settingsManager: settings,
                memoryService: memoryServices.service,
                memoryExtractionEngine: memoryServices.engine
            )
        }
        let layer = StartupProfiler.interval("operating_layer_init") {
            OpenBurnBarOperatingLayer(
                dataStore: initializedStore,
                settingsManager: settings,
                accountManager: accountManager,
                daemonManager: daemonManager,
                chatController: controller
            )
        }

        let context = OpenBurnBarRuntimeContext(
            dataStore: initializedStore,
            settingsManager: settings,
            accountManager: accountManager,
            quotaService: quotaService,
            daemonManager: daemonManager,
            cursorConnectorManager: cursorConnectorManager,
            chatController: controller,
            operatingLayer: layer
        )
        context.applyMemoryServices(memoryServices)
        #if canImport(AppKit) && !DISTRIBUTION_MAS
        let textExpansionRuntime = TextExpansionRuntimeController(
            dataStore: initializedStore,
            settingsManager: settings
        )
        context.textExpansionRuntimeController = textExpansionRuntime
        #endif
        StartupProfiler.event("runtime_context_ready")
        return context
    }

    #if DEBUG
    @MainActor
    private func toggleHermesIrohTransportFromDebugMenu() {
        guard let context = startupState.runtimeContext else {
            NSSound.beep()
            return
        }
        context.settingsManager.hermesRemoteRelayEnabled = true
        context.settingsManager.hermesIrohTransportEnabled.toggle()
    }
    #endif

    private var liveMenuBarScene: some Scene {
        // Side effects stay OUTSIDE any result builder: a plain computed var
        // sequences statements freely, where `@SceneBuilder` would try to type
        // each one as a Scene component.
        installCommandRouter()
        OpenBurnBarRuntime.beginApplicationHostActivityIfNeeded()
        openUITestDashboardIfNeeded()
        presentStartupRecoveryIfNeeded()
        // The AppDelegate owns the live status item + popover via AppKit
        // (`NSPopover` survives SwiftUI's macOS-26/Tahoe `MenuBarExtra(.window)`
        // regression). SceneBuilder still needs at least one Scene to satisfy
        // the type checker, so we declare a `Window` whose body immediately
        // closes its own host window. macOS auto-shows the first scene on
        // launch, so we collapse that auto-opened window the instant SwiftUI
        // hands us the chance.
        return Window("OpenBurnBar", id: "openburnbar.background") {
            BackgroundSceneSentinel()
        }
        .windowResizability(.contentSize)
    }

    /// When the app fails to open the data store, the AppDelegate's status item
    /// still mounts but renders an empty popover. Surface the recovery window
    /// so the user has actionable UI.
    @MainActor
    private func presentStartupRecoveryIfNeeded() {
        guard !OpenBurnBarRuntime.shouldUseTestStubScene else { return }
        guard !OpenBurnBarRuntime.isUITestLaunch else { return }
        guard case .failed = startupState else { return }
        guard !hasPresentedStartupRecoveryWindow else { return }
        hasPresentedStartupRecoveryWindow = true
        DispatchQueue.main.async { [self] in
            openStartupRecoveryWindow()
        }
    }

    @MainActor
    private func openUITestDashboardIfNeeded() {
        guard OpenBurnBarRuntime.isUITestLaunch else { return }
        guard !didOpenUITestDashboard else { return }
        guard startupState.runtimeContext != nil else { return }
        didOpenUITestDashboard = true

        Self.seedUITestDefaultsIfNeeded()
        if case .ready(let context) = startupState {
            context.settingsManager.conversationIndexingConsentShown = true
            context.settingsManager.cliAssistantConsentShown = true
        }

        DispatchQueue.main.async {
            AppCommandRouter.shared.openDashboard?()
            if OpenBurnBarRuntime.shouldOpenSettingsForUITest {
                AppCommandRouter.shared.openSettings?()
            }
        }
    }

    /// The live menu-bar scene already short-circuits both `content` and `label`
    /// to `EmptyView()` when `OpenBurnBarRuntime.isRunningTests` is true (see
    /// `liveMenuBarScene` above), so all heavyweight work (popover construction,
    /// `task` blocks, daemon attaches, periodic refresh) is already gated. The
    /// remaining XCTest-host concern (synchronous `DataStore` open + Firebase /
    /// Sentry boot) is handled in `init()`. Returning `liveMenuBarScene`
    /// unconditionally keeps `body` as a single concrete `Scene` type, avoiding
    /// SwiftUI's `SceneBuilder` if/else inference quirks.
    @SceneBuilder
    var body: some Scene {
        liveMenuBarScene
            .commands {
                // Standard macOS Cmd-, binding. Without this, Settings only
                // opens from the status-item menu's key equivalent, which is
                // active solely while that menu is open.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        AppCommandRouter.shared.openSettings?()
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .help) {
                    Button("How Memory Works…") {
                        _ = SettingsDeepLinkRouting.route(to: "cloud.memoryTour")
                        AppCommandRouter.shared.openSettings?()
                    }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                }
                #if DEBUG
                CommandMenu("Debug") {
                    Button(
                        startupState.runtimeContext?.settingsManager.hermesIrohTransportEnabled == true
                            ? "Disable Hermes iroh Transport"
                            : "Enable Hermes iroh Transport"
                    ) {
                        toggleHermesIrohTransportFromDebugMenu()
                    }
                    .keyboardShortcut("i", modifiers: [.command, .option, .control])
                }
                #else
                CommandGroup(after: .appInfo) {}
                #endif
            }

        // Mercury Phase 8 — global chrome window. Hosts the
        // `IncomingCallSheet` (when an iPhone asks to mirror) and the
        // `CallHUD` (while a mirror is active), independent of the
        // menu-bar popover's open state. Auto-shows when the router
        // transitions out of `.idle`/`.cooldown`; auto-hides otherwise.
        WindowGroup(id: "mercury.chrome") {
            if let context = startupState.runtimeContext,
               let router = context.mercuryRouter,
               let peerSource = context.mercuryPeerSource,
               let hud = context.mercuryCallHUDState {
                MercuryChromeRoot(
                    router: router,
                    peerSource: peerSource,
                    hudState: hud
                )
                .environment(context.accountManager)
            } else {
                EmptyView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
