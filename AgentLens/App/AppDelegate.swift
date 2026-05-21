import AppKit
import Carbon
import GoogleSignIn
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
    private var popover: NSPopover?
    private var statusItemLocalMouseMonitor: Any?
    private var statusItemGlobalMouseMonitor: Any?
    private var lastHandledStatusItemEventKey: OpenBurnBarStatusItemClick.EventKey?
    private var lastHandledStatusItemEventTime: TimeInterval = 0

    // live wallpaper variables
    public var dataStore: DataStore? = nil {
        didSet {
            setupWallpaperObservers()
        }
    }
    public var daemonManager: OpenBurnBarDaemonManager? = nil {
        didSet {
            setupWallpaperObservers()
        }
    }

    private var wallpaperPanels: [BurnBarWallpaperPanel] = []
    private var sharedWallpaperViewModel = SwarmWallpaperViewModel()

    // Observers
    private var wallpaperEnabledObserver: Any?
    private var dataStoreObservation: Any?
    private var daemonObservation: Any?
    private var batteryTimer: Timer?
    private var wallpaperActivityTimer: Timer?
    private var wallpaperAgentStatusObserver: NSObjectProtocol?
    private var wallpaperColorDriverTask: Task<Void, Never>?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if AppCommandRouter.shared.handle(url) {
            return
        }
        _ = GIDSignIn.sharedInstance.handle(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OpenBurnBarRuntime.beginHarnessHostActivityIfNeeded()

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        guard !OpenBurnBarRuntime.shouldUseTestStubScene else { return }
        installStatusItem()

        // Start wallpaper orchestration
        observeDesktopWallpaper()
        updateWallpaperState()
        setupPowerMonitoring()
        setupScreenChangeObserver()
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
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            self.popover = popover
        }

        guard let popover else { return }

        if popover.contentViewController == nil {
            let content = AppCommandRouter.shared.makeMenuBarPopoverContent?({ [weak popover] in
                popover?.performClose(nil)
            }) ?? AnyView(Text("No Content"))

            let host = NSHostingController(rootView: content)
            popover.contentViewController = host
        }

        // Ensure we have a reasonable size before showing
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

    // MARK: - Live Wallpaper Orchestration

    private func observeDesktopWallpaper() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWallpaperEnabledChange),
            name: .enableDesktopWallpaperDidChange,
            object: nil
        )
    }

    @objc private func handleWallpaperEnabledChange() {
        Task { @MainActor in
            self.updateWallpaperState()
            self.configureWallpaperActivityPolling()
            self.syncWallpaperColorDriver()
        }
    }

    private func updateWallpaperState() {
        let isEnabled = SettingsManager.shared.appearance.enableDesktopWallpaper
        if isEnabled {
            setupWallpaperPanels()
        } else {
            teardownWallpaperPanels()
        }
    }

    private func setupWallpaperPanels() {
        teardownWallpaperPanels()
        let screens = NSScreen.screens
        for screen in screens {
            let panel = BurnBarWallpaperPanel(screen: screen, viewModel: sharedWallpaperViewModel)
            panel.orderBack(nil)
            wallpaperPanels.append(panel)
        }
    }

    private func teardownWallpaperPanels() {
        for panel in wallpaperPanels {
            panel.orderOut(self)
            panel.close()
        }
        wallpaperPanels.removeAll()
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

    private func setupPowerMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerStateChange),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncBatteryState()
            }
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
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                if state == kIOPSBatteryPowerValue {
                    return true
                }
            }
        }
        return false
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
        wallpaperActivityTimer?.invalidate()
        wallpaperActivityTimer = nil

        guard SettingsManager.shared.appearance.enableDesktopWallpaper else { return }
        wallpaperActivityTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncWallpaperColorDriver()
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
        NotificationCenter.default.removeObserver(self, name: .enableDesktopWallpaperDidChange, object: nil)
        if let wallpaperAgentStatusObserver {
            NotificationCenter.default.removeObserver(wallpaperAgentStatusObserver)
            self.wallpaperAgentStatusObserver = nil
        }
        dataStoreObservation = nil
        daemonObservation = nil
        wallpaperActivityTimer?.invalidate()
        wallpaperActivityTimer = nil
        wallpaperColorDriverTask?.cancel()
        wallpaperColorDriverTask = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
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
        popover?.contentViewController = nil
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
            "cursor": .cursor
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

    public init() {}
}

/// SwiftUI wrapper for displaying the SwarmCanvasView within the wallpaper panel.
struct SwarmWallpaperView: View {
    let viewModel: SwarmWallpaperViewModel
    @State private var settings = SettingsManager.shared

    var body: some View {
        if viewModel.isPaused {
            Color.clear
                .ignoresSafeArea()
        } else {
            let background = settings.appearance.desktopWallpaperBackground
            SwarmCanvasView(
                accent: .purple,
                pace: .cinematic, // Cinematic pace is perfect for ambient wallpaper
                colorDriver: viewModel.colorDriver,
                isBatteryThrottled: viewModel.isBatteryThrottled,
                externalPointer: viewModel.pointer,
                isTransparent: background.isTransparent,
                backdropColor: background.isTransparent ? nil : background.swatchColor
            )
            .ignoresSafeArea()
        }
    }
}

/// A stationary, click-through transparent NSPanel floating behind desktop folders and icons
/// that hosts the dynamic AI usage ember swarm simulation.
public class BurnBarWallpaperPanel: NSPanel {
    private var mouseMonitor: Any?
    private let viewModel: SwarmWallpaperViewModel
    private let targetScreen: NSScreen

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
            .stationary,         // Lock in position during swipe transitions
            .fullScreenAuxiliary // Render cleanly alongside fullscreen windows
        ]
        
        self.ignoresMouseEvents = true // Make click-through so user can interact with files
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.hidesOnDeactivate = false
        
        let swarmView = SwarmWallpaperView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: swarmView)
        hostingView.frame = self.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        self.contentView = hostingView

        // Global mouse tracking monitor to feed cursor position to the canvas without window focus
        self.mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self = self, !self.viewModel.isPaused else { return }
            let globalPoint = NSEvent.mouseLocation
            
            // Check if mouse is on this screen
            if self.targetScreen.frame.contains(globalPoint) {
                let localPoint = self.convertScreenPointToLocal(globalPoint)
                self.viewModel.pointer = localPoint
            } else {
                self.viewModel.pointer = nil
            }
        }

        // Register occlusion state observer to freeze rendering (0fps) when covered or on inactive Space
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOcclusionChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: self
        )
        
        // Trigger initial check
        handleOcclusionChange()
    }

    @objc private func handleOcclusionChange() {
        let isVisible = self.occlusionState.contains(.visible)
        self.viewModel.isPaused = !isVisible
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
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
