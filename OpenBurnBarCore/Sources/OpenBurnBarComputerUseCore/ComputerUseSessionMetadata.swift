import Foundation
import OpenBurnBarKernel

/// Stable identifier for a Computer Use session. UUID v4 by default; the
/// id ends up on the iroh `control.*` streams, in the audit chain header,
/// and in the Firestore session document. Kept distinct from
/// `BurnBarRunID` because a single agent run can host multiple successive
/// CU sessions (Manual → user halts → Trusted resume).
public struct ComputerUseSessionID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func newRandom() -> Self {
        Self(rawValue: UUID().uuidString)
    }

    public var description: String { rawValue }
}

/// Which surface the session operates on. Picked by the human at session
/// start and pinned for the session's lifetime — switching modes
/// requires ending the current session and starting a new one (Decision 2
/// of the master plan). The wire enum is stable; new modes go at the end.
public enum ComputerUseMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Path A — read-only mirror, the agent runs locally and the phone
    /// watches. No phone-emitted input. The default mode for Phase 8.
    case agentWatch = "agent_watch"

    /// Path B — agent drives a managed Playwright Chromium window. Only
    /// browser-prefixed tool kinds dispatch. Phase 9.
    case browser

    /// Path C — agent drives the whole Mac via `CGEvent` + AX. Requires
    /// Accessibility permission. MAS-build hard-codes this off. Phase 11.
    case system
}

/// Approval granularity. Defaults to `.manual`. Resets to `.manual` when
/// a fresh session is started — `.trusted` is never sticky across
/// sessions (Decision 2, "Trust modes, chosen per session, never per
/// agent").
public enum ComputerUseTrustMode: String, Codable, CaseIterable, Hashable, Sendable, Comparable {
    /// Every action gates through `BurnBarApprovalRequest`. Default.
    case manual

    /// Every action gates, but an approval can opt into a burst window
    /// covering the next N similar actions (≤ 10 actions or 30 s).
    case step

    /// Actions covered by an active scope rule dispatch without
    /// per-action approval; out-of-scope actions fall back to Manual.
    case trusted

    // MARK: Comparable (lowest trust → highest trust: manual < step < trusted)

    public static func < (lhs: ComputerUseTrustMode, rhs: ComputerUseTrustMode) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .manual: return 0
        case .step: return 1
        case .trusted: return 2
        }
    }
}

/// Why a session ended. Reported by `ComputerUseSessionLogger` and to
/// Firestore at session-end so cost / dispute investigations can branch
/// on the cause without reading the full audit chain.
public enum ComputerUseEndReason: String, Codable, CaseIterable, Hashable, Sendable {
    case completed
    case userHalt = "user_halt"
    case panicHotkey = "panic_hotkey"
    case panicPhoneGesture = "panic_phone_gesture"
    case panicMacLock = "panic_mac_lock"
    case panicRemoteConfig = "panic_remote_config"
    case panicAccessibilityRevoked = "panic_accessibility_revoked"
    case timeout
    case entitlementLost = "entitlement_lost"
    case budgetSoftCap = "budget_soft_cap"
    case budgetHardCap = "budget_hard_cap"
    case error
}

/// Source identifier captured on every audit `panicHalted` entry so
/// disputes can trace *which* kill path fired without re-parsing the
/// outer session log.
public enum ComputerUsePanicSource: String, Codable, CaseIterable, Hashable, Sendable {
    case hotkey
    case phoneGesture = "phone_gesture"
    case macLock = "mac_lock"
    case remoteConfig = "remote_config"
    case accessibilityRevoked = "accessibility_revoked"
    case stalled
    /// Device/session trust was revoked (escrow-device revocation or panic
    /// revoke-all); the live session is torn down for auditable forensics.
    case revoked
}

