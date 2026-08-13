import AppKit
import OpenBurnBarCore
import SwiftUI

// Extracted verbatim from AppDelegate.swift (audit wave 4, item 14).
// The menu-bar status item + NSPopover host: icon style/update badge
// observation, click handling (primary + fallback monitor + dedupe),
// popover show/close/prewarm, the secondary right-click menu, and the
// NSPopoverDelegate callbacks.
extension AppDelegate {
    func installStatusItem() {
        if statusItem != nil {
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: OpenBurnBarStatusItemBrandMark.statusItemWidth)
        if let button = item.button {
            button.image = OpenBurnBarStatusItemBrandMark.image(
                colorful: shouldRenderColorfulMenuBarIcon
            )
            button.imagePosition = .imageOnly
            button.title = OpenBurnBarStatusItemBrandMark.menuBarTitle
            button.toolTip = "OpenBurnBar"
            button.setAccessibilityLabel("OpenBurnBar")
            button.setAccessibilityIdentifier(OBBAccessibilityID.menuBarStatusItem)
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: OpenBurnBarStatusItemClick.primaryActionMask)
        }
        self.statusItem = item
        installStatusItemMouseFallback()
        observeMenuBarIconStyle()
        observeUpdateBadge()
        QuotaResetJewelPresenter.shared.statusItemButton = item.button
    }

    func configureQuotaResetCelebrations(quotaService: ProviderQuotaService) {
        let store = quotaService.celebrationStore
        store.settingsProvider = { [weak self] in self?.settingsManager?.quotas }
        store.trayVisibleProvider = { [weak self] in
            self?.glassPopoverPanel?.isVisible == true || self?.popover?.isShown == true
        }
        store.vaultVisibleProvider = {
            NSApp.windows.contains { window in
                window.isVisible && window.title.localizedCaseInsensitiveContains("quota")
            }
        }
        store.presentJewel = { performance in
            QuotaResetJewelPresenter.shared.show(performance)
        }
        store.dismissJewel = {
            QuotaResetJewelPresenter.shared.hide()
        }
        store.announce = { text in
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                NSAccessibility.post(
                    element: window,
                    notification: .announcementRequested,
                    userInfo: [.announcement: text]
                )
            }
        }
        store.notify = { event in
            QuotaResetCelebrationNotifier.post(event)
        }
        QuotaResetJewelPresenter.shared.statusItemButton = statusItem?.button
        QuotaResetJewelPresenter.shared.onOpen = { [weak self] in
            guard let button = self?.statusItem?.button else { return }
            self?.showPopover(button)
        }
    }

    /// Watches `colorfulMenuBarIcon` and swaps the status item image live.
    func observeMenuBarIconStyle() {
        guard let settingsManager else { return }
        menuBarIconObservation = withObservationTracking {
            _ = settingsManager.appearance.colorfulMenuBarIcon
            return nil as Any?
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshMenuBarIconStyle()
                self.observeMenuBarIconStyle()
            }
        }
    }

    func refreshMenuBarIconStyle() {
        guard let button = statusItem?.button else { return }
        button.image = OpenBurnBarStatusItemBrandMark.image(
            colorful: shouldRenderColorfulMenuBarIcon
        )
    }

    private var shouldRenderColorfulMenuBarIcon: Bool {
        settingsManager?.appearance.colorfulMenuBarIcon ?? true
    }

    /// Overlays a small ember dot on the menu-bar icon whenever an update is
    /// available or being applied, so users notice without opening anything.
    /// Implemented as a subview so it never disturbs the base icon's template
    /// tinting (which the icon-style observer keeps swapping).
    private func observeUpdateBadge() {
        #if !DISTRIBUTION_MAS
        updateBadgeObservation = withObservationTracking {
            _ = DirectDownloadUpdateChecker.shared.phase
            return nil as Any?
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshUpdateBadge()
                self?.observeUpdateBadge()
            }
        }
        refreshUpdateBadge()
        #endif
    }

    @MainActor
    private func refreshUpdateBadge() {
        #if !DISTRIBUTION_MAS
        guard let button = statusItem?.button else { return }
        let shouldShow = DirectDownloadUpdateChecker.shared.phase.isActionable
        guard shouldShow else {
            updateBadgeView?.removeFromSuperview()
            updateBadgeView = nil
            return
        }
        let diameter: CGFloat = 6
        let badge = updateBadgeView ?? {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor(srgbRed: 0.98, green: 0.31, blue: 0.33, alpha: 1).cgColor
            view.layer?.cornerRadius = diameter / 2
            view.layer?.borderWidth = 0.5
            view.layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
            return view
        }()
        if badge.superview == nil { button.addSubview(badge) }
        badge.frame = NSRect(
            x: button.bounds.width - diameter - 1,
            y: button.bounds.height - diameter - 1,
            width: diameter,
            height: diameter
        )
        updateBadgeView = badge
        #endif
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        let triggeringEvent = NSApp.currentEvent.map(OpenBurnBarStatusItemEventSnapshot.init)
        handleStatusItemClickOnMainActor(triggeringEvent: triggeringEvent)
    }

    private func handleStatusItemClickOnMainActor(triggeringEvent: OpenBurnBarStatusItemEventSnapshot?) {
        guard let button = statusItem?.button else {
            return
        }
        guard !OpenBurnBarStatusItemClick.shouldIgnoreKeyboardRetoggle(
            triggeringEvent,
            isPopoverShown: glassPopoverPanel?.isVisible ?? popover?.isShown ?? false
        ) else {
            return
        }
        guard shouldHandleStatusItemEvent(triggeringEvent) else {
            return
        }

        switch OpenBurnBarStatusItemClick.action(for: nil) {
        case .togglePopover:
            togglePopover(button)
        case .showSecondaryMenu:
            showSecondaryMenu(button)
        case .ignore:
            break
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if glassPopoverPanel?.isVisible == true || popover?.isShown == true {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }

    func showPopover(_ sender: NSStatusBarButton) {
        let popover = ensurePopover()

        // Fallback only: the prewarmer rebuilds content off the click path
        // after launch and after every close (§15 of
        // docs/architecture/macos-performance.md). This branch covers a
        // click that outruns the scheduled prime.
        if popover.contentViewController == nil {
            installPopoverContent(into: popover)
        }

        guard let host = popover.contentViewController,
              let statusFrame = sender.openBurnBarScreenFrame else { return }
        popover.contentViewController = nil

        let panel = ensureGlassPopoverPanel()
        panel.contentViewController = OpenBurnBarGlassHostingController(contentController: host)
        panel.anchor(to: statusFrame)

        NSApp.activate(ignoringOtherApps: true)
        OpenBurnBarPopoverWindowConfigurator.apply(to: panel)
        popoverDismissController.installEscapeKeyMonitor { [weak self] in
            self?.closePopover(nil)
        }
        Analytics.shared.track(.menubarPopoverShown)
    }

    private func ensurePopover() -> NSPopover {
        if let popover {
            return popover
        }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        self.popover = popover
        return popover
    }

    private func ensureGlassPopoverPanel() -> OpenBurnBarGlassPopoverPanel {
        if let glassPopoverPanel { return glassPopoverPanel }
        let panel = OpenBurnBarGlassPopoverPanel()
        glassPopoverPanel = panel
        return panel
    }

    private func closePopover(_ sender: Any?) {
        if let panel = glassPopoverPanel, panel.isVisible {
            panel.orderOut(sender)
            panel.contentViewController = nil
            popoverDismissController.uninstall()
            popoverPrewarmer?.schedulePrime()
            return
        }
        guard let popover, popover.isShown else { return }
        popover.performClose(sender)
    }

    /// Builds a brand-new content controller from the CURRENT router
    /// factory and installs it. Shared by the click-path fallback and the
    /// off-click prewarm.
    private func installPopoverContent(into popover: NSPopover) {
        let content = AppCommandRouter.shared.makeMenuBarPopoverContent?({ [weak self] in
            self?.closePopover(nil)
        }) ?? AnyView(Text("No Content"))

        let host = NSHostingController(rootView: content)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        popover.contentViewController = host
    }

    // Internal (not private) so the popover prewarm wiring is unit-testable;
    // production callers are unchanged (applicationDidFinishLaunching and the
    // prewarmer's prime closure).
    func installPopoverPrewarming() {
        let prewarmer = PopoverContentPrewarmer(
            isPopoverShown: { [weak self] in
                guard let self else { return false }
                return self.glassPopoverPanel?.isVisible == true || self.popover?.isShown == true
            },
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
        popover.contentSize = NSSize(width: 340, height: 540)
    }

    private func installStatusItemMouseFallback() {
        guard statusItemLocalMouseMonitor == nil else {
            return
        }

        statusItemLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: OpenBurnBarStatusItemClick.fallbackActionMask,
            handler: Self.makeStatusItemMouseFallbackHandler(delegate: self)
        )
    }

    nonisolated private static func makeStatusItemMouseFallbackHandler(delegate: AppDelegate) -> (NSEvent) -> NSEvent? {
        { [weak delegate] event in
            let snapshot = OpenBurnBarStatusItemFallbackEvent(event)
            Task { @MainActor [weak delegate] in
                delegate?.handleStatusItemFallbackMouseEvent(snapshot)
            }
            return event
        }
    }

    func uninstallStatusItemMouseFallback() {
        if let monitor = statusItemLocalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            statusItemLocalMouseMonitor = nil
        }
    }

    private func handleStatusItemFallbackMouseEvent(_ event: OpenBurnBarStatusItemFallbackEvent) {
        guard let button = statusItem?.button,
              let frame = button.openBurnBarScreenFrame,
              OpenBurnBarMenuExtraClickFallback.click(event.mouseLocation, hits: frame),
              shouldHandleStatusItemEvent(event)
        else {
            return
        }

        switch OpenBurnBarStatusItemClick.action(for: event.eventType) {
        case .togglePopover:
            togglePopover(button)
        case .showSecondaryMenu:
            showSecondaryMenu(button)
        case .ignore:
            break
        }
    }

    private func shouldHandleStatusItemEvent(_ event: OpenBurnBarStatusItemEventSnapshot?) -> Bool {
        guard let event else {
            return shouldHandleStatusItemEvent(
                key: nil,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
        }
        let key = OpenBurnBarStatusItemClick.EventKey(event)
        return shouldHandleStatusItemEvent(key: key, timestamp: event.timestamp)
    }

    private func shouldHandleStatusItemEvent(_ event: OpenBurnBarStatusItemFallbackEvent) -> Bool {
        let key = OpenBurnBarStatusItemClick.EventKey(
            eventNumber: event.eventNumber,
            eventTypeRawValue: event.eventTypeRawValue,
            timestamp: event.timestamp
        )
        return shouldHandleStatusItemEvent(key: key, timestamp: event.timestamp)
    }

    private func shouldHandleStatusItemEvent(
        key: OpenBurnBarStatusItemClick.EventKey?,
        timestamp: TimeInterval
    ) -> Bool {
        if let key, key == lastHandledStatusItemEventKey {
            return false
        }
        if timestamp - lastHandledStatusItemEventTime < 0.12 {
            return false
        }
        lastHandledStatusItemEventKey = key
        lastHandledStatusItemEventTime = timestamp
        return true
    }

    private func showSecondaryMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        let dashboard = menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboardAction(_:)), keyEquivalent: "d"); dashboard.target = self
        let learning = menu.addItem(
            withTitle: "What BurnBar Learned…",
            action: #selector(openSafariLearningAction(_:)),
            keyEquivalent: ""
        )
        learning.target = self
        let settings = menu.addItem(withTitle: "Settings...", action: #selector(openSettingsAction(_:)), keyEquivalent: ","); settings.target = self
#if !DISTRIBUTION_MAS
        // cov:ignore on the next line -- status-menu wiring; behavior is
        // line-gated in the DirectDownload* companion tests.
        let updates = menu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdatesAction(_:)), keyEquivalent: ""); updates.target = self // cov:ignore -- menu glue
