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
        guard !riskyExecutionRequested else {
            return true
        }
        switch normalizedMode {
        case "manual_all":
            return true
        case "risky_only", "existing_policy", "read_only", nil, "":
            return false
        default:
            // Unknown / unrecognized approval mode → fail CLOSED: require
            // approval rather than silently dispatching a mission. Firestore
            // rules constrain approvalMode to the known enum, so this is
            // defense-in-depth for any caller that is not rules-validated (A4).
            return true
        }
    }
}
