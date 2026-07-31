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
        } else if (
          typeof value === "object" &&
          value !== null &&
          value.constructor.name === "NumericIncrementTransform"
        ) {
          const operand = Reflect.get(value, "operand");
          const prior = typeof next[key] === "number" ? next[key] : 0;
          next[key] = prior + (typeof operand === "number" ? operand : 0);
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

import {
  applyStripeCheckoutSession,
  applyStripeSubscription,
  BURNBAR_PRO_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
  deactivateStripeCustomerEntitlements,
  reconcileStripeCharge,
  reconcileStripeCreditNote,
  reconcileStripeDispute,
  reconcileStripeInvoice,
  writeBurnBarProEntitlement,
} from "../callables/shared.js";
import {
  markStripeWebhookEventFailed,
  markStripeWebhookEventProcessed,
  reserveStripeWebhookEvent,
} from "../callables/stripe.js";

const UID = "stripe-user-1";
const SUBSCRIPTION_ID = "sub_ordering_1";
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

describe("Stripe webhook entitlement ordering", () => {
  it("keeps a cancellation when a stale active subscription update replays later", async () => {
    await writeBurnBarProEntitlement({
      uid: UID,
      productID: "com.openburnbar.pro.monthly",
      expiresAtMillis: Date.parse("2026-06-10T00:00:00.000Z"),
      source: "stripe_webhook_verified",
      platform: "stripe",
      externalSubscriptionID: SUBSCRIPTION_ID,
      rawStatus: "canceled",
      environment: "Production",
      activeOverride: false,
      sourceEventID: "evt_deleted",
      sourceEventCreatedMillis: 2_000,
    });

    await writeBurnBarProEntitlement({
      uid: UID,
      productID: "com.openburnbar.pro.monthly",
      expiresAtMillis: Date.parse("2026-07-10T00:00:00.000Z"),
      source: "stripe_webhook_verified",
      platform: "stripe",
      externalSubscriptionID: SUBSCRIPTION_ID,
      rawStatus: "active",
      environment: "Production",
      activeOverride: true,
      sourceEventID: "evt_stale_update",
      sourceEventCreatedMillis: 1_000,
    });

    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.active).toBe(false);
    expect(entitlement?.rawStatus).toBe("canceled");
    expect(entitlement?.sourceEventID).toBe("evt_deleted");
    expect(entitlement?.sourceEventCreatedMillis).toBe(2_000);
  });

  it("preserves the watermark when a write carries none (checkout-path erasure regression, LB-5)", async () => {
    await activeSubscriptionWrite({ sourceEventID: "evt_first", sourceEventCreatedMillis: 2_000 });

    // A write with no event context (the pre-fix checkout path, or any
    // non-webhook caller) must still apply — and must NOT erase the
    // watermark, or the next buffered stale event would sail through.
    await activeSubscriptionWrite({
      expiresAtMillis: Date.parse("2026-08-10T00:00:00.000Z"),
      rawStatus: "active_renewed",
    });

    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.rawStatus).toBe("active_renewed");
    expect(entitlement?.expiresAt).toBe("2026-08-10T00:00:00.000Z");
    expect(entitlement?.sourceEventID).toBe("evt_first");
    expect(entitlement?.sourceEventCreatedMillis).toBe(2_000);

    // The preserved watermark still rejects the stale replay.
    await activeSubscriptionWrite({
      rawStatus: "stale_replay",
      activeOverride: false,
      sourceEventID: "evt_stale",
      sourceEventCreatedMillis: 1_000,
    });
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)?.rawStatus).toBe("active_renewed");
  });

  it("rejects a same-second write from a DIFFERENT event (second-granularity tie-break)", async () => {
    await writeBurnBarProEntitlement({
      uid: UID,
      productID: "com.openburnbar.pro.monthly",
      expiresAtMillis: Date.parse("2026-06-10T00:00:00.000Z"),
      source: "stripe_webhook_verified",
      platform: "stripe",
      externalSubscriptionID: SUBSCRIPTION_ID,
      rawStatus: "canceled",
      environment: "Production",
      activeOverride: false,
      sourceEventID: "evt_deleted",
      sourceEventCreatedMillis: 2_000,
    });

    // Stripe's event.created is second-granular: a stale update sharing the
    // cancellation's second used to slip past the strict > watermark check
    // and resurrect the entitlement.
    await activeSubscriptionWrite({
      rawStatus: "stale_same_second",
      sourceEventID: "evt_stale_update",
      sourceEventCreatedMillis: 2_000,
    });

    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.active).toBe(false);
    expect(entitlement?.rawStatus).toBe("canceled");
    expect(entitlement?.sourceEventID).toBe("evt_deleted");
  });

  it("re-applies a redelivery of the SAME event id (idempotent, not blocked by the tie-break)", async () => {
    await activeSubscriptionWrite({ sourceEventID: "evt_same", sourceEventCreatedMillis: 2_000 });

    // The webhook re-fetches the subscription, so a redelivered event can
    // legitimately carry fresher state under the same event id.
    await activeSubscriptionWrite({
      expiresAtMillis: Date.parse("2026-09-10T00:00:00.000Z"),
      rawStatus: "active_refetched",
      sourceEventID: "evt_same",
      sourceEventCreatedMillis: 2_000,
    });

    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.rawStatus).toBe("active_refetched");
    expect(entitlement?.expiresAt).toBe("2026-09-10T00:00:00.000Z");
  });
});

