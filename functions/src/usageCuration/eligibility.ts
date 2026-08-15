/**
 * @fileoverview Membership gates for Memory Power-Up packs.
 *
 * Text packs require any BurnBar Pro family membership at purchase-intent.
 * Vision packs require Cloud Pro / Ultra at purchase-intent *and* at grant
 * time; if entitlement lapses between checkout and grant, the pack is held
 * pending instead of silently credited.
 *
 * This module may import entitlements. `wallet.ts` must not.
 */

import { HttpsError } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import {
  BURNBAR_PRO_ENTITLEMENT_ID,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
  isActiveBurnBarCloudProEntitlement,
  isActiveBurnBarUltraEntitlement,
  isActivePremiumEntitlement,
} from "../callables/shared/entitlements.js";
import { DEFAULT_MEMORY_PACKS, type MemoryPackId } from "./catalog.js";

async function hasActiveMemoryPackTextEntitlement(uid: string): Promise<boolean> {
  const [proSnap, hostedSnap, proMaxSnap, ultraSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
  ]);
  return (
    isActivePremiumEntitlement(proSnap.data()) ||
    isActivePremiumEntitlement(hostedSnap.data()) ||
    isActiveBurnBarCloudProEntitlement(proMaxSnap.data()) ||
    isActiveBurnBarUltraEntitlement(ultraSnap.data())
  );
}

export async function hasActiveMemoryPackVisionEntitlement(uid: string): Promise<boolean> {
  const [proMaxSnap, ultraSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
  ]);
  return isActiveBurnBarCloudProEntitlement(proMaxSnap.data()) || isActiveBurnBarUltraEntitlement(ultraSnap.data());
}

export async function assertMemoryPackPurchaseEntitlement(uid: string, packId: MemoryPackId): Promise<void> {
  const pack = DEFAULT_MEMORY_PACKS[packId];
  if (pack.requiresVisionEntitlement) {
    if (await hasActiveMemoryPackVisionEntitlement(uid)) return;
    throw new HttpsError(
      "permission-denied",
      "BurnBar Cloud Pro or Ultra is required to buy Vision Memory Boost.",
    );
  }
  if (await hasActiveMemoryPackTextEntitlement(uid)) return;
  throw new HttpsError("permission-denied", "BurnBar Pro is required to buy Memory Boost packs.");
}
