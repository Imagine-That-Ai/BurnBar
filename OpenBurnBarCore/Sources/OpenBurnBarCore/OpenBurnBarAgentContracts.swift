import Foundation

public enum BurnBarAgentIntentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case replaceStringInFile = "replace_string_in_file"
    case runTerminal = "run_terminal"
    case inspectWorkspace = "inspect_workspace"
    case generic
}

/// Risk classification for agent tools and intents.
public enum BurnBarToolRisk: String, Codable, CaseIterable, Hashable, Sendable {
    case low
    case medium
    case high
}

public struct BurnBarTextReplacement: Codable, Hashable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct BurnBarTerminalCommandIntent: Codable, Hashable, Sendable {
    public let command: String
    public let cwd: String?
    public let name: String?
    public let preserveFocus: Bool?

    public init(command: String, cwd: String? = nil, name: String? = nil, preserveFocus: Bool? = nil) {
        self.command = command
        self.cwd = cwd
        self.name = name
        self.preserveFocus = preserveFocus
    }
}

public struct BurnBarAgentIntent: Codable, Hashable, Sendable {
    public let kind: BurnBarAgentIntentKind
    public let objective: String
    public let summary: String
    public let targetPath: String?
    public let searchQuery: String?
    public let replacement: BurnBarTextReplacement?
    public let terminalCommand: BurnBarTerminalCommandIntent?
    public let requestedTools: [BurnBarToolKind]?
    public let toolArguments: BurnBarJSONValue?

    public init(
        kind: BurnBarAgentIntentKind,
        objective: String,
        summary: String,
        targetPath: String? = nil,
        searchQuery: String? = nil,
        replacement: BurnBarTextReplacement? = nil,
        terminalCommand: BurnBarTerminalCommandIntent? = nil,
        requestedTools: [BurnBarToolKind]? = nil,
        toolArguments: BurnBarJSONValue? = nil
    ) {
        self.kind = kind
        self.objective = objective
        self.summary = summary
        self.targetPath = targetPath
        self.searchQuery = searchQuery
        self.replacement = replacement
        self.terminalCommand = terminalCommand
        self.requestedTools = requestedTools
        self.toolArguments = toolArguments
    }

    public var requestedToolsOrEmpty: [BurnBarToolKind] {
        requestedTools ?? []
    }
}

/// Typed planner input contract with required constraints, risk level, and desired outputs.
/// This is the canonical input to the BurnBarPlannerService.plan() method.
public struct BurnBarPlannerInput: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let missionID: BurnBarMissionID
    public let normalizedIntent: BurnBarAgentIntent
    /// Explicit constraints that the plan must respect (e.g., file paths to avoid, tools not to use).
    public let constraints: [String]
    /// Risk classification derived from intent and tool set.
    public let riskLevel: BurnBarToolRisk
    /// Explicit desired outputs the plan should produce.
    public let desiredOutputs: [String]
    /// Optional workflow hints derived from workspace workflow metadata.
    public let workflowHints: [String: BurnBarJSONValue]?
    /// Optional tool hints derived from explicit tool metadata.
    public let toolHints: [String: BurnBarJSONValue]?
    /// Optional policy overrides.
    public let policyOverrides: [String: BurnBarJSONValue]?

    public init(
        schemaVersion: Int = 1,
        missionID: BurnBarMissionID,
        normalizedIntent: BurnBarAgentIntent,
        constraints: [String],
        riskLevel: BurnBarToolRisk,
        desiredOutputs: [String],
        workflowHints: [String: BurnBarJSONValue]? = nil,
        toolHints: [String: BurnBarJSONValue]? = nil,
        policyOverrides: [String: BurnBarJSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.missionID = missionID
        self.normalizedIntent = normalizedIntent
        self.constraints = constraints
        self.riskLevel = riskLevel
        self.desiredOutputs = desiredOutputs
        self.workflowHints = workflowHints
        self.toolHints = toolHints
        self.policyOverrides = policyOverrides
    }
}

/// Error thrown when planner input validation fails.
public enum BurnBarPlannerInputError: Error, LocalizedError {
    case missingRequiredField(String)
    case unsupportedSchemaVersion(Int)
    case invalidIntent(String)

    public var errorDescription: String? {
        switch self {
        case .missingRequiredField(let field):
            return "Planner input is missing required field: '\(field)'."
        case .unsupportedSchemaVersion(let version):
            return "Planner input has unsupported schema version \(version)."
        case .invalidIntent(let message):
            return "Planner input has invalid intent: \(message)"
        }
    }
}

