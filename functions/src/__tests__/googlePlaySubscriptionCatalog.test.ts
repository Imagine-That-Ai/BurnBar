import { describe, expect, it, vi } from "vitest";

vi.mock("../config.js", () => ({
  getConfig: () => ({
    googlePlaySubscriptionProductID: "cloud-monthly",
    googlePlayCloudMonthlyProductID: "cloud-monthly",
    googlePlayCloudAnnualProductID: "cloud-annual",
    burnBarProProductID: "legacy-cloud-monthly",
    burnBarProAnnualProductID: "legacy-cloud-annual",
    googlePlayCloudProMonthlyProductID: "pro-monthly",
    googlePlayCloudProAnnualProductID: "pro-annual",
    burnBarProMaxProductID: "legacy-pro-monthly",
    burnBarProMaxAnnualProductID: "legacy-pro-annual",
    googlePlayUltraMonthlyProductID: "ultra-monthly",
    googlePlayUltraAnnualProductID: "ultra-annual",
    burnBarUltraProductID: "legacy-ultra-monthly",
    burnBarUltraAnnualProductID: "legacy-ultra-annual",
  }),
}));

vi.mock("../callables/shared/entitlements.js", () => ({
  BURNBAR_PRO_ENTITLEMENT_ID: "burnbar_pro",
  BURNBAR_PRO_MAX_ENTITLEMENT_ID: "burnbar_pro_max",
  BURNBAR_ULTRA_ENTITLEMENT_ID: "burnbar_ultra",
}));

import { GOOGLE_PLAY_ACTIVE_STATES, selectGooglePlaySubscriptionLineItem } from "../callables/shared/googlePlay.js";

describe("Google Play subscription catalog", () => {
  it("keeps canceled subscriptions entitled until their paid-through expiry", () => {
    expect(GOOGLE_PLAY_ACTIVE_STATES.has("SUBSCRIPTION_STATE_CANCELED")).toBe(true);
  });

  it("maps every commercial tier to its entitlement family", () => {
    const selectionFor = (productId: string) =>
      selectGooglePlaySubscriptionLineItem({
        lineItems: [{ productId, expiryTime: "2030-01-01T00:00:00.000Z" }],
      }).target;

    expect(selectionFor("cloud-annual")).toMatchObject({
      entitlementID: "burnbar_pro",
      tierRank: 1,
    });
    expect(selectionFor("pro-monthly")).toMatchObject({
      entitlementID: "burnbar_pro_max",
      tierRank: 2,
    });
    expect(selectionFor("ultra-annual")).toMatchObject({
      entitlementID: "burnbar_ultra",
      tierRank: 3,
    });
  });

  it("prefers the product named by RTDN over another longer-lived line item", () => {
    const selected = selectGooglePlaySubscriptionLineItem(
      {
        lineItems: [
          { productId: "cloud-annual", expiryTime: "2027-08-01T00:00:00.000Z" },
          { productId: "pro-monthly", expiryTime: "2027-07-01T00:00:00.000Z" },
        ],
      },
      ["pro-monthly"],
    );
    expect(selected.target).toMatchObject({
      entitlementID: "burnbar_pro_max",
      canonicalProductID: "pro-monthly",
    });
  });

  it("falls back to the longest-lived supported line item and ignores unknown products", () => {
    const selected = selectGooglePlaySubscriptionLineItem({
      lineItems: [
        { productId: "unknown", expiryTime: "2030-01-01T00:00:00.000Z" },
        { productId: "cloud-monthly", expiryTime: "2027-07-01T00:00:00.000Z" },
        { productId: "ultra-monthly", expiryTime: "2027-08-01T00:00:00.000Z" },
      ],
    });
    expect(selected.target).toMatchObject({
      entitlementID: "burnbar_ultra",
      canonicalProductID: "ultra-monthly",
    });
  });
});
