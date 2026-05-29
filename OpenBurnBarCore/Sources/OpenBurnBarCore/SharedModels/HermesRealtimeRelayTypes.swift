import Foundation

public enum HermesRealtimeRelayProtocol {
    public static let version = 1
    public static let capability = "realtime_relay"
    public static let defaultHostedRelayURLString = ""
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
    // Mercury Phase 8 — iOS-initiated mirror request / Mac ack / iOS
    // outbound presence heartbeat. Rides the existing media.control
    // stream; no new ALPN. Same forward-compat contract as the chat
    // frame types.
    case mediaMirrorRequest = "media.mirror.request"
    case mediaMirrorAck = "media.mirror.ack"
    case mediaMirrorStop = "media.mirror.stop"
    case mediaMirrorDisplaySelect = "media.mirror.display.select"
    case mediaPresenceHeartbeat = "media.presence.heartbeat"
    case mediaCallInvite = "media.call.invite"
    case mediaCallAck = "media.call.ack"
    /// Receiver -> encoder acknowledgement for a VideoToolbox LTR token
    /// carried on a decoded MediaFrame v2 video frame. This is inert for
    /// v1 peers and only participates after both peers negotiate v2.
    case mediaLongTermReferenceAck = "media.ltr.ack"
    /// Encoded `OpenBurnBarMedia.MediaFrame` bytes carried over the existing
    /// long-lived `media.control` stream after a mirror request is accepted.
    /// The media payload's `streamClass` identifies the logical receiver
    /// (`media.screen.video`, `control.surface.frame`, etc.).
    case mediaStreamFrame = "media.stream.frame"
    // Computer Use control plane — see
    // plans/2026-05-16-computer-use-master-plan.md. Same
    // forward-compatibility contract as the media frame types.
    case controlClassify = "control.classify"
    case controlActionLogEntry = "control.action.log.entry"
    case controlInputIntent = "control.input.intent"
    case controlApprovalRequest = "control.approval.request"
    case controlApprovalResponse = "control.approval.response"
    case controlAgentGrantRequest = "control.agent.grant.request"
    case controlAgentGrantReceipt = "control.agent.grant.receipt"
    case controlClipboardRequest = "control.clipboard.request"
    case controlClipboardResponse = "control.clipboard.response"
    case controlDenied = "control.denied"
    case controlAgentContextTarget = "control.agent.context.target"
    // Remote Unlock — human-only Mac unlock lane. These frames are kept
    // separate from Computer Use so agents can never consume credential input.
    case remoteUnlockSession = "remote_unlock.session"
    case remoteUnlockState = "remote_unlock.state"
    case remoteUnlockInput = "remote_unlock.input"
    case remoteUnlockCredential = "remote_unlock.credential"
    case remoteUnlockResult = "remote_unlock.result"
    case remoteUnlockDenied = "remote_unlock.denied"
    // System Permission Concierge — Phase 14. Mac emits status frames when a
    // tool failure is classified as a TCC denial; the phone replies with a
    // signed request asking the Mac to surface the right native prompt /
    // System Settings deep link. Both frames are forward-compatible —
    // older peers skip unknown control frame types.
    case controlSystemPermissionRequest = "control.system.permission.request"
    case controlSystemPermissionStatus = "control.system.permission.status"
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
    public var agentGrantRequest: HermesRealtimeRelayAgentGrantRequest?
    public var agentGrantReceipt: HermesRealtimeRelayAgentGrantReceipt?
    public var clipboardRequest: HermesRealtimeRelayClipboardRequest?
    public var clipboardResponse: HermesRealtimeRelayClipboardResponse?
    public var denied: HermesRealtimeRelayControlDenied?
    public var authorityPeerNodeId: String?
    public var authorityPublicKeyBase64: String?
    public var agentContextTarget: HermesRealtimeRelayAgentContextTarget?
    public var remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession?
    public var remoteUnlockState: HermesRealtimeRelayRemoteUnlockState?
    public var remoteUnlockInput: HermesRealtimeRelayRemoteUnlockInput?
    public var remoteUnlockCredential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope?
    public var remoteUnlockResult: HermesRealtimeRelayRemoteUnlockResult?
    public var systemPermissionRequest: HermesRealtimeRelaySystemPermissionRequest?
    public var systemPermissionStatus: HermesRealtimeRelaySystemPermissionStatus?

    public init(
        streamClass: String? = nil,
        sessionId: String? = nil,
        actionLogEntry: HermesRealtimeRelayActionLogEntry? = nil,
        inputIntent: HermesRealtimeRelayInputIntent? = nil,
        approvalRequest: HermesRealtimeRelayApprovalRequest? = nil,
        approvalResponse: HermesRealtimeRelayApprovalResponse? = nil,
        agentGrantRequest: HermesRealtimeRelayAgentGrantRequest? = nil,
        agentGrantReceipt: HermesRealtimeRelayAgentGrantReceipt? = nil,
        clipboardRequest: HermesRealtimeRelayClipboardRequest? = nil,
        clipboardResponse: HermesRealtimeRelayClipboardResponse? = nil,
        denied: HermesRealtimeRelayControlDenied? = nil,
        authorityPeerNodeId: String? = nil,
        authorityPublicKeyBase64: String? = nil,
        agentContextTarget: HermesRealtimeRelayAgentContextTarget? = nil,
        remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession? = nil,
        remoteUnlockState: HermesRealtimeRelayRemoteUnlockState? = nil,
        remoteUnlockInput: HermesRealtimeRelayRemoteUnlockInput? = nil,
        remoteUnlockCredential: HermesRealtimeRelayRemoteUnlockCredentialEnvelope? = nil,
        remoteUnlockResult: HermesRealtimeRelayRemoteUnlockResult? = nil,
        systemPermissionRequest: HermesRealtimeRelaySystemPermissionRequest? = nil,
        systemPermissionStatus: HermesRealtimeRelaySystemPermissionStatus? = nil
    ) {
        self.streamClass = streamClass
        self.sessionId = sessionId
        self.actionLogEntry = actionLogEntry
        self.inputIntent = inputIntent
        self.approvalRequest = approvalRequest
        self.approvalResponse = approvalResponse
        self.agentGrantRequest = agentGrantRequest
        self.agentGrantReceipt = agentGrantReceipt
        self.clipboardRequest = clipboardRequest
        self.clipboardResponse = clipboardResponse
        self.denied = denied
        self.authorityPeerNodeId = authorityPeerNodeId
        self.authorityPublicKeyBase64 = authorityPublicKeyBase64
        self.agentContextTarget = agentContextTarget
        self.remoteUnlockSession = remoteUnlockSession
        self.remoteUnlockState = remoteUnlockState
        self.remoteUnlockInput = remoteUnlockInput
        self.remoteUnlockCredential = remoteUnlockCredential
        self.remoteUnlockResult = remoteUnlockResult
        self.systemPermissionRequest = systemPermissionRequest
        self.systemPermissionStatus = systemPermissionStatus
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
        case pointerMove = "pointer_move"
        case pointerClick = "pointer_click"
        case panic
    }

    public var kind: Kind
    public var displayId: String?
    public var normalizedX: Double?
    public var normalizedY: Double?
    public var normalizedX2: Double?
    public var normalizedY2: Double?
    public var text: String?
    public var key: String?
    public var modifiers: [String]?
    public var mouseButton: Int?
    public var clientIntentId: String?
    public var authority: HermesRealtimeRelayAuthorityEnvelope

