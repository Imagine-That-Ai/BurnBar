import { describe, expect, it, vi } from "vitest";
import type Stripe from "stripe";

vi.mock("../adminRuntime.js", () => ({
  db: { doc: () => ({ set: vi.fn(), get: vi.fn() }) },
}));
vi.mock("../resilienceHelpers.js", () => ({
  stripeWithResilience: vi.fn(),
}));
vi.mock("../usageCuration/wallet.js", () => ({
  grantMemoryPack: vi.fn(),
  reverseMemoryPackGrant: vi.fn(),
}));
vi.mock("../usageCuration/eligibility.js", () => ({
  hasActiveMemoryPackVisionEntitlement: vi.fn(),
}));
vi.mock("../usageCuration/remoteConfig.js", () => ({
  loadMemoryPackCatalog: vi.fn(),
}));
vi.mock("../config.js", () => ({
  getConfig: () => ({}),
}));
vi.mock("../callables/shared/validators.js", () => ({
  requiredIdentifier: (value: string) => value,
}));

import { stripeMemoryPackDiscountMinor, stripeMemoryPackLineItem } from "../usageCuration/stripeRail.js";

function session(partial: Record<string, unknown>): Stripe.Checkout.Session {
  return partial as unknown as Stripe.Checkout.Session;
}

describe("Stripe Memory Boost checkout guards", () => {
  it("does not default a missing line-item quantity to 1", () => {
    const parsed = stripeMemoryPackLineItem(
      session({
        line_items: {
          data: [{ price: { id: "price_text_1m" } }],
        },
      }),
    );
    expect(parsed.priceID).toBe("price_text_1m");
    expect(parsed.quantity).toBeUndefined();
  });

  it("rejects a discount on the session total", () => {
    expect(
      stripeMemoryPackDiscountMinor(
        session({
          total_details: { amount_discount: 50 },
        }),
      ),
    ).toBe(50);
    expect(
      stripeMemoryPackDiscountMinor(
        session({
          discounts: [{ coupon: "promo" }],
        }),
      ),
    ).toBeGreaterThan(0);
    expect(stripeMemoryPackDiscountMinor(session({}))).toBe(0);
  });
});