describe("Stripe checkout watermark stamping", () => {
  it("stamps the checkout event's watermark on the entitlement so later stale events are rejected", async () => {
    const eventCreatedMillis = Date.parse("2026-06-11T10:00:05.000Z");
    const periodEndSeconds = Math.floor(Date.parse("2030-01-01T00:00:00.000Z") / 1000);
    const retrieve = vi.fn(async () => ({
      id: SUBSCRIPTION_ID,
      status: "active",
      customer: "cus_checkout_1",
      metadata: { firebaseUID: UID },
      current_period_end: periodEndSeconds,
      items: { data: [] },
    }));
    // @ts-expect-error reason: Stripe stub for checkout watermark test
    const stripe: Stripe = { subscriptions: { retrieve } };
    const session = {
      id: "cs_test_1",
      metadata: { firebaseUID: UID },
      subscription: SUBSCRIPTION_ID,
      payment_status: "paid",
    };
    // @ts-expect-error reason: Stripe checkout session stub
    const typedSession: Stripe.Checkout.Session = session;

    await applyStripeCheckoutSession(stripe, typedSession, {
      eventID: "evt_checkout_1",
      eventCreatedMillis,
    });

    // The subscription was re-fetched fresh, so stamping the checkout
    // event's watermark is safe (state is at least as new as event.created).
    expect(retrieve).toHaveBeenCalledWith(SUBSCRIPTION_ID);
    const entitlement = firestoreState.docs.get(ENTITLEMENT_PATH);
    expect(entitlement?.active).toBe(true);
    expect(entitlement?.sourceEventID).toBe("evt_checkout_1");
    expect(entitlement?.sourceEventCreatedMillis).toBe(eventCreatedMillis);

    // A buffered pre-checkout subscription event can no longer rewind it.
    await activeSubscriptionWrite({
      rawStatus: "stale_pre_checkout",
      activeOverride: false,
      sourceEventID: "evt_pre_checkout",
      sourceEventCreatedMillis: eventCreatedMillis - 5_000,
    });
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)?.active).toBe(true);
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)?.sourceEventID).toBe("evt_checkout_1");
  });
});

