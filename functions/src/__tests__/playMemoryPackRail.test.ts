import { beforeEach, describe, expect, it, vi } from "vitest";

const state = vi.hoisted(() => {
  const sets: Array<{ path: string; data: Record<string, unknown> }> = [];
  return {
    productsGet: vi.fn(),
    productsConsume: vi.fn(),
    grantExists: vi.fn(),
    grantMemoryPack: vi.fn(),
    reverseMemoryPackGrant: vi.fn(),
    visionEligible: vi.fn(),
    claimToken: vi.fn(),
    sets,
  };
});

vi.mock("googleapis", () => ({
  google: {
    auth: { getClient: vi.fn(async () => ({})) },
    androidpublisher: vi.fn(() => ({
      purchases: {
        products: {
          get: state.productsGet,
          consume: state.productsConsume,
        },
      },
    })),
  },
}));

vi.mock("../config.js", () => ({
  getConfig: () => ({
    googlePlayPackageName: "com.openburnbar",
    googlePlayMemoryBoostText1mProductID: "com.openburnbar.memory.boost.text.1m",
    googlePlayMemoryBoostText5mProductID: "com.openburnbar.memory.boost.text.5m",
    googlePlayMemoryBoostVision1mProductID: "com.openburnbar.memory.boost.vision.1m",
  }),
}));

vi.mock("../resilienceHelpers.js", () => ({
  externalApiWithResilience: vi.fn(async (_name: string, fn: () => Promise<unknown>) => fn()),
  googlePlayConsumeWithResilience: vi.fn(async (fn: () => Promise<unknown>) => fn()),
}));

vi.mock("../usageCuration/wallet.js", () => ({
  grantExists: (...args: unknown[]) => state.grantExists(...args),
  grantMemoryPack: (...args: unknown[]) => state.grantMemoryPack(...args),
  reverseMemoryPackGrant: (...args: unknown[]) => state.reverseMemoryPackGrant(...args),
}));

vi.mock("../usageCuration/eligibility.js", () => ({
  hasActiveMemoryPackVisionEntitlement: (...args: unknown[]) => state.visionEligible(...args),
}));

vi.mock("../callables/googlePlayTokenClaims.js", () => ({
  claimGooglePlayPurchaseToken: (...args: unknown[]) => state.claimToken(...args),
}));

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc: (path: string) => ({
      set: async (data: Record<string, unknown>) => {
        state.sets.push({ path, data });
      },
    }),
  },
}));

import { redeemPlayMemoryPack, reverseVoidedMemoryPack } from "../usageCuration/playRail.js";

const UID = "play-user";
const PRODUCT_ID = "com.openburnbar.memory.boost.text.1m";

describe("Play Memory Boost rail", () => {
  beforeEach(() => {
    state.productsGet.mockReset();
    state.productsConsume.mockReset();
    state.grantExists.mockReset();
    state.grantMemoryPack.mockReset();
    state.reverseMemoryPackGrant.mockReset();
    state.visionEligible.mockReset();
    state.claimToken.mockReset();
    state.sets = [];
    state.grantExists.mockResolvedValue(false);
    state.grantMemoryPack.mockResolvedValue({
      granted: true,
      pending: false,
      alreadyGranted: false,
    });
    state.visionEligible.mockResolvedValue(false);
    state.claimToken.mockResolvedValue(undefined);
    state.productsConsume.mockResolvedValue({});
  });

  it("refuses an unknown product and an unpaid purchase", async () => {
    await expect(
      redeemPlayMemoryPack({ uid: UID, purchaseToken: "tok", productID: "com.openburnbar.pro.monthly" }),
    ).rejects.toMatchObject({ code: "invalid-argument" });

    state.productsGet.mockResolvedValue({ data: { purchaseState: 1, orderId: "GPA.1" } });
    await expect(
      redeemPlayMemoryPack({ uid: UID, purchaseToken: "tok", productID: PRODUCT_ID }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });

  it("replays an already-granted pack and consumes if Play has not yet", async () => {
    state.productsGet.mockResolvedValue({
      data: { purchaseState: 0, consumptionState: 0, orderId: "GPA.replay" },
    });
    state.grantExists.mockImplementation(async (_uid: string, _source: string, transactionId: string) => {
      return transactionId === "GPA.replay";
    });
    const result = await redeemPlayMemoryPack({ uid: UID, purchaseToken: "tok", productID: PRODUCT_ID });
    expect(result.alreadyGranted).toBe(true);
    expect(result.consumed).toBe(true);
    expect(state.claimToken).not.toHaveBeenCalled();
    expect(state.productsConsume).toHaveBeenCalled();
  });

  it("refuses a consumed token that was never granted", async () => {
    state.productsGet.mockResolvedValue({
      data: { purchaseState: 0, consumptionState: 1, orderId: "GPA.consumed" },
    });
    await expect(
      redeemPlayMemoryPack({ uid: UID, purchaseToken: "tok", productID: PRODUCT_ID }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });

  it("claims, grants, consumes, and records a new purchase", async () => {
    state.productsGet.mockResolvedValue({
      data: { purchaseState: 0, consumptionState: 0, orderId: "GPA.new" },
    });
    const result = await redeemPlayMemoryPack({ uid: UID, purchaseToken: "tok-new", productID: PRODUCT_ID });
    expect(result).toMatchObject({ granted: true, consumed: true, packId: "text_1m", alreadyGranted: false });
    expect(state.claimToken).toHaveBeenCalledWith(
      expect.objectContaining({ uid: UID, kind: "memory_pack", productID: PRODUCT_ID }),
    );
    expect(state.grantMemoryPack).toHaveBeenCalledWith(
      expect.objectContaining({ uid: UID, source: "google_play", transactionId: "GPA.new", packId: "text_1m" }),
    );
    expect(state.sets[0]?.path).toContain("memory_pack");
  });

  it("treats a consume race as success when Play reports already consumed", async () => {
    state.productsGet
      .mockResolvedValueOnce({ data: { purchaseState: 0, consumptionState: 0, orderId: "GPA.race" } })
      .mockResolvedValueOnce({ data: { consumptionState: 1 } });
    state.productsConsume.mockRejectedValue(new Error("already consumed"));
    const result = await redeemPlayMemoryPack({ uid: UID, purchaseToken: "tok-race", productID: PRODUCT_ID });
    expect(result.consumed).toBe(true);
  });

  it("fails closed when Play does not confirm consumption", async () => {
    state.productsGet
      .mockResolvedValueOnce({ data: { purchaseState: 0, consumptionState: 0, orderId: "GPA.fail" } })
      .mockResolvedValueOnce({ data: { consumptionState: 0 } });
    state.productsConsume.mockRejectedValue(new Error("consume failed"));
    await expect(
      redeemPlayMemoryPack({ uid: UID, purchaseToken: "tok-fail", productID: PRODUCT_ID }),
    ).rejects.toMatchObject({ code: "unavailable" });
  });

  it("reverses a voided pack by order id or token hash", async () => {
    await reverseVoidedMemoryPack({ uid: UID, tokenHash: "hash", orderId: "GPA.void" });
    expect(state.reverseMemoryPackGrant).toHaveBeenCalledWith({
      uid: UID,
      source: "google_play",
      transactionId: "GPA.void",
      originalTransactionId: "hash",
      fullReversal: true,
    });
    await reverseVoidedMemoryPack({ uid: UID, tokenHash: "hash-only" });
    expect(state.reverseMemoryPackGrant).toHaveBeenCalledWith({
      uid: UID,
      source: "google_play",
      transactionId: "hash-only",
      originalTransactionId: "hash-only",
      fullReversal: true,
    });
  });
});
