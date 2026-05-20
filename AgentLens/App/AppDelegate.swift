import AppKit
import Carbon
import GoogleSignIn
import SwiftUI

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
            button.image = OpenBurnBarStatusItemBrandMark.image
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: OpenBurnBarStatusItemClick.actionMask)
        }
        self.statusItem = item
        installStatusItemMouseFallback()
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
    static let image: NSImage = {
        let side: CGFloat = 18
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
            rendered.isTemplate = false
            return rendered
        }
        let fallback = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        fallback.isTemplate = true
        return fallback
    }()
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
