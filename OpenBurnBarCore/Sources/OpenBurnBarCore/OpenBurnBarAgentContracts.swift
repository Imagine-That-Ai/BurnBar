import Foundation
import CryptoKit

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
    public let metadata: BurnBarRunCreateMetadata
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
        metadata: BurnBarRunCreateMetadata = BurnBarRunCreateMetadata(),
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

// MARK: - DAG Domain Model

/// Schema version for DAG contracts.
/// Versions supported: 1 (current).
public enum BurnBarDAGSchemaVersion: Int, Codable, CaseIterable, Hashable, Sendable {
    case v1 = 1

    public static let current = v1
    public static let supported: [BurnBarDAGSchemaVersion] = [.v1]

    public static func isSupported(_ version: BurnBarDAGSchemaVersion) -> Bool {
        supported.contains(version)
    }
}

/// Errors related to DAG contract validation.
public enum BurnBarDAGError: Error, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case missingRequiredNode(String)
    case circularDependencyDetected(nodeID: String)
    case invalidEdge(sourceID: String, targetID: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "DAG contract has unsupported schema version \(version). Supported versions: \(BurnBarDAGSchemaVersion.supported.map { $0.rawValue })."
        case .missingRequiredNode(let nodeID):
            return "DAG contract references missing node: '\(nodeID)'."
        case .circularDependencyDetected(let nodeID):
            return "DAG contract contains circular dependency involving node: '\(nodeID)'."
        case .invalidEdge(let sourceID, let targetID):
            return "DAG contract contains invalid edge from '\(sourceID)' to '\(targetID)'."
        }
    }
}

