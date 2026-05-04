import Foundation

// MARK: - Provider ID

/// Stable provider identity used by account, quota, cloud, and daemon contracts.
///
/// This is intentionally separate from `AgentProvider`, whose raw values are
/// display-oriented and cannot represent catalog-only providers such as OpenAI.
public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = Self.normalize(rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public var description: String { rawValue }

    public static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    public static let anthropic = ProviderID(rawValue: "anthropic")
    public static let claudeCode = ProviderID(rawValue: "claude-code")
    public static let codex = ProviderID(rawValue: "codex")
    public static let openAI = ProviderID(rawValue: "openai")
}

// MARK: - Provider Account Status

public enum ProviderAccountStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case connected
    case disconnected
    case stale
    case error
    case disabled
    case deleted
}

public enum ProviderAccountStorageScope: String, Codable, CaseIterable, Hashable, Sendable {
    case cloudRefreshable = "cloud_refreshable"
    case localOnly = "local_only"
    case deviceKeychain = "device_keychain"
    case serverPrivate = "server_private"
}

public enum ProviderAccountRefreshState: String, Codable, CaseIterable, Hashable, Sendable {
    case connected
    case refreshing
    case stale
    case error
    case disabled
    case localOnly = "local_only"
}

public struct ProviderAccountCredentialDescriptor: Codable, Hashable, Sendable {
    public let credentialKind: CredentialKind
    public let storageScope: ProviderAccountStorageScope
    public let redactedLabel: String

    public init(
        credentialKind: CredentialKind,
        storageScope: ProviderAccountStorageScope,
        redactedLabel: String
    ) {
        self.credentialKind = credentialKind
        self.storageScope = storageScope
        self.redactedLabel = redactedLabel
    }
}

// MARK: - Provider Account Document

public struct ProviderAccountDoc: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let providerID: ProviderID
    public let label: String
    public let identityHint: String?
    public let status: ProviderAccountStatus
    public let credentialKind: CredentialKind
    public let storageScope: ProviderAccountStorageScope
    public let redactedLabel: String
    public let sourceDeviceID: String?
    public let linkedSwitcherProfileID: String?
    public let isDefault: Bool
    public let sortKey: Double
    public let lastValidatedAt: Date?
    public let lastRefreshAt: Date?
    public let lastErrorCode: String?
    public let schemaVersion: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        providerID: ProviderID,
        label: String,
        identityHint: String? = nil,
        status: ProviderAccountStatus,
        credentialKind: CredentialKind,
        storageScope: ProviderAccountStorageScope,
        redactedLabel: String,
        sourceDeviceID: String? = nil,
        linkedSwitcherProfileID: String? = nil,
        isDefault: Bool = false,
        sortKey: Double = 0,
        lastValidatedAt: Date? = nil,
        lastRefreshAt: Date? = nil,
        lastErrorCode: String? = nil,
        schemaVersion: Int = 1,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.identityHint = identityHint
        self.status = status
        self.credentialKind = credentialKind
        self.storageScope = storageScope
        self.redactedLabel = redactedLabel
        self.sourceDeviceID = sourceDeviceID
        self.linkedSwitcherProfileID = linkedSwitcherProfileID
        self.isDefault = isDefault
        self.sortKey = sortKey
        self.lastValidatedAt = lastValidatedAt
        self.lastRefreshAt = lastRefreshAt
        self.lastErrorCode = lastErrorCode
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Provider Account Routing

public enum ProviderRoutingModelCompatibility: String, Codable, CaseIterable, Hashable, Sendable {
    case compatible
    case incompatible
    case unknown
}

public enum ProviderRoutingQuotaState: String, Codable, CaseIterable, Hashable, Sendable {
    case healthy
    case pressure
    case unknown
    case exhausted
    case rateLimited = "rate_limited"
    case authFailed = "auth_failed"
    case coolingDown = "cooling_down"
    case disabled
    case deleted
}

public enum ProviderRoutingRuntimeSignal: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case rateLimited = "rate_limited"
    case quotaExhausted = "quota_exhausted"
    case authFailed = "auth_failed"
    case transientFailure = "transient_failure"
}

