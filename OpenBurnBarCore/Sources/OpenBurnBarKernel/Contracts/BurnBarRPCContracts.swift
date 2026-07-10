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
    case linuxOnboardingSnapshot = "daemon.onboarding.snapshot"
    case linuxOnboardingAction = "daemon.onboarding.action"
    case linuxOnboardingReset = "daemon.onboarding.reset"
    case configGet = "daemon.config.get"
    case configUpdate = "daemon.config.update"
    case providerCredentialSlotUpsert = "daemon.provider.credential_slot.upsert"
    case providerCredentialSlotRemove = "daemon.provider.credential_slot.remove"
    case providerExternalAuthStart = "daemon.provider.external_auth.start"
    case providerExternalAuthStatus = "daemon.provider.external_auth.status"
    case providerExternalAuthCancel = "daemon.provider.external_auth.cancel"
    case providerModelVariantUpsert = "daemon.provider.model_variant.upsert"
    case providerModelVariantRemove = "daemon.provider.model_variant.remove"
    case providerModelAliasUpsert = "daemon.provider.model_alias.upsert"
    case providerModelAliasRemove = "daemon.provider.model_alias.remove"
    case providerCustomModelUpsert = "daemon.provider.custom_model.upsert"
    case providerCustomModelRemove = "daemon.provider.custom_model.remove"
    case providerModelDisplayNameSet = "daemon.provider.model_display_name.set"
    case providerModelDisplayNameClear = "daemon.provider.model_display_name.clear"
    case usageRecord = "daemon.usage.record"
    case usageRecent = "daemon.usage.recent"
    case proxyRouteLogRecent = "daemon.proxy.route_log.recent"
    case proxyRouteLogClear = "daemon.proxy.route_log.clear"
    case quotaSignalsRecent = "daemon.quota.signals.recent"
    case quotaSignalsClear = "daemon.quota.signals.clear"
    case perfMeasure = "perf.measure"
    case accountStatus = "daemon.account.status"
    case accountDeviceAuthStart = "daemon.account.device_auth.start"
    case accountDeviceAuthPoll = "daemon.account.device_auth.poll"
    case accountDeviceAuthCancel = "daemon.account.device_auth.cancel"
    case accountSignOut = "daemon.account.sign_out"
    case membershipStatus = "daemon.membership.status"
    case membershipCheckoutURL = "daemon.membership.checkoutUrl"
    case membershipRestore = "daemon.membership.restore"
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
    /// T-DMN-04: provision the daemon's pinned phone-control verifying key for a
    /// source device. First-party Mac app only; mutates daemon keychain trust state.
    case phoneControlPinProvision = "daemon.phone_control.pin.provision"
    case daemonMediaSessionState = "daemon.media.session.state"
    case daemonMediaCallAccept = "daemon.media.call.accept"
    case daemonMediaCallDecline = "daemon.media.call.decline"
    case daemonMediaCallEnd = "daemon.media.call.end"
    case daemonMediaCapabilityGet = "daemon.media.capability.get"
    case daemonMediaStatus = "daemon.media.status"
    case daemonMediaFileOfferList = "daemon.media.file.offer.list"
    case daemonMediaFileAccept = "daemon.media.file.accept"
    case daemonMediaFileDecline = "daemon.media.file.decline"
    case daemonMediaFileSend = "daemon.media.file.send"
    case controllerSummary = "daemon.controller.summary"
    /// Aggregated controller runtime (summary + questions + followups +
    /// missions + notification health + simulator runs) in one round trip.
    /// Newer than the per-list RPCs: clients must fall back to those when
    /// an older daemon rejects this method.
    case controllerRuntimeSnapshot = "daemon.controller.runtime_snapshot"
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
    /// M2 (split-brain remediation Phase 2): daemon-side authorization verdict
    /// for a remote (mobile/Wand) mission whose sealed payload the GUI
    /// transport has already unsealed and decoded. Additive — no shipped
    /// client calls it yet; M3 wires the GUI listener in shadow mode.
    case missionAuthorizeRemote = "daemon.mission.authorizeRemote"
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
    case subscriptionStart = "subscription.start"
    case subscriptionResume = "subscription.resume"
    case subscriptionStop = "subscription.stop"
    case clientAttach = "client.attach"
    case clientClaimControl = "client.claimControl"
    case clientDetach = "client.detach"
    /// Planner-backed lexical + aggregate search over the local OpenBurnBar SQLite index (daemon must have DB path).
    case searchQuery = "daemon.search.query"
    case memoryRemember = "daemon.memory.remember"
    case memoryRecall = "daemon.memory.recall"
    case memoryForget = "daemon.memory.forget"
    case memoryAuditTrail = "daemon.memory.audit_trail"
    case memoryAnalytics = "daemon.memory.analytics"
    case codeIndexProject = "daemon.code.index_project"
    case codeSearch = "daemon.code.search"
    case codeContextPack = "daemon.code.context_pack"
    case codeGetSymbol = "daemon.code.get_symbol"
    case codeFindReferences = "daemon.code.find_references"
    case codeCallGraph = "daemon.code.call_graph"
    case codeDiagnostics = "daemon.code.diagnostics"
    case codeIndexStatus = "daemon.code.index_status"
    case codeExplore = "daemon.code.explore"
    case codeWatchProject = "daemon.code.watch_project"
    case codeOpsDiagnostics = "daemon.code.ops_diagnostics"
    case runResume = "run.resume"
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

