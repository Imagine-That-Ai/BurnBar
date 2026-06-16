import { describe, expect, it } from "vitest";

import { resolveDataTierFromEntitlements, wandParallelMaxForDataTier } from "../callables/dataDomainUsage.js";

type DataTier = Parameters<typeof wandParallelMaxForDataTier>[0];

const FAR_FUTURE = "2999-01-01T00:00:00.000Z";

function activeEntitlement(productID: string, expiresAt: string = FAR_FUTURE): Record<string, unknown> {
  return { active: true, productID, expiresAt };
}

function expectCap(tier: DataTier, cap: number): void {
  expect(wandParallelMaxForDataTier(tier)).toBe(cap);
}

describe("data domain usage Wand tier limits", () => {
  it("maps the public Wand ladder without collapsing Cloud to Free", () => {
    expectCap("free", 1);
    expectCap("cloud", 3);
    expectCap("pro", 8);
    expectCap("ultra", 16);
  });

  it("resolves entitlements top-down into the Wand parallel cap ladder", () => {
    expect(resolveDataTierFromEntitlements({})).toBe("free");

    expect(
      resolveDataTierFromEntitlements({
        cloud: activeEntitlement("com.openburnbar.hostedQuotaSync.cloud.monthly"),
      }),
    ).toBe("cloud");

    expect(
      resolveDataTierFromEntitlements({
        legacyCloud: activeEntitlement("com.openburnbar.pro.monthly"),
      }),
    ).toBe("cloud");

    expect(
      resolveDataTierFromEntitlements({
        cloudPro: activeEntitlement("com.openburnbar.proMax.v2.monthly"),
        cloud: activeEntitlement("com.openburnbar.hostedQuotaSync.cloud.monthly"),
      }),
    ).toBe("pro");

    expect(
      resolveDataTierFromEntitlements({
        ultra: activeEntitlement("com.openburnbar.ultra.monthly"),
        cloudPro: activeEntitlement("com.openburnbar.proMax.v2.monthly"),
        cloud: activeEntitlement("com.openburnbar.hostedQuotaSync.cloud.monthly"),
      }),
    ).toBe("ultra");
  });
});
