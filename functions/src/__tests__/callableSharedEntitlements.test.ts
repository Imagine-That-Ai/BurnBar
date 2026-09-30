import { describe, expect, it } from "vitest";

import { entitlementExpiryMillis, isActivePremiumEntitlement } from "../../../packages/functions-shared/src/shared/entitlements.js";

const FAR_FUTURE = "2999-01-01T00:00:00.000Z";

function activeEntitlement(productID: string, expiresAt: string = FAR_FUTURE): Record<string, unknown> {
  return { active: true, productID, expiresAt };
}

describe("callable shared entitlement predicates", () => {
  it("fails closed on inactive or expired entitlement docs", () => {
    expect(isActivePremiumEntitlement({ ...activeEntitlement("com.openburnbar.pro.monthly"), active: false })).toBe(
      false,
    );
    expect(
      isActivePremiumEntitlement(activeEntitlement("com.openburnbar.pro.monthly", "2000-01-01T00:00:00.000Z")),
    ).toBe(false);
  });

  it("preserves the legacy expiry sentinel while delegating date math", () => {
    const millis = Date.parse("2030-06-12T00:00:00.000Z");

    expect(entitlementExpiryMillis({ expireAt: { toMillis: () => millis }, expiresAt: FAR_FUTURE })).toBe(millis);
    expect(entitlementExpiryMillis({ expireAt: new Date(millis) })).toBe(millis);
    expect(entitlementExpiryMillis({ expireAt: "2030-06-12T00:00:00.000Z" })).toBe(millis);
    expect(entitlementExpiryMillis({ expiresAt: "2030-06-12T00:00:00.000Z" })).toBe(millis);
    expect(entitlementExpiryMillis({ expiresAt: "not-a-date" })).toBe(0);
    expect(entitlementExpiryMillis({})).toBe(0);
  });
});
