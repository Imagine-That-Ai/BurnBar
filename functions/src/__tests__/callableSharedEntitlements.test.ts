import { describe, expect, it } from "vitest";

import {
  entitlementExpiryMillis,
  isActiveBurnBarCloudProEntitlement,
  isActiveBurnBarUltraEntitlement,
  isActiveHostedQuotaEntitlement,
  isActivePremiumEntitlement,
} from "../callables/shared.js";

const FAR_FUTURE = "2999-01-01T00:00:00.000Z";

function activeEntitlement(productID: string, expiresAt: string = FAR_FUTURE): Record<string, unknown> {
  return { active: true, productID, expiresAt };
}

describe("callable shared entitlement predicates", () => {
  it("uses the resolved backend catalog for hosted quota and premium checks", () => {
    expect(isActiveHostedQuotaEntitlement(activeEntitlement("com.openburnbar.hostedQuotaSync.cloud.monthly"))).toBe(
      true,
    );
    expect(isActiveHostedQuotaEntitlement(activeEntitlement("com.openburnbar.pro.monthly"))).toBe(false);

    expect(isActivePremiumEntitlement(activeEntitlement("com.openburnbar.hostedQuotaSync.cloud.monthly"))).toBe(true);
    expect(isActivePremiumEntitlement(activeEntitlement("com.openburnbar.pro.monthly"))).toBe(true);
    expect(isActivePremiumEntitlement(activeEntitlement("com.openburnbar.pro.annual"))).toBe(true);
    expect(isActivePremiumEntitlement(activeEntitlement("com.openburnbar.promax.v2.monthly"))).toBe(true);
    expect(isActivePremiumEntitlement(activeEntitlement("com.openburnbar.proMax.bundle.monthly"))).toBe(true);
    expect(isActivePremiumEntitlement(activeEntitlement("com.openburnbar.unknown"))).toBe(false);
  });

  it("keeps Cloud Pro aliases and Ultra strictness intact", () => {
    expect(isActiveBurnBarCloudProEntitlement(activeEntitlement("com.openburnbar.proMax.v2.monthly"))).toBe(true);
    expect(isActiveBurnBarCloudProEntitlement(activeEntitlement("com.openburnbar.promax.annual"))).toBe(true);
    expect(isActiveBurnBarCloudProEntitlement(activeEntitlement("com.openburnbar.proMax.bundle.monthly"))).toBe(true);
    expect(isActiveBurnBarCloudProEntitlement(activeEntitlement("com.openburnbar.pro.monthly"))).toBe(false);

    expect(isActiveBurnBarUltraEntitlement(activeEntitlement("com.openburnbar.ultra.monthly"))).toBe(true);
    expect(isActiveBurnBarUltraEntitlement(activeEntitlement("com.openburnbar.ultra.annual.v2"))).toBe(true);
    expect(isActiveBurnBarUltraEntitlement(activeEntitlement("com.openburnbar.ultra.annual"))).toBe(true);
    expect(isActiveBurnBarUltraEntitlement(activeEntitlement("com.openburnbar.proMax.v2.monthly"))).toBe(false);
  });

  it("fails closed on inactive or expired entitlement docs", () => {
    expect(isActivePremiumEntitlement({ ...activeEntitlement("com.openburnbar.pro.monthly"), active: false })).toBe(
      false,
    );
    expect(isActivePremiumEntitlement(activeEntitlement("com.openburnbar.pro.monthly", "2000-01-01T00:00:00.000Z")))
      .toBe(false);
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
