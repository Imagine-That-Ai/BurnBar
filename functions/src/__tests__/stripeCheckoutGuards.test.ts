import { describe, expect, it, vi } from "vitest";
import type Stripe from "stripe";

vi.mock("../adminRuntime.js", () => ({
  auth: {},
  db: {},
}));

vi.mock("../resilienceHelpers.js", () => ({
  stripeWithResilience: vi.fn(async <T>(_name: string, fn: () => Promise<T>) => fn()),
}));

import {
  STRIPE_CHECKOUT_SCHEMA_VERSION,
  assertStripeCustomerCanStartSubscriptionCheckout,
  findReusableStripeSubscriptionCheckoutSession,
  stripeTaxAwareCheckoutParams,
} from "../callables/shared/stripe.js";

describe("Stripe subscription checkout guards", () => {
  it("enables automatic tax and persists verified Checkout billing identity", () => {
    expect(stripeTaxAwareCheckoutParams()).toEqual({
      automatic_tax: { enabled: true },
      billing_address_collection: "auto",
      customer_update: {
        address: "auto",
        name: "auto",
      },
      tax_id_collection: { enabled: true },
    });
  });

  it("rejects checkout when a non-terminal subscription already exists", async () => {
    const list = vi.fn(async () => ({
      data: [{ id: "sub_existing_1", status: "past_due" }],
      has_more: false,
    }));
    const stripe = { subscriptions: { list } } as unknown as Stripe;

    await expect(assertStripeCustomerCanStartSubscriptionCheckout(stripe, "cus_existing_1")).rejects.toMatchObject({
      code: "already-exists",
      details: {
        subscriptionID: "sub_existing_1",
        subscriptionStatus: "past_due",
        action: "open_billing_portal",
      },
    });
  });

  it("allows checkout after only terminal subscriptions and reuses a matching open session", async () => {
    const subscriptionList = vi.fn(async () => ({
      data: [
        { id: "sub_canceled_1", status: "canceled" },
        { id: "sub_expired_1", status: "incomplete_expired" },
      ],
      has_more: false,
    }));
    const openSession = {
      id: "cs_reusable_1",
      mode: "subscription",
      url: "https://checkout.stripe.test/reusable",
      metadata: {
        tier: "cloud_pro",
        cadence: "annual",
        checkoutSchemaVersion: STRIPE_CHECKOUT_SCHEMA_VERSION,
      },
      automatic_tax: { enabled: true },
      tax_id_collection: { enabled: true },
    };
    const sessionList = vi.fn(async () => ({ data: [openSession], has_more: false }));
    const stripe = {
      subscriptions: { list: subscriptionList },
      checkout: { sessions: { list: sessionList } },
    } as unknown as Stripe;

    await expect(assertStripeCustomerCanStartSubscriptionCheckout(stripe, "cus_terminal_1")).resolves.toBeUndefined();
    await expect(
      findReusableStripeSubscriptionCheckoutSession(stripe, "cus_terminal_1", {
        tier: "cloud_pro",
        cadence: "annual",
      }),
    ).resolves.toMatchObject({ id: openSession.id, url: openSession.url });
  });

  it("does not reuse a legacy open session that lacks tax-aware customer updates", async () => {
    const sessionList = vi.fn(async () => ({
      data: [
        {
          id: "cs_legacy_1",
          mode: "subscription",
          url: "https://checkout.stripe.test/legacy",
          metadata: { tier: "cloud", cadence: "monthly" },
          automatic_tax: { enabled: false },
          tax_id_collection: { enabled: false },
        },
      ],
      has_more: false,
    }));
    const stripe = {
      checkout: { sessions: { list: sessionList } },
    } as unknown as Stripe;

    await expect(
      findReusableStripeSubscriptionCheckoutSession(stripe, "cus_legacy_1", {
        tier: "cloud",
        cadence: "monthly",
      }),
    ).resolves.toBeUndefined();
  });
});
