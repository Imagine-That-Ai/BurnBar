#if canImport(AppKit)
import AppKit
import CoreGraphics

/// Best-effort printable character extraction for global key monitors.
/// Use the layout-resolved characters first so shifted punctuation such as `&` is
/// preserved. Fall back to the modifier-free value, the bridged raw event, and finally
/// the US-ANSI keycode map when an event does not carry a character payload.
public enum TextExpansionKeyEventCharacters {
    public static func characters(from event: NSEvent) -> String? {
        if let chars = event.characters, !chars.isEmpty {
            return chars
        }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars
        }
        if let cgEvent = event.cgEvent,
           let unicode = unicodeString(from: cgEvent),
           !unicode.isEmpty {
            return unicode
        }
        return usKeyboardCharacter(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift))
    }

    /// Character extraction for a raw `CGEvent` (e.g. inside a `CGEvent` tap callback).
    ///
    /// `keyboardGetUnicodeString` reflects the layout-resolved character *with* modifiers
    /// applied, so Shift+7 reliably yields `&` — unlike `NSEvent.charactersIgnoringModifiers`,
    /// which can drop Shift and return `7`, breaking `&&` trigger detection. We fall back to a
    /// US-ANSI keycode map when the event carries no unicode payload.
    public static func characters(fromCGEvent event: CGEvent) -> String? {
        if let unicode = unicodeString(from: event), !unicode.isEmpty {
            return unicode
        }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        return usKeyboardCharacter(keyCode: keyCode, shift: event.flags.contains(.maskShift))
    }

    private static func unicodeString(from event: CGEvent) -> String? {
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: 0,
            actualStringLength: &length,
            unicodeString: nil
        )
        guard length > 0 else { return nil }
        var buffer = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(
            maxStringLength: length,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }

    /// US ANSI fallback for punctuation-heavy triggers like `&&name`.
    static func usKeyboardCharacter(keyCode: UInt16, shift: Bool) -> String? {
        let base: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
            39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
            49: " ", 50: "`"
        ]
        let shifted: [UInt16: String] = [
            18: "!", 19: "@", 20: "#", 21: "$", 23: "%", 22: "^", 26: "&", 28: "*", 25: "(",
            29: ")", 27: "_", 24: "+", 30: "}", 33: "{", 39: "\"", 41: ":", 42: "|", 43: "<",
            44: ">", 47: "?", 50: "~"
        ]
        if shift, let value = shifted[keyCode] {
            return value
        }
        return base[keyCode]
    }
}
#endif
