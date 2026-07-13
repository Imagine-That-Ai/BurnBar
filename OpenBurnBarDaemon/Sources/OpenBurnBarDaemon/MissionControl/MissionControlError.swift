import OpenBurnBarCore
import Foundation

public enum BurnBarMissionControlError: Error, LocalizedError {
    case projectNotFound(String)
    case invalidProjectIdentifier(String)
    case ambiguousProjectIdentifier(String)
    case projectIdentityConflict(String)
    case projectDeleted(String)
    case questionNotFound(BurnBarQuestionID)
    case followupNotFound(BurnBarFollowupID)
    case missionNotFound(BurnBarMissionID)
    case missionNotApproved(BurnBarMissionID)
    case missionTerminal(BurnBarMissionID, BurnBarMissionStatus)
    case enterprisePolicyBlocked(BurnBarMissionID, BurnBarEnterprisePolicyReasonCode, String)
    case performanceGuardrailExceeded(String, Double, Double)
    case simulatorRunNotFound(BurnBarSimulatorRunID)
    case missingPayload(String)
    /// VAL-DAEMON-011: Execution readiness gate failed with explicit reason code.
    case executionReadinessFailed(BurnBarMissionID, BurnBarExecutionReadinessCode, String)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let slug):
            return "OpenBurnBar controller project '\(slug)' was not found."
        case .invalidProjectIdentifier(let identifier):
            return "OpenBurnBar controller project identifier '\(identifier)' is invalid."
        case .ambiguousProjectIdentifier(let identifier):
            return "OpenBurnBar controller project identifier '\(identifier)' matches more than one project."
        case .projectIdentityConflict(let identifier):
            return "OpenBurnBar controller project identifier '\(identifier)' is already owned by another project."
        case .projectDeleted(let slug):
            return "OpenBurnBar controller project '\(slug)' was deleted and cannot be recreated without an explicit restore."
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
        case .enterprisePolicyBlocked(let id, let reasonCode, let detail):
            return "OpenBurnBar mission '\(id.rawValue)' blocked by enterprise policy [\(reasonCode.rawValue)]: \(detail)"
        case .performanceGuardrailExceeded(let metric, let threshold, let observed):
            return "OpenBurnBar mission-control performance guardrail exceeded [\(metric)]: observed \(observed) > threshold \(threshold)."
        case .simulatorRunNotFound(let id):
            return "OpenBurnBar simulator run '\(id.rawValue)' was not found."
        case .missingPayload(let eventType):
            return "OpenBurnBar controller event '\(eventType)' is missing a payload."
        case .executionReadinessFailed(let id, let code, let detail):
            return "OpenBurnBar mission '\(id.rawValue)' dispatch blocked: [\(code.rawValue)] \(detail)"
        }
    }
}
