/**
 * @fileoverview Stripe and Google Play BurnBar Pro billing callables
 */

import { HttpsError, onCall, onRequest, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { logError, wrapCallableHandler } from "../logging.js";
import {
  BURNBAR_PRO_ENTITLEMENT_ID,
  STRIPE_API_SECRETS,
  STRIPE_WEBHOOK_SECRETS,
  GOOGLE_PLAY_ACTIVE_STATES,
  nowISO,
  boundedTrimmedString,
  sha256Hex,
  requireConfiguredStripe,
  requireConfiguredStripeWebhookSecret,
  boundedHttpsURL,
  getOrCreateStripeCustomer,
  googlePlayLineItemForProduct,
  googlePlayExpiryMillis,
  applyStripeCheckoutSession,
  applyStripeSubscription,
  writeBurnBarProEntitlement,
} from "./shared.js";
import { google } from "googleapis";
import Stripe from "stripe";
import { isStripeCheckoutSession, isStripeSubscription, jsonObject, stripUndefinedObject } from "../guards.js";

// ---------------------------------------------------------------------------
// Callable / HTTP: BurnBar Pro billing bridges
// ---------------------------------------------------------------------------

export const createStripeBurnBarProCheckoutSession = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: STRIPE_API_SECRETS,
  },
  wrapCallableHandler("createStripeBurnBarProCheckoutSession", async (
    request: CallableRequest<{
      successUrl?: unknown;
      cancelUrl?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before starting checkout.");
    enforceAuthAndAppCheck(request, uid);

    const cfg = getConfig();
    const stripe = requireConfiguredStripe();
    const successUrl = boundedHttpsURL(request.data.successUrl, "successUrl");
    const cancelUrl = boundedHttpsURL(request.data.cancelUrl, "cancelUrl");
    const customerID = await getOrCreateStripeCustomer(uid, stripe);

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerID,
      client_reference_id: uid,
      success_url: successUrl,
      cancel_url: cancelUrl,
      allow_promotion_codes: true,
      line_items: [{ price: cfg.stripeBurnBarProPriceID, quantity: 1 }],
      metadata: {
        firebaseUID: uid,
        entitlementID: BURNBAR_PRO_ENTITLEMENT_ID,
      },
      subscription_data: {
        metadata: {
          firebaseUID: uid,
          entitlementID: BURNBAR_PRO_ENTITLEMENT_ID,
        },
      },
    });

    return { sessionId: session.id, url: session.url };
  }
));

export const createStripeBurnBarProPortalSession = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: STRIPE_API_SECRETS,
  },
  wrapCallableHandler("createStripeBurnBarProPortalSession", async (
    request: CallableRequest<{
      returnUrl?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before opening the billing portal.");
    enforceAuthAndAppCheck(request, uid);

    const stripe = requireConfiguredStripe();
    const returnUrl = boundedHttpsURL(request.data.returnUrl, "returnUrl");
    const customerID = await getOrCreateStripeCustomer(uid, stripe);
    const session = await stripe.billingPortal.sessions.create({
      customer: customerID,
      return_url: returnUrl,
    });
    return { url: session.url };
  }
));

export const verifyGooglePlayBurnBarProSubscription = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("verifyGooglePlayBurnBarProSubscription", async (
    request: CallableRequest<{
      purchaseToken?: unknown;
      productID?: unknown;
    }>
  ) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before verifying Google Play billing.");
    enforceAuthAndAppCheck(request, uid);

    const cfg = getConfig();
    const purchaseToken = boundedTrimmedString(request.data.purchaseToken, "purchaseToken", 4096, true);
    const productID =
      boundedTrimmedString(request.data.productID, "productID", 256, false) ??
      cfg.googlePlaySubscriptionProductID;
    if (productID !== cfg.googlePlaySubscriptionProductID && productID !== cfg.burnBarProProductID) {
      throw new HttpsError("invalid-argument", "Unsupported Google Play subscription product.");
    }

    const authClient = await google.auth.getClient({
      scopes: ["https://www.googleapis.com/auth/androidpublisher"],
    });
    const androidpublisher = google.androidpublisher({ version: "v3", auth: authClient });
    const response = await androidpublisher.purchases.subscriptionsv2.get({
      packageName: cfg.googlePlayPackageName,
      token: purchaseToken,
    });

    const purchase = jsonObject(response.data);
    const subscriptionState =
      typeof purchase.subscriptionState === "string"
        ? purchase.subscriptionState
        : "SUBSCRIPTION_STATE_UNSPECIFIED";
    const lineItem = googlePlayLineItemForProduct(purchase, productID);
    const expiresAtMillis = googlePlayExpiryMillis(lineItem);
    const active = GOOGLE_PLAY_ACTIVE_STATES.has(subscriptionState) && expiresAtMillis > Date.now();
    const tokenHash = sha256Hex(purchaseToken);
    const entitlement = await writeBurnBarProEntitlement({
      uid,
      productID: cfg.googlePlaySubscriptionProductID,
      expiresAtMillis,
      source: "google_play_verified",
      platform: "android",
      purchaseTokenHash: tokenHash,
      rawStatus: subscriptionState,
      environment: "Production",
      activeOverride: active,
    });

    await db.doc(`users/${uid}/billing/google_play_purchases/${tokenHash}`).set(
      stripUndefinedObject({
        uid,
        productID: cfg.googlePlaySubscriptionProductID,
        purchaseTokenHash: tokenHash,
        subscriptionState,
        expiresAt: new Date(expiresAtMillis).toISOString(),
        lineItemProductID: lineItem && typeof lineItem.productId === "string" ? lineItem.productId : undefined,
        lastVerifiedAt: nowISO(),
        schemaVersion: 1,
      }),
      { merge: true }
    );

    return { entitlement, subscriptionState, active, expiresAt: new Date(expiresAtMillis).toISOString() };
  }
));

export const stripeBurnBarProWebhook = onRequest(
  {
    region: "us-central1",
    maxInstances: 20,
    secrets: STRIPE_WEBHOOK_SECRETS,
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
            await applyStripeSubscription(stripe, event.data.object);
          }
          break;
        default:
          break;
      }
      res.json({ received: true });
    } catch (err) {
      logError({ event: "callable_error", message: "Stripe webhook handling failed", detail: String(err) });
      res.status(500).send("Stripe webhook handling failed.");
    }
  }
);