public struct BurnBarPerfMeasureRequest: Codable, Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct BurnBarPerfMeasureResponse: Codable, Hashable, Sendable {
    public let ok: Bool
    public let source: String
    public let detail: String?

    public init(ok: Bool, source: String, detail: String? = nil) {
        self.ok = ok
        self.source = source
        self.detail = detail
    }
}

public enum BurnBarAccountState: String, Codable, Hashable, Sendable {
    case signedOut = "signed_out"
    case authorizationPending = "authorization_pending"
    case signedIn = "signed_in"
}

public enum BurnBarAccountProblemCode: String, Codable, Hashable, Sendable {
    case secretStoreUnavailable = "secret_store_unavailable"
    case networkUnavailable = "network_unavailable"
    case reauthenticationRequired = "reauthentication_required"
    case authorizationExpired = "authorization_expired"
}

public struct BurnBarAccountProblem: Codable, Hashable, Sendable {
    public let code: BurnBarAccountProblemCode
    public let message: String
    public let recoverable: Bool

    public init(code: BurnBarAccountProblemCode, message: String, recoverable: Bool) {
        self.code = code
        self.message = message
        self.recoverable = recoverable
    }
}

public struct BurnBarAccountDeviceAuthSession: Codable, Hashable, Sendable {
    public let flowID: String
    public let userCode: String
    public let verificationURL: String
    public let expiresAt: String
    public let pollIntervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case flowID = "flow_id"
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresAt = "expires_at"
        case pollIntervalSeconds = "poll_interval_seconds"
    }

    public init(
        flowID: String,
        userCode: String,
        verificationURL: String,
        expiresAt: String,
        pollIntervalSeconds: Int
    ) {
        self.flowID = flowID
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
        self.pollIntervalSeconds = pollIntervalSeconds
    }
}

public struct BurnBarAccountSnapshot: Codable, Hashable, Sendable {
    public let state: BurnBarAccountState
    public let uid: String?
    public let email: String?
    public let displayName: String?
    public let photoURL: String?
    public let trustClass: String
    public let syncState: String
    public let credentialBackend: String?
    public let session: BurnBarAccountDeviceAuthSession?
    public let problem: BurnBarAccountProblem?
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case state
        case uid
        case email
        case displayName = "display_name"
        case photoURL = "photo_url"
        case trustClass = "trust_class"
        case syncState = "sync_state"
        case credentialBackend = "credential_backend"
        case session
        case problem
        case updatedAt = "updated_at"
    }

    public init(
        state: BurnBarAccountState,
        uid: String? = nil,
        email: String? = nil,
        displayName: String? = nil,
        photoURL: String? = nil,
        trustClass: String = "linux_lower_trust",
        syncState: String = "local_only",
        credentialBackend: String? = nil,
        session: BurnBarAccountDeviceAuthSession? = nil,
        problem: BurnBarAccountProblem? = nil,
        updatedAt: String
    ) {
        self.state = state
        self.uid = uid
        self.email = email
        self.displayName = displayName
        self.photoURL = photoURL
        self.trustClass = trustClass
        self.syncState = syncState
        self.credentialBackend = credentialBackend
        self.session = session
        self.problem = problem
        self.updatedAt = updatedAt
    }
}

