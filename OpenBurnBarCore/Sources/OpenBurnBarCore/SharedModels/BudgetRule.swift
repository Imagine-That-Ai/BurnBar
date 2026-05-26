import Foundation

// MARK: - BudgetRuleScope

/// Where this budget rule applies. `BudgetGate` evaluates every matching scope when
/// deciding whether to allow / warn / block a request; the most restrictive outcome wins.
public enum BudgetRuleScope: String, Codable, CaseIterable, Hashable, Sendable {
    /// Limit on a specific `(providerID, accountID)` credential. The user's primary lever
    /// for "stop spending on this OpenRouter key at $50/mo."
    case credential
    /// Limit on a specific project name (free-text `token_usage.projectName`).
    case project
    /// Single ceiling across all per-usage credentials. Cheap to add given the per-credential
    /// ledger is the source of truth.
    case global
    /// Org-wide rule synced via Firestore (Phase 8). Enforced locally on each seat against
    /// its own ledger; seat operators cannot disable but can request increases.
    case organization
}

// MARK: - BudgetPeriod

/// Reset cadence for a rule's running spend.
public enum BudgetPeriod: String, Codable, CaseIterable, Hashable, Sendable {
    case day
    case week
    case month
    case allTime

    /// Returns the inclusive lower bound (the start of the current window) for a given
    /// reference time. Used by `BudgetLedger` to slice `token_usage` rows.
    public func windowStart(reference: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .day:
            return calendar.startOfDay(for: reference)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: reference)?.start
                ?? calendar.date(byAdding: .day, value: -7, to: reference)
        case .month:
            return calendar.dateInterval(of: .month, for: reference)?.start
                ?? calendar.date(byAdding: .month, value: -1, to: reference)
        case .allTime:
            return nil
        }
    }

    /// Returns the next reset boundary (when the running total resets to zero). `nil` for
    /// `.allTime` since that period never resets.
    public func nextReset(reference: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .day:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference))
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: reference) else { return nil }
            return interval.end
        case .month:
            guard let interval = calendar.dateInterval(of: .month, for: reference) else { return nil }
            return interval.end
        case .allTime:
            return nil
        }
    }
}

// MARK: - BudgetBehavior

/// What `BudgetGate` does when a rule's running spend meets or exceeds its limit.
public enum BudgetBehavior: String, Codable, CaseIterable, Hashable, Sendable {
    /// Emit a one-shot warning at 80% (debounced per-period) and hard-block at 100%.
    /// The user-recommended default per the planning conversation.
    case warnThenBlock
    /// Block immediately at 100% with no warning grace period.
    case hardBlock
    /// Fire the 80% / 100% notifications but always let the request through. Pure observability.
    case warnOnly
    /// Hard-block at 100% AND auto-promote the configured fallback credential(s) on the same
    /// request. Keeps work flowing while still enforcing the cap.
    case hardBlockWithFallback
}

// MARK: - BudgetBillingMode

/// Whether the credential being charged costs marginal $ per token or runs on a flat-rate plan.
/// Subscription credentials short-circuit `BudgetGate.evaluate` to `.allow` so a Claude Pro
/// OAuth key never gets blocked by these limits.
public enum BudgetBillingMode: String, Codable, CaseIterable, Hashable, Sendable {
    case perUsage
    case subscription
    case unknown
}

// MARK: - BudgetRule

/// User-configured spending limit. Persisted in `budget_rules` and synced via `CloudSync`
/// once Phase 8 wires the org-level rollup.
public struct BudgetRule: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var scope: BudgetRuleScope
    /// Free-form identifier joined with `providerID`/`accountID`/`projectName` depending on
    /// scope. Kept as a single column so `.organization` rules can carry arbitrary keys
    /// without schema churn.
    public var identifier: String?
    /// For credential-scope rules: the `ProviderID.rawValue` (e.g. "anthropic", "openai",
    /// "openrouter").
    public var providerID: String?
    /// For credential-scope rules: the hashed partition token from `token_usage.providerAccountID`.
    public var accountID: String?
    /// For project-scope rules: the raw `token_usage.projectName` string.
    public var projectName: String?
    /// Human-facing label. Falls back to a synthesized name when nil.
    public var label: String?
    /// Spending ceiling in USD.
    public var amountUSD: Double
    public var period: BudgetPeriod
    public var behavior: BudgetBehavior
    /// Optional ordered list of credential rule IDs to promote when this rule blocks
    /// (only honored when `behavior == .hardBlockWithFallback`).
    public var fallbackCredentialIDs: [String]
    /// When non-nil and in the future, `BudgetGate.evaluate` short-circuits to `.allow` for
    /// this rule. Lets Hermes / Settings temporarily pause enforcement.
    public var pausedUntil: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var syncedAt: Date?
    public var sourceDeviceID: String?
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        scope: BudgetRuleScope,
        identifier: String? = nil,
        providerID: String? = nil,
        accountID: String? = nil,
        projectName: String? = nil,
        label: String? = nil,
        amountUSD: Double,
        period: BudgetPeriod,
        behavior: BudgetBehavior = .warnThenBlock,
        fallbackCredentialIDs: [String] = [],
        pausedUntil: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        syncedAt: Date? = nil,
        sourceDeviceID: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.scope = scope
        self.identifier = identifier
        self.providerID = providerID
        self.accountID = accountID
        self.projectName = projectName
        self.label = label
        self.amountUSD = amountUSD
        self.period = period
        self.behavior = behavior
        self.fallbackCredentialIDs = fallbackCredentialIDs
        self.pausedUntil = pausedUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.syncedAt = syncedAt
        self.sourceDeviceID = sourceDeviceID
        self.isEnabled = isEnabled
    }

    /// Returns a human-facing label. Synthesizes one when `label` is nil so views never
    /// have to guard on it.
    public var displayLabel: String {
        if let label, !label.isEmpty { return label }
        switch scope {
        case .credential:
            let providerName = providerID ?? "credential"
            if let accountID, !accountID.isEmpty {
                return "\(providerName) · …\(accountID.suffix(6))"
            }
            return "\(providerName) · default"
        case .project:
            return projectName ?? "Unnamed project"
        case .global:
            return "All per-usage credentials"
        case .organization:
            return identifier ?? "Organization"
        }
    }

    /// True when `pausedUntil` is set and still in the future.
    public func isPaused(at reference: Date = Date()) -> Bool {
        if let pausedUntil { return pausedUntil > reference }
        return false
    }
}

