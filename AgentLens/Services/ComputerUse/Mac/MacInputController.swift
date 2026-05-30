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
        case windowNotFound(CGWindowID)
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
            let displayId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { String($0.uint32Value) }
            // Translate from bottom-left-origin AppKit points to the
            // top-left-origin event-tap pixels CGEventPost expects.
            return MacInputCore.DisplayBounds(
                displayId: displayId,
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
        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: position, mouseButton: .left),
              let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: position, mouseButton: cgButton),
              let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: position, mouseButton: cgButton) else {
            throw InputError.eventCreationFailed
        }
        moveEvent.post(tap: .cghidEventTap)
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
        return Date().timeIntervalSince(started) * 1000.0
    }

    @discardableResult
    public func clickCurrent(button: Int = 0) throws -> Double {
        let current = CGEvent(source: nil)?.location ?? .zero
        return try click(x: Int(current.x), y: Int(current.y), button: button)
    }

    /// Type a UTF-8 string by walking each scalar through the
    /// Unicode keyboard event API. Slower than a paste but does not
    /// touch the user's pasteboard.
    @discardableResult
    public func type(text: String) throws -> Double {
        guard isAccessibilityTrusted() else { throw InputError.accessibilityNotTrusted }
        let started = Date()
        for typingEvent in MacInputCore.unicodeTypingEvents(for: text) {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: typingEvent.isKeyDown) else {
                throw InputError.eventCreationFailed
            }
            if typingEvent.carriesUnicodeText {
                var chars = Array(typingEvent.text.utf16)
                event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            }
            event.post(tap: .cghidEventTap)
        }
        return Date().timeIntervalSince(started) * 1000.0
    }

    /// Raise and focus a specific macOS window before keyboard events are
    /// posted. The inline terminal mirror uses this so phone-originated typing
    /// keeps landing in the Terminal window that is being captured, even if the
    /// user briefly activates another app on the Mac.
    @discardableResult
    public func focusWindow(windowID: CGWindowID) throws -> Double {
        guard isAccessibilityTrusted() else { throw InputError.accessibilityNotTrusted }
        guard let descriptor = Self.windowDescriptor(windowID: windowID) else {
            throw InputError.windowNotFound(windowID)
        }

        let started = Date()
        NSRunningApplication(processIdentifier: descriptor.processIdentifier)?
            .activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        let appElement = AXUIElementCreateApplication(descriptor.processIdentifier)
        guard let window = Self.matchingAccessibilityWindow(
            appElement: appElement,
            descriptor: descriptor
        ) else {
            throw InputError.windowNotFound(windowID)
        }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
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

    /// Synthesize a pixel-precise scroll event at a connected-display point.
    /// Positive deltas follow CGEvent's native wheel convention.
    @discardableResult
    public func scroll(x: Int, y: Int, deltaX: Int = 0, deltaY: Int) throws -> Double {
        guard isAccessibilityTrusted() else { throw InputError.accessibilityNotTrusted }
        guard isPointOnConnectedDisplay(x: x, y: y) else {
            throw InputError.displayBoundsViolation(x, y)
        }
        let started = Date()
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else {
            throw InputError.eventCreationFailed
        }
        event.location = CGPoint(x: CGFloat(x), y: CGFloat(y))
        event.post(tap: .cghidEventTap)
        return Date().timeIntervalSince(started) * 1000.0
    }

    @discardableResult
    public func pointerMove(deltaX: Int, deltaY: Int) throws -> Double {
        guard isAccessibilityTrusted() else { throw InputError.accessibilityNotTrusted }
        let started = Date()
        let current = CGEvent(source: nil)?.location ?? .zero
        let proposed = CGPoint(
            x: current.x + CGFloat(deltaX),
            y: current.y + CGFloat(deltaY)
        )
        guard isPointOnConnectedDisplay(x: Int(proposed.x), y: Int(proposed.y)) else {
            throw InputError.displayBoundsViolation(Int(proposed.x), Int(proposed.y))
        }
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: proposed,
            mouseButton: .left
        ) else {
            throw InputError.eventCreationFailed
        }
        event.post(tap: .cghidEventTap)
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

    private struct WindowDescriptor {
        let windowID: CGWindowID
        let processIdentifier: pid_t
        let title: String?
        let bounds: CGRect?
    }

    private static func windowDescriptor(windowID: CGWindowID) -> WindowDescriptor? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = windows.first,
              let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber else {
            return nil
        }
        let title = info[kCGWindowName as String] as? String
        let bounds: CGRect?
        if let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary {
            bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        } else {
            bounds = nil
        }
        return WindowDescriptor(
            windowID: windowID,
            processIdentifier: ownerPID.int32Value,
            title: title,
            bounds: bounds
        )
    }

    private static func matchingAccessibilityWindow(
        appElement: AXUIElement,
        descriptor: WindowDescriptor
    ) -> AXUIElement? {
        guard let windows = accessibilityWindows(for: appElement) else { return nil }
        if let bounds = descriptor.bounds,
           let frameMatch = windows.first(where: { window in
               guard let position = axCGPoint(window, kAXPositionAttribute as CFString),
                     let size = axCGSize(window, kAXSizeAttribute as CFString) else {
                   return false
               }
               let frame = CGRect(origin: position, size: size)
               return abs(frame.origin.x - bounds.origin.x) <= 3
                   && abs(frame.origin.y - bounds.origin.y) <= 3
                   && abs(frame.width - bounds.width) <= 6
                   && abs(frame.height - bounds.height) <= 6
           }) {
            return frameMatch
        }
        if let title = descriptor.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           let titleMatch = windows.first(where: {
               axString($0, kAXTitleAttribute as CFString) == title
           }) {
            return titleMatch
        }
        return windows.first
    }

    private static func accessibilityWindows(for appElement: AXUIElement) -> [AXUIElement]? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &raw)
        guard error == .success,
              let raw,
              let windows = raw as? [AXUIElement] else {
            return nil
        }
        return windows
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func axCGPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axCGSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let value = raw,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}

#endif
