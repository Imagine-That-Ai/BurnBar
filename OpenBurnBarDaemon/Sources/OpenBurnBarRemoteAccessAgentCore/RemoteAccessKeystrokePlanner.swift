import Foundation

public struct RemoteAccessKeystroke: Equatable, Sendable {
    public var character: Character
    public var virtualKey: UInt16
    public var requiresShift: Bool

    public init(character: Character, virtualKey: UInt16, requiresShift: Bool = false) {
        self.character = character
        self.virtualKey = virtualKey
        self.requiresShift = requiresShift
    }
}

public enum RemoteAccessKeystrokePlanner {
    public static func planForANSIUSKeyboard(_ text: String) -> [RemoteAccessKeystroke]? {
        var plan: [RemoteAccessKeystroke] = []
        for character in text {
            guard let keystroke = keystroke(for: character) else { return nil }
            plan.append(keystroke)
        }
        return plan
    }

    public static func keystroke(for character: Character) -> RemoteAccessKeystroke? {
        if let entry = lowercaseKeyCodes[character] {
            return RemoteAccessKeystroke(character: character, virtualKey: entry)
        }
        if let scalar = String(character).unicodeScalars.first,
           scalar.properties.isAlphabetic,
           String(character).count == 1 {
            let lower = Character(String(scalar).lowercased())
            if let keyCode = lowercaseKeyCodes[lower] {
                return RemoteAccessKeystroke(
                    character: character,
                    virtualKey: keyCode,
                    requiresShift: true
                )
            }
        }
        if let entry = shiftedKeyCodes[character] {
            return RemoteAccessKeystroke(
                character: character,
                virtualKey: entry,
                requiresShift: true
            )
        }
        return nil
    }

    private static let lowercaseKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49
    ]

    private static let shiftedKeyCodes: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "&": 26,
        "*": 28, "(": 25, ")": 29, "+": 24, "}": 30, "{": 33, "\"": 39,
        ":": 41, "|": 42, "<": 43, "?": 44, ">": 47, "~": 50, "_": 27
    ]
}
