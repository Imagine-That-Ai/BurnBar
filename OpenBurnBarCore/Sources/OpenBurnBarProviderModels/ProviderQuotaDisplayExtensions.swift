import Foundation

// MARK: - Mac / AgentLens display helpers (ported from pre-lift ProviderQuotaTypes)

public extension ProviderQuotaBucket {
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
        remainingText(displayMode: .remainingPercent)
    }

    func remainingText(displayMode mode: QuotaPercentageDisplayMode) -> String {
        switch mode {
        case .remainingPercent:
            if let remainingPercent {
                return Self.formatQuotaValue(remainingPercent, unit: .percent)
            }
            if let remainingValue {
                return Self.formatQuotaValue(remainingValue, unit: unit)
            }
            return "Unavailable"
        case .usedPercent:
            let usedP: Double
            if let usedPercent {
                usedP = usedPercent
            } else if let remainingPercent {
                usedP = max(0, 100 - remainingPercent)
            } else {
                usedP = progressFraction * 100
            }
            return Self.formatQuotaValue(usedP, unit: .percent)
        case .fractional:
            let frac: Double
            if let remainingPercent {
                frac = remainingPercent / 100.0
            } else if let remainingValue, let limitValue, limitValue > 0 {
                frac = remainingValue / limitValue
            } else {
                frac = 1.0 - progressFraction
            }
            return String(format: "%.2f", frac)
        case .absoluteValues:
            if let remainingValue, let limitValue {
                return "\(Self.formatQuotaValue(remainingValue, unit: unit)) / \(Self.formatQuotaValue(limitValue, unit: unit))"
            } else if let remainingValue {
                return Self.formatQuotaValue(remainingValue, unit: unit)
            } else if let usedValue, let limitValue {
                let calcRemaining = max(0, limitValue - usedValue)
                return "\(Self.formatQuotaValue(calcRemaining, unit: unit)) / \(Self.formatQuotaValue(limitValue, unit: unit))"
            }
            return "Unavailable"
        }
    }

    var usageText: String {
        if let usedValue, let limitValue {
            return "\(Self.formatQuotaValue(usedValue, unit: unit)) / \(Self.formatQuotaValue(limitValue, unit: unit))"
        }
        if let usedPercent {
            return "\(Self.formatQuotaValue(usedPercent, unit: .percent)) used"
        }
        return "No usage detail"
    }

    fileprivate static func formatQuotaValue(_ value: Double, unit: ProviderQuotaUnit) -> String {
        switch unit {
        case .percent:
            let clamped = min(max(value, 0), 100)
            return "\(Int(clamped.rounded()))%"
        case .tokens:
            if value >= 1_000_000_000 {
                return String(format: "%.2fB", value / 1_000_000_000)
            }
            if value >= 1_000_000 {
                return String(format: "%.1fM", value / 1_000_000)
            }
            if value >= 1_000 {
                return String(format: "%.1fK", value / 1_000)
            }
            return "\(Int(value.rounded()))"
        case .requests, .sessions, .lines, .files, .count:
            if value >= 1_000 {
                return String(format: "%.1fK", value / 1_000)
            }
            if value.rounded() == value {
                return "\(Int(value))"
            }
            return String(format: "%.1f", value)
        case .currency, .credits:
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencySymbol = "$"
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
        case .fastCalls, .unknown:
            if value.rounded() == value {
                return "\(Int(value))"
            }
            return String(format: "%.1f", value)
        }
    }
}

public extension ProviderQuotaSnapshot {
    var hourlyBucket: ProviderQuotaBucket? {
        hourlyBucket(relativeTo: Date())
    }

    func hourlyBucket(relativeTo now: Date) -> ProviderQuotaBucket? {
        displayableQuotaBuckets(relativeTo: now).first { $0.windowKind == .rollingHours }
    }

    var weeklyBucket: ProviderQuotaBucket? {
        weeklyBucket(relativeTo: Date())
    }

    func weeklyBucket(relativeTo now: Date) -> ProviderQuotaBucket? {
        displayableQuotaBuckets(relativeTo: now).first(where: isWeeklyQuotaBucket)
    }

