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

    public init(
        mode: String,
        trustMode: String,
        scopeRuleIds: [String] = [],
        phoneViewerNodeId: String? = nil,
        macHostNodeId: String? = nil,
        actionCap: Int = 50,
        sessionTimeoutSeconds: Int = 1800,
        clientID: BurnBarClientID,
        runID: BurnBarRunID? = nil
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

    public init(sessionId: String, invocation: BurnBarToolInvocation) {
        self.sessionId = sessionId
        self.invocation = invocation
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
    public let result: BurnBarToolResult?

    public init(
        sessionId: String,
        callID: String,
        status: Status,
        approvalId: String? = nil,
        denyReason: String? = nil,
        auditEntryIndex: Int? = nil,
        auditHeadHashHex: String? = nil,
        result: BurnBarToolResult? = nil
    ) {
        self.sessionId = sessionId
        self.callID = callID
        self.status = status
        self.approvalId = approvalId
        self.denyReason = denyReason
        self.auditEntryIndex = auditEntryIndex
        self.auditHeadHashHex = auditHeadHashHex
        self.result = result
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

    public init(sessionId: String, includeScreenshots: Bool = true) {
        self.sessionId = sessionId
        self.includeScreenshots = includeScreenshots
    }
}

public struct ComputerUseAuditExportResponse: Codable, Hashable, Sendable {
    public let sessionId: String
    public let archiveURL: String
    public let archiveSizeBytes: Int64
    public let entryCount: Int
    public let headHashHex: String
    public let openTimestampsProofBase64: String?

    public init(
        sessionId: String,
        archiveURL: String,
        archiveSizeBytes: Int64,
        entryCount: Int,
        headHashHex: String,
        openTimestampsProofBase64: String? = nil
    ) {
        self.sessionId = sessionId
        self.archiveURL = archiveURL
        self.archiveSizeBytes = archiveSizeBytes
        self.entryCount = entryCount
        self.headHashHex = headHashHex
        self.openTimestampsProofBase64 = openTimestampsProofBase64
    }
}

/// Server-side document shape mirrored to Firestore for cross-device
/// visibility (the phone reads the header — never the full chain).
public struct ComputerUseSessionDocSnapshot: Codable, Hashable, Sendable {
    public let sessionId: String
    public let userId: String
    public let mode: String
    public let trustMode: String
    public let startedAt: Date
    public let endedAt: Date?
    public let endReason: String?
    public let actionCount: Int
    public let approvalCount: Int
    public let rejectionCount: Int
    public let panicHaltCount: Int
    public let visionSpendUSD: Double
    public let manifestHashHex: String
    public let auditHeadHashHex: String?

    public init(
        sessionId: String,
        userId: String,
        mode: String,
        trustMode: String,
        startedAt: Date,
        endedAt: Date? = nil,
        endReason: String? = nil,
        actionCount: Int = 0,
        approvalCount: Int = 0,
        rejectionCount: Int = 0,
        panicHaltCount: Int = 0,
        visionSpendUSD: Double = 0,
        manifestHashHex: String,
        auditHeadHashHex: String? = nil
    ) {
        self.sessionId = sessionId
        self.userId = userId
        self.mode = mode
        self.trustMode = trustMode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.actionCount = actionCount
        self.approvalCount = approvalCount
        self.rejectionCount = rejectionCount
        self.panicHaltCount = panicHaltCount
        self.visionSpendUSD = visionSpendUSD
        self.manifestHashHex = manifestHashHex
        self.auditHeadHashHex = auditHeadHashHex
    }
}
