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
    case providerCredentialSlotUpsert = "daemon.provider.credential_slot.upsert"
    case providerCredentialSlotRemove = "daemon.provider.credential_slot.remove"
    case providerModelVariantUpsert = "daemon.provider.model_variant.upsert"
    case providerModelVariantRemove = "daemon.provider.model_variant.remove"
    case usageRecord = "daemon.usage.record"
    case usageRecent = "daemon.usage.recent"
    case connectorPlaneGet = "daemon.connector.plane.get"
    case connectorConfigUpdate = "daemon.connector.config.update"
    case connectorAction = "daemon.connector.action"
    case browserToolingGet = "daemon.browser.tooling.get"
    case browserToolingUpdate = "daemon.browser.tooling.update"
    case browserAction = "daemon.browser.action"
    case computerUseSessionStart = "daemon.computer_use.session.start"
    case computerUseInvoke = "daemon.computer_use.invoke"
    case computerUseApprovalPending = "daemon.computer_use.approval.pending"
    case computerUseApprovalRespond = "daemon.computer_use.approval.respond"
    case computerUsePanicHalt = "daemon.computer_use.panic_halt"
    case computerUseAuditExport = "daemon.computer_use.audit_export"
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
