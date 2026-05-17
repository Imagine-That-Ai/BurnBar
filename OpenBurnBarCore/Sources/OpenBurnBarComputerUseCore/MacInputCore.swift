import Foundation

/// Pure, platform-neutral logic that backs `MacInputController` —
/// virtual-key mapping, modifier-string normalization, and
/// display-bounds containment. Extracted so the Phase 11 logic is
/// unit-testable from the cross-platform core target (`MacInputController`
/// itself is AppKit-only and lives in the AgentLens target).
public enum MacInputCore {
    /// Map a user-facing key name to the macOS HIToolbox virtual-key
    /// code. Returns `nil` for unknown names. The table is the same
    /// one `MacInputController.virtualKey(for:)` consumes in the Mac
    /// target — kept in sync via this single source of truth.
    public static func virtualKey(for name: String) -> UInt16? {
        switch name.lowercased() {
        case "return", "enter": return 36
        case "tab": return 48
        case "space": return 49
        case "delete": return 51
        case "escape", "esc": return 53
        case "up": return 126
        case "down": return 125
        case "left": return 123
        case "right": return 124
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "=": return 24
        case "9": return 25
        case "7": return 26
        case "-": return 27
        case "8": return 28
        case "0": return 29
        case "]": return 30
        case "o": return 31
        case "u": return 32
        case "[": return 33
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "'": return 39
        case "k": return 40
        case ";": return 41
        case "\\": return 42
        case ",": return 43
        case "/": return 44
        case "n": return 45
        case "m": return 46
        case ".": return 47
        case "`": return 50
        default: return nil
        }
    }

    /// Canonical modifier flag bit field. Lifted from `CGEventFlags` so
    /// the test can assert it without importing CoreGraphics.
    public struct Modifiers: OptionSet, Sendable, Equatable, Codable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let command   = Modifiers(rawValue: 1 << 0)
        public static let alternate = Modifiers(rawValue: 1 << 1)
        public static let control   = Modifiers(rawValue: 1 << 2)
        public static let shift     = Modifiers(rawValue: 1 << 3)
        public static let function  = Modifiers(rawValue: 1 << 4)
    }

    /// Translate a string array (`["cmd", "shift"]`, `["⌘", "⇧"]`, etc.)
    /// into the canonical modifier bit field. Unknown tokens are
    /// silently ignored — the editor validates ahead of save.
    public static func modifiers(for raw: [String]) -> Modifiers {
        var result: Modifiers = []
        for token in raw {
            switch token.lowercased() {
            case "cmd", "command", "⌘": result.insert(.command)
            case "opt", "option", "alt", "⌥": result.insert(.alternate)
            case "ctrl", "control", "⌃": result.insert(.control)
            case "shift", "⇧": result.insert(.shift)
            case "fn": result.insert(.function)
            default: continue
            }
        }
        return result
    }

    /// Bounds check for a `(x, y)` display coordinate against a list of
    /// connected-display rectangles (already converted to the global
    /// `CGEventPost` top-left-origin coordinate space).
    public struct DisplayBounds: Sendable, Equatable, Codable {
        public let originX: Int
        public let originY: Int
        public let width: Int
        public let height: Int

        public init(originX: Int, originY: Int, width: Int, height: Int) {
            self.originX = originX
            self.originY = originY
            self.width = width
            self.height = height
        }
    }

    public static func contains(point: (x: Int, y: Int), displays: [DisplayBounds]) -> Bool {
        for d in displays {
            if point.x >= d.originX,
               point.x < d.originX + d.width,
               point.y >= d.originY,
               point.y < d.originY + d.height {
                return true
            }
        }
        return false
    }
}
