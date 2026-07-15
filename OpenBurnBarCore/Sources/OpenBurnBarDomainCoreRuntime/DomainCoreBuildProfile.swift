import Foundation

public enum DomainCoreBuildDomain: String, CaseIterable, Sendable {
    case quota, cloudVault, cloudVaultRewrap, cloudVaultSearch, hermes, pricing

    fileprivate var environmentKey: String {
        switch self {
        case .quota: "OPENBURNBAR_DOMAIN_CORE_QUOTA_MODE"
        case .cloudVault: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE"
        case .cloudVaultRewrap: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE"
        case .cloudVaultSearch: "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE"
        case .hermes: "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE"
        case .pricing: "OPENBURNBAR_DOMAIN_CORE_PRICING_MODE"
        }
    }

    fileprivate var infoKey: String {
        switch self {
        case .quota: "OpenBurnBarDomainCoreModeQuota"
        case .cloudVault: "OpenBurnBarDomainCoreModeCloudVault"
        case .cloudVaultRewrap: "OpenBurnBarDomainCoreModeCloudVaultRewrap"
        case .cloudVaultSearch: "OpenBurnBarDomainCoreModeCloudVaultSearch"
        case .hermes: "OpenBurnBarDomainCoreModeHermes"
        case .pricing: "OpenBurnBarDomainCoreModePricing"
        }
    }
}

public enum DomainCoreBuildMode: String, Sendable { case legacy, shadow, rust }

public struct DomainCoreCandidateIdentity: Equatable, Sendable {
    public let candidateCommit: String
    public let coreVersion: String
    public let abiVersion: UInt32
    public let sourceSha256: String

    fileprivate init(
        candidateCommit: String,
        coreVersion: String,
        abiVersion: UInt32,
        sourceSha256: String
    ) {
        self.candidateCommit = candidateCommit
        self.coreVersion = coreVersion
        self.abiVersion = abiVersion
        self.sourceSha256 = sourceSha256
    }
}

public struct DomainCoreBuildProfile: Equatable, Sendable {
    public let name: String
    public let artifactAuthority: String
    public let distribution: String
    public let rolloutChannel: String?
    public let evidenceEnabled: Bool
    public let candidateIdentity: DomainCoreCandidateIdentity?
    public let modes: [DomainCoreBuildDomain: DomainCoreBuildMode]
    public let isValid: Bool

    fileprivate static func failClosed(authority: String, valid: Bool) -> Self {
        Self(
            name: valid ? "developer" : "invalid-signed-profile",
            artifactAuthority: authority,
            distribution: valid ? "development" : "invalid",
            rolloutChannel: nil,
            evidenceEnabled: false,
            candidateIdentity: nil,
            modes: Dictionary(uniqueKeysWithValues: DomainCoreBuildDomain.allCases.map { ($0, .legacy) }),
            isValid: valid
        )
    }
}

public enum DomainCoreBuildProfileResolver {
    private enum CandidateIdentityResolution {
        case absent
        case valid(DomainCoreCandidateIdentity)
        case invalid
    }

    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> DomainCoreBuildProfile {
        let authority = string(info["OpenBurnBarDomainCoreBuildAuthority"])
        switch authority {
        case nil, "", "development":
            return development(environment: environment, info: info)
        case "signed":
            return signed(info: info)
        default:
            return .failClosed(authority: authority ?? "invalid", valid: false)
        }
    }

