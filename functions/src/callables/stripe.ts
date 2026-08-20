/**
 * @fileoverview Stripe and Google Play BurnBar Pro billing callables
 */

import { HttpsError, onCall, onRequest, type CallableRequest } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { logError, logWarn, wrapCallableHandler } from "../logging.js";
import {
  externalApiWithResilience,
  googlePlayConsumeWithResilience,
  stripeWithResilience,
} from "../resilienceHelpers.js";
import {
  BURNBAR_PRO_ENTITLEMENT_ID,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
  STRIPE_API_SECRETS,
  STRIPE_WEBHOOK_SECRETS,
  GOOGLE_PLAY_ACTIVE_STATES,
  nowISO,
  sha256Hex,
  requireConfiguredStripe,
  requireConfiguredStripeWebhookSecret,
  boundedHttpsURL,
  assertActiveBurnBarCloudProEntitlement,
  getOrCreateStripeCustomer,
  selectGooglePlaySubscriptionLineItem,
  assertStripeCustomerCanStartSubscriptionCheckout,
  findReusableStripeSubscriptionCheckoutSession,
  expireOpenStripeSubscriptionCheckoutSessions,
  creditCloudProTopUp,
  writeBurnBarProEntitlement,
} from "./shared.js";
import Stripe from "stripe";
import { parseGooglePlayProSubscriptionInput, parseGooglePlayTopUpInput } from "./stripeInputSchemas.js";
import { errorMessage, jsonObject, stripUndefinedObject } from "../guards.js";
import {
  allowanceDocPath,
  cloudProTopUpReceiptDocPath,
  monthKeyForDate,
  type CloudProTopUpKind,
} from "../cloudProAllowanceCore.js";
import { googlePlayBillingRecordPath } from "./googlePlayBillingPaths.js";
import { claimGooglePlayPurchaseToken } from "./googlePlayTokenClaims.js";
import { googlePlayTopUpKind, STRIPE_TOP_UP_KINDS, topUpCheckoutSelection } from "./stripeTopUps.js";
import { STRIPE_CHECKOUT_CUSTOMER_AND_TAX_SETTINGS } from "./stripeCheckoutPolicy.js";
import { FUNCTIONS_REGION, HOT_PATH_OPTIONS } from "../runtimeOptions.js";
import {
  ANALYTICS_SECRETS,
  ConsentSignal,
  emitSubscriptionEntitlementGranted,
  entitlementFamilyOf,
  boundedAnalyticsDeviceId,
} from "../analytics/index.js";
import { processStripeWebhookEvent } from "./stripeWebhookDispatch.js";

// ---------------------------------------------------------------------------
// Callable / HTTP: BurnBar Pro billing bridges
// ---------------------------------------------------------------------------

type StripeCheckoutTier = "cloud" | "cloud_pro" | "ultra";
type StripeCheckoutCadence = "monthly" | "annual";
type StripeWebhookReservation = "reserved" | "processed" | "processing";

const STRIPE_WEBHOOK_EVENT_LEASE_MS = 10 * 60 * 1000;

/**
 * Retention for `stripe_webhook_events` ledger docs (LB-5): long enough to
 * keep the dedupe/ordering ledger useful for incident forensics and Stripe's
 * multi-day redelivery window, short enough that the collection cannot grow
 * unboundedly with billing traffic.
 */
const STRIPE_WEBHOOK_EVENT_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;

/**
 * TTL anchor written on EVERY `stripe_webhook_events` ledger write: Stripe
 * event time + 90 days. The Firestore TTL policy on the `expireAt` field is
 * applied via ops tooling (gcloud firestore fields ttls update), not in code;
 * docs merely become eligible for deletion once the policy exists.
 */
function stripeWebhookEventExpireAt(event: Stripe.Event): Timestamp {
  return Timestamp.fromMillis(event.created * 1000 + STRIPE_WEBHOOK_EVENT_RETENTION_MS);
}

function isAllowedChoice<T extends string>(raw: string, allowed: readonly T[]): raw is T {
  for (const choice of allowed) {
    if (choice === raw) return true;
  }
  return false;
}

function optionalChoice<T extends string>(raw: unknown, allowed: readonly T[], fieldName: string): T | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  if (typeof raw !== "string" || !isAllowedChoice(raw, allowed)) {
    throw new HttpsError("invalid-argument", `${fieldName} is not supported.`);
  }
  return raw;
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
  const tier = optionalChoice(data.tier, ["cloud", "cloud_pro", "ultra"] as const, "tier") ?? "cloud";
  const cadence = optionalChoice(data.cadence, ["monthly", "annual"] as const, "cadence") ?? "monthly";
  if (tier === "ultra") {
    const priceID = cadence === "annual" ? cfg.stripeBurnBarUltraAnnualPriceID : cfg.stripeBurnBarUltraMonthlyPriceID;
    return {
      priceID: requireConfiguredPriceID(priceID, `BurnBar Ultra ${cadence}`),
      entitlementID: BURNBAR_ULTRA_ENTITLEMENT_ID,
      tier,
      cadence,
    };
  }
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

