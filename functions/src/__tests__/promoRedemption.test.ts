/**
 * Decision-logic coverage for `redeemPromoCode`.
 *
 * These exercise which outcome the callable reaches and what it consumes, over
 * the repo's path-keyed fake Firestore. The end-to-end proof that a redemption
 * actually writes a usable Ultra entitlement lives in
 * `scripts/test-promo-redemption.mjs`, which runs the shipped writer against a
 * real Firestore emulator — so these tests never stand in for that.
 */
import { Timestamp } from "firebase-admin/firestore";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { callableRequest, callableRunner, seedDoc } from "./bola/callableBolaHarness.js";

const store = vi.hoisted(() => new Map<string, Record<string, unknown>>());
const writeEntitlementMock = vi.hoisted(() => vi.fn());
const recordFailureMock = vi.hoisted(() => vi.fn());
const rateLimitMock = vi.hoisted(() => vi.fn());
const lockoutMock = vi.hoisted(() => vi.fn());
const nonceMock = vi.hoisted(() => vi.fn());

vi.mock("../../../packages/functions-shared/src/adminRuntime.js", async () => {
  const harness = await import("./bola/callableBolaHarness.js");
  return { db: harness.pathKeyedFirestore(store) };
});

vi.mock("../../../packages/functions-shared/src/appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: nonceMock,
}));

vi.mock("../../../packages/functions-shared/src/callables/publicRateLimit.js", () => ({
  assertCallableApprovalNotLocked: lockoutMock,
  checkPromoRedeemRateLimit: rateLimitMock,
  recordCallableApprovalFailure: recordFailureMock,
}));

vi.mock("../../../packages/functions-shared/src/shared/entitlements.js", async () => {
  const actual = await vi.importActual<typeof import("../../../packages/functions-shared/src/shared/entitlements.js")>(
    "../../../packages/functions-shared/src/shared/entitlements.js",
  );
  return { ...actual, writeBurnBarProEntitlement: writeEntitlementMock };
});

import { redeemPromoCode, redeemPromoCodeForUid } from "../../../functions-identity/src/domains/billing/promoRedemption.js";
import { canonicalizePromoCode, promoCodeDigest } from "../../../functions-identity/src/domains/billing/promoCampaigns.js";
import { PROMO_ENTITLEMENT_SOURCE } from "../../../packages/functions-shared/src/shared/entitlementWriteSource.js";

const CODE = "XOPEN-ULTRA";
const CAMPAIGN_ID = "xopen-ultra";
const ULTRA_SKU = "com.openburnbar.ultra.annual.v2";
const FAR_FUTURE = Date.parse("2099-01-01T00:00:00.000Z");

function digestPath(code: string): string {
  const canonical = canonicalizePromoCode(code);
  if (!canonical) throw new Error(`test code ${code} does not canonicalize`);
  return `promo_codes/${promoCodeDigest(canonical)}`;
}

function seedCampaign(overrides: Record<string, unknown> = {}): void {
  seedDoc(store, `promo_campaigns/${CAMPAIGN_ID}`, {
    campaignID: CAMPAIGN_ID,
    active: true,
    entitlementID: "burnbar_ultra",
    productID: ULTRA_SKU,
    grantExpiresAtMillis: FAR_FUTURE,
    maxRedemptions: 5000,
    redemptionCount: 0,
    ...overrides,
  });
  seedDoc(store, digestPath(CODE), { campaignID: CAMPAIGN_ID, active: true });
}

