package com.openburnbar.data.models

/**
 * One cost rule (Wave 2.5, decision 3).
 *
 * `costUSD` is the canonical cost field (the TypeSpec spelling). `costUsd` and
 * `cost` are read-only legacy fallbacks behind this rule — read them only
 * through [effectiveCostUSD], never directly. Normative spec plus the
 * cross-client fixture live in `tests/fixtures/cost-rule/`; the TypeScript
 * (`costRule.ts`) and Swift (`CostRule`) implementations must agree with this
 * file byte-for-byte on `v1.json`.
 */
object CostRule {
    /**
     * The first value in [costUSD, costUsd, cost] that is finite and >= 0,
     * else 0.0. Zero wins (it is valid data); negatives, NaN, infinities, and
     * nulls (absent fields) fall through to the next spelling. Callers pass
     * null for unparseable payloads — producers must write numbers, and this
     * rule never coerces strings.
     */
    fun effectiveCostUSD(costUSD: Double?, costUsd: Double?, cost: Double?): Double {
        for (candidate in listOf(costUSD, costUsd, cost)) {
            if (candidate != null && candidate.isFinite() && candidate >= 0.0) return candidate
        }
        return 0.0
    }

    /** Sum of [effectiveCostUSD] over events, in order (fixture total). */
    fun totalCostUSD(costs: List<CostSpellings>): Double =
        costs.sumOf { effectiveCostUSD(it.costUSD, it.costUsd, it.cost) }
}

/** A usage event's cost spellings (all optional; null = absent/unusable). */
data class CostSpellings(
    val costUSD: Double? = null,
    val costUsd: Double? = null,
    val cost: Double? = null,
)
