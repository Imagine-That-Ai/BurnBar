import Foundation

/// Run ID (3.2: extracted; usage events and war-room dispatch stamp it).

public struct BurnBarRunID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID().uuidString
    }
}
