/**
 * @fileoverview One cost rule (Wave 2.5, decision 3).
 *
 * `costUSD` is the canonical cost field (the TypeSpec spelling).
 * `costUsd` and `cost` are read-only legacy fallbacks behind this rule — read
 * them only through `effectiveCostUSD`, never directly. Normative spec plus
 * the cross-client fixture live in `tests/fixtures/cost-rule/`; the Kotlin
 * (`CostRule.kt`) and Swift (`CostRule`) implementations must agree with this
 * file byte-for-byte on `v1.json`.
 */

/** A usage event's cost spellings as read from Firestore (all optional). */
export interface CostSpellings {
  costUSD?: unknown;
  costUsd?: unknown;
  cost?: unknown;
}

function isUsableCost(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

/**
 * The first value in [costUSD, costUsd, cost] that is a finite number >= 0,
 * else 0. Zero wins (it is valid data); negatives, NaN, infinities, and
 * non-numbers (including numeric strings — producers must write numbers)
 * fall through to the next spelling.
 */
export function effectiveCostUSD(event: CostSpellings): number {
  const candidates = [event.costUSD, event.costUsd, event.cost];
  for (const candidate of candidates) {
    if (isUsableCost(candidate)) return candidate;
  }
  return 0;
}

/** Sum of `effectiveCostUSD` over events, in order (fixture total). */
export function totalCostUSD(events: CostSpellings[]): number {
  return events.reduce((sum, event) => sum + effectiveCostUSD(event), 0);
}