public struct BurnBarAccountStatusResponse: Codable, Hashable, Sendable {
    public let account: BurnBarAccountSnapshot

    public init(account: BurnBarAccountSnapshot) {
        self.account = account
    }
}

public struct BurnBarAccountFlowRequest: Codable, Hashable, Sendable {
    public let flowID: String

    enum CodingKeys: String, CodingKey {
        case flowID = "flow_id"
    }

    public init(flowID: String) {
        self.flowID = flowID
    }
}

public enum BurnBarMembershipState: String, Codable, Hashable, Sendable {
    case active
    case cancelled
    case paymentFailed
    case offline
}

public enum BurnBarMembershipErrorCode: String, Codable, Hashable, Sendable {
    case unauthenticated
    case offline
    case cloudUnavailable
    case invalidResponse
}

public struct BurnBarMembershipErrorResult: Codable, Hashable, Sendable {
    public let code: BurnBarMembershipErrorCode
    public let message: String

    public init(code: BurnBarMembershipErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct BurnBarMembershipEntitlementDocument: Codable, Hashable, Sendable {
    public let active: Bool
    public let productID: String?
    public let expiresAt: String?
    public let expireAt: String?
    public let source: String?

    public init(
        active: Bool,
        productID: String? = nil,
        expiresAt: String? = nil,
        expireAt: String? = nil,
        source: String? = nil
    ) {
        self.active = active
        self.productID = productID
        self.expiresAt = expiresAt
        self.expireAt = expireAt
        self.source = source
    }
}

public struct BurnBarMembershipSnapshot: Codable, Hashable, Sendable {
    public let tier: String
    public let entitlementIds: [String]
    public let activeEntitlements: [String]
    public let entitlementDocs: [String: BurnBarMembershipEntitlementDocument]
    public let renewsAt: String?
    public let restoreAvailable: Bool
    public let state: BurnBarMembershipState
    public let cacheEvent: String
    public let shellCacheEvent: String
    public let daemonCacheKey: String
    public let source: String
    public let updatedAt: String?
    public let error: BurnBarMembershipErrorResult?

    public init(
        tier: String,
        entitlementIds: [String],
        activeEntitlements: [String]? = nil,
        entitlementDocs: [String: BurnBarMembershipEntitlementDocument] = [:],
        renewsAt: String? = nil,
        restoreAvailable: Bool,
        state: BurnBarMembershipState,
        cacheEvent: String = "membership.entitlement_cache.updated",
        shellCacheEvent: String = "membership.entitlement_cache.updated",
        daemonCacheKey: String,
        source: String,
        updatedAt: String? = nil,
        error: BurnBarMembershipErrorResult? = nil
    ) {
        self.tier = tier
        self.entitlementIds = entitlementIds
        self.activeEntitlements = activeEntitlements ?? entitlementIds
        self.entitlementDocs = entitlementDocs
        self.renewsAt = renewsAt
        self.restoreAvailable = restoreAvailable
        self.state = state
        self.cacheEvent = cacheEvent
        self.shellCacheEvent = shellCacheEvent
        self.daemonCacheKey = daemonCacheKey
        self.source = source
        self.updatedAt = updatedAt
        self.error = error
    }
}

public struct BurnBarMembershipStatusResponse: Codable, Hashable, Sendable {
    public let membership: BurnBarMembershipSnapshot

    public init(membership: BurnBarMembershipSnapshot) {
        self.membership = membership
    }
}

public struct BurnBarMembershipCheckoutURLRequest: Codable, Hashable, Sendable {
    public let successURL: String
    public let cancelURL: String

    enum CodingKeys: String, CodingKey {
        case successURL = "success_url"
        case cancelURL = "cancel_url"
    }

    public init(
        successURL: String = "openburnbar://membership/success",
        cancelURL: String = "openburnbar://membership/cancel"
    ) {
        self.successURL = successURL
        self.cancelURL = cancelURL
    }
}

public struct BurnBarMembershipCheckoutURLResponse: Codable, Hashable, Sendable {
    public let url: String
    public let source: String

    public init(url: String, source: String = "stripe_checkout") {
        self.url = url
        self.source = source
    }
}

public struct BurnBarMembershipRestoreResponse: Codable, Hashable, Sendable {
    public let ok: Bool
    public let membership: BurnBarMembershipSnapshot?
    public let error: BurnBarMembershipErrorResult?

    public init(
        ok: Bool,
        membership: BurnBarMembershipSnapshot? = nil,
        error: BurnBarMembershipErrorResult? = nil
    ) {
        self.ok = ok
        self.membership = membership
        self.error = error
    }
}

public enum DaemonMediaSessionPhase: String, Codable, Hashable, Sendable {
    case idle
    case ringing
    case streaming
    case cooldown
}

public enum DaemonMediaSessionKind: String, Codable, Hashable, Sendable {
    case mirror
    case call
}

public struct DaemonMediaPeerSnapshot: Codable, Hashable, Sendable {
    public let connectionID: String
    public let displayName: String
    public let isOnline: Bool
    public let lastSeenAt: Date
    public let capabilities: [String]

    public init(
        connectionID: String,
        displayName: String,
        isOnline: Bool,
        lastSeenAt: Date,
        capabilities: [String]
    ) {
        self.connectionID = connectionID
        self.displayName = displayName
        self.isOnline = isOnline
        self.lastSeenAt = lastSeenAt
        self.capabilities = capabilities
    }
}

public struct DaemonMediaSessionSnapshot: Codable, Hashable, Sendable {
    public let phase: DaemonMediaSessionPhase
    public let kind: DaemonMediaSessionKind?
    public let sessionID: String?
    public let requestID: String?
    public let streamClass: String?
    public let peer: DaemonMediaPeerSnapshot?
    public let startedAt: Date?
    public let updatedAt: Date
    public let cooldownUntil: Date?
    public let shellConnected: Bool
    public let queuedFrameCount: Int
    public let droppedFrameCount: Int

    public init(
        phase: DaemonMediaSessionPhase,
        kind: DaemonMediaSessionKind? = nil,
        sessionID: String? = nil,
        requestID: String? = nil,
        streamClass: String? = nil,
        peer: DaemonMediaPeerSnapshot? = nil,
        startedAt: Date? = nil,
        updatedAt: Date,
        cooldownUntil: Date? = nil,
        shellConnected: Bool = false,
        queuedFrameCount: Int = 0,
        droppedFrameCount: Int = 0
    ) {
        self.phase = phase
        self.kind = kind
        self.sessionID = sessionID
        self.requestID = requestID
        self.streamClass = streamClass
        self.peer = peer
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.cooldownUntil = cooldownUntil
        self.shellConnected = shellConnected
        self.queuedFrameCount = queuedFrameCount
        self.droppedFrameCount = droppedFrameCount
    }
}

public struct DaemonMediaCapabilityResponse: Codable, Hashable, Sendable {
    public let platform: String
    public let available: Bool
    public let mediaSocketPath: String?
    public let supportsDaemonToShellFrames: Bool
    public let supportsShellToDaemonControl: Bool
    public let codecsKnown: Bool
    public let codecs: [String: Bool]
    public let source: String
    public let detail: String?

    public init(
        platform: String,
        available: Bool,
        mediaSocketPath: String?,
        supportsDaemonToShellFrames: Bool,
        supportsShellToDaemonControl: Bool,
        codecsKnown: Bool,
        codecs: [String: Bool],
        source: String,
        detail: String? = nil
    ) {
        self.platform = platform
        self.available = available
        self.mediaSocketPath = mediaSocketPath
        self.supportsDaemonToShellFrames = supportsDaemonToShellFrames
        self.supportsShellToDaemonControl = supportsShellToDaemonControl
        self.codecsKnown = codecsKnown
        self.codecs = codecs
        self.source = source
        self.detail = detail
    }
}

public struct DaemonMediaStatusResponse: Codable, Hashable, Sendable {
    public let capability: DaemonMediaCapabilityResponse
    public let session: DaemonMediaSessionSnapshot

    public init(
        capability: DaemonMediaCapabilityResponse,
        session: DaemonMediaSessionSnapshot
    ) {
        self.capability = capability
        self.session = session
    }
}

public struct DaemonMediaSessionStateResponse: Codable, Hashable, Sendable {
    public let session: DaemonMediaSessionSnapshot

    public init(session: DaemonMediaSessionSnapshot) {
        self.session = session
    }
}

public struct DaemonMediaCallAcceptRequest: Codable, Hashable, Sendable {
    public let requestID: String?
    public let sessionID: String?

    public init(requestID: String? = nil, sessionID: String? = nil) {
        self.requestID = requestID
        self.sessionID = sessionID
    }
}

public struct DaemonMediaCallDeclineRequest: Codable, Hashable, Sendable {
    public let requestID: String?
    public let reason: String?

    public init(requestID: String? = nil, reason: String? = nil) {
        self.requestID = requestID
        self.reason = reason
    }
}

public struct DaemonMediaCallEndRequest: Codable, Hashable, Sendable {
    public let sessionID: String?
    public let reason: String?

    public init(sessionID: String? = nil, reason: String? = nil) {
        self.sessionID = sessionID
        self.reason = reason
    }
}

public struct DaemonMediaCallActionResponse: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let session: DaemonMediaSessionSnapshot
    public let detail: String?

    public init(
        accepted: Bool,
        session: DaemonMediaSessionSnapshot,
        detail: String? = nil
    ) {
        self.accepted = accepted
        self.session = session
        self.detail = detail
    }
}

public enum DaemonMediaFileTransferDirection: String, Codable, Hashable, Sendable {
    case inbound
    case outbound
}

public enum DaemonMediaFileTransferPhase: String, Codable, Hashable, Sendable {
    case pendingAccept
    case downloading
    case sending
    case offered
    case completed
    case declined
    case failed
}

public enum DaemonMediaFileTransferErrorCode: String, Codable, Hashable, Sendable {
    case capabilityAbsent
    case invalidRequest
    case transferNotFound
    case localFileMissing
    case noControlRoute
    case publishFailed
    case fetchFailed
    case ioFailed
    case peerRejected
}

public struct DaemonMediaFileTransferProgress: Codable, Hashable, Sendable {
    public let bytesTransferred: Int64
    public let bytesTotal: Int64
    public let fraction: Double

