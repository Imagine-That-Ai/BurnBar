import { describe, expect, it, vi } from "vitest";
import type Stripe from "stripe";

const state = vi.hoisted(() => {
  const writes: Array<{ path: string; data: Record<string, unknown> }> = [];
  return {
    documents: new Map<string, Record<string, unknown>>(),
    writes,
  };
});

vi.mock("../adminRuntime.js", () => ({
  auth: {
    getUser: vi.fn(async () => ({
      email: "member@example.com",
      displayName: "BurnBar Member",
    })),
  },
  db: {
    doc: (path: string) => ({
      get: async () => {
        const data = state.documents.get(path);
        return {
          get: (field: string) => data?.[field],
        };
      },
      set: async (data: Record<string, unknown>) => {
        state.documents.set(path, { ...(state.documents.get(path) ?? {}), ...data });
        state.writes.push({ path, data });
      },
    }),
  },
}));

vi.mock("../resilienceHelpers.js", () => ({
  stripeWithResilience: vi.fn(async <T>(_name: string, fn: () => Promise<T>) => fn()),
}));

vi.mock("../logging.js", () => ({
  logWarn: vi.fn(),
}));

import {
  assertStripeCustomerCanStartSubscriptionCheckout,
  expireOpenStripeSubscriptionCheckoutSessions,
  findReusableStripeSubscriptionCheckoutSession,
  getOrCreateStripeCustomer,
} from "../callables/shared/stripe.js";

// The guards under test take a Stripe client; each stub covers the client surface its test exercises.
function stripeClient(stub: object): Stripe {
  // @ts-expect-error reason: the stub implements the Stripe client surface these checkout guard tests exercise
  return stub;
}

describe("Stripe subscription checkout guards", () => {
  it("rejects checkout when a non-terminal subscription already exists", async () => {
    const list = vi.fn(async () => ({
      data: [{ id: "sub_existing_1", status: "past_due" }],
      has_more: false,
    }));
    const stripe = stripeClient({ subscriptions: { list } });

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
        redirectFingerprint: "production-redirects",
      },
    };
    const sessionList = vi.fn(async () => ({ data: [openSession], has_more: false }));
    const stripe = stripeClient({
      subscriptions: { list: subscriptionList },
      checkout: { sessions: { list: sessionList } },
    });

    await expect(assertStripeCustomerCanStartSubscriptionCheckout(stripe, "cus_terminal_1")).resolves.toBeUndefined();
    await expect(
      findReusableStripeSubscriptionCheckoutSession(
        stripe,
        "cus_terminal_1",
        {
          tier: "cloud_pro",
          cadence: "annual",
        },
        "production-redirects",
      ),
    ).resolves.toMatchObject({ id: openSession.id, url: openSession.url });
  });

  it("does not reuse a staging Checkout Session for production redirects", async () => {
    const stagingSession = {
      id: "cs_staging_1",
      mode: "subscription",
      url: "https://checkout.stripe.test/staging",
      metadata: {
        tier: "cloud_pro",
        cadence: "annual",
        redirectFingerprint: "staging-redirects",
      },
    };
    const sessionList = vi.fn(async () => ({ data: [stagingSession], has_more: false }));
    const stripe = stripeClient({
      checkout: { sessions: { list: sessionList } },
    });

    await expect(
      findReusableStripeSubscriptionCheckoutSession(
        stripe,
        "cus_environment_boundary",
        { tier: "cloud_pro", cadence: "annual" },
        "production-redirects",
      ),
    ).resolves.toBeUndefined();
  });

  it("expires every open subscription-mode session so parallel selections cannot both be paid", async () => {
    const openSessions = [
      { id: "cs_open_cloud_monthly", mode: "subscription" },
      { id: "cs_open_ultra_annual", mode: "subscription" },
      { id: "cs_open_topup", mode: "payment" },
    ];
    const sessionList = vi.fn(async () => ({ data: openSessions, has_more: false }));
    const expire = vi.fn(async (id: string) => ({ id, status: "expired" }));
    const stripe = stripeClient({
      checkout: { sessions: { list: sessionList, expire } },
    });

    await expireOpenStripeSubscriptionCheckoutSessions(stripe, "cus_parallel_1");

    expect(sessionList).toHaveBeenCalledWith({
      customer: "cus_parallel_1",
      limit: 100,
      status: "open",
    });
    expect(expire.mock.calls.map((call) => call[0])).toEqual(["cs_open_cloud_monthly", "cs_open_ultra_annual"]);
  });

  it("swallows an expire race when a listed session already completed", async () => {
    const sessionList = vi.fn(async () => ({
      data: [
        { id: "cs_completed_in_race", mode: "subscription" },
        { id: "cs_still_open", mode: "subscription" },
      ],
      has_more: false,
    }));
    const expire = vi
      .fn()
      .mockRejectedValueOnce(new Error("This Checkout Session is already complete."))
      .mockResolvedValueOnce({ id: "cs_still_open", status: "expired" });
    const stripe = stripeClient({
      checkout: { sessions: { list: sessionList, expire } },
    });

    await expect(expireOpenStripeSubscriptionCheckoutSessions(stripe, "cus_race_1")).resolves.toBeUndefined();
    expect(expire).toHaveBeenCalledTimes(2);
  });

  it("recovers a metadata-matched Stripe customer before creating another", async () => {
    state.documents.clear();
    state.writes.length = 0;
    const search = vi.fn(async () => ({
      data: [
        {
          id: "cus_recovered_1",
          created: 1_700_000_000,
          metadata: { firebaseUID: "firebase-user-1" },
        },
      ],
    }));
    const create = vi.fn();
    const stripe = stripeClient({ customers: { search, create } });

    await expect(getOrCreateStripeCustomer("firebase-user-1", stripe)).resolves.toBe("cus_recovered_1");
    expect(create).not.toHaveBeenCalled();
    expect(state.documents.get("users/firebase-user-1/billing/stripe")).toMatchObject({
      uid: "firebase-user-1",
      customerID: "cus_recovered_1",
    });
  });

  it("uses one stable Stripe idempotency key for concurrent first-customer creation", async () => {
    state.documents.clear();
    state.writes.length = 0;
    const search = vi.fn(async () => ({ data: [] }));
    const create = vi.fn(async (_params: unknown, options: { idempotencyKey?: string }) => ({
      id: "cus_idempotent_1",
      created: 1_700_000_100,
      metadata: { firebaseUID: "firebase-user-race" },
      options,
    }));
    const stripe = stripeClient({ customers: { search, create } });

    const [first, second] = await Promise.all([
      getOrCreateStripeCustomer("firebase-user-race", stripe),
      getOrCreateStripeCustomer("firebase-user-race", stripe),
    ]);

    expect(first).toBe("cus_idempotent_1");
    expect(second).toBe("cus_idempotent_1");
    expect(create).toHaveBeenCalledTimes(2);
    const idempotencyKeys = create.mock.calls.map((call) => call[1]?.idempotencyKey);
    expect(new Set(idempotencyKeys).size).toBe(1);
    expect(idempotencyKeys[0]).toMatch(/^burnbar_customer_v1:[a-f0-9]{64}$/u);
  });
});
