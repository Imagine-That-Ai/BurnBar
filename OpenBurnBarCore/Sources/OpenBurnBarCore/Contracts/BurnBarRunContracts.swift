import Foundation

public enum BurnBarRunPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case idle
    case planning
    case awaitingApproval = "awaiting_approval"
    case executingTool = "executing_tool"
    case waitingOnCompanion = "waiting_on_companion"
    case modelStreaming = "model_streaming"
    case completed
    case failed
    case cancelled
}

public struct BurnBarRunStateSnapshot: Codable, Hashable, Sendable {
    public let runID: BurnBarRunID
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID
    public let phase: BurnBarRunPhase
    public let modelID: String
    public let updatedAt: Date
    public let errorMessage: String?
    public let activeApprovalID: BurnBarApprovalID?

    public init(
        runID: BurnBarRunID,
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        phase: BurnBarRunPhase,
        modelID: String,
        updatedAt: Date,
        errorMessage: String? = nil,
        activeApprovalID: BurnBarApprovalID? = nil
    ) {
        self.runID = runID
        self.clientID = clientID
        self.sessionID = sessionID
        self.phase = phase
        self.modelID = modelID
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.activeApprovalID = activeApprovalID
    }
}

public enum BurnBarRunStateMachineError: Error, LocalizedError {
    case invalidTransition(from: BurnBarRunPhase, to: BurnBarRunPhase)

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to):
            return "Invalid OpenBurnBar run-state transition from \(from.rawValue) to \(to.rawValue)."
        }
    }
}

public enum BurnBarRunStateMachine {
    public static func canTransition(from: BurnBarRunPhase, to: BurnBarRunPhase) -> Bool {
        switch (from, to) {
        case (.idle, .planning):
            return true
        case (.planning, .awaitingApproval),
             (.planning, .executingTool),
             (.planning, .waitingOnCompanion),
             (.planning, .modelStreaming),
             (.planning, .completed),
             (.planning, .failed),
             (.planning, .cancelled):
            return true
        case (.awaitingApproval, .planning),
             (.awaitingApproval, .cancelled):
            return true
        case (.executingTool, .planning),
             (.executingTool, .awaitingApproval),
             (.executingTool, .waitingOnCompanion),
             (.executingTool, .modelStreaming),
             (.executingTool, .completed),
             (.executingTool, .failed),
             (.executingTool, .cancelled):
            return true
        case (.waitingOnCompanion, .awaitingApproval),
             (.waitingOnCompanion, .executingTool),
             (.waitingOnCompanion, .modelStreaming),
             (.waitingOnCompanion, .completed),
             (.waitingOnCompanion, .failed),
             (.waitingOnCompanion, .cancelled):
            return true
        case (.modelStreaming, .executingTool),
             (.modelStreaming, .completed),
             (.modelStreaming, .failed),
             (.modelStreaming, .cancelled):
            return true
        case (.failed, .planning),
             (.failed, .cancelled):
            return true
        default:
            return false
        }
    }

    @discardableResult
    public static func validatedTransition(from: BurnBarRunPhase, to: BurnBarRunPhase) throws -> BurnBarRunPhase {
        guard canTransition(from: from, to: to) else {
            throw BurnBarRunStateMachineError.invalidTransition(from: from, to: to)
        }
        return to
    }
}

public struct BurnBarRunCreateRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID
    public let prompt: String
    public let modelID: String
    public let metadata: [String: BurnBarJSONValue]

    public init(
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        prompt: String,
        modelID: String,
        metadata: [String: BurnBarJSONValue] = [:]
    ) {
        self.clientID = clientID
        self.sessionID = sessionID
        self.prompt = prompt
        self.modelID = modelID
        self.metadata = metadata
    }
}

public struct BurnBarRunCreateResponse: Codable, Hashable, Sendable {
    public let runID: BurnBarRunID
    public let phase: BurnBarRunPhase

    public init(runID: BurnBarRunID, phase: BurnBarRunPhase) {
        self.runID = runID
        self.phase = phase
    }
}

public struct BurnBarRunListRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let offset: Int
    public let limit: Int

    public init(clientID: BurnBarClientID, offset: Int = 0, limit: Int = 50) {
        self.clientID = clientID
        self.offset = max(offset, 0)
        self.limit = max(limit, 1)
    }
}

public struct BurnBarRunGetRequest: Codable, Hashable, Sendable {
    public let runID: BurnBarRunID
    public let clientID: BurnBarClientID

    public init(runID: BurnBarRunID, clientID: BurnBarClientID) {
        self.runID = runID
        self.clientID = clientID
    }
}

public struct BurnBarRunListResponse: Codable, Hashable, Sendable {
    public let runs: [BurnBarRunStateSnapshot]

    public init(runs: [BurnBarRunStateSnapshot]) {
        self.runs = runs
    }
}

