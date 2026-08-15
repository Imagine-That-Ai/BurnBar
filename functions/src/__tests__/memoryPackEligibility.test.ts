import { beforeEach, describe, expect, it, vi } from "vitest";

const entitlementDocs = vi.hoisted(() => new Map<string, Record<string, unknown>>());

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc: (path: string) => ({
      get: async () => ({
        data: () => entitlementDocs.get(path),
      }),
    }),
  },
}));

vi.mock("../callables/shared/entitlements.js", () => ({
  BURNBAR_PRO_ENTITLEMENT_ID: "burnbar_pro",
  BURNBAR_PRO_MAX_ENTITLEMENT_ID: "burnbar_pro_max",
  BURNBAR_ULTRA_ENTITLEMENT_ID: "burnbar_ultra",
  isActivePremiumEntitlement: (raw: Record<string, unknown> | undefined) => raw?.tier === "premium",
  isActiveBurnBarCloudProEntitlement: (raw: Record<string, unknown> | undefined) => raw?.tier === "cloudPro",
  isActiveBurnBarUltraEntitlement: (raw: Record<string, unknown> | undefined) => raw?.tier === "ultra",
}));

import {
  assertMemoryPackPurchaseEntitlement,
  hasActiveMemoryPackVisionEntitlement,
} from "../usageCuration/eligibility.js";

const UID = "user_eligibility";

describe("Memory Boost purchase entitlement", () => {
  beforeEach(() => {
    entitlementDocs.clear();
  });

  it("refuses text and vision packs with no membership", async () => {
    await expect(assertMemoryPackPurchaseEntitlement(UID, "text_1m")).rejects.toMatchObject({
      code: "permission-denied",
    });
    await expect(assertMemoryPackPurchaseEntitlement(UID, "vision_1m")).rejects.toMatchObject({
      code: "permission-denied",
    });
    expect(await hasActiveMemoryPackVisionEntitlement(UID)).toBe(false);
  });

  it("allows text packs on BurnBar Pro or hosted quota and still holds vision", async () => {
    entitlementDocs.set(`users/${UID}/entitlements/burnbar_pro`, { tier: "premium" });
    await expect(assertMemoryPackPurchaseEntitlement(UID, "text_5m")).resolves.toBeUndefined();
    await expect(assertMemoryPackPurchaseEntitlement(UID, "vision_1m")).rejects.toMatchObject({
      code: "permission-denied",
    });

    entitlementDocs.clear();
    entitlementDocs.set(`users/${UID}/entitlements/hosted_quota_sync`, { tier: "premium" });
    await expect(assertMemoryPackPurchaseEntitlement(UID, "text_1m")).resolves.toBeUndefined();
  });

  it("allows vision packs on Cloud Pro or Ultra", async () => {
    entitlementDocs.set(`users/${UID}/entitlements/burnbar_pro_max`, { tier: "cloudPro" });
    await expect(assertMemoryPackPurchaseEntitlement(UID, "text_1m")).resolves.toBeUndefined();
    await expect(assertMemoryPackPurchaseEntitlement(UID, "vision_1m")).resolves.toBeUndefined();
    expect(await hasActiveMemoryPackVisionEntitlement(UID)).toBe(true);

    entitlementDocs.clear();
    entitlementDocs.set(`users/${UID}/entitlements/burnbar_ultra`, { tier: "ultra" });
    await expect(assertMemoryPackPurchaseEntitlement(UID, "vision_1m")).resolves.toBeUndefined();
  });
});
