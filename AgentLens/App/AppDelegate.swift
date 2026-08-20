import AppKit
import Carbon
import GoogleSignIn
import OpenBurnBarCore

/// Hosts the OpenBurnBar status item and popover.
///
/// SwiftUI `MenuBarExtra(.window)` regressed on macOS 26 (Tahoe): the click is
/// delivered to the status-item scene client but the popover panel never
/// renders. We host the dropdown ourselves with `NSPopover`, which is the
/// AppKit pattern that continues to work across every macOS release. The
/// popover's content is the same SwiftUI view tree (`MenuBarPopoverView`) used
/// by the rest of the app, vended through `AppCommandRouter`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem?
    // Internal access is the unit-test read seam (the setter is internal so
    // AppDelegate+StatusItem.swift can install the popover) — the menu-bar status item never exists in the
    // XCTest host, so tests drive `installPopoverPrewarming()` /
    // `primePopoverContent()` directly and inspect the result here.
    var popover: NSPopover?
    var glassPopoverPanel: OpenBurnBarGlassPopoverPanel?
    var popoverPrewarmer: PopoverContentPrewarmer?
    var statusItemLocalMouseMonitor: Any?
    let popoverDismissController = PopoverDismissController()
    var lastHandledStatusItemEventKey: OpenBurnBarStatusItemClick.EventKey?
    var lastHandledStatusItemEventTime: TimeInterval = 0

    // live wallpaper variables
    var settingsManager: SettingsManager? {
        didSet {
            guard oldValue !== settingsManager else { return }
            applyWallpaperAppearance()
            refreshMenuBarIconStyle()
            observeMenuBarIconStyle()
            observeMenuBarValue()
            updateWallpaperState()
            configureWallpaperActivityPolling()
            syncWallpaperColorDriver()
        }
    }
    var dataStore: DataStore? {
        didSet {
            setupWallpaperObservers()
            observeMenuBarValue()
            if let dataStore {
                let dataStoreActor = dataStore.actor
                Task.detached(priority: .background) {
                    await dataStoreActor.runWorkingDirectoryBackfillIfNeeded()
                }
            }
        }
    }
    weak var usageAggregator: UsageAggregator?
    var daemonManager: OpenBurnBarDaemonManager? {
        didSet {
            setupWallpaperObservers()
        }
    }

    var wallpaperPanels: [BurnBarWallpaperPanel] = []
    var sharedWallpaperViewModel = SwarmWallpaperViewModel()
    var originalDesktopImageURLByScreenID: [CGDirectDisplayID: URL] = [:]
    var installedDesktopFallbackByScreenID: [CGDirectDisplayID: DesktopWallpaperBackground] = [:]

    // Observers
    var wallpaperEnabledObserver: Any?
    var wallpaperBackgroundObserver: Any?
    var wallpaperSpeedObserver: Any?
    var wallpaperProviderGlyphsObserver: Any?
    var wallpaperCycleShapesObserver: Any?
    var wallpaperSparklesObserver: Any?
    var wallpaperExcludeBrandShapesObserver: Any?
    var wallpaperClickCycleObserver: Any?
    var wallpaperPollTimer: Timer?
    var dataStoreObservation: Any?
    var daemonObservation: Any?
    var menuBarValueObservation: Any?
    var batteryNotificationSource: CFRunLoopSource?
    var wallpaperActivityTimer: Timer?
    var wallpaperAgentStatusObserver: NSObjectProtocol?
    var wallpaperSpaceChangeObserver: NSObjectProtocol?
    var wallpaperColorDriverTask: Task<Void, Never>?

    // RR-5: Cloud Vault rotation pickup. A revoke initiated from an offline or
    // unavailable device leaves the rotation requirement `pending`, so the
    // revoked device's cached key is not yet retired. This surviving Mac
    // discovers those pending requirements on foreground/launch (and right after
    // a local revoke) and finishes the rotation when it is an eligible survivor.
    private var cloudVaultRotationPickupObserver: NSObjectProtocol?
    private var postRevokeCloudVaultRotationPickupObserver: NSObjectProtocol?
    private var lastCloudVaultRotationPickupAt: TimeInterval = 0
    private var isPreparingToTerminate = false

    // Analytics: app foreground/background lifecycle observer.
    private var appResignActiveAnalyticsObserver: NSObjectProtocol?
    /// Foreground passes within this window of the last attempt are coalesced so
    /// rapid activate/deactivate cycles don't spam the server callable.
    private static let cloudVaultRotationPickupDebounceInterval: TimeInterval = 30

    // Status-item icon/badge observation state (driven by AppDelegate+StatusItem).
    var menuBarIconObservation: Any?
    var updateBadgeObservation: Any?
    var updateBadgeView: NSView?
    private var performanceGateVisibilityObserver: NSObjectProtocol?
    private var performanceGateHiddenWindows: [NSWindow] = []
    private var performanceGateWindowDidExposeObserver: NSObjectProtocol?
    private var performanceGateWindowsShouldBeVisible = true

    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            applicationOnMainActor(application, open: urls)
        }
    }

    private func applicationOnMainActor(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if AppCommandRouter.shared.handle(url) {
            return
        }
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    nonisolated func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            installPerformanceGateVisibilityControlIfNeeded()
        }
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            applicationDidFinishLaunchingOnMainActor()
        }
    }

    private func applicationDidFinishLaunchingOnMainActor() {
        guard enforceSingleOpenBurnBarInstance() else { return }
        OpenBurnBarRuntime.beginApplicationHostActivityIfNeeded()

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        guard !OpenBurnBarRuntime.shouldUseTestStubScene else { return }
        installStatusItem()
        installPopoverPrewarming()
        guard OpenBurnBarRuntime.shouldStartBackgroundApplicationServices(
            isPerformanceGateLaunch: OpenBurnBarRuntime.isPerformanceGateLaunch
        ) else { return }
#if !DISTRIBUTION_MAS
        DirectDownloadUpdateChecker.shared.startAutomaticChecks()
        Task {
            await GrokDFeature.startLocalBoxIfNeeded()
        }
#endif

        // Start wallpaper orchestration
        observeDesktopWallpaper()
        updateWallpaperState()
        setupPowerMonitoring()
        setupScreenChangeObserver()

        // RR-5: pick up any pending Cloud Vault rotations this Mac is a survivor
        // for — on every foreground and once right after a local revoke.
        observeCloudVaultRotationPickupTriggers()
        pickUpPendingCloudVaultRotations(force: true)
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
    private func installPerformanceGateVisibilityControlIfNeeded() {
        guard OpenBurnBarRuntime.isPerformanceGateLaunch,
              performanceGateVisibilityObserver == nil else { return }

        performanceGateVisibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: OpenBurnBarRuntime.performanceGateVisibilityNotification,
            object: OpenBurnBarRuntime.currentPerformanceGateNotificationObject,
            queue: .main
        ) { [weak self] notification in
            guard let visible = notification.userInfo?["visible"] as? Bool else { return }
            MainActor.assumeIsolated {
                self?.setPerformanceGateWindowsVisible(visible)
            }
        }
        performanceGateWindowDidExposeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExposeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.hidePerformanceGateWindowIfNeeded(window)
            }
        }
    }

    private func setPerformanceGateWindowsVisible(_ visible: Bool) {
        performanceGateWindowsShouldBeVisible = visible
        if visible {
            let windows = performanceGateHiddenWindows
            performanceGateHiddenWindows.removeAll(keepingCapacity: true)
            if windows.isEmpty {
                if !NSApplication.shared.windows.contains(where: \.isVisible) {
                    AppCommandRouter.shared.openDashboard?()
                }
                return
            }
            for window in windows {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                } else {
                    window.orderFrontRegardless()
                }
            }
            return
        }

        for window in NSApplication.shared.windows where window.isVisible {
            hidePerformanceGateWindowIfNeeded(window)
        }
    }

    private func hidePerformanceGateWindowIfNeeded(_ window: NSWindow) {
        guard !performanceGateWindowsShouldBeVisible else { return }
        if !performanceGateHiddenWindows.contains(where: { $0 === window }) {
            performanceGateHiddenWindows.append(window)
        }
        if window.styleMask.contains(.miniaturizable) {
            window.miniaturize(nil)
        }
        if window.isVisible {
            window.orderOut(nil)
        }
    }

    /// Registers the foreground + post-revoke triggers for the RR-5 Cloud Vault
    /// rotation pickup. Foreground passes are debounced; the post-revoke pass
    /// fires immediately so a local revoke completes the rotation chain even when
    /// the app stays in the foreground.
    private func observeCloudVaultRotationPickupTriggers() {
        guard !OpenBurnBarRuntime.isRunningTests else { return }
        if cloudVaultRotationPickupObserver == nil {
            cloudVaultRotationPickupObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    Analytics.shared.track(.appForegrounded)
                    self?.pickUpPendingCloudVaultRotations(force: false)
                }
            }
        }
        if appResignActiveAnalyticsObserver == nil {
            appResignActiveAnalyticsObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    // The glass tray sits at `.statusBar` with
                    // `hidesOnDeactivate = false`, so leaving it open when the
                    // user clicks another app keeps BurnBar chrome glued above
                    // everything. Close it on resign so the desktop behaves
                    // like any other Mac app.
                    self?.closePopoverOnResignActive()
                    Analytics.shared.track(.appBackgrounded)
                }
            }
        }
        if postRevokeCloudVaultRotationPickupObserver == nil {
            postRevokeCloudVaultRotationPickupObserver = NotificationCenter.default.addObserver(
                forName: .openBurnBarDidRevokeDeviceTrust,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.pickUpPendingCloudVaultRotations(force: true) }
            }
        }
    }

    /// Fire-and-forget RR-5 Cloud Vault rotation pickup. Non-fatal on any error
    /// (signed-out, network, no eligible requirements) — it simply retries on the
    /// next foreground/revoke. `force` bypasses the foreground debounce for the
    /// launch and post-revoke passes.
    private func pickUpPendingCloudVaultRotations(force: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        if !force,
           now - lastCloudVaultRotationPickupAt < Self.cloudVaultRotationPickupDebounceInterval {
            return
        }
        lastCloudVaultRotationPickupAt = now

        let rotatingDeviceId = MacLiveDeviceTrustGateway.loadOrCreateDeviceId()
        Task {
            do {
                let result = try await ComputerUseSecurityCallableClient.pickUpPendingCloudVaultRotations(
                    rotatingDeviceId: rotatingDeviceId
                )
                if !result.completedRequirementIds.isEmpty || !result.failedRequirements.isEmpty {
                    AppLogger.sync.info(
                        "cloud_vault_rotation_pickup_complete",
                        metadata: [
                            "eligible": String(result.eligibleRequirementIds.count),
                            "completed": String(result.completedRequirementIds.count),
                            "failed": String(result.failedRequirements.count)
                        ]
                    )
                }
            } catch {
                AppLogger.sync.error(
                    "cloud_vault_rotation_pickup_failed",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func enforceSingleOpenBurnBarInstance() -> Bool {
        guard !OpenBurnBarRuntime.isRunningTests,
              ProcessInfo.processInfo.environment["OPENBURNBAR_ALLOW_MULTIPLE_INSTANCES"] != "1",
              let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return true
        }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        let installedBundleURL = URL(fileURLWithPath: "/Applications/OpenBurnBar.app").standardizedFileURL
        let isInstalledApp = currentBundleURL == installedBundleURL
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentProcessIdentifier }

        if isInstalledApp {
            for peer in peers where peer.bundleURL?.standardizedFileURL != installedBundleURL {
                NSLog("OpenBurnBar: terminating stale duplicate instance at %@", peer.bundleURL?.path ?? "unknown")
                peer.terminate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    if !peer.isTerminated {
                        peer.forceTerminate()
                    }
                }
            }
            return true
        }

        if peers.contains(where: { $0.bundleURL?.standardizedFileURL == installedBundleURL }) {
            NSLog("OpenBurnBar: exiting stale duplicate instance at %@", currentBundleURL.path)
            NSApp.terminate(nil)
            return false
        }

        return true
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        if AppCommandRouter.shared.handle(url) {
            return
        }
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            applicationShouldTerminateOnMainActor(sender)
        }
    }

    private func applicationShouldTerminateOnMainActor(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if OpenBurnBarRuntime.isRunningTests {
            return .terminateNow
        }
        if isPreparingToTerminate {
            return .terminateLater
        }
        isPreparingToTerminate = true

        // Abort in-flight SQLCipher page decrypts before NSApp is allowed to
        // call `exit()`. The crash report's faulting thread was still inside
        // `sqlcipher_memset` on `GRDB.DatabasePool.reader.3` while the main
        // thread was already in `-[NSApplication terminate:]`.
        dataStore?.interruptDatabaseReaders()
        usageAggregator?.stopBackgroundWork()
        BackgroundCadenceCoordinator.shared.unregisterAll()
        ProviderQuotaService.shared.stopAutomaticRefresh()

        Task { @MainActor in
            await dataStore?.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            applicationWillTerminateOnMainActor()
        }
    }

    private func applicationWillTerminateOnMainActor() {
        Analytics.shared.track(.appSessionEnded)
        uninstallStatusItemMouseFallback()
        teardownWallpaperPanels()
        teardownWallpaperObservers()
        if let observer = cloudVaultRotationPickupObserver {
            NotificationCenter.default.removeObserver(observer)
            cloudVaultRotationPickupObserver = nil
        }
        if let observer = postRevokeCloudVaultRotationPickupObserver {
            NotificationCenter.default.removeObserver(observer)
            postRevokeCloudVaultRotationPickupObserver = nil
        }
        if let observer = appResignActiveAnalyticsObserver {
            NotificationCenter.default.removeObserver(observer)
            appResignActiveAnalyticsObserver = nil
        }
        if let observer = performanceGateVisibilityObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            performanceGateVisibilityObserver = nil
        }
    }
}

public extension Notification.Name {
    /// Posted on the main queue right after a local device-trust revoke
    /// completes (`DeviceTrustViewModel.revoke`). The app delegate observes this
    /// to run the RR-5 Cloud Vault rotation pickup immediately, so the revoking
    /// Mac finishes the rotation chain without waiting for the next foreground.
    static let openBurnBarDidRevokeDeviceTrust = Notification.Name("openBurnBarDidRevokeDeviceTrust")
}

// The direct-download update checker (verified download + Ed25519 signature
// check against SUPublicEDKey) lives in
// AgentLens/Services/DirectDownloadUpdateService.swift.