public struct ProviderRoutingCandidate: Codable, Identifiable, Hashable, Sendable {
    public let providerID: ProviderID
    public let accountID: String
    public let accountLabel: String
    public let credentialHandle: String
    public let storageScope: ProviderAccountStorageScope
    public let modelCompatibility: ProviderRoutingModelCompatibility
    public var quotaState: ProviderRoutingQuotaState
    public var cooldownUntil: Date?
    public let priority: Int
    public var routingEnabled: Bool
    public var lastUsedAt: Date?
    public var lastFailureCode: String?
    public let localCredentialAvailable: Bool

    public var id: String { "\(providerID.rawValue):\(accountID)" }

    public init(
        providerID: ProviderID,
        accountID: String,
        accountLabel: String,
        credentialHandle: String,
        storageScope: ProviderAccountStorageScope,
        modelCompatibility: ProviderRoutingModelCompatibility = .unknown,
        quotaState: ProviderRoutingQuotaState = .unknown,
        cooldownUntil: Date? = nil,
        priority: Int = 0,
        routingEnabled: Bool = true,
        lastUsedAt: Date? = nil,
        lastFailureCode: String? = nil,
        localCredentialAvailable: Bool = false
    ) {
        self.providerID = providerID
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.credentialHandle = ProviderRoutingPolicy.sanitizedAuditText(credentialHandle)
        self.storageScope = storageScope
        self.modelCompatibility = modelCompatibility
        self.quotaState = quotaState
        self.cooldownUntil = cooldownUntil
        self.priority = priority
        self.routingEnabled = routingEnabled
        self.lastUsedAt = lastUsedAt
        self.lastFailureCode = lastFailureCode.map(ProviderRoutingPolicy.sanitizedAuditText)
        self.localCredentialAvailable = localCredentialAvailable
    }

    public static func defaultLegacyAccount(
        providerID: ProviderID,
        providerLabel: String? = nil,
        credentialHandle: String = "legacy-default",
        localCredentialAvailable: Bool = true
    ) -> ProviderRoutingCandidate {
        ProviderRoutingCandidate(
            providerID: providerID,
            accountID: "default",
            accountLabel: providerLabel ?? "Default",
            credentialHandle: credentialHandle,
            storageScope: .deviceKeychain,
            modelCompatibility: .unknown,
            quotaState: .unknown,
            priority: 0,
            routingEnabled: true,
            localCredentialAvailable: localCredentialAvailable
        )
    }

    public func applying(
        _ signal: ProviderRoutingRuntimeSignal,
        at now: Date = Date(),
        cooldown: TimeInterval = 5 * 60,
        failureCode: String? = nil
    ) -> ProviderRoutingCandidate {
        var copy = self
        copy.lastFailureCode = ProviderRoutingPolicy.sanitizedAuditText(failureCode ?? signal.rawValue)
        switch signal {
        case .success:
            copy.quotaState = .healthy
            copy.cooldownUntil = nil
            copy.lastFailureCode = nil
            copy.lastUsedAt = now
        case .rateLimited:
            copy.quotaState = .rateLimited
            copy.cooldownUntil = now.addingTimeInterval(cooldown)
        case .quotaExhausted:
            copy.quotaState = .exhausted
            copy.cooldownUntil = now.addingTimeInterval(cooldown)
        case .authFailed:
            copy.quotaState = .authFailed
            copy.cooldownUntil = nil
        case .transientFailure:
            copy.quotaState = .coolingDown
            copy.cooldownUntil = now.addingTimeInterval(cooldown)
        }
        return copy
    }
}

public struct ProviderRoutingRequest: Codable, Hashable, Sendable {
    public let modelID: String?
    public let preferredProviderIDs: [ProviderID]
    public let allowProviderFallback: Bool

    public init(
        modelID: String? = nil,
        preferredProviderIDs: [ProviderID] = [],
        allowProviderFallback: Bool = true
    ) {
        self.modelID = modelID
        self.preferredProviderIDs = preferredProviderIDs
        self.allowProviderFallback = allowProviderFallback
    }
}

