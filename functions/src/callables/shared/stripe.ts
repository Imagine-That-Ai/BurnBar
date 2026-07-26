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
import { logWarn } from "../../logging.js";
import {
  BURNBAR_PRO_ENTITLEMENT_ID,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
  writeBurnBarProEntitlement,
} from "./entitlements.js";
import { applyStripeTopUpCheckoutSession, reconcileStripeTopUpCharge } from "./stripeTopUps.js";
import { sha256Hex } from "./validators.js";

const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");
const STRIPE_WEBHOOK_SECRET = defineSecret("STRIPE_WEBHOOK_SECRET");
export const STRIPE_API_SECRETS = [STRIPE_SECRET_KEY];
export const STRIPE_WEBHOOK_SECRETS = [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET];
const STRIPE_ACTIVE_STATES = new Set<string>(["active", "trialing", "past_due"]);
const STRIPE_BLOCKING_SUBSCRIPTION_STATES = new Set<Stripe.Subscription.Status>([
  "incomplete",
  "trialing",
  "active",
  "past_due",
  "unpaid",
  "paused",
]);

interface StripeSubscriptionCheckoutSelection {
  tier: "cloud" | "cloud_pro" | "ultra";
  cadence: "monthly" | "annual";
}

interface StripeEventContext {
  eventID?: string;
  eventCreatedMillis?: number;
}

