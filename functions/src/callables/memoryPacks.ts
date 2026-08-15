/**
 * @fileoverview Memory Power-Up commerce callables (catalog, Stripe, Play, settle).
 */

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { wrapCallableHandler, logCallableStart, traceIdFromCallableRequest } from "../logging.js";
import { STRIPE_API_SECRETS, requireConfiguredStripe, getOrCreateStripeCustomer, boundedHttpsURL } from "./shared.js";
import { STRIPE_CHECKOUT_CUSTOMER_AND_TAX_SETTINGS } from "./stripeCheckoutPolicy.js";
import { stripeWithResilience } from "../resilienceHelpers.js";
import { FUNCTIONS_REGION, HOT_PATH_OPTIONS } from "../runtimeOptions.js";
import { listedMemoryPacks, loadMemoryPackCatalog, isMemoryPackOffered } from "../usageCuration/remoteConfig.js";
import { memoryPackRuntimeIds } from "../usageCuration/catalog.js";
import {
  assertMemoryPackPurchaseEntitlement,
  hasActiveMemoryPackVisionEntitlement,
} from "../usageCuration/eligibility.js";
import * as memoryWallet from "../usageCuration/wallet.js";
import {
  requireConfiguredStripeMemoryPackPrice,
  stripeMemoryPackCheckoutMetadata,
  stripeMemoryPackIdempotencyKey,
} from "../usageCuration/stripeRail.js";
import * as playRail from "../usageCuration/playRail.js";
import { parseCreateMemoryPackCheckoutInput, parseRedeemPlayMemoryPackInput } from "./memoryPackInputSchemas.js";

export const listMemoryPacks = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    ...HOT_PATH_OPTIONS,
  },
  wrapCallableHandler("listMemoryPacks", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before listing Memory Boost packs.");
    enforceAuthAndAppCheck(request, uid);
    logCallableStart("listMemoryPacks", traceIdFromCallableRequest(request), uid);
    const visionEligible = await hasActiveMemoryPackVisionEntitlement(uid);
    const catalog = await loadMemoryPackCatalog();
    const packs = listedMemoryPacks(catalog, visionEligible).map((pack) => ({
      packId: pack.packId,
      lane: pack.lane,
      tokens: pack.tokens,
      title: pack.title,
      cadence: pack.cadence,
      appleProductID: memoryPackRuntimeIds(pack.packId).appleProductID,
      playProductID: memoryPackRuntimeIds(pack.packId).playProductID,
      requiresVisionEntitlement: pack.requiresVisionEntitlement,
    }));
    return { packs, visionEligible };
  }),
);

export const settlePendingMemoryPacks = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("settlePendingMemoryPacks", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before settling Memory Boost packs.");
    enforceAuthAndAppCheck(request, uid);
    const visionEligible = await hasActiveMemoryPackVisionEntitlement(uid);
    const settled = await memoryWallet.settlePendingMemoryPacks(uid, visionEligible);
    return { settled, visionEligible };
  }),
);

export const createMemoryPackCheckoutSession = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: STRIPE_API_SECRETS,
    ...HOT_PATH_OPTIONS,
  },
  wrapCallableHandler("createMemoryPackCheckoutSession", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before starting Memory Boost checkout.");
    enforceAuthAndAppCheck(request, uid);
    const cfg = getConfig();
    const input = parseCreateMemoryPackCheckoutInput(request.data);
    const successUrl = boundedHttpsURL(input.successUrl, "successUrl", cfg.stripeRedirectURLAllowlist);
    const cancelUrl = boundedHttpsURL(input.cancelUrl, "cancelUrl", cfg.stripeRedirectURLAllowlist);
    const catalog = await loadMemoryPackCatalog();
    if (!isMemoryPackOffered(catalog.packs[input.packId])) {
      throw new HttpsError("failed-precondition", "This Memory Boost pack is not currently offered.");
    }
    await assertMemoryPackPurchaseEntitlement(uid, input.packId);
    const priceID = requireConfiguredStripeMemoryPackPrice(input.packId);
    const stripe = requireConfiguredStripe();
    const customerID = await getOrCreateStripeCustomer(uid, stripe);
    const session = await stripeWithResilience("checkout.sessions.create.memory_pack", () =>
      stripe.checkout.sessions.create(
        {
          mode: "payment",
          customer: customerID,
          ...STRIPE_CHECKOUT_CUSTOMER_AND_TAX_SETTINGS,
          client_reference_id: uid,
          success_url: successUrl,
          cancel_url: cancelUrl,
          allow_promotion_codes: false,
          line_items: [{ price: priceID, quantity: 1 }],
          metadata: stripeMemoryPackCheckoutMetadata(uid, input.packId),
          payment_intent_data: {
            metadata: stripeMemoryPackCheckoutMetadata(uid, input.packId),
          },
        },
        { idempotencyKey: stripeMemoryPackIdempotencyKey(uid, input.packId, input.attemptId) },
      ),
    );
    return { sessionId: session.id, url: session.url };
  }),
);

export const redeemPlayMemoryPack = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 100,
  },
  wrapCallableHandler("redeemPlayMemoryPack", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before redeeming a Memory Boost pack.");
    enforceAuthAndAppCheck(request, uid);
    const input = parseRedeemPlayMemoryPackInput(request.data);
    return playRail.redeemPlayMemoryPack({ uid, purchaseToken: input.purchaseToken, productID: input.productID });
  }),
);