/// Identifier for a DAG node.
public struct BurnBarDAGNodeID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a deterministic node ID from mission ID, step index, and content hash.
    /// This ensures the same intent input produces identical node IDs.
    public static func deterministic(
        missionID: BurnBarMissionID,
        stepIndex: Int,
        contentHash: String
    ) -> BurnBarDAGNodeID {
        let input = "\(missionID.rawValue)|\(stepIndex)|\(contentHash)"
        return BurnBarDAGNodeID(rawValue: deterministicIDHash(input))
    }

    /// Generates a stable hash from input string using SHA256.
    /// This is deterministic across process launches unlike Swift's Hasher which is process-seeded.
    private static func deterministicIDHash(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
public struct BurnBarDAGEdgeID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a deterministic edge ID from source and target node IDs.
    /// This ensures the same edge produces identical IDs across serializations.
    public static func deterministic(
        sourceNodeID: BurnBarDAGNodeID,
        targetNodeID: BurnBarDAGNodeID
    ) -> BurnBarDAGEdgeID {
        let input = "edge|\(sourceNodeID.rawValue)|\(targetNodeID.rawValue)"
        return BurnBarDAGEdgeID(rawValue: deterministicEdgeHash(input))
    }

    /// Generates a stable hash from edge input using SHA256.
    /// This is deterministic across process launches unlike Swift's Hasher which is process-seeded.
    private static func deterministicEdgeHash(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

/// Execution status of a DAG node.
public enum BurnBarDAGNodeStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case ready
    case running
    case completed
    case failed
    case skipped
}

/// A node in the typed DAG representing a discrete step or task.
public struct BurnBarDAGNode: Codable, Hashable, Identifiable, Sendable {
    public let id: BurnBarDAGNodeID
    public let title: String
    public let detail: String
    public let status: BurnBarDAGNodeStatus
    public let dependsOn: [BurnBarDAGNodeID]
    public let metadata: [String: BurnBarJSONValue]?

    public init(
        id: BurnBarDAGNodeID,
        title: String,
        detail: String,
        status: BurnBarDAGNodeStatus = .pending,
        dependsOn: [BurnBarDAGNodeID] = [],
        metadata: [String: BurnBarJSONValue]? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.dependsOn = dependsOn
        self.metadata = metadata
    }

    /// Creates a deterministic node ID based on mission context and step properties.
    public static func makeDeterministicID(
        missionID: BurnBarMissionID,
        stepIndex: Int,
        title: String,
        detail: String
    ) -> BurnBarDAGNodeID {
        let contentHash = "\(title)|\(detail)"
        return BurnBarDAGNodeID.deterministic(
            missionID: missionID,
            stepIndex: stepIndex,
            contentHash: contentHash
        )
    }
}

/// An edge in the DAG representing a dependency relationship between two nodes.
public struct BurnBarDAGEdge: Codable, Hashable, Identifiable, Sendable {
    public let id: BurnBarDAGEdgeID
    public let sourceNodeID: BurnBarDAGNodeID
    public let targetNodeID: BurnBarDAGNodeID

    public init(
        id: BurnBarDAGEdgeID? = nil,
        sourceNodeID: BurnBarDAGNodeID,
        targetNodeID: BurnBarDAGNodeID
    ) {
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        // Use provided ID or generate deterministic one
        self.id = id ?? BurnBarDAGEdgeID.deterministic(
            sourceNodeID: sourceNodeID,
            targetNodeID: targetNodeID
        )
    }
}

/// A typed DAG contract produced by the planner.
/// Contains versioned serialization with backward compatibility support.
public struct BurnBarDAGContract: Codable, Hashable, Sendable {
    public let schemaVersion: BurnBarDAGSchemaVersion
    public let missionID: BurnBarMissionID
    public let nodes: [BurnBarDAGNode]
    public let edges: [BurnBarDAGEdge]
    public let metadata: [String: BurnBarJSONValue]?

    public init(
        schemaVersion: BurnBarDAGSchemaVersion = .v1,
        missionID: BurnBarMissionID,
        nodes: [BurnBarDAGNode],
        edges: [BurnBarDAGEdge] = [],
        metadata: [String: BurnBarJSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.missionID = missionID
        self.nodes = nodes
        self.edges = edges
        self.metadata = metadata
    }

    /// Custom decoder that handles unknown schema versions explicitly.
    /// Swift's default Codable throws DecodingError for unknown enum raw values,
    /// but we want to surface explicit BurnBarDAGError.unsupportedSchemaVersion.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // First, decode schema version as raw Int to check support before creating enum
        let schemaVersionRaw = try container.decode(Int.self, forKey: .schemaVersion)

        // Check if schema version is supported
        guard let schemaVersion = BurnBarDAGSchemaVersion(rawValue: schemaVersionRaw),
              BurnBarDAGSchemaVersion.isSupported(schemaVersion) else {
            throw BurnBarDAGError.unsupportedSchemaVersion(schemaVersionRaw)
        }

        self.schemaVersion = schemaVersion
        self.missionID = try container.decode(BurnBarMissionID.self, forKey: .missionID)
        self.nodes = try container.decode([BurnBarDAGNode].self, forKey: .nodes)
        self.edges = try container.decodeIfPresent([BurnBarDAGEdge].self, forKey: .edges) ?? []
        self.metadata = try container.decodeIfPresent([String: BurnBarJSONValue].self, forKey: .metadata)
    }

    /// Coding keys for BurnBarDAGContract.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case missionID
        case nodes
        case edges
        case metadata
    }

    /// Validates the DAG contract for consistency.
    /// Throws BurnBarDAGError if validation fails.
    public func validate() throws {
        // Check schema version is supported
        guard BurnBarDAGSchemaVersion.isSupported(schemaVersion) else {
            throw BurnBarDAGError.unsupportedSchemaVersion(schemaVersion.rawValue)
        }

        // Build set of valid node IDs
        let nodeIDs = Set(nodes.map { $0.id })

        // Validate all node IDs in dependsOn exist
        for node in nodes {
            for depID in node.dependsOn {
                guard nodeIDs.contains(depID) else {
                    throw BurnBarDAGError.missingRequiredNode(depID.rawValue)
                }
            }
        }

        // Validate all edge endpoints exist
        for edge in edges {
            guard nodeIDs.contains(edge.sourceNodeID) else {
                throw BurnBarDAGError.invalidEdge(
                    sourceID: edge.sourceNodeID.rawValue,
                    targetID: edge.targetNodeID.rawValue
                )
            }
            guard nodeIDs.contains(edge.targetNodeID) else {
                throw BurnBarDAGError.invalidEdge(
                    sourceID: edge.sourceNodeID.rawValue,
                    targetID: edge.targetNodeID.rawValue
                )
            }
        }

        // Check for circular dependencies using DFS
        try detectCircularDependencies()
    }

    /// Detects circular dependencies in the DAG using depth-first search.
    private func detectCircularDependencies() throws {
        var visited: Set<BurnBarDAGNodeID> = []
        var recursionStack: Set<BurnBarDAGNodeID> = []

        func dfs(_ nodeID: BurnBarDAGNodeID) throws {
            visited.insert(nodeID)
            recursionStack.insert(nodeID)

            // Find all nodes this node depends on
            guard let node = nodes.first(where: { $0.id == nodeID }) else { return }
            for depID in node.dependsOn {
                if !visited.contains(depID) {
                    try dfs(depID)
                } else if recursionStack.contains(depID) {
                    throw BurnBarDAGError.circularDependencyDetected(nodeID: nodeID.rawValue)
                }
            }

            recursionStack.remove(nodeID)
        }

        for node in nodes {
            if !visited.contains(node.id) {
                try dfs(node.id)
            }
        }
    }

    /// Returns the topological order of nodes if the DAG is valid.
    /// Returns nil if the DAG has cycles.
    public func topologicalSort() -> [BurnBarDAGNode]? {
        var inDegree: [BurnBarDAGNodeID: Int] = [:]
        var adjacency: [BurnBarDAGNodeID: [BurnBarDAGNodeID]] = [:]

        // Initialize
        for node in nodes {
            inDegree[node.id] = node.dependsOn.count
            adjacency[node.id] = []
        }

        // Build adjacency list (reverse of dependsOn)
        for node in nodes {
            for depID in node.dependsOn {
                adjacency[depID, default: []].append(node.id)
            }
        }

        // Kahn's algorithm
        var queue: [BurnBarDAGNodeID] = []
        for (nodeID, degree) in inDegree where degree == 0 {
            queue.append(nodeID)
        }

        var result: [BurnBarDAGNode] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if let node = nodes.first(where: { $0.id == current }) {
                result.append(node)
            }

            for neighbor in adjacency[current] ?? [] {
                inDegree[neighbor]! -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        // If not all nodes are in result, there's a cycle
        return result.count == nodes.count ? result : nil
    }
}

/// Encoder/decoder for versioned DAG contracts with explicit schema version tracking.
public enum BurnBarDAGContractCodec {
    /// Current schema version for encoding.
    public static let currentSchemaVersion = BurnBarDAGSchemaVersion.v1

    /// Encodes a DAG contract to JSON data.
    public static func encode(_ contract: BurnBarDAGContract) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(contract)
    }

    /// Decodes a DAG contract from JSON data.
    /// Throws BurnBarDAGError for unsupported schema versions.
    public static func decode(from data: Data) throws -> BurnBarDAGContract {
        let decoder = JSONDecoder()
        // Custom init(from:) in BurnBarDAGContract handles unsupported schema versions explicitly
        let contract = try decoder.decode(BurnBarDAGContract.self, from: data)

        // Validate DAG structure (schema version already validated in init)
        try contract.validate()

        return contract
    }

    /// Decodes a DAG contract from JSON string.
    public static func decode(from jsonString: String) throws -> BurnBarDAGContract {
        guard let data = jsonString.data(using: .utf8) else {
            throw BurnBarDAGError.unsupportedSchemaVersion(0)
        }
        return try decode(from: data)
    }
}

