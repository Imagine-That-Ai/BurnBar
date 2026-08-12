import Foundation

public enum BurnBarProtocolVersion {
    public static let current = 1
    public static let supported = [1]

    public static func negotiate(with clientSupportedVersions: [Int]) -> Int? {
        supported.first(where: clientSupportedVersions.contains)
    }
}

public enum BurnBarRPCMethod: String, Codable, Hashable, Sendable {
    case health = "daemon.health"
    case catalog = "daemon.catalog"
    case configGet = "daemon.config.get"
    case configUpdate = "daemon.config.update"
    case usageRecent = "daemon.usage.recent"
    case runCreate = "run.create"
    case runList = "run.list"
    case runGet = "run.get"
    case runPoll = "run.poll"
    case runCancel = "run.cancel"
    case runRetry = "run.retry"
    case workspaceExecuteTool = "workspace.executeTool"
    case workspaceToolResult = "workspace.toolResult"
    case approvalRespond = "approval.respond"
    case clientAttach = "client.attach"
    case clientClaimControl = "client.claimControl"
    case clientDetach = "client.detach"
    /// Planner-backed lexical + aggregate search over the local BurnBar SQLite index (daemon must have DB path).
    case searchQuery = "daemon.search.query"
    case fleetSnapshot = "daemon.fleet.snapshot"
    case fleetOrchestratorGet = "daemon.fleet.orchestrator.get"
    case fleetOrchestratorSet = "daemon.fleet.orchestrator.set"
    case fleetDirectiveRecord = "daemon.fleet.directive.record"
}

// MARK: - Indexed search (daemon + extension)

/// Parameters for `BurnBarRPCMethod.searchQuery`.
public struct BurnBarSearchQueryRequest: Codable, Sendable, Hashable {
    public let query: String
    public let providerRaw: String?
    public let projectName: String?
    /// Optional inclusive date range as seconds since 1970 (matches JSON number encoding).
    public let dateRangeStartEpoch: Double?
    public let dateRangeEndEpoch: Double?
    public let resultLimit: Int

    // MARK: - Semantic Search Fields (Optional)

    /// Pre-computed query embedding vector. When provided, enables semantic search
    /// in the daemon without requiring API keys. This is the recommended approach
    /// for extension clients that cannot store API keys.
    public let queryEmbedding: [Float]?

    /// The embedding version ID used to generate the query embedding.
    /// Used to filter `chunk_embeddings` to the matching version.
    public let embeddingVersionID: String?

    /// The embedding dimension count. Used to validate that the query embedding
    /// matches the indexed embedding dimensions.
    public let embeddingDimension: Int?

    /// The distance metric used by the query embedding.
    public let embeddingDistanceMetric: BurnBarEmbeddingDistanceMetric?

    /// Whether to skip semantic search even if embeddings are available.
    /// Useful for testing or when only lexical results are desired.
    public let skipSemanticSearch: Bool

    public init(
        query: String,
        providerRaw: String? = nil,
        projectName: String? = nil,
        dateRangeStartEpoch: Double? = nil,
        dateRangeEndEpoch: Double? = nil,
        resultLimit: Int = 50,
        queryEmbedding: [Float]? = nil,
        embeddingVersionID: String? = nil,
        embeddingDimension: Int? = nil,
        embeddingDistanceMetric: BurnBarEmbeddingDistanceMetric? = nil,
        skipSemanticSearch: Bool = false
    ) {
        self.query = query
        self.providerRaw = providerRaw
        self.projectName = projectName
        self.dateRangeStartEpoch = dateRangeStartEpoch
        self.dateRangeEndEpoch = dateRangeEndEpoch
        self.resultLimit = resultLimit
        self.queryEmbedding = queryEmbedding
        self.embeddingVersionID = embeddingVersionID
        self.embeddingDimension = embeddingDimension
        self.embeddingDistanceMetric = embeddingDistanceMetric
        self.skipSemanticSearch = skipSemanticSearch
    }
}

public struct BurnBarIndexedSearchHit: Codable, Sendable, Hashable {
    public let chunkID: String
    public let sourceKind: String
    public let sourceID: String
    public let title: String
    public let snippet: String
    public let provider: String?
    public let projectName: String?

    // MARK: - Semantic Fields

    /// Combined relevance score from hybrid fusion (0.0 to 1.0).
    /// Present when semantic search was performed.
    public let relevanceScore: Double?

    /// Source of the hit (lexical, semantic, or both via RRF).
    public let hitSource: BurnBarHitSource?

