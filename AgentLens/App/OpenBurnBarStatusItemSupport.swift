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
