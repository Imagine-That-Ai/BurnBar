import Foundation

// MARK: - Remote mission authorization (daemon.mission.authorizeRemote)
//
// M2 of the split-brain remediation program
// (docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md, Phase 2). The
// menubar GUI remains the TRANSPORT for remote (mobile/Wand) missions — it
// alone can authenticate to Firebase, attach the listener, and unseal
// cloud-vault payloads — but forwards the DECODED decision inputs to the
// daemon so a single authority issues the trust / approval / capability /
// fan-out verdict. The request deliberately carries a prompt summary + hash
// only: never sealed payloads, never the full prompt.

/// The capability grant a remote mission asks the executor Mac to run with.
/// Doubles as the daemon's authorized CEILING in the response: the ceiling is
/// never wider than the request, and capability identifiers the daemon does
/// not recognize are denied by default (dropped from the ceiling).
public struct BurnBarRemoteMissionCapabilityGrantRequest: Codable, Hashable, Sendable {
    public let commandsAllowed: Bool
    public let fileEditsAllowed: Bool
    /// Forward-compatibility lane for capability identifiers newer clients may
    /// request. Deny-by-default: an authorizer that does not recognize an
    /// identifier never carries it into the authorized ceiling.
    public let additionalCapabilities: [String]

    public init(
        commandsAllowed: Bool,
        fileEditsAllowed: Bool,
        additionalCapabilities: [String] = []
    ) {
        self.commandsAllowed = commandsAllowed
        self.fileEditsAllowed = fileEditsAllowed
        self.additionalCapabilities = additionalCapabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Fail closed: an ABSENT capability key on the wire is a non-grant,
        // never a default-open.
        commandsAllowed = try container.decodeIfPresent(Bool.self, forKey: .commandsAllowed) ?? false
        fileEditsAllowed = try container.decodeIfPresent(Bool.self, forKey: .fileEditsAllowed) ?? false
        additionalCapabilities = try container.decodeIfPresent([String].self, forKey: .additionalCapabilities) ?? []
    }
}

public enum BurnBarRemoteMissionAuthorizationVerdict: String, Codable, CaseIterable, Hashable, Sendable {
    case authorized
    case requiresApproval = "requires_approval"
    case denied
}

public enum BurnBarRemoteMissionDenialReason: String, Codable, CaseIterable, Hashable, Sendable {
    /// The executor device's trust state is a KNOWN not-trusted state.
    case untrustedDevice = "untrusted_device"
    /// The executor device's trust state is unrecognized — fail closed.
    case unknownTrustState = "unknown_trust_state"
    /// The mission's approval handshake was rejected or cancelled.
    case approvalRejected = "approval_rejected"
    /// The requested fan-out exceeds the entitlement tier's parallelism cap.
    case fanOutCapExceeded = "fan_out_cap_exceeded"
    /// The request itself is malformed (e.g. non-positive fan-out count).
    case invalidRequest = "invalid_request"
}

/// The backend/model decision accompanying an authorized verdict. In M2 the
/// daemon carries the requested runtime through unchanged (defaulting to
/// "auto"); actual Wand backend resolution stays GUI-side until execution
/// migrates in M5.
public struct BurnBarRemoteMissionBackendDecision: Codable, Hashable, Sendable {
    public let runtimeID: String
    public let modelID: String?
    public let reason: String

    public init(runtimeID: String, modelID: String? = nil, reason: String) {
        self.runtimeID = runtimeID
        self.modelID = modelID
        self.reason = reason
    }
}

public struct BurnBarRemoteMissionAuthorizeRequest: Codable, Hashable, Sendable {
    /// Firestore mission request document ID.
    public let missionID: String
    /// Device that published the mission (phone/tablet), not the executor.
    public let originDeviceID: String
    /// Origin platform, e.g. "ios" / "android".
    public let originPlatform: String
    /// GUI-reported `escrow_devices.trustState` for THIS executor Mac.
    /// Advisory input only: the daemon applies its own fail-closed policy.
    public let executorTrustState: String
    /// Short human-readable summary — never the full mission prompt.
    public let promptSummary: String
    /// SHA-256 hex of the full decoded prompt, for audit correlation without
    /// carrying the payload across the socket.
    public let promptSHA256: String
    /// Requested runtime/backend identifier (e.g. "codex", "hermes", "auto").
    public let requestedRuntime: String?
    public let requestedModelID: String?
    public let requestedGrant: BurnBarRemoteMissionCapabilityGrantRequest
    /// Persona sandbox envelope decoded by the GUI (`personaScopeJSON`).
    public let personaScope: PersonaScopeEnvelope?
    /// Approval evidence, verbatim from the mission document.
    public let approvalMode: String?
    public let approvalStatus: String?
    public let approverDeviceID: String?
    /// Caller-reported entitlement tier wire name: "none" / "cloud" / "pro" /
    /// "ultra". Advisory only; daemon authorization must use daemon-trusted
    /// entitlement state when deciding fan-out authority.
    public let entitlementTier: String
    /// Sibling count of the mission's Wand fan-out group (1 = solo mission).
    public let requestedFanOutCount: Int
    /// The GUI-resolved trusted Wand fan-out cap for this account, read from the
    /// server-signed Firestore entitlement documents (NOT the advisory
    /// `entitlementTier` wire text). Absent for older GUIs; when present the
    /// daemon treats it as the authoritative cap, clamped to a hard ceiling so a
    /// compromised transport can never widen fan-out past the maximum tier. When
    /// absent the daemon fails closed to the free-tier cap.
    public let trustedFanOutCap: Int?
    public let workingDirectory: String?

