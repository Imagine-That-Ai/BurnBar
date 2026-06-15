/**
 * @fileoverview Stripe billing + Google Play subscription helpers: secrets, customer
 * provisioning, checkout/subscription application, and entitlement product resolution.
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import Stripe from "stripe";

import { getConfig } from "../../config.js";
import { stripeWithResilience } from "../../resilienceHelpers.js";
import { jsonObject, recordOrUndefined } from "../../guards.js";
import { auth, db } from "../../adminRuntime.js";
import { type CloudProTopUpKind } from "../../cloudProAllowanceCore.js";
import {
  BURNBAR_PRO_ENTITLEMENT_ID,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  creditCloudProTopUp,
  writeBurnBarProEntitlement,
} from "./entitlements.js";

const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");
const STRIPE_WEBHOOK_SECRET = defineSecret("STRIPE_WEBHOOK_SECRET");
export const STRIPE_API_SECRETS = [STRIPE_SECRET_KEY];
export const STRIPE_WEBHOOK_SECRETS = [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET];
export const GOOGLE_PLAY_ACTIVE_STATES = new Set<string>([
  "SUBSCRIPTION_STATE_ACTIVE",
  "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
]);
const STRIPE_ACTIVE_STATES = new Set<string>(["active", "trialing", "past_due"]);

export function requireConfiguredStripe(): Stripe {
  const cfg = getConfig();
  const secretKey = STRIPE_SECRET_KEY.value() || cfg.stripeSecretKey;
  if (!secretKey || !(cfg.stripeBurnBarCloudMonthlyPriceID || cfg.stripeBurnBarProPriceID)) {
    throw new HttpsError("failed-precondition", "Stripe BurnBar Pro checkout is not configured.");
  }
  return new Stripe(secretKey);
}

export function requireConfiguredStripeWebhookSecret(): string {
  const secret = STRIPE_WEBHOOK_SECRET.value() || getConfig().stripeWebhookSecret;
  if (!secret) {
    throw new HttpsError("failed-precondition", "Stripe BurnBar Pro webhook is not configured.");
  }
  return secret;
}

export async function getOrCreateStripeCustomer(uid: string, stripe: Stripe): Promise<string> {
  const ref = db.doc(`users/${uid}/billing/stripe`);
  const existing = await ref.get();
  const existingID = existing.get("customerID");
  if (typeof existingID === "string" && existingID.startsWith("cus_")) {
    return existingID;
  }

  const user = await auth.getUser(uid).catch(() => undefined);
  const customer = await stripeWithResilience("customers.create", () =>
    stripe.customers.create({
      email: user?.email ?? undefined,
      name: user?.displayName ?? undefined,
      metadata: { firebaseUID: uid },
    }),
  );
  await ref.set(
    {
      uid,
      customerID: customer.id,
      createdAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    },
    { merge: true },
  );
  await db.doc(`stripe_customers/${customer.id}`).set(
    {
      uid,
      customerID: customer.id,
      createdAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    },
    { merge: true },
  );
  return customer.id;
}

export function googlePlayLineItemForProduct(
  purchase: Record<string, unknown>,
  productID: string,
): Record<string, unknown> | undefined {
  const lineItems = Array.isArray(purchase.lineItems)
    ? purchase.lineItems.filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
    : [];
  return lineItems.find((item) => item.productId === productID);
}

export function googlePlayExpiryMillis(lineItem: Record<string, unknown> | undefined): number {
  const expiryTime = lineItem?.expiryTime;
  if (typeof expiryTime === "string") {
    const parsed = Date.parse(expiryTime);
    if (Number.isFinite(parsed)) return parsed;
  }
  throw new HttpsError("failed-precondition", "Google Play did not return an expiry for this subscription.");
}

export async function applyStripeCheckoutSession(
  stripe: Stripe,
  session: Stripe.Checkout.Session,
  eventContext: { eventID?: string; eventCreatedMillis?: number } = {},
): Promise<void> {
  const uid = session.metadata?.firebaseUID ?? session.client_reference_id ?? undefined;
  if (!uid) return;
  if (session.metadata?.topUpKind) {
    if (session.payment_status !== "paid") return;
    await creditCloudProTopUp({
      uid,
      kind: stripeTopUpKind(session.metadata.topUpKind),
      source: "stripe_checkout",
      externalPaymentID: session.id,
    });
    return;
  }
  let subscription: Stripe.Subscription | undefined;
  const subscriptionId = session.subscription;
  if (typeof subscriptionId === "string") {
    subscription = await stripeWithResilience("subscriptions.retrieve", () =>
      stripe.subscriptions.retrieve(subscriptionId),
    );
  } else if (session.subscription && typeof session.subscription === "object") {
    subscription = session.subscription;
  }
  if (subscription) {
    // Forward the checkout event's watermark (LB-5): the subscription state
    // written here was re-fetched fresh from Stripe (or embedded in the
    // checkout event itself), so it is at least as new as event.created —
    // stamping that watermark is safe and keeps later stale subscription
    // events rejectable. This path used to omit the context, which erased
    // the watermark on every checkout.
    await applyStripeSubscription(stripe, subscription, uid, eventContext);
  }
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

export async function applyStripeSubscription(
  stripe: Stripe,
  subscription: Stripe.Subscription,
  uidOverride?: string,
  eventContext: { eventID?: string; eventCreatedMillis?: number } = {},
): Promise<void> {
  const uid = uidOverride ?? (await uidForStripeSubscription(subscription));
  if (!uid) return;

  const customerID = stripeCustomerID(subscription.customer);
  const expiresAtMillis = stripeSubscriptionPeriodEndMillis(subscription);
  const status = String(subscription.status ?? "unknown");
  const active = STRIPE_ACTIVE_STATES.has(status) && expiresAtMillis > Date.now();
  const entitlementID =
    subscription.metadata?.entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID
      ? BURNBAR_PRO_MAX_ENTITLEMENT_ID
      : BURNBAR_PRO_ENTITLEMENT_ID;
  const productID = stripeSubscriptionProductID(subscription, entitlementID);

  await writeBurnBarProEntitlement({
    uid,
    productID,
    expiresAtMillis,
    source: "stripe_webhook_verified",
    platform: "stripe",
    entitlementID,
    externalSubscriptionID: subscription.id,
    externalCustomerID: customerID,
    rawStatus: status,
    environment: "Production",
    activeOverride: active,
    sourceEventID: eventContext.eventID,
    sourceEventCreatedMillis: eventContext.eventCreatedMillis,
  });

  if (customerID) {
    await db.doc(`users/${uid}/billing/stripe`).set(
      {
        uid,
        customerID,
        subscriptionID: subscription.id,
        subscriptionStatus: status,
        currentPeriodEnd: new Date(expiresAtMillis).toISOString(),
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      },
      { merge: true },
    );
    await db.doc(`stripe_customers/${customerID}`).set(
      {
        uid,
        customerID,
        subscriptionID: subscription.id,
        subscriptionStatus: status,
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      },
      { merge: true },
    );
  }
}

function stripeSubscriptionProductID(subscription: Stripe.Subscription, entitlementID: string): string {
  const cfg = getConfig();
  const priceIDs = new Set(
    subscription.items?.data
      ?.map((item) => item.price?.id)
      .filter((priceID): priceID is string => typeof priceID === "string") || [],
  );
  if (cfg.stripeBurnBarCloudAnnualPriceID && priceIDs.has(cfg.stripeBurnBarCloudAnnualPriceID)) {
    return cfg.burnBarProAnnualProductID;
  }
  if (cfg.stripeBurnBarCloudProMonthlyPriceID && priceIDs.has(cfg.stripeBurnBarCloudProMonthlyPriceID)) {
    return cfg.burnBarProMaxProductID;
  }
  if (cfg.stripeBurnBarCloudProAnnualPriceID && priceIDs.has(cfg.stripeBurnBarCloudProAnnualPriceID)) {
    return cfg.burnBarProMaxAnnualProductID;
  }
  return entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID ? cfg.burnBarProMaxProductID : cfg.burnBarProProductID;
}

async function uidForStripeSubscription(subscription: Stripe.Subscription): Promise<string | undefined> {
  const metadataUID = subscription.metadata?.firebaseUID;
  if (metadataUID) return metadataUID;
  const customerID = stripeCustomerID(subscription.customer);
  if (!customerID) return undefined;
  const snap = await db.doc(`stripe_customers/${customerID}`).get();
  const uid = snap.get("uid");
  return typeof uid === "string" ? uid : undefined;
}

function stripeCustomerID(customer: unknown): string | undefined {
  if (typeof customer === "string") return customer;
  if (customer && typeof customer === "object" && "id" in customer && typeof customer.id === "string") {
    return customer.id;
  }
  return undefined;
}

function stripeSubscriptionPeriodEndMillis(subscription: Stripe.Subscription): number {
  const raw = jsonObject(subscription);
  const direct = raw.current_period_end;
  if (typeof direct === "number") return direct * 1000;
  const items = recordOrUndefined(raw.items);
  const firstItem = Array.isArray(items?.data) ? recordOrUndefined(items.data[0]) : undefined;
  const itemEnd = firstItem?.current_period_end;
  if (typeof itemEnd === "number") return itemEnd * 1000;
  return Date.now() - 1;
}
