/**
 * @fileoverview Stripe and Google Play BurnBar Pro billing callables
 */

import { HttpsError, onCall, onRequest, type CallableRequest } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { logError, wrapCallableHandler } from "../logging.js";
import { externalApiWithResilience, stripeWithResilience } from "../resilienceHelpers.js";
import {
  BURNBAR_PRO_ENTITLEMENT_ID,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
  STRIPE_API_SECRETS,
  STRIPE_WEBHOOK_SECRETS,
  GOOGLE_PLAY_ACTIVE_STATES,
  nowISO,
  boundedTrimmedString,
  sha256Hex,
  requireConfiguredStripe,
  requireConfiguredStripeWebhookSecret,
  boundedHttpsURL,
  assertActiveBurnBarCloudProEntitlement,
  getOrCreateStripeCustomer,
  googlePlayLineItemForProduct,
  googlePlayExpiryMillis,
  applyStripeCheckoutSession,
  applyStripeSubscription,
  creditCloudProTopUp,
  writeBurnBarProEntitlement,
} from "./shared.js";
import Stripe from "stripe";
import { isStripeCheckoutSession, isStripeSubscription, jsonObject, stripUndefinedObject } from "../guards.js";
import type { CloudProTopUpKind } from "../cloudProAllowanceCore.js";
import { googlePlayBillingRecordPath } from "./googlePlayBillingPaths.js";
import { claimGooglePlayPurchaseToken } from "./googlePlayTokenClaims.js";
import { FUNCTIONS_REGION, HOT_PATH_OPTIONS } from "../runtimeOptions.js";

// ---------------------------------------------------------------------------
// Callable / HTTP: BurnBar Pro billing bridges
// ---------------------------------------------------------------------------

type StripeCheckoutTier = "cloud" | "cloud_pro";
type StripeCheckoutCadence = "monthly" | "annual";
type StripeTopUpKind = "agent_control_actions_100" | "floo_relay_50gb";
type StripeWebhookReservation = "reserved" | "processed" | "processing";

const STRIPE_WEBHOOK_EVENT_LEASE_MS = 10 * 60 * 1000;

function optionalChoice<T extends string>(raw: unknown, allowed: readonly T[], fieldName: string): T | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  if (typeof raw !== "string" || !allowed.includes(raw as T)) {
    throw new HttpsError("invalid-argument", `${fieldName} is not supported.`);
  }
  return raw as T;
}

function requireConfiguredPriceID(priceID: string, label: string): string {
  if (!priceID) throw new HttpsError("failed-precondition", `${label} Stripe price is not configured.`);
  return priceID;
}

function subscriptionCheckoutSelection(data: { tier?: unknown; cadence?: unknown }): {
  priceID: string;
  entitlementID: string;
  tier: StripeCheckoutTier;
  cadence: StripeCheckoutCadence;
} {
  const cfg = getConfig();
  const tier = optionalChoice(data.tier, ["cloud", "cloud_pro"] as const, "tier") ?? "cloud";
  const cadence = optionalChoice(data.cadence, ["monthly", "annual"] as const, "cadence") ?? "monthly";
  if (tier === "cloud_pro") {
    const priceID =
      cadence === "annual" ? cfg.stripeBurnBarCloudProAnnualPriceID : cfg.stripeBurnBarCloudProMonthlyPriceID;
    return {
      priceID: requireConfiguredPriceID(priceID, `BurnBar Cloud Pro ${cadence}`),
      entitlementID: BURNBAR_PRO_MAX_ENTITLEMENT_ID,
      tier,
      cadence,
    };
  }
  const priceID =
    cadence === "annual"
      ? cfg.stripeBurnBarCloudAnnualPriceID
      : cfg.stripeBurnBarCloudMonthlyPriceID || cfg.stripeBurnBarProPriceID;
  return {
    priceID: requireConfiguredPriceID(priceID, `BurnBar Cloud ${cadence}`),
    entitlementID: BURNBAR_PRO_ENTITLEMENT_ID,
    tier,
    cadence,
  };
}