describe("Stripe lifecycle reconciliation", () => {
  const PERIOD_END_SECONDS = Math.floor(Date.parse("2030-01-01T00:00:00.000Z") / 1000);

  function subscription(
    id: string,
    customer = "cus_lifecycle_1",
    status: Stripe.Subscription.Status = "active",
  ): Stripe.Subscription {
    const value = {
      id,
      status,
      customer,
      metadata: { firebaseUID: UID },
      current_period_end: PERIOD_END_SECONDS,
      items: { data: [] },
    };
    // @ts-expect-error reason: focused Stripe subscription stub
    return value;
  }

  it("maps an Ultra Stripe subscription to the Ultra entitlement and full feature set", async () => {
    const ultraMonthlyPriceID = "price_ultra_monthly";
    const ultra = {
      ...subscription("sub_ultra_1"),
      metadata: { firebaseUID: UID, entitlementID: BURNBAR_ULTRA_ENTITLEMENT_ID },
      items: { data: [{ price: { id: ultraMonthlyPriceID } }] },
    };

    await applyStripeSubscription({} as Stripe, ultra as unknown as Stripe.Subscription, UID, {
      eventID: "evt_ultra_1",
      eventCreatedMillis: 4_500,
    });

    expect(firestoreState.docs.get(`users/${UID}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`)).toMatchObject({
      active: true,
      entitlementFamily: BURNBAR_ULTRA_ENTITLEMENT_ID,
      features: {
        hostedQuota: true,
        hostedLLM: true,
        encryptedSessionLogBackup: true,
        cloudConversationSearch: true,
        floo: true,
        agentControl: true,
      },
      externalSubscriptionID: ultra.id,
      sourceEventID: "evt_ultra_1",
    });
  });

  it("reconciles invoice failures through the invoice's current subscription", async () => {
    const current = subscription("sub_invoice_current");
    const retrieve = vi.fn(async () => current);
    // @ts-expect-error reason: focused Stripe client stub
    const stripe: Stripe = { subscriptions: { retrieve } };
    const invoice = {
      id: "in_failed_1",
      customer: current.customer,
      parent: {
        type: "subscription_details",
        subscription_details: { subscription: current.id, metadata: null },
        quote_details: null,
      },
    };

    await reconcileStripeInvoice(
      stripe,
      // @ts-expect-error reason: focused Stripe invoice stub
      invoice,
      { eventID: "evt_invoice_failed", eventCreatedMillis: 4_000 },
    );

    expect(retrieve).toHaveBeenCalledWith(current.id);
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)).toMatchObject({
      active: true,
      externalSubscriptionID: current.id,
      sourceEventID: "evt_invoice_failed",
      sourceEventCreatedMillis: 4_000,
    });
  });

  it("reconciles a refunded charge against every current customer subscription", async () => {
    const cloud = subscription("sub_refund_cloud");
    const cloudPro = {
      ...subscription("sub_refund_cloud_pro"),
      metadata: { firebaseUID: UID, entitlementID: "burnbar_pro_max" },
    };
    const list = vi.fn(async () => ({ data: [cloud, cloudPro], has_more: false }));
    const charge = {
      id: "ch_refunded_1",
      customer: "cus_lifecycle_1",
      payment_intent: "pi_refunded_1",
      amount: 2_000,
      amount_refunded: 2_000,
    };
    const chargeRetrieve = vi.fn(async () => charge);
    const checkoutList = vi.fn(async () => ({ data: [], has_more: false }));
    const stripe = {
      subscriptions: { list },
      charges: { retrieve: chargeRetrieve },
      checkout: { sessions: { list: checkoutList } },
    } as unknown as Stripe;

    await reconcileStripeCharge(
      stripe,
      // @ts-expect-error reason: focused Stripe charge stub
      charge,
      { eventID: "evt_charge_refunded", eventCreatedMillis: 5_000 },
    );

    expect(list).toHaveBeenCalledWith({
      customer: "cus_lifecycle_1",
      limit: 100,
      status: "all",
    });
    expect(chargeRetrieve).toHaveBeenCalledWith(charge.id);
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)?.externalSubscriptionID).toBe(cloud.id);
    expect(firestoreState.docs.get(`users/${UID}/entitlements/burnbar_pro_max`)?.externalSubscriptionID).toBe(
      cloudPro.id,
    );
  });

  it("maps a paid top-up to its PaymentIntent and Charge, then reverses partial refunds", async () => {
    const customerID = "cus_topup_1";
    const paymentIntentID = "pi_topup_1";
    const chargeID = "ch_topup_1";
    await writeBurnBarProEntitlement({
      uid: UID,
      productID: "com.openburnbar.proMax.v2.monthly",
      expiresAtMillis: Date.parse("2030-01-01T00:00:00.000Z"),
      source: "stripe_webhook_verified",
      platform: "stripe",
      entitlementID: "burnbar_pro_max",
      rawStatus: "active",
      activeOverride: true,
    });
    const paidCharge = {
      id: chargeID,
      amount: 2_000,
      amount_refunded: 0,
      currency: "usd",
      customer: null,
      payment_intent: paymentIntentID,
    };
    const paymentIntentRetrieve = vi.fn(async () => ({
      id: paymentIntentID,
      amount: 2_000,
      amount_received: 2_000,
      currency: "usd",
      latest_charge: paidCharge,
    }));
    const chargeRetrieve = vi.fn(async () => paidCharge);
    const stripe = {
      paymentIntents: { retrieve: paymentIntentRetrieve },
      charges: { retrieve: chargeRetrieve },
    };
    const session = {
      id: "cs_topup_1",
      customer: customerID,
      metadata: { firebaseUID: UID, topUpKind: "agent_control_actions_100" },
      payment_status: "paid",
      payment_intent: paymentIntentID,
      amount_total: 2_000,
      currency: "usd",
    };

    await applyStripeCheckoutSession(stripe as unknown as Stripe, session as unknown as Stripe.Checkout.Session, {
      eventID: "evt_topup_paid",
      eventCreatedMillis: 8_000,
    });

    const allowancePath = `users/${UID}/billing/allowances/months/${new Date().toISOString().slice(0, 7)}`;
    const receiptPath = `users/${UID}/billing/cloud_pro_topups/receipts/stripe_checkout_${session.id}`;
    expect(firestoreState.docs.get(allowancePath)?.topupActionsPurchased).toBe(100);
    expect(firestoreState.docs.get(receiptPath)).toMatchObject({
      externalPaymentIntentID: paymentIntentID,
      externalChargeID: chargeID,
      externalAmountMinor: 2_000,
    });
    expect(firestoreState.docs.get(receiptPath)?.reversedUnits).toBeUndefined();
    expect(firestoreState.docs.get(`stripe_topup_payments/charge_${chargeID}`)).toMatchObject({
      uid: UID,
      receiptID: `stripe_checkout_${session.id}`,
      paymentIntentID,
      chargeID,
    });

    paidCharge.amount_refunded = 1_000;
    await reconcileStripeCharge(stripe as unknown as Stripe, paidCharge as unknown as Stripe.Charge, {
      eventID: "evt_topup_refund",
      eventCreatedMillis: 9_000,
    });

    expect(firestoreState.docs.get(allowancePath)?.topupActionsPurchased).toBe(50);
    expect(firestoreState.docs.get(receiptPath)).toMatchObject({
      refundedAmountMinor: 1_000,
      refundReversedUnits: 50,
      reversedUnits: 50,
      reversalState: "partial",
    });
  });

  it("suspends a disputed top-up and restores only the non-refunded portion after a win", async () => {
    const chargeID = "ch_disputed_topup_1";
    const paymentIntentID = "pi_disputed_topup_1";
    const receiptID = "stripe_checkout_cs_disputed_topup_1";
    const monthKey = "2026-07";
    const receiptPath = `users/${UID}/billing/cloud_pro_topups/receipts/${receiptID}`;
    const allowancePath = `users/${UID}/billing/allowances/months/${monthKey}`;
    firestoreState.docs.set(`stripe_topup_payments/charge_${chargeID}`, {
      uid: UID,
      receiptID,
      checkoutSessionID: "cs_disputed_topup_1",
      paymentIntentID,
      chargeID,
    });
    firestoreState.docs.set(receiptPath, {
      uid: UID,
      firstMonthKey: monthKey,
      latestMonthKey: monthKey,
      meter: "hosted_actions",
      units: 100,
      refundedAmountMinor: 500,
      refundReversedUnits: 25,
      reversedUnits: 25,
      externalAmountMinor: 2_000,
    });
    firestoreState.docs.set(allowancePath, { topupActionsPurchased: 75 });
    const charge = {
      id: chargeID,
      amount: 2_000,
      amount_refunded: 500,
      currency: "usd",
      customer: null,
      payment_intent: paymentIntentID,
    };
    const chargeRetrieve = vi.fn(async () => charge);
    const paymentIntentRetrieve = vi.fn(async () => ({ id: paymentIntentID, customer: null }));
    const disputeRetrieve = vi
      .fn()
      .mockResolvedValueOnce({ id: "dp_topup_1", charge, status: "under_review" })
      .mockResolvedValueOnce({ id: "dp_topup_1", charge, status: "won" });
    const stripe = {
      charges: { retrieve: chargeRetrieve },
      disputes: { retrieve: disputeRetrieve },
      paymentIntents: { retrieve: paymentIntentRetrieve },
    };
    const dispute = { id: "dp_topup_1", charge, status: "under_review" };

    await reconcileStripeDispute(stripe as unknown as Stripe, dispute as unknown as Stripe.Dispute, {
      eventID: "evt_dispute_open",
      eventCreatedMillis: 10_000,
    });
    expect(firestoreState.docs.get(allowancePath)?.topupActionsPurchased).toBe(0);
    expect(firestoreState.docs.get(receiptPath)).toMatchObject({
      disputeStatus: "under_review",
      disputeReversedUnits: 100,
      reversedUnits: 100,
      reversalState: "reversed",
    });

    await reconcileStripeDispute(stripe as unknown as Stripe, dispute as unknown as Stripe.Dispute, {
      eventID: "evt_dispute_won",
      eventCreatedMillis: 11_000,
    });
    expect(firestoreState.docs.get(allowancePath)?.topupActionsPurchased).toBe(75);
    expect(firestoreState.docs.get(receiptPath)).toMatchObject({
      disputeStatus: "won",
      disputeReversedUnits: 0,
      refundReversedUnits: 25,
      reversedUnits: 25,
      reversalState: "partial",
    });
  });

  it("resolves credit notes through their invoice before reconciling the subscription", async () => {
    const current = subscription("sub_credit_note_1");
    const invoiceRetrieve = vi.fn(async () => ({
      id: "in_credit_note_1",
      customer: current.customer,
      parent: {
        type: "subscription_details",
        subscription_details: { subscription: current.id, metadata: null },
        quote_details: null,
      },
    }));
    const subscriptionRetrieve = vi.fn(async () => current);
    const stripe = {
      invoices: { retrieve: invoiceRetrieve },
      subscriptions: { retrieve: subscriptionRetrieve },
    };

    await reconcileStripeCreditNote(
      // @ts-expect-error reason: focused Stripe client stub
      stripe,
      { id: "cn_1", invoice: "in_credit_note_1", customer: current.customer },
      { eventID: "evt_credit_note", eventCreatedMillis: 6_000 },
    );

    expect(invoiceRetrieve).toHaveBeenCalledWith("in_credit_note_1");
    expect(subscriptionRetrieve).toHaveBeenCalledWith(current.id);
    expect(firestoreState.docs.get(ENTITLEMENT_PATH)?.sourceEventID).toBe("evt_credit_note");
  });

  it("deactivates only Stripe-backed entitlements when the Stripe customer is deleted", async () => {
    const customerID = "cus_deleted_1";
    firestoreState.docs.set(`stripe_customers/${customerID}`, { uid: UID, customerID });
    await activeSubscriptionWrite({
      externalCustomerID: customerID,
      sourceEventID: "evt_active",
      sourceEventCreatedMillis: 1_000,
    });
    await writeBurnBarProEntitlement({
      uid: UID,
      productID: "com.openburnbar.pro.max.monthly",
      expiresAtMillis: Date.parse("2030-01-01T00:00:00.000Z"),
      source: "app_store_verified",
      platform: "ios",
      entitlementID: "burnbar_pro_max",
      rawStatus: "active",
      activeOverride: true,
    });

    await deactivateStripeCustomerEntitlements(customerID, undefined, {
      eventID: "evt_customer_deleted",
      eventCreatedMillis: 7_000,
    });

    expect(firestoreState.docs.get(ENTITLEMENT_PATH)).toMatchObject({
      active: false,
      rawStatus: "customer_deleted",
      sourceEventID: "evt_customer_deleted",
    });
    expect(firestoreState.docs.get(`users/${UID}/entitlements/burnbar_pro_max`)?.active).toBe(true);
    expect(firestoreState.docs.get(`stripe_customers/${customerID}`)).toMatchObject({
      subscriptionStatus: "customer_deleted",
    });
  });
});

