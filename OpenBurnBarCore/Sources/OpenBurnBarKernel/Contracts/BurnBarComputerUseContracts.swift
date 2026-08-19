import Foundation

// MARK: - Daemon ⇄ Mac socket RPC for Computer Use
//
// The Mac app drives session lifecycle via socket RPC to the daemon —
// the same shape as `BurnBarRPCContracts.swift` uses for run + approval
// requests. Wire-stable Codable structs. See
// `plans/2026-05-16-computer-use-master-plan.md` § B.3.

/// Open a new Computer Use session. The daemon validates entitlement,
/// allocates a `ComputerUseSessionID`, writes the manifest into the
/// audit directory, and replies with the seeded chain head hash so the
/// Mac UI can render "Audit · b3:<hex>" immediately.
/// T-DMN-04: provision the daemon's pinned phone-control verifying key for a
/// source device. The first-party Mac app calls this once per paired phone so
/// the daemon can independently verify local-auth proofs.
public struct DaemonPhoneControlPinProvisionRequest: Codable, Hashable, Sendable {
    public let deviceId: String
    /// Stable transport peer identity used by signed action-authority envelopes.
    /// This can differ from the platform source-device document id.
    public let peerNodeId: String?
    /// Base64 of the canonical published public-key bytes (32-byte raw for
    /// Ed25519, 65-byte X9.63 for SE-P256).
    public let publicKeyBase64: String
    public let keyKind: PhoneControlSigningKeyKind

    public init(
        deviceId: String,
        peerNodeId: String? = nil,
        publicKeyBase64: String,
        keyKind: PhoneControlSigningKeyKind = .ed25519
    ) {
        self.deviceId = deviceId
        self.peerNodeId = peerNodeId
        self.publicKeyBase64 = publicKeyBase64
        self.keyKind = keyKind
    }
}

public struct DaemonPhoneControlPinProvisionResponse: Codable, Hashable, Sendable {
    public let pinned: Bool
    public let deviceId: String

    public init(pinned: Bool, deviceId: String) {
        self.pinned = pinned
        self.deviceId = deviceId
    }
}

/// Non-secret grant metadata the daemon uses to recompute the local-auth proof
/// intent hash. Keeping the signable fields on the socket prevents the daemon
/// from trusting a caller-supplied hash for high-risk Computer Use session
/// starts.
public struct ComputerUseLocalAuthGrantBinding: Codable, Hashable, Sendable {
    public let requestId: String
    public let runtime: String
    public let threadId: String
    public let preset: String
    public let capabilities: [String]
    public let trustMode: String
    public let deliveryMode: String
    public let requestedAt: Date
    public let expiresAt: Date
    public let grantDurationSeconds: Double
    public let sourceDeviceId: String
    public let clientIntentId: String
    public let localAuthenticationSatisfied: Bool

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
        localAuthenticationSatisfied: Bool
    ) {
        self.requestId = requestId
        self.runtime = runtime
        self.threadId = threadId
        self.preset = preset
        self.capabilities = capabilities.sorted()
        self.trustMode = trustMode
        self.deliveryMode = deliveryMode
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.grantDurationSeconds = grantDurationSeconds
        self.sourceDeviceId = sourceDeviceId
        self.clientIntentId = clientIntentId
        self.localAuthenticationSatisfied = localAuthenticationSatisfied
    }
}

public enum ComputerUseDesktopOwnerAuthorizationMethod: String, Codable, Hashable, Sendable {
    case linuxDesktopOwner = "linux_desktop_owner"
}

/// Concrete browser execution surface selected for a Computer Use session.
///
/// The legacy wire shape omits this field and therefore continues to mean the
/// daemon-managed Playwright browser. Safari sessions opt in explicitly so the
/// daemon can skip Playwright startup, require an exact run binding on macOS,
/// and route every action through the embedded WebExtension broker.
public enum ComputerUseExecutionSurface: String, Codable, Hashable, Sendable {
    case managedBrowser = "managed_browser"
    case safariExtension = "safari_extension"
}

