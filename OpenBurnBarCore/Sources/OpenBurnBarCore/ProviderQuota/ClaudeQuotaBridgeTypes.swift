import Foundation

// MARK: - Claude statusline bridge (macOS seam; types public for Core adapters)

public struct ClaudeQuotaBridgeStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled
        case awaitingFirstPayload
        case ready
        case disabledByHooks
        case invalidConfiguration
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

    public var isInstalled: Bool {
        switch state {
        case .awaitingFirstPayload, .ready, .disabledByHooks:
            return true
        case .notInstalled, .invalidConfiguration:
            return false
        }
    }
}