#if os(iOS)
import ActivityKit
import Foundation

@available(iOS 16.1, *)
public struct AgentWatchLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var appName: String
        public var lastAction: String
        public var actionsCount: Int
        public var approvalPending: Bool
        public var elapsed: TimeInterval

        public init(
            appName: String,
            lastAction: String,
            actionsCount: Int,
            approvalPending: Bool,
            elapsed: TimeInterval
        ) {
            self.appName = appName
            self.lastAction = lastAction
            self.actionsCount = actionsCount
            self.approvalPending = approvalPending
            self.elapsed = elapsed
        }
    }

    public var sessionId: String
    public var startedAt: Date

    public init(sessionId: String, startedAt: Date) {
        self.sessionId = sessionId
        self.startedAt = startedAt
    }
}
#endif
