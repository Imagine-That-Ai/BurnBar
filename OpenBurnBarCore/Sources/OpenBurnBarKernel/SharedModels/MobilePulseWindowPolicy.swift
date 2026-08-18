import Foundation

/// Pulse timeline scopes used by the mobile hero. Source oracle:
/// `PulseWindowMetricBuilder` in `OpenBurnBarMobile/Views/Pulse/PulseWindowMetrics.swift`.
public enum MobilePulseTimelineScope: String, Sendable, CaseIterable {
    case minute
    case hour
    case day
    case week
    case month
}

public struct MobilePulseUsageEvent: Sendable, Equatable {
    public let startMs: Int64
    public let endMs: Int64
    public let tokens: Int
    public let costUsd: Double

    public init(startMs: Int64, endMs: Int64, tokens: Int, costUsd: Double) {
        self.startMs = startMs
        self.endMs = endMs
        self.tokens = tokens
        self.costUsd = costUsd
    }

    /// iOS oracle: `max(startTime, endTime)`. Sync `updatedAt` is not an event time.
    public var eventDateMs: Int64 { max(startMs, endMs) }
}

public struct MobilePulseRollupTotals: Sendable, Equatable {
    public let requests: Int
    public let tokens: Int
    public let costUsd: Double

    public static let zero = MobilePulseRollupTotals(requests: 0, tokens: 0, costUsd: 0)

    public init(requests: Int, tokens: Int, costUsd: Double) {
        self.requests = requests
        self.tokens = tokens
        self.costUsd = costUsd
    }
}

public struct MobilePulseWindowResult: Sendable, Equatable {
    public let total: MobilePulseRollupTotals
    public let trailing: MobilePulseRollupTotals?

    public init(total: MobilePulseRollupTotals, trailing: MobilePulseRollupTotals?) {
        self.total = total
        self.trailing = trailing
    }
}

public enum MobilePulseLoadPresentation: String, Sendable, Equatable {
    case loading
    case failed
    case empty
    case live
    case staleRefreshFailed = "stale-refresh-failed"

    /// Failed / empty / stale-refresh must never render as a live $0 hero.
    public var looksLikeLiveZero: Bool { self == .live }
}

/// Shared Pulse/Burn window math. Authority: iOS `PulseWindowMetricBuilder`.
public enum MobilePulseWindowPolicy {
    public static let dayWindowMs: Int64 = 24 * 60 * 60 * 1_000

    public static func metrics(
        scope: MobilePulseTimelineScope,
        rollups: [String: MobilePulseRollupTotals],
        usages: [MobilePulseUsageEvent],
        nowMs: Int64
    ) -> MobilePulseWindowResult {
        switch scope {
        case .minute:
            return liveMetrics(usages: usages, startMs: nowMs - 60_000, endMs: nowMs, trailing: rollups["7d"])
        case .hour:
            return liveMetrics(usages: usages, startMs: nowMs - 3_600_000, endMs: nowMs, trailing: rollups["7d"])
        case .day:
            return liveMetrics(usages: usages, startMs: nowMs - dayWindowMs, endMs: nowMs, trailing: rollups["7d"])
        case .week:
            return MobilePulseWindowResult(total: rollups["7d"] ?? .zero, trailing: rollups["30d"])
        case .month:
            return MobilePulseWindowResult(total: rollups["30d"] ?? .zero, trailing: rollups["90d"])
        }
    }

    /// Firestore query start: floor `now - 24h` to the hour in `timeZoneIdentifier`.
    public static func liveQueryStartMs(nowMs: Int64, timeZoneIdentifier: String) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)
            ?? TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1_000)
        let rollingStart = now.addingTimeInterval(-Double(dayWindowMs) / 1_000)
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: rollingStart)
        let floored = calendar.date(from: components) ?? rollingStart
        return Int64((floored.timeIntervalSince1970 * 1_000).rounded())
    }

    public static func loadPresentation(
        isLoading: Bool,
        failed: Bool,
        hasCachedData: Bool
    ) -> MobilePulseLoadPresentation {
        if isLoading && !hasCachedData { return .loading }
        if failed { return hasCachedData ? .staleRefreshFailed : .failed }
        if !hasCachedData { return .empty }
        return .live
    }

    public static func currencyHero(costUsd: Double) -> String {
        max(0, costUsd).formatAsCost()
    }

    public static func tokensHero(tokens: Int) -> String {
        max(0, tokens).formatAsTokenVolume()
    }

    public static func quotaDedupKey(provider: String, accountId: String?, accountLabel: String?) -> String {
        let providerKey = provider.lowercased()
        let accountKey = accountId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "provider-level"
        return "\(providerKey)::\(accountKey.lowercased())"
    }

    public static func sortQuotaKeys(_ keys: [String]) -> [String] {
        keys.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    public static func pulseCost(costUsd: Double, costUSD: Double, cost: Double) -> Double {
        let raw = [costUsd, costUSD, cost].first { $0 != 0 } ?? 0
        return max(0, raw)
    }

    public static func pulseTokens(
        totalTokens: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        reasoningTokens: Int
    ) -> Int {
        let billed = max(0, inputTokens) + max(0, outputTokens) + max(0, cacheCreationTokens)
            + max(0, cacheReadTokens) + max(0, reasoningTokens)
        let raw = totalTokens != 0 ? totalTokens : billed
        return max(0, raw)
    }

    private static func liveMetrics(
        usages: [MobilePulseUsageEvent],
        startMs: Int64,
        endMs: Int64,
        trailing: MobilePulseRollupTotals?
    ) -> MobilePulseWindowResult {
        let rows = usages.filter { event in
            let at = event.eventDateMs
            return at >= startMs && at <= endMs
        }
        return MobilePulseWindowResult(
            total: MobilePulseRollupTotals(
                requests: rows.count,
                tokens: rows.reduce(0) { $0 + max(0, $1.tokens) },
                costUsd: rows.reduce(0) { $0 + max(0, $1.costUsd) }
            ),
            trailing: trailing
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
