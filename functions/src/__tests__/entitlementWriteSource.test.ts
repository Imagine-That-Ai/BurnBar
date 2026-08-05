import { describe, expect, it } from "vitest";

import { sameEntitlementWriteSource } from "../callables/shared/entitlementWriteSource.js";

describe("sameEntitlementWriteSource", () => {
  const stripeOperatorBridge = {
    source: "internal_operator_grant",
    platform: "stripe",
    externalSubscriptionID: "sub_live_cloud_pro",
  };

  it("treats a matching external subscription from the same source as the same purchase", () => {
    expect(
      sameEntitlementWriteSource(
        { source: "stripe_webhook_verified", externalSubscriptionID: "sub_live_cloud_pro" },
        { source: "stripe_webhook_verified", externalSubscriptionID: "sub_live_cloud_pro" },
      ),
    ).toBe(true);
  });

  it("treats a matching purchase token hash from the same source as the same purchase", () => {
    expect(
      sameEntitlementWriteSource(
        { source: "google_play_verified", purchaseTokenHash: "purchase-token-hash" },
        {
          source: "google_play_verified",
          externalSubscriptionID: "different-subscription",
          purchaseTokenHash: "purchase-token-hash",
        },
      ),
    ).toBe(true);
  });

  it("treats an identifier-free write from the same source as the same purchase", () => {
    expect(
      sameEntitlementWriteSource(
        { source: "stripe_webhook_verified", externalSubscriptionID: "sub_live_cloud_pro" },
        { source: "stripe_webhook_verified" },
      ),
    ).toBe(true);
  });

  it("rejects a same-source write whose identifiers all mismatch", () => {
    expect(
      sameEntitlementWriteSource(
        {
          source: "stripe_webhook_verified",
          externalSubscriptionID: "sub_live_cloud_pro",
          purchaseTokenHash: "purchase-token-hash",
        },
        {
          source: "stripe_webhook_verified",
          externalSubscriptionID: "sub_other",
          purchaseTokenHash: "other-token-hash",
        },
      ),
    ).toBe(false);
  });

  it("lets a verified Stripe lifecycle adopt an operator bridge bound to the same subscription", () => {
    expect(
      sameEntitlementWriteSource(stripeOperatorBridge, {
        source: "stripe_webhook_verified",
        externalSubscriptionID: "sub_live_cloud_pro",
      }),
    ).toBe(true);
  });

  it("preserves an operator bridge bound to a different Stripe subscription", () => {
    expect(
      sameEntitlementWriteSource(stripeOperatorBridge, {
        source: "stripe_webhook_verified",
        externalSubscriptionID: "sub_other",
      }),
    ).toBe(false);
  });

  it("preserves an operator bridge on another platform", () => {
    expect(
      sameEntitlementWriteSource(
        { ...stripeOperatorBridge, platform: "google_play" },
        {
          source: "stripe_webhook_verified",
          externalSubscriptionID: "sub_live_cloud_pro",
        },
      ),
    ).toBe(false);
  });

  it("preserves an operator bridge when the verified write carries no subscription id", () => {
    expect(
      sameEntitlementWriteSource(stripeOperatorBridge, {
        source: "stripe_webhook_verified",
      }),
    ).toBe(false);
  });

  it("keeps unrelated cross-source writes distinct", () => {
    expect(
      sameEntitlementWriteSource(
        { source: "google_play_verified", purchaseTokenHash: "purchase-token-hash" },
        {
          source: "stripe_webhook_verified",
          externalSubscriptionID: "sub_live_cloud_pro",
        },
      ),
    ).toBe(false);
  });
});
