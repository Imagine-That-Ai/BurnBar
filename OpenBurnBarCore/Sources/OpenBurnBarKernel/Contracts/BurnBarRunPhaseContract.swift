import Foundation

public enum BurnBarRunPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case idle
    case planning
    case awaitingApproval = "awaiting_approval"
    case awaitingComputerUseSession = "awaiting_computer_use_session"
    case executingTool = "executing_tool"
    case waitingOnCompanion = "waiting_on_companion"
    case modelStreaming = "model_streaming"
    case completed
    case failed
    case cancelled
}
