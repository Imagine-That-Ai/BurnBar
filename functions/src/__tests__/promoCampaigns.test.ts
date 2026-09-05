import { describe, expect, it } from "vitest";

import { paidEntitlementWriteWouldDowngrade } from "../callables/shared/entitlements.js";
import {
  canonicalizePromoCode,
  evaluatePromoCampaign,
  evaluatePromoCode,
  promoCampaignDocPath,
  promoCodeDigest,
  promoCodeDocPath,
  promoRedemptionDocPath,
  promoRejectionMessage,
  PROMO_ENTITLEMENT_SOURCE,
  type PromoCampaignDoc,
} from "../promoCampaigns.js";

const NOW = Date.parse("2026-09-05T00:00:00.000Z");
const FAR_FUTURE = Date.parse("2099-01-01T00:00:00.000Z");

function campaign(overrides: Partial<PromoCampaignDoc> = {}): PromoCampaignDoc {
  return {
    campaignID: "xopen-ultra",
    active: true,
    entitlementID: "burnbar_ultra",
    productID: "com.openburnbar.ultra.annual.v2",
    grantExpiresAtMillis: FAR_FUTURE,
    ...overrides,
  };
}

describe("promo code canonicalization", () => {
  it("treats every plausible spelling of one code as the same code", () => {
    const canonical = canonicalizePromoCode("XOPEN-ULTRA");
    expect(canonical).toBe("XOPENULTRA");
    // Hand-typed, pasted from the post, and arriving through a ?code= link.
    for (const spelling of ["xopen-ultra", "XOPENULTRA", " XOpen Ultra ", "xopen_ultra", "XOPEN–ULTRA"]) {
      expect(canonicalizePromoCode(spelling)).toBe(canonical);
    }
  });

  it("rejects inputs that cannot be a code before any lookup happens", () => {
    expect(canonicalizePromoCode("")).toBeUndefined();
    expect(canonicalizePromoCode("---")).toBeUndefined();
    expect(canonicalizePromoCode("AB")).toBeUndefined();
    expect(canonicalizePromoCode("A".repeat(65))).toBeUndefined();
    expect(canonicalizePromoCode(undefined)).toBeUndefined();
    expect(canonicalizePromoCode(42)).toBeUndefined();
    expect(canonicalizePromoCode({ code: "XOPEN-ULTRA" })).toBeUndefined();
  });

  it("derives a stable 64-hex digest that separates distinct codes", () => {
    const digest = promoCodeDigest("XOPENULTRA");
    expect(digest).toMatch(/^[0-9a-f]{64}$/);
    expect(promoCodeDigest("XOPENULTRA")).toBe(digest);
    expect(promoCodeDigest("PODEXULTRA")).not.toBe(digest);
  });

  it("builds server-only document paths", () => {
    expect(promoCampaignDocPath("xopen-ultra")).toBe("promo_campaigns/xopen-ultra");
    expect(promoCodeDocPath("a".repeat(64))).toBe(`promo_codes/${"a".repeat(64)}`);
    expect(promoRedemptionDocPath("xopen-ultra", "uid-1")).toBe("promo_campaigns/xopen-ultra/redemptions/uid-1");
  });
});

describe("promo code eligibility", () => {
  it("accepts an active code mapped to a campaign", () => {
    expect(evaluatePromoCode({ campaignID: "xopen-ultra", active: true })).toEqual({ ok: true });
  });

  it("distinguishes an unknown code from a rotated-out one", () => {
    expect(evaluatePromoCode(undefined)).toEqual({ ok: false, reason: "unknown_code" });
    expect(evaluatePromoCode({ campaignID: "xopen-ultra", active: false })).toEqual({
      ok: false,
      reason: "code_disabled",
    });
  });

  it("fails closed when the mapping has no campaign", () => {
    expect(evaluatePromoCode({ campaignID: "", active: true })).toEqual({ ok: false, reason: "campaign_missing" });
  });
});

