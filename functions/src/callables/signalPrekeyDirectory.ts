/**
 * @fileoverview L41 Signal prekey/session directory RUNTIME callables — the
 * server half of the prekey/session lifecycle whose Firestore SHAPE + rules
 * already landed (firestore.rules:3479-3883, docs/signalification/
 * L41_SIGNAL_PREKEY_SESSION_DIRECTORY.md).
 *
 * The Firestore rules already let a trusted owner write these docs directly, but
 * two runtime flows MUST be server-owned and a few more benefit from a uniform,
 * cross-checked surface:
 *
 *   - publishSignalPrekeyBundle  — admin-validated batch publish of the device's
 *     PUBLIC signed prekey + one-time prekeys + Kyber prekeys under an already
 *     published identity key. The Admin SDK BYPASSES firestore.rules, so this
 *     callable RE-VALIDATES every invariant the rules enforce (shape, base64,
 *     numeric-id bounds, algorithm, lifecycle, identity/device cross-check) and
 *     rejects any private-key/session-state field — defense-in-depth, mirroring
 *     signalAtRestWrite.ts.
 *   - claimSignalPrekeyBundle    — ATOMIC fetch-and-mark of one available
 *     one-time prekey + one Kyber prekey for an X3DH/PQXDH session initiator.
 *     Client-direct claim via rules is RACY (two initiators read the same
 *     available key and both mark it claimed → key reuse). The single-claim
 *     guarantee only exists inside a Firestore transaction, so it lives here.
 *   - recordSignalSession        — write session DIRECTORY metadata (never the
 *     serialized Signal session; that stays device-local) under the caller's OWN
 *     trusted identity. Same-user multi-device scope only: a named peerUid must
 *     equal the owner. (It does NOT verify the referenced prekeys were claimed by
 *     this session — that cross-check is not implemented; do not rely on it.)
 *   - recordSignalRotation       — append a rotation event before an identity
 *     key-version transition, optionally minting a rewrap job id.
 *
 * The server NEVER sees private key material or serialized session state: every
 * payload is rejected if it carries a privateKey, serializedSession, sessionState,
 * or ratchetState field (mirrors signalDirectoryDocumentLimits in the rules).
 * Identity generation, prekey generation, X3DH, and the Double Ratchet all run on
 * device.
 *
 * Scope: same-user multi-device only (mode "same-user-device"). The rules are
 * owner-only read, so a caller can only publish/claim under their OWN namespace.
 * A cross-user "gateway-transport" mode is a deliberate future extension and is
 * NOT accepted today (SESSION_MODES rejects it; recordSignalSession requires any
 * named peerUid to equal the owner).
 */

import { Timestamp, FieldValue } from "firebase-admin/firestore";
import type { DocumentReference, Transaction, WriteBatch } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { db } from "../adminRuntime.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { recordOrUndefined } from "../guards.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { randomBytes } from "node:crypto";
import {
  safeCloudDocumentID,
  requireRecordArray,
  commitBatchedWrites,
} from "./shared.js";
import {
  FORBIDDEN_FIELDS,
  MAX_KYBER_PREKEYS_PER_CALL,
  MAX_ONE_TIME_PREKEYS_PER_CALL,
  MIN_AVAILABLE_KYBER_PREKEYS,
  MIN_AVAILABLE_ONE_TIME_PREKEYS,
  assertNoForbiddenFields,
  buildKyberPreKeyDoc,
  buildOneTimePreKeyDoc,
  buildRotationEventDoc,
  buildSessionDoc,
  buildSignedPreKeyDoc,
  parseFutureExpiry,
  parseSignalBase64,
  prekeyReplenishStatus,
  selectPrekeyToClaim,
} from "./signalPrekeyDirectoryValidators.js";
import type { DirectoryContext } from "./signalPrekeyDirectoryValidators.js";

const TRUSTED_DEVICE_STATES = new Set(["pending", "trusted"]);

const CALLABLE_OPTS = {
  region: FUNCTIONS_REGION,
  enforceAppCheck: getConfig().enforceAppCheck,
  maxInstances: 50,
} as const;

/**
 * The single-use claim mutation. Marking a one-time / Kyber prekey `status: "claimed"`
 * is what removes it from future `status == "available"` queries, so a claimed prekey is
 * never re-issued to a second device. Extracted as a pure builder so the consume semantics
 * (status flip + session attribution) are unit-testable independent of the transaction.
 */
