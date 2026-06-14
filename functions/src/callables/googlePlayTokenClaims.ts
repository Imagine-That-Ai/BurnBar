/**
 * Global registry so a Google Play purchase token cannot grant entitlements to multiple Firebase UIDs.
 */

import { HttpsError } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { nowISO } from "./shared.js";

export const GOOGLE_PLAY_TOKEN_CLAIMS_COLLECTION = "google_play_token_claims";

type GooglePlayTokenClaimKind = "subscription" | "topup";

function errorCode(error: unknown): unknown {
  return typeof error === "object" && error !== null ? Reflect.get(error, "code") : undefined;
}

export async function claimGooglePlayPurchaseToken(args: {
  uid: string;
  purchaseTokenHash: string;
  productID: string;
  kind: GooglePlayTokenClaimKind;
}): Promise<void> {
  const ref = db.doc(`${GOOGLE_PLAY_TOKEN_CLAIMS_COLLECTION}/${args.purchaseTokenHash}`);
  try {
    await ref.create({
      uid: args.uid,
      productID: args.productID,
      kind: args.kind,
      claimedAt: nowISO(),
      schemaVersion: 1,
    });
  } catch (err: unknown) {
    const code = errorCode(err);
    if (code !== 6) {
      throw err;
    }
    const snap = await ref.get();
    const existingUid = snap.get("uid");
    if (typeof existingUid === "string" && existingUid !== args.uid) {
      throw new HttpsError(
        "permission-denied",
        "This Google Play purchase is already linked to another BurnBar account.",
      );
    }
  }
}