    public init(
        kind: Kind,
        displayId: String? = nil,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        normalizedX2: Double? = nil,
        normalizedY2: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String]? = nil,
        mouseButton: Int? = nil,
        clientIntentId: String? = nil,
        authority: HermesRealtimeRelayAuthorityEnvelope
    ) {
        self.kind = kind
        self.displayId = displayId
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedX2 = normalizedX2
        self.normalizedY2 = normalizedY2
        self.text = text
        self.key = key
        self.modifiers = modifiers
        self.mouseButton = mouseButton
        self.clientIntentId = clientIntentId
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

public enum HermesRealtimeRelayClipboardAction: String, Codable, Sendable, Equatable {
    case pasteToMac = "paste_to_mac"
    case grabFromMac = "grab_from_mac"
}

public enum HermesRealtimeRelayClipboardStatus: String, Codable, Sendable, Equatable {
    case accepted
    case denied
    case empty
    case tooLarge = "too_large"
    case unsupported
    case error
}

public struct HermesRealtimeRelayClipboardRequest: Codable, Sendable, Equatable {
    public var requestId: String
    public var action: HermesRealtimeRelayClipboardAction
    public var contentType: String
    public var text: String?
    public var maxBytes: Int
    public var clientIntentId: String
    public var authority: HermesRealtimeRelayAuthorityEnvelope

    public init(
        requestId: String,
        action: HermesRealtimeRelayClipboardAction,
        contentType: String,
        text: String? = nil,
        maxBytes: Int,
        clientIntentId: String,
        authority: HermesRealtimeRelayAuthorityEnvelope
    ) {
        self.requestId = requestId
        self.action = action
        self.contentType = contentType
        self.text = text
        self.maxBytes = maxBytes
        self.clientIntentId = clientIntentId
        self.authority = authority
    }
}

public struct HermesRealtimeRelayClipboardResponse: Codable, Sendable, Equatable {
    public var requestId: String
    public var action: HermesRealtimeRelayClipboardAction
    public var status: HermesRealtimeRelayClipboardStatus
    public var contentType: String?
    public var text: String?
    public var byteCount: Int?
    public var detail: String?

    public init(
        requestId: String,
        action: HermesRealtimeRelayClipboardAction,
        status: HermesRealtimeRelayClipboardStatus,
        contentType: String? = nil,
        text: String? = nil,
        byteCount: Int? = nil,
        detail: String? = nil
    ) {
        self.requestId = requestId
        self.action = action
        self.status = status
        self.contentType = contentType
        self.text = text
        self.byteCount = byteCount
        self.detail = detail
    }
}

public struct HermesRealtimeRelayAgentGrantRequest: Codable, Sendable, Equatable {
    public var requestId: String
    public var runtime: String
    public var threadId: String
    public var preset: String
    public var capabilities: [String]
    public var trustMode: String
    public var deliveryMode: String
    public var requestedAt: Date
    public var expiresAt: Date
    public var grantDurationSeconds: Double
    public var sourceDeviceId: String
    public var clientIntentId: String
    public var localAuthenticationSatisfied: Bool
    public var authority: HermesRealtimeRelayAuthorityEnvelope

    public init(
        requestId: String,
        runtime: String,
        threadId: String,
        preset: String,
        capabilities: [String],
        trustMode: String,
        deliveryMode: String,
        requestedAt: Date,
        expiresAt: Date,
        grantDurationSeconds: Double,
        sourceDeviceId: String,
        clientIntentId: String,
        localAuthenticationSatisfied: Bool,
        authority: HermesRealtimeRelayAuthorityEnvelope
    ) {
        self.requestId = requestId
        self.runtime = runtime
        self.threadId = threadId
        self.preset = preset
        self.capabilities = capabilities
        self.trustMode = trustMode
        self.deliveryMode = deliveryMode
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.grantDurationSeconds = grantDurationSeconds
        self.sourceDeviceId = sourceDeviceId
        self.clientIntentId = clientIntentId
        self.localAuthenticationSatisfied = localAuthenticationSatisfied
        self.authority = authority
    }
}

public struct HermesRealtimeRelayAgentGrantReceipt: Codable, Sendable, Equatable {
    public var receiptId: String
    public var requestId: String
    public var runtime: String
    public var threadId: String
    public var status: String
    public var appliedGrantId: String?
    public var capabilities: [String]
    public var trustMode: String
    public var receivedAt: Date
    public var grantExpiresAt: Date?
    public var sourceDeviceId: String?
    public var denialReason: String?
    public var message: String?

    public init(
        receiptId: String,
        requestId: String,
        runtime: String,
        threadId: String,
        status: String,
        appliedGrantId: String? = nil,
        capabilities: [String],
        trustMode: String,
        receivedAt: Date,
        grantExpiresAt: Date? = nil,
        sourceDeviceId: String? = nil,
        denialReason: String? = nil,
        message: String? = nil
    ) {
        self.receiptId = receiptId
        self.requestId = requestId
        self.runtime = runtime
        self.threadId = threadId
        self.status = status
        self.appliedGrantId = appliedGrantId
        self.capabilities = capabilities
        self.trustMode = trustMode
        self.receivedAt = receivedAt
        self.grantExpiresAt = grantExpiresAt
        self.sourceDeviceId = sourceDeviceId
        self.denialReason = denialReason
        self.message = message
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
    /// Optional PNG evidence captured immediately before the requested
    /// action. This lets daemon-originated browser approvals render the
    /// same pre-action thumbnail as app-owned Mac approvals without a
    /// second file-transfer round trip.
    public var beforeScreenshotPNGBase64: String?
    public var beforeScreenshotMimeType: String?
    public var beforeScreenshotSizeBytes: Int?
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
        beforeScreenshotPNGBase64: String? = nil,
        beforeScreenshotMimeType: String? = nil,
        beforeScreenshotSizeBytes: Int? = nil,
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
        self.beforeScreenshotPNGBase64 = beforeScreenshotPNGBase64
        self.beforeScreenshotMimeType = beforeScreenshotMimeType
        self.beforeScreenshotSizeBytes = beforeScreenshotSizeBytes
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
        case agentUnavailable = "agent_unavailable"
        case unknown
    }

    public var reason: Reason
    public var detail: String?

    public init(reason: Reason, detail: String? = nil) {
        self.reason = reason
        self.detail = detail
    }
}

// MARK: - Remote Unlock

public enum HermesRealtimeRelayMacLockState: String, Codable, CaseIterable, Sendable, Hashable {
    case unlocked
    case screenSaver = "screen_saver"
    case screenLocked = "screen_locked"
    case displaySleeping = "display_sleeping"
    case loginWindow = "login_window"
    case securityAgent = "security_agent"
    case fastUserSwitching = "fast_user_switching"
    case remoteDesktopCurtain = "remote_desktop_curtain"
    case rebootLoginWindow = "reboot_login_window"
    case fileVaultPreboot = "filevault_preboot"
    case unknown
}

public enum HermesRealtimeRelayRemoteUnlockBackend: String, Codable, CaseIterable, Sendable, Equatable {
    case screenCaptureKit = "screen_capture_kit"
    case persistentScreenCaptureKit = "persistent_screen_capture_kit"
    case appleScreenSharingLoopback = "apple_screen_sharing_loopback"
    case fileVaultSSH = "filevault_ssh"
    case unavailable
}

public enum HermesRealtimeRelayRemoteUnlockCertificationStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case uncertified
    case certified
    case stale
    case blocked
    case failed
}

public struct HermesRealtimeRelayRemoteUnlockCapabilities: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var certificationStatus: HermesRealtimeRelayRemoteUnlockCertificationStatus
    public var certifiedAt: Date?
    public var certifiedOSBuild: String?
    public var activeBackend: HermesRealtimeRelayRemoteUnlockBackend
    public var supportedBackends: [HermesRealtimeRelayRemoteUnlockBackend]
    public var supportedLockStates: [HermesRealtimeRelayMacLockState]
    public var blockers: [String]
    public var allowsCredentialPaste: Bool
    public var allowsSavedCredentialUnlock: Bool
    public var credentialRecipientKeyId: String?
    public var credentialRecipientPublicKeyBase64: String?
    public var credentialEnvelopeAlgorithm: String?
    public var fileVaultSSHSupported: Bool

    public init(
        enabled: Bool,
        certificationStatus: HermesRealtimeRelayRemoteUnlockCertificationStatus,
        certifiedAt: Date? = nil,
        certifiedOSBuild: String? = nil,
        activeBackend: HermesRealtimeRelayRemoteUnlockBackend,
        supportedBackends: [HermesRealtimeRelayRemoteUnlockBackend] = [],
        supportedLockStates: [HermesRealtimeRelayMacLockState] = [],
        blockers: [String] = [],
        allowsCredentialPaste: Bool = false,
        allowsSavedCredentialUnlock: Bool = false,
        credentialRecipientKeyId: String? = nil,
        credentialRecipientPublicKeyBase64: String? = nil,
        credentialEnvelopeAlgorithm: String? = nil,
        fileVaultSSHSupported: Bool = false
    ) {
        self.enabled = enabled
        self.certificationStatus = certificationStatus
        self.certifiedAt = certifiedAt
        self.certifiedOSBuild = certifiedOSBuild
        self.activeBackend = activeBackend
        self.supportedBackends = supportedBackends
        self.supportedLockStates = supportedLockStates
        self.blockers = blockers
        self.allowsCredentialPaste = allowsCredentialPaste
        self.allowsSavedCredentialUnlock = allowsSavedCredentialUnlock
        self.credentialRecipientKeyId = credentialRecipientKeyId
        self.credentialRecipientPublicKeyBase64 = credentialRecipientPublicKeyBase64
        self.credentialEnvelopeAlgorithm = credentialEnvelopeAlgorithm
        self.fileVaultSSHSupported = fileVaultSSHSupported
    }

    public static let unavailable = HermesRealtimeRelayRemoteUnlockCapabilities(
        enabled: false,
        certificationStatus: .uncertified,
        activeBackend: .unavailable,
        blockers: ["remote_unlock_not_certified"]
    )

    private enum CodingKeys: String, CodingKey {
        case enabled
        case certificationStatus
        case certifiedAt
        case certifiedOSBuild
        case activeBackend
        case supportedBackends
        case supportedLockStates
        case blockers
        case allowsCredentialPaste
        case allowsSavedCredentialUnlock
        case credentialRecipientKeyId
        case credentialRecipientPublicKeyBase64
        case credentialEnvelopeAlgorithm
        case fileVaultSSHSupported
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.certificationStatus = try container.decode(
            HermesRealtimeRelayRemoteUnlockCertificationStatus.self,
            forKey: .certificationStatus
        )
        if container.contains(.certifiedAt) {
            self.certifiedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .certifiedAt)
        } else {
            self.certifiedAt = nil
        }
        self.certifiedOSBuild = try container.decodeIfPresent(String.self, forKey: .certifiedOSBuild)
        self.activeBackend = try container.decode(
            HermesRealtimeRelayRemoteUnlockBackend.self,
            forKey: .activeBackend
        )
        self.supportedBackends = try container.decodeIfPresent(
            [HermesRealtimeRelayRemoteUnlockBackend].self,
            forKey: .supportedBackends
        ) ?? []
        self.supportedLockStates = try container.decodeIfPresent(
            [HermesRealtimeRelayMacLockState].self,
            forKey: .supportedLockStates
        ) ?? []
        self.blockers = try container.decodeIfPresent([String].self, forKey: .blockers) ?? []
        self.allowsCredentialPaste = try container.decodeIfPresent(Bool.self, forKey: .allowsCredentialPaste) ?? false
        self.allowsSavedCredentialUnlock = try container.decodeIfPresent(Bool.self, forKey: .allowsSavedCredentialUnlock) ?? false
        self.credentialRecipientKeyId = try container.decodeIfPresent(String.self, forKey: .credentialRecipientKeyId)
        self.credentialRecipientPublicKeyBase64 = try container.decodeIfPresent(
            String.self,
            forKey: .credentialRecipientPublicKeyBase64
        )
        self.credentialEnvelopeAlgorithm = try container.decodeIfPresent(
            String.self,
            forKey: .credentialEnvelopeAlgorithm
        )
        self.fileVaultSSHSupported = try container.decodeIfPresent(Bool.self, forKey: .fileVaultSSHSupported) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(certificationStatus, forKey: .certificationStatus)
        if let certifiedAt {
            try container.encode(HermesRealtimeRelayDateCodec.encode(certifiedAt), forKey: .certifiedAt)
        }
        try container.encodeIfPresent(certifiedOSBuild, forKey: .certifiedOSBuild)
        try container.encode(activeBackend, forKey: .activeBackend)
        try container.encode(supportedBackends, forKey: .supportedBackends)
        try container.encode(supportedLockStates, forKey: .supportedLockStates)
        try container.encode(blockers, forKey: .blockers)
        try container.encode(allowsCredentialPaste, forKey: .allowsCredentialPaste)
        try container.encode(allowsSavedCredentialUnlock, forKey: .allowsSavedCredentialUnlock)
        try container.encodeIfPresent(credentialRecipientKeyId, forKey: .credentialRecipientKeyId)
        try container.encodeIfPresent(credentialRecipientPublicKeyBase64, forKey: .credentialRecipientPublicKeyBase64)
        try container.encodeIfPresent(credentialEnvelopeAlgorithm, forKey: .credentialEnvelopeAlgorithm)
        try container.encode(fileVaultSSHSupported, forKey: .fileVaultSSHSupported)
    }
}

