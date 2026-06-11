import AppKit
import Carbon
import GoogleSignIn
import QuartzCore
import SwiftUI
import IOKit.ps
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
    private var statusItem: NSStatusItem?
    // Internal read access (`private(set)`) is the unit-test seam for the
    // popover prewarm wiring — the menu-bar status item never exists in the
    // XCTest host, so tests drive `installPopoverPrewarming()` /
    // `primePopoverContent()` directly and inspect the result here.
    private(set) var popover: NSPopover?
    private(set) var popoverPrewarmer: PopoverContentPrewarmer?
    private var statusItemLocalMouseMonitor: Any?
    private var statusItemGlobalMouseMonitor: Any?
    private var lastHandledStatusItemEventKey: OpenBurnBarStatusItemClick.EventKey?
    private var lastHandledStatusItemEventTime: TimeInterval = 0

    // live wallpaper variables
    public var dataStore: DataStore? = nil {
        didSet {
            setupWallpaperObservers()
            if let dataStore {
                let database = dataStore.database
                Task.detached(priority: .background) {
                    await WorkingDirectoryBackfillService().runIfNeeded(database: database)
                }
            }
        }
    }
    public var daemonManager: OpenBurnBarDaemonManager? = nil {
        didSet {
            setupWallpaperObservers()
        }
    }

    private var wallpaperPanels: [BurnBarWallpaperPanel] = []
    private var sharedWallpaperViewModel = SwarmWallpaperViewModel()
    private var originalDesktopImageURLByScreenID: [CGDirectDisplayID: URL] = [:]
    private var installedDesktopFallbackByScreenID: [CGDirectDisplayID: DesktopWallpaperBackground] = [:]

    // Observers
    private var wallpaperEnabledObserver: Any?
    private var wallpaperBackgroundObserver: Any?
    private var wallpaperSpeedObserver: Any?
    private var wallpaperProviderGlyphsObserver: Any?
    private var wallpaperCycleShapesObserver: Any?
    private var wallpaperExcludeBrandShapesObserver: Any?
    private var wallpaperClickCycleObserver: Any?
    private var wallpaperPollTimer: Timer?
    private var dataStoreObservation: Any?
    private var daemonObservation: Any?
    private var batteryNotificationSource: CFRunLoopSource?
    private var wallpaperActivityTimer: Timer?
    private var wallpaperAgentStatusObserver: NSObjectProtocol?
    private var wallpaperSpaceChangeObserver: NSObjectProtocol?
    private var wallpaperColorDriverTask: Task<Void, Never>?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if AppCommandRouter.shared.handle(url) {
            return
        }
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard enforceSingleOpenBurnBarInstance() else { return }
        OpenBurnBarRuntime.beginHarnessHostActivityIfNeeded()

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        guard !OpenBurnBarRuntime.shouldUseTestStubScene else { return }
        installStatusItem()
        installPopoverPrewarming()
#if !DISTRIBUTION_MAS
        DirectDownloadUpdateChecker.shared.startAutomaticChecks()
