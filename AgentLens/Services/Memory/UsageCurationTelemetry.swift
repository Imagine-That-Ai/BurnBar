import Foundation

// MARK: - Usage Curation Telemetry (U5)
//
// Per-call token accounting for the BurnBar-cloud curation lane, kept ONLY as
// numbers: token counts, call counts, and an estimated USD figure. No candidate
// text, no image bytes, no memory content — nothing plaintext is ever recorded.
// The persisted monthly aggregate backs the acceptance-criteria measurement
// ("what did cloud curation cost this month?") and the settings surface's
// usage readout.

/// Persisted monthly aggregate (UserDefaults JSON). One month at a time — a
/// month rollover starts a fresh aggregate.
struct UsageCurationMonthlyTelemetry: Codable, Equatable, Sendable {
    /// UTC month key, e.g. "2026-08".
    var monthKey: String
    var promptTokens: Int
    var outputTokens: Int
    var cachedTokens: Int
    var callCount: Int
    var estimatedUSD: Double

    static func empty(monthKey: String) -> UsageCurationMonthlyTelemetry {
        UsageCurationMonthlyTelemetry(
            monthKey: monthKey,
            promptTokens: 0,
            outputTokens: 0,
            cachedTokens: 0,
            callCount: 0,
            estimatedUSD: 0
        )
    }
}

/// `ModelUsage`-style per-call token breakdown: the server's `cachedTokens`
/// (a subset of `promptTokens`) maps onto the app's cache-read convention,
/// where `inputTokens` counts only uncached input (see `ModelUsage` /
/// `CacheEfficiency` in AgentProvider.swift).
struct UsageCurationCallTokens: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var totalTokens: Int
}

/// Records per-call curation usage into the monthly aggregate. Sendable and
/// lock-guarded so the (off-main) pipeline worker can record directly.
final class UsageCurationTelemetry: Sendable {
    private static let aggregateDefaultsKey = "usageCurationTelemetryMonthly"

    private let lock = NSLock()
    nonisolated(unsafe) private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.now = now
    }

    /// Map one server usage report onto the app's cache-aware token fields.
    static func callTokens(from usage: UsageCurationTokenUsage) -> UsageCurationCallTokens {
        let cacheRead = min(max(usage.cachedTokens, 0), max(usage.promptTokens, 0))
        return UsageCurationCallTokens(
            inputTokens: max(usage.promptTokens, 0) - cacheRead,
            outputTokens: max(usage.outputTokens, 0),
            cacheReadTokens: cacheRead,
            totalTokens: max(usage.promptTokens, 0) + max(usage.outputTokens, 0)
        )
    }

    /// Fold one settled cloud call into the current month's aggregate. A month
    /// rollover (UTC) discards the previous month's aggregate first.
    func record(usage: UsageCurationTokenUsage) {
        let cost = UsageMemoryBudgetLedger.PriceTable.estimatedCostUSD(
            promptTokens: usage.promptTokens,
            outputTokens: usage.outputTokens,
            lane: usage.lane
        )
        lock.lock()
        defer { lock.unlock() }
        var aggregate = loadCurrentMonth()
        aggregate.promptTokens += max(usage.promptTokens, 0)
        aggregate.outputTokens += max(usage.outputTokens, 0)
        aggregate.cachedTokens += max(usage.cachedTokens, 0)
        aggregate.callCount += 1
        aggregate.estimatedUSD += cost
        store(aggregate)
    }

    /// The current UTC month's aggregate (zeroed when nothing was recorded this
    /// month yet). Exposed for the acceptance-criteria measurement and the
    /// settings usage readout.
    var currentMonth: UsageCurationMonthlyTelemetry {
        lock.lock()
        defer { lock.unlock() }
        return loadCurrentMonth()
    }

    // MARK: Internals

    /// Caller must hold `lock`.
    private func loadCurrentMonth() -> UsageCurationMonthlyTelemetry {
        let month = Self.monthKey(for: now())
        guard let data = defaults.data(forKey: Self.aggregateDefaultsKey),
              let stored = try? JSONDecoder().decode(UsageCurationMonthlyTelemetry.self, from: data), // try?-ok(optional telemetry decode, reset)
              stored.monthKey == month
        else {
            return .empty(monthKey: month)
        }
        return stored
    }

    /// Caller must hold `lock`.
    private func store(_ aggregate: UsageCurationMonthlyTelemetry) {
        guard let data = try? JSONEncoder().encode(aggregate) else { return } // try?-ok(encode telemetry, skip)
        defaults.set(data, forKey: Self.aggregateDefaultsKey)
    }

    /// UTC month key ("2026-08"), aligned with the server's monthly allowance
    /// windows.
    static func monthKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}