public struct HermesRealtimeRelayRemoteUnlockSession: Codable, Sendable, Equatable {
    public enum Intent: String, Codable, Sendable, Equatable {
        case request
        case attach
        case cancel
    }

    public var requestId: String
    public var sessionId: String?
    public var intent: Intent
    public var requesterDisplayName: String
    public var viewerDeviceId: String?
    public var requestedAt: Date
    public var expiresAt: Date
    public var localAuthenticationSatisfied: Bool
    public var requestedLockState: HermesRealtimeRelayMacLockState?
    public var requestedBackend: HermesRealtimeRelayRemoteUnlockBackend?
    public var authority: HermesRealtimeRelayAuthorityEnvelope

    public init(
        requestId: String,
        sessionId: String? = nil,
        intent: Intent,
        requesterDisplayName: String,
        viewerDeviceId: String? = nil,
        requestedAt: Date,
        expiresAt: Date,
        localAuthenticationSatisfied: Bool,
        requestedLockState: HermesRealtimeRelayMacLockState? = nil,
        requestedBackend: HermesRealtimeRelayRemoteUnlockBackend? = nil,
        authority: HermesRealtimeRelayAuthorityEnvelope
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.intent = intent
        self.requesterDisplayName = requesterDisplayName
        self.viewerDeviceId = viewerDeviceId
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.localAuthenticationSatisfied = localAuthenticationSatisfied
        self.requestedLockState = requestedLockState
        self.requestedBackend = requestedBackend
        self.authority = authority
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case sessionId
        case intent
        case requesterDisplayName
        case viewerDeviceId
        case requestedAt
        case expiresAt
        case localAuthenticationSatisfied
        case requestedLockState
        case requestedBackend
        case authority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self.intent = try container.decode(Intent.self, forKey: .intent)
        self.requesterDisplayName = try container.decode(String.self, forKey: .requesterDisplayName)
        self.viewerDeviceId = try container.decodeIfPresent(String.self, forKey: .viewerDeviceId)
        self.requestedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .requestedAt)
        self.expiresAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .expiresAt)
        self.localAuthenticationSatisfied = try container.decode(Bool.self, forKey: .localAuthenticationSatisfied)
        self.requestedLockState = try container.decodeIfPresent(
            HermesRealtimeRelayMacLockState.self,
            forKey: .requestedLockState
        )
        self.requestedBackend = try container.decodeIfPresent(
            HermesRealtimeRelayRemoteUnlockBackend.self,
            forKey: .requestedBackend
        )
        self.authority = try container.decode(HermesRealtimeRelayAuthorityEnvelope.self, forKey: .authority)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(intent, forKey: .intent)
        try container.encode(requesterDisplayName, forKey: .requesterDisplayName)
        try container.encodeIfPresent(viewerDeviceId, forKey: .viewerDeviceId)
        try container.encode(HermesRealtimeRelayDateCodec.encode(requestedAt), forKey: .requestedAt)
        try container.encode(HermesRealtimeRelayDateCodec.encode(expiresAt), forKey: .expiresAt)
        try container.encode(localAuthenticationSatisfied, forKey: .localAuthenticationSatisfied)
        try container.encodeIfPresent(requestedLockState, forKey: .requestedLockState)
        try container.encodeIfPresent(requestedBackend, forKey: .requestedBackend)
        try container.encode(authority, forKey: .authority)
    }
}

public struct HermesRealtimeRelayRemoteUnlockState: Codable, Sendable, Equatable {
    public var sessionId: String?
    public var lockState: HermesRealtimeRelayMacLockState
    public var backend: HermesRealtimeRelayRemoteUnlockBackend
    public var capabilities: HermesRealtimeRelayRemoteUnlockCapabilities
    public var controlOwnerViewerId: String?
    public var observedAt: Date

    public init(
        sessionId: String? = nil,
        lockState: HermesRealtimeRelayMacLockState,
        backend: HermesRealtimeRelayRemoteUnlockBackend,
        capabilities: HermesRealtimeRelayRemoteUnlockCapabilities,
        controlOwnerViewerId: String? = nil,
        observedAt: Date
    ) {
        self.sessionId = sessionId
        self.lockState = lockState
        self.backend = backend
        self.capabilities = capabilities
        self.controlOwnerViewerId = controlOwnerViewerId
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case lockState
        case backend
        case capabilities
        case controlOwnerViewerId
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self.lockState = try container.decode(HermesRealtimeRelayMacLockState.self, forKey: .lockState)
        self.backend = try container.decode(HermesRealtimeRelayRemoteUnlockBackend.self, forKey: .backend)
        self.capabilities = try container.decode(
            HermesRealtimeRelayRemoteUnlockCapabilities.self,
            forKey: .capabilities
        )
        self.controlOwnerViewerId = try container.decodeIfPresent(String.self, forKey: .controlOwnerViewerId)
        self.observedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .observedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(lockState, forKey: .lockState)
        try container.encode(backend, forKey: .backend)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(controlOwnerViewerId, forKey: .controlOwnerViewerId)
        try container.encode(HermesRealtimeRelayDateCodec.encode(observedAt), forKey: .observedAt)
    }
}

public enum HermesRealtimeRelayRemoteUnlockInputAction: String, Codable, CaseIterable, Sendable, Equatable {
    case focusPasswordField = "focus_password_field"
    case submit
    case escape
    case disconnect
    case key
    case pointerMove = "pointer_move"
    case pointerClick = "pointer_click"
}

public struct HermesRealtimeRelayRemoteUnlockInput: Codable, Sendable, Equatable {
    public var requestId: String
    public var sessionId: String
    public var action: HermesRealtimeRelayRemoteUnlockInputAction
    public var key: String?
    public var normalizedX: Double?
    public var normalizedY: Double?
    public var clientIntentId: String
    public var requestedAt: Date
    public var authority: HermesRealtimeRelayAuthorityEnvelope

