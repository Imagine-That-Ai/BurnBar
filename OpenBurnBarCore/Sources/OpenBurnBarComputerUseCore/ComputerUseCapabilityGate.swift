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
    /// The fail-closed audit reservation could not be appended to the
    /// hash chain BEFORE dispatch, so the action was NOT executed. A
    /// durable audit record is mandatory; absence of one denies the action.
    case auditFailure = "audit_failure"
    /// Remote-clipboard read/write attempted without the dedicated,
    /// short-lived clipboard consent. Clipboard is split from the broad
    /// remote-control (allowsSystem) grant: the user can deny clipboard
    /// while keeping screen-share + input. Absence of consent fails closed.
    case clipboardConsentRequired = "clipboard_consent_required"
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
    public let originatedFromPhone: Bool
    /// Whether phone-control intents are subject to the SAME AX deny-region
    /// protection as autonomous-agent input — secure text fields, system auth
    /// sheets, the screen-lock window, etc. **Default `true`** (F3): a remote
    /// controller, even one with a valid Ed25519-signed authority, must not be
    /// able to silently type into a password field. The legacy bypass — for the
    /// narrow case where the operator must drive their own login window — is
    /// preserved only when an operator explicitly opts out via Remote Config
    /// `computer_use_phone_control_respects_deny_regions = false`.
    public let phoneControlRespectsDenyRegions: Bool
    /// Whether the operator has already confirmed control of this phone session
    /// on the Mac/overlay (F3). The FIRST input of a phone session returns
    /// `.allowed(.mac)` so the dispatcher raises the approval sheet — restoring
    /// the documented "approval is the only ground truth" invariant — and the
    /// coordinator sets this `true` after that approval so subsequent inputs flow
    /// as `.phone` and the live mirror stays responsive. Default `false`
    /// (fail-safe: an unconfirmed session requires approval).
    public let phoneSessionFirstActionConfirmed: Bool
    /// Dedicated, short-lived consent for remote-clipboard read/write. This
    /// is a SEPARATE bit from `entitlement.allowsSystem` so the user can
    /// grant screen-share + Mac input yet still deny clipboard. Defaults to
    /// `false` everywhere (fail-closed): existing remote-control grants do
    /// NOT silently include clipboard, and absence is treated as denied.
    public let clipboardConsentGranted: Bool

    public init(
        entitlement: ComputerUseEntitlementSnapshot,
        envelope: ComputerUseBudgetEnvelope,
        usage: ComputerUseQuotaUsage,
        session: ComputerUseSessionState,
        concurrentSessionActive: Bool,
        killSwitch: Bool,
        accessibilityTrusted: Bool,
        originatedFromPhone: Bool = false,
        phoneControlRespectsDenyRegions: Bool = true,
        phoneSessionFirstActionConfirmed: Bool = false,
        clipboardConsentGranted: Bool = false
    ) {
        self.entitlement = entitlement
        self.envelope = envelope
        self.usage = usage
        self.session = session
        self.concurrentSessionActive = concurrentSessionActive
        self.killSwitch = killSwitch
        self.accessibilityTrusted = accessibilityTrusted
        self.originatedFromPhone = originatedFromPhone
        self.phoneControlRespectsDenyRegions = phoneControlRespectsDenyRegions
        self.phoneSessionFirstActionConfirmed = phoneSessionFirstActionConfirmed
        self.clipboardConsentGranted = clipboardConsentGranted
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
        //
        // Direct phone control is a local, paired-device lane. It still has its
        // own feature bit, signed authority, action cap, and kill switch, but
        // it must not depend on the
        // hosted Computer Use subscription being active. Otherwise a paired
        // iPhone can connect and stream the Mac, then every tap is denied as an
        // entitlement failure before dispatch.
        let directPhoneControl = context.originatedFromPhone
            && context.entitlement.allowsPhoneControl
            && context.session.manifest.phoneViewerNodeId?.isEmpty == false
        if !context.entitlement.isActive && !directPhoneControl { return .denied(.entitlement) }
        switch action {
        case .browser:
            if !context.entitlement.allowsBrowser { return .denied(.entitlement) }
        case .macInput, .macInspect:
            if !context.entitlement.allowsSystem { return .denied(.entitlement) }
            if context.originatedFromPhone && !context.entitlement.allowsPhoneControl { return .denied(.entitlement) }
            if !context.accessibilityTrusted { return .denied(.accessibilityRevoked) }
        case .remoteClipboard:
            // Clipboard rides the same remote-control lane (allowsSystem +
            // accessibility + phone-control) AS WELL AS its own dedicated,
            // short-lived consent. The consent is checked LAST so that a
            // missing clipboard grant is reported as `.clipboardConsentRequired`
            // (not `.entitlement`), and so it fails closed when absent.
            if !context.entitlement.allowsSystem { return .denied(.entitlement) }
            if context.originatedFromPhone && !context.entitlement.allowsPhoneControl { return .denied(.entitlement) }
            if !context.accessibilityTrusted { return .denied(.accessibilityRevoked) }
            if !context.clipboardConsentGranted { return .denied(.clipboardConsentRequired) }
        case .phoneIntent:
            if !context.entitlement.allowsPhoneControl { return .denied(.entitlement) }
        }

        // 2. Concurrency.
        if context.concurrentSessionActive { return .denied(.concurrentSession) }

        let skipsMeteredComputerUseCaps = skipsMeteredCapsForDirectPhoneControl(
            action: action,
            context: context
        )

        // Safety caps are never metering. Direct phone control may be local and
        // unbilled, but it is still a remote-control session and must obey the
        // declared action cap and wall-clock timeout.
        if context.session.actionsExecuted >= context.session.manifest.actionCap {
            return .denied(.sessionLimit)
        }
        if context.session.manifest.sessionTimeoutSeconds > 0,
           Date().timeIntervalSince(context.session.manifest.startedAt) >=
           Double(context.session.manifest.sessionTimeoutSeconds) {
            return .denied(.sessionLimit)
        }

        if !skipsMeteredComputerUseCaps {
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
        }

        // 6. Legacy phone escape hatch — explicit operator opt-out ONLY.
        //    A verified phone-control intent is the operator acting in a live
        //    mirror. Historically that short-circuited the AX deny-region and
        //    approval checks so the operator could drive their own locked login
        //    window. That bypass let a remote controller (or anything holding the
        //    controller's signing key) silently type into a password field with
        //    no approval, contradicting the "approval is the only ground truth"
        //    invariant. It now survives ONLY when an operator explicitly sets
        //    `phoneControlRespectsDenyRegions = false` via Remote Config — the
        //    narrow login-window case — and is OFF by default.
        if directPhoneControl && !context.phoneControlRespectsDenyRegions {
            switch action {
            case .macInput, .phoneIntent:
                return .allowed(approvedBy: .phone)
            case .browser, .macInspect, .remoteClipboard:
                break
            }
        }

        // 7. Accessibility deny region beats EVERYTHING — agent, mac, AND phone.
        //    By default (the block above does not fire) a verified phone intent is
        //    now subject to the same protection: even a valid allow rule or a
        //    signed phone authority cannot override a password-field / system
        //    auth-sheet / locked-screen click.
        if accessibilityDeny != nil { return .denied(.denyRegion) }

        // 8. Verified phone input that cleared the deny-region check. Honor the
        //    operator's signed authority WITHOUT applying agent-oriented scope
        //    allow/deny rules (those protect autonomous agent runs, not a human
        //    operator) — but DO require the one-time per-session approval so the
        //    first input of a phone session raises the on-Mac/overlay sheet.
        if directPhoneControl {
            switch action {
            case .macInput, .phoneIntent:
                return phoneControlApproval(context: context)
            case .browser, .macInspect, .remoteClipboard:
                break
            }
        }

        // 9. Scope rules (deny precedence enforced by matcher).
        switch scopeOutcome {
        case .denied: return .denied(.scopeDenied)
        case .allowed:
            if context.originatedFromPhone {
                return phoneControlApproval(context: context)
            }
            // Trusted-mode + allow rule covers approval automatically.
            // Step / Manual modes still need explicit approval; the
            // dispatcher checks the trust mode after this gate returns
            // and either dispatches or raises an approval request.
            if context.session.liveTrustMode == .trusted {
                return .allowed(approvedBy: .trustedScope)
            }
            return .allowed(approvedBy: .mac)
        case .notMatched:
            if context.originatedFromPhone {
                return phoneControlApproval(context: context)
            }
            // Manual / Step / Trusted all fall back to per-action
            // approval here; the dispatcher will pop the sheet.
            return .allowed(approvedBy: .mac)
        }
    }

    /// Approval authority for a verified phone-control action that has already
    /// cleared the kill switch, entitlement, concurrency, cap, and deny-region
    /// checks. The FIRST input of a phone session returns `.mac` so the
    /// dispatcher raises the on-Mac/overlay approval sheet — restoring the
    /// documented "approval is the only ground truth" invariant — and the
    /// coordinator records that confirmation so subsequent inputs return `.phone`
    /// and the live mirror stays responsive.
    private func phoneControlApproval(context: ComputerUseCapabilityContext) -> ComputerUseCapabilityCheck {
        context.phoneSessionFirstActionConfirmed
            ? .allowed(approvedBy: .phone)
            : .allowed(approvedBy: .mac)
    }

    private func skipsMeteredCapsForDirectPhoneControl(
        action: ComputerUseAction,
        context: ComputerUseCapabilityContext
    ) -> Bool {
        guard context.originatedFromPhone else { return false }
        switch action {
        case .macInput, .phoneIntent, .remoteClipboard:
            return true
        case .browser, .macInspect:
            return false
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
