import Foundation

/// Reason an attempted Computer Use action was refused. Carried in the
/// audit chain's `denyReason` field and reported on the `control.denied`
/// stream when the iroh accept-loop refuses to open a control stream.
public enum ComputerUseDenyReason: String, Codable, Sendable, Hashable, CaseIterable {
    /// User does not own the SKU.
    case entitlement
    /// Per-session action cap or wall-clock limit hit.
    case sessionLimit = "session_limit"
    /// Per-day action cap hit across all sessions.
    case dailyLimit = "daily_limit"
    /// Per-day vision spend ceiling hit.
    case dailySpendCeiling = "daily_spend_ceiling"
    /// Hourly budget projection has crossed the soft cap.
    case softCap = "soft_cap"
    /// Hourly budget projection has crossed the hard cap.
    case hardCap = "hard_cap"
    /// Action matched neither an active allow rule nor a built-in deny.
    case scopeNotMatched = "scope_not_matched"
    /// Action matched a deny rule (built-in or user-defined).
    case scopeDenied = "scope_denied"
    /// Action targets a UI region declared off-limits by the
    /// accessibility deny matcher (secure text field, system auth
    /// sheet, etc.).
    case denyRegion = "deny_region"
    /// `computer_use_kill_switch = true` was set in Remote Config.
    case killSwitch = "kill_switch"
    /// Concurrent session attempt while another session is active.
    case concurrentSession = "concurrent_session"
    /// Accessibility permission missing or revoked mid-run.
    case accessibilityRevoked = "accessibility_revoked"
    /// Authority envelope signature failed verification.
    case signatureFailure = "signature_failure"
    /// Authority envelope counter is a replay.
    case counterReplay = "counter_replay"
    /// Authority envelope timestamp is outside the freshness window.
    case staleTimestamp = "stale_timestamp"
    /// User explicitly rejected the action at the approval sheet.
    case userRejected = "user_rejected"
}

/// Outcome returned by `ComputerUseCapabilityGate.check(...)`. The
/// dispatcher consumes this directly. `.allowed` always carries the
/// audit-chain `approvedBy` value the dispatcher should record.
public enum ComputerUseCapabilityCheck: Equatable, Sendable {
    case allowed(approvedBy: ComputerUseAuditEntry.ApprovedBy)
    case denied(ComputerUseDenyReason)
}

/// Daily quota counters mirrored from Firestore + local caches. Pure
/// data — the dispatcher reads it via the capability gate.
public struct ComputerUseQuotaUsage: Codable, Hashable, Sendable {
    public var dayKey: String  // YYYY-MM-DD
    public var browserActionsExecuted: Int
    public var browserActionsRejected: Int
    public var systemActionsExecuted: Int
    public var systemActionsRejected: Int
    public var phoneControlIntentsExecuted: Int
    public var phoneControlIntentsRejected: Int
    public var sessionsStarted: Int
    public var sessionsCompleted: Int
    public var totalSessionSeconds: Int
    public var visionModelSpendUSD: Double
    public var updatedAt: Date?

    public init(
        dayKey: String,
        browserActionsExecuted: Int = 0,
        browserActionsRejected: Int = 0,
        systemActionsExecuted: Int = 0,
        systemActionsRejected: Int = 0,
        phoneControlIntentsExecuted: Int = 0,
        phoneControlIntentsRejected: Int = 0,
        sessionsStarted: Int = 0,
        sessionsCompleted: Int = 0,
        totalSessionSeconds: Int = 0,
        visionModelSpendUSD: Double = 0,
        updatedAt: Date? = nil
    ) {
        self.dayKey = dayKey
        self.browserActionsExecuted = browserActionsExecuted
        self.browserActionsRejected = browserActionsRejected
        self.systemActionsExecuted = systemActionsExecuted
        self.systemActionsRejected = systemActionsRejected
        self.phoneControlIntentsExecuted = phoneControlIntentsExecuted
        self.phoneControlIntentsRejected = phoneControlIntentsRejected
        self.sessionsStarted = sessionsStarted
        self.sessionsCompleted = sessionsCompleted
        self.totalSessionSeconds = totalSessionSeconds
        self.visionModelSpendUSD = visionModelSpendUSD
        self.updatedAt = updatedAt
    }

    public var totalActionsExecuted: Int {
        browserActionsExecuted + systemActionsExecuted
    }
}

/// Live entitlement snapshot. The Mac coordinator subscribes to
/// `MacCloudEntitlementStore.hostedComputerUseEntitlement`; the iOS
/// client mirrors it for informational display only.
public struct ComputerUseEntitlementSnapshot: Codable, Hashable, Sendable {
    public let isActive: Bool
    public let productId: String?
    public let expireAt: Date?
    public let allowsBrowser: Bool
    public let allowsSystem: Bool
    public let allowsPhoneControl: Bool
    public let allowsTrustedScopes: Bool
    public let allowsAuditExport: Bool

    public init(
        isActive: Bool,
        productId: String? = nil,
        expireAt: Date? = nil,
        allowsBrowser: Bool = false,
        allowsSystem: Bool = false,
        allowsPhoneControl: Bool = false,
        allowsTrustedScopes: Bool = false,
        allowsAuditExport: Bool = false
    ) {
        self.isActive = isActive
        self.productId = productId
        self.expireAt = expireAt
        self.allowsBrowser = allowsBrowser
        self.allowsSystem = allowsSystem
        self.allowsPhoneControl = allowsPhoneControl
        self.allowsTrustedScopes = allowsTrustedScopes
        self.allowsAuditExport = allowsAuditExport
    }

