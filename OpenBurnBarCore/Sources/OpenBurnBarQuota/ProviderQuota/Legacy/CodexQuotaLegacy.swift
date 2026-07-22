import Foundation
import OpenBurnBarKernel

enum CodexQuotaLegacy {
    static func usageSnapshot(_ data: Data, now: Date) throws -> ProviderQuotaSnapshot {
        let payload = try JSONDecoder().decode(CodexUsagePayload.self, from: data)
        var buckets = rateLimitBuckets(
            payload.rateLimit,
            prefix: "codex",
            labelPrefix: nil,
            now: now
        )

        for additional in payload.additionalRateLimits.prefix(8) {
            let label = additional.limitName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            buckets.append(contentsOf: rateLimitBuckets(
                additional.rateLimit,
                prefix: "codex-\(slug(label))",
                labelPrefix: label,
                now: now
            ))
        }

        guard !buckets.isEmpty else {
            throw CodexOAuthQuotaError.invalidResponse
        }

        let plan = payload.planType?.capitalized ?? "Codex"
        return ProviderQuotaSnapshot(
            provider: .codex,
            fetchedAt: now,
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://chatgpt.com/codex/settings/usage",
            statusMessage: "\(plan) quota snapshot from the local Codex login session.",
            buckets: buckets
        )
    }

    private static func rateLimitBuckets(
        _ limit: CodexUsagePayload.RateLimit?,
        prefix: String,
        labelPrefix: String?,
        now: Date
    ) -> [ProviderQuotaBucket] {
        guard let limit else { return [] }
        var buckets: [ProviderQuotaBucket] = []
        if let primary = limit.primaryWindow {
            buckets.append(bucket(
                window: primary,
                key: "\(prefix)-5h",
                label: labelPrefix.map { "\($0) 5-hour window" } ?? "5-hour window",
                fallbackKind: .rollingHours,
                now: now
            ))
        }
        if let secondary = limit.secondaryWindow {
            buckets.append(bucket(
                window: secondary,
                key: "\(prefix)-7d",
                label: labelPrefix.map { "\($0) 7-day window" } ?? "7-day window",
                fallbackKind: .rollingDays,
                now: now
            ))
        }
        return buckets
    }

    private static func bucket(
        window: CodexUsagePayload.Window,
        key: String,
        label: String,
        fallbackKind: ProviderQuotaWindowKind,
        now: Date
    ) -> ProviderQuotaBucket {
        let used = min(max(window.usedPercent, 0), 100)
        return ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: windowKind(seconds: window.limitWindowSeconds) ?? fallbackKind,
            usedValue: used,
            limitValue: 100,
            remainingValue: max(0, 100 - used),
            usedPercent: used,
            resetsAt: resetDate(for: window, now: now),
            unit: .percent,
            isEstimated: false
        )
    }

    private static func resetDate(for window: CodexUsagePayload.Window, now: Date) -> Date? {
        if let resetAt = window.resetAt, resetAt > 0 {
            return Date(timeIntervalSince1970: TimeInterval(resetAt))
        }
        if let resetAfter = window.resetAfterSeconds, resetAfter >= 0 {
            return now.addingTimeInterval(TimeInterval(resetAfter))
        }
        return nil
    }

    private static func windowKind(seconds: Int?) -> ProviderQuotaWindowKind? {
        guard let seconds, seconds > 0 else { return nil }
        switch seconds {
        case 18_000:
            return .rollingHours
        case 604_800:
            return .rollingDays
        default:
            return seconds >= 86_400 ? .rollingDays : .rollingHours
        }
    }

    private static func slug(_ value: String) -> String {
        let lower = value.lowercased()
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "additional" : collapsed
    }
}

private struct CodexUsagePayload: Decodable {
    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        additionalRateLimits = try container.decodeIfPresent([AdditionalRateLimit].self, forKey: .additionalRateLimits) ?? []
    }

    struct AdditionalRateLimit: Decodable {
        let limitName: String
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case rateLimit = "rate_limit"
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let resetAt: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }
}