/// Requests a fresh, desktop-local owner authorization before session start.
/// This is a request only: success, timestamps, and proofs are produced and
/// verified locally by the daemon and are never accepted from the client.
public struct ComputerUseDesktopOwnerAuthorizationRequest: Codable, Hashable, Sendable {
    public let method: ComputerUseDesktopOwnerAuthorizationMethod

    public init(method: ComputerUseDesktopOwnerAuthorizationMethod) {
        self.method = method
    }
}

public struct ComputerUseSessionStartRequest: Codable, Hashable, Sendable {
    public let mode: String  // ComputerUseMode raw value
    public let trustMode: String  // ComputerUseTrustMode raw value
    public let scopeRuleIds: [String]
    public let phoneViewerNodeId: String?
    public let macHostNodeId: String?
    public let actionCap: Int
    public let sessionTimeoutSeconds: Int
    public let clientID: BurnBarClientID
    public let runID: BurnBarRunID?
    /// Exact managed-run call selected by the Linux session handshake.
    public let runCallID: String?
    /// Exact managed-run generation selected by the Linux session handshake.
    public let runGeneration: UInt64?
    /// Explicit execution surface for browser-mode sessions. `nil` preserves
    /// the legacy managed-browser behavior.
    public let executionSurface: ComputerUseExecutionSurface?
    /// Surface-owned session identifier. Safari requires the exact attached
    /// WebExtension session id; managed-browser sessions leave this nil.
    public let executionSurfaceSessionId: String?
    /// Opaque handle for daemon-brokered paired-phone authority. The challenge
    /// id is transport state, not part of the canonical session intent hash.
    /// Linux release clients send this instead of receiving proof material.
    public let grantChallengeId: String?
    /// Additive desktop-local authorization requirement. Phone proof remains
    /// independently mandatory when daemon proof enforcement is enabled.
    public let desktopOwnerAuthorizationRequest: ComputerUseDesktopOwnerAuthorizationRequest?

    /// T-DMN-04 — the single-use, op-hash-bound Ed25519 local-auth proof that
    /// authorizes starting a high-risk computer-use session. The Mac app already
    /// validates this in `PhoneControlAuthorityValidator`; carrying it on the
    /// socket lets the daemon INDEPENDENTLY re-verify it against the PINNED phone
    /// key, so the proof binding survives a compromise of the first-party app.
    /// Optional on the wire: legacy payloads decode it as `nil`, and a daemon with
    /// proof enforcement OFF (unsigned developer builds) ignores it.
    public let localAuthProof: HermesRealtimeRelayAgentGrantLocalAuthProof?
    /// The source device this session-start claims to originate from. The daemon
    /// requires `proof.deviceId == sourceDeviceId`. Optional for wire compat.
    public let sourceDeviceId: String?
    /// The canonical op/intent hash (hex) the daemon is about to honor. The proof
    /// MUST be bound to exactly these bytes. Optional for wire compat; enforced
    /// daemons derive the expected value from `localAuthGrantBinding` and only
    /// accept this field as a consistency hint.
    public let intentHashHex: String?
    /// The canonical grant metadata the daemon hashes independently before
    /// verifying `localAuthProof`. Optional for wire compat; required when daemon
    /// proof enforcement is enabled.
    public let localAuthGrantBinding: ComputerUseLocalAuthGrantBinding?