// MARK: - Critical Path Tracking

/// Tracks the execution timing and critical path for a DAG node.
public struct BurnBarDAGNodeTiming: Codable, Hashable, Sendable {
    public let nodeID: BurnBarDAGNodeID
    public let scheduledAt: Date?
    public let startedAt: Date?
    public let completedAt: Date?
    public let estimatedDuration: TimeInterval?
    public let actualDuration: TimeInterval?

    public init(
        nodeID: BurnBarDAGNodeID,
        scheduledAt: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        estimatedDuration: TimeInterval? = nil,
        actualDuration: TimeInterval? = nil
    ) {
        self.nodeID = nodeID
        self.scheduledAt = scheduledAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.estimatedDuration = estimatedDuration
        self.actualDuration = actualDuration
    }

    /// Whether this node has started execution.
    public var hasStarted: Bool { startedAt != nil }

    /// Whether this node has completed execution.
    public var hasCompleted: Bool { completedAt != nil }

    /// Whether this node is currently running.
    public var isRunning: Bool { startedAt != nil && completedAt == nil }

    /// The actual duration if completed.
    public var durationIfCompleted: TimeInterval? {
        guard let started = startedAt, let completed = completedAt else { return nil }
        return completed.timeIntervalSince(started)
    }
}

/// Represents the critical path through a DAG - the longest sequence of dependent nodes
/// that determines the minimum execution time.
public struct BurnBarCriticalPathArtifact: Codable, Hashable, Sendable {
    public let missionID: BurnBarMissionID
    public let dagSchemaVersion: BurnBarDAGSchemaVersion
    /// Ordered list of node IDs forming the critical path (from start to end).
    public let criticalPathNodes: [BurnBarDAGNodeID]
    /// Total estimated duration of the critical path.
    public let estimatedTotalDuration: TimeInterval
    /// Current critical path nodes with updated timing (may differ from criticalPathNodes
    /// as execution progresses and estimates are refined).
    public let currentCriticalPathNodes: [BurnBarDAGNodeID]
    /// Estimated remaining duration along the critical path.
    public let estimatedRemainingDuration: TimeInterval
    /// Node timings keyed by node ID.
    public let nodeTimings: [String: BurnBarDAGNodeTiming]
    /// When this artifact was last updated.
    public let updatedAt: Date
    /// Whether the DAG execution is complete.
    public let isComplete: Bool

