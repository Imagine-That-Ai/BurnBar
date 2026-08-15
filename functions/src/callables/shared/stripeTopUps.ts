/**
 * @fileoverview Stripe Checkout top-up crediting and refund/dispute reconciliation.
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import Stripe from "stripe";

import { db } from "../../adminRuntime.js";
import { type CloudProTopUpKind } from "../../cloudProAllowanceCore.js";
import { stripeWithResilience } from "../../resilienceHelpers.js";
import { creditCloudProTopUp, reconcileCloudProTopUpReversal } from "./entitlements.js";
import { requiredIdentifier } from "./validators.js";

interface StripeTopUpPaymentMapping {
  uid: string;
  receiptID: string;
  checkoutSessionID: string;
  paymentIntentID?: string;
  chargeID?: string;
}

interface StripeEventContext {
  eventID?: string;
  eventCreatedMillis?: number;
}

function stripeTopUpKind(raw: string): CloudProTopUpKind {
  if (
    raw === "agent_control_actions_100" ||
    raw === "floo_relay_50gb" ||
    raw === "elder_wand_searches_100" ||
    raw === "elder_wand_searches_500"
  ) {
    return raw;
  }
  throw new HttpsError("invalid-argument", "Unsupported Stripe top-up kind.");
}

function stripeObjectID(value: unknown): string | undefined {
  if (typeof value === "string" && value.length > 0) return value;
  if (value && typeof value === "object" && "id" in value && typeof value.id === "string") {
    return value.id;
  }
  return undefined;
}

async function stripePaymentIntentForCheckoutSession(
  stripe: Stripe,
  session: Stripe.Checkout.Session,
): Promise<Stripe.PaymentIntent | undefined> {
  const sessionPaymentIntent = session.payment_intent;
  if (sessionPaymentIntent && typeof sessionPaymentIntent === "object") {
    return sessionPaymentIntent;
  }
  if (typeof sessionPaymentIntent !== "string") return undefined;
  return stripeWithResilience("payment_intents.retrieve.checkout_topup", () =>
    stripe.paymentIntents.retrieve(sessionPaymentIntent, {
      expand: ["latest_charge"],
    }),
  );
}

function stripeChargeAmount(charge: string | Stripe.Charge | null | undefined): number | undefined {
  return charge && typeof charge === "object" && Number.isFinite(charge.amount) ? charge.amount : undefined;
}

function stripeChargeCurrency(charge: string | Stripe.Charge | null | undefined): string | undefined {
  return charge && typeof charge === "object" && typeof charge.currency === "string" ? charge.currency : undefined;
}

/**
 * Applies a Checkout top-up when the session carries top-up metadata.
 *
 * Returns true whenever the session belongs to the top-up flow, including a
 * pending/unpaid session that should not fall through into subscription logic.
 */
export async function applyStripeTopUpCheckoutSession(
  stripe: Stripe,
  session: Stripe.Checkout.Session,
  uid: string,
): Promise<boolean> {
  const rawTopUpKind = session.metadata?.topUpKind;
  if (!rawTopUpKind) return false;
  if (session.payment_status !== "paid") return true;

  const paymentIntent = await stripePaymentIntentForCheckoutSession(stripe, session);
  const paymentIntentID = stripeObjectID(paymentIntent) ?? stripeObjectID(session.payment_intent);
  const chargeID = paymentIntent ? stripeObjectID(paymentIntent.latest_charge) : undefined;
  const amountMinor =
    stripeChargeAmount(paymentIntent?.latest_charge) ??
    paymentIntent?.amount_received ??
    paymentIntent?.amount ??
    session.amount_total ??
    undefined;
  const currency =
    stripeChargeCurrency(paymentIntent?.latest_charge) ?? paymentIntent?.currency ?? session.currency ?? undefined;

  await creditCloudProTopUp({
    uid,
    kind: stripeTopUpKind(rawTopUpKind),
    source: "stripe_checkout",
    externalPaymentID: session.id,
    externalPaymentIntentID: paymentIntentID,
    externalChargeID: chargeID,
    externalAmountMinor: amountMinor,
    externalCurrency: currency,
  });
  await recordStripeTopUpPayment({
    uid,
    receiptID: requiredIdentifier(`stripe_checkout_${session.id}`, "receiptID"),
    checkoutSessionID: session.id,
    paymentIntentID,
    chargeID,
  });
  return true;
}

function stripeTopUpPaymentMappingRef(kind: "charge" | "payment_intent", externalID: string) {
  return db.doc(`stripe_topup_payments/${requiredIdentifier(`${kind}_${externalID}`, "stripeTopUpPaymentID")}`);
}

