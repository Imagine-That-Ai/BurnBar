import Foundation

public enum HermesRealtimeRelayProtocol {
    public static let version = 1
    public static let capability = "realtime_relay"
    public static let defaultHostedRelayURLString = "wss://hermes-realtime-relay-cjrjb5ckqq-uc.a.run.app/v1/hermes/ws"
    public static let roleHeaderName = "X-OpenBurnBar-Relay-Role"
    public static let hostRoleHeaderValue = "host"
    public static let clientRoleHeaderValue = "client"
}

public enum HermesRealtimeRelayFrameType: String, Codable, Sendable, Equatable {
    case hostRegister = "host.register"
    case hostReady = "host.ready"
    case requestStart = "request.start"
    case requestCancel = "request.cancel"
    case responseChunk = "response.chunk"
    case responseComplete = "response.complete"
    case responseError = "response.error"
    case ping
    case pong
    // Mercury media rollout — see plans/2026-05-15-mercury-media-master-plan.md
    // and docs/HERMES_MEDIA_TRANSPORT.md. Older peers skip unknown frame types
    // on the chat stream so adding cases here is forward-compatible.
    case mediaClassify = "media.classify"
    case mediaBlobAdvertise = "media.blob.advertise"
    case mediaBlobAck = "media.blob.ack"
    // Computer Use control plane — see
    // plans/2026-05-16-computer-use-master-plan.md. Same
    // forward-compatibility contract as the media frame types.
    case controlClassify = "control.classify"
    case controlActionLogEntry = "control.action.log.entry"
    case controlInputIntent = "control.input.intent"
    case controlApprovalRequest = "control.approval.request"
    case controlApprovalResponse = "control.approval.response"
    case controlDenied = "control.denied"
}

public struct HermesRealtimeRelayFrame: Codable, Sendable, Equatable {
    public var type: HermesRealtimeRelayFrameType
    public var uid: String
    public var connectionId: String
    public var requestId: String?
    public var protocolVersion: Int
    public var runtime: String?
    public var payload: HermesRealtimeRelayPayload?
    // Optional sibling to `payload`. Carries Mercury media metadata
    // (stream-class negotiation, blob advertisement, ack). Encoded only
    // when non-nil so chat-only traffic stays byte-identical to the
    // pre-rollout wire form.
    public var media: HermesRealtimeRelayMediaPayload?
    // Optional sibling to `payload` and `media`. Carries Computer Use
    // control-plane metadata. Encoded only when non-nil so pre-Computer
    // Use traffic stays byte-identical to the existing wire form.
    public var control: HermesRealtimeRelayControlPayload?

    public init(
        type: HermesRealtimeRelayFrameType,
        uid: String,
        connectionId: String,
        requestId: String? = nil,
        protocolVersion: Int = HermesRealtimeRelayProtocol.version,
        runtime: String? = nil,
        payload: HermesRealtimeRelayPayload? = nil,
        media: HermesRealtimeRelayMediaPayload? = nil,
        control: HermesRealtimeRelayControlPayload? = nil
    ) {
        self.type = type
        self.uid = uid
        self.connectionId = connectionId
        self.requestId = requestId
        self.protocolVersion = protocolVersion
        self.runtime = runtime
        self.payload = payload
        self.media = media
        self.control = control
    }
}

/// Computer Use control-plane payload — see Phase 8/9/12 of
/// `plans/2026-05-16-computer-use-master-plan.md`. Fields are mutually
/// optional so a single struct can carry any of the four control frame
/// types without forcing receivers to learn about cases they don't yet
/// support. The `kind` discriminator pairs with the outer frame's
/// `HermesRealtimeRelayFrameType` for explicit dispatch.
public struct HermesRealtimeRelayControlPayload: Codable, Sendable, Equatable {
    public var streamClass: String?
    public var sessionId: String?
    public var actionLogEntry: HermesRealtimeRelayActionLogEntry?
    public var inputIntent: HermesRealtimeRelayInputIntent?
    public var approvalRequest: HermesRealtimeRelayApprovalRequest?
    public var approvalResponse: HermesRealtimeRelayApprovalResponse?
    public var denied: HermesRealtimeRelayControlDenied?
    public var authorityPeerNodeId: String?
    public var authorityPublicKeyBase64: String?

