import Foundation

// MARK: - Quota Domain

enum ProviderQuotaSourceKind: String, Codable, CaseIterable {
    case officialAPI
    case localCLI
    case localSession
    case manualEstimate
    case unavailable

    var label: String {
        switch self {
        case .officialAPI: return "Official API"
        case .localCLI: return "Local CLI"
        case .localSession: return "Local session"
        case .manualEstimate: return "Estimated"
        case .unavailable: return "Unavailable"
        }
    }
}

enum ProviderQuotaConfidence: String, Codable {
    case exact
    case estimated
    case unavailable

    var label: String {
        switch self {
        case .exact: return "Exact"
        case .estimated: return "Estimated"
        case .unavailable: return "Unavailable"
        }
    }
}

enum ProviderQuotaUnit: String, Codable {
    case percent
    case requests
    case tokens
    case count

    var shortLabel: String {
        switch self {
        case .percent: return "%"
        case .requests: return "req"
        case .tokens: return "tok"
        case .count: return ""
        }
    }
}

enum ProviderQuotaWindowKind: String, Codable {
    case rollingHours
    case rollingDays
    case daily
    case weekly
    case monthly
    case custom
}

struct ProviderQuotaBucket: Codable, Hashable, Identifiable {
    let key: String
    let label: String
    let windowKind: ProviderQuotaWindowKind
    let usedValue: Double?
    let limitValue: Double?
    let remainingValue: Double?
    let usedPercent: Double?
    let resetsAt: Date?
    let unit: ProviderQuotaUnit
    let isEstimated: Bool

    var id: String { key }

    var remainingPercent: Double? {
        // Prioritize usedPercent — it's the most reliable signal when present,
        // because remainingValue may be a raw count that coincidentally looks like a percent.
        if let usedPercent {
            return max(0, min(100 - usedPercent, 100))
        }
        if let remainingValue, unit == .percent {
            return min(max(remainingValue, 0), 100)
        }
        if let remainingValue, let limitValue, limitValue > 0 {
            return min(max((remainingValue / limitValue) * 100, 0), 100)
        }
        return nil
    }

    var progressFraction: Double {
        if let usedPercent {
            return min(max(usedPercent / 100, 0), 1)
        }
        if let usedValue, let limitValue, limitValue > 0 {
            return min(max(usedValue / limitValue, 0), 1)
        }
        if let remainingPercent {
            return min(max((100 - remainingPercent) / 100, 0), 1)
        }
        return 0
    }

    var remainingText: String {
        if let remainingPercent {
            return Self.format(remainingPercent, unit: .percent)
        }
        if let remainingValue {
            return Self.format(remainingValue, unit: unit)
        }
        return "Unavailable"
    }

    var usageText: String {
        if let usedValue, let limitValue {
            return "\(Self.format(usedValue, unit: unit)) / \(Self.format(limitValue, unit: unit))"
        }
        if let usedPercent {
            return "\(Self.format(usedPercent, unit: .percent)) used"
        }
        return "No usage detail"
    }

    private static func format(_ value: Double, unit: ProviderQuotaUnit) -> String {
        switch unit {
        case .percent:
            let clamped = min(max(value, 0), 100)
            return "\(Int(clamped.rounded()))%"
        case .tokens:
            if value >= 1_000_000 {
                return String(format: "%.1fM", value / 1_000_000)
            }
            if value >= 1_000 {
                return String(format: "%.1fK", value / 1_000)
            }
            return "\(Int(value.rounded()))"
        case .requests, .count:
            if value >= 1_000 {
                return String(format: "%.1fK", value / 1_000)
            }
            if value.rounded() == value {
                return "\(Int(value))"
            }
            return String(format: "%.1f", value)
        }
    }
}