export function requireConfiguredStripe(): Stripe {
  const cfg = getConfig();
  const secretKey = STRIPE_SECRET_KEY.value() || cfg.stripeSecretKey;
  const hasSubscriptionPrice = Boolean(
    cfg.stripeBurnBarCloudMonthlyPriceID ||
    cfg.stripeBurnBarProPriceID ||
    cfg.stripeBurnBarCloudAnnualPriceID ||
    cfg.stripeBurnBarCloudProMonthlyPriceID ||
    cfg.stripeBurnBarCloudProAnnualPriceID ||
    cfg.stripeBurnBarUltraMonthlyPriceID ||
    cfg.stripeBurnBarUltraAnnualPriceID,
  );
  if (!secretKey || !hasSubscriptionPrice) {
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

function stripeSearchLiteral(value: string): string {
  return value.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
}

async function persistStripeCustomerMapping(
  uid: string,
  customer: Pick<Stripe.Customer, "id" | "created">,
): Promise<void> {
  const now = Timestamp.now();
  const createdAt = Timestamp.fromMillis(customer.created * 1000);
  await Promise.all([
    db.doc(`users/${uid}/billing/stripe`).set(
      {
        uid,
        customerID: customer.id,
        createdAt,
        updatedAt: now,
        schemaVersion: 1,
      },
      { merge: true },
    ),
    db.doc(`stripe_customers/${customer.id}`).set(
      {
        uid,
        customerID: customer.id,
        createdAt,
        updatedAt: now,
        schemaVersion: 1,
      },
      { merge: true },
    ),
  ]);
}

export async function getOrCreateStripeCustomer(uid: string, stripe: Stripe): Promise<string> {
  const ref = db.doc(`users/${uid}/billing/stripe`);
  const existing = await ref.get();
  const existingID = existing.get("customerID");
  if (typeof existingID === "string" && existingID.startsWith("cus_")) {
    return existingID;
  }

  try {
    const matches = await stripeWithResilience("customers.search.firebase_uid", () =>
      stripe.customers.search({
        query: `metadata['firebaseUID']:'${stripeSearchLiteral(uid)}'`,
        limit: 100,
      }),
    );
    const recovered = matches.data
      .filter((customer) => customer.metadata.firebaseUID === uid)
      .sort((lhs, rhs) => lhs.created - rhs.created || lhs.id.localeCompare(rhs.id))
      .at(0);
    if (recovered) {
      await persistStripeCustomerMapping(uid, recovered);
      return recovered.id;
    }
  } catch (error) {
    // Search is a recovery path. A stable create idempotency key below still
    // converges concurrent first-checkout calls if search is temporarily
    // unavailable or has not indexed a just-created customer yet.
    logWarn({
      event: "stripe_customer_metadata_search_failed",
      error: error instanceof Error ? error.name : "unknown",
    });
  }

  const user = await auth.getUser(uid).catch(() => undefined);
  const customer = await stripeWithResilience("customers.create", () =>
    stripe.customers.create(
      {
        email: user?.email ?? undefined,
        name: user?.displayName ?? undefined,
        metadata: {
          firebaseUID: uid,
          firebaseUIDHash: sha256Hex(uid),
        },
      },
      {
        idempotencyKey: `burnbar_customer_v1:${sha256Hex(uid)}`,
      },
    ),
  );
  await persistStripeCustomerMapping(uid, customer);
  return customer.id;
}

/**
 * Rejects a second Checkout subscription when Stripe already has a
 * non-terminal subscription for the customer. Plan changes and cancellations
 * belong in Billing Portal so one Firebase user cannot accumulate parallel
 * paid entitlements accidentally.
 */
export async function assertStripeCustomerCanStartSubscriptionCheckout(
  stripe: Stripe,
  customerID: string,
): Promise<void> {
  let startingAfter: string | undefined;
  for (;;) {
    const page = await stripeWithResilience("subscriptions.list.checkout_guard", () =>
      stripe.subscriptions.list({
        customer: customerID,
        limit: 100,
        status: "all",
        ...(startingAfter ? { starting_after: startingAfter } : {}),
      }),
    );
    const blocking = page.data.find((subscription) => STRIPE_BLOCKING_SUBSCRIPTION_STATES.has(subscription.status));
    if (blocking) {
      throw new HttpsError(
        "already-exists",
        "This BurnBar account already has a Stripe subscription. Use Manage billing to change or resume it.",
        {
          subscriptionID: blocking.id,
          subscriptionStatus: blocking.status,
          action: "open_billing_portal",
        },
      );
    }
    const last = page.data.at(-1);
    if (!page.has_more || !last) return;
    startingAfter = last.id;
  }
}

/** Reuses an open matching Checkout Session so retries and double-clicks converge. */
export async function findReusableStripeSubscriptionCheckoutSession(
  stripe: Stripe,
  customerID: string,
  selection: StripeSubscriptionCheckoutSelection,
  redirectFingerprint: string,
): Promise<Stripe.Checkout.Session | undefined> {
  let startingAfter: string | undefined;
  for (;;) {
    const page = await stripeWithResilience("checkout.sessions.list.subscription_guard", () =>
      stripe.checkout.sessions.list({
        customer: customerID,
        limit: 100,
        status: "open",
        ...(startingAfter ? { starting_after: startingAfter } : {}),
      }),
    );
    const reusable = page.data.find(
      (session) =>
        session.mode === "subscription" &&
        typeof session.url === "string" &&
        session.metadata?.tier === selection.tier &&
        session.metadata?.cadence === selection.cadence &&
        session.metadata?.redirectFingerprint === redirectFingerprint,
    );
    if (reusable) return reusable;
    const last = page.data.at(-1);
    if (!page.has_more || !last) return undefined;
    startingAfter = last.id;
  }
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
  eventContext: StripeEventContext = {},
): Promise<void> {
  const uid = session.metadata?.firebaseUID ?? session.client_reference_id ?? undefined;
  if (!uid) return;
  if (await applyStripeTopUpCheckoutSession(stripe, session, uid)) return;

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

export async function applyStripeSubscription(
  stripe: Stripe,
  subscription: Stripe.Subscription,
  uidOverride?: string,
  eventContext: StripeEventContext = {},
): Promise<void> {
  const uid = uidOverride ?? (await uidForStripeSubscription(subscription));
  if (!uid) return;

  const customerID = stripeCustomerID(subscription.customer);
  const expiresAtMillis = stripeSubscriptionPeriodEndMillis(subscription);
  const status = String(subscription.status ?? "unknown");
  const active = STRIPE_ACTIVE_STATES.has(status) && expiresAtMillis > Date.now();
  const metadataEntitlementID = subscription.metadata?.entitlementID;
  const entitlementID =
    metadataEntitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID
      ? BURNBAR_ULTRA_ENTITLEMENT_ID
      : metadataEntitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID
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

/**
 * Re-fetches and applies one subscription so non-subscription webhook events
 * never write a stale point-in-time snapshot.
 */
export async function reconcileStripeSubscription(
  stripe: Stripe,
  subscriptionID: string,
  eventContext: StripeEventContext = {},
): Promise<void> {
  const subscription = await stripeWithResilience("subscriptions.retrieve.webhook_reconcile", () =>
    stripe.subscriptions.retrieve(subscriptionID),
  );
  await applyStripeSubscription(stripe, subscription, undefined, eventContext);
}

/**
 * Reconciles every subscription currently attached to a Stripe customer.
 *
 * Refund and dispute objects do not expose an invoice in Stripe API 2025-09-30;
 * the customer is the durable bridge back to all affected subscriptions. The
 * explicit pagination prevents a large customer history from silently
 * truncating reconciliation at Stripe's first page.
 */
export async function reconcileStripeCustomerSubscriptions(
  stripe: Stripe,
  customerID: string,
  eventContext: StripeEventContext = {},
): Promise<number> {
  let startingAfter: string | undefined;
  let reconciled = 0;

  for (;;) {
    const page = await stripeWithResilience("subscriptions.list.webhook_reconcile", () =>
      stripe.subscriptions.list({
        customer: customerID,
        limit: 100,
        status: "all",
        ...(startingAfter ? { starting_after: startingAfter } : {}),
      }),
    );
    for (const subscription of page.data) {
      await applyStripeSubscription(stripe, subscription, undefined, eventContext);
      reconciled += 1;
    }
    const last = page.data.at(-1);
    if (!page.has_more || !last) break;
    startingAfter = last.id;
  }

  if (reconciled === 0) {
    await deactivateStripeCustomerEntitlements(customerID, undefined, eventContext);
  }
  return reconciled;
}

/** Reconciles an invoice's exact subscription, falling back to its customer. */
export async function reconcileStripeInvoice(
  stripe: Stripe,
  invoiceOrID: Stripe.Invoice | string,
  eventContext: StripeEventContext = {},
): Promise<void> {
  const invoice =
    typeof invoiceOrID === "string"
      ? await stripeWithResilience("invoices.retrieve.webhook_reconcile", () => stripe.invoices.retrieve(invoiceOrID))
      : invoiceOrID;
  const subscriptionID = stripeInvoiceSubscriptionID(invoice);
  if (subscriptionID) {
    await reconcileStripeSubscription(stripe, subscriptionID, eventContext);
    return;
  }
  const customerID = stripeCustomerID(invoice.customer);
  if (customerID) {
    await reconcileStripeCustomerSubscriptions(stripe, customerID, eventContext);
  }
}

/** Reconciles all subscriptions associated with a refunded charge. */
export async function reconcileStripeCharge(
  stripe: Stripe,
  charge: Stripe.Charge,
  eventContext: StripeEventContext = {},
  disputeStatus?: Stripe.Dispute.Status,
): Promise<void> {
  const currentCharge = await stripeWithResilience("charges.retrieve.webhook_reconcile", () =>
    stripe.charges.retrieve(charge.id),
  );
  await reconcileStripeTopUpCharge(stripe, currentCharge, eventContext, disputeStatus);

  let customerID = stripeCustomerID(currentCharge.customer);
  if (!customerID) {
    const paymentIntent = currentCharge.payment_intent;
    if (typeof paymentIntent === "string") {
      const current = await stripeWithResilience("payment_intents.retrieve.webhook_reconcile", () =>
        stripe.paymentIntents.retrieve(paymentIntent),
      );
      customerID = stripeCustomerID(current.customer);
    } else if (paymentIntent && typeof paymentIntent === "object") {
      customerID = stripeCustomerID(paymentIntent.customer);
    }
  }
  if (customerID) {
    await reconcileStripeCustomerSubscriptions(stripe, customerID, eventContext);
  }
}

/** Resolves a dispute through its charge, then reconciles the customer. */
export async function reconcileStripeDispute(
  stripe: Stripe,
  dispute: Stripe.Dispute,
  eventContext: StripeEventContext = {},
): Promise<void> {
  const currentDispute = await stripeWithResilience("disputes.retrieve.webhook_reconcile", () =>
    stripe.disputes.retrieve(dispute.id),
  );
  const charge =
    typeof currentDispute.charge === "string"
      ? await stripeWithResilience("charges.retrieve.dispute_reconcile", () =>
          stripe.charges.retrieve(currentDispute.charge as string),
        )
      : currentDispute.charge;
  await reconcileStripeCharge(stripe, charge, eventContext, currentDispute.status);
}

/** Re-fetches a refund's charge so failed/canceled refund updates can restore units. */
export async function reconcileStripeRefund(
  stripe: Stripe,
  refund: Stripe.Refund,
  eventContext: StripeEventContext = {},
): Promise<void> {
  const currentRefund = await stripeWithResilience("refunds.retrieve.webhook_reconcile", () =>
    stripe.refunds.retrieve(refund.id),
  );
  let charge = currentRefund.charge;
  if (!charge && currentRefund.payment_intent) {
    const paymentIntent =
      typeof currentRefund.payment_intent === "string"
        ? await stripeWithResilience("payment_intents.retrieve.refund_reconcile", () =>
            stripe.paymentIntents.retrieve(currentRefund.payment_intent as string),
          )
        : currentRefund.payment_intent;
    charge = paymentIntent.latest_charge;
  }
  if (!charge) return;
  const resolvedCharge =
    typeof charge === "string"
      ? await stripeWithResilience("charges.retrieve.refund_reconcile", () => stripe.charges.retrieve(charge))
      : charge;
  await reconcileStripeCharge(stripe, resolvedCharge, eventContext);
}

/** Resolves a credit note through its invoice, then reconciles the subscription. */
export async function reconcileStripeCreditNote(
  stripe: Stripe,
  creditNote: Stripe.CreditNote,
  eventContext: StripeEventContext = {},
): Promise<void> {
  await reconcileStripeInvoice(stripe, creditNote.invoice, eventContext);
}

/**
 * Customer deletion is terminal and can make Stripe retrieval impossible.
 * Deactivate only locally stored Stripe-backed entitlements for that customer;
 * App Store and Google Play entitlements on the same Firebase user are left
 * untouched.
 */
export async function deactivateStripeCustomerEntitlements(
  customerID: string,
  uidOverride?: string,
  eventContext: StripeEventContext = {},
): Promise<void> {
  const customerRef = db.doc(`stripe_customers/${customerID}`);
  const customerSnap = await customerRef.get();
  const mappedUID = customerSnap.get("uid");
  const uid = uidOverride ?? (typeof mappedUID === "string" ? mappedUID : undefined);

  if (uid) {
    const entitlementIDs = [
      BURNBAR_PRO_ENTITLEMENT_ID,
      BURNBAR_PRO_MAX_ENTITLEMENT_ID,
      BURNBAR_ULTRA_ENTITLEMENT_ID,
    ] as const;
    const entitlementSnaps = await Promise.all(
      entitlementIDs.map((entitlementID) => db.doc(`users/${uid}/entitlements/${entitlementID}`).get()),
    );
    for (let index = 0; index < entitlementIDs.length; index += 1) {
      const entitlementID = entitlementIDs[index];
      const existing = entitlementSnaps[index].data();
      if (!existing || !isStripeBackedEntitlementForCustomer(existing, customerID)) continue;
      await writeBurnBarProEntitlement({
        uid,
        productID: stripeEntitlementProductID(existing, entitlementID),
        expiresAtMillis: stripeEntitlementExpiryMillis(existing),
        source: typeof existing.source === "string" ? existing.source : "stripe_webhook_verified",
        platform: "stripe",
        entitlementID,
        externalSubscriptionID:
          typeof existing.externalSubscriptionID === "string" ? existing.externalSubscriptionID : undefined,
        externalCustomerID: customerID,
        rawStatus: "customer_deleted",
        environment: "Production",
        activeOverride: false,
        sourceEventID: eventContext.eventID,
        sourceEventCreatedMillis: eventContext.eventCreatedMillis,
      });
    }

    await db.doc(`users/${uid}/billing/stripe`).set(
      {
        uid,
        customerID,
        subscriptionStatus: "customer_deleted",
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      },
      { merge: true },
    );
  }

  await customerRef.set(
    {
      ...(uid ? { uid } : {}),
      customerID,
      subscriptionStatus: "customer_deleted",
      sourceEventID: eventContext.eventID,
      sourceEventCreatedMillis: eventContext.eventCreatedMillis,
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    },
    { merge: true },
  );
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
  if (cfg.stripeBurnBarUltraMonthlyPriceID && priceIDs.has(cfg.stripeBurnBarUltraMonthlyPriceID)) {
    return cfg.burnBarUltraProductID;
  }
  if (cfg.stripeBurnBarUltraAnnualPriceID && priceIDs.has(cfg.stripeBurnBarUltraAnnualPriceID)) {
    return cfg.burnBarUltraAnnualProductID;
  }
  if (entitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID) return cfg.burnBarUltraProductID;
  return entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID ? cfg.burnBarProMaxProductID : cfg.burnBarProProductID;
}

function stripeInvoiceSubscriptionID(invoice: Stripe.Invoice): string | undefined {
  const parentSubscription = invoice.parent?.subscription_details?.subscription;
  const parentID = stripeObjectID(parentSubscription);
  if (parentID) return parentID;

  // Compatibility for invoices created under older Stripe API versions.
  return stripeObjectID(jsonObject(invoice).subscription);
}

function stripeObjectID(value: unknown): string | undefined {
  if (typeof value === "string" && value.length > 0) return value;
  if (value && typeof value === "object" && "id" in value && typeof value.id === "string") {
    return value.id;
  }
  return undefined;
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
  return stripeObjectID(customer);
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

function isStripeBackedEntitlementForCustomer(entitlement: Record<string, unknown>, customerID: string): boolean {
  const platformIsStripe = entitlement.platform === "stripe";
  const sourceIsStripe = typeof entitlement.source === "string" && entitlement.source.startsWith("stripe");
  if (!platformIsStripe && !sourceIsStripe) return false;
  const externalCustomerID = entitlement.externalCustomerID;
  return typeof externalCustomerID !== "string" || externalCustomerID === customerID;
}

function stripeEntitlementProductID(entitlement: Record<string, unknown>, entitlementID: string): string {
  if (typeof entitlement.productID === "string" && entitlement.productID.length > 0) {
    return entitlement.productID;
  }
  const cfg = getConfig();
  if (entitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID) return cfg.burnBarUltraProductID;
  if (entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID) return cfg.burnBarProMaxProductID;
  return cfg.burnBarProProductID;
}

function stripeEntitlementExpiryMillis(entitlement: Record<string, unknown>): number {
  const expireAt = entitlement.expireAt;
  if (expireAt && typeof expireAt === "object" && "toMillis" in expireAt && typeof expireAt.toMillis === "function") {
    const millis = expireAt.toMillis();
    if (Number.isFinite(millis)) return millis;
  }
  if (typeof entitlement.expiresAt === "string") {
    const millis = Date.parse(entitlement.expiresAt);
    if (Number.isFinite(millis)) return millis;
  }
  return Date.now() - 1;
}