#endif

        // Start wallpaper orchestration
        observeDesktopWallpaper()
        updateWallpaperState()
        setupPowerMonitoring()
        setupScreenChangeObserver()
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
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

    private func installStatusItem() {
        if statusItem != nil {
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = OpenBurnBarStatusItemBrandMark.image(
                colorful: SettingsManager.shared.appearance.colorfulMenuBarIcon
            )
            button.imagePosition = .imageOnly
            button.toolTip = "OpenBurnBar"
            button.setAccessibilityLabel("OpenBurnBar")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: OpenBurnBarStatusItemClick.actionMask)
        }
        self.statusItem = item
        installStatusItemMouseFallback()
        observeMenuBarIconStyle()
    }

    private var menuBarIconObservation: Any?

    /// Watches `colorfulMenuBarIcon` and swaps the status item image live.
    private func observeMenuBarIconStyle() {
        menuBarIconObservation = withObservationTracking {
            _ = SettingsManager.shared.appearance.colorfulMenuBarIcon
            return nil as Any?
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let button = self.statusItem?.button else { return }
                button.image = OpenBurnBarStatusItemBrandMark.image(
                    colorful: SettingsManager.shared.appearance.colorfulMenuBarIcon
                )
                self.observeMenuBarIconStyle()
            }
        }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton ?? statusItem?.button else {
            return
        }
        let event = NSApp.currentEvent
        guard shouldHandleStatusItemEvent(event) else { return }

        switch OpenBurnBarStatusItemClick.action(for: event?.type) {
        case .togglePopover:
            togglePopover(button)
        case .showSecondaryMenu:
            showSecondaryMenu(button)
        case .ignore:
            break
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if let popover = popover, popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover(sender)
        }
    }

    private func showPopover(_ sender: NSStatusBarButton) {
        let popover = ensurePopover()

        // Fallback only: the prewarmer rebuilds content off the click path
        // after launch and after every close (§15 of
        // docs/architecture/macos-performance.md). This branch covers a
        // click that outruns the scheduled prime.
        if popover.contentViewController == nil {
            installPopoverContent(into: popover)
        }

        // Cheap when prewarmed (layout already ran during the prime);
        // re-reading keeps the size honest for data that changed since.
        let size = popover.contentViewController?.view.fittingSize ?? .zero
        if size.width > 1 && size.height > 1 {
            popover.contentSize = size
        } else {
            // Fallback to defaults if fittingSize is not yet available
            popover.contentSize = NSSize(width: 340, height: 540)
        }

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }

    private func ensurePopover() -> NSPopover {
        if let popover {
            return popover
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        self.popover = popover
        return popover
    }

    /// Builds a brand-new content controller from the CURRENT router
    /// factory and installs it. Shared by the click-path fallback and the
    /// off-click prewarm.
    private func installPopoverContent(into popover: NSPopover) {
        let content = AppCommandRouter.shared.makeMenuBarPopoverContent?({ [weak popover] in
            popover?.performClose(nil)
        }) ?? AnyView(Text("No Content"))

        let host = NSHostingController(rootView: content)
        popover.contentViewController = host
    }

    // Internal (not private) so the popover prewarm wiring is unit-testable;
    // production callers are unchanged (applicationDidFinishLaunching and the
    // prewarmer's prime closure).
    func installPopoverPrewarming() {
        let prewarmer = PopoverContentPrewarmer(
            isPopoverShown: { [weak self] in self?.popover?.isShown ?? false },
            prime: { [weak self] in self?.primePopoverContent() }
        )
        popoverPrewarmer = prewarmer
        AppCommandRouter.shared.onMenuBarPopoverFactoryChanged = { [weak prewarmer] in
            prewarmer?.schedulePrime()
        }
        // The real factory can land before this hook installs (SwiftUI body
        // vs. applicationDidFinishLaunching ordering is not guaranteed).
        if AppCommandRouter.shared.makeMenuBarPopoverContent != nil {
            prewarmer.schedulePrime()
        }
    }

    /// Rebuilds the popover content from the current factory and primes the
    /// expensive first layout — all off the click path. Rebuilding (rather
    /// than keeping a stale controller) preserves the deliberate
    /// fresh-state-on-show behavior from fd19d53ac and guarantees a factory
    /// reinstall (e.g. EmptyView fallback → real runtime content) never
    /// freezes stale content into the popover.
    func primePopoverContent() {
        guard AppCommandRouter.shared.makeMenuBarPopoverContent != nil else { return }
        let popover = ensurePopover()
        installPopoverContent(into: popover)
        _ = popover.contentViewController?.view.fittingSize
    }

    private func installStatusItemMouseFallback() {
        guard statusItemLocalMouseMonitor == nil, statusItemGlobalMouseMonitor == nil else {
            return
        }

        let mask = OpenBurnBarStatusItemClick.actionMask
        statusItemLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleStatusItemFallbackMouseEvent(event)
            return event
        }
        statusItemGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in
                self?.handleStatusItemFallbackMouseEvent(event)
            }
        }
    }

    private func uninstallStatusItemMouseFallback() {
        if let monitor = statusItemLocalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            statusItemLocalMouseMonitor = nil
        }
        if let monitor = statusItemGlobalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            statusItemGlobalMouseMonitor = nil
        }
    }

    private func handleStatusItemFallbackMouseEvent(_ event: NSEvent) {
        guard let button = statusItem?.button,
              let frame = button.openBurnBarScreenFrame,
              OpenBurnBarMenuExtraClickFallback.click(NSEvent.mouseLocation, hits: frame),
              shouldHandleStatusItemEvent(event)
        else {
            return
        }

        switch OpenBurnBarStatusItemClick.action(for: event.type) {
        case .togglePopover:
            togglePopover(button)
        case .showSecondaryMenu:
            showSecondaryMenu(button)
        case .ignore:
            break
        }
    }

    private func shouldHandleStatusItemEvent(_ event: NSEvent?) -> Bool {
        guard let event else { return true }
        let key = OpenBurnBarStatusItemClick.EventKey(event)
        if key == lastHandledStatusItemEventKey {
            return false
        }
        if event.timestamp - lastHandledStatusItemEventTime < 0.12 {
            return false
        }
        lastHandledStatusItemEventKey = key
        lastHandledStatusItemEventTime = event.timestamp
        return true
    }

    private func showSecondaryMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboardAction(_:)), keyEquivalent: "d")
        menu.addItem(withTitle: "Settings...", action: #selector(openSettingsAction(_:)), keyEquivalent: ",")
#if !DISTRIBUTION_MAS
        // cov:ignore on the next line -- status-menu wiring; behavior is
        // line-gated in the DirectDownload* companion tests.
        // swiftlint:disable:next line_length
        menu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdatesAction(_:)), keyEquivalent: "") // cov:ignore -- menu glue
