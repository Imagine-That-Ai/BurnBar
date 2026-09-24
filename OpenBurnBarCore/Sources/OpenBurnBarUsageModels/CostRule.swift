import Foundation

/// One cost rule (Wave 2.5, decision 3).
///
/// `costUSD` is the canonical cost field (the TypeSpec spelling). `costUsd`
/// and `cost` are read-only legacy fallbacks behind this rule — read them
/// only through `effectiveCostUSD`, never directly. Normative spec plus the
/// cross-client fixture live in `tests/fixtures/cost-rule/`; the TypeScript
/// (`costRule.ts`) and Kotlin (`CostRule.kt`) implementations must agree with
/// this file byte-for-byte on `v1.json`.
public enum CostRule {
    /// The first value in `[costUSD, costUsd, cost]` that is finite and ≥ 0,
    /// else `0`. Zero wins (it is valid data); negatives, NaN, infinities,
    /// and nils (absent fields) fall through to the next spelling. Callers
    /// pass nil for unparseable payloads — producers must write numbers, and
    /// this rule never coerces strings.
    public static func effectiveCostUSD(costUSD: Double?, costUsd: Double?, cost: Double?) -> Double {
        for candidate in [costUSD, costUsd, cost] {
            if let candidate, candidate.isFinite, candidate >= 0 {
                return candidate
            }
        }
        return 0
    }

    /// Sum of `effectiveCostUSD` over events, in order (fixture total).
    public static func totalCostUSD(_ costs: [CostSpellings]) -> Double {
        costs.reduce(0) { $0 + effectiveCostUSD(costUSD: $1.costUSD, costUsd: $1.costUsd, cost: $1.cost) }
    }
}

/// A usage event's cost spellings (all optional; nil = absent/unusable).
public struct CostSpellings: Sendable {
    public let costUSD: Double?
    public let costUsd: Double?
    public let cost: Double?

    public init(costUSD: Double? = nil, costUsd: Double? = nil, cost: Double? = nil) {
        self.costUSD = costUSD
        self.costUsd = costUsd
        self.cost = cost
    }
}
