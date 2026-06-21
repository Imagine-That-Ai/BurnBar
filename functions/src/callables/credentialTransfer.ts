/**
 * @fileoverview Server-owned routing for Android credential transfer v2.
 *
 * The decryption secret is deliberately absent from every server-observable
 * surface. Cloud Functions owns authorization, expiry, claim leasing, and
 * one-time completion; Android owns the device-local secret and AEAD decrypt.
 */

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { randomUUID } from "node:crypto";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import { boundedTrimmedString, sha256Hex } from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const TRANSFER_ID_PATTERN = /^ct_[A-Za-z0-9_-]{22,86}$/u;
const LEGACY_HUMAN_CODE_PATTERN = /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{12}$/u;
const FULL_TRANSFER_TOKEN_PATTERN = /^obbct_v2\.ct_[A-Za-z0-9_-]{22,86}\.[ABCDEFGHJKMNPQRSTUVWXYZ23456789-]{26,64}$/u;
const V2_PAYLOAD_PATTERN = /^v2\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{16}\.[A-Za-z0-9_-]{16,266667}$/u;
const MAX_PAYLOAD_LENGTH = 200_000;
const TRANSFER_TTL_MS = 24 * 60 * 60 * 1000;
const CLAIM_TTL_MS = 10 * 60 * 1000;

type RequestData = Record<string, unknown>;
type TransferState = "ready" | "claimed" | "consumed" | "cancelled";

const forbiddenRequestKeys = new Set([
  "code",
  "codehash",
  "credentialtransfercode",
  "credentialtransfersecret",
  "credentialtransfertoken",
  "secret",
  "secretcode",
  "transfercode",
  "transfertoken",
]);

function isRecord(value: unknown): value is RequestData {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizedKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/gu, "");
}

function requireData(data: unknown, allowedKeys: ReadonlySet<string>): RequestData {
  if (!isRecord(data)) {
    throw new HttpsError("invalid-argument", "Request payload must be an object.");
  }
  for (const key of Object.keys(data)) {
    const normalized = normalizedKey(key);
    if (forbiddenRequestKeys.has(normalized)) {
      throw new HttpsError("invalid-argument", "Legacy transfer secrets are not accepted.");
    }
    if (!allowedKeys.has(key)) {
      throw new HttpsError("invalid-argument", `Unsupported credential transfer field: ${key}.`);
    }
  }
  return data;
}

function rejectLegacyHumanCode(raw: unknown): void {
  if (typeof raw !== "string") return;
  const compact = raw.trim().toUpperCase().replace(/[-\s]/gu, "");
  if (LEGACY_HUMAN_CODE_PATTERN.test(compact) || FULL_TRANSFER_TOKEN_PATTERN.test(raw.trim())) {
    throw new HttpsError("invalid-argument", "Legacy transfer codes are not accepted.");
  }
}

function normalizeCredentialTransferId(raw: unknown): string {
  rejectLegacyHumanCode(raw);
  const value = boundedTrimmedString(raw, "transferId", 128, true);
  if (!TRANSFER_ID_PATTERN.test(value)) {
    throw new HttpsError("invalid-argument", "Invalid credential transfer id.");
  }
  return value;
}

function requireV2Payload(raw: unknown): string {
  const payload = boundedTrimmedString(raw, "payload", MAX_PAYLOAD_LENGTH, true);
  if (!V2_PAYLOAD_PATTERN.test(payload)) {
    throw new HttpsError("invalid-argument", "Invalid credential transfer payload.");
  }
  return payload;
}

function requireClaimId(raw: unknown): string {
  const claimId = boundedTrimmedString(raw, "claimId", 128, true);
  if (!/^[0-9a-fA-F-]{36}$/u.test(claimId)) {
    throw new HttpsError("invalid-argument", "Invalid credential transfer claim.");
  }
  return claimId;
}

function timestampMillis(raw: unknown): number | undefined {
  if (raw instanceof Timestamp) return raw.toMillis();
  if (raw && typeof raw === "object" && typeof (raw as { toMillis?: unknown }).toMillis === "function") {
    return (raw as { toMillis: () => number }).toMillis();
  }
  return undefined;
}