    public init(
        requestId: String,
        sessionId: String,
        action: HermesRealtimeRelayRemoteUnlockInputAction,
        key: String? = nil,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        clientIntentId: String,
        requestedAt: Date,
        authority: HermesRealtimeRelayAuthorityEnvelope
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.action = action
        self.key = key
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.clientIntentId = clientIntentId
        self.requestedAt = requestedAt
        self.authority = authority
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case sessionId
        case action
        case key
        case normalizedX
        case normalizedY
        case clientIntentId
        case requestedAt
        case authority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.action = try container.decode(HermesRealtimeRelayRemoteUnlockInputAction.self, forKey: .action)
        self.key = try container.decodeIfPresent(String.self, forKey: .key)
        self.normalizedX = try container.decodeIfPresent(Double.self, forKey: .normalizedX)
        self.normalizedY = try container.decodeIfPresent(Double.self, forKey: .normalizedY)
        self.clientIntentId = try container.decode(String.self, forKey: .clientIntentId)
        self.requestedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .requestedAt)
        self.authority = try container.decode(HermesRealtimeRelayAuthorityEnvelope.self, forKey: .authority)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(normalizedX, forKey: .normalizedX)
        try container.encodeIfPresent(normalizedY, forKey: .normalizedY)
        try container.encode(clientIntentId, forKey: .clientIntentId)
        try container.encode(HermesRealtimeRelayDateCodec.encode(requestedAt), forKey: .requestedAt)
        try container.encode(authority, forKey: .authority)
    }
}

public struct HermesRealtimeRelayRemoteUnlockCredentialEnvelope: Codable, Sendable, Equatable {
    public enum CredentialKind: String, Codable, Sendable, Equatable {
        case typedPassword = "typed_password"
        case clipboardPassword = "clipboard_password"
        case savedPassword = "saved_password"
    }

    public var requestId: String
    public var sessionId: String
    public var clientIntentId: String
    public var credentialKind: CredentialKind
    public var recipientKeyId: String
    public var algorithm: String
    public var ciphertextBase64: String
    public var aadBase64: String
    public var redactedByteCount: Int
    public var requestedAt: Date
    public var expiresAt: Date
    public var authority: HermesRealtimeRelayAuthorityEnvelope

    public init(
        requestId: String,
        sessionId: String,
        clientIntentId: String,
        credentialKind: CredentialKind,
        recipientKeyId: String,
        algorithm: String,
        ciphertextBase64: String,
        aadBase64: String,
        redactedByteCount: Int,
        requestedAt: Date,
        expiresAt: Date,
        authority: HermesRealtimeRelayAuthorityEnvelope
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.clientIntentId = clientIntentId
        self.credentialKind = credentialKind
        self.recipientKeyId = recipientKeyId
        self.algorithm = algorithm
        self.ciphertextBase64 = ciphertextBase64
        self.aadBase64 = aadBase64
        self.redactedByteCount = redactedByteCount
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.authority = authority
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case sessionId
        case clientIntentId
        case credentialKind
        case recipientKeyId
        case algorithm
        case ciphertextBase64
        case aadBase64
        case redactedByteCount
        case requestedAt
        case expiresAt
        case authority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.clientIntentId = try container.decode(String.self, forKey: .clientIntentId)
        self.credentialKind = try container.decode(CredentialKind.self, forKey: .credentialKind)
        self.recipientKeyId = try container.decode(String.self, forKey: .recipientKeyId)
        self.algorithm = try container.decode(String.self, forKey: .algorithm)
        self.ciphertextBase64 = try container.decode(String.self, forKey: .ciphertextBase64)
        self.aadBase64 = try container.decode(String.self, forKey: .aadBase64)
        self.redactedByteCount = try container.decode(Int.self, forKey: .redactedByteCount)
        self.requestedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .requestedAt)
        self.expiresAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .expiresAt)
        self.authority = try container.decode(HermesRealtimeRelayAuthorityEnvelope.self, forKey: .authority)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(clientIntentId, forKey: .clientIntentId)
        try container.encode(credentialKind, forKey: .credentialKind)
        try container.encode(recipientKeyId, forKey: .recipientKeyId)
        try container.encode(algorithm, forKey: .algorithm)
        try container.encode(ciphertextBase64, forKey: .ciphertextBase64)
        try container.encode(aadBase64, forKey: .aadBase64)
        try container.encode(redactedByteCount, forKey: .redactedByteCount)
        try container.encode(HermesRealtimeRelayDateCodec.encode(requestedAt), forKey: .requestedAt)
        try container.encode(HermesRealtimeRelayDateCodec.encode(expiresAt), forKey: .expiresAt)
        try container.encode(authority, forKey: .authority)
    }
}

public struct HermesRealtimeRelayRemoteUnlockResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case accepted
        case denied
        case failed
        case expired
        case unlocked
        case disconnected
    }

    public var requestId: String
    public var sessionId: String?
    public var status: Status
    public var lockState: HermesRealtimeRelayMacLockState?
    public var backend: HermesRealtimeRelayRemoteUnlockBackend?
    public var detail: String?
    public var completedAt: Date

    public init(
        requestId: String,
        sessionId: String? = nil,
        status: Status,
        lockState: HermesRealtimeRelayMacLockState? = nil,
        backend: HermesRealtimeRelayRemoteUnlockBackend? = nil,
        detail: String? = nil,
        completedAt: Date
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.status = status
        self.lockState = lockState
        self.backend = backend
        self.detail = detail
        self.completedAt = completedAt
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case sessionId
        case status
        case lockState
        case backend
        case detail
        case completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self.status = try container.decode(Status.self, forKey: .status)
        self.lockState = try container.decodeIfPresent(HermesRealtimeRelayMacLockState.self, forKey: .lockState)
        self.backend = try container.decodeIfPresent(HermesRealtimeRelayRemoteUnlockBackend.self, forKey: .backend)
        self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.completedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .completedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(lockState, forKey: .lockState)
        try container.encodeIfPresent(backend, forKey: .backend)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(HermesRealtimeRelayDateCodec.encode(completedAt), forKey: .completedAt)
    }
}

// MARK: - System Permission Concierge — Phase 14

/// macOS Transparency, Consent, and Control (TCC) buckets the System
/// Permission Concierge knows how to grant remotely. Carried over the
/// existing Computer Use control stream; older peers ignore the new
/// frame types because the outer envelope is forward-compatible.
public enum HermesRealtimeRelaySystemPermissionKind: String, Codable, CaseIterable, Sendable, Equatable {
    case screenRecording = "screen_recording"
    case accessibility
    case camera
    case microphone
    case fullDiskAccess = "full_disk_access"
    case automation
}

/// Live status of a single TCC bucket as observed by the Mac. The Mac
/// emits one frame per (kind, bundleId) change and one optimistic frame
/// when it starts servicing a request.
public enum HermesRealtimeRelaySystemPermissionStatusKind: String, Codable, CaseIterable, Sendable, Equatable {
    case needsAccess = "needs_access"
    case requesting
    case granted
    case denied
    case timeout
    case unknown
}

/// Mac-side action the phone wants run for a permission kind. The Mac
/// receiver gates the action against the bundled `kind`.
public enum HermesRealtimeRelaySystemPermissionAction: String, Codable, CaseIterable, Sendable, Equatable {
    /// Trigger the macOS native prompt (CGRequestScreenCaptureAccess,
    /// AXIsProcessTrustedWithOptions(prompt: true), AVCaptureDevice
    /// requestAccess) when one exists. No-op for FDA.
    case prompt
    /// Open the matching System Settings deep link via NSWorkspace.
    case openSettings = "open_settings"
    /// Native prompt + deep link in one shot. Default behaviour for kinds
    /// that benefit from both (Screen Recording is the canonical case —
    /// the prompt seeds the TCC entry, the deep link finishes the job).
    case promptAndOpenSettings = "prompt_and_open_settings"
    /// Run a polling probe-read only; no UI side effects. Used by the
    /// monitor at startup to populate the latest status without touching
    /// System Settings.
    case probeOnly = "probe_only"
    /// Once the related TCC bucket flips to granted, re-dispatch the
    /// original failed tool call. The Mac honors this only when the
    /// originating tool call is still inflight.
    case retryFailedTool = "retry_failed_tool"
}

public struct HermesRealtimeRelaySystemPermissionRequest: Codable, Sendable, Equatable {
    public var requestId: String
    public var clientIntentId: String
    public var kind: HermesRealtimeRelaySystemPermissionKind
    /// Required for `kind == .automation` (target bundle id, e.g.
    /// `com.apple.Notes`). Optional for all other kinds.
    public var bundleId: String?
    /// Tool call id this request is trying to unblock. Carried verbatim
    /// in the resulting status frames so the iOS retry dispatcher and
    /// the Mac retry hook can pair the request with the original
    /// inflight tool invocation.
    public var originatingToolCallId: String?
    public var originatingToolName: String?
    public var action: HermesRealtimeRelaySystemPermissionAction
    public var requestedAt: Date
    public var authority: HermesRealtimeRelayAuthorityEnvelope