// MARK: - BudgetEventKind

/// Append-only audit log entry kinds. Feeds `burnbar_budget_audit` and the in-app event
/// inspector.
public enum BudgetEventKind: String, Codable, CaseIterable, Hashable, Sendable {
    case warning
    case block
    case override
    case pause
    case resume
    case ruleCreated
    case ruleUpdated
    case ruleDeleted
}

// MARK: - BudgetEvent

/// Single immutable audit-log row.
public struct BudgetEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var ruleID: String
    public var kind: BudgetEventKind
    /// Where this event originated — "settings_ui", "hermes_tool", "mcp_tool", "auto_gate",
    /// "billing_reconciliation". Free-form so future sources don't require schema changes.
    public var source: String?
    public var amountAtEvent: Double
    public var limitAtEvent: Double
    public var detailJSON: String?
    public var occurredAt: Date
    public var syncedAt: Date?
    public var sourceDeviceID: String?

    public init(
        id: String = UUID().uuidString,
        ruleID: String,
        kind: BudgetEventKind,
        source: String? = nil,
        amountAtEvent: Double,
        limitAtEvent: Double,
        detailJSON: String? = nil,
        occurredAt: Date = Date(),
        syncedAt: Date? = nil,
        sourceDeviceID: String? = nil
    ) {
        self.id = id
        self.ruleID = ruleID
        self.kind = kind
        self.source = source
        self.amountAtEvent = amountAtEvent
        self.limitAtEvent = limitAtEvent
        self.detailJSON = detailJSON
        self.occurredAt = occurredAt
        self.syncedAt = syncedAt
        self.sourceDeviceID = sourceDeviceID
    }
}

// MARK: - BudgetCredentialIdentity

/// Unified credential handle used by `BudgetGate` to look up matching rules. Bridges
/// the daemon plane (`BurnBarProviderRoute.credentialSlotID` + `providerID`) and the
/// AgentLens plane (raw bearer token → hashed slot ID).
public struct BudgetCredentialIdentity: Hashable, Sendable {
    public let providerID: String
    public let slotID: String
    public let displayLabel: String
    public let billingMode: BudgetBillingMode

    public init(
        providerID: String,
        slotID: String,
        displayLabel: String,
        billingMode: BudgetBillingMode = .unknown
    ) {
        self.providerID = providerID
        self.slotID = slotID
        self.displayLabel = displayLabel
        self.billingMode = billingMode
    }

    /// Derives `BudgetBillingMode` from a raw secret prefix. Anthropic OAuth keys
    /// (`sk-ant-oat*`) are subscription identities and must never be gated; Console keys
    /// (`sk-ant-api*`) and bearer-style OpenAI keys (`sk-*`) are per-usage.
    public static func billingMode(forSecretPrefix prefix: String) -> BudgetBillingMode {
        let lower = prefix.lowercased()
        if lower.hasPrefix("sk-ant-oat") { return .subscription }
        if lower.hasPrefix("sk-ant-api") { return .perUsage }
        if lower.hasPrefix("sk-") { return .perUsage }
        return .unknown
    }
}

// MARK: - BudgetGateDecision

/// `BudgetGate.evaluate` outcome. Pure data — callers translate into 402 / chat error /
/// header attachment.
public enum BudgetGateDecision: Hashable, Sendable {
    /// Default — request flows through with no gate intervention.
    case allow
    /// Pass-through, but a header / chip should be attached so the chat surface can render
    /// "you're at \(usedPercent)% of \(rule.displayLabel)."
    case warn(rule: BudgetRule, usedPercent: Double, used: Double, limit: Double)
    /// Hard block. Caller should return 402 (daemon) or throw `BudgetBlockedError` (AgentLens).
    /// `fallback` is the next candidate credential when `rule.behavior == .hardBlockWithFallback`.
    case block(rule: BudgetRule, used: Double, limit: Double, fallback: BudgetCredentialIdentity?)
    /// Rule is enforcement-eligible but currently paused (e.g. Hermes set a 1-hour bypass).
    /// Treated as allow but surfaced separately for telemetry.
    case paused(rule: BudgetRule, resumeAt: Date)
}