function claimIdHash(uid: string, transferId: string, claimId: string): string {
  return sha256Hex(`${uid}:${transferId}:${claimId}`);
}

function requireOwnedV2Transfer(data: RequestData, uid: string): void {
  if (data.ownerUid !== uid) {
    throw new HttpsError("permission-denied", "Credential transfer does not belong to this account.");
  }
  if (data.schemaVersion !== 2) {
    throw new HttpsError("failed-precondition", "Credential transfer is no longer supported.");
  }
}

function currentState(data: RequestData): TransferState {
  const state = data.state;
  if (state === "ready" || state === "claimed" || state === "consumed" || state === "cancelled") {
    return state;
  }
  throw new HttpsError("failed-precondition", "Credential transfer is not available.");
}

function requireUnexpired(data: RequestData, nowMillis: number): void {
  const expiresAtMillis = timestampMillis(data.expiresAt);
  if (expiresAtMillis == null || expiresAtMillis <= nowMillis) {
    throw new HttpsError("failed-precondition", "Credential transfer has expired.");
  }
}

function requirePayloadFromDoc(data: RequestData): string {
  const payload = typeof data.payload === "string" ? data.payload : "";
  if (!V2_PAYLOAD_PATTERN.test(payload) || payload.length > MAX_PAYLOAD_LENGTH) {
    throw new HttpsError("data-loss", "Credential transfer payload is invalid.");
  }
  return payload;
}

function requireMatchingClaim(
  data: RequestData,
  uid: string,
  transferId: string,
  claimId: string,
): void {
  if (data.claimedByUid !== uid || data.claimIdHash !== claimIdHash(uid, transferId, claimId)) {
    throw new HttpsError("permission-denied", "Credential transfer claim does not match.");
  }
}

export const createCredentialTransfer = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "createCredentialTransfer",
    async (request: CallableRequest<{ transferId?: unknown; payload?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before exporting credentials.");
      enforceAuthAndAppCheck(request, uid);

      const data = requireData(request.data, new Set(["transferId", "payload"]));
      const transferId = normalizeCredentialTransferId(data.transferId);
      const payload = requireV2Payload(data.payload);
      const ref = db.doc(`credential_transfers/${transferId}`);
      const nowMillis = Date.now();

      return db.runTransaction(async (tx) => {
        const existing = await tx.get(ref);
        if (existing.exists) {
          throw new HttpsError("already-exists", "Credential transfer already exists.");
        }
        await tx.create(ref, {
          ownerUid: uid,
          schemaVersion: 2,
          payload,
          state: "ready",
          consumed: false,
          createdAt: FieldValue.serverTimestamp(),
          expiresAt: Timestamp.fromMillis(nowMillis + TRANSFER_TTL_MS),
        });
        return { ok: true, transferId };
      });
    },
  ),
);

export const consumeCredentialTransfer = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("consumeCredentialTransfer", async (request: CallableRequest<{ transferId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before importing credentials.");
    enforceAuthAndAppCheck(request, uid);

    const data = requireData(request.data, new Set(["transferId"]));
    const transferId = normalizeCredentialTransferId(data.transferId);
    const ref = db.doc(`credential_transfers/${transferId}`);
    const nowMillis = Date.now();

    return db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) {
        throw new HttpsError("not-found", "Invalid or expired credential transfer.");
      }
      const transfer = snap.data() ?? {};
      requireOwnedV2Transfer(transfer, uid);
      requireUnexpired(transfer, nowMillis);

      const state = currentState(transfer);
      if (state === "consumed") {
        throw new HttpsError("failed-precondition", "Credential transfer has already been used.");
      }
      if (state === "cancelled") {
        throw new HttpsError("failed-precondition", "Credential transfer has been cancelled.");
      }
      if (state === "claimed") {
        const claimExpiresAtMillis = timestampMillis(transfer.claimExpiresAt);
        if (claimExpiresAtMillis == null || claimExpiresAtMillis > nowMillis) {
          throw new HttpsError("failed-precondition", "Credential transfer is already being imported.");
        }
      }

      const payload = requirePayloadFromDoc(transfer);
      const claimId = randomUUID();
      await tx.update(ref, {
        state: "claimed",
        claimedByUid: uid,
        claimExpiresAt: Timestamp.fromMillis(nowMillis + CLAIM_TTL_MS),
        claimIdHash: claimIdHash(uid, transferId, claimId),
      });
      return { ok: true, payload, claimId };
    });
  }),
);

