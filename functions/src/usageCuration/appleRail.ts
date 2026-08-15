/**
 * @fileoverview App Store redeem + ASN V2 rail for Memory Power-Up packs.
 */

import { HttpsError } from "firebase-functions/v2/https";
import type { Firestore } from "firebase-admin/firestore";

import { memoryPackFromAppleProductID } from "./catalog.js";
import { grantExists, grantMemoryPack, reverseMemoryPackGrant } from "./wallet.js";
import { hasActiveMemoryPackVisionEntitlement } from "./eligibility.js";
import { consumeBindingByToken } from "../appstore/reconciler.js";
import { logWarn } from "../logging.js";

export async function redeemAppleMemoryPack(args: {
  db: Firestore;
  uid: string;
  productID: string;
  transactionId: string;
  originalTransactionId?: string;
  appAccountToken?: string;
}): Promise<{ granted: boolean; pending: boolean; alreadyGranted: boolean; packId: string }> {
  const packId = memoryPackFromAppleProductID(args.productID);
  if (!packId) {
    throw new HttpsError("invalid-argument", "Unsupported App Store Memory Boost productID.");
  }
  if (await grantExists(args.uid, "app_store", args.transactionId)) {
    const visionEligible = await hasActiveMemoryPackVisionEntitlement(args.uid);
    const grant = await grantMemoryPack({
      uid: args.uid,
      source: "app_store",
      transactionId: args.transactionId,
      originalTransactionId: args.originalTransactionId ?? args.transactionId,
      packId,
      visionEligible,
    });
    return {
      granted: grant.granted,
      pending: grant.pending,
      alreadyGranted: true,
      packId,
    };
  }
  const token = args.appAccountToken?.toLowerCase() ?? "";
  if (!token) {
    throw new HttpsError("permission-denied", "transaction is missing appAccountToken binding");
  }
  const bindingUid = await consumeBindingByToken(args.db, token, args.uid);
  if (bindingUid !== args.uid) {
    throw new HttpsError("permission-denied", "Memory Boost binding belongs to a different user");
  }
  const visionEligible = await hasActiveMemoryPackVisionEntitlement(args.uid);
  const grant = await grantMemoryPack({
    uid: args.uid,
    source: "app_store",
    transactionId: args.transactionId,
    originalTransactionId: args.originalTransactionId ?? args.transactionId,
    packId,
    visionEligible,
  });
  return {
    granted: grant.granted,
    pending: grant.pending,
    alreadyGranted: grant.alreadyGranted,
    packId,
  };
}

export async function applyAppleMemoryPackNotification(args: {
  db: Firestore;
  productID: string;
  transactionId: string;
  originalTransactionId?: string;
  appAccountToken?: string;
  notificationType?: string;
}): Promise<boolean> {
  const packId = memoryPackFromAppleProductID(args.productID);
  if (!packId) return false;

  const type = args.notificationType ?? "";
  if (type === "REFUND" || type === "REVOKE") {
    let uid: string | undefined;
    const token = args.appAccountToken?.toLowerCase();
    if (token) {
      const cg = await args.db.collectionGroup("entitlement_bindings").where("id", "==", token).limit(1).get();
      uid = cg.docs[0]?.get("uid");
    }
    await reverseMemoryPackGrant({
      uid: typeof uid === "string" ? uid : "",
      source: "app_store",
      transactionId: args.transactionId,
      originalTransactionId: args.originalTransactionId,
      refundFull: true,
    });
    return true;
  }

  if (type === "REFUND_REVERSED") {
    let uid: string | undefined;
    const token = args.appAccountToken?.toLowerCase();
    if (token) {
      const cg = await args.db.collectionGroup("entitlement_bindings").where("id", "==", token).limit(1).get();
      uid = cg.docs[0]?.get("uid");
    }
    await reverseMemoryPackGrant({
      uid: typeof uid === "string" ? uid : "",
      source: "app_store",
      transactionId: args.transactionId,
      originalTransactionId: args.originalTransactionId,
      restoreRefund: true,
    });
    return true;
  }

  if (type === "CONSUMPTION_REQUEST") {
    logWarn({
      event: "memory_pack.apple_consumption_request_unanswered",
      productID: args.productID,
      transactionId: args.transactionId,
    });
    return true;
  }

  if (type === "ONE_TIME_CHARGE") {
    const token = args.appAccountToken?.toLowerCase();
    if (!token) return true;
    const cg = await args.db.collectionGroup("entitlement_bindings").where("id", "==", token).limit(1).get();
    const uid = cg.docs[0]?.get("uid");
    if (typeof uid !== "string" || !uid) return true;
    const visionEligible = await hasActiveMemoryPackVisionEntitlement(uid);
    await grantMemoryPack({
      uid,
      source: "app_store",
      transactionId: args.transactionId,
      originalTransactionId: args.originalTransactionId ?? args.transactionId,
      packId,
      visionEligible,
    });
    return true;
  }

  return true;
}
