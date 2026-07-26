import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import { STRIPE_CHECKOUT_CUSTOMER_AND_TAX_SETTINGS } from "../callables/stripeCheckoutPolicy.js";

describe("Stripe Checkout customer and tax policy", () => {
  it("enables automatic tax and persists the billing identity on the existing customer", () => {
    expect(STRIPE_CHECKOUT_CUSTOMER_AND_TAX_SETTINGS).toEqual({
      automatic_tax: { enabled: true },
      billing_address_collection: "auto",
      tax_id_collection: { enabled: true },
      customer_update: {
        address: "auto",
        name: "auto",
      },
    });
  });

  it("applies the shared policy to subscription and prepaid top-up checkout sessions", () => {
    const source = readFileSync(resolve(__dirname, "../callables/stripe.ts"), "utf8");
    expect(source.match(/\.\.\.STRIPE_CHECKOUT_CUSTOMER_AND_TAX_SETTINGS/gu)).toHaveLength(2);
  });
});