    public init(
        chunkID: String,
        sourceKind: String,
        sourceID: String,
        title: String,
        snippet: String,
        provider: String?,
        projectName: String?,
        relevanceScore: Double? = nil,
        hitSource: BurnBarHitSource? = nil
    ) {
        self.chunkID = chunkID
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.title = title
        self.snippet = snippet
        self.provider = provider
        self.projectName = projectName
        self.relevanceScore = relevanceScore
        self.hitSource = hitSource
    }
}

/// Indicates the source(s) that contributed to a search hit.
public enum BurnBarHitSource: String, Codable, Sendable {
    /// Hit found via lexical FTS search.
    case lexical = "lexical"
    /// Hit found via semantic vector search.
    case semantic = "semantic"
    /// Hit found in both lexical and semantic, combined via RRF.
    case hybrid = "hybrid"
}

public struct BurnBarSearchQueryResult: Codable, Sendable, Hashable {
    public let plan: BurnBarSearchPlan
    public let aggregateOccurrenceCount: Int?
    public let hits: [BurnBarIndexedSearchHit]
    /// Explains limitations (e.g. semantic ranking unavailable in daemon-only path).
    public let degradedMessage: String?
    /// Indicates whether semantic search was performed successfully.
    public let semanticSearchPerformed: Bool
    /// The number of hits that came from semantic search (if performed).
    public let semanticHitCount: Int?

    public init(
        plan: BurnBarSearchPlan,
        aggregateOccurrenceCount: Int?,
        hits: [BurnBarIndexedSearchHit],
        degradedMessage: String? = nil,
        semanticSearchPerformed: Bool = false,
        semanticHitCount: Int? = nil
    ) {
        self.plan = plan
        self.aggregateOccurrenceCount = aggregateOccurrenceCount
        self.hits = hits
        self.degradedMessage = degradedMessage
        self.semanticSearchPerformed = semanticSearchPerformed
        self.semanticHitCount = semanticHitCount
    }
}

public struct BurnBarRPCRequestEnvelope: Codable, Hashable, Sendable {
    public let id: String
    public let method: BurnBarRPCMethod

    public init(id: String = UUID().uuidString, method: BurnBarRPCMethod) {
        self.id = id
        self.method = method
    }
}

public struct BurnBarRPCRequestEnvelopeWithParams<Params: Codable & Sendable>: Codable, Sendable {
    public let id: String
    public let method: BurnBarRPCMethod
    public let params: Params

