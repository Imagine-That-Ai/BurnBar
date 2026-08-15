/**
 * @fileoverview Google Play redeem + RTDN void rail for Memory Power-Up packs.
 */

import { HttpsError } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { getConfig } from "../config.js";
import { jsonObject } from "../guards.js";
import { externalApiWithResilience, googlePlayConsumeWithResilience } from "../resilienceHelpers.js";
import { sha256Hex } from "../callables/shared/validators.js";
import { claimGooglePlayPurchaseToken } from "../callables/googlePlayTokenClaims.js";
import { googlePlayBillingRecordPath } from "../callables/googlePlayBillingPaths.js";
import { memoryPackFromPlayProductID } from "./catalog.js";
import { grantExists, grantMemoryPack, reverseMemoryPackGrant } from "./wallet.js";
import { hasActiveMemoryPackVisionEntitlement } from "./eligibility.js";

export async function redeemPlayMemoryPack(args: {
  uid: string;
  purchaseToken: string;
  productID: string;
}): Promise<{
  granted: boolean;
  pending: boolean;
  alreadyGranted: boolean;
  consumed: boolean;
  packId: string;
}> {
  const packId = memoryPackFromPlayProductID(args.productID);
  if (!packId) {
    throw new HttpsError("invalid-argument", "Unsupported Google Play Memory Boost productID.");
  }

  const cfg = getConfig();
  const tokenHash = sha256Hex(args.purchaseToken);
  const { google } = await import("googleapis");
  const authClient = await google.auth.getClient({
    scopes: ["https://www.googleapis.com/auth/androidpublisher"],
  });
  const androidpublisher = google.androidpublisher({ version: "v3", auth: authClient });
  const response = await externalApiWithResilience("googleplay.products.get.memory_pack", () =>
    androidpublisher.purchases.products.get({
      packageName: cfg.googlePlayPackageName,
      productId: args.productID,
      token: args.purchaseToken,
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
    throw new HttpsError("failed-precondition", "Google Play Memory Boost purchase is not in the purchased state.");
  }

  const orderId = typeof purchase.orderId === "string" && purchase.orderId ? purchase.orderId : tokenHash;
  const grantedByOrder = await grantExists(args.uid, "google_play", orderId);
  const grantedByToken = await grantExists(args.uid, "google_play", tokenHash);
  const alreadyGranted = grantedByOrder || grantedByToken;
  const grantTransactionId = grantedByOrder || !grantedByToken ? orderId : tokenHash;
  if (alreadyGranted) {
    const visionEligible = await hasActiveMemoryPackVisionEntitlement(args.uid);
    const grant = await grantMemoryPack({
      uid: args.uid,
      source: "google_play",
      transactionId: grantTransactionId,
      originalTransactionId: tokenHash,
      packId,
      visionEligible,
    });
    let consumed = consumptionState === 1;
    if (!consumed) {
      consumed = await consumePlayMemoryPack(
        androidpublisher,
        cfg.googlePlayPackageName,
        args.productID,
        args.purchaseToken,
      );
    }
    return {
      granted: grant.granted,
      pending: grant.pending,
      alreadyGranted: true,
      consumed,
      packId,
    };
  }
  if (consumptionState === 1 && !alreadyGranted) {
    throw new HttpsError(
      "failed-precondition",
      "Google Play Memory Boost purchase was already consumed before server verification.",
    );
  }

  await claimGooglePlayPurchaseToken({
    uid: args.uid,
    purchaseTokenHash: tokenHash,
    productID: args.productID,
    kind: "memory_pack",
  });

  const visionEligible = await hasActiveMemoryPackVisionEntitlement(args.uid);
  const grant = await grantMemoryPack({
    uid: args.uid,
    source: "google_play",
    transactionId: orderId,
    originalTransactionId: tokenHash,
    packId,
    visionEligible,
  });

  let consumed = consumptionState === 1;
  if (!consumed) {
    consumed = await consumePlayMemoryPack(
      androidpublisher,
      cfg.googlePlayPackageName,
      args.productID,
      args.purchaseToken,
    );
  }

  await db.doc(googlePlayBillingRecordPath(args.uid, "memory_pack", tokenHash)).set(
    {
      purchaseTokenHash: tokenHash,
      productID: args.productID,
      packId,
      orderId,
      consumed,
      schemaVersion: 1,
    },
    { merge: true },
  );

  return {
    granted: grant.granted,
    pending: grant.pending,
    alreadyGranted: grant.alreadyGranted,
    consumed,
    packId,
  };
}

interface PlayPublisherProducts {
  purchases: {
    products: {
      consume: (args: { packageName: string; productId: string; token: string }) => Promise<unknown>;
      get: (args: { packageName: string; productId: string; token: string }) => Promise<{ data: unknown }>;
    };
  };
}

async function consumePlayMemoryPack(
  androidpublisher: PlayPublisherProducts,
  packageName: string,
  productId: string,
  token: string,
): Promise<boolean> {
  try {
    await googlePlayConsumeWithResilience(() =>
      androidpublisher.purchases.products.consume({
        packageName,
        productId,
        token,
      }),
    );
    return true;
  } catch {
    const refreshed = await externalApiWithResilience("googleplay.products.get.after_memory_pack_consume", () =>
      androidpublisher.purchases.products.get({
        packageName,
        productId,
        token,
      }),
    );
    const refreshedPurchase = jsonObject(refreshed.data);
    if (refreshedPurchase.consumptionState === 1) return true;
    throw new HttpsError("unavailable", "Google Play did not confirm Memory Boost consumption.");
  }
}

export async function reverseVoidedMemoryPack(args: {
  uid: string;
  tokenHash: string;
  orderId?: string;
}): Promise<void> {
  await reverseMemoryPackGrant({
    uid: args.uid,
    source: "google_play",
    transactionId: args.orderId ?? args.tokenHash,
    originalTransactionId: args.tokenHash,
    fullReversal: true,
  });
}
