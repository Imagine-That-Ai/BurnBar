/**
 * @fileoverview Write-ordering guards for paid entitlement documents.
 *
 * Provider webhooks arrive out of order and are redelivered, so a naive
 * last-write-wins on `users/{uid}/entitlements/{id}` lets a stale replay
 * resurrect a cancelled subscription or shorten a live one. These predicates
 * are the ordering contract every entitlement write is checked against inside
 * the write transaction, and they are pure so each ordering case is testable
 * without Firestore.
 */

import { isTimestampWithToMillis } from "../../guards.js";
import { PROMO_ENTITLEMENT_SOURCE } from "../../promoCampaigns.js";
import { sameEntitlementWriteSource } from "./entitlementWriteSource.js";

export function paidEntitlementWriteWouldDowngrade(
  existing: Record<string, unknown> | undefined,
  incoming: {
    source: string;
    expiresAtMillis: number;
    active: boolean;
    externalSubscriptionID?: string;
    purchaseTokenHash?: string;
    nowMillis?: number;
  },
): boolean {
  if (!existing || existing.active !== true) return false;
  const existingExpiresAtMillis = entitlementExpiresAtMillis(existing);
  const nowMillis = incoming.nowMillis ?? Date.now();
  if (!existingExpiresAtMillis || existingExpiresAtMillis <= nowMillis) return false;

  // Promotional grants and paid receipts rank by trust, not by expiry. A promo
  // grant carries a deliberately far-future expiry, so the generic "shorter
  // expiry = downgrade" rule below would read every real purchase as a
  // downgrade and every promo write as an upgrade — exactly backwards.
  const existingIsPromoGrant = existing.source === PROMO_ENTITLEMENT_SOURCE;
  const incomingIsPromoGrant = incoming.source === PROMO_ENTITLEMENT_SOURCE;
  if (existingIsPromoGrant !== incomingIsPromoGrant) {
    // A verified purchase (or operator bridge) always supersedes a promo grant:
    // the subscriber's real billing lifecycle has to own the document, or their
    // cancellation could never take effect.
    if (existingIsPromoGrant) return false;
    // The mirror image: a campaign grant must never overwrite a live paid
    // entitlement, which would erase externalSubscriptionID / purchaseTokenHash
    // and strand the subscription's own webhooks.
    return true;
  }

  if (sameEntitlementWriteSource(existing, incoming)) return false;
  return !incoming.active || incoming.expiresAtMillis < existingExpiresAtMillis;
}

function entitlementExpiresAtMillis(existing: Record<string, unknown>): number | undefined {
  const expireAt = existing.expireAt;
  if (isTimestampWithToMillis(expireAt)) return expireAt.toMillis();
  const expiresAt = existing.expiresAt;
  if (typeof expiresAt === "string") {
    const parsed = Date.parse(expiresAt);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

export function paidEntitlementWriteWouldRewindSourceEvent(
  existing: Record<string, unknown> | undefined,
  incoming: {
    source: string;
    active: boolean;
    externalSubscriptionID?: string;
    purchaseTokenHash?: string;
    sourceEventID?: string;
    sourceEventCreatedMillis?: number;
  },
): boolean {
  if (!existing || typeof incoming.sourceEventCreatedMillis !== "number") return false;
  const existingEventCreatedMillis = existing.sourceEventCreatedMillis;
  if (typeof existingEventCreatedMillis !== "number") return false;
  if (!sameEntitlementWriteSource(existing, incoming)) return false;
  if (existingEventCreatedMillis > incoming.sourceEventCreatedMillis) return true;
  if (
    existingEventCreatedMillis !== incoming.sourceEventCreatedMillis ||
    typeof existing.sourceEventID !== "string" ||
    typeof incoming.sourceEventID !== "string" ||
    existing.sourceEventID === incoming.sourceEventID
  ) {
    return false;
  }

  // Stripe's event.created has second granularity, so distinct transitions can
  // share one timestamp. Resolve that tie by terminal-state dominance:
  // deletion/cancellation may replace an active write, and an active write may
  // never resurrect an entitlement whose inactive state is terminal
  // (cancelled/expired/revoked). Transient billing states (e.g. incomplete,
  // past_due, on-hold) are legitimately followed by activation in the same
  // second — incomplete -> active is Stripe's normal first-payment sequence —
  // so an active write may replace those. Unknown or missing rawStatus is
  // treated as terminal (fail closed). Same-event redeliveries remain
  // idempotent through the early return above.
  if (existing.active === true) return incoming.active;
  return !(incoming.active && isTransientInactiveEntitlementStatus(existing.rawStatus));
}

/**
 * Inactive entitlement states that a same-second active write may legitimately
 * supersede: they precede activation in the provider's own lifecycle rather
 * than terminating it. Anything else (canceled, expired, revoked, unknown,
 * missing) is treated as terminal so a stale active replay cannot resurrect a
 * cancelled entitlement.
 */
function isTransientInactiveEntitlementStatus(rawStatus: unknown): boolean {
  if (typeof rawStatus !== "string") return false;
  switch (rawStatus) {
    // Stripe subscription statuses that are inactive but recoverable.
    case "incomplete":
    case "past_due":
    case "paused":
    case "unpaid":
    // Google Play subscription states that are inactive but recoverable.
    case "SUBSCRIPTION_STATE_ON_HOLD":
    case "SUBSCRIPTION_STATE_PAUSED":
    case "SUBSCRIPTION_STATE_PENDING":
    case "SUBSCRIPTION_STATE_IN_GRACE_PERIOD":
      return true;
    default:
      return false;
  }
}