    public init(
        missionID: BurnBarMissionID,
        dagSchemaVersion: BurnBarDAGSchemaVersion = .v1,
        criticalPathNodes: [BurnBarDAGNodeID] = [],
        estimatedTotalDuration: TimeInterval = 0,
        currentCriticalPathNodes: [BurnBarDAGNodeID] = [],
        estimatedRemainingDuration: TimeInterval = 0,
        nodeTimings: [String: BurnBarDAGNodeTiming] = [:],
        updatedAt: Date = Date(),
        isComplete: Bool = false
    ) {
        self.missionID = missionID
        self.dagSchemaVersion = dagSchemaVersion
        self.criticalPathNodes = criticalPathNodes
        self.estimatedTotalDuration = estimatedTotalDuration
        self.currentCriticalPathNodes = currentCriticalPathNodes
        self.estimatedRemainingDuration = estimatedRemainingDuration
        self.nodeTimings = nodeTimings
        self.updatedAt = updatedAt
        self.isComplete = isComplete
    }

    /// Returns timing for a specific node if available.
    public func timing(for nodeID: BurnBarDAGNodeID) -> BurnBarDAGNodeTiming? {
        nodeTimings[nodeID.rawValue]
    }

    /// Returns whether a specific node is on the critical path.
    public func isOnCriticalPath(_ nodeID: BurnBarDAGNodeID) -> Bool {
        currentCriticalPathNodes.contains(nodeID)
    }

    /// Returns the total completed duration for all nodes that have completed.
    public var completedCriticalPathDuration: TimeInterval {
        nodeTimings.values
            .compactMap { $0.durationIfCompleted }
            .reduce(0, +)
    }
}

// MARK: - VAL-EXEC-010: Reconciler Winner Selection

/// Reason codes for winner selection during DAG reconciliation.
/// These codes provide deterministic, replay-stable winner selection.
public enum BurnBarReconcilerWinnerReasonCode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Winner selected because it was the only policy-valid, dependency-complete candidate.
    case onlyCandidate = "ONLY_CANDIDATE"
    /// Winner selected because it succeeded when others failed.
    case successOverFailure = "SUCCESS_OVER_FAILURE"
    /// Winner selected because it had higher evidence completeness.
    case higherEvidenceCompleteness = "HIGHER_EVIDENCE_COMPLETENESS"
    /// Winner selected because it had lower risk residual.
    case lowerRiskResidual = "LOWER_RISK_RESIDUAL"
    /// Winner selected because it had lower cost/latency penalty.
    case lowerCostLatencyPenalty = "LOWER_COST_LATENCY_PENALTY"
    /// Winner selected because it had the earliest terminal sequence number.
    case earliestSequenceNumber = "EARLIEST_SEQUENCE_NUMBER"
    /// Winner selected as final tie-break by lexical candidate ID.
    case lexicalTieBreak = "LEXICAL_TIE_BREAK"
    /// No reconciliation needed (single winner or no conflict).
    case noReconciliationNeeded = "NO_RECONCILIATION_NEEDED"

    public var label: String {
        switch self {
        case .onlyCandidate: return "Only valid candidate"
        case .successOverFailure: return "Succeeded over failed"
        case .higherEvidenceCompleteness: return "Higher evidence completeness"
        case .lowerRiskResidual: return "Lower risk residual"
        case .lowerCostLatencyPenalty: return "Lower cost/latency"
        case .earliestSequenceNumber: return "Earliest sequence number"
        case .lexicalTieBreak: return "Lexical tie-break"
        case .noReconciliationNeeded: return "No reconciliation needed"
        }
    }
}