#endif
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit \(OpenBurnBarCore.OpenBurnBarIdentity.productName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); quit.target = NSApp

        let anchor = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: anchor, in: sender)
    }

    @objc private func openDashboardAction(_ sender: Any?) {
        AppCommandRouter.shared.openDashboard?()
    }

    @objc private func openSettingsAction(_ sender: Any?) {
        AppCommandRouter.shared.openSettings?()
    }

    @objc private func openSafariLearningAction(_ sender: Any?) {
        AppCommandRouter.shared.openSafariLearning?()
    }

#if !DISTRIBUTION_MAS
    @objc private func checkForUpdatesAction(_ sender: Any?) { // cov:ignore -- menu-action glue; checkForUpdatesNow's logic is line-gated in the DirectDownload* companions
        DirectDownloadUpdateChecker.shared.checkForUpdatesNow() // cov:ignore -- see above
    }
#endif

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        guard let shownPopover = notification.object as? NSPopover,
              shownPopover === popover,
              let window = shownPopover.contentViewController?.view.window
        else {
            return
        }

        configureMenuPopoverWindow(window)
    }

    func popoverDidClose(_ notification: Notification) {
        // Clear content when closed to ensure fresh state on next show
        // (fd19d53ac) — then rebuild it on the next main-queue turn so the
        // following open pays no construction or first-layout cost on the
        // click path (§15).
        popoverDismissController.uninstall()
        popover?.contentViewController = nil
        popoverPrewarmer?.schedulePrime()
    }

    private func configureMenuPopoverWindow(_ window: NSWindow) {
        OpenBurnBarPopoverWindowConfigurator.apply(to: window)
    }
}

private struct OpenBurnBarStatusItemFallbackEvent: Sendable {
    let eventNumber: Int
    let eventTypeRawValue: NSEvent.EventType.RawValue
    let timestamp: TimeInterval
    let mouseLocationX: CGFloat
    let mouseLocationY: CGFloat

    var eventType: NSEvent.EventType? {
        NSEvent.EventType(rawValue: eventTypeRawValue)
    }

    var mouseLocation: NSPoint {
        NSPoint(x: mouseLocationX, y: mouseLocationY)
    }

    init(_ event: NSEvent) {
        self.eventNumber = event.eventNumber
        self.eventTypeRawValue = event.type.rawValue
        self.timestamp = event.timestamp
        let mouseLocation = NSEvent.mouseLocation
        self.mouseLocationX = mouseLocation.x
        self.mouseLocationY = mouseLocation.y
    }
}

private extension NSStatusBarButton {
    var openBurnBarScreenFrame: CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}
