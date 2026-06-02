import { describe, expect, it } from "vitest";

import {
  isActiveBurnBarCloudProEntitlement,
  isActiveHostedQuotaEntitlement,
  isActivePremiumEntitlement,
} from "../entitlements.js";

const future = new Date(Date.now() + 60 * 60 * 1000).toISOString();

describe("entitlement production environment gating", () => {
  it("accepts only active production hosted quota entitlements", () => {
    const entitlement = {
      active: true,
      environment: "Production",
      productID: "com.openburnbar.hostedQuotaSync.cloud.monthly",
      expiresAt: future,
    };

    expect(isActiveHostedQuotaEntitlement(entitlement)).toBe(true);
    expect(isActiveHostedQuotaEntitlement({ ...entitlement, environment: "Sandbox" })).toBe(false);
    expect(isActiveHostedQuotaEntitlement({ ...entitlement, environment: undefined })).toBe(false);
  });

  it("accepts only production premium and cloud pro entitlements", () => {
    const pro = {
      active: true,
      environment: "Production",
      productID: "com.openburnbar.pro.monthly",
      expiresAt: future,
    };
    const proMax = {
      active: true,
      environment: "Production",
      productID: "com.openburnbar.proMax.v2.monthly",
      expiresAt: future,
    };

    expect(isActivePremiumEntitlement(pro)).toBe(true);
    expect(isActivePremiumEntitlement({ ...pro, environment: "Sandbox" })).toBe(false);
    expect(isActivePremiumEntitlement({ ...pro, environment: undefined })).toBe(false);

    expect(isActiveBurnBarCloudProEntitlement(proMax)).toBe(true);
    expect(isActiveBurnBarCloudProEntitlement({ ...proMax, environment: "Sandbox" })).toBe(false);
    expect(isActiveBurnBarCloudProEntitlement({ ...proMax, environment: undefined })).toBe(false);
  });
});