#endif
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(OpenBurnBarIdentity.productName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openDashboardAction(_ sender: Any?) {
        AppCommandRouter.shared.openDashboard?()
    }

    @objc private func openSettingsAction(_ sender: Any?) {
        AppCommandRouter.shared.openSettings?()
    }

#if !DISTRIBUTION_MAS
    @objc private func checkForUpdatesAction(_ sender: Any?) { // cov:ignore -- menu-action glue; checkForUpdatesNow's logic is line-gated in the DirectDownload* companions
        DirectDownloadUpdateChecker.shared.checkForUpdatesNow() // cov:ignore -- see above
    }
#endif

    // MARK: - Live Wallpaper Orchestration

    private func observeDesktopWallpaper() {
        wallpaperEnabledObserver = NotificationCenter.default.addObserver(
            forName: .enableDesktopWallpaperDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWallpaperEnabledChange()
            }
        }

        wallpaperBackgroundObserver = NotificationCenter.default.addObserver(
            forName: .desktopWallpaperBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWallpaperBackgroundChange()
            }
        }

        wallpaperSpeedObserver = NotificationCenter.default.addObserver(
            forName: .desktopWallpaperSpeedDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sharedWallpaperViewModel.speed = SettingsManager.shared.appearance.desktopWallpaperSpeed
            }
        }

        wallpaperProviderGlyphsObserver = NotificationCenter.default.addObserver(
            forName: .desktopWallpaperProviderGlyphsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sharedWallpaperViewModel.providerGlyphs = SettingsManager.shared.appearance.desktopWallpaperProviderGlyphs
            }
        }

        wallpaperCycleShapesObserver = NotificationCenter.default.addObserver(
            forName: .cycleShapesScreensaverDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sharedWallpaperViewModel.autoCyclesShapes = SettingsManager.shared.appearance.cycleShapesScreensaver
            }
        }

        wallpaperClickCycleObserver = NotificationCenter.default.addObserver(
            forName: .clickDesktopToCycleSwarmDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sharedWallpaperViewModel.allowsDesktopClickCycle = SettingsManager.shared.appearance.clickDesktopToCycleSwarm
            }
        }

        wallpaperExcludeBrandShapesObserver = NotificationCenter.default.addObserver(
            forName: .excludeBrandShapesFromSwarmDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sharedWallpaperViewModel.excludeBrandShapesFromSwarm = SettingsManager.shared.appearance.excludeBrandShapesFromSwarm
            }
        }
    }

    @objc private func handleWallpaperEnabledChange() {
        self.updateWallpaperState()
        self.configureWallpaperActivityPolling()
        self.syncWallpaperColorDriver()
    }

    private func handleWallpaperBackgroundChange() {
        sharedWallpaperViewModel.background = SettingsManager.shared.appearance.desktopWallpaperBackground
        syncSystemDesktopFallback()
        refreshWallpaperPanels()
    }

    private func checkForSystemWallpaperChanges() {
        guard SettingsManager.shared.appearance.enableDesktopWallpaper else { return }

        var didCaptureNewOriginal = false

        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen),
                  let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
                continue
            }

            // If the user changed the system desktop wallpaper to a non-fallback image,
            // and it is different from the currently cached original wallpaper,
            // capture it as the new original wallpaper that we will restore later,
            // and trigger a re-apply of the themed fallback image.
            if !isOpenBurnBarFallbackURL(currentURL) && currentURL != originalDesktopImageURL(for: displayID) {
                originalDesktopImageURLByScreenID[displayID] = currentURL
                storeOriginalDesktopImageURL(currentURL, for: displayID)
                didCaptureNewOriginal = true
            }
        }

        if didCaptureNewOriginal {
            // Re-apply the selected wallpaper theme to overlay on top of the newly chosen system wallpaper.
            syncSystemDesktopFallback()
        }
    }

    private func updateWallpaperState() {
        let isEnabled = SettingsManager.shared.appearance.enableDesktopWallpaper
        if isEnabled {
            setupWallpaperPanels()
        } else {
            teardownWallpaperPanels(restoreSystemWallpaper: true)
        }
    }

    private func setupWallpaperPanels() {
        teardownWallpaperPanels(restoreSystemWallpaper: false)
        sharedWallpaperViewModel.background = SettingsManager.shared.appearance.desktopWallpaperBackground
        sharedWallpaperViewModel.speed = SettingsManager.shared.appearance.desktopWallpaperSpeed
        sharedWallpaperViewModel.providerGlyphs = SettingsManager.shared.appearance.desktopWallpaperProviderGlyphs
        sharedWallpaperViewModel.autoCyclesShapes = SettingsManager.shared.appearance.cycleShapesScreensaver
        sharedWallpaperViewModel.allowsDesktopClickCycle = SettingsManager.shared.appearance.clickDesktopToCycleSwarm
        sharedWallpaperViewModel.excludeBrandShapesFromSwarm = SettingsManager.shared.appearance.excludeBrandShapesFromSwarm
        syncSystemDesktopFallback()
        let screens = NSScreen.screens
        for screen in screens {
            let panel = BurnBarWallpaperPanel(screen: screen, viewModel: sharedWallpaperViewModel)
            panel.orderFrontRegardless()
            wallpaperPanels.append(panel)
        }
    }

    private func refreshWallpaperPanels() {
        for panel in wallpaperPanels {
            panel.orderFrontRegardless()
        }
    }

    private func teardownWallpaperPanels(restoreSystemWallpaper: Bool = true) {
        for panel in wallpaperPanels {
            panel.orderOut(self)
            panel.close()
        }
        wallpaperPanels.removeAll()
        if restoreSystemWallpaper {
            restoreOriginalDesktopImages()
        }
    }

    private func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChange() {
        if SettingsManager.shared.appearance.enableDesktopWallpaper {
            setupWallpaperPanels()
        }
    }

    private func syncSystemDesktopFallback() {
        guard SettingsManager.shared.appearance.enableDesktopWallpaper else {
            restoreOriginalDesktopImages()
            return
        }

        let background = SettingsManager.shared.appearance.desktopWallpaperBackground
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            captureOriginalDesktopImageIfNeeded(for: screen, displayID: displayID)

            do {
                if installedDesktopFallbackByScreenID[displayID] == background,
                   currentDesktopImageIsOpenBurnBarFallback(for: screen) {
                    continue
                }

                let fallbackURL = try renderDesktopFallbackImage(for: background, screen: screen, displayID: displayID)
                try NSWorkspace.shared.setDesktopImageURL(
                    fallbackURL,
                    for: screen,
                    options: [
                        .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
                        .allowClipping: false
                    ]
                )
                installedDesktopFallbackByScreenID[displayID] = background
            } catch {
                NSLog("OpenBurnBar desktop fallback failed for display \(displayID): \(error.localizedDescription)")
            }
        }
    }

    private func restoreOriginalDesktopImages() {
        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen),
                  let originalURL = originalDesktopImageURL(for: displayID),
                  currentDesktopImageIsOpenBurnBarFallback(for: screen) else {
                continue
            }

            do {
                try NSWorkspace.shared.setDesktopImageURL(originalURL, for: screen, options: [:])
                clearStoredOriginalDesktopImageURL(for: displayID)
            } catch {
                NSLog("OpenBurnBar desktop restore failed for display \(displayID): \(error.localizedDescription)")
            }
        }
        installedDesktopFallbackByScreenID.removeAll()
    }

    private func captureOriginalDesktopImageIfNeeded(for screen: NSScreen, displayID: CGDirectDisplayID) {
        if originalDesktopImageURLByScreenID[displayID] == nil,
           let storedURL = storedOriginalDesktopImageURL(for: displayID) {
            originalDesktopImageURLByScreenID[displayID] = storedURL
        }

        guard originalDesktopImageURLByScreenID[displayID] == nil,
              let currentURL = NSWorkspace.shared.desktopImageURL(for: screen),
              !isOpenBurnBarFallbackURL(currentURL) else {
            return
        }
        originalDesktopImageURLByScreenID[displayID] = currentURL
        storeOriginalDesktopImageURL(currentURL, for: displayID)
    }

    private func originalDesktopImageURL(for displayID: CGDirectDisplayID) -> URL? {
        if let url = originalDesktopImageURLByScreenID[displayID] {
            return url
        }
        if let storedURL = storedOriginalDesktopImageURL(for: displayID) {
            originalDesktopImageURLByScreenID[displayID] = storedURL
            return storedURL
        }
        return nil
    }

    private func storeOriginalDesktopImageURL(_ url: URL, for displayID: CGDirectDisplayID) {
        UserDefaults.standard.set(url.absoluteString, forKey: originalDesktopImageURLKey(for: displayID))
    }

    private func storedOriginalDesktopImageURL(for displayID: CGDirectDisplayID) -> URL? {
        guard let raw = UserDefaults.standard.string(forKey: originalDesktopImageURLKey(for: displayID)) else {
            return nil
        }
        return URL(string: raw)
    }

    private func clearStoredOriginalDesktopImageURL(for displayID: CGDirectDisplayID) {
        originalDesktopImageURLByScreenID.removeValue(forKey: displayID)
        UserDefaults.standard.removeObject(forKey: originalDesktopImageURLKey(for: displayID))
    }

    private func originalDesktopImageURLKey(for displayID: CGDirectDisplayID) -> String {
        "desktopWallpaper.originalDesktopImageURL.\(displayID)"
    }

    private func currentDesktopImageIsOpenBurnBarFallback(for screen: NSScreen) -> Bool {
        guard let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else { return false }
        return isOpenBurnBarFallbackURL(currentURL)
    }

    private func isOpenBurnBarFallbackURL(_ url: URL) -> Bool {
        let directory = desktopFallbackDirectory()
        return url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path)
    }

    private func desktopFallbackDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return root.appendingPathComponent("OpenBurnBar/DesktopWallpaperFallbacks", isDirectory: true)
    }

    private func renderDesktopFallbackImage(
        for background: DesktopWallpaperBackground,
        screen: NSScreen,
        displayID: CGDirectDisplayID
    ) throws -> URL {
        let directory = desktopFallbackDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scale = max(screen.backingScaleFactor, 1)
        let pixelWidth = max(1, Int((screen.frame.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((screen.frame.height * scale).rounded(.up)))
        let fileURL = directory.appendingPathComponent(
            "\(background.rawValue)-\(displayID)-\(pixelWidth)x\(pixelHeight).png",
            isDirectory: false
        )

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "OpenBurnBarWallpaper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create wallpaper bitmap"
            ])
        }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        NSGradient(colors: desktopFallbackColors(for: background))?.draw(in: rect, angle: -32)
        NSColor.black.withAlphaComponent(0.18).setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "OpenBurnBarWallpaper", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode wallpaper PNG"
            ])
        }
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func desktopFallbackColors(for background: DesktopWallpaperBackground) -> [NSColor] {
        switch background {
        case .macOSDesktop:
            return [
                NSColor(red: 0.180, green: 0.455, blue: 0.930, alpha: 1),
                NSColor(red: 0.960, green: 0.385, blue: 0.455, alpha: 1),
                NSColor(red: 0.980, green: 0.720, blue: 0.255, alpha: 1)
            ]
        case .midnight:
            return [
                NSColor(red: 0.018, green: 0.026, blue: 0.070, alpha: 1),
                NSColor(red: 0.055, green: 0.145, blue: 0.320, alpha: 1),
                NSColor(red: 0.115, green: 0.260, blue: 0.520, alpha: 1)
            ]
        case .amoledBlack:
            return [.black, NSColor(red: 0.010, green: 0.010, blue: 0.012, alpha: 1), NSColor(red: 0.055, green: 0.055, blue: 0.060, alpha: 1)]
        case .graphite:
            return [
                NSColor(red: 0.105, green: 0.112, blue: 0.128, alpha: 1),
                NSColor(red: 0.270, green: 0.295, blue: 0.330, alpha: 1),
                NSColor(red: 0.475, green: 0.505, blue: 0.545, alpha: 1)
            ]
        case .warmEmber:
            return [
                NSColor(red: 0.115, green: 0.052, blue: 0.030, alpha: 1),
                NSColor(red: 0.470, green: 0.145, blue: 0.020, alpha: 1),
                NSColor(red: 0.920, green: 0.355, blue: 0.055, alpha: 1)
            ]
        case .deepIndigo:
            return [
                NSColor(red: 0.045, green: 0.035, blue: 0.120, alpha: 1),
                NSColor(red: 0.180, green: 0.115, blue: 0.390, alpha: 1),
                NSColor(red: 0.410, green: 0.300, blue: 0.880, alpha: 1)
            ]
        case .auroraTeal:
            return [
                NSColor(red: 0.015, green: 0.045, blue: 0.050, alpha: 1),
                NSColor(red: 0.050, green: 0.180, blue: 0.200, alpha: 1),
                NSColor(red: 0.120, green: 0.380, blue: 0.400, alpha: 1)
            ]
        case .sunsetCrimson:
            return [
                NSColor(red: 0.045, green: 0.018, blue: 0.020, alpha: 1),
                NSColor(red: 0.180, green: 0.055, blue: 0.070, alpha: 1),
                NSColor(red: 0.420, green: 0.115, blue: 0.145, alpha: 1)
            ]
        case .cyberpunkViolet:
            return [
                NSColor(red: 0.030, green: 0.015, blue: 0.045, alpha: 1),
                NSColor(red: 0.150, green: 0.055, blue: 0.220, alpha: 1),
                NSColor(red: 0.380, green: 0.120, blue: 0.520, alpha: 1)
            ]
        case .forestMoss:
            return [
                NSColor(red: 0.015, green: 0.035, blue: 0.020, alpha: 1),
                NSColor(red: 0.055, green: 0.140, blue: 0.080, alpha: 1),
                NSColor(red: 0.150, green: 0.320, blue: 0.180, alpha: 1)
            ]
        case .solarFlare:
            return [
                NSColor(red: 0.050, green: 0.035, blue: 0.015, alpha: 1),
                NSColor(red: 0.200, green: 0.140, blue: 0.055, alpha: 1),
                NSColor(red: 0.480, green: 0.340, blue: 0.120, alpha: 1)
            ]
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func setupPowerMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerStateChange),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        // Event-driven AC <-> battery detection. IOPSCreateLimitedPowerNotification
        // fires only on limited-power transitions, replacing a 5 s polling timer
        // (~17k IOKit snapshots/day at idle). The callback is a C function pointer,
        // so `self` round-trips through an Unmanaged context pointer and hops back
        // to the main actor before touching the wallpaper view model.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                delegate.syncBatteryState()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            batteryNotificationSource = source
        }
        syncBatteryState()
    }

    @objc private func handlePowerStateChange() {
        syncBatteryState()
    }

    private func syncBatteryState() {
        let onBattery = isRunningOnBattery()
        sharedWallpaperViewModel.isBatteryThrottled = onBattery
    }

    private func isRunningOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return Self.isOnBattery(powerSourceDescriptions: descriptions)
    }

    nonisolated static func isOnBattery(powerSourceDescriptions: [[String: Any]]) -> Bool {
        powerSourceDescriptions.contains { description in
            description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
        }
    }

    private func setupWallpaperObservers() {
        observeDataStoreChanges()
        observeDaemonChanges()
        observeWallpaperAgentStatuses()
        configureWallpaperActivityPolling()
        syncWallpaperColorDriver()
    }

    private func observeDataStoreChanges() {
        guard let dataStore else { return }
        dataStoreObservation = withObservationTracking {
            _ = dataStore.totalCostToday
            _ = dataStore.providerSummaries
            return nil as Any?
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncWallpaperColorDriver()
                self.observeDataStoreChanges()
            }
        }
    }

    private func observeDaemonChanges() {
        guard let daemonManager else { return }
        daemonObservation = withObservationTracking {
            _ = daemonManager.isBusy
            return nil as Any?
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncWallpaperColorDriver()
                self.observeDaemonChanges()
            }
        }
    }

    private func observeWallpaperAgentStatuses() {
        guard wallpaperAgentStatusObserver == nil else { return }
        wallpaperAgentStatusObserver = NotificationCenter.default.addObserver(
            forName: PixelClockAgentStatusStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncWallpaperColorDriver()
            }
        }
    }

    private func configureWallpaperActivityPolling() {
        // The legacy 3 s `wallpaperActivityTimer` and 1 s `wallpaperPollTimer`
        // burned cycles every second on every machine that ever enabled the
        // live wallpaper, even when the desktop and agents were idle. They
        // were replaced with three observer-driven sources that fire only on
        // actual state changes, plus a defensive 30 s reconcile so we still
        // catch desktop wallpaper changes that NSWorkspace didn't notify us
        // about (rare, but possible when a third-party tool writes the
        // preferences plist directly).
        //
        //   - `pixelClockAgentStatusStore` already posts
        //     `didChangeNotification` whenever an agent process flips state;
        //     `observeWallpaperAgentStatuses()` (called above) listens to it.
        //   - `NSWorkspace.shared.notificationCenter` posts
        //     `activeSpaceDidChangeNotification` when the user switches
        //     Spaces, which is the most common cause of a wallpaper change.
        //   - `NSApplication.didChangeScreenParametersNotification` covers
        //     resolution / display changes.
        //   - A 30 s `Timer` is the defensive backstop and still runs 30×
        //     less often than the old 1 s poller.
        wallpaperActivityTimer?.invalidate()
        wallpaperActivityTimer = nil
        wallpaperPollTimer?.invalidate()
        wallpaperPollTimer = nil
        if let observer = wallpaperSpaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wallpaperSpaceChangeObserver = nil
        }

        guard SettingsManager.shared.appearance.enableDesktopWallpaper else { return }

        wallpaperSpaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkForSystemWallpaperChanges()
            }
        }

        // Defensive backstop. 30 s is invisible to humans because the only
        // observable side-effect is re-applying the themed fallback if the
        // captured original wallpaper changed — which the observers above
        // already catch in the common case.
        wallpaperPollTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForSystemWallpaperChanges()
            }
        }
    }

    private func syncWallpaperColorDriver() {
        wallpaperColorDriverTask?.cancel()
        guard let dataStore else {
            sharedWallpaperViewModel.colorDriver = nil
            return
        }

        let totalCost = dataStore.totalCostToday
        let summaries = dataStore.providerSummaries
        let daemonIsBusy = daemonManager?.isBusy ?? false

        wallpaperColorDriverTask = Task { @MainActor [weak self] in
            let statuses = await PixelClockAgentStatusStore.shared.snapshotIncludingExternalProcesses()
            guard !Task.isCancelled else { return }
            self?.sharedWallpaperViewModel.colorDriver = SwarmWallpaperColorDriverBuilder.driver(
                totalCostToday: totalCost,
                providerSummaries: summaries,
                agentStatuses: statuses,
                daemonIsBusy: daemonIsBusy
            )
        }
    }

    private func teardownWallpaperObservers() {
        if let wallpaperEnabledObserver {
            NotificationCenter.default.removeObserver(wallpaperEnabledObserver)
            self.wallpaperEnabledObserver = nil
        }
        if let wallpaperBackgroundObserver {
            NotificationCenter.default.removeObserver(wallpaperBackgroundObserver)
            self.wallpaperBackgroundObserver = nil
        }
        if let wallpaperSpeedObserver {
            NotificationCenter.default.removeObserver(wallpaperSpeedObserver)
            self.wallpaperSpeedObserver = nil
        }
        if let wallpaperProviderGlyphsObserver {
            NotificationCenter.default.removeObserver(wallpaperProviderGlyphsObserver)
            self.wallpaperProviderGlyphsObserver = nil
        }
        if let wallpaperCycleShapesObserver {
            NotificationCenter.default.removeObserver(wallpaperCycleShapesObserver)
            self.wallpaperCycleShapesObserver = nil
        }
        if let wallpaperClickCycleObserver {
            NotificationCenter.default.removeObserver(wallpaperClickCycleObserver)
            self.wallpaperClickCycleObserver = nil
        }
        if let wallpaperExcludeBrandShapesObserver {
            NotificationCenter.default.removeObserver(wallpaperExcludeBrandShapesObserver)
            self.wallpaperExcludeBrandShapesObserver = nil
        }
        wallpaperPollTimer?.invalidate()
        wallpaperPollTimer = nil
        if let wallpaperAgentStatusObserver {
            NotificationCenter.default.removeObserver(wallpaperAgentStatusObserver)
            self.wallpaperAgentStatusObserver = nil
        }
        if let wallpaperSpaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wallpaperSpaceChangeObserver)
            self.wallpaperSpaceChangeObserver = nil
        }
        dataStoreObservation = nil
        daemonObservation = nil
        wallpaperActivityTimer?.invalidate()
        wallpaperActivityTimer = nil
        wallpaperColorDriverTask?.cancel()
        wallpaperColorDriverTask = nil
        if let batteryNotificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), batteryNotificationSource, .defaultMode)
            CFRunLoopSourceInvalidate(batteryNotificationSource)
            self.batteryNotificationSource = nil
        }
        NotificationCenter.default.removeObserver(self, name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        guard let window = popover?.contentViewController?.view.window else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        // Clear content when closed to ensure fresh state on next show
        // (fd19d53ac) — then rebuild it on the next main-queue turn so the
        // following open pays no construction or first-layout cost on the
        // click path (§15).
        popover?.contentViewController = nil
        popoverPrewarmer?.schedulePrime()
    }

    func applicationWillTerminate(_ notification: Notification) {
        uninstallStatusItemMouseFallback()
        teardownWallpaperPanels()
        teardownWallpaperObservers()
    }
}