    public init(
        mode: String,
        trustMode: String,
        scopeRuleIds: [String] = [],
        phoneViewerNodeId: String? = nil,
        macHostNodeId: String? = nil,
        actionCap: Int = 50,
        sessionTimeoutSeconds: Int = 1800,
        clientID: BurnBarClientID,
        runID: BurnBarRunID? = nil,
        runCallID: String? = nil,
        runGeneration: UInt64? = nil,
        executionSurface: ComputerUseExecutionSurface? = nil,
        executionSurfaceSessionId: String? = nil,
        grantChallengeId: String? = nil,
        desktopOwnerAuthorizationRequest: ComputerUseDesktopOwnerAuthorizationRequest? = nil,
        localAuthProof: HermesRealtimeRelayAgentGrantLocalAuthProof? = nil,
        sourceDeviceId: String? = nil,
        intentHashHex: String? = nil,
        localAuthGrantBinding: ComputerUseLocalAuthGrantBinding? = nil
    ) {
        self.mode = mode
        self.trustMode = trustMode
        self.scopeRuleIds = scopeRuleIds
        self.phoneViewerNodeId = phoneViewerNodeId
        self.macHostNodeId = macHostNodeId
        self.actionCap = actionCap
        self.sessionTimeoutSeconds = sessionTimeoutSeconds
        self.clientID = clientID
        self.runID = runID
        self.runCallID = runCallID
        self.runGeneration = runGeneration
        self.executionSurface = executionSurface
        self.executionSurfaceSessionId = executionSurfaceSessionId
        self.grantChallengeId = grantChallengeId
        self.desktopOwnerAuthorizationRequest = desktopOwnerAuthorizationRequest
        self.localAuthProof = localAuthProof
        self.sourceDeviceId = sourceDeviceId
        self.intentHashHex = intentHashHex
        self.localAuthGrantBinding = localAuthGrantBinding
    }
}

public enum ComputerUseSessionGrantBrokerState: String, Codable, Hashable, Sendable {
    case unavailable
    case awaitingPhone = "awaiting_phone"
    case awaitingDesktopOwner = "awaiting_desktop_owner"
    case ready
    case denied
    case expired
    case consumed
}

public enum ComputerUseSessionGrantReadinessReason: String, Codable, Hashable, Sendable {
    case ready
    case brokerUnavailable = "broker_unavailable"
    case transportUnavailable = "transport_unavailable"
    case pairingUnavailable = "pairing_unavailable"
    case proofValidatorUnavailable = "proof_validator_unavailable"
}

/// Non-secret release readiness for the daemon-owned Linux session-grant path.
/// The desktop must not advertise Computer Use as ready until this response is
/// available and affirmative.
public struct ComputerUseSessionGrantReadinessResponse: Codable, Hashable, Sendable {
    public let available: Bool
    public let reason: ComputerUseSessionGrantReadinessReason

    public init(available: Bool, reason: ComputerUseSessionGrantReadinessReason) {
        self.available = available
        self.reason = reason
    }
}

/// Safe metadata used to ask the daemon-owned paired-controller broker for one
/// exact phone grant. Proofs, signatures, and signing keys never appear in this
/// request or its response.
public struct ComputerUseSessionGrantAcquireRequest: Codable, Hashable, Sendable {
    public let sessionRequest: ComputerUseSessionStartRequest

    public init(
        sessionRequest: ComputerUseSessionStartRequest
    ) {
        self.sessionRequest = sessionRequest
    }
}

public struct ComputerUseSessionGrantStatusRequest: Codable, Hashable, Sendable {
    public let challengeId: String

    public init(challengeId: String) {
        self.challengeId = challengeId
    }
}

public struct ComputerUseSessionGrantStatusResponse: Codable, Hashable, Sendable {
    public let challengeId: String
    public let sessionIntentId: String
    public let state: ComputerUseSessionGrantBrokerState
    public let issuedAt: Date
    public let expiresAt: Date
    public let denialReason: String?

    public init(
        challengeId: String,
        sessionIntentId: String,
        state: ComputerUseSessionGrantBrokerState,
        issuedAt: Date,
        expiresAt: Date,
        denialReason: String? = nil
    ) {
        self.challengeId = challengeId
        self.sessionIntentId = sessionIntentId
        self.state = state
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.denialReason = denialReason
    }
}

public struct ComputerUseSessionStartResponse: Codable, Hashable, Sendable {
    public let sessionId: String
    public let manifestHashHex: String
    public let startedAt: Date
    public let entitlementProductId: String
    public let actionCap: Int