    public init(
        missionID: String,
        originDeviceID: String,
        originPlatform: String,
        executorTrustState: String,
        promptSummary: String,
        promptSHA256: String,
        requestedRuntime: String? = nil,
        requestedModelID: String? = nil,
        requestedGrant: BurnBarRemoteMissionCapabilityGrantRequest,
        personaScope: PersonaScopeEnvelope? = nil,
        approvalMode: String? = nil,
        approvalStatus: String? = nil,
        approverDeviceID: String? = nil,
        entitlementTier: String,
        requestedFanOutCount: Int = 1,
        trustedFanOutCap: Int? = nil,
        workingDirectory: String? = nil
    ) {
        self.missionID = missionID
        self.originDeviceID = originDeviceID
        self.originPlatform = originPlatform
        self.executorTrustState = executorTrustState
        self.promptSummary = promptSummary
        self.promptSHA256 = promptSHA256
        self.requestedRuntime = requestedRuntime
        self.requestedModelID = requestedModelID
        self.requestedGrant = requestedGrant
        self.personaScope = personaScope
        self.approvalMode = approvalMode
        self.approvalStatus = approvalStatus
        self.approverDeviceID = approverDeviceID
        self.entitlementTier = entitlementTier
        self.requestedFanOutCount = requestedFanOutCount
        self.trustedFanOutCap = trustedFanOutCap
        self.workingDirectory = workingDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        missionID = try container.decode(String.self, forKey: .missionID)
        originDeviceID = try container.decode(String.self, forKey: .originDeviceID)
        originPlatform = try container.decode(String.self, forKey: .originPlatform)
        executorTrustState = try container.decode(String.self, forKey: .executorTrustState)
        promptSummary = try container.decode(String.self, forKey: .promptSummary)
        promptSHA256 = try container.decode(String.self, forKey: .promptSHA256)
        requestedRuntime = try container.decodeIfPresent(String.self, forKey: .requestedRuntime)
        requestedModelID = try container.decodeIfPresent(String.self, forKey: .requestedModelID)
        requestedGrant = try container.decode(BurnBarRemoteMissionCapabilityGrantRequest.self, forKey: .requestedGrant)
        personaScope = try container.decodeIfPresent(PersonaScopeEnvelope.self, forKey: .personaScope)
        approvalMode = try container.decodeIfPresent(String.self, forKey: .approvalMode)
        approvalStatus = try container.decodeIfPresent(String.self, forKey: .approvalStatus)
        approverDeviceID = try container.decodeIfPresent(String.self, forKey: .approverDeviceID)
        entitlementTier = try container.decode(String.self, forKey: .entitlementTier)
        requestedFanOutCount = try container.decodeIfPresent(Int.self, forKey: .requestedFanOutCount) ?? 1
        // Absent on the wire from an older GUI: fail closed (nil → daemon uses
        // the free-tier cap). A present cap is honored (and hard-clamped) by the
        // daemon policy, never trusted verbatim.
        trustedFanOutCap = try container.decodeIfPresent(Int.self, forKey: .trustedFanOutCap)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
    }
}

public struct BurnBarRemoteMissionAuthorizeResponse: Codable, Hashable, Sendable {
    public let verdict: BurnBarRemoteMissionAuthorizationVerdict
    /// Present exactly when `verdict == .denied`.
    public let deniedReason: BurnBarRemoteMissionDenialReason?
    /// Human-readable explanation for operators/telemetry; never load-bearing.
    public let detail: String?
    /// The authorized capability ceiling (never wider than requested). Present
    /// for `.authorized` and `.requiresApproval` (what WOULD be authorized
    /// once approval lands); absent for `.denied`.
    public let grantCeiling: BurnBarRemoteMissionCapabilityGrantRequest?
    /// Present exactly when `verdict == .authorized`.
    public let backendDecision: BurnBarRemoteMissionBackendDecision?

