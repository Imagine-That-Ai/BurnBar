import { beforeEach, describe, expect, it, vi } from "vitest";
import type Stripe from "stripe";

const state = vi.hoisted(() => ({
  docs: new Map<string, Record<string, unknown>>(),
  grantMemoryPack: vi.fn(),
  reverseMemoryPackGrant: vi.fn(),
  visionEligible: vi.fn(),
  loadCatalog: vi.fn(),
  stripeWithResilience: vi.fn(async (_name: string, fn: () => Promise<unknown>) => fn()),
  prices: {
    text_1m: "price_text_1m",
    text_5m: "price_text_5m",
    vision_1m: "price_vision_1m",
  },
}));

vi.mock("firebase-admin/firestore", () => ({
  Timestamp: {
    now: () => ({ seconds: 1, nanoseconds: 0 }),
  },
}));

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc: (path: string) => ({
      set: async (data: Record<string, unknown>, options?: { merge?: boolean }) => {
        const next = options?.merge ? { ...(state.docs.get(path) ?? {}), ...data } : data;
        state.docs.set(path, next);
      },
      get: async () => ({
        data: () => state.docs.get(path),
      }),
    }),
  },
}));

vi.mock("../resilienceHelpers.js", () => ({
  stripeWithResilience: (name: string, fn: () => Promise<unknown>) => state.stripeWithResilience(name, fn),
}));

vi.mock("../usageCuration/wallet.js", () => ({
  grantMemoryPack: (...args: unknown[]) => state.grantMemoryPack(...args),
  reverseMemoryPackGrant: (...args: unknown[]) => state.reverseMemoryPackGrant(...args),
}));

vi.mock("../usageCuration/eligibility.js", () => ({
  hasActiveMemoryPackVisionEntitlement: (...args: unknown[]) => state.visionEligible(...args),
}));

vi.mock("../usageCuration/remoteConfig.js", () => ({
  loadMemoryPackCatalog: (...args: unknown[]) => state.loadCatalog(...args),
}));

vi.mock("../config.js", () => ({
  getConfig: () => ({
    stripeMemoryBoostText1mPriceID: state.prices.text_1m,
    stripeMemoryBoostText5mPriceID: state.prices.text_5m,
    stripeMemoryBoostVision1mPriceID: state.prices.vision_1m,
  }),
}));

import {
  applyStripeMemoryPackCheckoutSession,
  reconcileStripeMemoryPackCharge,
  requireConfiguredStripeMemoryPackPrice,
  stripeMemoryPackCheckoutMetadata,
  stripeMemoryPackDiscountMinor,
  stripeMemoryPackIdempotencyKey,
  stripeMemoryPackLineItem,
} from "../usageCuration/stripeRail.js";

function stripeStub<T>(stub: object = {}): T {
  // @ts-expect-error reason: the stub implements the Stripe surface these Memory Boost tests exercise
  return stub;
}

const UID = "stripe-user";

function paidSession(overrides: Record<string, unknown> = {}): Stripe.Checkout.Session {
  return stripeStub<Stripe.Checkout.Session>({
    id: "cs_mem_1",
    metadata: { kind: "memory_pack", packId: "text_1m" },
    payment_status: "paid",
    amount_total: 299,
    currency: "usd",
    line_items: {
      data: [{ price: { id: "price_text_1m" }, quantity: 1 }],
    },
    payment_intent: { id: "pi_mem_1", latest_charge: { id: "ch_mem_1" } },
    ...overrides,
  });
}

describe("Stripe Memory Boost checkout guards", () => {
  it("does not default a missing line-item quantity to 1", () => {
    const parsed = stripeMemoryPackLineItem({
      line_items: {
        data: [{ price: { id: "price_text_1m" } }],
      },
    });
    expect(parsed.priceID).toBe("price_text_1m");
    expect(parsed.quantity).toBeUndefined();
  });

  it("accepts a string price id and ignores a non-record session", () => {
    expect(stripeMemoryPackLineItem({ line_items: { data: [{ price: "price_text_5m", quantity: 1 }] } })).toEqual({
      priceID: "price_text_5m",
      quantity: 1,
    });
    expect(stripeMemoryPackLineItem("session")).toEqual({});
    expect(stripeMemoryPackLineItem({ line_items: { data: [] } })).toEqual({});
  });

  it("rejects a discount on the session total", () => {
    expect(
      stripeMemoryPackDiscountMinor({
        total_details: { amount_discount: 50 },
      }),
    ).toBe(50);
    expect(
      stripeMemoryPackDiscountMinor({
        discounts: [{ coupon: "promo" }],
      }),
    ).toBeGreaterThan(0);
    expect(stripeMemoryPackDiscountMinor({})).toBe(0);
    expect(stripeMemoryPackDiscountMinor("session")).toBe(0);
  });
});