public enum BurnBarPlanStepStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

public struct BurnBarPlanStep: Codable, Hashable, Sendable {
    public let title: String
    public let detail: String
    public let status: BurnBarPlanStepStatus

    public init(
        title: String,
        detail: String,
        status: BurnBarPlanStepStatus = .pending
    ) {
        self.title = title
        self.detail = detail
        self.status = status
    }
}

public struct BurnBarPlanOutline: Codable, Hashable, Sendable {
    public let objective: String
    public let steps: [BurnBarPlanStep]

    public init(objective: String, steps: [BurnBarPlanStep]) {
        self.objective = objective
        self.steps = steps
    }
}

public enum BurnBarRecoveryAction: String, Codable, CaseIterable, Hashable, Sendable {
    case requestApproval = "request_approval"
    case retryTool = "retry_tool"
    case failRun = "fail_run"
}

public struct BurnBarRecoveryDecision: Codable, Hashable, Sendable {
    public let action: BurnBarRecoveryAction
    public let reason: String
    public let userMessage: String

    public init(action: BurnBarRecoveryAction, reason: String, userMessage: String) {
        self.action = action
        self.reason = reason
        self.userMessage = userMessage
    }
}

public enum BurnBarAgentLoopActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case complete
    case searchWorkspace = "search_workspace"
    case readFile = "read_file"
    case applyPatch = "apply_patch"
    case runTerminal = "run_terminal"
    case requestApproval = "request_approval"
    case fail
}

public struct BurnBarAgentContextSnapshot: Codable, Hashable, Sendable {
    public let candidatePaths: [String]
    public let activeFilePath: String?
    public let lastReadFilePath: String?
    public let lastReadContent: String?
    public let searchHints: [String]
    public let replacementTargetPath: String?
    public let searchResultPaths: [String]

    public init(
        candidatePaths: [String],
        activeFilePath: String? = nil,
        lastReadFilePath: String? = nil,
        lastReadContent: String? = nil,
        searchHints: [String],
        replacementTargetPath: String? = nil,
        searchResultPaths: [String] = []
    ) {
        self.candidatePaths = candidatePaths
        self.activeFilePath = activeFilePath
        self.lastReadFilePath = lastReadFilePath
        self.lastReadContent = lastReadContent
        self.searchHints = searchHints
        self.replacementTargetPath = replacementTargetPath
        self.searchResultPaths = searchResultPaths
    }
}

public struct BurnBarAgentLoopDecision: Codable, Hashable, Sendable {
    public let action: BurnBarAgentLoopActionKind
    public let requestedTool: BurnBarToolKind?
    public let arguments: BurnBarJSONValue?
    public let rationale: String
    public let message: String?

    public init(
        action: BurnBarAgentLoopActionKind,
        requestedTool: BurnBarToolKind? = nil,
        arguments: BurnBarJSONValue? = nil,
        rationale: String,
        message: String? = nil
    ) {
        self.action = action
        self.requestedTool = requestedTool
        self.arguments = arguments
        self.rationale = rationale
        self.message = message
    }
}

public struct BurnBarAgentLoopState: Codable, Hashable, Sendable {
    public let iterationCount: Int
    public let lastDecision: BurnBarAgentLoopDecision?
    public let lastContextSnapshot: BurnBarAgentContextSnapshot?
    public let lastExecutedTool: BurnBarToolKind?
    public let terminalPending: Bool

    public init(
        iterationCount: Int = 0,
        lastDecision: BurnBarAgentLoopDecision? = nil,
        lastContextSnapshot: BurnBarAgentContextSnapshot? = nil,
        lastExecutedTool: BurnBarToolKind? = nil,
        terminalPending: Bool = false
    ) {
        self.iterationCount = iterationCount
        self.lastDecision = lastDecision
        self.lastContextSnapshot = lastContextSnapshot
        self.lastExecutedTool = lastExecutedTool
        self.terminalPending = terminalPending
    }
}

public enum BurnBarRunJournalEventKind: String, Codable, CaseIterable, Hashable, Sendable {
    case runCreated = "run_created"
    case planGenerated = "plan_generated"
    case loopDecided = "loop_decided"
    case stateTransitioned = "state_transitioned"
    case approvalRequested = "approval_requested"
    case approvalResponded = "approval_responded"
    case toolDispatched = "tool_dispatched"
    case toolCompleted = "tool_completed"
    case recoveryDecided = "recovery_decided"
    case runCompleted = "run_completed"
    case runFailed = "run_failed"
    case runCancelled = "run_cancelled"
}