    public init(bytesTransferred: Int64, bytesTotal: Int64) {
        self.bytesTransferred = max(0, bytesTransferred)
        self.bytesTotal = max(0, bytesTotal)
        self.fraction = bytesTotal > 0
            ? min(1.0, max(0.0, Double(max(0, bytesTransferred)) / Double(bytesTotal)))
            : 0
    }
}

public struct DaemonMediaFileTransferSnapshot: Codable, Hashable, Sendable {
    public let transferID: String
    public let manifestID: String
    public let direction: DaemonMediaFileTransferDirection
    public let phase: DaemonMediaFileTransferPhase
    public let filename: String
    public let mime: String
    public let size: Int64
    public let peer: DaemonMediaPeerSnapshot?
    public let progress: DaemonMediaFileTransferProgress
    public let localPath: String?
    public let errorCode: DaemonMediaFileTransferErrorCode?
    public let detail: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let completedAt: Date?

    public init(
        transferID: String,
        manifestID: String,
        direction: DaemonMediaFileTransferDirection,
        phase: DaemonMediaFileTransferPhase,
        filename: String,
        mime: String,
        size: Int64,
        peer: DaemonMediaPeerSnapshot? = nil,
        progress: DaemonMediaFileTransferProgress,
        localPath: String? = nil,
        errorCode: DaemonMediaFileTransferErrorCode? = nil,
        detail: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil
    ) {
        self.transferID = transferID
        self.manifestID = manifestID
        self.direction = direction
        self.phase = phase
        self.filename = filename
        self.mime = mime
        self.size = size
        self.peer = peer
        self.progress = progress
        self.localPath = localPath
        self.errorCode = errorCode
        self.detail = detail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

public struct DaemonMediaFileOfferListResponse: Codable, Hashable, Sendable {
    public let capabilityAvailable: Bool
    public let downloadDirectory: String?
    public let transfers: [DaemonMediaFileTransferSnapshot]
    public let detail: String?

    public init(
        capabilityAvailable: Bool,
        downloadDirectory: String? = nil,
        transfers: [DaemonMediaFileTransferSnapshot],
        detail: String? = nil
    ) {
        self.capabilityAvailable = capabilityAvailable
        self.downloadDirectory = downloadDirectory
        self.transfers = transfers
        self.detail = detail
    }
}

public struct DaemonMediaFileAcceptRequest: Codable, Hashable, Sendable {
    public let transferID: String?
    public let manifestID: String?

    public init(transferID: String? = nil, manifestID: String? = nil) {
        self.transferID = transferID
        self.manifestID = manifestID
    }
}

public struct DaemonMediaFileDeclineRequest: Codable, Hashable, Sendable {
    public let transferID: String?
    public let manifestID: String?
    public let reason: String?

    public init(transferID: String? = nil, manifestID: String? = nil, reason: String? = nil) {
        self.transferID = transferID
        self.manifestID = manifestID
        self.reason = reason
    }
}

public struct DaemonMediaFileSendRequest: Codable, Hashable, Sendable {
    public let path: String
    public let peerID: String?

    public init(path: String, peerID: String? = nil) {
        self.path = path
        self.peerID = peerID
    }
}

public struct DaemonMediaFileActionResponse: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let transfer: DaemonMediaFileTransferSnapshot?
    public let errorCode: DaemonMediaFileTransferErrorCode?
    public let detail: String?

    public init(
        accepted: Bool,
        transfer: DaemonMediaFileTransferSnapshot? = nil,
        errorCode: DaemonMediaFileTransferErrorCode? = nil,
        detail: String? = nil
    ) {
        self.accepted = accepted
        self.transfer = transfer
        self.errorCode = errorCode
        self.detail = detail
    }
}

public enum BurnBarResumeMode: String, Codable, Sendable, Hashable {
    case print
    case copy
    case open
    case spawn
}

public struct BurnBarRunResumeRequest: Codable, Sendable, Hashable {
    public let sessionID: String
    public let targetHarness: String?
    public let targetModel: String?
    public let mode: BurnBarResumeMode