    public static func mode(
        for domain: DomainCoreBuildDomain,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> DomainCoreBuildMode {
        current(environment: environment, info: info).modes[domain] ?? .legacy
    }

    public static func evidenceChannel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> String? {
        let profile = current(environment: environment, info: info)
        return profile.isValid && profile.evidenceEnabled ? profile.rolloutChannel : nil
    }

    private static func development(environment: [String: String], info: [String: Any]) -> DomainCoreBuildProfile {
        let candidateIdentity: DomainCoreCandidateIdentity?
        switch resolveCandidateIdentity(info: info) {
        case .absent:
            candidateIdentity = nil
        case let .valid(identity):
            candidateIdentity = identity
        case .invalid:
            return .failClosed(authority: "development", valid: false)
        }
        var profile = DomainCoreBuildProfile.failClosed(authority: "development", valid: true)
        var modes = profile.modes
        for domain in DomainCoreBuildDomain.allCases {
            let raw = environment[domain.environmentKey] ?? string(info[domain.infoKey])
            modes[domain] = raw.flatMap { DomainCoreBuildMode(rawValue: $0.lowercased()) } ?? .legacy
        }
        profile = DomainCoreBuildProfile(
            name: string(info["OpenBurnBarDomainCoreBuildProfile"]) ?? "developer",
            artifactAuthority: "development",
            distribution: "development",
            rolloutChannel: nil,
            evidenceEnabled: false,
            candidateIdentity: candidateIdentity,
            modes: modes,
            isValid: true
        )
        return profile
    }

    private static func signed(info: [String: Any]) -> DomainCoreBuildProfile {
        guard let name = string(info["OpenBurnBarDomainCoreBuildProfile"]),
              let distribution = string(info["OpenBurnBarDomainCoreDistribution"]),
              let evidenceEnabled = bool(info["OpenBurnBarDomainCoreEvidenceEnabled"])
        else { return .failClosed(authority: "signed", valid: false) }
        guard case let .valid(candidateIdentity) = resolveCandidateIdentity(info: info) else {
            return .failClosed(authority: "signed", valid: false)
        }
        var modes: [DomainCoreBuildDomain: DomainCoreBuildMode] = [:]
        for domain in DomainCoreBuildDomain.allCases {
            guard let raw = string(info[domain.infoKey]), let mode = DomainCoreBuildMode(rawValue: raw.lowercased()) else {
                return .failClosed(authority: "signed", valid: false)
            }
            modes[domain] = mode
        }
        let channel = string(info["OpenBurnBarDomainCoreRolloutChannel"]).flatMap { $0.isEmpty ? nil : $0 }
        let valid = switch (name, distribution) {
        case ("public-production", "public"):
            !evidenceEnabled && channel == nil && !modes.values.contains(.shadow)
        case ("internal", "internal"), ("beta", "beta"):
            evidenceEnabled && channel == distribution && modes[.quota] == .shadow
        default: false
        }
        guard valid else { return .failClosed(authority: "signed", valid: false) }
        return DomainCoreBuildProfile(
            name: name,
            artifactAuthority: "signed",
            distribution: distribution,
            rolloutChannel: channel,
            evidenceEnabled: evidenceEnabled,
            candidateIdentity: candidateIdentity,
            modes: modes,
            isValid: true
        )
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        switch string(value)?.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    private static func resolveCandidateIdentity(info: [String: Any]) -> CandidateIdentityResolution {
        let commitValue = info["OpenBurnBarDomainCoreCandidateCommit"]
        let versionValue = info["OpenBurnBarDomainCoreExpectedVersion"]
        let abiValue = info["OpenBurnBarDomainCoreExpectedABIVersion"]
        let sourceSHA256Value = info["OpenBurnBarDomainCoreExpectedSourceSHA256"]
        let values = [commitValue, versionValue, abiValue, sourceSHA256Value]
        if values.allSatisfy(isAbsentCandidateValue) {
            return .absent
        }

        guard let commit = exactString(commitValue),
              matches(commit, pattern: #"^[0-9a-f]{40}$"#),
              let version = exactString(versionValue),
              version.utf8.count <= 64,
              matches(
                  version,
                  pattern: #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
              ),
              let abiVersion = canonicalABIVersion(abiValue),
              let sourceSHA256 = exactString(sourceSHA256Value),
              matches(sourceSHA256, pattern: #"^[0-9a-f]{64}$"#)
        else { return .invalid }

        return .valid(
            DomainCoreCandidateIdentity(
                candidateCommit: commit,
                coreVersion: version,
                abiVersion: abiVersion,
                sourceSha256: sourceSHA256
            )
        )
    }

    private static func isAbsentCandidateValue(_ value: Any?) -> Bool {
        value == nil || (value as? String) == ""
    }

    private static func exactString(_ value: Any?) -> String? {
        value as? String
    }

    private static func canonicalABIVersion(_ value: Any?) -> UInt32? {
        if value is Bool { return nil }
        let raw: String
        if let value = value as? String {
            raw = value
        } else if let value = value as? NSNumber {
            raw = value.stringValue
        } else {
            return nil
        }
        guard matches(raw, pattern: #"^[1-9]\d*$"#) else { return nil }
        return UInt32(raw)
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: fullRange)?.range == fullRange
    }
}
