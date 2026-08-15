import { describe, expect, it, vi } from "vitest";

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
  });
});