    public static let inactive = ComputerUseEntitlementSnapshot(isActive: false)
}

/// Live capability-gate inputs. Built once per `check(...)` call so the
/// gate decision is a pure function of immutable state — the gate has
/// no side effects, so test code can drive every branch from a fixture.
public struct ComputerUseCapabilityContext: Sendable {
    public let entitlement: ComputerUseEntitlementSnapshot
    public let envelope: ComputerUseBudgetEnvelope
    public let usage: ComputerUseQuotaUsage
    public let session: ComputerUseSessionState
    public let concurrentSessionActive: Bool
    public let killSwitch: Bool
    public let accessibilityTrusted: Bool

    public init(
        entitlement: ComputerUseEntitlementSnapshot,
        envelope: ComputerUseBudgetEnvelope,
        usage: ComputerUseQuotaUsage,
        session: ComputerUseSessionState,
        concurrentSessionActive: Bool,
        killSwitch: Bool,
        accessibilityTrusted: Bool
    ) {
        self.entitlement = entitlement
        self.envelope = envelope
        self.usage = usage
        self.session = session
        self.concurrentSessionActive = concurrentSessionActive
        self.killSwitch = killSwitch
        self.accessibilityTrusted = accessibilityTrusted
    }
}

/// The protocol the dispatcher consults before every action. The Mac
/// implementation lives in `AgentLens/Services/ComputerUse/`; tests use
/// a fixture impl that returns whatever outcome the test wants. Sendable
/// so a single instance can be passed across actors.
public protocol ComputerUseCapabilityGate: Sendable {
    func check(
        action: ComputerUseAction,
        scopeOutcome: ComputerUseScopeOutcome,
        accessibilityDeny: ComputerUseAccessibilityDenyReason?,
        context: ComputerUseCapabilityContext
    ) -> ComputerUseCapabilityCheck
}

/// Default capability gate. Pure decision tree shared by Mac + iOS.
/// Order matters — early returns mean "the harshest denial wins."
public struct DefaultComputerUseCapabilityGate: ComputerUseCapabilityGate {
    public init() {}

    public func check(
        action: ComputerUseAction,
        scopeOutcome: ComputerUseScopeOutcome,
        accessibilityDeny: ComputerUseAccessibilityDenyReason?,
        context: ComputerUseCapabilityContext
    ) -> ComputerUseCapabilityCheck {
        // 0. Org-wide kill switch.
        if context.killSwitch { return .denied(.killSwitch) }

        // 1. Entitlement.
        if !context.entitlement.isActive { return .denied(.entitlement) }
        switch action {
        case .browser:
            if !context.entitlement.allowsBrowser { return .denied(.entitlement) }
        case .macInput, .macInspect:
            if !context.entitlement.allowsSystem { return .denied(.entitlement) }
            if !context.accessibilityTrusted { return .denied(.accessibilityRevoked) }
        case .phoneIntent:
            if !context.entitlement.allowsPhoneControl { return .denied(.entitlement) }
        }

        // 2. Concurrency.
        if context.concurrentSessionActive { return .denied(.concurrentSession) }

        // 3. Budget caps (hard > soft).
        if context.envelope.level == .hardCap { return .denied(.hardCap) }
        if context.envelope.level == .softCap && exceedsSoftCap(context: context) {
            return .denied(.softCap)
        }

        // 4. Daily caps.
        if context.usage.totalActionsExecuted >= context.envelope.activeActionsPerDay {
            return .denied(.dailyLimit)
        }
        if context.usage.visionModelSpendUSD >= context.envelope.perUserDailySpendCeilingUSD {
            return .denied(.dailySpendCeiling)
        }

        // 5. Per-session caps.
        if context.session.actionsExecuted >= context.session.manifest.actionCap {
            return .denied(.sessionLimit)
        }

        // 6. Accessibility deny region beats scope outcome — even an
        //    allow rule cannot override a password field click.
        if accessibilityDeny != nil { return .denied(.denyRegion) }

        // 7. Scope rules (deny precedence enforced by matcher).
        switch scopeOutcome {
        case .denied: return .denied(.scopeDenied)
        case .allowed:
            // Trusted-mode + allow rule covers approval automatically.
            // Step / Manual modes still need explicit approval; the
            // dispatcher checks the trust mode after this gate returns
            // and either dispatches or raises an approval request.
            if context.session.liveTrustMode == .trusted {
                return .allowed(approvedBy: .trustedScope)
            }
            return .allowed(approvedBy: .mac)
        case .notMatched:
            // Manual / Step / Trusted all fall back to per-action
            // approval here; the dispatcher will pop the sheet.
            return .allowed(approvedBy: .mac)
        }
    }

    private func exceedsSoftCap(context: ComputerUseCapabilityContext) -> Bool {
        // Soft cap tightens the envelope; if the session has used most
        // of its tightened budget, treat as denied. Bias the threshold
        // by 1 to leave at least one action of headroom after a soft
        // cap engages so the user can finish a coherent step.
        return context.usage.totalActionsExecuted + 1 >= context.envelope.activeActionsPerDay
    }
}