    public init(id: String = UUID().uuidString, method: BurnBarRPCMethod, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct BurnBarRPCError: Codable, Hashable, Sendable {
    public let code: Int
    public let message: String
    /// Machine-actionable, never-secret-bearing context for the failure
    /// (e.g. byte counts for oversized frames, the expected envelope shape
    /// for invalid requests). Always encoded (non-optional); the default is
    /// empty for callers that have no context to add.
    public let details: String

    public init(code: Int, message: String, details: String = "") {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct BurnBarRPCResponseEnvelope<Result: Codable & Sendable>: Codable, Sendable {
    public let id: String
    public let protocolVersion: Int
    public let result: Result?
    public let error: BurnBarRPCError?

    public init(
        id: String,
        protocolVersion: Int = BurnBarProtocolVersion.current,
        result: Result? = nil,
        error: BurnBarRPCError? = nil
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.result = result
        self.error = error
    }
}

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
            return "Invalid BurnBar run-state transition from \(from.rawValue) to \(to.rawValue)."
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

public enum BurnBarWorkspaceCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case local
    case remote
    case readonly
    case virtualWorkspace = "virtual_workspace"
    case untrusted
}

public enum BurnBarApprovalPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case userApproval = "user_approval"
}

public enum BurnBarToolKind: String, Codable, CaseIterable, Hashable, Sendable {
    case readFile = "read_file"
    case searchWorkspace = "search_workspace"
    case applyPatch = "apply_patch"
    case runTerminal = "run_terminal"
}

public struct BurnBarToolDefinition: Codable, Hashable, Sendable {
    public let kind: BurnBarToolKind
    public let displayName: String
    public let approvalPolicy: BurnBarApprovalPolicy
    public let requiresTrustedWorkspace: Bool
    public let requiredCapabilities: [BurnBarWorkspaceCapability]

    public init(
        kind: BurnBarToolKind,
        displayName: String,
        approvalPolicy: BurnBarApprovalPolicy,
        requiresTrustedWorkspace: Bool,
        requiredCapabilities: [BurnBarWorkspaceCapability] = []
    ) {
        self.kind = kind
        self.displayName = displayName
        self.approvalPolicy = approvalPolicy
        self.requiresTrustedWorkspace = requiresTrustedWorkspace
        self.requiredCapabilities = requiredCapabilities
    }
}

public struct BurnBarToolInvocation: Codable, Hashable, Sendable {
    public let callID: String
    public let runID: BurnBarRunID
    public let tool: BurnBarToolKind
    public let arguments: BurnBarJSONValue
    public let requestedBy: BurnBarClientID
    public let requestedAt: Date

    public init(
        callID: String,
        runID: BurnBarRunID,
        tool: BurnBarToolKind,
        arguments: BurnBarJSONValue,
        requestedBy: BurnBarClientID,
        requestedAt: Date
    ) {
        self.callID = callID
        self.runID = runID
        self.tool = tool
        self.arguments = arguments
        self.requestedBy = requestedBy
        self.requestedAt = requestedAt
    }
}

public struct BurnBarToolResult: Codable, Hashable, Sendable {
    public let callID: String
    public let runID: BurnBarRunID
    public let succeeded: Bool
    public let output: BurnBarJSONValue?
    public let errorMessage: String?
    public let completedAt: Date

    public init(
        callID: String,
        runID: BurnBarRunID,
        succeeded: Bool,
        output: BurnBarJSONValue?,
        errorMessage: String? = nil,
        completedAt: Date
    ) {
        self.callID = callID
        self.runID = runID
        self.succeeded = succeeded
        self.output = output
        self.errorMessage = errorMessage
        self.completedAt = completedAt
    }
}

public enum BurnBarToolExecutionErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
    case trustGated = "trust_gated"
    case noWorkspace = "no_workspace"
    case remoteUnsupported = "remote_unsupported"
    case applyFailed = "apply_failed"
    case terminalFailed = "terminal_failed"
    case unknown
}

public struct BurnBarToolExecutionError: Codable, Hashable, Sendable {
    public let code: BurnBarToolExecutionErrorCode
    public let message: String

    public init(code: BurnBarToolExecutionErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum BurnBarToolCallStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case cancelled
}

public struct BurnBarToolCallSnapshot: Codable, Hashable, Sendable {
    public let callID: String
    public let runID: BurnBarRunID
    public let tool: BurnBarToolKind
    public let arguments: BurnBarJSONValue
    public let status: BurnBarToolCallStatus
    public let requestedBy: BurnBarClientID
    public let requestedAt: Date
    public let claimedBy: BurnBarClientID?
    public let claimedAt: Date?
    public let completedAt: Date?
    public let output: BurnBarJSONValue?
    public let error: BurnBarToolExecutionError?

    public init(
        callID: String,
        runID: BurnBarRunID,
        tool: BurnBarToolKind,
        arguments: BurnBarJSONValue,
        status: BurnBarToolCallStatus,
        requestedBy: BurnBarClientID,
        requestedAt: Date,
        claimedBy: BurnBarClientID? = nil,
        claimedAt: Date? = nil,
        completedAt: Date? = nil,
        output: BurnBarJSONValue? = nil,
        error: BurnBarToolExecutionError? = nil
    ) {
        self.callID = callID
        self.runID = runID
        self.tool = tool
        self.arguments = arguments
        self.status = status
        self.requestedBy = requestedBy
        self.requestedAt = requestedAt
        self.claimedBy = claimedBy
        self.claimedAt = claimedAt
        self.completedAt = completedAt
        self.output = output
        self.error = error
    }
}

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

public struct BurnBarProtocolHandshakeRequest: Codable, Hashable, Sendable {
    public let clientName: String
    public let clientVersion: String
    public let supportedProtocolVersions: [Int]

    public init(clientName: String, clientVersion: String, supportedProtocolVersions: [Int]) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.supportedProtocolVersions = supportedProtocolVersions
    }
}

public struct BurnBarProtocolHandshakeResponse: Codable, Hashable, Sendable {
    public let negotiatedProtocolVersion: Int?
    public let daemonVersion: String
    public let compatible: Bool

    public init(negotiatedProtocolVersion: Int?, daemonVersion: String, compatible: Bool) {
        self.negotiatedProtocolVersion = negotiatedProtocolVersion
        self.daemonVersion = daemonVersion
        self.compatible = compatible
    }
}

public struct BurnBarHealthRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarHealthResponse: Codable, Hashable, Sendable {
    public let ok: Bool
    public let daemonVersion: String
    public let protocolVersion: Int
    public let socketPath: String?