function buildPrekeyClaimStamp(sessionId: string): {
  status: "claimed";
  claimedBySessionId: string;
  claimedAt: FieldValue;
  updatedAt: FieldValue;
} {
  return {
    status: "claimed",
    claimedBySessionId: sessionId,
    claimedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
}

// ---------------------------------------------------------------------------
// Firestore glue (callable bodies).
// ---------------------------------------------------------------------------

function requireUid(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in to use the Signal prekey directory.");
  enforceAuthAndAppCheck(request, uid);
  return uid;
}

interface ResolvedIdentity {
  identityKeyId: string;
  deviceId: string;
  keyVersion: number;
  identityPublicKeyData: string;
  ref: DocumentReference;
}

/**
 * Load the caller's published identity key and cross-check the backing escrow
 * device is trusted with a matching keyVersion — the admin-side equivalent of
 * signalIdentityMatchesKnownDevice() + signalDirectoryParentMatches() in the
 * rules. The deviceId/keyVersion are read from the AUTHORITATIVE stored identity
 * doc, never trusted from the request.
 */
async function resolveTrustedIdentity(uid: string, identityKeyIdRaw: unknown): Promise<ResolvedIdentity> {
  const identityKeyId = safeCloudDocumentID(identityKeyIdRaw, "identityKeyId");
  const ref = db.doc(`users/${uid}/signal_identity_public_keys/${identityKeyId}`);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("failed-precondition", "Publish the Signal identity key before its prekey bundle.");
  }
  const data = snap.data();
  if (!data) {
    throw new HttpsError("failed-precondition", "Stored Signal identity key is malformed.");
  }
  const deviceId = String(data.deviceId ?? "");
  const keyVersion = Number(data.keyVersion ?? 0);
  const identityPublicKeyData = String(data.publicKeyData ?? "");
  if (!deviceId || !Number.isInteger(keyVersion) || keyVersion < 1 || !identityPublicKeyData) {
    throw new HttpsError("failed-precondition", "Stored Signal identity key is malformed.");
  }
  const deviceSnap = await db.doc(`users/${uid}/escrow_devices/${deviceId}`).get();
  if (!deviceSnap.exists) {
    throw new HttpsError("failed-precondition", "Signal identity key has no backing escrow device.");
  }
  const deviceData = deviceSnap.data();
  if (!deviceData) {
    throw new HttpsError("failed-precondition", "Backing escrow device is malformed.");
  }
  if (!TRUSTED_DEVICE_STATES.has(String(deviceData.trustState))) {
    throw new HttpsError("failed-precondition", "Backing escrow device is not trusted.");
  }
  if (Number(deviceData.keyVersion) !== keyVersion) {
    throw new HttpsError("failed-precondition", "Identity keyVersion does not match the escrow device.");
  }
  return { identityKeyId, deviceId, keyVersion, identityPublicKeyData, ref };
}

/**
 * publishSignalPrekeyBundle — admin-validated, idempotent batch publish of the
 * device's PUBLIC signed prekey + one-time prekeys + Kyber prekeys. Existing doc
 * ids are skipped (so a claimed prekey is never clobbered back to available).
 */
