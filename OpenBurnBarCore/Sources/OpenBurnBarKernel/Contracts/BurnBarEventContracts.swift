import Foundation

public enum BurnBarDaemonEventKind: String, Codable, Hashable, Sendable {
    case runStateUpdated = "run_state_updated"
    case approvalRequested = "approval_requested"
    case usageRecorded = "usage_recorded"
    case arbitrationUpdated = "arbitration_updated"
}

public struct BurnBarDaemonEvent: Codable, Hashable, Sendable {
    public let kind: BurnBarDaemonEventKind
    public let runState: BurnBarRunStateSnapshot?
    public let approvalRequest: BurnBarApprovalRequest?
    public let usageEvent: BurnBarUsageEvent?
    public let arbitration: BurnBarClientArbitrationSnapshot?
    public let emittedAt: Date

    public init(
        kind: BurnBarDaemonEventKind,
        runState: BurnBarRunStateSnapshot? = nil,
        approvalRequest: BurnBarApprovalRequest? = nil,
        usageEvent: BurnBarUsageEvent? = nil,
        arbitration: BurnBarClientArbitrationSnapshot? = nil,
        emittedAt: Date
    ) {
        self.kind = kind
        self.runState = runState
        self.approvalRequest = approvalRequest
        self.usageEvent = usageEvent
        self.arbitration = arbitration
        self.emittedAt = emittedAt
    }
}
