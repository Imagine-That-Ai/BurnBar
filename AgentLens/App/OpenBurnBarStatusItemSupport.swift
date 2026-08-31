import AppKit

// Extracted verbatim from AppDelegate.swift (audit wave 4, item 14).
// Pure status-item/popover support types: click action + dedupe-key model,
// event snapshot, brand-mark image, click-fallback geometry, and the
// popover window configurator.

enum OpenBurnBarStatusItemClick {
    struct EventKey: Equatable {
        let eventNumber: Int
        let eventTypeRawValue: NSEvent.EventType.RawValue
        let timestampBucket: Int

        init(_ event: NSEvent) {
            self.eventNumber = event.eventNumber
            self.eventTypeRawValue = event.type.rawValue
            self.timestampBucket = Int(event.timestamp * 1_000)
        }

        init(_ event: OpenBurnBarStatusItemEventSnapshot) {
            self.eventNumber = event.eventNumber
            self.eventTypeRawValue = event.eventTypeRawValue
            self.timestampBucket = Int(event.timestamp * 1_000)
        }

        init(eventNumber: Int, eventTypeRawValue: NSEvent.EventType.RawValue, timestamp: TimeInterval) {
            self.eventNumber = eventNumber
            self.eventTypeRawValue = eventTypeRawValue
            self.timestampBucket = Int(timestamp * 1_000)
        }
    }

    enum Action: Equatable {
        case togglePopover
        case showSecondaryMenu
        case ignore
    }

    static let primaryActionMask: NSEvent.EventTypeMask = [.leftMouseDown]
    static let fallbackActionMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
    static let actionMask: NSEvent.EventTypeMask = primaryActionMask.union(fallbackActionMask)

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

    static func shouldIgnoreKeyboardRetoggle(_ event: NSEvent?, isPopoverShown: Bool) -> Bool {
        shouldIgnoreKeyboardRetoggle(
            eventType: event?.type,
            charactersIgnoringModifiers: event?.charactersIgnoringModifiers,
            isPopoverShown: isPopoverShown
        )
    }

    static func shouldIgnoreKeyboardRetoggle(
        _ event: OpenBurnBarStatusItemEventSnapshot?,
        isPopoverShown: Bool
    ) -> Bool {
        shouldIgnoreKeyboardRetoggle(
            eventType: event?.eventType,
            charactersIgnoringModifiers: event?.charactersIgnoringModifiers,
            isPopoverShown: isPopoverShown
        )
    }

    static func shouldIgnoreKeyboardRetoggle(
        eventType: NSEvent.EventType?,
        charactersIgnoringModifiers: String?,
        isPopoverShown: Bool
    ) -> Bool {
        guard isPopoverShown, eventType == .keyDown else {
            return false
        }
        switch charactersIgnoringModifiers {
        case " ", "\r", "\n", "\u{3}":
            return true
        default:
            return false
        }
    }
}

struct OpenBurnBarStatusItemEventSnapshot: Sendable {
    let eventNumber: Int
    let eventTypeRawValue: NSEvent.EventType.RawValue
    let timestamp: TimeInterval
    let charactersIgnoringModifiers: String?

    init(_ event: NSEvent) {
        self.eventNumber = event.eventNumber
        self.eventTypeRawValue = event.type.rawValue
        self.timestamp = event.timestamp
        self.charactersIgnoringModifiers = event.charactersIgnoringModifiers
    }

    var eventType: NSEvent.EventType? {
        NSEvent.EventType(rawValue: eventTypeRawValue)
    }
}

enum OpenBurnBarStatusItemBrandMark {
    private static let side: CGFloat = 18
    static let statusItemWidth: CGFloat = NSStatusItem.squareLength
    static let menuBarTitle = ""

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

enum OpenBurnBarPopoverWindowConfigurator {
    @MainActor
    static func apply(to window: NSWindow) {
        apply(to: window, orderFront: defaultOrderFront)
    }

