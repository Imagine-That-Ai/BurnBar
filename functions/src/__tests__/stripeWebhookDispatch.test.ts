import { beforeEach, describe, expect, it, vi } from "vitest";
import type Stripe from "stripe";

const state = vi.hoisted(() => ({
  applyCheckout: vi.fn(),
  applySubscription: vi.fn(),
  reconcileInvoice: vi.fn(),
  reconcileCharge: vi.fn(),
  reconcileRefund: vi.fn(),
  reconcileDispute: vi.fn(),
  reconcileCreditNote: vi.fn(),
  deactivateCustomer: vi.fn(),
}));

vi.mock("../resilienceHelpers.js", () => ({
  stripeWithResilience: vi.fn(async <T>(_name: string, fn: () => Promise<T>) => fn()),
}));

vi.mock("../callables/shared.js", () => ({
  applyStripeCheckoutSession: state.applyCheckout,
  applyStripeSubscription: state.applySubscription,
  reconcileStripeInvoice: state.reconcileInvoice,
  reconcileStripeCharge: state.reconcileCharge,
  reconcileStripeRefund: state.reconcileRefund,
  reconcileStripeDispute: state.reconcileDispute,
  reconcileStripeCreditNote: state.reconcileCreditNote,
  deactivateStripeCustomerEntitlements: state.deactivateCustomer,
}));

import { processStripeWebhookEvent } from "../callables/stripeWebhookDispatch.js";

function webhookEvent(type: string, object: Record<string, unknown>, id = "evt_dispatch_1"): Stripe.Event {
  return {
    id,
    type,
    created: 1_700_000_000,
    data: { object },
  } as unknown as Stripe.Event;
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("processStripeWebhookEvent", () => {
  it("applies completed Checkout sessions with the event ordering context", async () => {
    const session = { id: "cs_1", object: "checkout.session" };
    const event = webhookEvent("checkout.session.completed", session);

    await processStripeWebhookEvent({} as Stripe, event);

    expect(state.applyCheckout).toHaveBeenCalledWith(
      {},
      session,
      expect.objectContaining({
        eventID: event.id,
        eventCreatedMillis: event.created * 1000,
      }),
    );
  });

  it("re-fetches subscription creates and updates before applying current state", async () => {
    const snapshot = { id: "sub_1", object: "subscription" };
    const current = { ...snapshot, status: "active" };
    const retrieve = vi.fn(async () => current);
    const stripe = { subscriptions: { retrieve } } as unknown as Stripe;
    const event = webhookEvent("customer.subscription.updated", snapshot);

    await processStripeWebhookEvent(stripe, event);

    expect(retrieve).toHaveBeenCalledWith(snapshot.id);
    expect(state.applySubscription).toHaveBeenCalledWith(
      stripe,
      current,
      undefined,
      expect.objectContaining({ eventID: event.id }),
    );
  });

  it("applies subscription deletions from the terminal snapshot without retrieval", async () => {
    const snapshot = { id: "sub_deleted_1", object: "subscription", status: "canceled" };
    const event = webhookEvent("customer.subscription.deleted", snapshot);

    await processStripeWebhookEvent({} as Stripe, event);

    expect(state.applySubscription).toHaveBeenCalledWith(
      {},
      snapshot,
      undefined,
      expect.objectContaining({ eventID: event.id }),
    );
  });

  it.each([
    ["invoice.payment_failed", "reconcileInvoice", { id: "in_1" }],
    ["charge.refunded", "reconcileCharge", { id: "ch_1" }],
    ["refund.updated", "reconcileRefund", { id: "re_1" }],
    ["charge.dispute.closed", "reconcileDispute", { id: "dp_1" }],
    ["credit_note.voided", "reconcileCreditNote", { id: "cn_1" }],
  ] as const)("routes %s to %s", async (type, stateKey, object) => {
    const event = webhookEvent(type, object);

    await processStripeWebhookEvent({} as Stripe, event);

    expect(state[stateKey]).toHaveBeenCalledWith(
      {},
      object,
      expect.objectContaining({ eventID: event.id, eventCreatedMillis: event.created * 1000 }),
    );
  });

  it("deactivates a deleted customer's Stripe entitlements", async () => {
    const customer = { id: "cus_deleted_1", metadata: { firebaseUID: "uid_1" } };
    const event = webhookEvent("customer.deleted", customer);

    await processStripeWebhookEvent({} as Stripe, event);

    expect(state.deactivateCustomer).toHaveBeenCalledWith(
      customer.id,
      customer.metadata.firebaseUID,
      expect.objectContaining({ eventID: event.id }),
    );
  });

  it("ignores unrelated Stripe events", async () => {
    await processStripeWebhookEvent({} as Stripe, webhookEvent("payment_intent.created", { id: "pi_1" }));

    for (const handler of Object.values(state)) {
      expect(handler).not.toHaveBeenCalled();
    }
  });
});
