import Foundation
import OpenBurnBarKernel

enum ClaudeQuotaLegacy {
    private static let windowCandidates: [(key: String, label: String, kind: ProviderQuotaWindowKind)] = [
        ("five_hour", "5-hour window", .rollingHours),
        ("seven_day", "7-day window", .rollingDays),
        ("seven_day_sonnet", "7-day Sonnet window", .rollingDays),
        ("seven_day_opus", "7-day Opus window", .rollingDays),
        ("seven_day_oauth_apps", "7-day OAuth Apps window", .rollingDays)
    ]

    static func buckets(from rateLimits: ClaudeRateLimits) -> [ProviderQuotaBucket] {
        windowCandidates.compactMap { key, label, windowKind in
            guard let window = rateLimits.window(named: key) else { return nil }
            guard window.usedPercentage != nil || window.remainingPercentage != nil else {
                return nil
            }
            return ProviderQuotaBucket(
                key: "claude-\(FlexibleQuotaBucketNormalizer.sanitizeKey(key))",
                label: label,
                windowKind: windowKind,
                usedValue: window.usedPercentage,
                limitValue: 100,
                remainingValue: window.remainingPercentage,
                usedPercent: window.usedPercentage,
                resetsAt: window.resetsAt,
                unit: .percent,
                isEstimated: false
            )
        }
    }
}