    public init(
        sessionID: String,
        targetHarness: String? = nil,
        targetModel: String? = nil,
        mode: BurnBarResumeMode = .print
    ) {
        self.sessionID = sessionID
        self.targetHarness = targetHarness
        self.targetModel = targetModel
        self.mode = mode
    }
}

public struct BurnBarRunResumeResponse: Codable, Sendable, Hashable {
    public let kind: String
    public let argv: [String]?
    public let targetHarness: String?
    public let targetArgv: [String]?
    public let briefingMD: String?
    public let briefingPath: String?
    public let workingDirectory: String?
    public let note: String?
    public let pid: Int?
    public let cleanupAfterSeconds: Int?
    public let errorCode: String?
    public let errorRecovery: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case argv
        case targetHarness = "target_harness"
        case targetArgv = "target_argv"
        case briefingMD = "briefing_md"
        case briefingPath = "briefing_path"
        case workingDirectory = "working_directory"
        case note
        case pid
        case cleanupAfterSeconds = "cleanup_after_seconds"
        case errorCode = "code"
        case errorRecovery = "recovery"
    }

    public init(
        kind: String,
        argv: [String]? = nil,
        targetHarness: String? = nil,
        targetArgv: [String]? = nil,
        briefingMD: String? = nil,
        briefingPath: String? = nil,
        workingDirectory: String? = nil,
        note: String? = nil,
        pid: Int? = nil,
        cleanupAfterSeconds: Int? = nil,
        errorCode: String? = nil,
        errorRecovery: String? = nil
    ) {
        self.kind = kind
        self.argv = argv
        self.targetHarness = targetHarness
        self.targetArgv = targetArgv
        self.briefingMD = briefingMD
        self.briefingPath = briefingPath
        self.workingDirectory = workingDirectory
        self.note = note
        self.pid = pid
        self.cleanupAfterSeconds = cleanupAfterSeconds
        self.errorCode = errorCode
        self.errorRecovery = errorRecovery
    }
}

public struct BurnBarSubscriptionStartRequest: Codable, Sendable, Hashable {
    public let topic: String
    public let runID: String?
    public let requestedSubscriptionID: String?
    public let clientID: String?