public enum ProviderRoutingSkipReason: String, Codable, CaseIterable, Hashable, Sendable {
    case providerNotPreferred = "provider_not_preferred"
    case routingDisabled = "routing_disabled"
    case deleted
    case disabled
    case authFailed = "auth_failed"
    case exhausted
    case rateLimited = "rate_limited"
    case coolingDown = "cooling_down"
    case modelIncompatible = "model_incompatible"
    case missingCredential = "missing_credential"
}

public struct ProviderRoutingSkip: Codable, Hashable, Sendable {
    public let providerID: ProviderID
    public let accountID: String
    public let accountLabel: String
    public let reason: ProviderRoutingSkipReason
    public let detail: String

    public init(
        providerID: ProviderID,
        accountID: String,
        accountLabel: String,
        reason: ProviderRoutingSkipReason,
        detail: String
    ) {
        self.providerID = providerID
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.reason = reason
        self.detail = ProviderRoutingPolicy.sanitizedAuditText(detail)
    }
}

public struct ProviderRoutingDecisionEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let modelID: String?
    public let selectedProviderID: ProviderID?
    public let selectedAccountID: String?
    public let selectedAccountLabel: String?
    public let nextFallbackProviderID: ProviderID?
    public let nextFallbackAccountID: String?
    public let nextFallbackAccountLabel: String?
    public let reason: String
    public let skipped: [ProviderRoutingSkip]

    public init(
        id: UUID = UUID(),
        occurredAt: Date,
        modelID: String?,
        selected: ProviderRoutingCandidate?,
        nextFallback: ProviderRoutingCandidate?,
        reason: String,
        skipped: [ProviderRoutingSkip]
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.modelID = modelID
        self.selectedProviderID = selected?.providerID
        self.selectedAccountID = selected?.accountID
        self.selectedAccountLabel = selected?.accountLabel
        self.nextFallbackProviderID = nextFallback?.providerID
        self.nextFallbackAccountID = nextFallback?.accountID
        self.nextFallbackAccountLabel = nextFallback?.accountLabel
        self.reason = ProviderRoutingPolicy.sanitizedAuditText(reason)
        self.skipped = skipped
    }
}

public struct ProviderRoutingDecision: Codable, Hashable, Sendable {
    public let selected: ProviderRoutingCandidate?
    public let nextFallback: ProviderRoutingCandidate?
    public let exhaustedOrCoolingDown: [ProviderRoutingCandidate]
    public let skipped: [ProviderRoutingSkip]
    public let event: ProviderRoutingDecisionEvent

    public var activeAccountLabel: String? { selected?.accountLabel }
    public var lastSwitchReason: String { event.reason }
}

public struct ProviderRoutingStateSnapshot: Codable, Hashable, Sendable {
    public let activeAccount: ProviderRoutingCandidate?
    public let nextFallback: ProviderRoutingCandidate?
    public let exhaustedOrCoolingDownAccounts: [ProviderRoutingCandidate]
    public let lastSwitchReason: String?
    public let recentEvents: [ProviderRoutingDecisionEvent]

    public init(
        activeAccount: ProviderRoutingCandidate?,
        nextFallback: ProviderRoutingCandidate?,
        exhaustedOrCoolingDownAccounts: [ProviderRoutingCandidate],
        lastSwitchReason: String?,
        recentEvents: [ProviderRoutingDecisionEvent]
    ) {
        self.activeAccount = activeAccount
        self.nextFallback = nextFallback
        self.exhaustedOrCoolingDownAccounts = exhaustedOrCoolingDownAccounts
        self.lastSwitchReason = lastSwitchReason.map(ProviderRoutingPolicy.sanitizedAuditText)
        self.recentEvents = recentEvents
    }

    /// Calm-by-default predicate: the routing cockpit only earns its space
    /// when it adds information beyond a single healthy account. Surfaces use
    /// this to suppress the cockpit when there is one account that is doing
    /// fine — that case is already self-explanatory from the surrounding row.
    ///
    /// We deliberately ignore the boilerplate `lastSwitchReason` ("X is
    /// active.") because the policy emits it for every decision; the surface
    /// only wants to know whether *real* routing complexity exists.
    public var hasMeaningfulRoutingDetail: Bool {
        if nextFallback != nil { return true }
        if !exhaustedOrCoolingDownAccounts.isEmpty { return true }
        if let active = activeAccount, active.quotaState != .healthy { return true }
        return false
    }
}

