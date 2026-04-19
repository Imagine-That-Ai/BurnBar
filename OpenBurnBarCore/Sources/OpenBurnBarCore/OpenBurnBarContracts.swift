import Foundation

public enum BurnBarProtocolVersion {
    public static let current = 1
    public static let supported = [1]

    public static func negotiate(with clientSupportedVersions: [Int]) -> Int? {
        supported.first(where: clientSupportedVersions.contains)
    }
}

public enum BurnBarRPCMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case authBootstrap = "auth.bootstrap"
    case health = "daemon.health"
    case catalog = "daemon.catalog"
    case configGet = "daemon.config.get"
    case configUpdate = "daemon.config.update"
    case usageRecent = "daemon.usage.recent"
    case connectorPlaneGet = "daemon.connector.plane.get"
    case connectorConfigUpdate = "daemon.connector.config.update"
    case connectorAction = "daemon.connector.action"
    case browserToolingGet = "daemon.browser.tooling.get"
    case browserToolingUpdate = "daemon.browser.tooling.update"
    case browserAction = "daemon.browser.action"
    case controllerSummary = "daemon.controller.summary"
    case controllerProjectsList = "daemon.controller.project.list"
    case controllerProjectGet = "daemon.controller.project.get"
    case controllerProjectUpsert = "daemon.controller.project.upsert"
    case reviewRunRecord = "daemon.controller.review.record"
    case questionCreate = "daemon.question.create"
    case questionGet = "daemon.question.get"
    case questionsList = "daemon.question.list"
    case questionAnswer = "daemon.question.answer"
    case followupCreate = "daemon.followup.create"
    case followupsList = "daemon.followup.list"
    case followupDone = "daemon.followup.done"
    case followupSnooze = "daemon.followup.snooze"
    case followupCalendar = "daemon.followup.calendar"
    case missionCreate = "daemon.mission.create"
    case missionsList = "daemon.mission.list"
    case missionGet = "daemon.mission.get"
    case missionApprove = "daemon.mission.approve"
    case missionCancel = "daemon.mission.cancel"
    case missionDispatchPacket = "daemon.mission.packet.dispatch"
    case missionRecordResult = "daemon.mission.result.record"
    case notificationConfigGet = "daemon.notification.config.get"
    case notificationConfigUpdate = "daemon.notification.config.update"
    case notificationHealth = "daemon.notification.health"
    case notificationCommand = "daemon.notification.command"
    case simulatorRun = "daemon.simulator.run"
    case simulatorList = "daemon.simulator.list"
    case simulatorReplay = "daemon.simulator.replay"
    case projectionRebuild = "daemon.projection.rebuild"
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
    /// Planner-backed lexical + aggregate search over the local OpenBurnBar SQLite index (daemon must have DB path).
    case searchQuery = "daemon.search.query"
}


public struct BurnBarRPCRequestEnvelope: Codable, Hashable, Sendable {
    public let id: String
    public let method: BurnBarRPCMethod
    public let authToken: String?

    public init(id: String = UUID().uuidString, method: BurnBarRPCMethod, authToken: String? = nil) {
        self.id = id
        self.method = method
        self.authToken = authToken
    }
}

public struct BurnBarRPCRequestEnvelopeWithParams<Params: Codable & Sendable>: Codable, Sendable {
    public let id: String
    public let method: BurnBarRPCMethod
    public let authToken: String?
    public let params: Params

    public init(id: String = UUID().uuidString, method: BurnBarRPCMethod, authToken: String? = nil, params: Params) {
        self.id = id
        self.method = method
        self.authToken = authToken
        self.params = params
    }
}

public struct BurnBarAuthBootstrapRequest: Codable, Hashable, Sendable {
    public let clientName: String
    public let bootstrapToken: String

    public init(clientName: String, bootstrapToken: String) {
        self.clientName = clientName
        self.bootstrapToken = bootstrapToken
    }
}

public struct BurnBarAuthBootstrapResponse: Codable, Hashable, Sendable {
    public let sessionToken: String
    public let issuedAt: Date

    public init(sessionToken: String, issuedAt: Date = Date()) {
        self.sessionToken = sessionToken
        self.issuedAt = issuedAt
    }
}

