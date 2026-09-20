#if os(iOS)
import ActivityKit
import Foundation

@available(iOS 16.1, *)
public enum AgentWatchLiveActivityCopy {
    /// Shown on the lock screen when ActivityKit cannot take a push token.
    /// Missing entitlement or token means the activity only refreshes while
    /// OpenBurnBar is running. Do not claim remote updates in that case.
    public static let localOnlyRefresh = "Updates while OpenBurnBar is open"
}

@available(iOS 16.1, *)
public struct AgentWatchLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var appName: String
        public var lastAction: String
        public var actionsCount: Int
        public var approvalPending: Bool
        public var elapsed: TimeInterval
        /// `true` only after ActivityKit delivered a per-activity push token.
        /// Absent or `false` means the lock screen should show local-only copy.
        public var remoteRefreshEnabled: Bool?
        /// Binds lock-screen Approve/Deny to one request. Absent means
        /// the buttons stay disabled. Never a video frame.
        public var pendingApprovalId: String?

        public var showsLocalOnlyRefreshCopy: Bool { remoteRefreshEnabled != true }

        public init(
            appName: String,
            lastAction: String,
            actionsCount: Int,
            approvalPending: Bool,
            elapsed: TimeInterval,
            remoteRefreshEnabled: Bool? = nil,
            pendingApprovalId: String? = nil
        ) {
            self.appName = appName
            self.lastAction = lastAction
            self.actionsCount = actionsCount
            self.approvalPending = approvalPending
            self.elapsed = elapsed
            self.remoteRefreshEnabled = remoteRefreshEnabled
            self.pendingApprovalId = pendingApprovalId
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