public enum ProviderRoutingPolicy {
    public static func decide(
        request: ProviderRoutingRequest,
        candidates: [ProviderRoutingCandidate],
        now: Date = Date()
    ) -> ProviderRoutingDecision {
        var eligible: [ProviderRoutingCandidate] = []
        var skipped: [ProviderRoutingSkip] = []
        let normalizedCandidates = candidates.map { normalizedCandidate($0, now: now) }

        for candidate in normalizedCandidates {
            if let reason = skipReason(for: candidate, request: request, now: now) {
                skipped.append(reason)
            } else {
                eligible.append(candidate)
            }
        }

        let ranked = eligible.sorted { lhs, rhs in
            compare(lhs, rhs, request: request, now: now)
        }
        let selected = ranked.first
        let nextFallback = ranked.dropFirst().first
        let blocked = normalizedCandidates.filter { candidate in
            let state = effectiveQuotaState(for: candidate, now: now)
            return state == .exhausted || state == .rateLimited || state == .coolingDown
        }.sorted { compare($0, $1, request: request, now: now) }

        let reason = decisionReason(selected: selected, nextFallback: nextFallback, skipped: skipped)
        let event = ProviderRoutingDecisionEvent(
            occurredAt: now,
            modelID: request.modelID,
            selected: selected,
            nextFallback: nextFallback,
            reason: reason,
            skipped: skipped
        )

        return ProviderRoutingDecision(
            selected: selected,
            nextFallback: nextFallback,
            exhaustedOrCoolingDown: blocked,
            skipped: skipped,
            event: event
        )
    }