public struct BurnBarRPCError: Codable, Hashable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
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
    public let gatewayEnabled: Bool
    public let gatewayHost: String?
    public let gatewayPort: Int?

    public init(ok: Bool, daemonVersion: String, protocolVersion: Int, socketPath: String? = nil, gatewayEnabled: Bool = false, gatewayHost: String? = nil, gatewayPort: Int? = nil) {
        self.ok = ok
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.socketPath = socketPath
        self.gatewayEnabled = gatewayEnabled
        self.gatewayHost = gatewayHost
        self.gatewayPort = gatewayPort
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

public enum BurnBarProviderCredentialSlotStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case ready
    case coolingDown
    case exhausted
    case disabled
    case missingSecret
}

public struct BurnBarProviderCredentialSlot: Codable, Hashable, Identifiable, Sendable {
    public let slotID: String
    public var label: String
    public var isEnabled: Bool
    public var status: BurnBarProviderCredentialSlotStatus
    public var cooldownUntil: Date?
    public var lastSelectedAt: Date?
    public var lastQuotaRemainingPercent: Double?
    public var lastQuotaResetsAt: Date?
    public var lastStatusMessage: String?
    public var updatedAt: Date

    public var id: String { slotID }

    public init(
        slotID: String = UUID().uuidString,
        label: String,
        isEnabled: Bool = true,
        status: BurnBarProviderCredentialSlotStatus = .ready,
        cooldownUntil: Date? = nil,
        lastSelectedAt: Date? = nil,
        lastQuotaRemainingPercent: Double? = nil,
        lastQuotaResetsAt: Date? = nil,
        lastStatusMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.slotID = slotID
        self.label = label
        self.isEnabled = isEnabled
        self.status = status
        self.cooldownUntil = cooldownUntil
        self.lastSelectedAt = lastSelectedAt
        self.lastQuotaRemainingPercent = lastQuotaRemainingPercent
        self.lastQuotaResetsAt = lastQuotaResetsAt
        self.lastStatusMessage = lastStatusMessage
        self.updatedAt = updatedAt
    }
}

public struct BurnBarProviderSettings: Codable, Hashable, Identifiable, Sendable {
    public let providerID: String
    public var isEnabled: Bool
    public var baseURL: String
    public var preferredModelIDs: [String]
    public var preferredCredentialSlotID: String?
    public var credentialSlots: [BurnBarProviderCredentialSlot]

    public var id: String { providerID }

    public init(
        providerID: String,
        isEnabled: Bool = false,
        baseURL: String,
        preferredModelIDs: [String],
        preferredCredentialSlotID: String? = nil,
        credentialSlots: [BurnBarProviderCredentialSlot] = []
    ) {
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.preferredModelIDs = preferredModelIDs
        self.preferredCredentialSlotID = preferredCredentialSlotID
        self.credentialSlots = credentialSlots
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case isEnabled
        case baseURL
        case preferredModelIDs
        case preferredCredentialSlotID
        case credentialSlots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        preferredModelIDs = try container.decode([String].self, forKey: .preferredModelIDs)
        preferredCredentialSlotID = try container.decodeIfPresent(String.self, forKey: .preferredCredentialSlotID)
        credentialSlots = try container.decodeIfPresent([BurnBarProviderCredentialSlot].self, forKey: .credentialSlots) ?? []
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

public enum BurnBarConnectorKind: String, Codable, CaseIterable, Hashable, Sendable {
    case github
    case slack
    case linear
    case posthog
    case sentry
    case gmail
}

public enum BurnBarConnectorAuthKind: String, Codable, CaseIterable, Hashable, Sendable {
    case bearerToken = "bearer_token"
    case apiKey = "api_key"
    case oauthAccessToken = "oauth_access_token"
}

public enum BurnBarConnectorHealthStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled
    case missingSecret = "missing_secret"
    case configured
    case healthy
    case degraded
}

public enum BurnBarConnectorActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case testConnection = "test_connection"
    case sampleRequest = "sample_request"
}

public struct BurnBarConnectorConfigMutation: Codable, Hashable, Sendable {
    public let kind: BurnBarConnectorKind
    public let isEnabled: Bool
    public let baseURL: String
    public let authKind: BurnBarConnectorAuthKind
    public let metadata: [String: BurnBarJSONValue]

    public init(
        kind: BurnBarConnectorKind,
        isEnabled: Bool,
        baseURL: String,
        authKind: BurnBarConnectorAuthKind,
        metadata: [String: BurnBarJSONValue] = [:]
    ) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.authKind = authKind
        self.metadata = metadata
    }
}

public struct BurnBarConnectorConfigSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let kind: BurnBarConnectorKind
    public let displayName: String
    public let isEnabled: Bool
    public let baseURL: String
    public let authKind: BurnBarConnectorAuthKind
    public let secretConfigured: Bool
    public let secretHint: String?
    public let status: BurnBarConnectorHealthStatus
    public let lastCheckedAt: Date?
    public let statusDetail: String?
    public let supportedActions: [BurnBarConnectorActionKind]
    public let metadata: [String: BurnBarJSONValue]

    public var id: BurnBarConnectorKind { kind }

    public init(
        kind: BurnBarConnectorKind,
        displayName: String,
        isEnabled: Bool,
        baseURL: String,
        authKind: BurnBarConnectorAuthKind,
        secretConfigured: Bool,
        secretHint: String? = nil,
        status: BurnBarConnectorHealthStatus,
        lastCheckedAt: Date? = nil,
        statusDetail: String? = nil,
        supportedActions: [BurnBarConnectorActionKind] = BurnBarConnectorActionKind.allCases,
        metadata: [String: BurnBarJSONValue] = [:]
    ) {
        self.kind = kind
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.authKind = authKind
        self.secretConfigured = secretConfigured
        self.secretHint = secretHint
        self.status = status
        self.lastCheckedAt = lastCheckedAt
        self.statusDetail = statusDetail
        self.supportedActions = supportedActions
        self.metadata = metadata
    }
}

public struct BurnBarConnectorPlaneSnapshot: Codable, Hashable, Sendable {
    public let updatedAt: Date
    public let connectors: [BurnBarConnectorConfigSnapshot]

    public init(updatedAt: Date, connectors: [BurnBarConnectorConfigSnapshot]) {
        self.updatedAt = updatedAt
        self.connectors = connectors
    }
}

public struct BurnBarConnectorPlaneResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarConnectorPlaneSnapshot

    public init(snapshot: BurnBarConnectorPlaneSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarConnectorConfigUpdateRequest: Codable, Hashable, Sendable {
    public let config: BurnBarConnectorConfigMutation
    public let secret: String?
    public let replaceSecret: Bool

    public init(
        config: BurnBarConnectorConfigMutation,
        secret: String? = nil,
        replaceSecret: Bool = false
    ) {
        self.config = config
        self.secret = secret
        self.replaceSecret = replaceSecret
    }
}

public struct BurnBarConnectorActionRequest: Codable, Hashable, Sendable {
    public let kind: BurnBarConnectorKind
    public let action: BurnBarConnectorActionKind

    public init(kind: BurnBarConnectorKind, action: BurnBarConnectorActionKind) {
        self.kind = kind
        self.action = action
    }
}

public struct BurnBarConnectorActionResponse: Codable, Hashable, Sendable {
    public let kind: BurnBarConnectorKind
    public let action: BurnBarConnectorActionKind
    public let ok: Bool
    public let summary: String
    public let detail: String?
    public let payload: BurnBarJSONValue?
    public let recordedAt: Date

    public init(
        kind: BurnBarConnectorKind,
        action: BurnBarConnectorActionKind,
        ok: Bool,
        summary: String,
        detail: String? = nil,
        payload: BurnBarJSONValue? = nil,
        recordedAt: Date
    ) {
        self.kind = kind
        self.action = action
        self.ok = ok
        self.summary = summary
        self.detail = detail
        self.payload = payload
        self.recordedAt = recordedAt
    }
}

public enum BurnBarBrowserEngineKind: String, Codable, CaseIterable, Hashable, Sendable {
    case systemBrowser = "system_browser"
    case urlSession = "url_session"
    case playwright
    case lightpanda
}

public enum BurnBarBrowserToolStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled
    case ready
    case unavailable
    case degraded
}

public enum BurnBarBrowserActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case openExternal = "open_external"
    case fetchDocument = "fetch_document"
    case extractLinks = "extract_links"
}

public struct BurnBarBrowserEnginePreference: Codable, Hashable, Sendable {
    public let kind: BurnBarBrowserEngineKind
    public let isEnabled: Bool