    public init(
        requestId: String,
        clientIntentId: String,
        kind: HermesRealtimeRelaySystemPermissionKind,
        bundleId: String? = nil,
        originatingToolCallId: String? = nil,
        originatingToolName: String? = nil,
        action: HermesRealtimeRelaySystemPermissionAction,
        requestedAt: Date,
        authority: HermesRealtimeRelayAuthorityEnvelope
    ) {
        self.requestId = requestId
        self.clientIntentId = clientIntentId
        self.kind = kind
        self.bundleId = bundleId
        self.originatingToolCallId = originatingToolCallId
        self.originatingToolName = originatingToolName
        self.action = action
        self.requestedAt = requestedAt
        self.authority = authority
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case clientIntentId
        case kind
        case bundleId
        case originatingToolCallId
        case originatingToolName
        case action
        case requestedAt
        case authority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.clientIntentId = try container.decode(String.self, forKey: .clientIntentId)
        self.kind = try container.decode(HermesRealtimeRelaySystemPermissionKind.self, forKey: .kind)
        self.bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId)
        self.originatingToolCallId = try container.decodeIfPresent(String.self, forKey: .originatingToolCallId)
        self.originatingToolName = try container.decodeIfPresent(String.self, forKey: .originatingToolName)
        self.action = try container.decode(HermesRealtimeRelaySystemPermissionAction.self, forKey: .action)
        self.requestedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .requestedAt)
        self.authority = try container.decode(HermesRealtimeRelayAuthorityEnvelope.self, forKey: .authority)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(clientIntentId, forKey: .clientIntentId)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(bundleId, forKey: .bundleId)
        try container.encodeIfPresent(originatingToolCallId, forKey: .originatingToolCallId)
        try container.encodeIfPresent(originatingToolName, forKey: .originatingToolName)
        try container.encode(action, forKey: .action)
        try container.encode(HermesRealtimeRelayDateCodec.encode(requestedAt), forKey: .requestedAt)
        try container.encode(authority, forKey: .authority)
    }
}

public struct HermesRealtimeRelaySystemPermissionStatus: Codable, Sendable, Equatable {
    public var kind: HermesRealtimeRelaySystemPermissionKind
    public var bundleId: String?
    public var status: HermesRealtimeRelaySystemPermissionStatusKind
    public var originatingToolCallId: String?
    public var originatingToolName: String?
    /// System Settings deep link — `x-apple.systempreferences:` URL the
    /// phone displays as a fallback and that the Mac can re-open on its
    /// own when handling a request.
    public var deepLink: String?
    /// Human-readable steps to render in the iOS sheet ("Open System
    /// Settings → Privacy & Security → Screen Recording → toggle
    /// OpenBurnBar"). Optional — iOS has shipped defaults per kind.
    public var instructions: String?
    /// Compact category tag for the classifier or the failing tool
    /// (e.g. `"tccd"`, `"AXIsProcessTrusted"`, `"AppleEvents"`). Used by
    /// telemetry and the Mac audit chain — not surfaced in the iOS sheet.
    public var failureCategory: String?
    public var lastChangedAt: Date

    public init(
        kind: HermesRealtimeRelaySystemPermissionKind,
        bundleId: String? = nil,
        status: HermesRealtimeRelaySystemPermissionStatusKind,
        originatingToolCallId: String? = nil,
        originatingToolName: String? = nil,
        deepLink: String? = nil,
        instructions: String? = nil,
        failureCategory: String? = nil,
        lastChangedAt: Date = Date()
    ) {
        self.kind = kind
        self.bundleId = bundleId
        self.status = status
        self.originatingToolCallId = originatingToolCallId
        self.originatingToolName = originatingToolName
        self.deepLink = deepLink
        self.instructions = instructions
        self.failureCategory = failureCategory
        self.lastChangedAt = lastChangedAt
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case bundleId
        case status
        case originatingToolCallId
        case originatingToolName
        case deepLink
        case instructions
        case failureCategory
        case lastChangedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(HermesRealtimeRelaySystemPermissionKind.self, forKey: .kind)
        self.bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId)
        self.status = try container.decode(HermesRealtimeRelaySystemPermissionStatusKind.self, forKey: .status)
        self.originatingToolCallId = try container.decodeIfPresent(String.self, forKey: .originatingToolCallId)
        self.originatingToolName = try container.decodeIfPresent(String.self, forKey: .originatingToolName)
        self.deepLink = try container.decodeIfPresent(String.self, forKey: .deepLink)
        self.instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        self.failureCategory = try container.decodeIfPresent(String.self, forKey: .failureCategory)
        self.lastChangedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .lastChangedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(bundleId, forKey: .bundleId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(originatingToolCallId, forKey: .originatingToolCallId)
        try container.encodeIfPresent(originatingToolName, forKey: .originatingToolName)
        try container.encodeIfPresent(deepLink, forKey: .deepLink)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encodeIfPresent(failureCategory, forKey: .failureCategory)
        try container.encode(HermesRealtimeRelayDateCodec.encode(lastChangedAt), forKey: .lastChangedAt)
    }
}

public struct HermesRealtimeRelayMediaFrameChunk: Codable, Sendable, Equatable {
    public var chunkId: String
    public var chunkIndex: Int
    public var chunkCount: Int
    public var totalBytes: Int

    public init(
        chunkId: String,
        chunkIndex: Int,
        chunkCount: Int,
        totalBytes: Int
    ) {
        self.chunkId = chunkId
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.totalBytes = totalBytes
    }
}

public enum AgentFocusFollowMode: String, Codable, CaseIterable, Sendable, Equatable {
    case off
    case smart
    case debounced
    case immediate
}

public enum HermesRealtimeRelayFocusTargetKind: String, Codable, Sendable, Equatable {
    case cursor
    case focusedElement = "focused_element"
    case focusedWindow = "focused_window"
    case agentWorkspace = "agent_workspace"
}

public struct HermesRealtimeRelayNormalizedRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct HermesRealtimeRelayNormalizedPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct HermesRealtimeRelayFocusContext: Codable, Sendable, Equatable {
    public var appName: String
    public var bundleId: String
    public var windowTitle: String?
    public var windowId: UInt32?
    /// Smart Zoom target type. Optional so older peers without
    /// Smart Zoom continue to decode the existing focus payload.
    public var targetKind: HermesRealtimeRelayFocusTargetKind?
    /// Display the rect/point belong to. Matches
    /// `HermesRealtimeRelayDisplayDescriptor.id` so the phone can ignore
    /// context that targets a display it is not currently mirroring.
    public var displayId: String?
    /// Target rectangle expressed in display-relative normalized
    /// coordinates `[0...1]`. Used for text-field, window, and agent
    /// workspace targets.
    public var normalizedRect: HermesRealtimeRelayNormalizedRect?
    /// Target point expressed in display-relative normalized
    /// coordinates `[0...1]`. Used for cursor targets where a rect
    /// would be Mac-side guesswork.
    public var normalizedPoint: HermesRealtimeRelayNormalizedPoint?
    /// Provider's confidence in the target. `1.0` for direct AX hits,
    /// lower values for fallbacks like window-from-cursor.
    public var confidence: Double?
    /// Wall-clock timestamp the provider sampled the target. Used by
    /// the phone to age out stale Smart Zoom context.
    public var updatedAt: Date?