function topUpCheckoutSelection(kind: StripeTopUpKind): { priceID: string; kind: StripeTopUpKind } {
  const cfg = getConfig();
  switch (kind) {
    case "agent_control_actions_100":
      return {
        kind,
        priceID: requireConfiguredPriceID(cfg.stripeAgentControl100ActionsPriceID, "Agent Control 100 hosted actions"),
      };
    case "floo_relay_50gb":
      return {
        kind,
        priceID: requireConfiguredPriceID(cfg.stripeFlooRelay50GBPriceID, "Floo relay 50 GB"),
      };
  }
}

function googlePlaySubscriptionEntitlement(productID: string): { entitlementID: string; canonicalProductID: string } {
  const cfg = getConfig();
  const cloudProductIDs = new Set([
    cfg.googlePlaySubscriptionProductID,
    cfg.googlePlayCloudMonthlyProductID,
    cfg.googlePlayCloudAnnualProductID,
    cfg.burnBarProProductID,
    cfg.burnBarProAnnualProductID,
  ]);
  const cloudProProductIDs = new Set([
    cfg.googlePlayCloudProMonthlyProductID,
    cfg.googlePlayCloudProAnnualProductID,
    cfg.burnBarProMaxProductID,
    cfg.burnBarProMaxAnnualProductID,
  ]);
  const ultraProductIDs = new Set([
    cfg.googlePlayUltraMonthlyProductID,
    cfg.googlePlayUltraAnnualProductID,
    cfg.burnBarUltraProductID,
    cfg.burnBarUltraAnnualProductID,
  ]);
  if (cloudProductIDs.has(productID)) {
    return { entitlementID: BURNBAR_PRO_ENTITLEMENT_ID, canonicalProductID: productID };
  }
  if (cloudProProductIDs.has(productID)) {
    return { entitlementID: BURNBAR_PRO_MAX_ENTITLEMENT_ID, canonicalProductID: productID };
  }
  if (ultraProductIDs.has(productID)) {
    return { entitlementID: BURNBAR_ULTRA_ENTITLEMENT_ID, canonicalProductID: productID };
  }
  throw new HttpsError("invalid-argument", "Unsupported Google Play subscription product.");
}

function stripeWebhookEventRef(eventID: string) {
  return db.doc(`stripe_webhook_events/${eventID.replaceAll("/", "_")}`);
}

async function reserveStripeWebhookEvent(event: Stripe.Event): Promise<StripeWebhookReservation> {
  const ref = stripeWebhookEventRef(event.id);
  const nowMillis = Date.now();
  return db.runTransaction(async (transaction) => {
    const existing = await transaction.get(ref);
    if (existing.exists) {
      const status = existing.get("status");
      if (status === "processed") return "processed";
      const leaseExpiresAt = existing.get("leaseExpiresAt");
      const leaseExpiresAtMillis =
        leaseExpiresAt instanceof Timestamp
          ? leaseExpiresAt.toMillis()
          : typeof leaseExpiresAt?.toMillis === "function"
            ? leaseExpiresAt.toMillis()
            : 0;
      if (status === "processing" && leaseExpiresAtMillis > nowMillis) return "processing";
    }

    transaction.set(
      ref,
      {
        eventID: event.id,
        type: event.type,
        stripeCreatedAt: new Date(event.created * 1000).toISOString(),
        stripeCreatedMillis: event.created * 1000,
        status: "processing",
        processingStartedAt: Timestamp.fromMillis(nowMillis),
        leaseExpiresAt: Timestamp.fromMillis(nowMillis + STRIPE_WEBHOOK_EVENT_LEASE_MS),
        updatedAt: Timestamp.fromMillis(nowMillis),
        schemaVersion: 1,
      },
      { merge: true },
    );
    return "reserved";
  });
}

async function markStripeWebhookEventProcessed(event: Stripe.Event): Promise<void> {
  await stripeWebhookEventRef(event.id).set(
    {
      status: "processed",
      processedAt: Timestamp.now(),
      leaseExpiresAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    },
    { merge: true },
  );
}

async function markStripeWebhookEventFailed(event: Stripe.Event, error: unknown): Promise<void> {
  await stripeWebhookEventRef(event.id).set(
    stripUndefinedObject({
      status: "failed",
      failedAt: Timestamp.now(),
      leaseExpiresAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      error: error instanceof Error ? error.message : String(error),
      schemaVersion: 1,
    }),
    { merge: true },
  );
}