    public static func sanitizedAuditText(_ value: String) -> String {
        var result = value
        let patterns = [
            #"sk-[A-Za-z0-9_\-]{6,}"#,
            #"(?i)bearer\s+[A-Za-z0-9._\-]{6,}"#,
            #"(?i)(api[_-]?key|token|credential|secretVersionName|secret|cookie)\s*[:=]\s*[^,\s]+"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }

    private static func skipReason(
        for candidate: ProviderRoutingCandidate,
        request: ProviderRoutingRequest,
        now: Date
    ) -> ProviderRoutingSkip? {
        if !request.allowProviderFallback,
           let preferred = request.preferredProviderIDs.first,
           candidate.providerID != preferred {
            return skip(candidate, .providerNotPreferred, "Provider fallback is disabled.")
        }
        guard candidate.routingEnabled else {
            return skip(candidate, .routingDisabled, "Routing is disabled for \(candidate.accountLabel).")
        }
        guard !candidate.credentialHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return skip(candidate, .missingCredential, "\(candidate.accountLabel) has no credential handle.")
        }
        guard candidate.modelCompatibility != .incompatible else {
            return skip(candidate, .modelIncompatible, "\(candidate.accountLabel) is not compatible with this model.")
        }

        switch effectiveQuotaState(for: candidate, now: now) {
        case .deleted:
            return skip(candidate, .deleted, "\(candidate.accountLabel) was deleted.")
        case .disabled:
            return skip(candidate, .disabled, "\(candidate.accountLabel) is disabled.")
        case .authFailed:
            return skip(candidate, .authFailed, "\(candidate.accountLabel) failed authentication and needs attention.")
        case .exhausted:
            return skip(candidate, .exhausted, "\(candidate.accountLabel) is exhausted.")
        case .rateLimited:
            return skip(candidate, .rateLimited, "\(candidate.accountLabel) is rate limited.")
        case .coolingDown:
            return skip(candidate, .coolingDown, "\(candidate.accountLabel) is cooling down.")
        case .healthy, .pressure, .unknown:
            return nil
        }
    }

    private static func skip(
        _ candidate: ProviderRoutingCandidate,
        _ reason: ProviderRoutingSkipReason,
        _ detail: String
    ) -> ProviderRoutingSkip {
        ProviderRoutingSkip(
            providerID: candidate.providerID,
            accountID: candidate.accountID,
            accountLabel: candidate.accountLabel,
            reason: reason,
            detail: detail
        )
    }

    private static func effectiveQuotaState(
        for candidate: ProviderRoutingCandidate,
        now: Date
    ) -> ProviderRoutingQuotaState {
        if let cooldownUntil = candidate.cooldownUntil {
            if cooldownUntil > now {
                if candidate.quotaState == .exhausted { return .exhausted }
                if candidate.quotaState == .rateLimited { return .rateLimited }
                return .coolingDown
            }
            if candidate.quotaState == .coolingDown
                || candidate.quotaState == .rateLimited
                || candidate.quotaState == .exhausted {
                return .unknown
            }
        }
        return candidate.quotaState
    }

    private static func normalizedCandidate(
        _ candidate: ProviderRoutingCandidate,
        now: Date
    ) -> ProviderRoutingCandidate {
        let effectiveState = effectiveQuotaState(for: candidate, now: now)
        guard effectiveState != candidate.quotaState else {
            return candidate
        }
        var copy = candidate
        copy.quotaState = effectiveState
        copy.cooldownUntil = nil
        return copy
    }

    private static func compare(
        _ lhs: ProviderRoutingCandidate,
        _ rhs: ProviderRoutingCandidate,
        request: ProviderRoutingRequest,
        now: Date
    ) -> Bool {
        let lhsProvider = providerRank(lhs.providerID, preferences: request.preferredProviderIDs)
        let rhsProvider = providerRank(rhs.providerID, preferences: request.preferredProviderIDs)
        if lhsProvider != rhsProvider { return lhsProvider < rhsProvider }
        if lhs.localCredentialAvailable != rhs.localCredentialAvailable {
            return lhs.localCredentialAvailable
        }
        let lhsHealth = healthRank(effectiveQuotaState(for: lhs, now: now))
        let rhsHealth = healthRank(effectiveQuotaState(for: rhs, now: now))
        if lhsHealth != rhsHealth { return lhsHealth < rhsHealth }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        let lhsLastUsed = lhs.lastUsedAt ?? .distantPast
        let rhsLastUsed = rhs.lastUsedAt ?? .distantPast
        if lhsLastUsed != rhsLastUsed { return lhsLastUsed < rhsLastUsed }
        if lhs.providerID.rawValue != rhs.providerID.rawValue { return lhs.providerID.rawValue < rhs.providerID.rawValue }
        return lhs.accountID < rhs.accountID
    }

    private static func providerRank(_ providerID: ProviderID, preferences: [ProviderID]) -> Int {
        preferences.firstIndex(of: providerID) ?? Int.max
    }

    private static func healthRank(_ state: ProviderRoutingQuotaState) -> Int {
        switch state {
        case .healthy: return 0
        case .pressure: return 1
        case .unknown: return 2
        case .coolingDown: return 3
        case .rateLimited: return 4
        case .exhausted: return 5
        case .authFailed: return 6
        case .disabled: return 7
        case .deleted: return 8
        }
    }

    private static func decisionReason(
        selected: ProviderRoutingCandidate?,
        nextFallback: ProviderRoutingCandidate?,
        skipped: [ProviderRoutingSkip]
    ) -> String {
        guard let selected else {
            return "No eligible provider account is available."
        }
        if let firstSkipped = skipped.first {
            return "\(firstSkipped.accountLabel) \(plainReason(firstSkipped.reason)); routed to \(selected.accountLabel)."
        }
        if let nextFallback {
            return "\(selected.accountLabel) is active; \(nextFallback.accountLabel) is next fallback."
        }
        return "\(selected.accountLabel) is active."
    }

    private static func plainReason(_ reason: ProviderRoutingSkipReason) -> String {
        switch reason {
        case .providerNotPreferred: return "was outside the selected provider policy"
        case .routingDisabled: return "has routing disabled"
        case .deleted: return "was deleted"
        case .disabled: return "is disabled"
        case .authFailed: return "failed authentication"
        case .exhausted: return "is exhausted"
        case .rateLimited: return "hit a rate limit"
        case .coolingDown: return "is cooling down"
        case .modelIncompatible: return "does not support this model"
        case .missingCredential: return "is missing a credential"
        }
    }
}