public struct BurnBarRunJournalEvent: Codable, Hashable, Sendable {
    public let eventID: String
    public let runID: BurnBarRunID
    public let kind: BurnBarRunJournalEventKind
    public let phase: BurnBarRunPhase?
    public let payload: BurnBarJSONValue?
    public let emittedAt: Date

    public init(
        eventID: String = UUID().uuidString,
        runID: BurnBarRunID,
        kind: BurnBarRunJournalEventKind,
        phase: BurnBarRunPhase? = nil,
        payload: BurnBarJSONValue? = nil,
        emittedAt: Date
    ) {
        self.eventID = eventID
        self.runID = runID
        self.kind = kind
        self.phase = phase
        self.payload = payload
        self.emittedAt = emittedAt
    }
}

public struct BurnBarRunJournalCheckpoint: Codable, Hashable, Sendable {
    public let runID: BurnBarRunID
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID
    public let phase: BurnBarRunPhase
    public let modelID: String
    public let originalPrompt: String
    public let metadata: [String: BurnBarJSONValue]
    public let intent: BurnBarAgentIntent
    public let planOutline: BurnBarPlanOutline
    public let attempt: Int
    public let errorMessage: String?
    public let approvalRequest: BurnBarApprovalRequest?
    public let approvalResolvedForAttempt: Bool
    public let activeApprovalID: BurnBarApprovalID?
    public let pendingApprovalToolInvocation: BurnBarToolInvocation?
    public let lastToolCall: BurnBarToolCallSnapshot?
    public let lastToolCallID: String?
    public let workflowStep: Int
    public let workflowReadContent: String?
    public let companionToolCompleted: Bool
    public let lastRecoveryDecision: BurnBarRecoveryDecision?
    public let loopState: BurnBarAgentLoopState
    public let updatedAt: Date

    public init(
        runID: BurnBarRunID,
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        phase: BurnBarRunPhase,
        modelID: String,
        originalPrompt: String,
        metadata: [String: BurnBarJSONValue] = [:],
        intent: BurnBarAgentIntent,
        planOutline: BurnBarPlanOutline,
        attempt: Int = 1,
        errorMessage: String? = nil,
        approvalRequest: BurnBarApprovalRequest? = nil,
        approvalResolvedForAttempt: Bool = false,
        activeApprovalID: BurnBarApprovalID? = nil,
        pendingApprovalToolInvocation: BurnBarToolInvocation? = nil,
        lastToolCall: BurnBarToolCallSnapshot? = nil,
        lastToolCallID: String? = nil,
        workflowStep: Int = 0,
        workflowReadContent: String? = nil,
        companionToolCompleted: Bool = false,
        lastRecoveryDecision: BurnBarRecoveryDecision? = nil,
        loopState: BurnBarAgentLoopState = BurnBarAgentLoopState(),
        updatedAt: Date
    ) {
        self.runID = runID
        self.clientID = clientID
        self.sessionID = sessionID
        self.phase = phase
        self.modelID = modelID
        self.originalPrompt = originalPrompt
        self.metadata = metadata
        self.intent = intent
        self.planOutline = planOutline
        self.attempt = attempt
        self.errorMessage = errorMessage
        self.approvalRequest = approvalRequest
        self.approvalResolvedForAttempt = approvalResolvedForAttempt
        self.activeApprovalID = activeApprovalID
        self.pendingApprovalToolInvocation = pendingApprovalToolInvocation
        self.lastToolCall = lastToolCall
        self.lastToolCallID = lastToolCallID
        self.workflowStep = workflowStep
        self.workflowReadContent = workflowReadContent
        self.companionToolCompleted = companionToolCompleted
        self.lastRecoveryDecision = lastRecoveryDecision
        self.loopState = loopState
        self.updatedAt = updatedAt
    }
}

public extension BurnBarJSONValue {
    static func fromEncodable<Value: Encodable>(_ value: Value) throws -> BurnBarJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(BurnBarJSONValue.self, from: data)
    }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

public extension BurnBarAgentIntent {
    var requiresWorkspaceToolExecution: Bool {
        !(requestedTools ?? []).isEmpty
    }
}