/// Tracks a reconciliation event when multiple parallel DAG paths produce conflicting outcomes.
public struct BurnBarDAGReconciliationArtifact: Codable, Hashable, Sendable {
    /// Unique identifier for this reconciliation event.
    public let id: String
    /// Mission this reconciliation belongs to.
    public let missionID: BurnBarMissionID
    /// The winning node ID.
    public let winnerNodeID: BurnBarDAGNodeID
    /// All candidate node IDs that were considered.
    public let candidateNodeIDs: [BurnBarDAGNodeID]
    /// The reason code for why this winner was selected.
    public let winnerReasonCode: BurnBarReconcilerWinnerReasonCode
    /// Human-readable rationale for the winner selection.
    public let winnerRationale: String
    /// Priority score used for selection (higher = better).
    public let winnerScore: Double
    /// Scores for each candidate (for audit/debugging).
    public let candidateScores: [String: Double]
    /// When the reconciliation occurred.
    public let reconciledAt: Date
    /// Schema version for forward compatibility.
    public let schemaVersion: Int

    public init(
        id: String = UUID().uuidString,
        missionID: BurnBarMissionID,
        winnerNodeID: BurnBarDAGNodeID,
        candidateNodeIDs: [BurnBarDAGNodeID],
        winnerReasonCode: BurnBarReconcilerWinnerReasonCode,
        winnerRationale: String,
        winnerScore: Double,
        candidateScores: [String: Double],
        reconciledAt: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.missionID = missionID
        self.winnerNodeID = winnerNodeID
        self.candidateNodeIDs = candidateNodeIDs
        self.winnerReasonCode = winnerReasonCode
        self.winnerRationale = winnerRationale
        self.winnerScore = winnerScore
        self.candidateScores = candidateScores
        self.reconciledAt = reconciledAt
        self.schemaVersion = schemaVersion
    }
}

/// Tracks the execution state of a DAG scheduler for a mission.
public enum BurnBarSchedulerPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case idle
    case running
    case paused
    case completed
    case failed
}

/// The full scheduler state for a mission's DAG execution.
public struct BurnBarDAGSchedulerState: Codable, Hashable, Sendable {
    public let missionID: BurnBarMissionID
    public var phase: BurnBarSchedulerPhase
    /// Node statuses keyed by node ID.
    public var nodeStatuses: [String: BurnBarDAGNodeStatus]
    /// Currently executing node IDs.
    public var runningNodes: [BurnBarDAGNodeID]
    /// Nodes that are ready to execute (dependencies satisfied, not yet running).
    public var readyNodes: [BurnBarDAGNodeID]
    /// Nodes that have completed execution.
    public var completedNodes: [BurnBarDAGNodeID]
    /// Nodes that have failed.
    public var failedNodes: [BurnBarDAGNodeID]
    /// Critical path tracking artifact.
    public var criticalPath: BurnBarCriticalPathArtifact?
    /// VAL-EXEC-010: Reconciliation artifact when multiple parallel outcomes need winner selection.
    public var reconciliationArtifact: BurnBarDAGReconciliationArtifact?
    /// Concurrency limit for parallel execution.
    public let maxConcurrency: Int
    /// When the scheduler state was last updated.
    public var updatedAt: Date
    /// Error message if the scheduler is in failed state.
    public var errorMessage: String?

    public init(
        missionID: BurnBarMissionID,
        phase: BurnBarSchedulerPhase = .idle,
        nodeStatuses: [String: BurnBarDAGNodeStatus] = [:],
        runningNodes: [BurnBarDAGNodeID] = [],
        readyNodes: [BurnBarDAGNodeID] = [],
        completedNodes: [BurnBarDAGNodeID] = [],
        failedNodes: [BurnBarDAGNodeID] = [],
        criticalPath: BurnBarCriticalPathArtifact? = nil,
        reconciliationArtifact: BurnBarDAGReconciliationArtifact? = nil,
        maxConcurrency: Int = 4,
        updatedAt: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.missionID = missionID
        self.phase = phase
        self.nodeStatuses = nodeStatuses
        self.runningNodes = runningNodes
        self.readyNodes = readyNodes
        self.completedNodes = completedNodes
        self.failedNodes = failedNodes
        self.criticalPath = criticalPath
        self.reconciliationArtifact = reconciliationArtifact
        self.maxConcurrency = maxConcurrency
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
    }

    /// Whether the scheduler can accept new node starts.
    public var canStartMoreNodes: Bool {
        runningNodes.count < maxConcurrency && phase == .running
    }

    /// Whether all nodes are in terminal states.
    public var isTerminal: Bool {
        phase == .completed || phase == .failed
    }

    /// Returns the status of a specific node.
    public func status(for nodeID: BurnBarDAGNodeID) -> BurnBarDAGNodeStatus? {
        nodeStatuses[nodeID.rawValue]
    }
}
