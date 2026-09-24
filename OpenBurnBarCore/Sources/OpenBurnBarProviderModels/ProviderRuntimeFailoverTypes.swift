import Foundation

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