enum OpenBurnBarStatusItemClick {
    struct EventKey: Equatable {
        let eventNumber: Int
        let type: NSEvent.EventType
        let timestampBucket: Int

        init(_ event: NSEvent) {
            self.eventNumber = event.eventNumber
            self.type = event.type
            self.timestampBucket = Int(event.timestamp * 1_000)
        }
    }

    enum Action: Equatable {
        case togglePopover
        case showSecondaryMenu
        case ignore
    }

    static let actionMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

    static func action(for eventType: NSEvent.EventType?) -> Action {
        switch eventType {
        case .leftMouseDown, nil:
            return .togglePopover
        case .rightMouseDown:
            return .showSecondaryMenu
        default:
            return .ignore
        }
    }
}

private extension NSStatusBarButton {
    var openBurnBarScreenFrame: CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}

private enum OpenBurnBarStatusItemBrandMark {
    private static let side: CGFloat = 18

    /// Returns the menu-bar icon in either monochrome template mode or full color.
    static func image(colorful: Bool) -> NSImage {
        if let source = NSImage(named: "AppLogo") {
            let target = NSSize(width: side, height: side)
            let rendered = NSImage(size: target, flipped: false) { rect in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.imageInterpolation = .high
                source.draw(
                    in: rect,
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .copy,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: nil
                )
                NSGraphicsContext.restoreGraphicsState()
                return true
            }
            rendered.isTemplate = !colorful
            return rendered
        }
        let fallback = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        fallback.isTemplate = !colorful
        return fallback
    }
}


