import Foundation

public enum HarnessRuntimeDeliveryMode: String, Codable, CaseIterable, Hashable, Sendable {
    case gateway
    case cliProfile = "cli_profile"
    case shellShim = "shell_shim"
    case configRewrite = "config_rewrite"
    case envInjection = "env_injection"
}

public enum HarnessRuntimeRecoveryStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case retrySameProcess = "retry_same_process"
    case restartProcess = "restart_process"
    case nextRequestOnly = "next_request_only"
    case rewriteAndRelaunch = "rewrite_and_relaunch"
}

public enum ProviderRuntimeHealthSignal: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case quotaExhausted = "quota_exhausted"
    case rateLimited = "rate_limited"
    case authFailed = "auth_failed"
    case transientFailure = "transient_failure"
    case fatalConfigError = "fatal_config_error"
}

public struct ProviderRuntimeAccount: Codable, Hashable, Identifiable, Sendable {
    public let accountID: String
    public let providerID: ProviderID
    public let subscriptionTierID: String?
    public let credentialRef: String
    public let storageScope: ProviderAccountStorageScope
    public let priority: Int
    public let isEnabled: Bool
    public let isPinned: Bool
    public let neverAutoSwitch: Bool
    public let linkedSwitcherProfileID: String?
    public let linkedDaemonSlotID: String?
    public let linkedHarnessIDs: [String]

    public var id: String { "\(providerID.rawValue):\(accountID)" }

    public init(
        accountID: String,
        providerID: ProviderID,
        subscriptionTierID: String? = nil,
        credentialRef: String,
        storageScope: ProviderAccountStorageScope,
        priority: Int = 0,
        isEnabled: Bool = true,
        isPinned: Bool = false,
        neverAutoSwitch: Bool = false,
        linkedSwitcherProfileID: String? = nil,
        linkedDaemonSlotID: String? = nil,
        linkedHarnessIDs: [String] = []
    ) {
        self.accountID = accountID
        self.providerID = providerID
        self.subscriptionTierID = subscriptionTierID.map(ProviderRoutingPolicy.sanitizedAuditText)
        self.credentialRef = ProviderRoutingPolicy.sanitizedAuditText(credentialRef)
        self.storageScope = storageScope
        self.priority = priority
        self.isEnabled = isEnabled
        self.isPinned = isPinned
        self.neverAutoSwitch = neverAutoSwitch
        self.linkedSwitcherProfileID = linkedSwitcherProfileID.map(ProviderRoutingPolicy.sanitizedAuditText)
        self.linkedDaemonSlotID = linkedDaemonSlotID.map(ProviderRoutingPolicy.sanitizedAuditText)
        self.linkedHarnessIDs = linkedHarnessIDs.map(ProviderRoutingPolicy.sanitizedAuditText)
    }
}

public struct ModelCapabilityClass: Codable, Hashable, Identifiable, Sendable {
    public let providerID: ProviderID
    public let formatFamily: BurnBarProviderFormatFamily
    public let classID: String
    public let canonicalModelIDs: [String]
    public let aliases: [String]
    public let noDowngradeRank: Int
    public let allowsEquivalentPatchFamilies: Bool

    public var id: String { classID }

    public init(
        providerID: ProviderID,
        formatFamily: BurnBarProviderFormatFamily,
        classID: String,
        canonicalModelIDs: [String] = [],
        aliases: [String] = [],
        noDowngradeRank: Int = 0,
        allowsEquivalentPatchFamilies: Bool = false
    ) {
        self.providerID = providerID
        self.formatFamily = formatFamily
        self.classID = ProviderRoutingPolicy.sanitizedAuditText(classID)
        self.canonicalModelIDs = canonicalModelIDs.map(ProviderRoutingPolicy.sanitizedAuditText)
        self.aliases = aliases.map(ProviderRoutingPolicy.sanitizedAuditText)
        self.noDowngradeRank = noDowngradeRank
        self.allowsEquivalentPatchFamilies = allowsEquivalentPatchFamilies
    }

    public func matches(modelID: String) -> Bool {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if classID.lowercased() == normalized { return true }
        if canonicalModelIDs.contains(where: { $0.lowercased() == normalized }) { return true }
        return aliases.contains(where: { $0.lowercased() == normalized })
    }
}