export const publishSignalPrekeyBundle = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler(
    "publishSignalPrekeyBundle",
    async (
      request: CallableRequest<{
        identityKeyId?: unknown;
        signedPreKey?: unknown;
        oneTimePreKeys?: unknown;
        kyberPreKeys?: unknown;
      }>,
    ) => {
      const uid = requireUid(request);
      const identity = await resolveTrustedIdentity(uid, request.data?.identityKeyId);
      const ctx: DirectoryContext = {
        identityKeyId: identity.identityKeyId,
        deviceId: identity.deviceId,
        keyVersion: identity.keyVersion,
      };
      const nowMs = Date.now();

      if (request.data?.signedPreKey === undefined || request.data?.signedPreKey === null) {
        throw new HttpsError("invalid-argument", "signedPreKey is required.");
      }
      const signedPreKey = recordOrUndefined(request.data.signedPreKey);
      if (!signedPreKey) {
        throw new HttpsError("invalid-argument", "signedPreKey must be an object.");
      }
      const signed = buildSignedPreKeyDoc(signedPreKey, ctx, nowMs);

      const oneTimeRaw = requireRecordArray(
        request.data?.oneTimePreKeys ?? [],
        "oneTimePreKeys",
        MAX_ONE_TIME_PREKEYS_PER_CALL,
      );
      const kyberRaw = requireRecordArray(request.data?.kyberPreKeys ?? [], "kyberPreKeys", MAX_KYBER_PREKEYS_PER_CALL);
      const oneTime = oneTimeRaw.map((r) => buildOneTimePreKeyDoc(r, ctx, nowMs));
      const kyber = kyberRaw.map((r) => buildKyberPreKeyDoc(r, ctx, nowMs));

      const signedRef = identity.ref.collection("signed_prekeys").doc(signed.id);
      const oneTimeRefs = oneTime.map((d) => identity.ref.collection("one_time_prekeys").doc(d.id));
      const kyberRefs = kyber.map((d) => identity.ref.collection("kyber_prekeys").doc(d.id));

      // Idempotent: read every target ref once, then only create the missing
      // ones, so a re-publish (retry / overlapping batch) never resurrects a
      // claimed prekey.
      const allRefs = [signedRef, ...oneTimeRefs, ...kyberRefs];
      const existing = allRefs.length > 0 ? await db.getAll(...allRefs) : [];
      const existingIds = new Set(existing.filter((s) => s.exists).map((s) => s.ref.path));

      const writes: Array<(batch: WriteBatch) => void> = [];
      const stamp = { createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp() };
      let signedWritten = 0;
      let oneTimeWritten = 0;
      let kyberWritten = 0;
      if (!existingIds.has(signedRef.path)) {
        writes.push((b) => b.create(signedRef, { ...signed.data, ...stamp }));
        signedWritten = 1;
      }
      oneTime.forEach((d, i) => {
        if (!existingIds.has(oneTimeRefs[i].path)) {
          writes.push((b) => b.create(oneTimeRefs[i], { ...d.data, ...stamp }));
          oneTimeWritten += 1;
        }
      });
      kyber.forEach((d, i) => {
        if (!existingIds.has(kyberRefs[i].path)) {
          writes.push((b) => b.create(kyberRefs[i], { ...d.data, ...stamp }));
          kyberWritten += 1;
        }
      });
      if (writes.length > 0) await commitBatchedWrites(writes);

      // Count only UNEXPIRED available prekeys, so this matches what claimSignalPrekeyBundle
      // and signalPrekeyWatermark report (expired-but-available keys are not claimable).
      const watermarkNow = Timestamp.now();
      const [availableOneTime, availableKyber] = await Promise.all([
        identity.ref
          .collection("one_time_prekeys")
          .where("status", "==", "available")
          .where("expiresAt", ">", watermarkNow)
          .count()
          .get(),
        identity.ref
          .collection("kyber_prekeys")
          .where("status", "==", "available")
          .where("expiresAt", ">", watermarkNow)
          .count()
          .get(),
      ]);

      logInfo({
        event: "publishSignalPrekeyBundle",
        uid,
        identityKeyId: identity.identityKeyId,
        signedWritten,
        oneTimeWritten,
        kyberWritten,
      });

      return {
        ok: true as const,
        identityKeyId: identity.identityKeyId,
        signedPreKeyWritten: signedWritten === 1,
        oneTimePreKeysWritten: oneTimeWritten,
        kyberPreKeysWritten: kyberWritten,
        availableOneTimePreKeys: availableOneTime.data().count,
        availableKyberPreKeys: availableKyber.data().count,
      };
    },
  ),
);

/**
 * claimSignalPrekeyBundle — ATOMICALLY claim one available one-time prekey
 * (optional; X3DH degrades without it) and one Kyber prekey (mandatory for
 * PQXDH) under a target identity, returning the PUBLIC PQXDH bundle for session
 * setup. The transaction read-set + status update is what prevents two
 * initiators from claiming the same key.
 */