struct ProviderQuotaSnapshot: Codable, Hashable {
    let provider: AgentProvider
    let fetchedAt: Date
    let source: ProviderQuotaSourceKind
    /// Backend-compatible source kind (new field; defaults to `source` for backward compat).
    var sourceKind: ProviderQuotaSourceKind { source }
    /// Source identifier — device ID for desktop, credential ID for backend.
    var sourceId: String { "" }
    /// Firestore payload schema for cross-surface quota snapshots.
    var schemaVersion: Int { 1 }
    let confidence: ProviderQuotaConfidence
    let managementURL: String?
    let statusMessage: String
    let buckets: [ProviderQuotaBucket]

    var managementLink: URL? {
        guard let managementURL else { return nil }
        return URL(string: managementURL)
    }

    var primaryBucket: ProviderQuotaBucket? {
        buckets.sorted {
            let lhsPriority = primaryBucketPriority(for: $0)
            let rhsPriority = primaryBucketPriority(for: $1)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            let lhsRemaining = $0.remainingPercent ?? .infinity
            let rhsRemaining = $1.remainingPercent ?? .infinity
            if lhsRemaining == rhsRemaining {
                return ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture)
            }
            return lhsRemaining < rhsRemaining
        }.first
    }

    private func primaryBucketPriority(for bucket: ProviderQuotaBucket) -> Int {
        guard provider == .zai else { return 0 }
        let lowercased = bucket.label.lowercased()
        if lowercased.contains("token") || lowercased.contains("api") {
            return 0
        }
        if lowercased.contains("mcp") || lowercased.contains("tool") || lowercased.contains("time_limit") || lowercased.contains("time limit") {
            return 2
        }
        if lowercased == "limits" || lowercased == "limit" {
            return 3
        }
        return 1
    }

    var summaryText: String {
        guard let primaryBucket else { return statusMessage }
        return "\(primaryBucket.label): \(primaryBucket.remainingText) left"
    }

    func isStale(relativeTo now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) > 12 * 60 * 60
    }

    /// Returns the bucket representing the hourly/5h window (windowKind == .rollingHours)
    var hourlyBucket: ProviderQuotaBucket? {
        buckets.first { $0.windowKind == .rollingHours }
    }

    /// Returns the bucket representing the weekly window (windowKind == .weekly or .rollingDays)
    var weeklyBucket: ProviderQuotaBucket? {
        buckets.first { $0.windowKind == .weekly || $0.windowKind == .rollingDays }
    }
}

struct ClaudeQuotaBridgeStatus: Equatable {
    enum State: Equatable {
        case notInstalled
        case awaitingFirstPayload
        case ready
        case disabledByHooks
        case invalidConfiguration
    }

    let state: State
    let wrapperPath: String
    let detailText: String
    let lastPayloadAt: Date?

    var isInstalled: Bool {
        switch state {
        case .awaitingFirstPayload, .ready, .disabledByHooks:
            return true
        case .notInstalled, .invalidConfiguration:
            return false
        }
    }
}

// MARK: - Provider Settings

enum MiniMaxQuotaMode: String, CaseIterable, Codable, Identifiable {
    case tokenPlan
    case payAsYouGo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tokenPlan: return "Token Plan"
        case .payAsYouGo: return "Pay-as-you-go"
        }
    }
}

enum FactoryQuotaPlanTier: String, CaseIterable, Codable, Identifiable {
    case unknown
    case pro
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .pro: return "Pro (20M/month)"
        case .max: return "Max (200M/month)"
        }
    }

    var monthlyTokenCap: Double? {
        switch self {
        case .unknown: return nil
        case .pro: return 20_000_000
        case .max: return 200_000_000
        }
    }
}

// MARK: - Internal Policy / Kind

enum CodexQuotaScanPolicy {
    static let freshnessWindow: TimeInterval = 7 * 24 * 60 * 60
    static let tailReadBytes = 512 * 1024
    static let maxTailLines = 4000
}

enum MiniMaxAPIKeyKind {
    case codingPlan
    case standard
    case unknown
}
