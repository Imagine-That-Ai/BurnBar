import Foundation
import OpenBurnBarComputerUseCore

public struct RemoteAccessUnicodeTypingEvent: Equatable, Sendable {
    public let text: String
    public let isKeyDown: Bool
    public let carriesUnicodeText: Bool

    public init(text: String, isKeyDown: Bool, carriesUnicodeText: Bool) {
        self.text = text
        self.isKeyDown = isKeyDown
        self.carriesUnicodeText = carriesUnicodeText
    }
}

public enum RemoteAccessUnicodeTypingPlan {
    public static func events(for text: String) -> [RemoteAccessUnicodeTypingEvent] {
        MacInputCore.unicodeTypingEvents(for: text).map {
            RemoteAccessUnicodeTypingEvent(
                text: $0.text,
                isKeyDown: $0.isKeyDown,
                carriesUnicodeText: $0.carriesUnicodeText
            )
        }
    }
}