    public init(
        sessionId: String,
        manifestHashHex: String,
        startedAt: Date,
        entitlementProductId: String,
        actionCap: Int
    ) {
        self.sessionId = sessionId
        self.manifestHashHex = manifestHashHex
        self.startedAt = startedAt
        self.entitlementProductId = entitlementProductId
        self.actionCap = actionCap
    }
}

/// Invoke a Computer Use tool. Routed through the same daemon socket as
/// existing tools; the daemon's `ComputerUseRunCoordinator` enforces
/// approval + scope + deny matchers before dispatch.
public struct ComputerUseInvokeRequest: Codable, Hashable, Sendable {
    public let sessionId: String
    public let invocation: BurnBarToolInvocation

    /// T-DMN-04 — the single-use, op-hash-bound Ed25519 local-auth proof that
    /// authorizes this high-risk computer-use action. The daemon independently
    /// re-verifies it against the PINNED phone key so the binding survives an
    /// app compromise. Optional on the wire (legacy/dev-build compatible); see
    /// `ComputerUseSessionStartRequest.localAuthProof`.
    public let localAuthProof: HermesRealtimeRelayAgentGrantLocalAuthProof?
    /// The source device this invoke claims to originate from.
    public let sourceDeviceId: String?
    /// The canonical op/intent hash (hex) the daemon is about to honor.
    public let intentHashHex: String?
    /// The canonical grant metadata associated with the proof. Session invokes
    /// normally rely on the already-verified session-start record, but keeping
    /// this on the wire preserves one request shape for future per-action proof
    /// enforcement.
    public let localAuthGrantBinding: ComputerUseLocalAuthGrantBinding?

    public init(
        sessionId: String,
        invocation: BurnBarToolInvocation,
        localAuthProof: HermesRealtimeRelayAgentGrantLocalAuthProof? = nil,
        sourceDeviceId: String? = nil,
        intentHashHex: String? = nil,
        localAuthGrantBinding: ComputerUseLocalAuthGrantBinding? = nil
    ) {
        self.sessionId = sessionId
        self.invocation = invocation
        self.localAuthProof = localAuthProof
        self.sourceDeviceId = sourceDeviceId
        self.intentHashHex = intentHashHex
        self.localAuthGrantBinding = localAuthGrantBinding
    }
}

/// Privacy-safe subset of an on-disk audit entry used for server metering.
/// It deliberately excludes action summaries, descriptors, screenshots, URLs,
/// selectors, coordinates, and other user content.
public struct ComputerUseActionMeteringHeader: Codable, Hashable, Sendable {
    public let entryIndex: Int
    public let actionKind: String
    public let approvedBy: String
    public let scopeRuleId: String?
    public let denyReason: String?
    public let parentEntryHashHex: String
    public let recordedAt: Date

    public init(
        entryIndex: Int,
        actionKind: String,
        approvedBy: String,
        scopeRuleId: String? = nil,
        denyReason: String? = nil,
        parentEntryHashHex: String,
        recordedAt: Date
    ) {
        self.entryIndex = entryIndex
        self.actionKind = actionKind
        self.approvedBy = approvedBy
        self.scopeRuleId = scopeRuleId
        self.denyReason = denyReason
        self.parentEntryHashHex = parentEntryHashHex
        self.recordedAt = recordedAt
    }
}

public struct ComputerUseInvokeResponse: Codable, Hashable, Sendable {
    /// Sub-second outcome categories. `awaitingApproval` means the
    /// dispatcher raised an approval request and the caller should
    /// subscribe to the approval event stream for the resolution.
    public enum Status: String, Codable, Hashable, Sendable {
        case executed
        case denied
        case awaitingApproval = "awaiting_approval"
        case error
    }

    public let sessionId: String
    public let callID: String
    public let status: Status
    public let approvalId: String?
    public let denyReason: String?
    public let auditEntryIndex: Int?
    public let auditHeadHashHex: String?
    public let meteringHeader: ComputerUseActionMeteringHeader?
    public let result: BurnBarToolResult?

