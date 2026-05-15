import Foundation

public enum InsightMissionApprovalPolicy {
    public static func requiresPreDispatchApproval(
        approvalMode: String?,
        commandsAllowed: Bool,
        fileEditsAllowed: Bool
    ) -> Bool {
        let normalizedMode = approvalMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let riskyExecutionRequested = commandsAllowed || fileEditsAllowed
        switch normalizedMode {
        case "manual_all":
            return true
        case "risky_only", "existing_policy", nil, "":
            return riskyExecutionRequested
        case "read_only":
            return false
        default:
            return riskyExecutionRequested
        }
    }
}
