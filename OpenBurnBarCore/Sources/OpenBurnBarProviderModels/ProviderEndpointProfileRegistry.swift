import Foundation

// MARK: - Region

public enum ProviderEndpointRegion: String, Codable, CaseIterable, Hashable, Sendable {
    case cn
    case sgp
    case ams
    case global

    public var displayName: String {
        switch self {
        case .cn: return "China"
        case .sgp: return "Singapore"
        case .ams: return "Europe (Amsterdam)"
        case .global: return "Global"
        }
    }
}

// MARK: - Billing lane

public enum ProviderEndpointBillingLane: String, Codable, CaseIterable, Hashable, Sendable {
    case tokenPlan = "token_plan"
    case payAsYouGo = "payg"
    case subscription
    case unknown

    public var budgetBillingMode: BudgetBillingMode {
        switch self {
        case .tokenPlan, .subscription: return .subscription
        case .payAsYouGo: return .perUsage
        case .unknown: return .unknown
        }
    }
}

// MARK: - Token plan tier (MiMo)

public enum MimoTokenPlanTier: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case lite
    case standard
    case pro
    case max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lite: return "Lite"
        case .standard: return "Standard"
        case .pro: return "Pro"
        case .max: return "Max"
        }
    }

    /// Monthly credit caps (Xiaomi Token Plan, May 2026).
    public var monthlyCreditLimit: Double {
        switch self {
        case .lite: return 60_000_000
        case .standard: return 200_000_000
        case .pro: return 700_000_000
        case .max: return 1_600_000_000
        }
    }

    public func creditLimit(billingCycle: MimoTokenPlanBillingCycle) -> Double {
        switch billingCycle {
        case .monthly: return monthlyCreditLimit
        case .annual: return monthlyCreditLimit * 12
        }
    }
}

public enum MimoTokenPlanBillingCycle: String, Codable, CaseIterable, Hashable, Sendable {
    case monthly
    case annual
}

// MARK: - Profile

public struct ProviderEndpointProfile: Hashable, Sendable {
    public let id: String
    public let providerID: ProviderID
    public let displayName: String
    public let inferenceBaseURL: String
    public let quotaRemainsURL: String?
    public let billingLane: ProviderEndpointBillingLane
    public let region: ProviderEndpointRegion
    public let keyPrefix: String?
    public let authMethodID: String?

    public init(
        id: String,
        providerID: ProviderID,
        displayName: String,
        inferenceBaseURL: String,
        quotaRemainsURL: String? = nil,
        billingLane: ProviderEndpointBillingLane,
        region: ProviderEndpointRegion,
        keyPrefix: String? = nil,
        authMethodID: String? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.inferenceBaseURL = inferenceBaseURL
        self.quotaRemainsURL = quotaRemainsURL
        self.billingLane = billingLane
        self.region = region
        self.keyPrefix = keyPrefix
        self.authMethodID = authMethodID
    }
}

// MARK: - Registry

public enum ProviderEndpointProfileRegistry {
    public static let mimoPayg = ProviderEndpointProfile(
        id: "mimo.payg.global",
        providerID: ProviderID(rawValue: "mimo"),
        displayName: "MiMo Pay-as-you-go",
        inferenceBaseURL: "https://api.xiaomimimo.com/v1",
        quotaRemainsURL: nil,
        billingLane: .payAsYouGo,
        region: .global,
        keyPrefix: "sk-",
        authMethodID: "mimo-payg"
    )

    public static func mimoTokenPlan(region: ProviderEndpointRegion) -> ProviderEndpointProfile {
        let host: String
        switch region {
        case .cn: host = "https://token-plan-cn.xiaomimimo.com/v1"
        case .sgp: host = "https://token-plan-sgp.xiaomimimo.com/v1"
        case .ams: host = "https://token-plan-ams.xiaomimimo.com/v1"
        case .global: host = "https://token-plan-sgp.xiaomimimo.com/v1"
        }
        return ProviderEndpointProfile(
            id: "mimo.token-plan.\(region.rawValue)",
            providerID: ProviderID(rawValue: "mimo"),
            displayName: "MiMo Token Plan · \(region.displayName)",
            inferenceBaseURL: host,
            quotaRemainsURL: "\(host)/token_plan/remains",
            billingLane: .tokenPlan,
            region: region,
            keyPrefix: "tp-",
            authMethodID: "mimo-token-plan"
        )
    }

    public static let minimaxTokenPlan = ProviderEndpointProfile(
        id: "minimax.token-plan",
        providerID: ProviderID(rawValue: "minimax"),
        displayName: "MiniMax Token / Coding Plan",
        inferenceBaseURL: "https://api.minimax.io/v1",
        quotaRemainsURL: "https://www.minimax.io/v1/token_plan/remains",
        billingLane: .tokenPlan,
        region: .global,
        keyPrefix: "sk-cp-",
        authMethodID: "minimax-coding-plan"
    )

    public static let minimaxPayg = ProviderEndpointProfile(
        id: "minimax.payg",
        providerID: ProviderID(rawValue: "minimax"),
        displayName: "MiniMax Open Platform",
        inferenceBaseURL: "https://api.minimax.io/v1",
        quotaRemainsURL: nil,
        billingLane: .payAsYouGo,
        region: .global,
        keyPrefix: "sk-api-",
        authMethodID: "minimax-open-platform"
    )

    public static var allProfiles: [ProviderEndpointProfile] {
        [
            mimoPayg,
            mimoTokenPlan(region: .cn),
            mimoTokenPlan(region: .sgp),
            mimoTokenPlan(region: .ams),
            minimaxTokenPlan,
            minimaxPayg
        ]
    }

    public static func profile(id: String) -> ProviderEndpointProfile? {
        allProfiles.first { $0.id == id }
    }

    public static func profiles(for providerID: ProviderID) -> [ProviderEndpointProfile] {
        allProfiles.filter { $0.providerID == providerID }
    }

    public static func resolveProfileID(
        providerID: ProviderID,
        apiKey: String,
        explicitProfileID: String?,
        region: ProviderEndpointRegion?
    ) -> ProviderEndpointProfile? {
        if let explicitProfileID, let profile = profile(id: explicitProfileID) {
            return profile
        }

        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = profiles(for: providerID)

        if providerID.rawValue == "mimo" {
            if trimmed.hasPrefix("tp-") {
                guard let region else { return nil }
                return mimoTokenPlan(region: region)
            }
            if trimmed.hasPrefix("sk-") {
                return mimoPayg
            }
            return nil
        }

        if providerID.rawValue == "minimax" {
            if trimmed.hasPrefix("sk-cp-") { return minimaxTokenPlan }
            if trimmed.hasPrefix("sk-api-") { return minimaxPayg }
        }

        return candidates.first { profile in
            guard let prefix = profile.keyPrefix?.lowercased() else { return false }
            return trimmed.hasPrefix(prefix)
        }
    }

    /// Credit multiplier for MiMo Token Plan model IDs.
    public static func mimoCreditMultiplier(forModelID modelID: String) -> Double {
        let normalized = modelID.lowercased()
        if normalized.contains("tts") { return 0 }
        if normalized.contains("v2.5-pro") || normalized.contains("v2-pro") { return 2 }
        return 1
    }
}
