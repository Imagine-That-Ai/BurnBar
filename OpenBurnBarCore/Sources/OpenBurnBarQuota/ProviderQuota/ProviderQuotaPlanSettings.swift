import Foundation

// MARK: - Provider quota plan / policy settings (lifted from AgentLens)

public enum MiniMaxQuotaMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case tokenPlan
    case payAsYouGo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tokenPlan: return "Token Plan"
        case .payAsYouGo: return "Pay-as-you-go"
        }
    }
}

public enum FactoryQuotaPlanTier: String, CaseIterable, Codable, Identifiable, Sendable {
    case unknown
    case pro
    case plus
    case max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .pro: return "Pro (20M/month, $20)"
        case .plus: return "Plus (~100M/month, $100)"
        case .max: return "Max (~200M/month, $200)"
        }
    }

    public var shortName: String {
        switch self {
        case .unknown: return "Unknown"
        case .pro: return "Pro"
        case .plus: return "Plus"
        case .max: return "Max"
        }
    }

    private var tokenCaps: (fiveHour: Double, sevenDay: Double, monthly: Double)? {
        switch self {
        case .unknown: return nil
        case .pro: return (500_000, 5_000_000, 20_000_000)
        case .plus: return (2_500_000, 25_000_000, 100_000_000)
        case .max: return (5_000_000, 50_000_000, 200_000_000)
        }
    }

    public var fiveHourTokenCap: Double? { tokenCaps?.fiveHour }
    public var sevenDayTokenCap: Double? { tokenCaps?.sevenDay }
    public var monthlyTokenCap: Double? { tokenCaps?.monthly }
}

public enum XAIQuotaPlanTier: String, CaseIterable, Codable, Identifiable, Sendable {
    case unknown
    case superGrokLite
    case superGrok
    case superGrokHeavy
    case grokBuild

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .superGrokLite: return "SuperGrok Lite ($10/mo)"
        case .superGrok: return "SuperGrok ($30/mo)"
        case .superGrokHeavy: return "SuperGrok Heavy ($300/mo)"
        case .grokBuild: return "GrokBuild (xAI API credits)"
        }
    }

    public var shortName: String {
        switch self {
        case .unknown: return "Unknown"
        case .superGrokLite: return "Lite"
        case .superGrok: return "SuperGrok"
        case .superGrokHeavy: return "Heavy"
        case .grokBuild: return "GrokBuild"
        }
    }

    public var rollingTwoHourPromptCap: Double? {
        switch self {
        case .unknown, .grokBuild: return nil
        case .superGrokLite: return 30
        case .superGrok: return 100
        case .superGrokHeavy: return 400
        }
    }

    public var isSuperGrokConsumer: Bool {
        switch self {
        case .superGrokLite, .superGrok, .superGrokHeavy: return true
        case .unknown, .grokBuild: return false
        }
    }
}

public enum CodexQuotaScanPolicy: Sendable {
    public static let freshnessWindow: TimeInterval = 7 * 24 * 60 * 60
    public static let tailReadBytes = 512 * 1024
    public static let maxTailLines = 4000
}

public enum MiniMaxAPIKeyKind: Sendable {
    case codingPlan
    case standard
    case unknown
}