function googlePlayTopUpKind(productID: string): CloudProTopUpKind {
  const cfg = getConfig();
  if (
    productID === cfg.googlePlayAgentControl100ActionsProductID ||
    productID === cfg.agentControl100ActionsProductID
  ) {
    return "agent_control_actions_100";
  }
  if (productID === cfg.googlePlayFlooRelay50GBProductID || productID === cfg.flooRelay50GBProductID) {
    return "floo_relay_50gb";
  }
  throw new HttpsError("invalid-argument", "Unsupported Google Play top-up product.");
}

export const createStripeBurnBarProCheckoutSession = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: STRIPE_API_SECRETS,
  },
  wrapCallableHandler(
    "createStripeBurnBarProCheckoutSession",
    async (
      request: CallableRequest<{
        successUrl?: unknown;
        cancelUrl?: unknown;
        tier?: unknown;
        cadence?: unknown;
        topUpKind?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before starting checkout.");
      enforceAuthAndAppCheck(request, uid);

      const stripe = requireConfiguredStripe();
      const successUrl = boundedHttpsURL(request.data.successUrl, "successUrl");
      const cancelUrl = boundedHttpsURL(request.data.cancelUrl, "cancelUrl");
      const customerID = await getOrCreateStripeCustomer(uid, stripe);
      const topUpKind = optionalChoice(
        request.data.topUpKind,
        ["agent_control_actions_100", "floo_relay_50gb"] as const,
        "topUpKind",
      );

      if (topUpKind) {
        await assertActiveBurnBarCloudProEntitlement(uid);
        const topUp = topUpCheckoutSelection(topUpKind);
        const session = await stripeWithResilience("checkout.sessions.create.payment", () =>
          stripe.checkout.sessions.create({
            mode: "payment",
            customer: customerID,
            client_reference_id: uid,
            success_url: successUrl,
            cancel_url: cancelUrl,
            line_items: [{ price: topUp.priceID, quantity: 1 }],
            metadata: {
              firebaseUID: uid,
              topUpKind: topUp.kind,
            },
          }),
        );
        return { sessionId: session.id, url: session.url };
      }

      const selection = subscriptionCheckoutSelection(request.data);

      const session = await stripeWithResilience("checkout.sessions.create.subscription", () =>
        stripe.checkout.sessions.create({
          mode: "subscription",
          customer: customerID,
          client_reference_id: uid,
          success_url: successUrl,
          cancel_url: cancelUrl,
          allow_promotion_codes: true,
          line_items: [{ price: selection.priceID, quantity: 1 }],
          metadata: {
            firebaseUID: uid,
            entitlementID: selection.entitlementID,
            tier: selection.tier,
            cadence: selection.cadence,
          },
          subscription_data: {
            metadata: {
              firebaseUID: uid,
              entitlementID: selection.entitlementID,
              tier: selection.tier,
              cadence: selection.cadence,
            },
          },
        }),
      );

      return { sessionId: session.id, url: session.url };
    },
  ),
);

export const createStripeBurnBarProPortalSession = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: STRIPE_API_SECRETS,
  },
  wrapCallableHandler(
    "createStripeBurnBarProPortalSession",
    async (
      request: CallableRequest<{
        returnUrl?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before opening the billing portal.");
      enforceAuthAndAppCheck(request, uid);

      const stripe = requireConfiguredStripe();
      const returnUrl = boundedHttpsURL(request.data.returnUrl, "returnUrl");
      const customerID = await getOrCreateStripeCustomer(uid, stripe);
      const session = await stripeWithResilience("billingPortal.sessions.create", () =>
        stripe.billingPortal.sessions.create({
          customer: customerID,
          return_url: returnUrl,
        }),
      );
      return { url: session.url };
    },
  ),
);

