/**
 * @fileoverview One-time encrypted credential transfer consumption.
 *
 * The encrypted payload is still end-to-end opaque to the server, but payload
 * retrieval and code consumption must be atomic. Direct client reads allow two
 * same-UID devices to decrypt before either marks the transfer consumed.
 */

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import { boundedTrimmedString } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const TRANSFER_CODE_PATTERN = /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{12}$/u;

function normalizeCredentialTransferCode(raw: unknown): string {
  const value = boundedTrimmedString(raw, "code", 64, true)
    .toUpperCase()
    .replace(/[-\s]/gu, "");
  if (!TRANSFER_CODE_PATTERN.test(value)) {
    throw new HttpsError("invalid-argument", "Invalid transfer code.");
  }
  return value;
}

function timestampMillis(raw: unknown): number | undefined {
  if (raw instanceof Timestamp) return raw.toMillis();
  if (raw && typeof raw === "object" && typeof (raw as { toMillis?: unknown }).toMillis === "function") {
    return (raw as { toMillis: () => number }).toMillis();
  }
  return undefined;
}

export const consumeCredentialTransfer = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("consumeCredentialTransfer", async (request: CallableRequest<{ code?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before importing credentials.");
    enforceAuthAndAppCheck(request, uid);

    const code = normalizeCredentialTransferCode(request.data?.code);
    const ref = db.doc(`credential_transfers/${code}`);
    const nowMillis = Date.now();

    return db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Invalid or expired transfer code.");
      }
      const data = snap.data() ?? {};
      if (data.ownerUid !== uid) {
        throw new HttpsError("permission-denied", "Transfer code does not belong to this account.");
      }
      if (data.consumed === true) {
        throw new HttpsError("failed-precondition", "Transfer code has already been used.");
      }
      const expiresAtMillis = timestampMillis(data.expiresAt);
      if (expiresAtMillis == null || expiresAtMillis <= nowMillis) {
        throw new HttpsError("failed-precondition", "Transfer code has expired.");
      }
      const payload = typeof data.payload === "string" ? data.payload : "";
      if (!/^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u.test(payload)) {
        throw new HttpsError("data-loss", "Transfer payload is invalid.");
      }
      tx.update(ref, {
        consumed: true,
        consumedAt: FieldValue.serverTimestamp(),
      });
      return { ok: true, payload };
    });
  }),
);

export const __testing__ = {
  normalizeCredentialTransferCode,
};