describe("redeemPromoCode", () => {
  beforeEach(() => {
    store.clear();
    vi.clearAllMocks();
    writeEntitlementMock.mockResolvedValue({});
    recordFailureMock.mockResolvedValue(undefined);
    rateLimitMock.mockResolvedValue(undefined);
    lockoutMock.mockResolvedValue(undefined);
    nonceMock.mockResolvedValue(undefined);
  });

  it("grants the campaign tier and records the redemption", async () => {
    seedCampaign();

    const result = await redeemPromoCodeForUid("uid-fresh", CODE);

    expect(result.status).toBe("granted");
    expect(result.entitlementID).toBe("burnbar_ultra");
    expect(result.productID).toBe(ULTRA_SKU);
    expect(result.expiresAt).toBe(new Date(FAR_FUTURE).toISOString());

    // The grant carries promo provenance and no payment instrument.
    expect(writeEntitlementMock).toHaveBeenCalledTimes(1);
    expect(writeEntitlementMock).toHaveBeenCalledWith({
      uid: "uid-fresh",
      productID: ULTRA_SKU,
      expiresAtMillis: FAR_FUTURE,
      source: PROMO_ENTITLEMENT_SOURCE,
      platform: "web",
      entitlementID: "burnbar_ultra",
      activeOverride: true,
      promoGrant: { campaignID: CAMPAIGN_ID, redemptionID: "uid-fresh" },
    });

    expect(store.get(`promo_campaigns/${CAMPAIGN_ID}/redemptions/uid-fresh`)).toBeDefined();
  });

  it("re-asserts the grant on a repeat redemption without consuming another", async () => {
    seedCampaign();
    seedDoc(store, `promo_campaigns/${CAMPAIGN_ID}/redemptions/uid-repeat`, { uid: "uid-repeat" });

    const result = await redeemPromoCodeForUid("uid-repeat", CODE);

    // The grant is re-written so a ledger entry whose entitlement write failed
    // repairs itself, but the campaign cap is not charged twice.
    expect(result.status).toBe("already_redeemed");
    expect(writeEntitlementMock).toHaveBeenCalledTimes(1);
    expect(store.get(`promo_campaigns/${CAMPAIGN_ID}`)?.redemptionCount).toBe(0);
  });

  it.each([
    ["full", { maxRedemptions: 1, redemptionCount: 1 }],
    ["paused", { active: false }],
    ["ended", { endsAtMillis: Date.now() - 1000 }],
  ])("retries a failed grant from the ledger even when the campaign is %s", async (_label, overrides) => {
    seedCampaign();
    writeEntitlementMock.mockRejectedValueOnce(new Error("entitlement write failed"));
    await expect(redeemPromoCodeForUid("uid-retry", CODE)).rejects.toThrow("entitlement write failed");
    expect(store.get(`promo_campaigns/${CAMPAIGN_ID}/redemptions/uid-retry`)).toBeDefined();

    // The campaign closes before the retry; the recorded slot is still owed.
    seedCampaign({ redemptionCount: 1, ...overrides });
    const result = await redeemPromoCodeForUid("uid-retry", CODE);

    expect(result.status).toBe("already_redeemed");
    expect(result.expiresAt).toBe(new Date(FAR_FUTURE).toISOString());
    expect(writeEntitlementMock).toHaveBeenCalledTimes(2);
    expect(writeEntitlementMock).toHaveBeenLastCalledWith(
      expect.objectContaining({ uid: "uid-retry", productID: ULTRA_SKU, expiresAtMillis: FAR_FUTURE, entitlementID: "burnbar_ultra" }),
    );
    expect(store.get(`promo_campaigns/${CAMPAIGN_ID}`)?.redemptionCount).toBe(1);
  });

  it("re-asserts the recorded grant, not the campaign's current terms", async () => {
    const recordedExpiry = Date.parse("2098-06-01T00:00:00.000Z");
    seedCampaign({ active: false, productID: "com.openburnbar.ultra.monthly.v3" });
    seedDoc(store, `promo_campaigns/${CAMPAIGN_ID}/redemptions/uid-recorded`, {
      uid: "uid-recorded",
      campaignID: CAMPAIGN_ID,
      entitlementID: "burnbar_ultra",
      productID: ULTRA_SKU,
      grantExpiresAt: Timestamp.fromMillis(recordedExpiry),
    });

    const result = await redeemPromoCodeForUid("uid-recorded", CODE);

    expect(result).toMatchObject({ status: "already_redeemed", productID: ULTRA_SKU });
    expect(writeEntitlementMock).toHaveBeenCalledWith(
      expect.objectContaining({ productID: ULTRA_SKU, expiresAtMillis: recordedExpiry }),
    );
  });

  it("still requires a matching code on the ledger retry path", async () => {
    seedCampaign({ active: false });
    seedDoc(store, `promo_campaigns/${CAMPAIGN_ID}/redemptions/uid-wrong`, {
      entitlementID: "burnbar_ultra",
      productID: ULTRA_SKU,
      grantExpiresAt: Timestamp.fromMillis(FAR_FUTURE),
    });

    await expect(redeemPromoCodeForUid("uid-wrong", "NOPE-NOPE")).rejects.toMatchObject({ code: "not-found" });
    expect(writeEntitlementMock).not.toHaveBeenCalled();
  });

  it("leaves a live paid subscription alone and does not consume a redemption", async () => {
    seedCampaign();
    seedDoc(store, "users/uid-paid/entitlements/burnbar_ultra", {
      active: true,
      source: "stripe_webhook_verified",
      productID: ULTRA_SKU,
      externalSubscriptionID: "sub_live",
      expiresAt: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
    });

    const result = await redeemPromoCodeForUid("uid-paid", CODE);

    expect(result.status).toBe("already_entitled");
    expect(writeEntitlementMock).not.toHaveBeenCalled();
    expect(store.get(`promo_campaigns/${CAMPAIGN_ID}/redemptions/uid-paid`)).toBeUndefined();
    expect(store.get("users/uid-paid/entitlements/burnbar_ultra")?.externalSubscriptionID).toBe("sub_live");
  });

  it("grants over a lapsed paid entitlement", async () => {
    seedCampaign();
    seedDoc(store, "users/uid-lapsed/entitlements/burnbar_ultra", {
      active: true,
      source: "stripe_webhook_verified",
      productID: ULTRA_SKU,
      expiresAt: new Date(Date.now() - 1000).toISOString(),
    });

    expect((await redeemPromoCodeForUid("uid-lapsed", CODE)).status).toBe("granted");
    expect(writeEntitlementMock).toHaveBeenCalledTimes(1);
  });

  it("grants over an existing promo grant rather than treating it as a paid hold", async () => {
    seedCampaign();
    seedDoc(store, "users/uid-promo/entitlements/burnbar_ultra", {
      active: true,
      source: PROMO_ENTITLEMENT_SOURCE,
      productID: ULTRA_SKU,
      expiresAt: new Date(FAR_FUTURE).toISOString(),
    });

    expect((await redeemPromoCodeForUid("uid-promo", CODE)).status).toBe("granted");
  });

  it("rejects a malformed code before any lookup and charges the lockout", async () => {
    seedCampaign();

    await expect(redeemPromoCodeForUid("uid-bad", "no")).rejects.toMatchObject({ code: "invalid-argument" });
    expect(recordFailureMock).toHaveBeenCalledWith("uid-bad", "promo_redeem_fail");
    expect(writeEntitlementMock).not.toHaveBeenCalled();
  });

  it("rejects an unknown code and charges the lockout", async () => {
    seedCampaign();

    await expect(redeemPromoCodeForUid("uid-unknown", "NOPE-NOPE")).rejects.toMatchObject({ code: "not-found" });
    expect(recordFailureMock).toHaveBeenCalledWith("uid-unknown", "promo_redeem_fail");
    expect(writeEntitlementMock).not.toHaveBeenCalled();
  });

  it("rejects a rotated-out code", async () => {
    seedCampaign();
    seedDoc(store, digestPath(CODE), { campaignID: CAMPAIGN_ID, active: false });

    await expect(redeemPromoCodeForUid("uid-rotated", CODE)).rejects.toMatchObject({ code: "not-found" });
    expect(writeEntitlementMock).not.toHaveBeenCalled();
  });

  it("maps a paused campaign, a closed window, and an exhausted cap to distinct codes", async () => {
    seedCampaign({ active: false });
    await expect(redeemPromoCodeForUid("uid-paused", CODE)).rejects.toMatchObject({ code: "failed-precondition" });

    seedCampaign({ endsAtMillis: Date.now() - 1000 });
    await expect(redeemPromoCodeForUid("uid-closed", CODE)).rejects.toMatchObject({ code: "failed-precondition" });

    seedCampaign({ maxRedemptions: 2, redemptionCount: 2 });
    await expect(redeemPromoCodeForUid("uid-full", CODE)).rejects.toMatchObject({ code: "resource-exhausted" });

    expect(writeEntitlementMock).not.toHaveBeenCalled();
  });

  it("applies the lockout and rate limit before doing any work", async () => {
    seedCampaign();
    await redeemPromoCodeForUid("uid-limits", CODE);

    expect(lockoutMock).toHaveBeenCalledWith("uid-limits", "promo_redeem_fail");
    expect(rateLimitMock).toHaveBeenCalledWith("uid-limits");
  });

  it("refuses an unauthenticated caller and never touches the attestation path", async () => {
    seedCampaign();
    const run = callableRunner(redeemPromoCode);

    await expect(run({ data: { code: CODE } })).rejects.toMatchObject({ code: "unauthenticated" });
    expect(nonceMock).not.toHaveBeenCalled();
    expect(writeEntitlementMock).not.toHaveBeenCalled();
  });

  it("requires the attested nonce before redeeming through the callable", async () => {
    seedCampaign();
    const run = callableRunner(redeemPromoCode);

    const result = await run<{ status: string }>(callableRequest("uid-callable", { code: CODE, nonce: "n-1" }));

    expect(result.status).toBe("granted");
    expect(nonceMock).toHaveBeenCalledTimes(1);
    expect(nonceMock.mock.calls[0][1]).toBe("uid-callable");
    expect(nonceMock.mock.calls[0][2]).toBe("n-1");
  });
});