    public init(
        appName: String,
        bundleId: String,
        windowTitle: String? = nil,
        windowId: UInt32? = nil,
        targetKind: HermesRealtimeRelayFocusTargetKind? = nil,
        displayId: String? = nil,
        normalizedRect: HermesRealtimeRelayNormalizedRect? = nil,
        normalizedPoint: HermesRealtimeRelayNormalizedPoint? = nil,
        confidence: Double? = nil,
        updatedAt: Date? = nil
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.windowId = windowId
        self.targetKind = targetKind
        self.displayId = displayId
        self.normalizedRect = normalizedRect
        self.normalizedPoint = normalizedPoint
        self.confidence = confidence
        self.updatedAt = updatedAt
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
    /// Mercury Phase 8 — iOS-initiated mirror request envelope. Set on
    /// `media.mirror.request` frames; nil elsewhere.
    public var mirrorRequest: HermesRealtimeRelayMirrorRequest?
    /// Mac → iOS reply envelope. Set on `media.mirror.ack` frames; nil
    /// elsewhere.
    public var mirrorAck: HermesRealtimeRelayMirrorAck?
    /// iOS → Mac request to end an accepted mirror session. Set on
    /// `media.mirror.stop` frames; nil elsewhere.
    public var mirrorStop: HermesRealtimeRelayMirrorStop?
    /// iOS -> Mac request to switch the active mirrored display without
    /// ending the mirror session.
    public var mirrorDisplaySelection: HermesRealtimeRelayMirrorDisplaySelection?
    /// iOS → Mac presence beacon. Set on `media.presence.heartbeat`
    /// frames; nil elsewhere.
    public var presence: HermesRealtimeRelayPresenceHeartbeat?
    /// Phone → Mac request to surface an incoming Mercury call prompt on
    /// the Mac. Set on `media.call.invite` frames; nil elsewhere.
    public var callInvite: HermesRealtimeRelayCallInvite?
    /// Mac → phone response to a call invite. Set on `media.call.ack`
    /// frames; nil elsewhere.
    public var callAck: HermesRealtimeRelayCallAck?
    /// Receiver -> encoder LTR acknowledgement. Set on `media.ltr.ack`
    /// frames; nil elsewhere.
    public var longTermReferenceAck: HermesRealtimeRelayLongTermReferenceAck?
    /// Base64 text of `MediaPacketCodec.encode(MediaFrame)`. Kept as
    /// opaque bytes here so `OpenBurnBarCore` does not depend on the
    /// media target while the transport envelope remains Codable.
    public var encodedFrameBase64: String?
    /// Optional chunk descriptor for large encoded media frames. The
    /// `encodedFrameBase64` field carries the chunk bytes; receivers
    /// reassemble chunks by `chunkId` before decoding the media frame.
    public var frameChunk: HermesRealtimeRelayMediaFrameChunk?
    /// Optional Mac focus-follow context. Additive only: old peers ignore it,
    /// and media frames remain routable solely by `streamClass`.
    public var focusContext: HermesRealtimeRelayFocusContext?

    public init(
        streamClass: String? = nil,
        attachment: HermesRealtimeRelayAttachmentManifest? = nil,
        blobTicket: String? = nil,
        ack: HermesRealtimeRelayMediaAck? = nil,
        mirrorRequest: HermesRealtimeRelayMirrorRequest? = nil,
        mirrorAck: HermesRealtimeRelayMirrorAck? = nil,
        mirrorStop: HermesRealtimeRelayMirrorStop? = nil,
        mirrorDisplaySelection: HermesRealtimeRelayMirrorDisplaySelection? = nil,
        presence: HermesRealtimeRelayPresenceHeartbeat? = nil,
        callInvite: HermesRealtimeRelayCallInvite? = nil,
        callAck: HermesRealtimeRelayCallAck? = nil,
        longTermReferenceAck: HermesRealtimeRelayLongTermReferenceAck? = nil,
        encodedFrameBase64: String? = nil,
        frameChunk: HermesRealtimeRelayMediaFrameChunk? = nil,
        focusContext: HermesRealtimeRelayFocusContext? = nil
    ) {
        self.streamClass = streamClass
        self.attachment = attachment
        self.blobTicket = blobTicket
        self.ack = ack
        self.mirrorRequest = mirrorRequest
        self.mirrorAck = mirrorAck
        self.mirrorStop = mirrorStop
        self.mirrorDisplaySelection = mirrorDisplaySelection
        self.presence = presence
        self.callInvite = callInvite
        self.callAck = callAck
        self.longTermReferenceAck = longTermReferenceAck
        self.encodedFrameBase64 = encodedFrameBase64
        self.frameChunk = frameChunk
        self.focusContext = focusContext
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

/// Mercury Phase 8 — iOS-initiated request asking the Mac to start
/// hosting a screen share (or, in future phases, another mirrorable
/// stream class). The Mac arbitrates via `MercuryRouter` and replies
/// with `HermesRealtimeRelayMirrorAck`. Decision 2 in
/// `project_media_rollout`: the Mac is the only gate. No authority
/// envelope is required — the iroh pairing already authenticates the
/// requester.
/// Optional Phase 12 request to launch an agent's CLI **interactively** in a
/// visible Mac Terminal and pin the mirror to that single Terminal window,
/// rather than mirroring the full display. When present (and `interactive`),
/// the Mac launches `runtimeId`'s CLI, resolves the new Terminal window's
/// `CGWindowID`, and starts a window-pinned capture. Older Mac peers that do
/// not know this field keep their existing full-display mirror behavior.
public struct HermesRealtimeRelayAgentTerminalRequest: Codable, Sendable, Equatable {
    /// CLI runtime identifier (e.g. `codex`, `claude`, `droid`, `forge`,
    /// `antigravity`, `grok`, `hermes`, `pi`). Carried as a string for
    /// forward-compat with runtimes the Mac may not yet recognize.
    public var runtimeId: String
    /// Optional working directory to `cd` into before launching the CLI.
    public var workingDirectory: String?
    /// Whether to launch an interactive REPL/TUI (true) vs a one-shot run.
    /// Only `true` drives the window-pinned focused-terminal flow.
    public var interactive: Bool
    /// Optional model identifier to pass to the CLI.
    public var modelID: String?

    public init(
        runtimeId: String,
        workingDirectory: String? = nil,
        interactive: Bool = true,
        modelID: String? = nil
    ) {
        self.runtimeId = runtimeId
        self.workingDirectory = workingDirectory
        self.interactive = interactive
        self.modelID = modelID
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeId
        case workingDirectory
        case interactive
        case modelID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.runtimeId = try container.decode(String.self, forKey: .runtimeId)
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.interactive = try container.decodeIfPresent(Bool.self, forKey: .interactive) ?? true
        self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runtimeId, forKey: .runtimeId)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encode(interactive, forKey: .interactive)
        try container.encodeIfPresent(modelID, forKey: .modelID)
    }
}

public struct HermesRealtimeRelayMirrorRequest: Codable, Sendable, Equatable {
    /// iOS-generated UUID. Echoed in the ack for correlation.
    public var requestId: String
    /// Clock skew is tolerated by the Mac — informational only.
    public var requestedAt: Date
    /// Display name shown on the Mac's `IncomingCallSheet` ("Alberto's iPhone").
    public var requesterDisplayName: String
    /// Which `MediaStreamClass` the requester wants opened (default
    /// `media.screen.video`). Carried as a string for forward-compat
    /// with future mirrorable surfaces.
    public var streamClass: String
    /// Optional Phase 0/2 streaming probe snapshot from the requester.
    /// Older peers omit this field; the Mac falls back to the last
    /// heartbeat or the existing v1 behavior when it is absent.
    public var streamingCapabilities: HermesRealtimeRelayStreamingCapabilities?
    /// Optional Phase 5 focus-follow preference from the phone. Mac peers
    /// that do not know it keep their existing full-display mirror behavior.
    public var focusFollowMode: String?
    public var viewerId: String?
    public var viewerDeviceId: String?
    public var controlAuthorityPeerNodeId: String?
    /// Optional Remote Unlock request metadata. Presence is not enough to
    /// start unlock; the embedded authority must still validate on the Mac.
    public var remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession?
    /// Optional Phase 12 interactive-CLI request. When present (and
    /// `interactive`), the Mac launches the runtime's CLI in a visible
    /// Terminal and pins the mirror to that single window. Older peers omit
    /// this field and keep the existing full-display mirror behavior.
    public var agentTerminal: HermesRealtimeRelayAgentTerminalRequest?

    public init(
        requestId: String,
        requestedAt: Date,
        requesterDisplayName: String,
        streamClass: String,
        streamingCapabilities: HermesRealtimeRelayStreamingCapabilities? = nil,
        focusFollowMode: String? = nil,
        viewerId: String? = nil,
        viewerDeviceId: String? = nil,
        controlAuthorityPeerNodeId: String? = nil,
        remoteUnlockSession: HermesRealtimeRelayRemoteUnlockSession? = nil,
        agentTerminal: HermesRealtimeRelayAgentTerminalRequest? = nil
    ) {
        self.requestId = requestId
        self.requestedAt = requestedAt
        self.requesterDisplayName = requesterDisplayName
        self.streamClass = streamClass
        self.streamingCapabilities = streamingCapabilities
        self.focusFollowMode = focusFollowMode
        self.viewerId = viewerId
        self.viewerDeviceId = viewerDeviceId
        self.controlAuthorityPeerNodeId = controlAuthorityPeerNodeId
        self.remoteUnlockSession = remoteUnlockSession
        self.agentTerminal = agentTerminal
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case requestedAt
        case requesterDisplayName
        case streamClass
        case streamingCapabilities
        case focusFollowMode
        case viewerId
        case viewerDeviceId
        case controlAuthorityPeerNodeId
        case remoteUnlockSession
        case agentTerminal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.requestedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .requestedAt)
        self.requesterDisplayName = try container.decode(String.self, forKey: .requesterDisplayName)
        self.streamClass = try container.decode(String.self, forKey: .streamClass)
        self.streamingCapabilities = try container.decodeIfPresent(
            HermesRealtimeRelayStreamingCapabilities.self,
            forKey: .streamingCapabilities
        )
        self.focusFollowMode = try container.decodeIfPresent(String.self, forKey: .focusFollowMode)
        self.viewerId = try container.decodeIfPresent(String.self, forKey: .viewerId)
        self.viewerDeviceId = try container.decodeIfPresent(String.self, forKey: .viewerDeviceId)
        self.controlAuthorityPeerNodeId = try container.decodeIfPresent(String.self, forKey: .controlAuthorityPeerNodeId)
        self.remoteUnlockSession = try container.decodeIfPresent(
            HermesRealtimeRelayRemoteUnlockSession.self,
            forKey: .remoteUnlockSession
        )
        self.agentTerminal = try container.decodeIfPresent(
            HermesRealtimeRelayAgentTerminalRequest.self,
            forKey: .agentTerminal
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(HermesRealtimeRelayDateCodec.encode(requestedAt), forKey: .requestedAt)
        try container.encode(requesterDisplayName, forKey: .requesterDisplayName)
        try container.encode(streamClass, forKey: .streamClass)
        try container.encodeIfPresent(streamingCapabilities, forKey: .streamingCapabilities)
        try container.encodeIfPresent(focusFollowMode, forKey: .focusFollowMode)
        try container.encodeIfPresent(viewerId, forKey: .viewerId)
        try container.encodeIfPresent(viewerDeviceId, forKey: .viewerDeviceId)
        try container.encodeIfPresent(controlAuthorityPeerNodeId, forKey: .controlAuthorityPeerNodeId)
        try container.encodeIfPresent(remoteUnlockSession, forKey: .remoteUnlockSession)
        try container.encodeIfPresent(agentTerminal, forKey: .agentTerminal)
    }
}

public struct HermesRealtimeRelayDisplayDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var width: Int
    public var height: Int
    public var isPrimary: Bool

    public init(id: String, name: String, width: Int, height: Int, isPrimary: Bool = false) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.isPrimary = isPrimary
    }
}