    public init(
        sessionId: String,
        callID: String,
        status: Status,
        approvalId: String? = nil,
        denyReason: String? = nil,
        auditEntryIndex: Int? = nil,
        auditHeadHashHex: String? = nil,
        meteringHeader: ComputerUseActionMeteringHeader? = nil,
        result: BurnBarToolResult? = nil
    ) {
        self.sessionId = sessionId
        self.callID = callID
        self.status = status
        self.approvalId = approvalId
        self.denyReason = denyReason
        self.auditEntryIndex = auditEntryIndex
        self.auditHeadHashHex = auditHeadHashHex
        self.meteringHeader = meteringHeader
        self.result = result
    }
}

/// Poll the daemon for Computer Use approval requests that are waiting
/// on a real Mac/phone presenter. The daemon does not make the decision;
/// it only queues the request while the original invoke waits.
public struct ComputerUseApprovalPendingRequest: Codable, Hashable, Sendable {
    public let sessionId: String?

    public init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }
}

public struct ComputerUseRunRequirementSummary: Codable, Equatable, Sendable {
    public let runID: BurnBarRunID
    public let callID: String
    public let clientID: BurnBarClientID
    public let toolKind: BurnBarToolKind
    public let generation: UInt64
    public let requestedAt: Date

    public init(
        runID: BurnBarRunID,
        callID: String,
        clientID: BurnBarClientID,
        toolKind: BurnBarToolKind,
        generation: UInt64,
        requestedAt: Date
    ) {
        self.runID = runID
        self.callID = callID
        self.clientID = clientID
        self.toolKind = toolKind
        self.generation = generation
        self.requestedAt = requestedAt
    }
}

public struct ComputerUseApprovalPendingResponse: Codable, Equatable, Sendable {
    public let requests: [HermesRealtimeRelayApprovalRequest]
    public let runRequirements: [ComputerUseRunRequirementSummary]?
    /// Authoritative lifecycle state for an exact filtered session poll.
    /// `nil` preserves unfiltered polling semantics; filtered polls always
    /// return a concrete value so clients can retire daemon-ended sessions.
    public let sessionActive: Bool?
    /// Linux-native system automation readiness. This is additive and absent
    /// on platforms that do not compose PipeWire capture with daemon input.
    public let systemCapability: ComputerUseSystemCapabilitySnapshot?

    public init(
        requests: [HermesRealtimeRelayApprovalRequest],
        runRequirements: [ComputerUseRunRequirementSummary]? = nil,
        sessionActive: Bool? = nil,
        systemCapability: ComputerUseSystemCapabilitySnapshot? = nil
    ) {
        self.requests = requests
        self.runRequirements = runRequirements
        self.sessionActive = sessionActive
        self.systemCapability = systemCapability
    }
}

public struct ComputerUseSystemCapabilitySnapshot: Codable, Equatable, Sendable {
    public let available: Bool
    public let captureReady: Bool
    public let inputReady: Bool
    public let active: Bool
    public let reason: String
    public let source: String

    public init(
        available: Bool,
        captureReady: Bool,
        inputReady: Bool,
        active: Bool,
        reason: String,
        source: String = "linux-system-runtime"
    ) {
        self.available = available
        self.captureReady = captureReady
        self.inputReady = inputReady
        self.active = active
        self.reason = reason
        self.source = source
    }
}

/// Resolve a queued daemon Computer Use approval. This is the bridge
/// between the Mac approval presenter and the daemon's run coordinator.
public struct ComputerUseApprovalRespondRequest: Codable, Equatable, Sendable {
    public let sessionId: String?
    public let response: HermesRealtimeRelayApprovalResponse

    public init(
        sessionId: String? = nil,
        response: HermesRealtimeRelayApprovalResponse
    ) {
        self.sessionId = sessionId
        self.response = response
    }
}

