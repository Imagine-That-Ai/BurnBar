import {
  DEFAULT_ENTITLEMENT_CATALOG,
  productIDsForFeature,
  type EntitlementCatalog,
  type EntitlementFeature,
} from "./catalog.js";

/**
 * A Firestore-ish timestamp: the predicate only depends on `toMillis()`, so it
 * accepts the firebase-admin `Timestamp` without importing firebase-admin into the
 * shared package (keeping it dependency-free, like signal-envelope-contracts).
 */
interface MillisTimestamp {
  toMillis(): number;
}

function hasMillis(value: unknown): value is MillisTimestamp {
  return (
    typeof value === "object" &&
    value !== null &&
    "toMillis" in value &&
    typeof (value as { toMillis: unknown }).toMillis === "function"
  );
}

function millisFromExpiryValue(value: unknown): number {
  if (hasMillis(value)) return value.toMillis();
  if (value instanceof Date) return value.getTime();
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : Number.NaN;
  }
  return Number.NaN;
}

/**
 * Canonical expiry resolution for an entitlement document, in epoch millis.
 *
 * `expireAt` is the primary field (functions + relay write a Firestore Timestamp
 * here); `expiresAt` is the legacy/ISO mirror. Each field is resolved as the UNION
 * of every prior copy's accepted shapes, so this one function is a strict superset
 * that none of them regress on:
 *   - Firestore Timestamp (`toMillis()`) — functions + relay.
 *   - native `Date` — hosted-mcp's `dateFromRaw` accepted this.
 *   - ISO-8601 string (`Date.parse`) — all three; hosted-mcp accepted a string in
 *     `expireAt` too (it read `expireAt ?? expiresAt` through one string-aware coercer).
 *
 * Returns `Number.NaN` when nothing yields a finite value, so the caller's
 * `Number.isFinite(...) && expiry > now` guard fails closed.
 */
export function entitlementExpiryMillis(data: Record<string, unknown> | undefined): number {
  if (!data) return Number.NaN;
  const fromExpireAt = millisFromExpiryValue(data.expireAt);
  if (Number.isFinite(fromExpireAt)) return fromExpireAt;
  return millisFromExpiryValue(data.expiresAt);
}

/** Result of {@link evaluateEntitlement}: active flag plus the resolved expiry. */
export interface EntitlementEvaluation {
  active: boolean;
  /** Resolved expiry in epoch millis, or `undefined` when unparseable/absent. */
  expiresAtMs?: number;
}

/**
 * Pure, time-injectable core. A document grants `feature` iff:
 *   - `data.active === true`, AND
 *   - its `productID` is in the feature's product-ID set (per `catalog`), AND
 *   - its resolved expiry is finite and strictly in the future relative to `nowMs`.
 *
 * `nowMs` is injectable for deterministic tests; production callers omit it.
 */
export function evaluateEntitlement(
  data: Record<string, unknown> | undefined,
  feature: EntitlementFeature,
  options: { catalog?: EntitlementCatalog; nowMs?: number } = {},
): EntitlementEvaluation {
  if (!data || data.active !== true) return { active: false };
  const productID = typeof data.productID === "string" ? data.productID : "";
  const allowed = productIDsForFeature(feature, options.catalog ?? DEFAULT_ENTITLEMENT_CATALOG);
  if (!allowed.has(productID)) return { active: false };
  const expiresAtMs = entitlementExpiryMillis(data);
  const now = options.nowMs ?? Date.now();
  if (!Number.isFinite(expiresAtMs) || expiresAtMs <= now) {
    return { active: false, expiresAtMs: Number.isFinite(expiresAtMs) ? expiresAtMs : undefined };
  }
  return { active: true, expiresAtMs };
}

/**
 * Boolean form of {@link evaluateEntitlement} — the seam that replaces the hand-rolled
 * `isActive*Entitlement(...)` copies. Returns true iff the Firestore document grants
 * `feature` and has not expired.
 */
export function isActiveEntitlement(
  data: Record<string, unknown> | undefined,
  feature: EntitlementFeature,
  options: { catalog?: EntitlementCatalog; nowMs?: number } = {},
): boolean {
  return evaluateEntitlement(data, feature, options).active;
}