/// Mercury Phase 8 — Mac-side reply to a `HermesRealtimeRelayMirrorRequest`.
public struct HermesRealtimeRelayMirrorAck: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable, Equatable {
        case accepted
        case denied
        case coolingDown = "cooling_down"
        case unsupported
        case busy
    }

    public var requestId: String
    public var decision: Decision
    /// Free-text reason surfaced in the iOS Mercury Live sheet banner.
    public var detail: String?
    /// Populated only when `decision == .coolingDown`. Omitted from the
    /// wire form otherwise to preserve byte-identical encoding when the
    /// field is absent (see `MirrorAckEncodingTests`).
    public var cooldownSecondsRemaining: Int?
    public var availableDisplays: [HermesRealtimeRelayDisplayDescriptor]?
    public var selectedDisplayId: String?
    public var sessionId: String?
    public var viewerId: String?
    public var viewerRole: String?
    public var viewerCount: Int?
    public var maxViewers: Int?
    public var controlOwnerViewerId: String?
    public var remoteUnlockState: HermesRealtimeRelayRemoteUnlockState?
    public var remoteUnlockCapabilities: HermesRealtimeRelayRemoteUnlockCapabilities?

    public init(
        requestId: String,
        decision: Decision,
        detail: String? = nil,
        cooldownSecondsRemaining: Int? = nil,
        availableDisplays: [HermesRealtimeRelayDisplayDescriptor]? = nil,
        selectedDisplayId: String? = nil,
        sessionId: String? = nil,
        viewerId: String? = nil,
        viewerRole: String? = nil,
        viewerCount: Int? = nil,
        maxViewers: Int? = nil,
        controlOwnerViewerId: String? = nil,
        remoteUnlockState: HermesRealtimeRelayRemoteUnlockState? = nil,
        remoteUnlockCapabilities: HermesRealtimeRelayRemoteUnlockCapabilities? = nil
    ) {
        self.requestId = requestId
        self.decision = decision
        self.detail = detail
        self.cooldownSecondsRemaining = cooldownSecondsRemaining
        self.availableDisplays = availableDisplays
        self.selectedDisplayId = selectedDisplayId
        self.sessionId = sessionId
        self.viewerId = viewerId
        self.viewerRole = viewerRole
        self.viewerCount = viewerCount
        self.maxViewers = maxViewers
        self.controlOwnerViewerId = controlOwnerViewerId
        self.remoteUnlockState = remoteUnlockState
        self.remoteUnlockCapabilities = remoteUnlockCapabilities
    }
}

public struct HermesRealtimeRelayMirrorDisplaySelection: Codable, Sendable, Equatable {
    public var requestId: String
    public var sessionId: String?
    public var displayId: String
    public var selectedAt: Date

    public init(requestId: String, sessionId: String? = nil, displayId: String, selectedAt: Date = Date()) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.displayId = displayId
        self.selectedAt = selectedAt
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case sessionId
        case displayId
        case selectedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self.displayId = try container.decode(String.self, forKey: .displayId)
        self.selectedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .selectedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(displayId, forKey: .displayId)
        try container.encode(selectedAt, forKey: .selectedAt)
    }
}

/// Mercury Phase 8 — requester-side end signal for an accepted mirror session.
public struct HermesRealtimeRelayMirrorStop: Codable, Sendable, Equatable {
    public var requestId: String
    public var sessionId: String?
    public var stoppedAt: Date
    public var reason: String?

    public init(
        requestId: String,
        sessionId: String? = nil,
        stoppedAt: Date = Date(),
        reason: String? = nil
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.stoppedAt = stoppedAt
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case sessionId
        case stoppedAt
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        self.stoppedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .stoppedAt)
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(stoppedAt, forKey: .stoppedAt)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

/// Mercury phone-originated call invite. This is the cross-platform
/// sibling of the Mac -> phone PushKit/FCM call path: it rides the live
/// `media.control` stream so an already-awake Mac can surface a real
/// incoming-call prompt without needing a cloud wake.
public struct HermesRealtimeRelayCallInvite: Codable, Sendable, Equatable {
    public var requestId: String
    public var requestedAt: Date
    public var requesterDisplayName: String
    /// `"video"` today; kept as a string so future audio-only/group-call
    /// invites do not break older clients.
    public var callKind: String

    public init(
        requestId: String,
        requestedAt: Date,
        requesterDisplayName: String,
        callKind: String = "video"
    ) {
        self.requestId = requestId
        self.requestedAt = requestedAt
        self.requesterDisplayName = requesterDisplayName
        self.callKind = callKind
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case requestedAt
        case requesterDisplayName
        case callKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.requestedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .requestedAt)
        self.requesterDisplayName = try container.decode(String.self, forKey: .requesterDisplayName)
        self.callKind = try container.decodeIfPresent(String.self, forKey: .callKind) ?? "video"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(HermesRealtimeRelayDateCodec.encode(requestedAt), forKey: .requestedAt)
        try container.encode(requesterDisplayName, forKey: .requesterDisplayName)
        try container.encode(callKind, forKey: .callKind)
    }
}

/// Mac-side response to `HermesRealtimeRelayCallInvite`.
public struct HermesRealtimeRelayCallAck: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable, Equatable {
        case accepted
        case denied
        case unsupported
        case busy
    }

    public var requestId: String
    public var decision: Decision
    public var detail: String?

    public init(
        requestId: String,
        decision: Decision,
        detail: String? = nil
    ) {
        self.requestId = requestId
        self.decision = decision
        self.detail = detail
    }
}

public struct HermesRealtimeRelayLongTermReferenceAck: Codable, Sendable, Equatable {
    public var requestId: String?
    public var tokenValue: UInt64
    public var decodedAt: Date

    public init(
        requestId: String? = nil,
        tokenValue: UInt64,
        decodedAt: Date = Date()
    ) {
        self.requestId = requestId
        self.tokenValue = tokenValue
        self.decodedAt = decodedAt
    }

    private enum CodingKeys: String, CodingKey {
        case requestId
        case tokenValue
        case decodedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        self.tokenValue = try container.decode(UInt64.self, forKey: .tokenValue)
        self.decodedAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .decodedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(requestId, forKey: .requestId)
        try container.encode(tokenValue, forKey: .tokenValue)
        try container.encode(HermesRealtimeRelayDateCodec.encode(decodedAt), forKey: .decodedAt)
    }
}

/// Mercury Phase 8 — periodic iOS → Mac beacon so the Mac knows it has
/// a live mirrorable client (used for outbound triggers like "Call
/// iPhone" from the Mac popover). Sent every 60s once the iOS control
/// stream is `live`. Forward-compatible: unknown capability strings are
/// dropped silently by `MercuryPeer.Feature` decoding.
public struct HermesRealtimeRelayPresenceHeartbeat: Codable, Sendable, Equatable {
    public var sentAt: Date
    public var deviceDisplayName: String
    public var capabilities: [String]
    public var blurredWallpaperBase64: String?
    public var peerDeviceId: String?
    public var streamingCapabilities: HermesRealtimeRelayStreamingCapabilities?
    public var remoteUnlockCapabilities: HermesRealtimeRelayRemoteUnlockCapabilities?

    public init(
        sentAt: Date,
        deviceDisplayName: String,
        capabilities: [String],
        blurredWallpaperBase64: String? = nil,
        peerDeviceId: String? = nil,
        streamingCapabilities: HermesRealtimeRelayStreamingCapabilities? = nil,
        remoteUnlockCapabilities: HermesRealtimeRelayRemoteUnlockCapabilities? = nil
    ) {
        self.sentAt = sentAt
        self.deviceDisplayName = deviceDisplayName
        self.capabilities = capabilities
        self.blurredWallpaperBase64 = blurredWallpaperBase64
        self.peerDeviceId = peerDeviceId
        self.streamingCapabilities = streamingCapabilities
        self.remoteUnlockCapabilities = remoteUnlockCapabilities
    }