public struct ComputerUseApprovalRespondResponse: Codable, Hashable, Sendable {
    public let accepted: Bool

    public init(accepted: Bool) {
        self.accepted = accepted
    }
}

/// Halt a running session. Source distinguishes the three independent
/// panic-kill paths (Decision 7).
public struct ComputerUsePanicHaltRequest: Codable, Hashable, Sendable {
    public let sessionId: String
    public let source: String  // ComputerUsePanicSource raw value

    public init(sessionId: String, source: String) {
        self.sessionId = sessionId
        self.source = source
    }
}

public struct ComputerUsePanicHaltResponse: Codable, Hashable, Sendable {
    public let sessionId: String
    public let endedAt: Date
    public let auditHeadHashHex: String

    public init(sessionId: String, endedAt: Date, auditHeadHashHex: String) {
        self.sessionId = sessionId
        self.endedAt = endedAt
        self.auditHeadHashHex = auditHeadHashHex
    }
}

/// Export the on-disk audit chain for a session as a signed tar.gz.
/// Phase 13. The daemon writes the archive to a path under
/// `~/Library/Caches/...` and returns its URL; the Mac UI offers a save
/// sheet from there.
public struct ComputerUseAuditExportRequest: Codable, Hashable, Sendable {
    public let sessionId: String
    /// Whether to include screenshot PNGs in the archive. Defaults to
    /// true; the user can opt out for a chain-only export.
    public let includeScreenshots: Bool
    /// When true, submits the chain digest to OpenTimestamps and writes
    /// `chain.jsonl.ots` beside the session directory before packaging.
    public let anchorOpenTimestamps: Bool

    public init(
        sessionId: String,
        includeScreenshots: Bool = true,
        anchorOpenTimestamps: Bool = false
    ) {
        self.sessionId = sessionId
        self.includeScreenshots = includeScreenshots
        self.anchorOpenTimestamps = anchorOpenTimestamps
    }
}

public struct ComputerUseAuditExportResponse: Codable, Hashable, Sendable {
    public let sessionId: String
    public let archiveURL: String
    public let signatureURL: String?
    public let archiveSizeBytes: Int64
    public let entryCount: Int
    public let headHashHex: String
    public let archiveSHA256Hex: String?
    public let signatureAlgorithm: String?
    public let signatureSignerIdentifier: String?
    public let signatureSignerKind: String?
    public let signatureTrustRoot: String?
    public let signaturePublicKeyBase64: String?
    public let signaturePublicKeySHA256Hex: String?
    public let openTimestampsProofBase64: String?

    public init(
        sessionId: String,
        archiveURL: String,
        signatureURL: String? = nil,
        archiveSizeBytes: Int64,
        entryCount: Int,
        headHashHex: String,
        archiveSHA256Hex: String? = nil,
        signatureAlgorithm: String? = nil,
        signatureSignerIdentifier: String? = nil,
        signatureSignerKind: String? = nil,
        signatureTrustRoot: String? = nil,
        signaturePublicKeyBase64: String? = nil,
        signaturePublicKeySHA256Hex: String? = nil,
        openTimestampsProofBase64: String? = nil
    ) {
        self.sessionId = sessionId
        self.archiveURL = archiveURL
        self.signatureURL = signatureURL
        self.archiveSizeBytes = archiveSizeBytes
        self.entryCount = entryCount
        self.headHashHex = headHashHex
        self.archiveSHA256Hex = archiveSHA256Hex
        self.signatureAlgorithm = signatureAlgorithm
        self.signatureSignerIdentifier = signatureSignerIdentifier
        self.signatureSignerKind = signatureSignerKind
        self.signatureTrustRoot = signatureTrustRoot
        self.signaturePublicKeyBase64 = signaturePublicKeyBase64
        self.signaturePublicKeySHA256Hex = signaturePublicKeySHA256Hex
        self.openTimestampsProofBase64 = openTimestampsProofBase64
    }
}