    public init(kind: BurnBarBrowserEngineKind, isEnabled: Bool) {
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

public struct BurnBarBrowserEngineSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let kind: BurnBarBrowserEngineKind
    public let displayName: String
    public let isEnabled: Bool
    public let status: BurnBarBrowserToolStatus
    public let executablePath: String?
    public let detail: String?
    public let supportsFetch: Bool
    public let supportsExternalNavigation: Bool

    public var id: BurnBarBrowserEngineKind { kind }

    public init(
        kind: BurnBarBrowserEngineKind,
        displayName: String,
        isEnabled: Bool,
        status: BurnBarBrowserToolStatus,
        executablePath: String? = nil,
        detail: String? = nil,
        supportsFetch: Bool,
        supportsExternalNavigation: Bool
    ) {
        self.kind = kind
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.status = status
        self.executablePath = executablePath
        self.detail = detail
        self.supportsFetch = supportsFetch
        self.supportsExternalNavigation = supportsExternalNavigation
    }
}

public struct BurnBarBrowserToolingSnapshot: Codable, Hashable, Sendable {
    public let updatedAt: Date
    public let preferredEngine: BurnBarBrowserEngineKind
    public let allowExternalNavigation: Bool
    public let engines: [BurnBarBrowserEngineSnapshot]

    public init(
        updatedAt: Date,
        preferredEngine: BurnBarBrowserEngineKind,
        allowExternalNavigation: Bool,
        engines: [BurnBarBrowserEngineSnapshot]
    ) {
        self.updatedAt = updatedAt
        self.preferredEngine = preferredEngine
        self.allowExternalNavigation = allowExternalNavigation
        self.engines = engines
    }
}

public struct BurnBarBrowserToolingResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarBrowserToolingSnapshot

    public init(snapshot: BurnBarBrowserToolingSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarBrowserToolingUpdateRequest: Codable, Hashable, Sendable {
    public let preferredEngine: BurnBarBrowserEngineKind
    public let allowExternalNavigation: Bool
    public let enginePreferences: [BurnBarBrowserEnginePreference]

    public init(
        preferredEngine: BurnBarBrowserEngineKind,
        allowExternalNavigation: Bool,
        enginePreferences: [BurnBarBrowserEnginePreference]
    ) {
        self.preferredEngine = preferredEngine
        self.allowExternalNavigation = allowExternalNavigation
        self.enginePreferences = enginePreferences
    }
}

public struct BurnBarBrowserActionRequest: Codable, Hashable, Sendable {
    public let action: BurnBarBrowserActionKind
    public let url: String
    public let preferredEngine: BurnBarBrowserEngineKind?
    public let maxLinks: Int

    public init(
        action: BurnBarBrowserActionKind,
        url: String,
        preferredEngine: BurnBarBrowserEngineKind? = nil,
        maxLinks: Int = 10
    ) {
        self.action = action
        self.url = url
        self.preferredEngine = preferredEngine
        self.maxLinks = maxLinks
    }
}

public struct BurnBarBrowserActionResponse: Codable, Hashable, Sendable {
    public let action: BurnBarBrowserActionKind
    public let engine: BurnBarBrowserEngineKind
    public let ok: Bool
    public let summary: String
    public let detail: String?
    public let title: String?
    public let document: String?
    public let links: [String]
    public let recordedAt: Date

    public init(
        action: BurnBarBrowserActionKind,
        engine: BurnBarBrowserEngineKind,
        ok: Bool,
        summary: String,
        detail: String? = nil,
        title: String? = nil,
        document: String? = nil,
        links: [String] = [],
        recordedAt: Date
    ) {
        self.action = action
        self.engine = engine
        self.ok = ok
        self.summary = summary
        self.detail = detail
        self.title = title
        self.document = document
        self.links = links
        self.recordedAt = recordedAt
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
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let cost: Double
    public let recordedAt: Date

    private enum CodingKeys: String, CodingKey {
        case runID
        case providerID
        case modelID
        case inputTokens
        case outputTokens
        case cacheCreationTokens
        case cacheReadTokens
        case cost
        case recordedAt
    }

    public init(
        runID: BurnBarRunID? = nil,
        providerID: String,
        modelID: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int,
        cost: Double,
        recordedAt: Date
    ) {
        self.runID = runID
        self.providerID = providerID
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.cost = cost
        self.recordedAt = recordedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decodeIfPresent(BurnBarRunID.self, forKey: .runID)
        providerID = try container.decode(String.self, forKey: .providerID)
        modelID = try container.decode(String.self, forKey: .modelID)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        cost = try container.decode(Double.self, forKey: .cost)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try container.encode(cost, forKey: .cost)
        try container.encode(recordedAt, forKey: .recordedAt)
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
