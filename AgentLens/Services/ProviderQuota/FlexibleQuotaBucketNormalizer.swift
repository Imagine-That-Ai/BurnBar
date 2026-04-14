import Foundation
import OpenBurnBarCore

enum FlexibleQuotaBucketNormalizer {

    // MARK: - Date Formatters

    private static let zaiDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    // MARK: - Flexible Bucket Extraction

    static func extractFlexibleBuckets(from object: Any, provider: AgentProvider, endpointLabel: String) -> [ProviderQuotaBucket] {
        let unwrapped = unwrapDataEnvelope(object)
        var buckets = recurseBuckets(in: unwrapped, provider: provider, path: [endpointLabel])
        buckets.sort {
            let lhsPriority = bucketSortPriority(for: provider, bucket: $0)
            let rhsPriority = bucketSortPriority(for: provider, bucket: $1)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            let lhsRemaining = $0.remainingPercent ?? -1
            let rhsRemaining = $1.remainingPercent ?? -1
            if lhsRemaining == rhsRemaining {
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            return lhsRemaining > rhsRemaining
        }

        var seen = Set<String>()
        return buckets.filter { bucket in
            seen.insert(bucket.key).inserted
        }
    }

    static func recurseBuckets(in object: Any, provider: AgentProvider, path: [String]) -> [ProviderQuotaBucket] {
        if let dictionary = object as? [String: Any] {
            if let bucket = makeBucket(from: dictionary, provider: provider, path: path) {
                return [bucket]
            }

            var buckets: [ProviderQuotaBucket] = []
            for (key, value) in dictionary {
                buckets.append(contentsOf: recurseBuckets(in: value, provider: provider, path: path + [key]))
            }
            return buckets
        }

        if let array = object as? [Any] {
            return array.enumerated().flatMap { index, value in
                recurseBuckets(in: value, provider: provider, path: path + ["item\(index)"])
            }
        }

        return []
    }

    static func makeBucket(from dictionary: [String: Any], provider: AgentProvider, path: [String]) -> ProviderQuotaBucket? {
        let usageRatio = ratio(in: dictionary, keys: [
            "usage", "usageInfo", "usage_info", "quotaUsage", "quota_usage", "quotaStatus", "quota_status", "status", "summary"
        ])
        let rawUsedPercent = number(in: dictionary, keys: [
            "used_percent", "usedPercent", "used_percentage", "usage_percent", "usagePercent", "percentage", "usedRate", "usageRate"
        ])
        // If "percentage" field exceeds 100, it's actually a raw count, not a percent
        let usedPercent: Double? = (rawUsedPercent.flatMap { $0 >= 0 && $0 <= 100 ? $0 : nil })
        var usedValue = number(in: dictionary, keys: [
            "used", "used_num", "usedNum", "currentUsage", "current_usage", "currentValue", "current_value",
            "consumed", "consumed_num", "consumedNum", "current", "requestUsed", "requestsUsed",
            "current_interval_used_count", "currentIntervalUsedCount"
        ])
        var limitValue = number(in: dictionary, keys: [
            "limit", "limit_num", "limitNum", "total", "totalLimit", "total_limit",
            "max", "maxValue", "max_value", "quota", "quotaLimit", "quota_limit",
            "usageLimit", "usage_limit", "requestLimit", "requestsLimit", "totalUsage",
            "current_interval_total_count", "currentIntervalTotalCount"
        ])
        var remainingValue = number(in: dictionary, keys: [
            "remaining", "remain", "remain_num", "remainNum", "remaining_quota", "remainingQuota",
            "quota_remain", "quotaRemain", "remainingValue", "available", "available_num", "availableNum", "left",
            "current_interval_remaining_count", "currentIntervalRemainingCount",
            "current_interval_remains_count", "currentIntervalRemainsCount"
        ])
        let resetsAt = resolvedResetDate(in: dictionary)
        let intervalStart = date(in: dictionary, keys: ["start_time", "startTime"])
        let intervalHint = string(in: dictionary, keys: [
            "window", "quota_cycle", "quotaCycle", "cycle", "period", "period_name", "periodName"
        ])
        let miniMaxRemainingUsageCount = provider == .minimax
            ? number(in: dictionary, keys: [
                "current_interval_usage_count", "currentIntervalUsageCount"
            ])
            : nil

        if provider == .minimax, remainingValue == nil {
            remainingValue = miniMaxRemainingUsageCount
        }
        if provider == .minimax, usedValue == nil, let limitValue, let miniMaxRemainingUsageCount {
            usedValue = max(limitValue - miniMaxRemainingUsageCount, 0)
        }

        if usedValue == nil {
            usedValue = usageRatio?.used
        }
        if limitValue == nil {
            limitValue = usageRatio?.limit
        }
        if usedValue == nil, let remainingValue, let limitValue {
            usedValue = max(limitValue - remainingValue, 0)
        }
        if remainingValue == nil, let usedValue, let limitValue {
            remainingValue = max(limitValue - usedValue, 0)
        }

        guard usedPercent != nil || usedValue != nil || limitValue != nil || remainingValue != nil else {
            return nil
        }

        let rawLabel = string(in: dictionary, keys: [
            "label", "title", "name",
            "model", "model_name", "modelName",
            "resource", "resource_name", "resourceName",
            "quota_name", "quotaName"
        ])
            ?? string(in: dictionary, keys: ["window", "type"])
            ?? bestPathLabel(from: path)
            ?? "quota"
        // Z.ai uses unit+number fields to distinguish quota windows
        let zaiUnit = provider == .zai ? number(in: dictionary, keys: ["unit"]) : nil
        let zaiNumber = provider == .zai ? number(in: dictionary, keys: ["number"]) : nil
        let windowKind = inferWindowKind(
            from: intervalHint ?? rawLabel,
            provider: provider,
            intervalStart: intervalStart,
            resetsAt: resetsAt
        )
        let label = normalizedBucketLabel(
            rawLabel,
            provider: provider,
            inferredWindowKind: windowKind,
            unit: zaiUnit,
            number: zaiNumber
        )
        let unit = inferUnit(provider: provider, label: rawLabel, dictionary: dictionary, usedPercent: usedPercent, limitValue: limitValue)
        var normalizedRemaining: Double?
        if unit == .percent, let usedPercent {
            // When we have a reliable used-percent, compute remaining from it.
            // Raw "remaining" fields from APIs are often counts, not percentages.
            normalizedRemaining = max(0, 100 - usedPercent)
        } else if let usedPercent {
            normalizedRemaining = max(0, 100 - usedPercent)
        } else if let remainingValue {
            normalizedRemaining = remainingValue
        } else if let usedValue, let limitValue {
            normalizedRemaining = max(limitValue - usedValue, 0)
        } else {
            normalizedRemaining = nil
        }
        // Clamp percent-unit remaining so raw API counts never leak as "3896%"
        if unit == .percent, let nr = normalizedRemaining {
            normalizedRemaining = min(max(nr, 0), 100)
        }

        return ProviderQuotaBucket(
            key: "\(provider.rawValue.lowercased())-\(sanitizeKey(label))-\(sanitizeKey(bestPathLabel(from: path) ?? rawLabel))",
            label: label,
            windowKind: windowKind,
            usedValue: usedPercent != nil && unit == .percent ? usedPercent : usedValue,
            limitValue: unit == .percent ? 100 : limitValue,
            remainingValue: normalizedRemaining,
            usedPercent: usedPercent ?? inferPercent(usedValue: usedValue, limitValue: limitValue),
            resetsAt: resetsAt,
            unit: unit,
            isEstimated: false
        )
    }

    // MARK: - Inference Helpers

    static func inferWindowKind(
        from label: String,
        provider: AgentProvider,
        intervalStart: Date? = nil,
        resetsAt: Date? = nil
    ) -> ProviderQuotaWindowKind {
        let lowercased = label.lowercased()
        if lowercased.contains("5hour") || lowercased.contains("5-hour") || lowercased.contains("five") {
            return .rollingHours
        }
        if lowercased.contains("7day") || lowercased.contains("7-day") || lowercased.contains("seven") {
            return .rollingDays
        }
        if lowercased.contains("day") {
            return .daily
        }
        if lowercased.contains("week") {
            return .weekly
        }
        if lowercased.contains("month") {
            return .monthly
        }
        if let intervalStart, let resetsAt {
            let duration = resetsAt.timeIntervalSince(intervalStart)
            if provider == .minimax {
                switch duration {
                case 0..<(18 * 60 * 60):
                    return .rollingHours
                case 6 * 24 * 60 * 60...(8 * 24 * 60 * 60):
                    return .rollingDays
                default:
                    break
                }
            }
            switch duration {
            case 0..<(18 * 60 * 60):
                return .rollingHours
            case 18 * 60 * 60..<(36 * 60 * 60):
                return .daily
            case 36 * 60 * 60..<(9 * 24 * 60 * 60):
                return .weekly
            case 9 * 24 * 60 * 60...(45 * 24 * 60 * 60):
                return .monthly
            default:
                break
            }
        }
        return .custom
    }

    static func inferUnit(
        provider: AgentProvider,
        label: String,
        dictionary: [String: Any],
        usedPercent: Double?,
        limitValue: Double?
    ) -> ProviderQuotaUnit {
        if usedPercent != nil {
            return .percent
        }
        let lowercased = label.lowercased()
        if lowercased.contains("token") {
            return .tokens
        }
        if lowercased.contains("request") || lowercased.contains("prompt") || lowercased.contains("usage") {
            return .requests
        }
        if provider == .zai,
           let type = string(in: dictionary, keys: ["type"])?.lowercased(),
           type.contains("time_limit") {
            return .requests
        }
        if provider == .minimax,
           number(in: dictionary, keys: ["current_interval_total_count", "currentIntervalTotalCount"]) != nil {
            return .requests
        }
        if limitValue != nil {
            return .count
        }
        return .percent
    }

    static func inferPercent(usedValue: Double?, limitValue: Double?) -> Double? {
        guard let usedValue, let limitValue, limitValue > 0 else { return nil }
        return min(max((usedValue / limitValue) * 100, 0), 100)
    }

    static func resolvedResetDate(in dictionary: [String: Any], now: Date = Date()) -> Date? {
        if let explicitReset = date(in: dictionary, keys: [
            "resets_at", "reset_at", "resetTime", "reset_time", "nextResetAt", "next_reset_at", "next_reset_time",
            "expireAt", "expiresAt", "end_time", "endTime"
        ]) {
            return explicitReset
        }

        if let milliseconds = number(in: dictionary, keys: ["remains_time", "remainsTime"]), milliseconds > 0 {
            return now.addingTimeInterval(milliseconds / 1000)
        }

        guard let seconds = number(in: dictionary, keys: ["remaining_time", "remainingTime"]), seconds > 0 else {
            return nil
        }
        return now.addingTimeInterval(seconds)
    }

    static func normalizedBucketLabel(
        _ label: String,
        provider: AgentProvider,
        inferredWindowKind: ProviderQuotaWindowKind? = nil,
        unit: Double? = nil,
        number: Double? = nil
    ) -> String {
        let lowercased = label.lowercased()
        if provider == .zai {
            if lowercased.contains("tokens_limit") {
                // Z.ai API uses unit+number to distinguish windows:
                //   unit=3, number=5 → 5-hour rolling token quota
                //   unit=6, number=1 → weekly token quota
                if let unit, let number {
                    if Int(unit) == 6 && Int(number) == 1 {
                        return "Token usage (Weekly)"
                    }
                    if Int(unit) == 3 && Int(number) == 5 {
                        return "Token usage (5-hour)"
                    }
                }
                // Fallback if unit/number not available
                return "Token usage (5-hour)"
            }
            if lowercased.contains("time_limit") {
                return "MCP usage (1 month)"
            }
        }
        if lowercased.contains("five") || lowercased.contains("5hour") || lowercased.contains("5-hour") {
            return "5-hour window"
        }
        if lowercased.contains("seven") || lowercased.contains("7day") || lowercased.contains("7-day") || lowercased.contains("week") {
            return "7-day window"
        }
        if lowercased.contains("day") {
            return "Daily quota"
        }
        if lowercased.contains("month") {
            return "Monthly quota"
        }
        if provider == .minimax, let inferredWindowKind {
            switch inferredWindowKind {
            case .rollingHours:
                return "5-hour window"
            case .rollingDays, .weekly:
                return "7-day window"
            case .daily:
                return "Daily quota"
            case .monthly:
                return "Monthly quota"
            case .custom:
                break
            }
        }
        return label
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    static func bucketSortPriority(for provider: AgentProvider, bucket: ProviderQuotaBucket) -> Int {
        guard provider == .zai else { return 0 }
        let lowercased = bucket.label.lowercased()
        if lowercased.contains("5-hour") || lowercased.contains("5hour") {
            // 5h token window is the most urgent
            return 0
        }
        if lowercased.contains("token") || lowercased.contains("api") {
            // Weekly or other token windows
            return 1
        }
        if lowercased.contains("mcp") || lowercased.contains("tool") || lowercased.contains("time_limit") || lowercased.contains("time limit") {
            return 2
        }
        if lowercased == "limits" || lowercased == "limit" {
            return 3
        }
        return 1
    }

    static func bestPathLabel(from path: [String]) -> String? {
        path.reversed().first { component in
            let normalized = normalizeJSONKey(component)
            return !component.hasPrefix("item")
                && normalized != "data"
                && normalized != "minimax"
                && normalized != "zai"
                && normalized != "baseresp"
                && normalized != "quotalist"
                && normalized != "modelremains"
                && normalized != "resourceremains"
        }
    }

    static func sanitizeKey(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    // MARK: - JSON Parsing Helpers

    static func number(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = value(in: dictionary, matching: key) {
                if let number = value as? NSNumber {
                    return number.doubleValue
                }
                if let string = value as? String, let parsed = parseNumericValue(from: string) {
                    return parsed
                }
            }
        }
        return nil
    }

    static func string(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = value(in: dictionary, matching: key) as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func date(in dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = value(in: dictionary, matching: key) else { continue }
            if let date = parseDateValue(value) {
                return date
            }
        }
        return nil
    }

    static func value(in dictionary: [String: Any], matching requestedKey: String) -> Any? {
        let normalizedRequested = normalizeJSONKey(requestedKey)
        var bestMatch: (score: Int, value: Any)?
        let allowAffixFuzzyMatch = normalizedRequested.count >= 8
        let allowContainFuzzyMatch = normalizedRequested.count >= 12
        let requestLooksTemporal = keyLooksTemporal(normalizedRequested)

        for (key, value) in dictionary {
            let normalizedKey = normalizeJSONKey(key)
            let keyLooksTemporal = keyLooksTemporal(normalizedKey)
            let score: Int
            if normalizedKey == normalizedRequested {
                score = 3
            } else if allowAffixFuzzyMatch,
                      keyLooksTemporal == requestLooksTemporal,
                      (normalizedKey.hasSuffix(normalizedRequested) || normalizedKey.hasPrefix(normalizedRequested)) {
                score = 2
            } else if allowContainFuzzyMatch,
                      keyLooksTemporal == requestLooksTemporal,
                      normalizedKey.contains(normalizedRequested) {
                score = 1
            } else {
                continue
            }

            if score > (bestMatch?.score ?? -1) {
                bestMatch = (score, value)
            }
        }

        return bestMatch?.value
    }

    static func normalizeJSONKey(_ key: String) -> String {
        key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    }

    static func keyLooksTemporal(_ key: String) -> Bool {
        key.hasSuffix("time")
            || key.hasSuffix("at")
            || key.contains("reset")
            || key.contains("expire")
            || key.contains("window")
            || key.contains("period")
    }

    static func ratio(in dictionary: [String: Any], keys: [String]) -> (used: Double, limit: Double)? {
        for key in keys {
            guard let value = value(in: dictionary, matching: key) else { continue }
            if let string = value as? String, let parsed = parseRatioValues(from: string) {
                return parsed
            }
            if let array = value as? [Any], array.count >= 2,
               let first = array[0] as? NSNumber,
               let second = array[1] as? NSNumber {
                return (first.doubleValue, second.doubleValue)
            }
        }
        return nil
    }

    static func parseNumericValue(from string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("/") else { return nil }

        let normalized = trimmed.replacingOccurrences(of: ",", with: "")
        if let direct = Double(normalized) {
            return direct
        }

        let pattern = #"[-+]?\d*\.?\d+"#
        guard let range = normalized.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Double(String(normalized[range]))
    }

    static func parseRatioValues(from string: String) -> (used: Double, limit: Double)? {
        let normalized = string.replacingOccurrences(of: ",", with: "")
        let slashParts = normalized.split(separator: "/")
        if slashParts.count == 2,
           let used = parseNumericValue(from: String(slashParts[0])),
           let limit = parseNumericValue(from: String(slashParts[1])) {
            return (used, limit)
        }

        if normalized.localizedCaseInsensitiveContains(" of ")
            || normalized.localizedCaseInsensitiveContains(" out of ") {
            let matches = normalized
                .components(separatedBy: CharacterSet(charactersIn: "0123456789.-").inverted)
                .filter { !$0.isEmpty }
            if matches.count >= 2,
               let used = Double(matches[0]),
               let limit = Double(matches[1]) {
                return (used, limit)
            }
        }

        return nil
    }

    static func unwrapDataEnvelope(_ object: Any) -> Any {
        guard let dictionary = object as? [String: Any] else { return object }
        if let data = dictionary["data"] {
            return data
        }
        return dictionary
    }

    static func parseDateValue(_ value: Any) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            if raw > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: raw / 1000)
            }
            if raw > 1_000_000_000 {
                return Date(timeIntervalSince1970: raw)
            }
        }
        if let string = value as? String {
            if let isoDate = ThreadSafeISO8601DateFormatter.parse(string) {
                return isoDate
            }
            if let numeric = Double(string), numeric > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: numeric / 1000)
            }
            if let numeric = Double(string), numeric > 1_000_000_000 {
                return Date(timeIntervalSince1970: numeric)
            }
            if let date = zaiDateFormatter.date(from: string) {
                return date
            }
        }
        return nil
    }

}

func quotaNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