// MARK: - Status Item Geometry Helpers
enum OpenBurnBarMenuExtraClickFallback {
    static func click(_ point: CGPoint, hits frame: CGRect) -> Bool {
        // Add some slop for hit testing
        return frame.insetBy(dx: -5, dy: -5).contains(point)
    }

    static func hitFrame(for point: CGPoint, in frames: [CGRect]) -> CGRect? {
        return frames.first { click(point, hits: $0) }
    }

    static func mirroredFrames(for frames: [CGRect], anonymousFrames: [CGRect], displayBounds: [CGRect]) -> [CGRect] {
        return anonymousFrames.filter { anon in
            guard let anonymousDisplay = displayBounds.first(where: { $0.contains(anon.center) }) else {
                return false
            }

            return frames.contains { frame in
                guard let sourceDisplay = displayBounds.first(where: { $0.contains(frame.center) }),
                      sourceDisplay != anonymousDisplay else {
                    return false
                }

                let sourceRightInset = sourceDisplay.maxX - frame.maxX
                let anonymousRightInset = anonymousDisplay.maxX - anon.maxX
                let sourceTopInset = frame.minY - sourceDisplay.minY
                let anonymousTopInset = anon.minY - anonymousDisplay.minY

                return abs(anon.width - frame.width) <= 6
                    && abs(anon.height - frame.height) <= 6
                    && abs(anonymousRightInset - sourceRightInset) <= 10
                    && abs(anonymousTopInset - sourceTopInset) <= 6
            }
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

enum OpenBurnBarPopoverClickRegion {
    static func isInsideInteractiveRegion(_ point: CGPoint, statusItemFrame: CGRect, popoverFrame: CGRect) -> Bool {
        return statusItemFrame.insetBy(dx: -5, dy: -5).contains(point) || popoverFrame.contains(point)
    }
}

// MARK: - Dynamic Swarm Wallpaper Types

enum SwarmWallpaperColorDriverBuilder {
    static func driver(
        totalCostToday: Double,
        providerSummaries: [ProviderSummary],
        agentStatuses: [String: PixelClockAgentStatus],
        daemonIsBusy: Bool
    ) -> SwarmColorDriver {
        let runningProviders = runningProviders(from: agentStatuses)
        let mode: SwarmColorDriver.Mode = daemonIsBusy || !runningProviders.isEmpty ? .active : .idle
        let weights = runningProviders.isEmpty
            ? historicalWeights(from: providerSummaries, totalCostToday: totalCostToday)
            : activeWeights(from: runningProviders)

        return SwarmColorDriver(
            mode: mode,
            providers: weights,
            totalBurnRateUSD: totalCostToday
        )
    }

    static func runningProviders(from statuses: [String: PixelClockAgentStatus]) -> [AgentProvider] {
        let providers = statuses.compactMap { entry -> AgentProvider? in
            let (key, status) = entry
            guard status == .running else { return nil }
            return provider(forStatusToken: key)
        }

        var seen: Set<AgentProvider> = []
        return providers
            .filter { seen.insert($0).inserted }
            .sorted { $0.rawValue < $1.rawValue }
    }

    static func provider(forStatusToken token: String) -> AgentProvider? {
        let normalized = normalizedProviderToken(token)
        let aliases: [String: AgentProvider] = [
            "anthropic": .claudeCode,
            "claude": .claudeCode,
            "claudecode": .claudeCode,
            "claudecli": .claudeCode,
            "codex": .codex,
            "openai": .openAI,
            "openaicodex": .codex,
            "opencode": .openCode,
            "openclaw": .openClaw,
            "factory": .factory,
            "droid": .factory,
            "cursor": .cursor,
            "xai": .xAI,
            "grok": .xAI,
            "supergrok": .xAI
        ]
        if let alias = aliases[normalized] {
            return alias
        }

        return AgentProvider.allCases.first { provider in
            normalized == normalizedProviderToken(provider.rawValue)
                || normalized == normalizedProviderToken(provider.persistedToken)
                || normalized == normalizedProviderToken(provider.providerID.rawValue)
        }
    }

    private static func activeWeights(from providers: [AgentProvider]) -> [SwarmColorDriver.ProviderWeight] {
        guard !providers.isEmpty else { return [] }
        let weight = 1.0 / Double(providers.count)
        return providers.map { provider in
            SwarmColorDriver.ProviderWeight(provider: provider, weight: weight, quotaPressure: 0)
        }
    }

    private static func historicalWeights(
        from providerSummaries: [ProviderSummary],
        totalCostToday: Double
    ) -> [SwarmColorDriver.ProviderWeight] {
        guard !providerSummaries.isEmpty else { return [] }

        let weights: [SwarmColorDriver.ProviderWeight]
        if totalCostToday > 0 {
            weights = providerSummaries.map { summary in
                SwarmColorDriver.ProviderWeight(
                    provider: summary.provider,
                    weight: summary.totalCost / totalCostToday,
                    quotaPressure: 0
                )
            }
        } else {
            let totalTokens = providerSummaries.reduce(0) { $0 + $1.totalTokens }
            if totalTokens > 0 {
                weights = providerSummaries.map { summary in
                    SwarmColorDriver.ProviderWeight(
                        provider: summary.provider,
                        weight: Double(summary.totalTokens) / Double(totalTokens),
                        quotaPressure: 0
                    )
                }
            } else {
                let equalWeight = 1.0 / Double(providerSummaries.count)
                weights = providerSummaries.map { summary in
                    SwarmColorDriver.ProviderWeight(
                        provider: summary.provider,
                        weight: equalWeight,
                        quotaPressure: 0
                    )
                }
            }
        }

        return weights.sorted { lhs, rhs in
            if lhs.weight == rhs.weight {
                return lhs.provider.rawValue < rhs.provider.rawValue
            }
            return lhs.weight > rhs.weight
        }
    }

    private static func normalizedProviderToken(_ token: String) -> String {
        token
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// Reactive view model for coordinating the live background state.
@Observable
@MainActor
public final class SwarmWallpaperViewModel {
    public var pointer: CGPoint? = nil
    public var colorDriver: SwarmColorDriver? = nil
    public var isBatteryThrottled: Bool = false
    public var isPaused: Bool = false
    var background: DesktopWallpaperBackground = SettingsManager.shared.appearance.desktopWallpaperBackground
    var speed: Double = SettingsManager.shared.appearance.desktopWallpaperSpeed
    var providerGlyphs: [AgentProvider] = SettingsManager.shared.appearance.desktopWallpaperProviderGlyphs
    var autoCyclesShapes: Bool = SettingsManager.shared.appearance.cycleShapesScreensaver
    var allowsDesktopClickCycle: Bool = SettingsManager.shared.appearance.clickDesktopToCycleSwarm
    var enableSwarmSparkles: Bool = SettingsManager.shared.appearance.enableSwarmSparkles
    var excludeBrandShapesFromSwarm: Bool = SettingsManager.shared.appearance.excludeBrandShapesFromSwarm

    public init() {}
}

/// SwiftUI wrapper for displaying the SwarmCanvasView within the wallpaper panel.
struct SwarmWallpaperView: View {
    let viewModel: SwarmWallpaperViewModel

    var body: some View {
        let background = viewModel.background
        let speed = viewModel.speed
        let providerGlyphs = viewModel.providerGlyphs
        let autoCyclesShapes = viewModel.autoCyclesShapes
        let enableSparkles = viewModel.enableSwarmSparkles
        let excludeBrandShapes = viewModel.excludeBrandShapesFromSwarm

        SwarmCanvasView(
            accent: .purple,
            pace: .cinematic, // Cinematic pace is perfect for ambient wallpaper
            colorDriver: viewModel.colorDriver,
            isBatteryThrottled: viewModel.isBatteryThrottled,
            externalPointer: viewModel.pointer,
            isTransparent: false,
            backdropColor: background.isTransparent ? nil : background.swatchColor,
            backdropColors: background.swatchPreviewColors,
            colorPalette: background.swarmPalette,
            motionSpeedMultiplier: speed,
            isAutoCyclingEnabled: autoCyclesShapes,
            enabledProviderGlyphs: providerGlyphs,
            enableSwarmSparkles: enableSparkles,
            excludeBrandShapesFromSwarm: excludeBrandShapes,
            // The wallpaper is an ambient surface that sits behind every
            // window and icon — capping at 30 fps + rendering the Canvas
            // asynchronously halves CPU work with no perceptible change in
            // the ambient field.
            maxFrameRate: 30.0,
            rendersAsynchronously: true
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.18), value: background)
        .animation(.easeInOut(duration: 0.18), value: speed)
        .animation(.easeInOut(duration: 0.18), value: providerGlyphs)
        .animation(.easeInOut(duration: 0.18), value: autoCyclesShapes)
        .onReceive(NotificationCenter.default.publisher(for: .desktopWallpaperBackgroundDidChange)) { _ in
            viewModel.background = SettingsManager.shared.appearance.desktopWallpaperBackground
        }
        .onReceive(NotificationCenter.default.publisher(for: .desktopWallpaperSpeedDidChange)) { _ in
            viewModel.speed = SettingsManager.shared.appearance.desktopWallpaperSpeed
        }
        .onReceive(NotificationCenter.default.publisher(for: .desktopWallpaperProviderGlyphsDidChange)) { _ in
            viewModel.providerGlyphs = SettingsManager.shared.appearance.desktopWallpaperProviderGlyphs
        }
        .onReceive(NotificationCenter.default.publisher(for: .cycleShapesScreensaverDidChange)) { _ in
            viewModel.autoCyclesShapes = SettingsManager.shared.appearance.cycleShapesScreensaver
        }
        .onReceive(NotificationCenter.default.publisher(for: .clickDesktopToCycleSwarmDidChange)) { _ in
            viewModel.allowsDesktopClickCycle = SettingsManager.shared.appearance.clickDesktopToCycleSwarm
        }
        .onReceive(NotificationCenter.default.publisher(for: .enableSwarmSparklesDidChange)) { _ in
            viewModel.enableSwarmSparkles = SettingsManager.shared.appearance.enableSwarmSparkles
        }
        .onReceive(NotificationCenter.default.publisher(for: .excludeBrandShapesFromSwarmDidChange)) { _ in
            viewModel.excludeBrandShapesFromSwarm = SettingsManager.shared.appearance.excludeBrandShapesFromSwarm
        }
    }
}

/// A stationary, click-through transparent NSPanel floating behind desktop folders and icons
/// that hosts the dynamic AI usage ember swarm simulation.
public class BurnBarWallpaperPanel: NSPanel {
    private nonisolated(unsafe) var mouseMonitor: Any?
    private nonisolated(unsafe) var clickMonitor: Any?
    private let viewModel: SwarmWallpaperViewModel
    private let targetScreen: NSScreen

    /// Last pointer position written to the view-model. We coalesce raw HID
    /// events through a 30 Hz throttle (`pointerCommitInterval`) and a 4 pt
    /// movement gate, so micro-jitter no longer causes 60–120 `@Observable`
    /// writes per second — at idle desktop usage the pointer pipeline is now
    /// essentially zero-cost.
    private var lastCommittedPointer: CGPoint?
    private var pendingPointer: CGPoint?
    private var lastPointerCommitTime: TimeInterval = 0
    private nonisolated(unsafe) var pointerCoalesceTimer: DispatchSourceTimer?
    private static let pointerCommitInterval: TimeInterval = 1.0 / 30.0
    private static let pointerMovementThreshold: CGFloat = 4.0

    public init(screen: NSScreen, viewModel: SwarmWallpaperViewModel) {
        self.viewModel = viewModel
        self.targetScreen = screen

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = false
        // Place exactly under desktop icons, but above standard background image
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)

        self.collectionBehavior = [
            .canJoinAllSpaces,   // Live on all virtual desktops (Spaces)
            .ignoresCycle,       // Exclude from Cmd+` cycle list
            .stationary,         // Stay visually pinned during Space transitions
            .fullScreenAuxiliary // Keep the panel available while fullscreen Spaces are active
        ]

        self.ignoresMouseEvents = true // Make click-through so user can interact with files
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.canHide = false
        self.animationBehavior = .none
        self.isReleasedWhenClosed = false

        let swarmView = SwarmWallpaperView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: swarmView)
        hostingView.frame = self.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView

        // Global mouse tracking monitor to feed cursor position to the canvas without window focus.
        // We coalesce raw events through `enqueuePointerSample` so the
        // `@Observable` view-model is written at most ~30 times/sec instead
        // of at the raw HID rate (≥ 60 Hz on macOS).
        self.mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self, !self.viewModel.isPaused else { return }
            let globalPoint = NSEvent.mouseLocation

            if self.targetScreen.frame.contains(globalPoint) {
                let localPoint = self.convertScreenPointToLocal(globalPoint)
                self.enqueuePointerSample(localPoint)
            } else {
                self.enqueuePointerSample(nil)
            }
        }

        // Global mouse click tracking to cycle swarm when clicking on the desktop background.
        // Finder becomes frontmost after the click is dispatched, so validation is deferred.
        self.clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.scheduleDesktopClickCycleIfNeeded()
        }
    }