async function recordStripeTopUpPayment(mapping: StripeTopUpPaymentMapping): Promise<void> {
  const now = Timestamp.now();
  const doc = {
    ...mapping,
    updatedAt: now,
    schemaVersion: 1,
  };
  const refs = [
    mapping.chargeID ? stripeTopUpPaymentMappingRef("charge", mapping.chargeID) : undefined,
    mapping.paymentIntentID ? stripeTopUpPaymentMappingRef("payment_intent", mapping.paymentIntentID) : undefined,
  ].filter((ref): ref is ReturnType<typeof stripeTopUpPaymentMappingRef> => !!ref);
  await Promise.all(refs.map((ref) => ref.set(doc, { merge: true })));
}

async function readStripeTopUpPaymentMapping(
  kind: "charge" | "payment_intent",
  externalID: string,
): Promise<StripeTopUpPaymentMapping | undefined> {
  const snap = await stripeTopUpPaymentMappingRef(kind, externalID).get();
  const data = snap.data();
  if (
    !data ||
    typeof data.uid !== "string" ||
    typeof data.receiptID !== "string" ||
    typeof data.checkoutSessionID !== "string"
  ) {
    return undefined;
  }
  return {
    uid: data.uid,
    receiptID: data.receiptID,
    checkoutSessionID: data.checkoutSessionID,
    paymentIntentID: typeof data.paymentIntentID === "string" ? data.paymentIntentID : undefined,
    chargeID: typeof data.chargeID === "string" ? data.chargeID : undefined,
  };
}

async function stripeTopUpPaymentMappingForCharge(
  stripe: Stripe,
  charge: Stripe.Charge,
): Promise<StripeTopUpPaymentMapping | undefined> {
  const paymentIntentID = stripeObjectID(charge.payment_intent);
  const direct =
    (await readStripeTopUpPaymentMapping("charge", charge.id)) ??
    (paymentIntentID ? await readStripeTopUpPaymentMapping("payment_intent", paymentIntentID) : undefined);
  if (direct) return direct;
  if (!paymentIntentID) return undefined;

  // Backfill pre-mapping Stripe top-ups from Checkout metadata. This does not
  // re-credit anything; it only reconnects an existing receipt to the current
  // PaymentIntent/Charge so refunds and disputes remain enforceable.
  const sessions = await stripeWithResilience("checkout.sessions.list.topup_reconcile", () =>
    stripe.checkout.sessions.list({
      payment_intent: paymentIntentID,
      limit: 100,
    }),
  );
  const session = sessions.data.find(
    (candidate) =>
      candidate.payment_status === "paid" &&
      typeof candidate.metadata?.firebaseUID === "string" &&
      typeof candidate.metadata?.topUpKind === "string",
  );
  const uid = session?.metadata?.firebaseUID;
  if (!session || !uid) return undefined;
  const mapping: StripeTopUpPaymentMapping = {
    uid,
    receiptID: requiredIdentifier(`stripe_checkout_${session.id}`, "receiptID"),
    checkoutSessionID: session.id,
    paymentIntentID,
    chargeID: charge.id,
  };
  await recordStripeTopUpPayment(mapping);
  return mapping;
}

export async function reconcileStripeTopUpCharge(
  stripe: Stripe,
  charge: Stripe.Charge,
  eventContext: StripeEventContext,
  disputeStatus?: Stripe.Dispute.Status,
): Promise<void> {
  const mapping = await stripeTopUpPaymentMappingForCharge(stripe, charge);
  if (!mapping) return;
  const reversal = await reconcileCloudProTopUpReversal({
    uid: mapping.uid,
    receiptID: mapping.receiptID,
    refundedAmountMinor: charge.amount_refunded,
    originalAmountMinor: charge.amount,
    disputeStatus,
    sourceEventID: eventContext.eventID,
    sourceEventCreatedMillis: eventContext.eventCreatedMillis,
  });
  if (reversal.receiptMissing) {
    // Stripe delivers webhooks out of order: this refund/dispute resolved a
    // top-up mapping (so fulfillment WILL create the receipt), but the paid
    // Checkout event has not credited it yet. Returning success here would
    // mark the reversal event processed and the later fulfillment would
    // credit the full units with nothing left to reverse. Throw so the
    // webhook reports failure and Stripe redelivers until the receipt exists.
    throw new Error(
      `Stripe top-up reversal for receipt ${mapping.receiptID} arrived before fulfillment created the receipt; failing so the webhook retries.`,
    );
  }
}