    public init(
        streamClass: String? = nil,
        sessionId: String? = nil,
        actionLogEntry: HermesRealtimeRelayActionLogEntry? = nil,
        inputIntent: HermesRealtimeRelayInputIntent? = nil,
        approvalRequest: HermesRealtimeRelayApprovalRequest? = nil,
        approvalResponse: HermesRealtimeRelayApprovalResponse? = nil,
        denied: HermesRealtimeRelayControlDenied? = nil,
        authorityPeerNodeId: String? = nil,
        authorityPublicKeyBase64: String? = nil
    ) {
        self.streamClass = streamClass
        self.sessionId = sessionId
        self.actionLogEntry = actionLogEntry
        self.inputIntent = inputIntent
        self.approvalRequest = approvalRequest
        self.approvalResponse = approvalResponse
        self.denied = denied
        self.authorityPeerNodeId = authorityPeerNodeId
        self.authorityPublicKeyBase64 = authorityPublicKeyBase64
    }
}

public struct HermesRealtimeRelayActionLogEntry: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case planned
        case awaitingApproval = "awaiting_approval"
        case executing
        case completed
        case failed
        case rejected
        case panicHalted = "panic_halted"
    }

    public var entryIndex: Int
    public var gopOrdinal: UInt32?
    public var timestamp: Date
    public var actionKind: String
    public var summary: String
    public var status: Status
    public var screenshotHashBlake3: String?
    public var parentEntryBlake3: String?
    public var errorCategory: String?

    public init(
        entryIndex: Int,
        gopOrdinal: UInt32? = nil,
        timestamp: Date,
        actionKind: String,
        summary: String,
        status: Status,
        screenshotHashBlake3: String? = nil,
        parentEntryBlake3: String? = nil,
        errorCategory: String? = nil
    ) {
        self.entryIndex = entryIndex
        self.gopOrdinal = gopOrdinal
        self.timestamp = timestamp
        self.actionKind = actionKind
        self.summary = summary
        self.status = status
        self.screenshotHashBlake3 = screenshotHashBlake3
        self.parentEntryBlake3 = parentEntryBlake3
        self.errorCategory = errorCategory
    }
}

public struct HermesRealtimeRelayInputIntent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case tap
        case dragStart = "drag_start"
        case dragMove = "drag_move"
        case dragEnd = "drag_end"
        case type
        case shortcut
        case scroll
        case panic
    }

    public var kind: Kind
    public var normalizedX: Double?
    public var normalizedY: Double?
    public var normalizedX2: Double?
    public var normalizedY2: Double?
    public var text: String?
    public var key: String?
    public var modifiers: [String]?
    public var authority: HermesRealtimeRelayAuthorityEnvelope

    public init(
        kind: Kind,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        normalizedX2: Double? = nil,
        normalizedY2: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String]? = nil,
        authority: HermesRealtimeRelayAuthorityEnvelope
    ) {
        self.kind = kind
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedX2 = normalizedX2
        self.normalizedY2 = normalizedY2
        self.text = text
        self.key = key
        self.modifiers = modifiers
        self.authority = authority
    }
}

public struct HermesRealtimeRelayAuthorityEnvelope: Codable, Sendable, Equatable {
    public var peerNodeId: String
    public var counter: UInt64
    public var timestamp: Date
    public var intentHashBlake3: String
    public var signatureEd25519: String

    public init(
        peerNodeId: String,
        counter: UInt64,
        timestamp: Date,
        intentHashBlake3: String,
        signatureEd25519: String
    ) {
        self.peerNodeId = peerNodeId
        self.counter = counter
        self.timestamp = timestamp
        self.intentHashBlake3 = intentHashBlake3
        self.signatureEd25519 = signatureEd25519
    }
}

public struct HermesRealtimeRelayApprovalRequest: Codable, Sendable, Equatable {
    public var approvalId: String
    public var runId: String
    public var sessionId: String
    public var toolKind: String
    public var title: String
    public var message: String
    public var beforeScreenshotBlake3: String?
    public var actionSummary: String
    public var requestedAt: Date
    /// Optional `ComputerUseTrustMode.rawValue` for approval surfaces
    /// that need to reveal Step-only affordances such as burst approval.
    /// Older clients can omit this field and render Manual behavior.
    public var trustMode: String?

    public init(
        approvalId: String,
        runId: String,
        sessionId: String,
        toolKind: String,
        title: String,
        message: String,
        beforeScreenshotBlake3: String? = nil,
        actionSummary: String,
        requestedAt: Date,
        trustMode: String? = nil
    ) {
        self.approvalId = approvalId
        self.runId = runId
        self.sessionId = sessionId
        self.toolKind = toolKind
        self.title = title
        self.message = message
        self.beforeScreenshotBlake3 = beforeScreenshotBlake3
        self.actionSummary = actionSummary
        self.requestedAt = requestedAt
        self.trustMode = trustMode
    }
}