    var primaryDisplayableBucket: ProviderQuotaBucket? {
        primaryDisplayableBucket(relativeTo: Date())
    }

    func primaryDisplayableBucket(relativeTo now: Date) -> ProviderQuotaBucket? {
        displayableQuotaBuckets(relativeTo: now).min {
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
        }
    }

    func displayableQuotaBuckets(relativeTo now: Date) -> [ProviderQuotaBucket] {
        buckets.filter(\.isDisplayableQuotaSignal).map { $0.reconcilingElapsedWindow(asOf: now) }
    }

    private func isWeeklyQuotaBucket(_ bucket: ProviderQuotaBucket) -> Bool {
        if bucket.windowKind == .weekly { return true }
        guard bucket.windowKind == .rollingDays else { return false }

        let marker = "\(bucket.key) \(bucket.label)".lowercased()
        return marker.contains("week")
            || marker.contains("7 day")
            || marker.contains("7-day")
            || marker.contains("7d")
            || marker.contains("seven day")
    }

    private func primaryBucketPriority(for bucket: ProviderQuotaBucket) -> Int {
        let quotaProvider = AgentProvider.fromProviderID(providerID)
            ?? AgentProvider.fromPersistedToken(provider)
            ?? AgentProvider(rawValue: provider)
        let lowercasedKey = bucket.key.lowercased()
        let lowercasedLabel = bucket.label.lowercased()
        let marker = "\(lowercasedKey) \(lowercasedLabel)"

        // Demote auxiliary/non-plan buckets across all providers:
        if marker.contains("on-demand") || marker.contains("ondemand") || marker.contains("extra usage") || marker.contains("pay-as-you-go") || marker.contains("payg") {
            return 20
        }
        if marker.contains("cache") || marker.contains("hit rate") || marker.contains("passthrough") || marker.contains("custom proxy") {
            return 30
        }
        if marker.contains("droid core") || marker.contains("open-weight") {
            return 25
        }
        if marker.contains("mcp") || marker.contains("tool") {
            return 15
        }

        switch quotaProvider {
        case .cursor:
            if marker.contains("cursor-plan") || marker.contains("included usage") {
                return 0
            }
            if marker.contains("cursor-auto") || marker.contains("auto + composer") {
                return 1
            }
            if marker.contains("cursor-api") || marker.contains("api usage") {
                return 2
            }
            return 5

        case .factory:
            if marker.contains("7d") || marker.contains("7-day") || marker.contains("weekly") {
                return 0
            }
            if marker.contains("standard") {
                return 1
            }
            if marker.contains("30d") || marker.contains("monthly") {
                return 2
            }
            return 5

        case .claudeCode, .openClaude:
            if marker.contains("five-hour") || marker.contains("5-hour") || marker.contains("5h") {
                return 0
            }
            if marker.contains("seven-day") || marker.contains("7-day") || marker.contains("7d") {
                return 1
            }
            return 5

        case .antigravity:
            if marker.contains("active") {
                return 0
            }
            return 5

        case .zai:
            if marker.contains("5-hour") || marker.contains("5hour") || marker.contains("5h") {
                return 0
            }
            if marker.contains("weekly") || marker.contains("7d") || marker.contains("7-day") {
                return 1
            }
            if marker.contains("token") || marker.contains("api") {
                return 2
            }
            if marker.contains("time_limit") || marker.contains("time limit") {
                return 15
            }
            if marker == "limits" || marker == "limit" {
                return 18
            }
            return 5

        default:
            switch bucket.windowKind {
            case .rollingHours, .daily: return 0
            case .weekly, .rollingDays: return 1
            case .monthly: return 2
            case .lifetime: return 3
            case .custom: return 4
            }
        }
    }

    public var managementLink: URL? {
        guard let managementURL else { return nil }
        return URL(string: managementURL)
    }

    public var primaryBucket: ProviderQuotaBucket? {
        buckets.map { $0.reconcilingElapsedWindow() }.min {
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
        }
    }

    public var summaryText: String {
        guard let primaryBucket = primaryDisplayableBucket else {
            return statusMessage ?? ""
        }
        return "\(primaryBucket.label): \(primaryBucket.remainingText) left"
    }
}