describe("stripe_webhook_events ledger TTL", () => {
  const RETENTION_MS = 90 * 24 * 60 * 60 * 1000;

  function fakeEvent(id: string, createdSeconds: number): Stripe.Event {
    const event = { id, type: "customer.subscription.updated", created: createdSeconds };
    // @ts-expect-error reason: Stripe event stub
    const typed: Stripe.Event = event;
    return typed;
  }

  function ledgerExpireAtMillis(eventID: string): number | undefined {
    const doc = firestoreState.docs.get(`stripe_webhook_events/${eventID}`);
    const expireAt = doc?.expireAt;
    const toMillis = expireAt && typeof expireAt === "object" ? Reflect.get(expireAt, "toMillis") : undefined;
    return typeof toMillis === "function" ? toMillis.call(expireAt) : undefined;
  }

  it("writes expireAt = event time + 90 days on reserve, processed, and failed ledger writes", async () => {
    const createdSeconds = Math.floor(Date.parse("2026-06-11T09:00:00.000Z") / 1000);
    const expected = createdSeconds * 1000 + RETENTION_MS;

    const processedEvent = fakeEvent("evt_ledger_processed", createdSeconds);
    await reserveStripeWebhookEvent(processedEvent);
    expect(ledgerExpireAtMillis("evt_ledger_processed")).toBe(expected);
    await markStripeWebhookEventProcessed(processedEvent);
    const processedDoc = firestoreState.docs.get("stripe_webhook_events/evt_ledger_processed");
    expect(processedDoc?.status).toBe("processed");
    expect(ledgerExpireAtMillis("evt_ledger_processed")).toBe(expected);

    const failedEvent = fakeEvent("evt_ledger_failed", createdSeconds);
    await reserveStripeWebhookEvent(failedEvent);
    await markStripeWebhookEventFailed(failedEvent, new Error("handler exploded"));
    const failedDoc = firestoreState.docs.get("stripe_webhook_events/evt_ledger_failed");
    expect(failedDoc?.status).toBe("failed");
    expect(ledgerExpireAtMillis("evt_ledger_failed")).toBe(expected);
  });
});