    enum CodingKeys: String, CodingKey {
        case topic
        case runID = "run_id"
        case requestedSubscriptionID = "requested_subscription_id"
        case clientID = "client_id"
    }

    public init(
        topic: String,
        runID: String? = nil,
        requestedSubscriptionID: String? = nil,
        clientID: String? = nil
    ) {
        self.topic = topic
        self.runID = runID
        self.requestedSubscriptionID = requestedSubscriptionID
        self.clientID = clientID
    }
}

public struct BurnBarSubscriptionResumeRequest: Codable, Sendable, Hashable {
    public let subscriptionID: String
    public let topic: String
    public let afterSeq: Int
    public let runID: String?
    public let clientID: String?

    enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id"
        case topic
        case afterSeq = "after_seq"
        case runID = "run_id"
        case clientID = "client_id"
    }

    public init(
        subscriptionID: String,
        topic: String,
        afterSeq: Int,
        runID: String? = nil,
        clientID: String? = nil
    ) {
        self.subscriptionID = subscriptionID
        self.topic = topic
        self.afterSeq = afterSeq
        self.runID = runID
        self.clientID = clientID
    }
}

public struct BurnBarSubscriptionStopRequest: Codable, Sendable, Hashable {
    public let subscriptionID: String
    public let clientID: String?

    enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id"
        case clientID = "client_id"
    }

    public init(subscriptionID: String, clientID: String? = nil) {
        self.subscriptionID = subscriptionID
        self.clientID = clientID
    }
}

public struct BurnBarSubscriptionEvent: Codable, Sendable, Hashable {
    public let seq: Int
    public let kind: String
    public let snapshot: [String: String]
    public let terminal: Bool

    public init(seq: Int, kind: String, snapshot: [String: String], terminal: Bool = false) {
        self.seq = seq
        self.kind = kind
        self.snapshot = snapshot
        self.terminal = terminal
    }
}

public struct BurnBarSubscriptionResponse: Codable, Sendable, Hashable {
    public let subscriptionID: String
    public let topic: String
    public let seq: Int
    public let cursor: String
    public let firstSnapshot: Bool
    public let events: [BurnBarSubscriptionEvent]
    public let degradedFallback: Bool
    public let degradationReason: String?
    public let backpressure: String
    public let disconnectDetected: Bool
    public let recoveredAfterRestart: Bool
    public let terminalStateDelivered: Bool

    enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id"
        case topic
        case seq
        case cursor
        case firstSnapshot = "first_snapshot"
        case events
        case degradedFallback = "degraded_fallback"
        case degradationReason = "degradation_reason"
        case backpressure
        case disconnectDetected = "disconnect_detected"
        case recoveredAfterRestart = "recovered_after_restart"
        case terminalStateDelivered = "terminal_state_delivered"
    }

    public init(
        subscriptionID: String,
        topic: String,
        seq: Int,
        cursor: String,
        firstSnapshot: Bool,
        events: [BurnBarSubscriptionEvent],
        degradedFallback: Bool,
        degradationReason: String?,
        backpressure: String,
        disconnectDetected: Bool,
        recoveredAfterRestart: Bool,
        terminalStateDelivered: Bool
    ) {
        self.subscriptionID = subscriptionID
        self.topic = topic
        self.seq = seq
        self.cursor = cursor
        self.firstSnapshot = firstSnapshot
        self.events = events
        self.degradedFallback = degradedFallback
        self.degradationReason = degradationReason
        self.backpressure = backpressure
        self.disconnectDetected = disconnectDetected
        self.recoveredAfterRestart = recoveredAfterRestart
        self.terminalStateDelivered = terminalStateDelivered
    }
}

public struct BurnBarSubscriptionStopResponse: Codable, Sendable, Hashable {
    public let subscriptionID: String
    public let stopped: Bool
    public let lastSeq: Int

    enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id"
        case stopped
        case lastSeq = "last_seq"
    }

    public init(subscriptionID: String, stopped: Bool, lastSeq: Int) {
        self.subscriptionID = subscriptionID
        self.stopped = stopped
        self.lastSeq = lastSeq
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