public struct BurnBarRunDetailResponse: Codable, Hashable, Sendable {
    public let run: BurnBarRunStateSnapshot?
    public let approvalRequest: BurnBarApprovalRequest?
    public let pendingToolCall: BurnBarToolCallSnapshot?
    public let loopState: BurnBarAgentLoopState?
    public let arbitration: BurnBarClientArbitrationSnapshot?

    public init(
        run: BurnBarRunStateSnapshot?,
        approvalRequest: BurnBarApprovalRequest? = nil,
        pendingToolCall: BurnBarToolCallSnapshot? = nil,
        loopState: BurnBarAgentLoopState? = nil,
        arbitration: BurnBarClientArbitrationSnapshot? = nil
    ) {
        self.run = run
        self.approvalRequest = approvalRequest
        self.pendingToolCall = pendingToolCall
        self.loopState = loopState
        self.arbitration = arbitration
    }
}

public struct BurnBarRunSubscribeRequest: Codable, Hashable, Sendable {
    public let runID: BurnBarRunID
    public let clientID: BurnBarClientID

    public init(runID: BurnBarRunID, clientID: BurnBarClientID) {
        self.runID = runID
        self.clientID = clientID
    }
}

public struct BurnBarRunPollRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID
    public let runID: BurnBarRunID?
    public let limit: Int

    public init(clientID: BurnBarClientID, sessionID: BurnBarSessionID, runID: BurnBarRunID? = nil, limit: Int = 50) {
        self.clientID = clientID
        self.sessionID = sessionID
        self.runID = runID
        self.limit = max(limit, 1)
    }
}

public struct BurnBarRunEventBatch: Codable, Hashable, Sendable {
    public let runs: [BurnBarRunStateSnapshot]
    public let approvals: [BurnBarApprovalRequest]
    public let pendingToolCalls: [BurnBarToolCallSnapshot]
    public let arbitration: BurnBarClientArbitrationSnapshot?
    public let emittedAt: Date

    public init(
        runs: [BurnBarRunStateSnapshot],
        approvals: [BurnBarApprovalRequest],
        pendingToolCalls: [BurnBarToolCallSnapshot],
        arbitration: BurnBarClientArbitrationSnapshot?,
        emittedAt: Date
    ) {
        self.runs = runs
        self.approvals = approvals
        self.pendingToolCalls = pendingToolCalls
        self.arbitration = arbitration
        self.emittedAt = emittedAt
    }
}

public struct BurnBarRunCancelRequest: Codable, Hashable, Sendable {
    public let runID: BurnBarRunID
    public let clientID: BurnBarClientID
    public let reason: String?

    public init(runID: BurnBarRunID, clientID: BurnBarClientID, reason: String? = nil) {
        self.runID = runID
        self.clientID = clientID
        self.reason = reason
    }
}

public struct BurnBarRunRetryRequest: Codable, Hashable, Sendable {
    public let runID: BurnBarRunID
    public let clientID: BurnBarClientID

    public init(runID: BurnBarRunID, clientID: BurnBarClientID) {
        self.runID = runID
        self.clientID = clientID
    }
}

public struct BurnBarToolExecutionRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID
    public let runID: BurnBarRunID?

    public init(clientID: BurnBarClientID, sessionID: BurnBarSessionID, runID: BurnBarRunID? = nil) {
        self.clientID = clientID
        self.sessionID = sessionID
        self.runID = runID
    }
}

public enum BurnBarToolExecutionDisposition: String, Codable, CaseIterable, Hashable, Sendable {
    case dispatched
    case noPendingToolCall = "no_pending_tool_call"
    case runNotFound = "run_not_found"
}

public struct BurnBarToolExecutionResponse: Codable, Hashable, Sendable {
    public let disposition: BurnBarToolExecutionDisposition
    public let toolCall: BurnBarToolCallSnapshot?

    public init(disposition: BurnBarToolExecutionDisposition, toolCall: BurnBarToolCallSnapshot? = nil) {
        self.disposition = disposition
        self.toolCall = toolCall
    }
}

public struct BurnBarToolResultSubmissionRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID
    public let runID: BurnBarRunID
    public let callID: String
    public let succeeded: Bool
    public let output: BurnBarJSONValue?
    public let error: BurnBarToolExecutionError?
    public let completedAt: Date

    public init(
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        runID: BurnBarRunID,
        callID: String,
        succeeded: Bool,
        output: BurnBarJSONValue?,
        error: BurnBarToolExecutionError?,
        completedAt: Date
    ) {
        self.clientID = clientID
        self.sessionID = sessionID
        self.runID = runID
        self.callID = callID
        self.succeeded = succeeded
        self.output = output
        self.error = error
        self.completedAt = completedAt
    }
}

public struct BurnBarApprovalRespondRequest: Codable, Hashable, Sendable {
    public let response: BurnBarApprovalResponse

    public init(response: BurnBarApprovalResponse) {
        self.response = response
    }
}