export const claimSignalPrekeyBundle = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler(
    "claimSignalPrekeyBundle",
    async (request: CallableRequest<{ identityKeyId?: unknown; sessionId?: unknown }>) => {
      const uid = requireUid(request);
      // Cross-checks (identity exists, device trusted) before opening the txn.
      const identity = await resolveTrustedIdentity(uid, request.data?.identityKeyId);
      const sessionId = safeCloudDocumentID(request.data?.sessionId, "sessionId");
      // Mirror firestore.rules:3685/3749: claimedBySessionId is bounded to 200.
      if (sessionId.length > 200) {
        throw new HttpsError("invalid-argument", "sessionId must be 200 characters or fewer.");
      }

      const claimed = await db.runTransaction(async (tx: Transaction) => {
        // --- reads first (Firestore transaction requirement) ---
        // Re-enforce expiresAt > now admin-side: the rules block claiming an
        // expired prekey (firestore.rules:3680/3744), but the Admin SDK bypasses
        // rules, and an expired-but-still-"available" prekey is a reachable state
        // until cleanup runs. Filtering at the query keeps the claim rules-faithful.
        const now = Timestamp.now();
        const signedSnap = await tx.get(
          identity.ref.collection("signed_prekeys").where("status", "==", "active").limit(1),
        );
        if (signedSnap.empty) {
          throw new HttpsError("failed-precondition", "No active signed prekey is published for this identity.");
        }
        const kyberSnap = await tx.get(
          identity.ref
            .collection("kyber_prekeys")
            .where("status", "==", "available")
            .where("expiresAt", ">", now)
            .limit(8),
        );
        if (kyberSnap.empty) {
          throw new HttpsError(
            "resource-exhausted",
            "No unexpired Kyber prekeys are available; publish more before claiming.",
          );
        }
        const oneTimeSnap = await tx.get(
          identity.ref
            .collection("one_time_prekeys")
            .where("status", "==", "available")
            .where("expiresAt", ">", now)
            .limit(8),
        );

        // --- deterministic single selection (lowest numericId) ---
        const kyberPick = selectPrekeyToClaim(
          kyberSnap.docs.map((d) => ({
            id: d.id,
            numericId: Number(d.data().kyberPreKeyNumericId),
            ref: d.ref,
            data: d.data(),
          })),
        );
        if (!kyberPick) {
          throw new HttpsError(
            "resource-exhausted",
            "No unexpired Kyber prekeys are available; publish more before claiming.",
          );
        }
        const oneTimePick = selectPrekeyToClaim(
          oneTimeSnap.docs.map((d) => ({
            id: d.id,
            numericId: Number(d.data().oneTimePreKeyNumericId),
            ref: d.ref,
            data: d.data(),
          })),
        );

        // --- writes: mark claimed (single-use: removes the prekey from future
        // `status == "available"` queries so it is never re-issued) ---
        const claimStamp = buildPrekeyClaimStamp(sessionId);
        tx.update(kyberPick.ref, claimStamp);
        if (oneTimePick) tx.update(oneTimePick.ref, claimStamp);

        const signedData = signedSnap.docs[0].data();
        return {
          signedPreKey: {
            id: String(signedData.signedPreKeyId),
            numericId: Number(signedData.signedPreKeyNumericId),
            publicKeyB64: String(signedData.publicKeyB64),
            signatureB64: String(signedData.signatureB64),
          },
          kyberPreKey: {
            id: kyberPick.id,
            numericId: kyberPick.numericId,
            publicKeyB64: String(kyberPick.data.publicKeyB64),
            signatureB64: String(kyberPick.data.signatureB64),
          },
          oneTimePreKey: oneTimePick
            ? {
                id: oneTimePick.id,
                numericId: oneTimePick.numericId,
                publicKeyB64: String(oneTimePick.data.publicKeyB64),
              }
            : null,
        };
      });

      logInfo({
        event: "claimSignalPrekeyBundle",
        uid,
        identityKeyId: identity.identityKeyId,
        sessionId,
        claimedOneTime: claimed.oneTimePreKey !== null,
      });

      return {
        ok: true as const,
        identityKeyId: identity.identityKeyId,
        deviceId: identity.deviceId,
        keyVersion: identity.keyVersion,
        identityPublicKeyData: identity.identityPublicKeyData,
        ...claimed,
      };
    },
  ),
);

/**
 * recordSignalSession — persist session DIRECTORY metadata only (the serialized
 * Signal session never leaves the device). Idempotent on sessionId.
 */