public struct HermesRealtimeRelayApprovalResponse: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable, Equatable {
        case approve
        case reject
        case rejectAndHalt = "reject_and_halt"
    }

    public var approvalId: String
    public var decision: Decision
    public var respondedBy: String
    public var respondedAt: Date
    public var note: String?

    public init(
        approvalId: String,
        decision: Decision,
        respondedBy: String,
        respondedAt: Date,
        note: String? = nil
    ) {
        self.approvalId = approvalId
        self.decision = decision
        self.respondedBy = respondedBy
        self.respondedAt = respondedAt
        self.note = note
    }
}

public struct HermesRealtimeRelayControlDenied: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable, Equatable {
        case entitlement
        case sessionLimit = "session_limit"
        case dailyLimit = "daily_limit"
        case softCap = "soft_cap"
        case hardCap = "hard_cap"
        case scope
        case denyRegion = "deny_region"
        case killSwitch = "kill_switch"
        case signatureFailure = "signature_failure"
        case counterReplay = "counter_replay"
        case staleTimestamp = "stale_timestamp"
        case unknown
    }

    public var reason: Reason
    public var detail: String?

    public init(reason: Reason, detail: String? = nil) {
        self.reason = reason
        self.detail = detail
    }
}

public struct HermesRealtimeRelayMediaPayload: Codable, Sendable, Equatable {
    /// Identifier of the media stream class this frame addresses
    /// (`media.blob`, `media.screen.video`, `media.video.out`, etc.). Carried
    /// as a string rather than a closed enum so receivers route unknown
    /// classes to a no-op handler instead of failing to decode.
    public var streamClass: String?
    /// Attachment manifest carried on `media.blob.advertise`. Plaintext —
    /// metadata only, not content. Bytes flow over the iroh-blobs sub-stream.
    public var attachment: HermesRealtimeRelayAttachmentManifest?
    /// Base32-encoded iroh-blobs ticket. Receiver decodes and dials back to
    /// fetch the blob bytes.
    public var blobTicket: String?
    /// Acknowledgement carried on `media.blob.ack`.
    public var ack: HermesRealtimeRelayMediaAck?

    public init(
        streamClass: String? = nil,
        attachment: HermesRealtimeRelayAttachmentManifest? = nil,
        blobTicket: String? = nil,
        ack: HermesRealtimeRelayMediaAck? = nil
    ) {
        self.streamClass = streamClass
        self.attachment = attachment
        self.blobTicket = blobTicket
        self.ack = ack
    }
}

public struct HermesRealtimeRelayAttachmentManifest: Codable, Sendable, Equatable {
    public var manifestId: String
    public var blobHash: String
    public var filename: String
    public var mime: String
    public var size: Int64
    public var peerDeviceId: String?
    public var createdAt: Date

    public init(
        manifestId: String,
        blobHash: String,
        filename: String,
        mime: String,
        size: Int64,
        peerDeviceId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.manifestId = manifestId
        self.blobHash = blobHash
        self.filename = filename
        self.mime = mime
        self.size = size
        self.peerDeviceId = peerDeviceId
        self.createdAt = createdAt
    }
}

public struct HermesRealtimeRelayMediaAck: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case received
        case rejected
    }

    public var manifestId: String
    public var status: Status
    public var reason: String?

    public init(manifestId: String, status: Status, reason: String? = nil) {
        self.manifestId = manifestId
        self.status = status
        self.reason = reason
    }
}

public struct HermesRealtimeRelayPayload: Codable, Sendable, Equatable {
    public var operation: HermesRelayOperation?
    public var method: String?
    public var payloadCiphertext: String?
    public var wrappedKey: String?
    public var relayEncryption: String?
    public var relayKeyVersion: Int?
    public var sequence: Int?
    public var kind: HermesRelayChunkKind?
    public var ciphertext: String?
    public var error: String?
    public var chunkCount: Int?
    public var capabilities: [String]?

    public init(
        operation: HermesRelayOperation? = nil,
        method: String? = nil,
        payloadCiphertext: String? = nil,
        wrappedKey: String? = nil,
        relayEncryption: String? = nil,
        relayKeyVersion: Int? = nil,
        sequence: Int? = nil,
        kind: HermesRelayChunkKind? = nil,
        ciphertext: String? = nil,
        error: String? = nil,
        chunkCount: Int? = nil,
        capabilities: [String]? = nil
    ) {
        self.operation = operation
        self.method = method
        self.payloadCiphertext = payloadCiphertext
        self.wrappedKey = wrappedKey
        self.relayEncryption = relayEncryption
        self.relayKeyVersion = relayKeyVersion
        self.sequence = sequence
        self.kind = kind
        self.ciphertext = ciphertext
        self.error = error
        self.chunkCount = chunkCount
        self.capabilities = capabilities
    }
}
