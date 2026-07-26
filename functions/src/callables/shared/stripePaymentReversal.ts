/**
 * @fileoverview Durable per-subscription Stripe payment-reversal markers.
 *
 * A full refund or an open/lost dispute reverses a subscription payment
 * WITHOUT moving the subscription out of `active`, so subscription state
 * alone would keep the entitlement alive. `reconcileStripeCharge` records the
 * money-state here and `applyStripeSubscription` consults it before granting.
 */

import { Timestamp } from "firebase-admin/firestore";
import type Stripe from "stripe";

import { stripeWithResilience } from "../../resilienceHelpers.js";
import { jsonObject, stripUndefinedObject } from "../../guards.js";
import { db } from "../../adminRuntime.js";

interface StripeEventContext {
  eventID?: string;
  eventCreatedMillis?: number;
}

export function stripePaymentReversalDocPath(subscriptionID: string): string {
  return `stripe_payment_reversals/${subscriptionID}`;
}

export function stripeObjectID(value: unknown): string | undefined {
  if (typeof value === "string" && value.length > 0) return value;
  if (value && typeof value === "object" && "id" in value && typeof value.id === "string") {
    return value.id;
  }
  return undefined;
}

export function stripeInvoiceSubscriptionID(invoice: Stripe.Invoice): string | undefined {
  const parentSubscription = invoice.parent?.subscription_details?.subscription;
  const parentID = stripeObjectID(parentSubscription);
  if (parentID) return parentID;

  // Compatibility for invoices created under older Stripe API versions.
  return stripeObjectID(jsonObject(invoice).subscription);
}

/**
 * Dispute statuses under which the funds are (or are about to be) pulled from
 * the platform, mirroring the top-up dispute policy in
 * {@link import("./stripeTopUpReversal.js").disputeTopUpReversalUnits}: reverse
 * while the dispute is open or lost, restore on won / warning_closed.
 */
const STRIPE_DISPUTE_REVERSING_STATUSES = new Set<Stripe.Dispute.Status>([
  "needs_response",
  "under_review",
  "warning_needs_response",
  "warning_under_review",
  "lost",
]);

function stripeChargeReversalReason(
  charge: Stripe.Charge,
  disputeStatus?: Stripe.Dispute.Status,
): string | undefined {
  if (disputeStatus && STRIPE_DISPUTE_REVERSING_STATUSES.has(disputeStatus)) {
    return `dispute_${disputeStatus}`;
  }
  const amount = typeof charge.amount === "number" ? charge.amount : 0;
  const amountRefunded = typeof charge.amount_refunded === "number" ? charge.amount_refunded : 0;
  if (charge.refunded === true || (amount > 0 && amountRefunded >= amount)) {
    return "fully_refunded";
  }
  return undefined;
}

/**
 * Resolves the subscription an invoice-backed charge paid for. Charges created
 * under older Stripe API versions embed `invoice` directly; current API
 * versions require walking payment_intent -> invoice payments -> invoice.
 * Returns undefined for non-subscription charges (e.g. top-ups).
 */
async function stripeChargeSubscriptionID(stripe: Stripe, charge: Stripe.Charge): Promise<string | undefined> {
  let invoiceID = stripeObjectID(jsonObject(charge).invoice);
  if (!invoiceID) {
    const paymentIntentID = stripeObjectID(charge.payment_intent);
    if (!paymentIntentID) return undefined;
    const payments = await stripeWithResilience("invoice_payments.list.charge_reversal", () =>
      stripe.invoicePayments.list({
        payment: { type: "payment_intent", payment_intent: paymentIntentID },
        limit: 10,
      }),
    );
    for (const payment of payments.data) {
      invoiceID = stripeObjectID(payment.invoice);
      if (invoiceID) break;
    }
  }
  if (!invoiceID) return undefined;
  const invoice = await stripeWithResilience("invoices.retrieve.charge_reversal", () =>
    stripe.invoices.retrieve(invoiceID),
  );
  return stripeInvoiceSubscriptionID(invoice);
}

/**
 * Persists the durable per-subscription payment-reversal marker consulted by
 * `applyStripeSubscription`. The marker is set when a subscription charge is
 * fully refunded or actively disputed, and cleared only when the SAME charge
 * later recovers (dispute won / refund failed), so a partial refund on a
 * newer invoice can never silently re-enable an entitlement that an older
 * charge's dispute reversed.
 */
export async function recordStripeSubscriptionPaymentReversal(
  stripe: Stripe,
  charge: Stripe.Charge,
  eventContext: StripeEventContext = {},
  disputeStatus?: Stripe.Dispute.Status,
): Promise<void> {
  const reason = stripeChargeReversalReason(charge, disputeStatus);
  const subscriptionID = await stripeChargeSubscriptionID(stripe, charge);
  if (!subscriptionID) return;
  const ref = db.doc(stripePaymentReversalDocPath(subscriptionID));
  if (reason) {
    await ref.set(
      stripUndefinedObject({
        reversed: true,
        reason,
        subscriptionID,
        chargeID: charge.id,
        sourceEventID: eventContext.eventID,
        sourceEventCreatedMillis: eventContext.eventCreatedMillis,
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      }),
      { merge: true },
    );
    return;
  }
  const existing = await ref.get();
  if (existing.get("reversed") !== true || existing.get("chargeID") !== charge.id) return;
  await ref.set(
    stripUndefinedObject({
      reversed: false,
      reason: "restored",
      chargeID: charge.id,
      sourceEventID: eventContext.eventID,
      sourceEventCreatedMillis: eventContext.eventCreatedMillis,
      updatedAt: Timestamp.now(),
    }),
    { merge: true },
  );
}
