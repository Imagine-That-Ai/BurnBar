import Foundation

public struct BurnBarApprovalRequest: Codable, Hashable, Sendable {
    public let approvalID: BurnBarApprovalID
    public let runID: BurnBarRunID
    public let tool: BurnBarToolKind
    public let title: String
    public let message: String
    public let requestedAt: Date

    public init(
        approvalID: BurnBarApprovalID,
        runID: BurnBarRunID,
        tool: BurnBarToolKind,
        title: String,
        message: String,
        requestedAt: Date
    ) {
        self.approvalID = approvalID
        self.runID = runID
        self.tool = tool
        self.title = title
        self.message = message
        self.requestedAt = requestedAt
    }
}

public enum BurnBarApprovalDecision: String, Codable, Hashable, Sendable {
    case approve
    case reject
    case cancel
}

public struct BurnBarApprovalResponse: Codable, Hashable, Sendable {
    public let approvalID: BurnBarApprovalID
    public let clientID: BurnBarClientID
    public let decision: BurnBarApprovalDecision
    public let note: String?
    public let respondedAt: Date

    public init(
        approvalID: BurnBarApprovalID,
        clientID: BurnBarClientID,
        decision: BurnBarApprovalDecision,
        note: String? = nil,
        respondedAt: Date
    ) {
        self.approvalID = approvalID
        self.clientID = clientID
        self.decision = decision
        self.note = note
        self.respondedAt = respondedAt
    }
}

/// Reason codes for pre-dispatch execution readiness gate failures.
/// These codes are used consistently across daemon, app, and extension surfaces
/// to propagate actionable failure reasons when a mission cannot be dispatched.
public enum BurnBarExecutionReadinessCode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Required credential is missing or invalid for the execution provider.
    case missingCredential = "missing_credential"
    /// The target repository is invalid, inaccessible, or branch does not exist.
    case invalidRepoBranch = "invalid_repo_branch"
    /// Required runtime precondition is unavailable (e.g., workspace, tool, or service).
    case runtimeUnavailable = "runtime_unavailable"
    /// Credential exists but lacks sufficient permissions for the requested operation.
    case insufficientCredentialPermissions = "insufficient_credential_permissions"
}