public struct HarnessRuntimeBinding: Codable, Hashable, Identifiable, Sendable {
    public let harnessID: String
    public let deliveryMode: HarnessRuntimeDeliveryMode
    public let providerID: ProviderID
    public let modelCapabilityClassID: String
    public let currentAccountID: String?
    public let recoveryStrategy: HarnessRuntimeRecoveryStrategy

    public var id: String { harnessID }

    public init(
        harnessID: String,
        deliveryMode: HarnessRuntimeDeliveryMode,
        providerID: ProviderID,
        modelCapabilityClassID: String,
        currentAccountID: String? = nil,
        recoveryStrategy: HarnessRuntimeRecoveryStrategy
    ) {
        self.harnessID = ProviderRoutingPolicy.sanitizedAuditText(harnessID)
        self.deliveryMode = deliveryMode
        self.providerID = providerID
        self.modelCapabilityClassID = ProviderRoutingPolicy.sanitizedAuditText(modelCapabilityClassID)
        self.currentAccountID = currentAccountID.map(ProviderRoutingPolicy.sanitizedAuditText)
        self.recoveryStrategy = recoveryStrategy
    }
}

public struct ProviderAccountHealthEvidence: Codable, Hashable, Identifiable, Sendable {
    public let accountID: String
    public let providerID: ProviderID
    public let harnessID: String
    public let modelCapabilityClassID: String
    public let signal: ProviderRuntimeHealthSignal
    public let cooldownUntil: Date?
    public let resetsAt: Date?
    public let errorFingerprint: String?
    public let redactedDetail: String?
    public let observedAt: Date

    public var id: String { "\(providerID.rawValue):\(accountID):\(observedAt.timeIntervalSince1970)" }

    public init(
        accountID: String,
        providerID: ProviderID,
        harnessID: String,
        modelCapabilityClassID: String,
        signal: ProviderRuntimeHealthSignal,
        cooldownUntil: Date? = nil,
        resetsAt: Date? = nil,
        errorFingerprint: String? = nil,
        redactedDetail: String? = nil,
        observedAt: Date = Date()
    ) {
        self.accountID = ProviderRoutingPolicy.sanitizedAuditText(accountID)
        self.providerID = providerID
        self.harnessID = ProviderRoutingPolicy.sanitizedAuditText(harnessID)
        self.modelCapabilityClassID = ProviderRoutingPolicy.sanitizedAuditText(modelCapabilityClassID)
        self.signal = signal
        self.cooldownUntil = cooldownUntil
        self.resetsAt = resetsAt
        self.errorFingerprint = errorFingerprint.map(ProviderRoutingPolicy.sanitizedAuditText)
        self.redactedDetail = redactedDetail.map(ProviderRoutingPolicy.sanitizedAuditText)
        self.observedAt = observedAt
    }
}

public enum ProviderRuntimeFailoverPolicy {
    public static func isAccountEligible(
        _ account: ProviderRuntimeAccount,
        forProvider providerID: ProviderID,
        capabilityClassID: String,
        requestedSubscriptionTierID: String? = nil,
        allowDowngrade: Bool = false
    ) -> Bool {
        let normalizedCapabilityClassID = capabilityClassID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedCapabilityClassID.isEmpty else { return false }
        guard account.isEnabled else { return false }
        guard account.providerID == providerID else { return false }
        guard account.neverAutoSwitch == false else { return false }
        guard tierCompatible(
            requestedTierID: requestedSubscriptionTierID,
            candidateTierID: account.subscriptionTierID,
            allowDowngrade: allowDowngrade
        ) else {
            return false
        }
        return account.linkedHarnessIDs.isEmpty == false || account.linkedSwitcherProfileID != nil || account.linkedDaemonSlotID != nil
    }

    public static func tierCompatible(
        requestedTierID: String?,
        candidateTierID: String?,
        allowDowngrade: Bool
    ) -> Bool {
        let requested = requestedTierID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = candidateTierID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let requested, !requested.isEmpty else { return true }
        guard let candidate, !candidate.isEmpty else { return allowDowngrade }
        return candidate == requested || allowDowngrade
    }
}
