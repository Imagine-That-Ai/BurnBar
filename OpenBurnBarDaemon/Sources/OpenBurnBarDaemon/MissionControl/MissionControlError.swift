import OpenBurnBarCore
import Foundation

public enum BurnBarMissionControlError: Error, LocalizedError {
    case projectNotFound(String)
    case questionNotFound(BurnBarQuestionID)
    case followupNotFound(BurnBarFollowupID)
    case missionNotFound(BurnBarMissionID)
    case missionNotApproved(BurnBarMissionID)
    case missionTerminal(BurnBarMissionID, BurnBarMissionStatus)
    case simulatorRunNotFound(BurnBarSimulatorRunID)
    case missingPayload(String)
    /// VAL-DAEMON-011: Execution readiness gate failed with explicit reason code.
    case executionReadinessFailed(BurnBarMissionID, BurnBarExecutionReadinessCode, String)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let slug):
            return "OpenBurnBar controller project '\(slug)' was not found."
        case .questionNotFound(let id):
            return "OpenBurnBar pending question '\(id.rawValue)' was not found."
        case .followupNotFound(let id):
            return "OpenBurnBar followup '\(id.rawValue)' was not found."
        case .missionNotFound(let id):
            return "OpenBurnBar mission '\(id.rawValue)' was not found."
        case .missionNotApproved(let id):
            return "OpenBurnBar mission '\(id.rawValue)' has not been approved. Dispatch is blocked."
        case .missionTerminal(let id, let status):
            return "OpenBurnBar mission '\(id.rawValue)' is in terminal state '\(status.rawValue)'. Dispatch is blocked."
        case .simulatorRunNotFound(let id):
            return "OpenBurnBar simulator run '\(id.rawValue)' was not found."
        case .missingPayload(let eventType):
            return "OpenBurnBar controller event '\(eventType)' is missing a payload."
        case .executionReadinessFailed(let id, let code, let detail):
            return "OpenBurnBar mission '\(id.rawValue)' dispatch blocked: [\(code.rawValue)] \(detail)"
        }
    }
}