/// Immutable session-start manifest. Hashed by `ComputerUseAuditChain` as
/// the parent-hash for the first audit entry — this binds every entry to
/// the session's declared identity, scope, and trust mode at creation
/// time. Re-deriving the manifest from the live session must reproduce
/// byte-identical canonical JSON, so fields here cannot be mutated post
/// session-start.
public struct ComputerUseSessionManifest: Codable, Hashable, Sendable {
    public let sessionId: ComputerUseSessionID
    public let mode: ComputerUseMode
    public let trustMode: ComputerUseTrustMode
    public let startedAt: Date
    public let userId: String
    /// Daemon agent run bound to this session. When present, it becomes part
    /// of the manifest hash and therefore the root of every action audit entry.
    public let runId: String?
    /// Concrete browser execution surface selected at session admission.
    ///
    /// `nil` preserves the schema-v1 legacy meaning (daemon-managed
    /// Playwright). Safari sessions always persist `.safariExtension` so every
    /// audit entry is rooted in the real-session transport that executed it.
    public let executionSurface: ComputerUseExecutionSurface?
    /// Exact surface-owned session identifier. For Safari this is the leased
    /// WebExtension broker session; it is immutable for the life of the
    /// Computer Use session and prevents a run from switching tabs/surfaces
    /// after the audit root has been committed.
    public let executionSurfaceSessionId: String?
    public let macHostNodeId: String?
    public let phoneViewerNodeId: String?
    public let scopeRuleIds: [String]
    /// Full scope rules for this session. The daemon resolves scope by
    /// evaluating these rules against each browser action's URL. Empty
    /// means no scope restrictions (`.notMatched` → Manual approval).
    public let scopeRules: [ComputerUseScopeRule]
    public let entitlementProductId: String
    public let actionCap: Int
    public let sessionTimeoutSeconds: Int

    public init(
        sessionId: ComputerUseSessionID,
        mode: ComputerUseMode,
        trustMode: ComputerUseTrustMode,
        startedAt: Date,
        userId: String,
        runId: String? = nil,
        executionSurface: ComputerUseExecutionSurface? = nil,
        executionSurfaceSessionId: String? = nil,
        macHostNodeId: String? = nil,
        phoneViewerNodeId: String? = nil,
        scopeRuleIds: [String] = [],
        scopeRules: [ComputerUseScopeRule] = [],
        entitlementProductId: String,
        actionCap: Int,
        sessionTimeoutSeconds: Int
    ) {
        self.sessionId = sessionId
        self.mode = mode
        self.trustMode = trustMode
        self.startedAt = startedAt
        self.userId = userId
        self.runId = runId
        self.executionSurface = executionSurface
        self.executionSurfaceSessionId = executionSurfaceSessionId
        self.macHostNodeId = macHostNodeId
        self.phoneViewerNodeId = phoneViewerNodeId
        self.scopeRuleIds = scopeRuleIds
        self.scopeRules = scopeRules
        self.entitlementProductId = entitlementProductId
        self.actionCap = actionCap
        self.sessionTimeoutSeconds = sessionTimeoutSeconds
    }
}

/// Live mutable session state. The Mac coordinator owns the canonical
/// copy; the phone mirrors a subset. Trust mode is mutable but only
/// downward (Trusted → Step → Manual) once the session is live — the
/// upward path requires Mac UI confirmation (Decision 2 enforcement).
public struct ComputerUseSessionState: Sendable {
    public var sessionId: ComputerUseSessionID
    public var manifest: ComputerUseSessionManifest
    public var liveTrustMode: ComputerUseTrustMode
    public var actionsExecuted: Int
    public var actionsRejected: Int
    public var totalApprovalRoundTripMillis: Double
    public var lastActionAt: Date?
    public var endReason: ComputerUseEndReason?
    public var endedAt: Date?
    public var auditChainHeadHashHex: String?
    public var sessionTokensConsumed: Int

    public init(
        sessionId: ComputerUseSessionID,
        manifest: ComputerUseSessionManifest,
        liveTrustMode: ComputerUseTrustMode,
        actionsExecuted: Int = 0,
        actionsRejected: Int = 0,
        totalApprovalRoundTripMillis: Double = 0,
        lastActionAt: Date? = nil,
        endReason: ComputerUseEndReason? = nil,
        endedAt: Date? = nil,
        auditChainHeadHashHex: String? = nil,
        sessionTokensConsumed: Int = 0
    ) {
        self.sessionId = sessionId
        self.manifest = manifest
        self.liveTrustMode = liveTrustMode
        self.actionsExecuted = actionsExecuted
        self.actionsRejected = actionsRejected
        self.totalApprovalRoundTripMillis = totalApprovalRoundTripMillis
        self.lastActionAt = lastActionAt
        self.endReason = endReason
        self.endedAt = endedAt
        self.auditChainHeadHashHex = auditChainHeadHashHex
        self.sessionTokensConsumed = sessionTokensConsumed
    }
}