export const verifyGooglePlayBurnBarProSubscription = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "verifyGooglePlayBurnBarProSubscription",
    async (
      request: CallableRequest<{
        purchaseToken?: unknown;
        productID?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before verifying Google Play billing.");
      enforceAuthAndAppCheck(request, uid);

      const cfg = getConfig();
      const purchaseToken = boundedTrimmedString(request.data.purchaseToken, "purchaseToken", 4096, true);
      const productID =
        boundedTrimmedString(request.data.productID, "productID", 256, false) ?? cfg.googlePlaySubscriptionProductID;
      const entitlementTarget = googlePlaySubscriptionEntitlement(productID);

      // Lazy-load googleapis (~500ms) so every other function skips it on cold start.
      const { google } = await import("googleapis");
      const authClient = await google.auth.getClient({
        scopes: ["https://www.googleapis.com/auth/androidpublisher"],
      });
      const androidpublisher = google.androidpublisher({ version: "v3", auth: authClient });
      const response = await externalApiWithResilience("googleplay.subscriptionsv2.get", () =>
        androidpublisher.purchases.subscriptionsv2.get({
          packageName: cfg.googlePlayPackageName,
          token: purchaseToken,
        }),
      );

      const purchase = jsonObject(response.data);
      const subscriptionState =
        typeof purchase.subscriptionState === "string" ? purchase.subscriptionState : "SUBSCRIPTION_STATE_UNSPECIFIED";
      const lineItem = googlePlayLineItemForProduct(purchase, productID);
      const expiresAtMillis = googlePlayExpiryMillis(lineItem);
      const active = GOOGLE_PLAY_ACTIVE_STATES.has(subscriptionState) && expiresAtMillis > Date.now();
      const tokenHash = sha256Hex(purchaseToken);
      await claimGooglePlayPurchaseToken({
        uid,
        purchaseTokenHash: tokenHash,
        productID: entitlementTarget.canonicalProductID,
        kind: "subscription",
      });
      const entitlement = await writeBurnBarProEntitlement({
        uid,
        productID: entitlementTarget.canonicalProductID,
        expiresAtMillis,
        source: "google_play_verified",
        platform: "android",
        entitlementID: entitlementTarget.entitlementID,
        purchaseTokenHash: tokenHash,
        rawStatus: subscriptionState,
        environment: "Production",
        activeOverride: active,
      });

      await db.doc(googlePlayBillingRecordPath(uid, "purchase", tokenHash)).set(
        stripUndefinedObject({
          uid,
          productID: entitlementTarget.canonicalProductID,
          entitlementID: entitlementTarget.entitlementID,
          purchaseTokenHash: tokenHash,
          subscriptionState,
          expiresAt: new Date(expiresAtMillis).toISOString(),
          lineItemProductID: lineItem && typeof lineItem.productId === "string" ? lineItem.productId : undefined,
          lastVerifiedAt: nowISO(),
          schemaVersion: 1,
        }),
        { merge: true },
      );

      return { entitlement, subscriptionState, active, expiresAt: new Date(expiresAtMillis).toISOString() };
    },
  ),
);