    private enum CodingKeys: String, CodingKey {
        case sentAt
        case deviceDisplayName
        case displayName
        case capabilities
        case blurredWallpaperBase64
        case peerDeviceId
        case streamingCapabilities
        case remoteUnlockCapabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sentAt = try HermesRealtimeRelayDateCodec.decode(container, forKey: .sentAt)
        let canonicalName = try container.decodeIfPresent(String.self, forKey: .deviceDisplayName)
        let androidAliasName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.deviceDisplayName = canonicalName ?? androidAliasName ?? "Unknown Device"
        self.capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        self.blurredWallpaperBase64 = try container.decodeIfPresent(String.self, forKey: .blurredWallpaperBase64)
        self.peerDeviceId = try container.decodeIfPresent(String.self, forKey: .peerDeviceId)
        self.streamingCapabilities = try container.decodeIfPresent(
            HermesRealtimeRelayStreamingCapabilities.self,
            forKey: .streamingCapabilities
        )
        self.remoteUnlockCapabilities = try container.decodeIfPresent(
            HermesRealtimeRelayRemoteUnlockCapabilities.self,
            forKey: .remoteUnlockCapabilities
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(HermesRealtimeRelayDateCodec.encode(sentAt), forKey: .sentAt)
        try container.encode(deviceDisplayName, forKey: .deviceDisplayName)
        // Android builds before the Phase 0/2 streaming handshake used
        // `displayName`; keep the alias on the wire so they do not tear
        // down the control stream on Mac heartbeats.
        try container.encode(deviceDisplayName, forKey: .displayName)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(blurredWallpaperBase64, forKey: .blurredWallpaperBase64)
        try container.encodeIfPresent(peerDeviceId, forKey: .peerDeviceId)
        try container.encodeIfPresent(streamingCapabilities, forKey: .streamingCapabilities)
        try container.encodeIfPresent(remoteUnlockCapabilities, forKey: .remoteUnlockCapabilities)
    }
}

public enum HermesRealtimeRelayVideoCodec: String, Codable, Sendable, Equatable {
    case av1
    case hevc
    case h264
}

public struct HermesRealtimeRelayVideoCodecCapability: Codable, Sendable, Equatable {
    public var codec: HermesRealtimeRelayVideoCodec
    public var canEncode: Bool
    public var canDecode: Bool
    public var hardwareAccelerated: Bool
    public var lowLatencyEncode: Bool
    public var temporalLayering: Bool
    public var longTermReference: Bool
    public var screenContentCoding: Bool

    public init(
        codec: HermesRealtimeRelayVideoCodec,
        canEncode: Bool,
        canDecode: Bool,
        hardwareAccelerated: Bool,
        lowLatencyEncode: Bool = false,
        temporalLayering: Bool = false,
        longTermReference: Bool = false,
        screenContentCoding: Bool = false
    ) {
        self.codec = codec
        self.canEncode = canEncode
        self.canDecode = canDecode
        self.hardwareAccelerated = hardwareAccelerated
        self.lowLatencyEncode = lowLatencyEncode
        self.temporalLayering = temporalLayering
        self.longTermReference = longTermReference
        self.screenContentCoding = screenContentCoding
    }

    private enum CodingKeys: String, CodingKey {
        case codec
        case canEncode
        case canDecode
        case hardwareAccelerated
        case lowLatencyEncode
        case temporalLayering
        case longTermReference
        case screenContentCoding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.codec = try container.decode(HermesRealtimeRelayVideoCodec.self, forKey: .codec)
        self.canEncode = try container.decodeIfPresent(Bool.self, forKey: .canEncode) ?? false
        self.canDecode = try container.decodeIfPresent(Bool.self, forKey: .canDecode) ?? false
        self.hardwareAccelerated = try container.decodeIfPresent(Bool.self, forKey: .hardwareAccelerated) ?? false
        self.lowLatencyEncode = try container.decodeIfPresent(Bool.self, forKey: .lowLatencyEncode) ?? false
        self.temporalLayering = try container.decodeIfPresent(Bool.self, forKey: .temporalLayering) ?? false
        self.longTermReference = try container.decodeIfPresent(Bool.self, forKey: .longTermReference) ?? false
        self.screenContentCoding = try container.decodeIfPresent(Bool.self, forKey: .screenContentCoding) ?? false
    }
}

public struct HermesRealtimeRelayMediaFrameVersionSupport: Codable, Sendable, Equatable {
    public var supportsV1: Bool
    public var supportsV2: Bool

    public init(supportsV1: Bool = true, supportsV2: Bool = false) {
        self.supportsV1 = supportsV1
        self.supportsV2 = supportsV2
    }

    private enum CodingKeys: String, CodingKey {
        case supportsV1
        case supportsV2
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.supportsV1 = try container.decodeIfPresent(Bool.self, forKey: .supportsV1) ?? true
        self.supportsV2 = try container.decodeIfPresent(Bool.self, forKey: .supportsV2) ?? false
    }
}

public struct HermesRealtimeRelayDatagramCapability: Codable, Sendable, Equatable {
    public var maxPayloadBytes: Int?

    public init(maxPayloadBytes: Int?) {
        self.maxPayloadBytes = maxPayloadBytes
    }
}

public struct HermesRealtimeRelayStreamingCapabilities: Codable, Sendable, Equatable {
    public var codecCapabilities: [HermesRealtimeRelayVideoCodecCapability]
    public var mediaFrameVersions: HermesRealtimeRelayMediaFrameVersionSupport
    public var videoDatagrams: HermesRealtimeRelayDatagramCapability
    public var source: String

    public init(
        codecCapabilities: [HermesRealtimeRelayVideoCodecCapability],
        mediaFrameVersions: HermesRealtimeRelayMediaFrameVersionSupport = .init(),
        videoDatagrams: HermesRealtimeRelayDatagramCapability = .init(maxPayloadBytes: nil),
        source: String
    ) {
        self.codecCapabilities = codecCapabilities
        self.mediaFrameVersions = mediaFrameVersions
        self.videoDatagrams = videoDatagrams
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case codecCapabilities
        case mediaFrameVersions
        case videoDatagrams
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.codecCapabilities = try container.decodeIfPresent(
            [HermesRealtimeRelayVideoCodecCapability].self,
            forKey: .codecCapabilities
        ) ?? []
        self.mediaFrameVersions = try container.decodeIfPresent(
            HermesRealtimeRelayMediaFrameVersionSupport.self,
            forKey: .mediaFrameVersions
        ) ?? .init()
        self.videoDatagrams = try container.decodeIfPresent(
            HermesRealtimeRelayDatagramCapability.self,
            forKey: .videoDatagrams
        ) ?? .init(maxPayloadBytes: nil)
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
    }
}

private enum HermesRealtimeRelayDateCodec {
    static func decode<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> Date {
        if let date = try? container.decode(Date.self, forKey: key) {
            return date
        }
        if let raw = try? container.decode(String.self, forKey: key) {
            let iso8601 = ISO8601DateFormatter()
            iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let iso8601Basic = ISO8601DateFormatter()
            iso8601Basic.formatOptions = [.withInternetDateTime]
            if let date = iso8601.date(from: raw) ?? iso8601Basic.date(from: raw) {
                return date
            }
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Expected Swift JSONEncoder Date number or ISO-8601 date string."
        )
    }

    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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

public struct HermesRealtimeRelayAgentContextTarget: Codable, Sendable, Equatable {
    public var requestId: String
    public var sessionId: String?
    public var runtime: String
    public var threadId: String?
    public var displayId: String?
    public var normalizedX: Double
    public var normalizedY: Double
    public var normalizedRect: HermesRealtimeRelayNormalizedRect?
    public var instruction: String
    public var focusContext: HermesRealtimeRelayFocusContext?
    public var clientIntentId: String
    public var requestedAt: Date
    public var authority: HermesRealtimeRelayAuthorityEnvelope

    public init(
        requestId: String,
        sessionId: String? = nil,
        runtime: String,
        threadId: String? = nil,
        displayId: String? = nil,
        normalizedX: Double,
        normalizedY: Double,
        normalizedRect: HermesRealtimeRelayNormalizedRect? = nil,
        instruction: String,
        focusContext: HermesRealtimeRelayFocusContext? = nil,
        clientIntentId: String,
        requestedAt: Date,
        authority: HermesRealtimeRelayAuthorityEnvelope
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.runtime = runtime
        self.threadId = threadId
        self.displayId = displayId
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedRect = normalizedRect
        self.instruction = instruction
        self.focusContext = focusContext
        self.clientIntentId = clientIntentId
        self.requestedAt = requestedAt
        self.authority = authority
    }
}