    @MainActor
    static func apply(to window: NSWindow, orderFront: @MainActor (NSWindow) -> Void) {
        window.level = .statusBar
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        // NSPopover supplies an AppKit panel around the SwiftUI hierarchy. If
        // that panel stays opaque, SwiftUI's Liquid Glass can only sample a
        // flat window background and reads like a dark card. Keep the host
        // transparent so the single root glass plate samples the desktop
        // behind the popover in either system appearance.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        if let panel = window as? NSPanel {
            panel.hidesOnDeactivate = false
            // Keep SwiftUI text fields in the popover as normal key-window
            // editors. If the status-item button keeps keyboard ownership,
            // Space performs the button again and closes the popover.
            panel.becomesKeyOnlyIfNeeded = false
        }
        orderFront(window)
    }

    @MainActor
    private static func defaultOrderFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// Arrowless host for the menu tray. `NSPopover` always contributes its own
/// frosted chrome, which prevents clear Liquid Glass from sampling the desktop.
/// A transparent borderless panel leaves the SwiftUI glass plate as the only
/// compositing surface and gives it real pixels to refract.
@MainActor
final class OpenBurnBarGlassPopoverPanel: NSPanel {
    private var statusItemFrame: CGRect = .zero

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 540),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func anchor(to statusItemFrame: CGRect) {
        self.statusItemFrame = statusItemFrame
        syncStoredSize()
    }

    @objc private func defaultsDidChange(_ notification: Notification) {
        syncStoredSize()
    }

    private func syncStoredSize() {
        guard statusItemFrame != .zero else { return }
        let defaults = UserDefaults.standard
        let storedWidth = defaults.object(forKey: "popoverTrayWidth") as? Double ?? 340
        let storedHeight = defaults.object(forKey: "popoverTrayHeight") as? Double ?? 540
        let screen = NSScreen.screens.first { $0.frame.intersects(statusItemFrame) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(CGFloat(storedWidth), 320), min(560, visibleFrame.width - 24))
        let maximumHeight = min(max(visibleFrame.height * 0.86, 500), 760)
        let height = min(max(CGFloat(storedHeight), 500), maximumHeight)
        let idealX = statusItemFrame.midX - width / 2
        let x = min(max(idealX, visibleFrame.minX + 8), visibleFrame.maxX - width - 8)
        let y = max(visibleFrame.minY + 8, statusItemFrame.minY - height - 8)
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: isVisible, animate: false)
    }
}

/// Places the SwiftUI tray inside AppKit's system glass at the window boundary.
/// Unlike a glass modifier rendered inside a transparent hosting view,
/// `NSGlassEffectView` can refract content from behind the panel itself.
@MainActor
final class OpenBurnBarGlassHostingController: NSViewController {
    private let hostedController: NSViewController
    private weak var nativeGlassView: NSView?

    init(contentController: NSViewController) {
        hostedController = contentController
        super.init(nibName: nil, bundle: nil)
        addChild(contentController)

        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.style = .regular
            glassView.cornerRadius = 22
            glassView.tintColor = nil
            glassView.contentView = contentController.view
            nativeGlassView = glassView
            view = glassView
        } else {
            let materialView = NSVisualEffectView()
            materialView.material = .popover
            materialView.blendingMode = .behindWindow
            materialView.state = .active
            materialView.wantsLayer = true
            materialView.layer?.cornerRadius = 22
            materialView.layer?.masksToBounds = true
            materialView.addSubview(contentController.view)
            contentController.view.frame = materialView.bounds
            contentController.view.autoresizingMask = [.width, .height]
            view = materialView
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(glassPreferenceDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        applyGlassPreference()
    }

    @objc private func glassPreferenceDidChange(_ notification: Notification) {
        applyGlassPreference()
    }

    private func applyGlassPreference() {
        guard #available(macOS 26.0, *),
              let glassView = nativeGlassView as? NSGlassEffectView else { return }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let raw = UserDefaults.standard.double(forKey: LiquidGlassTransparency.storageKey)
        let effective = LiquidGlassTransparency.effective(
            raw,
            reduceTransparency: reduceTransparency
        )
        // Clear glass only when the user asked for it and Reduce Transparency
        // is off; otherwise stay on the denser regular plate so cardless rows
        // remain legible against the desktop.
        glassView.style = LiquidGlassTransparency.usesClearGlass(effective) ? .clear : .regular
        glassView.cornerRadius = 22
        glassView.tintColor = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
