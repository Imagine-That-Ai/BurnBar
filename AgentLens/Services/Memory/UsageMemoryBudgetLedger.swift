import Foundation

// MARK: - Usage Memory Budget Ledger (U5)
//
// Client-side belt-and-braces DAILY USD cap for BurnBar-cloud usage curation.
// The server already meters tokens per lane (U4 reserve/settle); this ledger is
// the local second belt that realizes `MemoryExtractionPolicy.defaultDailyCapUSD`
// ($0.50/day, previously reserved/unused) so a client bug, a clock-skewed
// server, or a compromised allowance can never turn the pipeline into an
// unbounded spender from THIS device. It estimates spend from a static price
// table — no plaintext, no per-call payloads, just two UserDefaults scalars.
final class UsageMemoryBudgetLedger: Sendable {
    private static let dayKeyDefaultsKey = "usageMemoryLedgerDayKey"
    private static let spentUSDDefaultsKey = "usageMemoryLedgerSpentUSD"

    /// Static per-lane price table (USD per token). Source: CoreWeave AI
    /// inference list pricing for the U4-pinned models, as of 2026-08
    /// (text lane deepseek-v4-flash $0.14/M input + $0.28/M output; multimodal
    /// lane minimax-m3 $0.23/M input + $0.96/M output). Deliberately static —
    /// a stale table over- or under-estimates by cents/day at most, and the
    /// server-side token meter remains the authoritative spend control.
    /// Cached prompt tokens are charged at the full input rate here
    /// (conservative overestimate; the cap is a ceiling, not an invoice).
    enum PriceTable {
        static func inputUSDPerToken(lane: UsageCurationLane) -> Double {
            switch lane {
            case .text: 0.14 / 1_000_000
            case .multimodal: 0.23 / 1_000_000
            }
        }

        static func outputUSDPerToken(lane: UsageCurationLane) -> Double {
            switch lane {
            case .text: 0.28 / 1_000_000
            case .multimodal: 0.96 / 1_000_000
            }
        }

        static func estimatedCostUSD(promptTokens: Int, outputTokens: Int, lane: UsageCurationLane) -> Double {
            Double(max(promptTokens, 0)) * inputUSDPerToken(lane: lane)
                + Double(max(outputTokens, 0)) * outputUSDPerToken(lane: lane)
        }
    }

    private let lock = NSLock()
    nonisolated(unsafe) private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - defaults: persistence store (tests inject a suite-scoped instance).
    ///   - now: injectable clock so tests drive day rollovers deterministically.
    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.now = now
    }

    /// Record one settled cloud call's usage against today's spend. A day
    /// rollover (UTC) since the last record resets the ledger first.
    func record(usage: UsageCurationTokenUsage, lane: UsageCurationLane) {
        let cost = PriceTable.estimatedCostUSD(
            promptTokens: usage.promptTokens,
            outputTokens: usage.outputTokens,
            lane: lane
        )
        lock.lock()
        defer { lock.unlock() }
        let spent = spendForToday()
        defaults.set(Self.dayKey(for: now()), forKey: Self.dayKeyDefaultsKey)
        defaults.set(spent + cost, forKey: Self.spentUSDDefaultsKey)
    }

    /// Estimated USD spent today (UTC). A day rollover reads as 0.
    var todaysSpendUSD: Double {
        lock.lock()
        defer { lock.unlock() }
        return spendForToday()
    }

    /// Whether today's spend is still under the daily cap. The default cap is
    /// `MemoryExtractionPolicy.defaultDailyCapUSD`; a zero or negative cap
    /// fail-closes (no cloud budget).
    func cloudBudgetOK(capUSD: Double = MemoryExtractionPolicy.defaultDailyCapUSD) -> Bool {
        guard capUSD > 0 else { return false }
        return todaysSpendUSD < capUSD
    }

    // MARK: Internals

    /// Caller must hold `lock`.
    private func spendForToday() -> Double {
        let storedDay = defaults.string(forKey: Self.dayKeyDefaultsKey)
        guard storedDay == Self.dayKey(for: now()) else { return 0 }
        return defaults.double(forKey: Self.spentUSDDefaultsKey)
    }

    /// UTC calendar day key ("2026-08-15"). UTC matches the server allowance
    /// windows, so both belts roll over together.
    static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
