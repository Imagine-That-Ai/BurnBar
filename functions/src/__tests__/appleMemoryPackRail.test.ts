import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Firestore } from "firebase-admin/firestore";

const state = vi.hoisted(() => {
  const bindings: Array<{ uid: string }> = [];
  return {
    grantExists: vi.fn(),
    grantMemoryPack: vi.fn(),
    reverseMemoryPackGrant: vi.fn(),
    visionEligible: vi.fn(),
    consumeBindingByToken: vi.fn(),
    logWarn: vi.fn(),
    bindings,
  };
});

vi.mock("../config.js", () => ({
  getConfig: () => ({
    memoryBoostText1mProductID: "com.openburnbar.memory.boost.text.1m",
    memoryBoostText5mProductID: "com.openburnbar.memory.boost.text.5m",
    memoryBoostVision1mProductID: "com.openburnbar.memory.boost.vision.1m",
  }),
}));

vi.mock("../usageCuration/wallet.js", () => ({
  grantExists: (...args: unknown[]) => state.grantExists(...args),
  grantMemoryPack: (...args: unknown[]) => state.grantMemoryPack(...args),
  reverseMemoryPackGrant: (...args: unknown[]) => state.reverseMemoryPackGrant(...args),
}));

vi.mock("../usageCuration/eligibility.js", () => ({
  hasActiveMemoryPackVisionEntitlement: (...args: unknown[]) => state.visionEligible(...args),
}));

vi.mock("../appstore/reconciler.js", () => ({
  consumeBindingByToken: (...args: unknown[]) => state.consumeBindingByToken(...args),
}));

vi.mock("../logging.js", () => ({
  logWarn: (...args: unknown[]) => state.logWarn(...args),
}));

import { applyAppleMemoryPackNotification, redeemAppleMemoryPack } from "../usageCuration/appleRail.js";

const UID = "apple-user";
function appleDb(): Firestore {
  const stub = {
    collectionGroup: () => ({
      where: () => ({
        limit: () => ({
          get: async () => ({
            docs: state.bindings.map((binding) => ({
              get: (field: string) => (field === "uid" ? binding.uid : undefined),
            })),
          }),
        }),
      }),
    }),
  };
  // @ts-expect-error reason: collectionGroup stub is the Apple Memory Boost notification surface these tests exercise
  return stub;
}
const db = appleDb();

describe("Apple Memory Boost rail", () => {
  beforeEach(() => {
    state.grantExists.mockReset();
    state.grantMemoryPack.mockReset();
    state.reverseMemoryPackGrant.mockReset();
    state.visionEligible.mockReset();
    state.consumeBindingByToken.mockReset();
    state.logWarn.mockReset();
    state.bindings = [];
    state.grantMemoryPack.mockResolvedValue({
      granted: true,
      pending: false,
      alreadyGranted: false,
    });
    state.visionEligible.mockResolvedValue(true);
  });

  it("refuses an unknown product id", async () => {
    await expect(
      redeemAppleMemoryPack({
        db,
        uid: UID,
        productID: "com.openburnbar.pro.monthly",
        transactionId: "txn_1",
      }),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });

  it("replays an existing grant without consuming a fresh binding", async () => {
    state.grantExists.mockResolvedValue(true);
    const result = await redeemAppleMemoryPack({
      db,
      uid: UID,
      productID: "com.openburnbar.memory.boost.text.1m",
      transactionId: "txn_replay",
    });
    expect(result.alreadyGranted).toBe(true);
    expect(state.consumeBindingByToken).not.toHaveBeenCalled();
    expect(state.grantMemoryPack).toHaveBeenCalledWith(
      expect.objectContaining({ uid: UID, transactionId: "txn_replay", packId: "text_1m" }),
    );
  });

  it("requires a matching appAccountToken binding on first redeem", async () => {
    state.grantExists.mockResolvedValue(false);
    await expect(
      redeemAppleMemoryPack({
        db,
        uid: UID,
        productID: "com.openburnbar.memory.boost.text.1m",
        transactionId: "txn_new",
      }),
    ).rejects.toMatchObject({ code: "permission-denied" });

    state.consumeBindingByToken.mockResolvedValue("other-user");
    await expect(
      redeemAppleMemoryPack({
        db,
        uid: UID,
        productID: "com.openburnbar.memory.boost.text.1m",
        transactionId: "txn_new",
        appAccountToken: "TOKEN",
      }),
    ).rejects.toMatchObject({ code: "permission-denied" });

    state.consumeBindingByToken.mockResolvedValue(UID);
    const result = await redeemAppleMemoryPack({
      db,
      uid: UID,
      productID: "com.openburnbar.memory.boost.text.1m",
      transactionId: "txn_new",
      appAccountToken: "TOKEN",
    });
    expect(result).toMatchObject({ granted: true, packId: "text_1m", alreadyGranted: false });
    expect(state.consumeBindingByToken).toHaveBeenCalledWith(db, "token", UID);
  });

  it("routes Apple refund, restore, consumption, and one-time charge notifications", async () => {
    expect(
      await applyAppleMemoryPackNotification({
        db,
        productID: "not-a-pack",
        transactionId: "txn",
      }),
    ).toBe(false);

    state.bindings = [{ uid: UID }];
    expect(
      await applyAppleMemoryPackNotification({
        db,
        productID: "com.openburnbar.memory.boost.text.1m",
        transactionId: "txn_refund",
        appAccountToken: "bind",
        notificationType: "REFUND",
      }),
    ).toBe(true);
    expect(state.reverseMemoryPackGrant).toHaveBeenCalledWith(
      expect.objectContaining({ uid: UID, refundFull: true }),
    );

    expect(
      await applyAppleMemoryPackNotification({
        db,
        productID: "com.openburnbar.memory.boost.text.1m",
        transactionId: "txn_restore",
        appAccountToken: "bind",
        notificationType: "REFUND_REVERSED",
      }),
    ).toBe(true);
    expect(state.reverseMemoryPackGrant).toHaveBeenCalledWith(
      expect.objectContaining({ uid: UID, restoreRefund: true }),
    );

    expect(
      await applyAppleMemoryPackNotification({
        db,
        productID: "com.openburnbar.memory.boost.text.1m",
        transactionId: "txn_consume",
        notificationType: "CONSUMPTION_REQUEST",
      }),
    ).toBe(true);
    expect(state.logWarn).toHaveBeenCalled();

    expect(
      await applyAppleMemoryPackNotification({
        db,
        productID: "com.openburnbar.memory.boost.text.1m",
        transactionId: "txn_charge",
        notificationType: "ONE_TIME_CHARGE",
      }),
    ).toBe(true);
    expect(state.grantMemoryPack).not.toHaveBeenCalled();

    await applyAppleMemoryPackNotification({
      db,
      productID: "com.openburnbar.memory.boost.vision.1m",
      transactionId: "txn_charge",
      appAccountToken: "bind",
      notificationType: "ONE_TIME_CHARGE",
    });
    expect(state.grantMemoryPack).toHaveBeenCalledWith(
      expect.objectContaining({ uid: UID, packId: "vision_1m", source: "app_store" }),
    );

    expect(
      await applyAppleMemoryPackNotification({
        db,
        productID: "com.openburnbar.memory.boost.text.1m",
        transactionId: "txn_other",
        notificationType: "DID_RENEW",
      }),
    ).toBe(true);
  });
});
