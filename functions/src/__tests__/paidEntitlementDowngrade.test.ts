import { describe, expect, it } from "vitest";

import { paidEntitlementWriteWouldDowngrade } from "../callables/shared.js";

describe("paidEntitlementWriteWouldDowngrade", () => {
  const nowMillis = Date.parse("2026-06-02T06:00:00Z");
  const stripeActiveCloudPro = {
    active: true,
    source: "stripe_webhook_verified",
    externalSubscriptionID: "sub_live_cloud_pro",
    expiresAt: "2026-06-30T06:00:00Z",
  };

  it("preserves a fresher active Stripe entitlement from an expired Google Play write", () => {
    expect(
      paidEntitlementWriteWouldDowngrade(stripeActiveCloudPro, {
        source: "google_play_verified",
        expiresAtMillis: Date.parse("2026-06-02T04:09:33Z"),
        active: false,
        purchaseTokenHash: "purchase-token-hash",
        nowMillis,
      }),
    ).toBe(true);
  });

  it("preserves a fresher active Stripe entitlement from a shorter Google Play renewal window", () => {
    expect(
      paidEntitlementWriteWouldDowngrade(stripeActiveCloudPro, {
        source: "google_play_verified",
        expiresAtMillis: Date.parse("2026-06-15T06:00:00Z"),
        active: true,
        purchaseTokenHash: "purchase-token-hash",
        nowMillis,
      }),
    ).toBe(true);
  });

  it("allows updates from the same Stripe subscription so cancellations and renewals can land", () => {
    expect(
      paidEntitlementWriteWouldDowngrade(stripeActiveCloudPro, {
        source: "stripe_webhook_verified",
        expiresAtMillis: Date.parse("2026-06-15T06:00:00Z"),
        active: false,
        externalSubscriptionID: "sub_live_cloud_pro",
        nowMillis,
      }),
    ).toBe(false);
  });

  it("allows a different provider write when it extends the entitlement farther", () => {
    expect(
      paidEntitlementWriteWouldDowngrade(stripeActiveCloudPro, {
        source: "google_play_verified",
        expiresAtMillis: Date.parse("2026-07-15T06:00:00Z"),
        active: true,
        purchaseTokenHash: "purchase-token-hash",
        nowMillis,
      }),
    ).toBe(false);
  });
});