export const verifyGooglePlayCloudProTopUp = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler(
    "verifyGooglePlayCloudProTopUp",
    async (
      request: CallableRequest<{
        purchaseToken?: unknown;
        productID?: unknown;
      }>,
    ): Promise<{
      credited: boolean;
      monthKey: string;
      units: number;
      kind: CloudProTopUpKind;
      purchaseState: number | undefined;
      consumed: boolean;
    }> => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before verifying Google Play top-ups.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarCloudProEntitlement(uid);

      const cfg = getConfig();
      const purchaseToken = boundedTrimmedString(request.data.purchaseToken, "purchaseToken", 4096, true);
      const productID = boundedTrimmedString(request.data.productID, "productID", 256, true);
      const kind = googlePlayTopUpKind(productID);
      const tokenHash = sha256Hex(purchaseToken);
      await claimGooglePlayPurchaseToken({
        uid,
        purchaseTokenHash: tokenHash,
        productID,
        kind: "topup",
      });

      const { google } = await import("googleapis");
      const authClient = await google.auth.getClient({
        scopes: ["https://www.googleapis.com/auth/androidpublisher"],
      });
      const androidpublisher = google.androidpublisher({ version: "v3", auth: authClient });
      const response = await externalApiWithResilience("googleplay.products.get", () =>
        androidpublisher.purchases.products.get({
          packageName: cfg.googlePlayPackageName,
          productId: productID,
          token: purchaseToken,
        }),
      );
      const purchase = jsonObject(response.data);
      const purchaseState =
        typeof purchase.purchaseState === "number" && Number.isFinite(purchase.purchaseState)
          ? purchase.purchaseState
          : undefined;
      const consumptionState =
        typeof purchase.consumptionState === "number" && Number.isFinite(purchase.consumptionState)
          ? purchase.consumptionState
          : undefined;
      if (purchaseState !== 0) {
        throw new HttpsError("failed-precondition", "Google Play top-up purchase is not in the purchased state.", {
          productID,
          purchaseTokenHash: tokenHash,
          purchaseState,
        });
      }

      const credited = await creditCloudProTopUp({
        uid,
        kind,
        source: "google_play",
        externalPaymentID: tokenHash,
      });
      let consumed = false;
      if (consumptionState !== 1) {
        await externalApiWithResilience("googleplay.products.consume", () =>
          androidpublisher.purchases.products.consume({
            packageName: cfg.googlePlayPackageName,
            productId: productID,
            token: purchaseToken,
          }),
        );
        consumed = true;
      }

      await db.doc(googlePlayBillingRecordPath(uid, "topup", tokenHash)).set(
        stripUndefinedObject({
          uid,
          productID,
          kind,
          purchaseTokenHash: tokenHash,
          purchaseState,
          consumptionState,
          orderId: typeof purchase.orderId === "string" ? purchase.orderId : undefined,
          credited,
          consumed,
          lastVerifiedAt: nowISO(),
          schemaVersion: 1,
        }),
        { merge: true },
      );

      return { ...credited, purchaseState, consumed };
    },
  ),
);

export const stripeBurnBarProWebhook = onRequest(
  {
    region: FUNCTIONS_REGION,
    maxInstances: 20,
    secrets: STRIPE_WEBHOOK_SECRETS,
    ...HOT_PATH_OPTIONS,
  },
  async (req, res): Promise<void> => {
    let stripe: Stripe;
    let webhookSecret: string;
    try {
      stripe = requireConfiguredStripe();
      webhookSecret = requireConfiguredStripeWebhookSecret();
    } catch {
      res.status(503).send("Stripe webhook is not configured.");
      return;
    }
    const signature = req.header("stripe-signature");
    if (!signature) {
      res.status(400).send("Missing Stripe signature.");
      return;
    }
    let event: Stripe.Event;
    try {
      const rawBody = Buffer.isBuffer(req.rawBody) ? req.rawBody : Buffer.from(JSON.stringify(req.body ?? {}));
      event = stripe.webhooks.constructEvent(rawBody, signature, webhookSecret);
    } catch (err) {
      res.status(400).send(`Webhook Error: ${err instanceof Error ? err.message : "invalid signature"}`);
      return;
    }

    const reservation = await reserveStripeWebhookEvent(event);
    if (reservation === "processed") {
      res.json({ received: true, duplicate: true });
      return;
    }
    if (reservation === "processing") {
      res.status(409).send("Stripe webhook event is already processing; retry later.");
      return;
    }

    try {
      switch (event.type) {
        case "checkout.session.completed":
        case "checkout.session.async_payment_succeeded":
          if (isStripeCheckoutSession(event.data.object)) {
            await applyStripeCheckoutSession(stripe, event.data.object);
          }
          break;
        case "customer.subscription.created":
        case "customer.subscription.updated":
        case "customer.subscription.deleted":
          if (isStripeSubscription(event.data.object)) {
            await applyStripeSubscription(stripe, event.data.object, undefined, {
              eventID: event.id,
              eventCreatedMillis: event.created * 1000,
            });
          }
          break;
        default:
          break;
      }
      await markStripeWebhookEventProcessed(event);
      res.json({ received: true });
    } catch (err) {
      await markStripeWebhookEventFailed(event, err);
      logError({ event: "callable_error", message: "Stripe webhook handling failed", detail: String(err) });
      res.status(500).send("Stripe webhook handling failed.");
    }
  },
);