    /// Coalesces raw HID-rate pointer events into a 30 Hz commit stream with
    /// a sub-threshold movement gate. The visible swarm consumes pointer
    /// position only at frame boundaries, so committing 60+ times/sec is
    /// pure waste — at the new cadence the field tracks the cursor within
    /// one frame visually while paying ½× to ¼× the `@Observable` write
    /// cost.
    private func enqueuePointerSample(_ point: CGPoint?) {
        // `nil` means the cursor left the screen — commit immediately so the
        // swarm doesn't keep pushing against a stale phantom pointer.
        if point == nil {
            pendingPointer = nil
            commitPendingPointer()
            return
        }

        // Movement gate: if the new sample is within `pointerMovementThreshold`
        // points of the last committed value, drop it.
        if let new = point, let last = lastCommittedPointer {
            let dx = abs(new.x - last.x)
            let dy = abs(new.y - last.y)
            if dx < Self.pointerMovementThreshold && dy < Self.pointerMovementThreshold {
                return
            }
        }

        pendingPointer = point

        let now = CACurrentMediaTime()
        if now - lastPointerCommitTime >= Self.pointerCommitInterval {
            commitPendingPointer()
            return
        }

        // Already armed — let the existing timer flush the pending sample.
        guard pointerCoalesceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = Self.pointerCommitInterval - (now - lastPointerCommitTime)
        timer.schedule(deadline: .now() + max(0, delay))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.commitPendingPointer()
        }
        pointerCoalesceTimer = timer
        timer.resume()
    }

    private func commitPendingPointer() {
        pointerCoalesceTimer?.cancel()
        pointerCoalesceTimer = nil
        let next = pendingPointer
        pendingPointer = nil
        lastCommittedPointer = next
        lastPointerCommitTime = CACurrentMediaTime()
        viewModel.pointer = next
    }

    private func scheduleDesktopClickCycleIfNeeded() {
        guard viewModel.allowsDesktopClickCycle else { return }
        let globalPoint = NSEvent.mouseLocation
        guard targetScreen.frame.contains(globalPoint) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.viewModel.allowsDesktopClickCycle,
                  self.targetScreen.frame.contains(globalPoint) else {
                return
            }
            NotificationCenter.default.post(name: .cycleSwarmShapeRequested, object: nil)
        }
    }

    private func convertScreenPointToLocal(_ globalPoint: NSPoint) -> CGPoint {
        let screenFrame = targetScreen.frame
        // Convert bottom-left y-up (macOS) to top-left y-down (SwiftUI Canvas)
        let localX = globalPoint.x - screenFrame.origin.x
        let localY = screenFrame.height - (globalPoint.y - screenFrame.origin.y)
        return CGPoint(x: localX, y: localY)
    }

    override public var canBecomeKey: Bool {
        return false
    }

    override public var canBecomeMain: Bool {
        return false
    }

    deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        pointerCoalesceTimer?.cancel()
        pointerCoalesceTimer = nil
    }
}

// The direct-download update checker (verified download + Ed25519 signature
// check against SUPublicEDKey) lives in
// AgentLens/Services/DirectDownloadUpdateService.swift.
