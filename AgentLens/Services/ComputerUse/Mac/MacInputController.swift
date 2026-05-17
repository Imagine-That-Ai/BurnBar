#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import AppKit
import CoreGraphics
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Posts synthetic input events on macOS. Phase 11.
///
/// `#if !DISTRIBUTION_MAS`: Apple does not allow sandboxed (Mac App
/// Store) apps to request the Accessibility permission this controller
/// depends on, so the entire file compiles to nothing in the MAS
/// build. The direct-download / notarized build defines no
/// `DISTRIBUTION_MAS` and ships Path C. See
/// `docs/runbooks/computer-use-app-store.md`.
///
/// Wraps `CGEvent` + `AXIsProcessTrusted` and validates points against
/// connected displays so a vision-model coordinate that lands
/// off-screen never makes it onto the HID event tap. The bound check
/// + virtual-key map + modifier parsing live in
/// `OpenBurnBarComputerUseCore.MacInputCore` so they can be
/// unit-tested in isolation; this file is the AppKit-only glue layer.
public final class MacInputController: @unchecked Sendable {
    public enum InputError: Error, Equatable, Sendable {
        case accessibilityNotTrusted
        case displayBoundsViolation(Int, Int)
        case eventCreationFailed
        case dragEndpointMissing
        case unknownKey(String)
    }

    public init() {}

    /// Live `AXIsProcessTrusted` check. The plan polls this every 5 s
    /// from `ComputerUseSessionCoordinator`; this method is the
    /// canonical probe.
    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Display-aware bounds check. Returns true if the point lies
    /// inside any connected display's frame, translated into the
    /// global event-tap coordinate space. Delegates the actual
    /// containment test to `MacInputCore.contains` so the test target
    /// can prove the predicate without an attached display.
    public func isPointOnConnectedDisplay(x: Int, y: Int) -> Bool {
        let totalHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let displays: [MacInputCore.DisplayBounds] = NSScreen.screens.map { screen in
            let frame = screen.frame
            // Translate from bottom-left-origin AppKit points to the
            // top-left-origin event-tap pixels CGEventPost expects.
            return MacInputCore.DisplayBounds(
                originX: Int(frame.origin.x),
                originY: Int(totalHeight - frame.maxY),
                width: Int(frame.width),
                height: Int(frame.height)
            )
        }
        return MacInputCore.contains(point: (x, y), displays: displays)
    }

    /// Synthesize a mouse click. `button` is 0 (left) / 1 (right) /
    /// 2 (middle). Returns the elapsed dispatch time in milliseconds
    /// for the audit entry.
    @discardableResult
    public func click(x: Int, y: Int, button: Int = 0) throws -> Double {
        guard isAccessibilityTrusted() else { throw InputError.accessibilityNotTrusted }
        guard isPointOnConnectedDisplay(x: x, y: y) else {
            throw InputError.displayBoundsViolation(x, y)
        }
        let position = CGPoint(x: CGFloat(x), y: CGFloat(y))
        let downType: CGEventType = button == 1 ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == 1 ? .rightMouseUp : .leftMouseUp
        let cgButton: CGMouseButton = button == 1 ? .right : .left

        let started = Date()
        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: position, mouseButton: cgButton),
              let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: position, mouseButton: cgButton) else {
            throw InputError.eventCreationFailed
        }
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
        return Date().timeIntervalSince(started) * 1000.0
    }

    /// Type a UTF-8 string by walking each scalar through the
    /// Unicode keyboard event API. Slower than a paste but does not
    /// touch the user's pasteboard.
    @discardableResult
    public func type(text: String) throws -> Double {
        guard isAccessibilityTrusted() else { throw InputError.accessibilityNotTrusted }
        let started = Date()
        for char in text {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                throw InputError.eventCreationFailed
            }
            var chars = Array(String(char).utf16)
            event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            event.post(tap: .cghidEventTap)

            guard let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw InputError.eventCreationFailed
            }
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.post(tap: .cghidEventTap)
        }
        return Date().timeIntervalSince(started) * 1000.0
    }

    /// Press a named key. Supported strings: "Return", "Tab", "Escape",
    /// "Delete", "Space", "Up", "Down", "Left", "Right", "A".."Z", "0".."9".
    @discardableResult
    public func key(_ name: String, modifiers: [String] = []) throws -> Double {
        guard isAccessibilityTrusted() else { throw InputError.accessibilityNotTrusted }
        guard let virtualKey = MacInputCore.virtualKey(for: name) else {
            throw InputError.unknownKey(name)
        }
        let started = Date()
        let flags = MacInputController.cgEventFlags(for: modifiers)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(virtualKey), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(virtualKey), keyDown: false) else {
            throw InputError.eventCreationFailed
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return Date().timeIntervalSince(started) * 1000.0
    }

    /// Synthesize a drag from `(sx, sy)` to `(ex, ey)`.
    @discardableResult
    public func dragDrop(
        startX sx: Int, startY sy: Int,
        endX ex: Int, endY ey: Int
    ) throws -> Double {
        guard isAccessibilityTrusted() else { throw InputError.accessibilityNotTrusted }
        guard isPointOnConnectedDisplay(x: sx, y: sy) else {
            throw InputError.displayBoundsViolation(sx, sy)
        }
        guard isPointOnConnectedDisplay(x: ex, y: ey) else {
            throw InputError.displayBoundsViolation(ex, ey)
        }
        let start = CGPoint(x: CGFloat(sx), y: CGFloat(sy))
        let end = CGPoint(x: CGFloat(ex), y: CGFloat(ey))
        let started = Date()
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
              let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: end, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
            throw InputError.eventCreationFailed
        }
        down.post(tap: .cghidEventTap)
        drag.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return Date().timeIntervalSince(started) * 1000.0
    }

    /// Whole-shortcut form: send `cmd+c`, `cmd+shift+left`, etc.
    @discardableResult
    public func shortcut(key: String, modifiers: [String]) throws -> Double {
        try self.key(key, modifiers: modifiers)
    }

    // MARK: keyboard map

    /// Bridge into the shared `MacInputCore.virtualKey` table. Retained
    /// for callers that already reference the static method; new code
    /// should go through `MacInputCore` directly.
    static func virtualKey(for name: String) -> CGKeyCode? {
        guard let raw = MacInputCore.virtualKey(for: name) else { return nil }
        return CGKeyCode(raw)
    }

    static func cgEventFlags(for modifiers: [String]) -> CGEventFlags {
        let normalized = MacInputCore.modifiers(for: modifiers)
        var flags: CGEventFlags = []
        if normalized.contains(.command) { flags.insert(.maskCommand) }
        if normalized.contains(.alternate) { flags.insert(.maskAlternate) }
        if normalized.contains(.control) { flags.insert(.maskControl) }
        if normalized.contains(.shift) { flags.insert(.maskShift) }
        if normalized.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

#endif