describe("promo campaign eligibility", () => {
  it("accepts an active, in-window, uncapped campaign", () => {
    expect(evaluatePromoCampaign(campaign(), { nowMillis: NOW })).toEqual({ ok: true });
  });

  it("refuses a missing or paused campaign", () => {
    expect(evaluatePromoCampaign(undefined, { nowMillis: NOW })).toEqual({ ok: false, reason: "campaign_missing" });
    expect(evaluatePromoCampaign(campaign({ active: false }), { nowMillis: NOW })).toEqual({
      ok: false,
      reason: "campaign_inactive",
    });
  });

  it("enforces the redemption window at both edges", () => {
    const windowed = campaign({ startsAtMillis: NOW, endsAtMillis: NOW + 1000 });
    expect(evaluatePromoCampaign(windowed, { nowMillis: NOW - 1 })).toEqual({
      ok: false,
      reason: "campaign_not_started",
    });
    expect(evaluatePromoCampaign(windowed, { nowMillis: NOW })).toEqual({ ok: true });
    expect(evaluatePromoCampaign(windowed, { nowMillis: NOW + 999 })).toEqual({ ok: true });
    // End is exclusive: the campaign is closed the instant it ends.
    expect(evaluatePromoCampaign(windowed, { nowMillis: NOW + 1000 })).toEqual({
      ok: false,
      reason: "campaign_ended",
    });
  });

  it("stops at the redemption cap and treats a missing count as zero", () => {
    expect(evaluatePromoCampaign(campaign({ maxRedemptions: 2, redemptionCount: 1 }), { nowMillis: NOW })).toEqual({
      ok: true,
    });
    expect(evaluatePromoCampaign(campaign({ maxRedemptions: 2, redemptionCount: 2 }), { nowMillis: NOW })).toEqual({
      ok: false,
      reason: "campaign_exhausted",
    });
    expect(evaluatePromoCampaign(campaign({ maxRedemptions: 2 }), { nowMillis: NOW })).toEqual({ ok: true });
  });
});

describe("promo rejection copy", () => {
  it("never leaks internal identifiers to an anonymous visitor", () => {
    const reasons = [
      "unknown_code",
      "code_disabled",
      "campaign_missing",
      "campaign_inactive",
      "campaign_not_started",
      "campaign_ended",
      "campaign_exhausted",
    ] as const;
    for (const reason of reasons) {
      const message = promoRejectionMessage(reason);
      expect(message.length).toBeGreaterThan(0);
      expect(message).not.toMatch(/promo_|campaign_|digest|firestore|uid|entitlement/i);
    }
  });

  it("tells a wrong code apart from a closed offer", () => {
    expect(promoRejectionMessage("unknown_code")).not.toBe(promoRejectionMessage("campaign_ended"));
    expect(promoRejectionMessage("campaign_exhausted")).not.toBe(promoRejectionMessage("campaign_inactive"));
  });
});

describe("promo grants rank against paid entitlements by trust, not expiry", () => {
  const promoDoc = {
    active: true,
    source: PROMO_ENTITLEMENT_SOURCE,
    expiresAt: new Date(FAR_FUTURE).toISOString(),
  };
  const paidDoc = {
    active: true,
    source: "stripe_webhook_verified",
    externalSubscriptionID: "sub_123",
    expiresAt: new Date(NOW + 30 * 24 * 3600 * 1000).toISOString(),
  };

  it("lets a real purchase take over a far-future promo grant", () => {
    // The promo expiry is decades beyond the subscription's, so the generic
    // "shorter expiry = downgrade" rule would otherwise reject every purchase.
    expect(
      paidEntitlementWriteWouldDowngrade(promoDoc, {
        source: "stripe_webhook_verified",
        expiresAtMillis: NOW + 30 * 24 * 3600 * 1000,
        active: true,
        externalSubscriptionID: "sub_123",
        nowMillis: NOW,
      }),
    ).toBe(false);
  });

  it("lets a cancellation of that purchase land too", () => {
    expect(
      paidEntitlementWriteWouldDowngrade(promoDoc, {
        source: "stripe_webhook_verified",
        expiresAtMillis: NOW,
        active: false,
        nowMillis: NOW,
      }),
    ).toBe(false);
  });

  it("refuses to let a promo grant overwrite a live paid subscription", () => {
    expect(
      paidEntitlementWriteWouldDowngrade(paidDoc, {
        source: PROMO_ENTITLEMENT_SOURCE,
        expiresAtMillis: FAR_FUTURE,
        active: true,
        nowMillis: NOW,
      }),
    ).toBe(true);
  });

  it("still grants when the paid entitlement has lapsed", () => {
    const lapsed = { ...paidDoc, expiresAt: new Date(NOW - 1000).toISOString() };
    expect(
      paidEntitlementWriteWouldDowngrade(lapsed, {
        source: PROMO_ENTITLEMENT_SOURCE,
        expiresAtMillis: FAR_FUTURE,
        active: true,
        nowMillis: NOW,
      }),
    ).toBe(false);
  });

  it("allows a promo grant to be re-asserted over itself", () => {
    expect(
      paidEntitlementWriteWouldDowngrade(promoDoc, {
        source: PROMO_ENTITLEMENT_SOURCE,
        expiresAtMillis: FAR_FUTURE,
        active: true,
        nowMillis: NOW,
      }),
    ).toBe(false);
  });
});