export const completeCredentialTransfer = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "completeCredentialTransfer",
    async (request: CallableRequest<{ transferId?: unknown; claimId?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before completing credential import.");
      enforceAuthAndAppCheck(request, uid);

      const data = requireData(request.data, new Set(["transferId", "claimId"]));
      const transferId = normalizeCredentialTransferId(data.transferId);
      const claimId = requireClaimId(data.claimId);
      const ref = db.doc(`credential_transfers/${transferId}`);
      const nowMillis = Date.now();

      return db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) {
          throw new HttpsError("not-found", "Invalid or expired credential transfer.");
        }
        const transfer = snap.data() ?? {};
        requireOwnedV2Transfer(transfer, uid);

        const state = currentState(transfer);
        if (state === "consumed") {
          requireMatchingClaim(transfer, uid, transferId, claimId);
          return { ok: true, state: "consumed" };
        }
        if (state !== "claimed") {
          throw new HttpsError("failed-precondition", "Credential transfer is not claimed.");
        }
        requireUnexpired(transfer, nowMillis);
        const claimExpiresAtMillis = timestampMillis(transfer.claimExpiresAt);
        if (claimExpiresAtMillis == null || claimExpiresAtMillis <= nowMillis) {
          throw new HttpsError("failed-precondition", "Credential transfer claim has expired.");
        }
        requireMatchingClaim(transfer, uid, transferId, claimId);

        await tx.update(ref, {
          state: "consumed",
          consumed: true,
          consumedAt: FieldValue.serverTimestamp(),
        });
        return { ok: true, state: "consumed" };
      });
    },
  ),
);

export const cancelCredentialTransfer = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler(
    "cancelCredentialTransfer",
    async (request: CallableRequest<{ transferId?: unknown; claimId?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before cancelling credential transfer.");
      enforceAuthAndAppCheck(request, uid);

      const data = requireData(request.data, new Set(["transferId", "claimId"]));
      const transferId = normalizeCredentialTransferId(data.transferId);
      const claimId = data.claimId === undefined ? undefined : requireClaimId(data.claimId);
      const ref = db.doc(`credential_transfers/${transferId}`);
      const nowMillis = Date.now();

      return db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) {
          throw new HttpsError("not-found", "Invalid or expired credential transfer.");
        }
        const transfer = snap.data() ?? {};
        requireOwnedV2Transfer(transfer, uid);

        const state = currentState(transfer);
        if (state === "consumed" || state === "cancelled") {
          return { ok: true, state };
        }
        requireUnexpired(transfer, nowMillis);

        if (state === "claimed") {
          const claimExpiresAtMillis = timestampMillis(transfer.claimExpiresAt);
          if (claimExpiresAtMillis != null && claimExpiresAtMillis > nowMillis) {
            if (!claimId) {
              throw new HttpsError("failed-precondition", "Credential transfer is already being imported.");
            }
            requireMatchingClaim(transfer, uid, transferId, claimId);
          }
          await tx.update(ref, {
            state: "ready",
            claimedByUid: FieldValue.delete(),
            claimExpiresAt: FieldValue.delete(),
            claimIdHash: FieldValue.delete(),
          });
          return { ok: true, state: "ready" };
        }

        if (claimId) {
          throw new HttpsError("failed-precondition", "Credential transfer claim is not active.");
        }
        await tx.update(ref, {
          state: "cancelled",
          cancelledAt: FieldValue.serverTimestamp(),
        });
        return { ok: true, state: "cancelled" };
      });
    },
  ),
);

export const __testing__ = {
  normalizeCredentialTransferId,
  rejectLegacyHumanCode,
};
