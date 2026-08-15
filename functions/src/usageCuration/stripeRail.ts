/**
 * @fileoverview Stripe Checkout + refund/dispute rail for Memory Power-Up packs.
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import Stripe from "stripe";

import { db } from "../adminRuntime.js";
import { stripeWithResilience } from "../resilienceHelpers.js";
import { requiredIdentifier } from "../callables/shared/validators.js";
import {
  DEFAULT_MEMORY_PACKS,
  isMemoryPackId,
  memoryPackFromStripePriceID,
  memoryPackRuntimeIds,
  type MemoryPackId,
} from "./catalog.js";
import { loadMemoryPackCatalog } from "./remoteConfig.js";
import { stripeMemoryPackPaymentDocPath } from "./paths.js";
import { grantMemoryPack, reverseMemoryPackGrant } from "./wallet.js";
import { hasActiveMemoryPackVisionEntitlement } from "./eligibility.js";

function stripeObjectID(value: unknown): string | undefined {
  if (typeof value === "string" && value.length > 0) return value;
  if (value && typeof value === "object" && "id" in value && typeof value.id === "string") {
    return value.id;
  }
  return undefined;
}

export function stripeMemoryPackLineItem(session: Stripe.Checkout.Session): {
  priceID?: string;
  quantity?: number;
} {
  const item = session.line_items?.data?.[0];
  if (!item) return {};
  const price = item.price;
  const priceID = typeof price === "string" ? price : price?.id;
  const quantity = item.quantity;
  return {
    priceID,
    quantity: typeof quantity === "number" && Number.isInteger(quantity) ? quantity : undefined,
  };
}

export function stripeMemoryPackDiscountMinor(session: Stripe.Checkout.Session): number {
  const totalDiscount = session.total_details?.amount_discount;
  if (typeof totalDiscount === "number" && Number.isFinite(totalDiscount) && totalDiscount > 0) {
    return totalDiscount;
  }
  if (Array.isArray(session.discounts) && session.discounts.length > 0) return 1;
  return 0;
}

async function recordStripeMemoryPackPayment(mapping: {
  uid: string;
  packId: MemoryPackId;
  checkoutSessionID: string;
  paymentIntentID?: string;
  chargeID?: string;
}): Promise<void> {
  const now = Timestamp.now();
  const doc = { ...mapping, updatedAt: now, schemaVersion: 1 };
  const refs = [];
  if (mapping.chargeID) refs.push(db.doc(stripeMemoryPackPaymentDocPath("charge", mapping.chargeID)));
  if (mapping.paymentIntentID) {
    refs.push(db.doc(stripeMemoryPackPaymentDocPath("payment_intent", mapping.paymentIntentID)));
  }
  await Promise.all(refs.map((ref) => ref.set(doc, { merge: true })));
}

async function readStripeMemoryPackPayment(
  kind: "charge" | "payment_intent",
  externalID: string,
): Promise<{ uid: string; packId: MemoryPackId; checkoutSessionID: string } | undefined> {
  const snap = await db.doc(stripeMemoryPackPaymentDocPath(kind, externalID)).get();
  const data = snap.data();
  if (!data || typeof data.uid !== "string" || !isMemoryPackId(data.packId) || typeof data.checkoutSessionID !== "string") {
    return undefined;
  }
  return { uid: data.uid, packId: data.packId, checkoutSessionID: data.checkoutSessionID };
}

export async function applyStripeMemoryPackCheckoutSession(
  stripe: Stripe,
  session: Stripe.Checkout.Session,
  uid: string,
): Promise<boolean> {
  if (session.metadata?.kind !== "memory_pack") return false;
  if (session.payment_status !== "paid") return true;

  const rawPackId = session.metadata.packId;
  if (!isMemoryPackId(rawPackId)) {
    throw new HttpsError("failed-precondition", "Stripe memory pack checkout is missing packId.");
  }

  let lineItems = session.line_items;
  if (!lineItems?.data?.length) {
    const expanded = await stripeWithResilience("checkout.sessions.retrieve.memory_pack", () =>
      stripe.checkout.sessions.retrieve(session.id, { expand: ["line_items.data.price", "payment_intent.latest_charge"] }),
    );
    lineItems = expanded.line_items;
    session = expanded;
  }
  const { priceID, quantity } = stripeMemoryPackLineItem({ ...session, line_items: lineItems });
  if (quantity !== 1) {
    throw new HttpsError("failed-precondition", "Stripe memory pack checkout quantity must be 1.");
  }
  if (stripeMemoryPackDiscountMinor({ ...session, line_items: lineItems }) > 0) {
    throw new HttpsError("failed-precondition", "Stripe memory pack checkout cannot use a discount.");
  }
  const expectedPriceID = memoryPackRuntimeIds(rawPackId).stripePriceID;
  const catalogPackId = memoryPackFromStripePriceID(priceID ?? "");
  if (!priceID || catalogPackId !== rawPackId || priceID !== expectedPriceID) {
    throw new HttpsError("failed-precondition", "Stripe memory pack price does not match the catalog pack.");
  }
  const catalog = await loadMemoryPackCatalog();
  const pack = catalog.packs[rawPackId];
  const amountTotal = session.amount_total ?? 0;
  const minCharge = pack.minChargeMinor * quantity;
  if (amountTotal < minCharge) {
    throw new HttpsError("failed-precondition", "Stripe memory pack charge is below the anti-typo floor.");
  }

  const paymentIntent = session.payment_intent;
  const paymentIntentObj =
    paymentIntent && typeof paymentIntent === "object"
      ? paymentIntent
      : typeof paymentIntent === "string"
        ? await stripeWithResilience("payment_intents.retrieve.memory_pack", () =>
            stripe.paymentIntents.retrieve(paymentIntent, { expand: ["latest_charge"] }),
          )
        : undefined;
  const paymentIntentID = stripeObjectID(paymentIntentObj) ?? stripeObjectID(session.payment_intent);
  const chargeID = paymentIntentObj ? stripeObjectID(paymentIntentObj.latest_charge) : undefined;
  await recordStripeMemoryPackPayment({
    uid,
    packId: rawPackId,
    checkoutSessionID: session.id,
    paymentIntentID,
    chargeID,
  });
  const visionEligible = await hasActiveMemoryPackVisionEntitlement(uid);

  await grantMemoryPack({
    uid,
    source: "stripe",
    transactionId: session.id,
    packId: rawPackId,
    visionEligible,
    amountMinor: amountTotal,
    currency: session.currency ?? "usd",
  });
  return true;
}

export async function reconcileStripeMemoryPackCharge(
  stripe: Stripe,
  charge: Stripe.Charge,
  disputeStatus?: Stripe.Dispute.Status,
): Promise<boolean> {
  const paymentIntentID = stripeObjectID(charge.payment_intent);
  let mapping =
    (await readStripeMemoryPackPayment("charge", charge.id)) ??
    (paymentIntentID ? await readStripeMemoryPackPayment("payment_intent", paymentIntentID) : undefined);
  if (!mapping) {
    mapping = await lookupStripeMemoryPackMappingFromStripe(stripe, charge, paymentIntentID);
    if (!mapping) return false;
  }

  const originalAmountMinor = charge.amount;
  const refundedAmountMinor = charge.amount_refunded;
  const reversingDispute =
    disputeStatus === "needs_response" ||
    disputeStatus === "under_review" ||
    disputeStatus === "warning_needs_response" ||
    disputeStatus === "warning_under_review" ||
    disputeStatus === "lost";
  const restoringDispute =
    disputeStatus === "won" || disputeStatus === "prevented" || disputeStatus === "warning_closed";

  try {
    await reverseMemoryPackGrant({
      uid: mapping.uid,
      source: "stripe",
      transactionId: mapping.checkoutSessionID,
      refundedAmountMinor,
      originalAmountMinor,
      disputeStatus: reversingDispute ? "open" : restoringDispute ? "won" : undefined,
    });
  } catch (err) {
    if (err instanceof Error && err.message === "memory_pack_grant_missing") {
      throw err;
    }
    throw err;
  }
  return true;
}

async function lookupStripeMemoryPackMappingFromStripe(
  stripe: Stripe,
  charge: Stripe.Charge,
  paymentIntentID: string | undefined,
): Promise<{ uid: string; packId: MemoryPackId; checkoutSessionID: string } | undefined> {
  if (!paymentIntentID) return undefined;
  const paymentIntent = await stripeWithResilience("payment_intents.retrieve.memory_pack_refund", () =>
    stripe.paymentIntents.retrieve(paymentIntentID),
  );
  if (paymentIntent.metadata?.kind !== "memory_pack") return undefined;
  const sessions = await stripeWithResilience("checkout.sessions.list.memory_pack_refund", () =>
    stripe.checkout.sessions.list({ payment_intent: paymentIntentID, limit: 1 }),
  );
  const session = sessions.data[0];
  const uid = session?.metadata?.firebaseUID ?? paymentIntent.metadata.firebaseUID;
  const packId = session?.metadata?.packId ?? paymentIntent.metadata.packId;
  if (!uid || !isMemoryPackId(packId) || !session?.id) {
    throw new Error("memory_pack_grant_missing");
  }
  await recordStripeMemoryPackPayment({
    uid,
    packId,
    checkoutSessionID: session.id,
    paymentIntentID,
    chargeID: charge.id,
  });
  return { uid, packId, checkoutSessionID: session.id };
}

export function requireConfiguredStripeMemoryPackPrice(packId: MemoryPackId): string {
  const priceID = memoryPackRuntimeIds(packId).stripePriceID;
  if (!priceID) {
    throw new HttpsError("failed-precondition", `Stripe price for Memory Boost ${packId} is not configured.`);
  }
  return priceID;
}

export function stripeMemoryPackCheckoutMetadata(uid: string, packId: MemoryPackId): Record<string, string> {
  return {
    firebaseUID: uid,
    kind: "memory_pack",
    packId,
  };
}

export function stripeMemoryPackIdempotencyKey(uid: string, packId: MemoryPackId, attemptId?: string): string {
  const attempt = attemptId?.trim() || String(Math.floor(Date.now() / (10 * 60 * 1000)));
  return requiredIdentifier(`memory_pack_checkout_${uid}_${packId}_${attempt}`, "idempotencyKey");
}

export { DEFAULT_MEMORY_PACKS };