function stripeWebhookEventRef(eventID: string) {
  return db.doc(`stripe_webhook_events/${eventID.replaceAll("/", "_")}`);
}

/** Exported for tests (stripeWebhookOrdering.test.ts). */
export async function reserveStripeWebhookEvent(event: Stripe.Event): Promise<StripeWebhookReservation> {
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
        expireAt: stripeWebhookEventExpireAt(event),
        schemaVersion: 1,
      },
      { merge: true },
    );
    return "reserved";
  });
}

/** Exported for tests (stripeWebhookOrdering.test.ts). */
export async function markStripeWebhookEventProcessed(event: Stripe.Event): Promise<void> {
  await stripeWebhookEventRef(event.id).set(
    {
      status: "processed",
      processedAt: Timestamp.now(),
      leaseExpiresAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      expireAt: stripeWebhookEventExpireAt(event),
      schemaVersion: 1,
    },
    { merge: true },
  );
}

/** Exported for tests (stripeWebhookOrdering.test.ts). */
export async function markStripeWebhookEventFailed(event: Stripe.Event, error: unknown): Promise<void> {
  await stripeWebhookEventRef(event.id).set(
    stripUndefinedObject({
      status: "failed",
      failedAt: Timestamp.now(),
      leaseExpiresAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      expireAt: stripeWebhookEventExpireAt(event),
      error: error instanceof Error ? error.message : String(error),
      schemaVersion: 1,
    }),
    { merge: true },
  );
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

      const cfg = getConfig();
      const stripe = requireConfiguredStripe();
      const successUrl = boundedHttpsURL(request.data.successUrl, "successUrl", cfg.stripeRedirectURLAllowlist);
      const cancelUrl = boundedHttpsURL(request.data.cancelUrl, "cancelUrl", cfg.stripeRedirectURLAllowlist);
      const customerID = await getOrCreateStripeCustomer(uid, stripe);
      const topUpKind = optionalChoice(request.data.topUpKind, STRIPE_TOP_UP_KINDS, "topUpKind");

      if (topUpKind) {
        await assertActiveBurnBarCloudProEntitlement(uid);
        const topUp = topUpCheckoutSelection(topUpKind);
        const session = await stripeWithResilience("checkout.sessions.create.payment", () =>
          stripe.checkout.sessions.create({
            mode: "payment",
            customer: customerID,
            ...STRIPE_CHECKOUT_CUSTOMER_AND_TAX_SETTINGS,
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
      await assertStripeCustomerCanStartSubscriptionCheckout(stripe, customerID);
      const redirectFingerprint = sha256Hex(`checkout_redirect_v1\n${successUrl}\n${cancelUrl}`);
      const reusable = await findReusableStripeSubscriptionCheckoutSession(
        stripe,
        customerID,
        selection,
        redirectFingerprint,
      );
      if (reusable) {
        return { sessionId: reusable.id, url: reusable.url, reused: true };
      }
      // A reuse miss means the user changed tier, cadence, or redirect URLs.
      // Expire the superseded open sessions before creating the new one so a
      // stale checkout URL for a different selection cannot still be paid.
      await expireOpenStripeSubscriptionCheckoutSessions(stripe, customerID);
      const idempotencyBucket = Math.floor(Date.now() / (10 * 60 * 1000));
      const idempotencyKey = sha256Hex(
        `burnbar_subscription_checkout:${uid}:${selection.tier}:${selection.cadence}:${redirectFingerprint}:${idempotencyBucket}`,
      );

      const session = await stripeWithResilience("checkout.sessions.create.subscription", () =>
        stripe.checkout.sessions.create(
          {
            mode: "subscription",
            customer: customerID,
            ...STRIPE_CHECKOUT_CUSTOMER_AND_TAX_SETTINGS,
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
              redirectFingerprint,
            },
            subscription_data: {
              metadata: {
                firebaseUID: uid,
                entitlementID: selection.entitlementID,
                tier: selection.tier,
                cadence: selection.cadence,
              },
            },
          },
          { idempotencyKey },
        ),
      );

      return { sessionId: session.id, url: session.url, reused: false };
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

      const cfg = getConfig();
      const stripe = requireConfiguredStripe();
      const returnUrl = boundedHttpsURL(request.data.returnUrl, "returnUrl", cfg.stripeRedirectURLAllowlist);
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
    // Bind the Amplitude key so `.value()` resolves at request time. If the
    // secret is unset the analytics stream stays dark (recorder key gate);
    // binding it does not enable any tracking on its own.
    secrets: ANALYTICS_SECRETS,
  },
  wrapCallableHandler(
    "verifyGooglePlayBurnBarProSubscription",
    async (
      request: CallableRequest<{
        purchaseToken?: unknown;
        productID?: unknown;
        // Opt-in analytics signal PROPAGATED from the client. Both default to
        // dark: absent/declined consent or a missing device id ⇒ no event.
        analyticsConsent?: unknown;
        analyticsDeviceId?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before verifying Google Play billing.");
      enforceAuthAndAppCheck(request, uid);

      const cfg = getConfig();
      const { purchaseToken, productID: requestedProductID } = parseGooglePlayProSubscriptionInput(request.data);
      const productID = requestedProductID ?? cfg.googlePlaySubscriptionProductID;

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
      const {
        lineItem,
        target: entitlementTarget,
        expiresAtMillis,
      } = selectGooglePlaySubscriptionLineItem(purchase, [productID]);
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

      // Opt-in, consent-gated server conversion. The entitlement is now durably
      // written; emit `subscription.entitlement.granted` ONLY when the client
      // propagated a `granted` consent flag + an anonymous device id. Dark
      // otherwise (unset/declined/no-key/no-device-id). Best-effort and
      // NON-FATAL: a `.catch` guarantees a failing Amplitude can never reject a
      // verified purchase. `purchaseToken` itself never reaches analytics — its
      // sha256 hash is the dedup key (insert_id).
      await emitSubscriptionEntitlementGranted({
        consent: new ConsentSignal(request.data.analyticsConsent),
        deviceId: boundedAnalyticsDeviceId(request.data.analyticsDeviceId),
        userId: uid, // analytics helper hashes the Firebase uid before user_id leaves process
        entitlementFamily: entitlementFamilyOf(entitlementTarget.entitlementID),
        source: "google_play",
        platform: "android",
        isActive: active,
        expiresInSeconds: Math.max(0, Math.round((expiresAtMillis - Date.now()) / 1000)),
        dedupeKey: `gp_sub_${tokenHash}`, // idempotent across client retries
      }).catch((err: unknown) => {
        logWarn({
          event: "subscription_analytics_emission_failed",
          user_id_hash: uid.slice(0, 8),
          detail: errorMessage(err),
        });
      });

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
      const { purchaseToken, productID } = parseGooglePlayTopUpInput(request.data);
      const kind = googlePlayTopUpKind(productID);
      const tokenHash = sha256Hex(purchaseToken);

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
      const receiptID = `google_play_${tokenHash}`;
      const monthKey = monthKeyForDate(new Date());
      const [existingServerReceipt, existingMonthlyTopUp] = await Promise.all([
        db.doc(cloudProTopUpReceiptDocPath(uid, receiptID)).get(),
        db.doc(`${allowanceDocPath(uid, monthKey)}/topups/${receiptID}`).get(),
      ]);
      if (consumptionState === 1 && !existingServerReceipt.exists && !existingMonthlyTopUp.exists) {
        throw new HttpsError(
          "failed-precondition",
          "Google Play top-up purchase was already consumed before server verification.",
          {
            productID,
            purchaseTokenHash: tokenHash,
            purchaseState,
            consumptionState,
          },
        );
      }
      await claimGooglePlayPurchaseToken({
        uid,
        purchaseTokenHash: tokenHash,
        productID,
        kind: "topup",
      });

      const credited = await creditCloudProTopUp({
        uid,
        kind,
        source: "google_play",
        externalPaymentID: tokenHash,
      });
      let consumed = false;
      let consumptionConfirmedAfterError = false;
      if (consumptionState !== 1) {
        try {
          await googlePlayConsumeWithResilience(() =>
            androidpublisher.purchases.products.consume({
              packageName: cfg.googlePlayPackageName,
              productId: productID,
              token: purchaseToken,
            }),
          );
          consumed = true;
        } catch (consumeError) {
          // Two verification requests can both observe consumptionState=0,
          // then race after the Firestore credit transaction. Google Play may
          // accept the first consume and reject the second even though the
          // purchase is now safely consumed. A timeout can produce the same
          // ambiguity. Re-read Play's authoritative state before surfacing an
          // error; only treat the call as successful when Play confirms the
          // exact token has transitioned to consumed.
          const refreshedResponse = await externalApiWithResilience("googleplay.products.get.after_consume", () =>
            androidpublisher.purchases.products.get({
              packageName: cfg.googlePlayPackageName,
              productId: productID,
              token: purchaseToken,
            }),
          );
          const refreshedPurchase = jsonObject(refreshedResponse.data);
          const refreshedConsumptionState =
            typeof refreshedPurchase.consumptionState === "number" &&
            Number.isFinite(refreshedPurchase.consumptionState)
              ? refreshedPurchase.consumptionState
              : undefined;
          if (refreshedConsumptionState !== 1) throw consumeError;
          consumed = true;
          consumptionConfirmedAfterError = true;
        }
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
          credited: true,
          creditedByThisInvocation: credited.credited,
          consumed,
          consumptionConfirmedAfterError,
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
      await processStripeWebhookEvent(stripe, event);
      await markStripeWebhookEventProcessed(event);
      res.json({ received: true });
    } catch (err) {
      await markStripeWebhookEventFailed(event, err);
      logError({ event: "callable_error", message: "Stripe webhook handling failed", detail: String(err) });
      res.status(500).send("Stripe webhook handling failed.");
    }
  },
);
