/**
 * Covers the two review-hardening behaviors around Stripe money-state:
 * 1. A fully refunded / disputed subscription charge deactivates the
 *    entitlement via the stripe_payment_reversals marker (and a recovery of
 *    the SAME charge restores it).
 * 2. The same-second webhook tie-break lets an activation supersede a
 *    transient inactive state (incomplete -> active) while still failing
 *    closed for terminal or unknown inactive states.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

const firestoreState = vi.hoisted(() => {
  type Doc = Record<string, unknown>;
  const docs = new Map<string, Doc>();

  class FakeDocSnapshot {
    constructor(private readonly value: Doc | undefined) {}

    get exists() {
      return this.value !== undefined;
    }

    data() {
      return this.value === undefined ? undefined : { ...this.value };
    }

    get(field: string) {
      return this.value === undefined ? undefined : this.value[field];
    }
  }

  class FakeDocRef {
    constructor(readonly path: string) {}

    collection(name: string) {
      return {
        doc: (id: string) => new FakeDocRef(`${this.path}/${name}/${id}`),
      };
    }

    async get() {
      return new FakeDocSnapshot(docs.get(this.path));
    }

    set(data: Doc, options?: { merge?: boolean }) {
      const next = options?.merge ? { ...(docs.get(this.path) ?? {}) } : {};
      for (const [key, value] of Object.entries(data)) {
        if (typeof value === "object" && value !== null && value.constructor.name === "DeleteTransform") {
          delete next[key];
        } else {
          next[key] = value;
        }
      }
      docs.set(this.path, next);
      return Promise.resolve();
    }
  }

  const db = {
    doc: (path: string) => new FakeDocRef(path),
    runTransaction: async <T>(
      fn: (transaction: {
        get: (ref: FakeDocRef) => ReturnType<FakeDocRef["get"]>;
        set: (ref: FakeDocRef, data: Doc, options?: { merge?: boolean }) => void;
      }) => Promise<T>,
    ): Promise<T> =>
      fn({
        get: (ref) => ref.get(),
        set: (ref, data, options) => {
          void ref.set(data, options);
        },
      }),
  };

  return { docs, db };
});

vi.mock("../adminRuntime.js", () => ({
  auth: {},
  db: firestoreState.db,
}));

vi.mock("../cloudProAllowanceRemoteConfig.js", () => ({
  loadCloudProAllowanceConfig: vi.fn(async () => ({
    includedHostedActionsMonthly: 500,
    includedRelayGBMonthly: 50,
    includedFusionSearchesMonthly: 100,
    includedUltraFusionSearchesMonthly: 300,
    actionTopUpUnit: 100,
    relayTopUpUnitGB: 50,
    fusionSearchTopUpUnit: 100,
    fusionSearchLargeTopUpUnit: 500,
    monthlyHostedActionCap: 2_000,
    monthlyRelayGBCap: 300,
    monthlyFusionSearchCap: 1_000,
    monthlyUltraFusionSearchCap: 2_000,
  })),
}));

vi.mock("../resilienceHelpers.js", () => ({
  stripeWithResilience: vi.fn(async <T>(_name: string, fn: () => Promise<T>) => fn()),
}));

import type Stripe from "stripe";

import { BURNBAR_PRO_ENTITLEMENT_ID, reconcileStripeCharge, writeBurnBarProEntitlement } from "../callables/shared.js";

function stripeStub<T>(stub: object = {}): T {
  // @ts-expect-error reason: the stub implements the Stripe surface these reversal tests exercise
  return stub;
}

const UID = "stripe-user-1";
const SUBSCRIPTION_ID = "sub_reversal_1";
const ENTITLEMENT_PATH = `users/${UID}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`;

function activeSubscriptionWrite(overrides: Partial<Parameters<typeof writeBurnBarProEntitlement>[0]> = {}) {
  return writeBurnBarProEntitlement({
    uid: UID,
    productID: "com.openburnbar.pro.monthly",
    expiresAtMillis: Date.parse("2026-07-10T00:00:00.000Z"),
    source: "stripe_webhook_verified",
    platform: "stripe",
    externalSubscriptionID: SUBSCRIPTION_ID,
    rawStatus: "active",
    environment: "Production",
    activeOverride: true,
    ...overrides,
  });
}

beforeEach(() => {
  firestoreState.docs.clear();
});

describe("Stripe subscription payment reversal", () => {
  it("deactivates a subscription entitlement on a fully refunded charge and restores it when the refund fails", async () => {
    const subscription = {
      id: SUBSCRIPTION_ID,
      status: "active",
      customer: "cus_reversal_1",
      metadata: { firebaseUID: UID },
      current_period_end: Math.floor(Date.parse("2030-01-01T00:00:00.000Z") / 1000),
      items: { data: [] },
    };
    const charge = {
      id: "ch_reversal_1",
      customer: "cus_reversal_1",
      payment_intent: "pi_reversal_1",
      amount: 2_000,
      amount_refunded: 2_000,
      refunded: true,
    };
    const stripe = stripeStub<Stripe>({
      subscriptions: { list: vi.fn(async () => ({ data: [subscription], has_more: false })) },
      charges: { retrieve: vi.fn(async () => charge) },
      checkout: { sessions: { list: vi.fn(async () => ({ data: [], has_more: false })) } },
      invoicePayments: {
        list: vi.fn(async () => ({ data: [{ id: "inpay_1", invoice: "in_reversal_1" }], has_more: false })),
      },
      invoices: {
        retrieve: vi.fn(async () => ({
          id: "in_reversal_1",
          customer: subscription.customer,
          parent: {
            type: "subscription_details",
            subscription_details: { subscription: subscription.id, metadata: null },
            quote_details: null,
          },
        })),
      },
    });

    await reconcileStripeCharge(
      stripe,
      // @ts-expect-error reason: focused Stripe charge stub
      charge,
      { eventID: "evt_full_refund", eventCreatedMillis: 5_000 },
    );

    expect(firestoreState.docs.get(`stripe_payment_reversals/${subscription.id}`)).toMatchObject({
      reversed: true,
      reason: "fully_refunded",
      chargeID: charge.id,
    });
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)).toMatchObject({
      active: false,
      rawStatus: "active:payment_reversed",
      externalSubscriptionID: subscription.id,
    });

    // The full refund later fails: Stripe re-sends the charge with the
    // refunded amount restored, and the SAME charge's marker is cleared.
    charge.amount_refunded = 0;
    charge.refunded = false;
    await reconcileStripeCharge(
      stripe,
      // @ts-expect-error reason: focused Stripe charge stub
      charge,
      { eventID: "evt_refund_failed", eventCreatedMillis: 6_000 },
    );

    expect(firestoreState.docs.get(`stripe_payment_reversals/${subscription.id}`)).toMatchObject({
      reversed: false,
      reason: "restored",
    });
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)).toMatchObject({
      active: true,
      rawStatus: "active",
    });
  });
});

describe("same-second tie-break vs transient inactive states", () => {
  it("allows a same-second activation to replace a transient inactive state (incomplete -> active)", async () => {
    // Stripe emits customer.subscription.created (status=incomplete) and
    // customer.subscription.updated (status=active) within the same second on
    // a normal first payment; the tie-break must not strand the entitlement
    // inactive when the incomplete event happens to apply first.
    await activeSubscriptionWrite({
      rawStatus: "incomplete",
      activeOverride: false,
      sourceEventID: "evt_incomplete",
      sourceEventCreatedMillis: 2_000,
    });

    await activeSubscriptionWrite({
      sourceEventID: "evt_activated",
      sourceEventCreatedMillis: 2_000,
    });

    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.active).toBe(true);
    expect(entitlement?.rawStatus).toBe("active");
    expect(entitlement?.sourceEventID).toBe("evt_activated");
  });

  it("fails closed on a same-second activation over an unknown inactive status", async () => {
    await activeSubscriptionWrite({
      rawStatus: "some_future_status",
      activeOverride: false,
      sourceEventID: "evt_unknown_status",
      sourceEventCreatedMillis: 2_000,
    });

    await activeSubscriptionWrite({
      sourceEventID: "evt_activation_replay",
      sourceEventCreatedMillis: 2_000,
    });

    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.active).toBe(false);
    expect(entitlement?.rawStatus).toBe("some_future_status");
    expect(entitlement?.sourceEventID).toBe("evt_unknown_status");
  });
});