    public init(
        verdict: BurnBarRemoteMissionAuthorizationVerdict,
        deniedReason: BurnBarRemoteMissionDenialReason? = nil,
        detail: String? = nil,
        grantCeiling: BurnBarRemoteMissionCapabilityGrantRequest? = nil,
        backendDecision: BurnBarRemoteMissionBackendDecision? = nil
    ) {
        self.verdict = verdict
        self.deniedReason = deniedReason
        self.detail = detail
        self.grantCeiling = grantCeiling
        self.backendDecision = backendDecision
    }
}

public struct BurnBarNotificationConfigGetRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarNotificationConfigUpdateRequest: Codable, Hashable, Sendable {
    public let config: BurnBarNotificationConfig

    public init(config: BurnBarNotificationConfig) {
        self.config = config
    }
}

public struct BurnBarNotificationConfigResponse: Codable, Hashable, Sendable {
    public let config: BurnBarNotificationConfig

    public init(config: BurnBarNotificationConfig) {
        self.config = config
    }
}

public struct BurnBarNotificationHealthRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarNotificationHealthResponse: Codable, Hashable, Sendable {
    public let health: BurnBarNotificationHealthSnapshot

    public init(health: BurnBarNotificationHealthSnapshot) {
        self.health = health
    }
}

public struct BurnBarNotificationCommandRequest: Codable, Hashable, Sendable {
    public let command: BurnBarTelegramCommand
    public let arguments: [String]
    public let actor: String

    public init(command: BurnBarTelegramCommand, arguments: [String] = [], actor: String) {
        self.command = command
        self.arguments = arguments
        self.actor = actor
    }
}

public struct BurnBarSimulatorRunRequest: Codable, Hashable, Sendable {
    public let projectSlug: String
    public let scenarioName: String
    public let seed: Int
    public let injectedEvents: [BurnBarControllerEvent]
    public let metadata: BurnBarMetadata

    public init(
        projectSlug: String,
        scenarioName: String,
        seed: Int,
        injectedEvents: [BurnBarControllerEvent] = [],
        metadata: BurnBarMetadata = [:]
    ) {
        self.projectSlug = projectSlug
        self.scenarioName = scenarioName
        self.seed = seed
        self.injectedEvents = injectedEvents
        self.metadata = metadata
    }
}

public struct BurnBarSimulatorListRequest: Codable, Hashable, Sendable {
    public let projectSlug: String?
    public let limit: Int

    public init(projectSlug: String? = nil, limit: Int = 50) {
        self.projectSlug = projectSlug
        self.limit = limit
    }
}

public struct BurnBarSimulatorListResponse: Codable, Hashable, Sendable {
    public let runs: [BurnBarSimulatorRunSnapshot]

    public init(runs: [BurnBarSimulatorRunSnapshot]) {
        self.runs = runs
    }
}

public struct BurnBarSimulatorReplayRequest: Codable, Hashable, Sendable {
    public let runID: BurnBarSimulatorRunID
    public let fromCheckpointID: BurnBarProjectionCheckpointID?
    public let includeEvents: Bool

    public init(
        runID: BurnBarSimulatorRunID,
        fromCheckpointID: BurnBarProjectionCheckpointID? = nil,
        includeEvents: Bool = true
    ) {
        self.runID = runID
        self.fromCheckpointID = fromCheckpointID
        self.includeEvents = includeEvents
    }
}

public struct BurnBarSimulatorRunResponse: Codable, Hashable, Sendable {
    public let run: BurnBarSimulatorRunSnapshot

    public init(run: BurnBarSimulatorRunSnapshot) {
        self.run = run
    }
}

public struct BurnBarProjectionRebuildRequest: Codable, Hashable, Sendable {
    public let projectionNames: [String]
    public let fromCheckpointID: BurnBarProjectionCheckpointID?

    public init(projectionNames: [String], fromCheckpointID: BurnBarProjectionCheckpointID? = nil) {
        self.projectionNames = projectionNames
        self.fromCheckpointID = fromCheckpointID
    }
}

public struct BurnBarProjectionRebuildResponse: Codable, Hashable, Sendable {
    public let status: [BurnBarProjectionStatusSnapshot]

    public init(status: [BurnBarProjectionStatusSnapshot]) {
        self.status = status
    }
}
