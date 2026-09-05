import { describe, expect, it } from "vitest";

import { paidEntitlementWriteWouldDowngrade } from "../callables/shared/entitlements.js";
import {
  canonicalizePromoCode,
  promoCampaignDocPath,
  promoCodeDigest,
  promoCodeDocPath,
  promoRedemptionDocPath,
  promoRejectionMessage,
  PROMO_ENTITLEMENT_SOURCE,
  resolvePromoCampaign,
  resolvePromoCode,
} from "../promoCampaigns.js";

const NOW = Date.parse("2026-09-05T00:00:00.000Z");
const FAR_FUTURE = Date.parse("2099-01-01T00:00:00.000Z");

function campaign(overrides: Record<string, unknown> = {}): Record<string, unknown> {
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

describe("promo code resolution", () => {
  it("accepts an active code mapped to a campaign", () => {
    expect(resolvePromoCode({ campaignID: "xopen-ultra", active: true })).toEqual({
      ok: true,
      value: { campaignID: "xopen-ultra" },
    });
  });

  it("distinguishes an unknown code from a rotated-out one", () => {
    expect(resolvePromoCode(undefined)).toEqual({ ok: false, reason: "unknown_code" });
    expect(resolvePromoCode({ campaignID: "xopen-ultra", active: false })).toEqual({
      ok: false,
      reason: "code_disabled",
    });
  });

  it("fails closed on a malformed stored document rather than trusting it", () => {
    // A Firestore read is untrusted input: no assertion may stand in for these checks.
    expect(resolvePromoCode({ campaignID: "", active: true })).toEqual({ ok: false, reason: "campaign_missing" });
    expect(resolvePromoCode({ campaignID: 42, active: true })).toEqual({ ok: false, reason: "campaign_missing" });
    expect(resolvePromoCode({ active: true })).toEqual({ ok: false, reason: "campaign_missing" });
    expect(resolvePromoCode("not-a-document")).toEqual({ ok: false, reason: "unknown_code" });
    expect(resolvePromoCode({ campaignID: "x", active: "yes" })).toEqual({ ok: false, reason: "code_disabled" });
  });
});

describe("promo campaign resolution", () => {
  const plan = {
    campaignID: "xopen-ultra",
    entitlementID: "burnbar_ultra",
    productID: "com.openburnbar.ultra.annual.v2",
    grantExpiresAtMillis: FAR_FUTURE,
    label: undefined,
  };

  it("accepts an active, in-window, uncapped campaign and returns its validated plan", () => {
    expect(resolvePromoCampaign(campaign(), { nowMillis: NOW })).toEqual({ ok: true, value: plan });
  });

  it("refuses a missing or paused campaign", () => {
    expect(resolvePromoCampaign(undefined, { nowMillis: NOW })).toEqual({ ok: false, reason: "campaign_missing" });
    expect(resolvePromoCampaign(campaign({ active: false }), { nowMillis: NOW })).toEqual({
      ok: false,
      reason: "campaign_inactive",
    });
  });

  it("enforces the redemption window at both edges", () => {
    const windowed = campaign({ startsAtMillis: NOW, endsAtMillis: NOW + 1000 });
    expect(resolvePromoCampaign(windowed, { nowMillis: NOW - 1 })).toEqual({
      ok: false,
      reason: "campaign_not_started",
    });
    expect(resolvePromoCampaign(windowed, { nowMillis: NOW }).ok).toBe(true);
    expect(resolvePromoCampaign(windowed, { nowMillis: NOW + 999 }).ok).toBe(true);
    // End is exclusive: the campaign is closed the instant it ends.
    expect(resolvePromoCampaign(windowed, { nowMillis: NOW + 1000 })).toEqual({
      ok: false,
      reason: "campaign_ended",
    });
  });

  it("stops at the redemption cap and treats a missing count as zero", () => {
    expect(resolvePromoCampaign(campaign({ maxRedemptions: 2, redemptionCount: 1 }), { nowMillis: NOW }).ok).toBe(true);
    expect(resolvePromoCampaign(campaign({ maxRedemptions: 2, redemptionCount: 2 }), { nowMillis: NOW })).toEqual({
      ok: false,
      reason: "campaign_exhausted",
    });
    expect(resolvePromoCampaign(campaign({ maxRedemptions: 2 }), { nowMillis: NOW }).ok).toBe(true);
  });

  it("carries the operator label through when present", () => {
    const resolved = resolvePromoCampaign(campaign({ label: "X launch" }), { nowMillis: NOW });
    expect(resolved).toEqual({ ok: true, value: { ...plan, label: "X launch" } });
  });

  it("refuses a campaign missing anything needed to mint an entitlement", () => {
    // Defaulting a tier or an expiry here would grant the wrong thing, so each
    // absent or wrongly-typed field must fail closed instead.
    for (const missing of ["campaignID", "entitlementID", "productID", "grantExpiresAtMillis"]) {
      const partial = campaign();
      delete partial[missing];
      expect(resolvePromoCampaign(partial, { nowMillis: NOW })).toEqual({ ok: false, reason: "campaign_missing" });
    }
    expect(resolvePromoCampaign(campaign({ grantExpiresAtMillis: "2099" }), { nowMillis: NOW })).toEqual({
      ok: false,
      reason: "campaign_missing",
    });
    expect(resolvePromoCampaign(campaign({ entitlementID: 7 }), { nowMillis: NOW })).toEqual({
      ok: false,
      reason: "campaign_missing",
    });
    expect(resolvePromoCampaign("not-a-document", { nowMillis: NOW })).toEqual({
      ok: false,
      reason: "campaign_missing",
    });
  });

  it("ignores non-numeric window and cap fields rather than trusting them", () => {
    // A malformed window must not silently close (or open) the campaign.
    expect(resolvePromoCampaign(campaign({ startsAtMillis: "soon", endsAtMillis: null }), { nowMillis: NOW }).ok).toBe(
      true,
    );
    expect(resolvePromoCampaign(campaign({ maxRedemptions: "many" }), { nowMillis: NOW }).ok).toBe(true);
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
