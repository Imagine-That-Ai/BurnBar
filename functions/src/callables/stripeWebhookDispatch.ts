/**
 * @fileoverview Stripe webhook lifecycle dispatch separated from the HTTP transport.
 */

import Stripe from "stripe";

import {
  isStripeCharge,
  isStripeCheckoutSession,
  isStripeCreditNote,
  isStripeCustomer,
  isStripeDispute,
  isStripeInvoice,
  isStripeRefund,
  isStripeSubscription,
} from "../guards.js";
import { stripeWithResilience } from "../resilienceHelpers.js";
import {
  applyStripeCheckoutSession,
  applyStripeSubscription,
  deactivateStripeCustomerEntitlements,
  reconcileStripeCharge,
  reconcileStripeCreditNote,
  reconcileStripeDispute,
  reconcileStripeInvoice,
  reconcileStripeRefund,
} from "./shared.js";

const CHECKOUT_EVENT_TYPES = new Set<string>([
  "checkout.session.completed",
  "checkout.session.async_payment_succeeded",
]);
const SUBSCRIPTION_REFRESH_EVENT_TYPES = new Set<string>([
  "customer.subscription.created",
  "customer.subscription.updated",
]);
const INVOICE_EVENT_TYPES = new Set<string>([
  "invoice.paid",
  "invoice.payment_succeeded",
  "invoice.payment_failed",
  "invoice.voided",
  "invoice.marked_uncollectible",
]);
const REFUND_EVENT_TYPES = new Set<string>([
  "charge.refund.updated",
  "refund.created",
  "refund.updated",
  "refund.failed",
]);
const DISPUTE_EVENT_TYPES = new Set<string>([
  "charge.dispute.created",
  "charge.dispute.updated",
  "charge.dispute.closed",
]);
const CREDIT_NOTE_EVENT_TYPES = new Set<string>(["credit_note.created", "credit_note.updated", "credit_note.voided"]);

interface StripeEventContext {
  eventID: string;
  eventCreatedMillis: number;
}

async function processCheckoutEvent(
  stripe: Stripe,
  event: Stripe.Event,
  eventContext: StripeEventContext,
): Promise<void> {
  const session = event.data.object;
  if (isStripeCheckoutSession(session)) {
    // The checkout path re-fetches the subscription fresh, so the written
    // state is at least as new as event.created.
    await applyStripeCheckoutSession(stripe, session, eventContext);
  }
}

async function processSubscriptionRefreshEvent(
  stripe: Stripe,
  event: Stripe.Event,
  eventContext: StripeEventContext,
): Promise<void> {
  const snapshot = event.data.object;
  if (!isStripeSubscription(snapshot)) return;

  // Stripe timestamps have second granularity. Re-fetching current state makes
  // same-second events converge, while the source event id remains the stable
  // ordering tie-break in the entitlement ledger.
  const subscription = await stripeWithResilience("subscriptions.retrieve.webhook", () =>
    stripe.subscriptions.retrieve(snapshot.id),
  );
  await applyStripeSubscription(stripe, subscription, undefined, eventContext);
}

async function processSubscriptionDeletedEvent(
  stripe: Stripe,
  event: Stripe.Event,
  eventContext: StripeEventContext,
): Promise<void> {
  const subscription = event.data.object;
  if (!isStripeSubscription(subscription)) return;

  // Cancellation is terminal, and retrieval may fail after customer deletion,
  // so the deletion snapshot itself is authoritative.
  await applyStripeSubscription(stripe, subscription, undefined, eventContext);
}

/** Applies the lifecycle mutation represented by one verified Stripe event. */
export async function processStripeWebhookEvent(stripe: Stripe, event: Stripe.Event): Promise<void> {
  const eventContext = {
    eventID: event.id,
    eventCreatedMillis: event.created * 1000,
  };

  if (CHECKOUT_EVENT_TYPES.has(event.type)) {
    await processCheckoutEvent(stripe, event, eventContext);
    return;
  }
  if (SUBSCRIPTION_REFRESH_EVENT_TYPES.has(event.type)) {
    await processSubscriptionRefreshEvent(stripe, event, eventContext);
    return;
  }
  if (event.type === "customer.subscription.deleted") {
    await processSubscriptionDeletedEvent(stripe, event, eventContext);
    return;
  }
  if (INVOICE_EVENT_TYPES.has(event.type)) {
    if (isStripeInvoice(event.data.object)) {
      await reconcileStripeInvoice(stripe, event.data.object, eventContext);
    }
    return;
  }
  if (event.type === "charge.refunded") {
    if (isStripeCharge(event.data.object)) {
      await reconcileStripeCharge(stripe, event.data.object, eventContext);
    }
    return;
  }
  if (REFUND_EVENT_TYPES.has(event.type)) {
    if (isStripeRefund(event.data.object)) {
      await reconcileStripeRefund(stripe, event.data.object, eventContext);
    }
    return;
  }
  if (DISPUTE_EVENT_TYPES.has(event.type)) {
    if (isStripeDispute(event.data.object)) {
      await reconcileStripeDispute(stripe, event.data.object, eventContext);
    }
    return;
  }
  if (CREDIT_NOTE_EVENT_TYPES.has(event.type)) {
    if (isStripeCreditNote(event.data.object)) {
      await reconcileStripeCreditNote(stripe, event.data.object, eventContext);
    }
    return;
  }
  if (event.type === "customer.deleted") {
    const customer = event.data.object;
    if (isStripeCustomer(customer)) {
      await deactivateStripeCustomerEntitlements(customer.id, customer.metadata?.firebaseUID, eventContext);
    }
  }
}