describe("Stripe Memory Boost checkout grant", () => {
  beforeEach(() => {
    state.docs.clear();
    state.grantMemoryPack.mockReset();
    state.reverseMemoryPackGrant.mockReset();
    state.visionEligible.mockReset();
    state.loadCatalog.mockReset();
    state.stripeWithResilience.mockClear();
    state.prices.text_1m = "price_text_1m";
    state.prices.text_5m = "price_text_5m";
    state.prices.vision_1m = "price_vision_1m";
    state.grantMemoryPack.mockResolvedValue({ granted: true, pending: false, alreadyGranted: false });
    state.visionEligible.mockResolvedValue(false);
    state.loadCatalog.mockResolvedValue({
      packs: {
        text_1m: { minChargeMinor: 200 },
        text_5m: { minChargeMinor: 700 },
        vision_1m: { minChargeMinor: 500 },
      },
    });
  });

  it("ignores a non-pack session and acknowledges an unpaid pack session", async () => {
    const stripe = stripeStub<Stripe>();
    expect(
      await applyStripeMemoryPackCheckoutSession(
        stripe,
        paidSession({ metadata: { kind: "subscription" } }),
        UID,
      ),
    ).toBe(false);
    expect(
      await applyStripeMemoryPackCheckoutSession(stripe, paidSession({ payment_status: "unpaid" }), UID),
    ).toBe(true);
    expect(state.grantMemoryPack).not.toHaveBeenCalled();
  });

  it("refuses missing packId, quantity other than 1, discounts, price mismatch, and sub-floor charges", async () => {
    const stripe = stripeStub<Stripe>();
    await expect(
      applyStripeMemoryPackCheckoutSession(stripe, paidSession({ metadata: { kind: "memory_pack" } }), UID),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    await expect(
      applyStripeMemoryPackCheckoutSession(stripe, paidSession({ line_items: { data: [{ price: { id: "price_text_1m" }, quantity: 2 }] } }), UID),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    await expect(
      applyStripeMemoryPackCheckoutSession(
        stripe,
        paidSession({ total_details: { amount_discount: 25 } }),
        UID,
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    await expect(
      applyStripeMemoryPackCheckoutSession(
        stripe,
        paidSession({ line_items: { data: [{ price: { id: "price_text_5m" }, quantity: 1 }] } }),
        UID,
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    await expect(
      applyStripeMemoryPackCheckoutSession(stripe, paidSession({ amount_total: 50 }), UID),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });

  it("expands line items, records the payment mapping, and grants the pack", async () => {
    const retrieveSession = vi.fn(async () =>
      paidSession({
        line_items: { data: [{ price: { id: "price_text_1m" }, quantity: 1 }] },
      }),
    );
    const stripe = stripeStub<Stripe>({
      checkout: { sessions: { retrieve: retrieveSession } },
    });
    expect(
      await applyStripeMemoryPackCheckoutSession(stripe, paidSession({ line_items: { data: [] } }), UID),
    ).toBe(true);
    expect(retrieveSession).toHaveBeenCalled();
    expect(state.grantMemoryPack).toHaveBeenCalledWith(
      expect.objectContaining({
        uid: UID,
        source: "stripe",
        transactionId: "cs_mem_1",
        packId: "text_1m",
        amountMinor: 299,
      }),
    );
    expect([...state.docs.keys()].some((path) => path.includes("charge_ch_mem_1"))).toBe(true);
    expect([...state.docs.keys()].some((path) => path.includes("payment_intent_pi_mem_1"))).toBe(true);
  });

  it("retrieves a string payment intent before granting", async () => {
    const retrievePI = vi.fn(async () => ({ id: "pi_str", latest_charge: "ch_str" }));
    const stripe = stripeStub<Stripe>({
      paymentIntents: { retrieve: retrievePI },
    });
    expect(
      await applyStripeMemoryPackCheckoutSession(stripe, paidSession({ payment_intent: "pi_str" }), UID),
    ).toBe(true);
    expect(retrievePI).toHaveBeenCalledWith("pi_str", { expand: ["latest_charge"] });
    expect([...state.docs.keys()].some((path) => path.includes("charge_ch_str"))).toBe(true);
  });
});

describe("Stripe Memory Boost refund and dispute rail", () => {
  beforeEach(() => {
    state.docs.clear();
    state.reverseMemoryPackGrant.mockReset();
    state.stripeWithResilience.mockClear();
    state.reverseMemoryPackGrant.mockResolvedValue(undefined);
  });

  it("returns false when the charge is not a Memory Boost payment", async () => {
    const stripe = stripeStub<Stripe>({
      paymentIntents: { retrieve: "not-a-function" },
    });
    expect(
      await reconcileStripeMemoryPackCharge(
        stripe,
        stripeStub<Stripe.Charge>({ id: "ch_other", payment_intent: "pi_other", amount: 299, amount_refunded: 0 }),
      ),
    ).toBe(false);

    const retrieve = vi.fn(async () => ({ metadata: { kind: "subscription" } }));
    expect(
      await reconcileStripeMemoryPackCharge(
        stripeStub<Stripe>({ paymentIntents: { retrieve } }),
        stripeStub<Stripe.Charge>({ id: "ch_sub", payment_intent: "pi_sub", amount: 299, amount_refunded: 0 }),
      ),
    ).toBe(false);
  });

  it("reverses from the Firestore mapping and restores a won dispute", async () => {
    await state.docs.set("stripe_memory_pack_payments/charge_ch_mapped", {
      uid: UID,
      packId: "text_1m",
      checkoutSessionID: "cs_mapped",
    });
    expect(
      await reconcileStripeMemoryPackCharge(
        stripeStub<Stripe>(),
        stripeStub<Stripe.Charge>({ id: "ch_mapped", payment_intent: "pi_mapped", amount: 299, amount_refunded: 299 }),
        "needs_response",
      ),
    ).toBe(true);
    expect(state.reverseMemoryPackGrant).toHaveBeenCalledWith(
      expect.objectContaining({
        uid: UID,
        transactionId: "cs_mapped",
        disputeStatus: "open",
        refundedAmountMinor: 299,
      }),
    );

    expect(
      await reconcileStripeMemoryPackCharge(
        stripeStub<Stripe>(),
        stripeStub<Stripe.Charge>({ id: "ch_mapped", payment_intent: "pi_mapped", amount: 299, amount_refunded: 0 }),
        "won",
      ),
    ).toBe(true);
    expect(state.reverseMemoryPackGrant).toHaveBeenCalledWith(
      expect.objectContaining({ disputeStatus: "won" }),
    );
  });

  it("looks the mapping up from Stripe and rethrows a missing grant", async () => {
    const retrieve = vi.fn(async () => ({
      metadata: { kind: "memory_pack", firebaseUID: UID, packId: "text_5m" },
    }));
    const list = vi.fn(async () => ({
      data: [{ id: "cs_lookup", metadata: { firebaseUID: UID, packId: "text_5m" } }],
    }));
    const stripe = stripeStub<Stripe>({
      paymentIntents: { retrieve },
      checkout: { sessions: { list } },
    });
    expect(
      await reconcileStripeMemoryPackCharge(
        stripe,
        stripeStub<Stripe.Charge>({ id: "ch_lookup", payment_intent: "pi_lookup", amount: 999, amount_refunded: 999 }),
      ),
    ).toBe(true);
    expect(state.reverseMemoryPackGrant).toHaveBeenCalledWith(
      expect.objectContaining({ uid: UID, transactionId: "cs_lookup" }),
    );

    state.reverseMemoryPackGrant.mockRejectedValueOnce(new Error("memory_pack_grant_missing"));
    await expect(
      reconcileStripeMemoryPackCharge(
        stripeStub<Stripe>(),
        stripeStub<Stripe.Charge>({ id: "ch_lookup", payment_intent: "pi_lookup", amount: 999, amount_refunded: 999 }),
      ),
    ).rejects.toMatchObject({ message: "memory_pack_grant_missing" });
  });

  it("throws when Stripe metadata cannot reconstruct the checkout mapping", async () => {
    const retrieve = vi.fn(async () => ({ metadata: { kind: "memory_pack" } }));
    const list = vi.fn(async () => ({ data: [] }));
    await expect(
      reconcileStripeMemoryPackCharge(
        stripeStub<Stripe>({
          paymentIntents: { retrieve },
          checkout: { sessions: { list } },
        }),
        stripeStub<Stripe.Charge>({ id: "ch_missing", payment_intent: "pi_missing", amount: 299, amount_refunded: 299 }),
      ),
    ).rejects.toMatchObject({ message: "memory_pack_grant_missing" });
  });
});

describe("Stripe Memory Boost checkout helpers", () => {
  it("requires a configured price, stamps metadata, and builds an idempotency key", () => {
    expect(requireConfiguredStripeMemoryPackPrice("text_1m")).toBe("price_text_1m");
    state.prices.text_1m = "";
    expect(() => requireConfiguredStripeMemoryPackPrice("text_1m")).toThrow(/not configured/);
    expect(stripeMemoryPackCheckoutMetadata(UID, "vision_1m")).toEqual({
      firebaseUID: UID,
      kind: "memory_pack",
      packId: "vision_1m",
    });
    expect(stripeMemoryPackIdempotencyKey(UID, "text_5m", "attempt-1")).toBe(
      "memory_pack_checkout_stripe-user_text_5m_attempt-1",
    );
  });
});