    public init(ok: Bool, daemonVersion: String, protocolVersion: Int, socketPath: String? = nil) {
        self.ok = ok
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.socketPath = socketPath
    }
}

public struct BurnBarCatalogRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarCatalogResponse: Codable, Hashable, Sendable {
    public let catalog: BurnBarCatalog

    public init(catalog: BurnBarCatalog) {
        self.catalog = catalog
    }
}

public struct BurnBarProviderSettings: Codable, Hashable, Identifiable, Sendable {
    public let providerID: String
    public var isEnabled: Bool
    public var baseURL: String
    public var preferredModelIDs: [String]

    public var id: String { providerID }

    public init(
        providerID: String,
        isEnabled: Bool = false,
        baseURL: String,
        preferredModelIDs: [String]
    ) {
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.preferredModelIDs = preferredModelIDs
    }
}

public struct BurnBarProviderConfigurationSnapshot: Codable, Hashable, Sendable {
    public var providers: [BurnBarProviderSettings]

    public init(providers: [BurnBarProviderSettings]) {
        self.providers = providers
    }

    public func providerSettings(id: String) -> BurnBarProviderSettings? {
        providers.first(where: { $0.providerID == id })
    }
}

public struct BurnBarConfigGetRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarConfigUpdateRequest: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot

    public init(snapshot: BurnBarProviderConfigurationSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarConfigResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarProviderConfigurationSnapshot

    public init(snapshot: BurnBarProviderConfigurationSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarRecentUsageRequest: Codable, Hashable, Sendable {
    public let limit: Int

    public init(limit: Int = 20) {
        self.limit = limit
    }
}

public struct BurnBarRecentUsageResponse: Codable, Hashable, Sendable {
    public let usage: [BurnBarUsageEvent]

    public init(usage: [BurnBarUsageEvent]) {
        self.usage = usage
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

    public init(clientID: BurnBarClientID) {
        self.clientID = clientID
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

    public init(clientID: BurnBarClientID, sessionID: BurnBarSessionID, runID: BurnBarRunID? = nil) {
        self.clientID = clientID
        self.sessionID = sessionID
        self.runID = runID
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

public struct BurnBarClientAttachRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID
    public let clientName: String
    public let supportedProtocolVersions: [Int]

    public init(
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        clientName: String,
        supportedProtocolVersions: [Int]
    ) {
        self.clientID = clientID
        self.sessionID = sessionID
        self.clientName = clientName
        self.supportedProtocolVersions = supportedProtocolVersions
    }
}

public struct BurnBarClientAttachResponse: Codable, Hashable, Sendable {
    public let attachedClientID: BurnBarClientID
    public let negotiatedProtocolVersion: Int?

    public init(attachedClientID: BurnBarClientID, negotiatedProtocolVersion: Int?) {
        self.attachedClientID = attachedClientID
        self.negotiatedProtocolVersion = negotiatedProtocolVersion
    }
}

public struct BurnBarClientClaimControlRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID

    public init(clientID: BurnBarClientID, sessionID: BurnBarSessionID) {
        self.clientID = clientID
        self.sessionID = sessionID
    }
}

public struct BurnBarClientDetachRequest: Codable, Hashable, Sendable {
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID

    public init(clientID: BurnBarClientID, sessionID: BurnBarSessionID) {
        self.clientID = clientID
        self.sessionID = sessionID
    }
}

public struct BurnBarUsageEvent: Codable, Hashable, Sendable {
    public let runID: BurnBarRunID?
    public let providerID: String
    public let modelID: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cost: Double
    public let recordedAt: Date

    public init(
        runID: BurnBarRunID? = nil,
        providerID: String,
        modelID: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cost: Double,
        recordedAt: Date
    ) {
        self.runID = runID
        self.providerID = providerID
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cost = cost
        self.recordedAt = recordedAt
    }
}

public struct BurnBarClientArbitrationSnapshot: Codable, Hashable, Sendable {
    public let activeClientID: BurnBarClientID?
    public let attachedClientIDs: [BurnBarClientID]
    public let reason: String?

    public init(activeClientID: BurnBarClientID?, attachedClientIDs: [BurnBarClientID], reason: String? = nil) {
        self.activeClientID = activeClientID
        self.attachedClientIDs = attachedClientIDs
        self.reason = reason
    }
}

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
