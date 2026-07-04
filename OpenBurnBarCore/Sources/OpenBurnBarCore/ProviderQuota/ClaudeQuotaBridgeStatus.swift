import Foundation

public struct ClaudeQuotaBridgeStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case notInstalled
        case invalidConfiguration
        case disabledByHooks
        case awaitingFirstPayload
        case ready
    }

    public let state: State
    public let wrapperPath: String
    public let detailText: String
    public let lastPayloadAt: Date?

    public init(
        state: State,
        wrapperPath: String,
        detailText: String,
        lastPayloadAt: Date?
    ) {
        self.state = state
        self.wrapperPath = wrapperPath
        self.detailText = detailText
        self.lastPayloadAt = lastPayloadAt
    }
}