export const recordSignalSession = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler(
    "recordSignalSession",
    async (request: CallableRequest<{ identityKeyId?: unknown; session?: unknown }>) => {
      const uid = requireUid(request);
      const identity = await resolveTrustedIdentity(uid, request.data?.identityKeyId);
      if (request.data?.session === undefined || request.data?.session === null) {
        throw new HttpsError("invalid-argument", "session is required.");
      }
      const sessionRaw = recordOrUndefined(request.data.session);
      if (!sessionRaw) {
        throw new HttpsError("invalid-argument", "session must be an object.");
      }
      const session = buildSessionDoc(
        sessionRaw,
        {
          identityKeyId: identity.identityKeyId,
          deviceId: identity.deviceId,
          keyVersion: identity.keyVersion,
        },
        uid,
      );
      const ref = identity.ref.collection("sessions").doc(session.id);
      const existing = await ref.get();
      if (!existing.exists) {
        await ref.create({
          ...session.data,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
      logInfo({ event: "recordSignalSession", uid, identityKeyId: identity.identityKeyId, sessionId: session.id });
      return { ok: true as const, sessionId: session.id, created: !existing.exists };
    },
  ),
);

/**
 * recordSignalRotation — append a rotation event before an identity key-version
 * transition. When rewrapRequired, mints a rewrapJobId the device can reference
 * when it re-wraps existing CloudVault content under the new key. Append-only.
 */
export const recordSignalRotation = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler(
    "recordSignalRotation",
    async (request: CallableRequest<{ identityKeyId?: unknown; rotation?: unknown }>) => {
      const uid = requireUid(request);
      const identity = await resolveTrustedIdentity(uid, request.data?.identityKeyId);
      if (request.data?.rotation === undefined || request.data?.rotation === null) {
        throw new HttpsError("invalid-argument", "rotation is required.");
      }
      const raw = recordOrUndefined(request.data.rotation);
      if (!raw) {
        throw new HttpsError("invalid-argument", "rotation must be an object.");
      }
      const rewrapRequired = raw.rewrapRequired === true;
      const rewrapJobId = rewrapRequired ? `rewrap_${randomBytes(12).toString("hex")}` : undefined;
      const rotation = buildRotationEventDoc(
        raw,
        {
          identityKeyId: identity.identityKeyId,
          deviceId: identity.deviceId,
          keyVersion: identity.keyVersion,
        },
        rewrapJobId,
      );
      const ref = identity.ref.collection("rotation_events").doc(rotation.id);
      const existing = await ref.get();
      if (existing.exists) {
        throw new HttpsError("already-exists", "A rotation event with that id already exists (append-only).");
      }
      await ref.create({
        ...rotation.data,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      logInfo({
        event: "recordSignalRotation",
        uid,
        identityKeyId: identity.identityKeyId,
        rotationId: rotation.id,
        rewrapRequired,
      });
      return { ok: true as const, rotationId: rotation.id, rewrapJobId: rewrapJobId ?? null };
    },
  ),
);

/**
 * signalPrekeyWatermark — a recipient device polls this for its OWN identity to learn
 * how many unexpired prekeys remain (one-time prekeys are consumed by OTHER devices'
 * claims, which the owner never sees in a claim response), and whether to replenish.
 */
export const signalPrekeyWatermark = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("signalPrekeyWatermark", async (request: CallableRequest<{ identityKeyId?: unknown }>) => {
    const uid = requireUid(request);
    const identity = await resolveTrustedIdentity(uid, request.data?.identityKeyId);
    const now = Timestamp.now();
    const [oneTime, kyber] = await Promise.all([
      identity.ref
        .collection("one_time_prekeys")
        .where("status", "==", "available")
        .where("expiresAt", ">", now)
        .count()
        .get(),
      identity.ref
        .collection("kyber_prekeys")
        .where("status", "==", "available")
        .where("expiresAt", ">", now)
        .count()
        .get(),
    ]);
    const availableOneTimePreKeys = oneTime.data().count;
    const availableKyberPreKeys = kyber.data().count;
    const status = prekeyReplenishStatus(availableOneTimePreKeys, availableKyberPreKeys);
    return {
      ok: true as const,
      identityKeyId: identity.identityKeyId,
      availableOneTimePreKeys,
      availableKyberPreKeys,
      minOneTimePreKeys: MIN_AVAILABLE_ONE_TIME_PREKEYS,
      minKyberPreKeys: MIN_AVAILABLE_KYBER_PREKEYS,
      ...status,
    };
  }),
);

export const __testing__ = {
  parseSignalBase64,
  assertNoForbiddenFields,
  parseFutureExpiry,
  buildSignedPreKeyDoc,
  buildOneTimePreKeyDoc,
  buildKyberPreKeyDoc,
  buildSessionDoc,
  buildRotationEventDoc,
  selectPrekeyToClaim,
  buildPrekeyClaimStamp,
  prekeyReplenishStatus,
  FORBIDDEN_FIELDS,
  MAX_ONE_TIME_PREKEYS_PER_CALL,
  MAX_KYBER_PREKEYS_PER_CALL,
  MIN_AVAILABLE_ONE_TIME_PREKEYS,
  MIN_AVAILABLE_KYBER_PREKEYS,
};
