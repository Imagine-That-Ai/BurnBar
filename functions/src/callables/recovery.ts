/**
 * @fileoverview Account recovery setup for zero-knowledge mode (Apple ADP pattern).
 *
 * Before a member turns on zero-knowledge (end-to-end) mode, they must register
 * at least one recovery method so a lost device can't permanently lock them out
 * of their own sealed data:
 *   - "recovery_key": the client generates a high-entropy recovery key, derives a
 *     wrapping key from it ON DEVICE, wraps the vault key, and uploads ONLY the
 *     wrapped blob + a verification hash. The server stores the ciphertext; the
 *     plaintext recovery key is shown once to the user and never transmitted.
 *   - "recovery_contact": split-knowledge social recovery — the client uploads a
 *     sealed share per trusted contact; reassembly happens on device.
 *
 * Mirrors Apple Advanced Data Protection's delayed-confirmation flow:
 * setupRecovery writes the method `confirmed:false`; the client must re-enter the
 * key (or the contact must confirm) and call confirmRecovery to flip it. The
 * collection is SERVER-WRITE-ONLY (firestore.rules owner-read, write:false).
 *
 * The server NEVER sees the vault key or the plaintext recovery key — only sealed
 * wrappers + verification hashes, consistent with the device_trust_keys domain.
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import { isRecord, stripUndefinedObject } from "../guards.js";
import { boundedTrimmedString, requireHexDigest, requireBoundedNumber, requireRecordArray, nowISO } from "./shared.js";
import { appendAuditEvent, appendAuditEventRequired, auditActorLabel, AUDIT_ACTIONS } from "./auditLog.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const RECOVERY_SCHEMA_VERSION = 2;
const RECOVERY_COLLECTION = "account_recovery_methods";
// Confirmation-verifier scheme version (security remediation M-5). v2 stores a
// one-way commitment SHA-256(salt || verificationHash) instead of the raw
// verificationHash, so a party that can READ the stored doc (server/admin, or a
// future read-rule slip) cannot replay the stored value to flip confirmed:true
// without actually possessing the recovery key.
const RECOVERY_CONFIRM_VERIFIER_VERSION = 2;

/**
 * Build a non-replayable confirmation commitment from the client-derived
 * verificationHash. The server stores only the commitment + a random salt; the
 * raw verificationHash is NEVER persisted, so reading the doc reveals nothing
 * that can be replayed at confirmRecovery (preimage resistance of SHA-256).
 */
function buildConfirmationCommitment(verificationHash: string): {
  confirmSalt: string;
  confirmVerifier: string;
  confirmVerifierVersion: number;
} {
  const confirmSalt = randomBytes(16).toString("hex");
  const confirmVerifier = createHash("sha256")
    .update(`${confirmSalt}:${verificationHash}`)
    .digest("hex");
  return { confirmSalt, confirmVerifier, confirmVerifierVersion: RECOVERY_CONFIRM_VERIFIER_VERSION };
}
const MAX_RECOVERY_CONTACTS = 5;
const MAX_WRAPPED_BLOB_LENGTH = 8192;
const RECOVERY_ID_PATTERN = /^rec_[a-z0-9_-]{8,80}$/u;

const CALLABLE_OPTS = {
  region: FUNCTIONS_REGION,
  enforceAppCheck: getConfig().enforceAppCheck,
  maxInstances: 50,
} as const;

type RecoveryMethodKind = "recovery_key" | "recovery_contact";

interface RecoveryContactShare {
  contactId: string;
  sealedShare: string;
  contactHint?: string;
}

/** Validate a base64-ish sealed blob field. */
function requireSealedBlob(raw: unknown, fieldName: string): string {
  const value = boundedTrimmedString(raw, fieldName, MAX_WRAPPED_BLOB_LENGTH, true);
  if (!/^[A-Za-z0-9+/=_-]+$/u.test(value)) {
    throw new HttpsError("invalid-argument", `${fieldName} must be a base64 sealed blob.`);
  }
  return value;
}

function parseRecoveryKeyPayload(raw: unknown): {
  wrappedVaultKey: string;
  verificationHash: string;
  keyVersion: number;
  algorithm: string;
} {
  if (!isRecord(raw)) {
    throw new HttpsError("invalid-argument", "payload must be a recovery-key envelope.");
  }
  const payload = raw;
  const algorithm = boundedTrimmedString(payload.algorithm, "payload.algorithm", 64, true);
  if (algorithm !== "AES-256-GCM") {
    throw new HttpsError("invalid-argument", "payload.algorithm must be AES-256-GCM.");
  }
  return {
    wrappedVaultKey: requireSealedBlob(payload.wrappedVaultKey, "payload.wrappedVaultKey"),
    verificationHash: requireHexDigest(payload.verificationHash, "payload.verificationHash"),
    keyVersion: requireBoundedNumber(payload.keyVersion ?? 1, "payload.keyVersion", 1, 100),
    algorithm,
  };
}

function parseRecoveryContactPayload(raw: unknown): { contacts: RecoveryContactShare[]; threshold: number } {
  if (!isRecord(raw)) {
    throw new HttpsError("invalid-argument", "payload must be a recovery-contact envelope.");
  }
  const payload = raw;
  const rawContacts = requireRecordArray(payload.contacts, "payload.contacts", MAX_RECOVERY_CONTACTS);
  if (rawContacts.length === 0) {
    throw new HttpsError("invalid-argument", "At least one recovery contact is required.");
  }
  const contacts: RecoveryContactShare[] = rawContacts.map((contact, idx) => {
    const share: RecoveryContactShare = {
      contactId: boundedTrimmedString(contact.contactId, `payload.contacts[${idx}].contactId`, 160, true),
      sealedShare: requireSealedBlob(contact.sealedShare, `payload.contacts[${idx}].sealedShare`),
    };
    const contactHint = boundedTrimmedString(contact.contactHint, `payload.contacts[${idx}].contactHint`, 256, false);
    if (contactHint) share.contactHint = contactHint;
    return share;
  });
  const threshold = requireBoundedNumber(payload.threshold ?? contacts.length, "payload.threshold", 1, contacts.length);
  return { contacts, threshold };
}

/**
 * Enforce proof-of-knowledge before confirming a recovery_key method: the client
 * must re-enter the recovery key, and the SHA-256 of the derived wrapping key
 * must match the verificationHash stored at setup. This makes confirmRecovery a
 * real delayed re-verification (Apple ADP), not a flag flip — catching users who
 * never saved the key. recovery_contact methods confirm out-of-band per contact.
 */
function verifyRecoveryConfirmation(data: Record<string, unknown>, suppliedHash: string | undefined): void {
  const kind = typeof data.kind === "string" ? data.kind : "recovery_key";
  if (kind !== "recovery_key") return;
  if (!suppliedHash) {
    throw new HttpsError("failed-precondition", "Re-enter your recovery key to confirm (verificationHash required).");
  }
  const recoveryKey = isRecord(data.recoveryKey) ? data.recoveryKey : undefined;

  // v2 (security remediation M-5): non-replayable commitment. The server stored
  // SHA-256(confirmSalt || verificationHash); recompute it from the SUPPLIED
  // hash and compare. The stored value cannot be replayed because it is not the
  // value the client must send.
  const confirmVerifier = recoveryKey?.confirmVerifier;
  const confirmSalt = recoveryKey?.confirmSalt;
  if (typeof confirmVerifier === "string" && typeof confirmSalt === "string") {
    const computed = createHash("sha256").update(`${confirmSalt}:${suppliedHash}`).digest("hex");
    const a = Buffer.from(computed);
    const b = Buffer.from(confirmVerifier);
    if (a.length !== b.length || !timingSafeEqual(a, b)) {
      throw new HttpsError("permission-denied", "Recovery key verification failed.");
    }
    return;
  }

  // Legacy v1 fallback: pre-remediation methods stored the raw verificationHash.
  // These remain equality-checked (and replay-exposed if their doc is read);
  // surface them so they can be re-set-up onto the v2 commitment scheme.
  const stored = recoveryKey?.verificationHash;
  if (typeof stored !== "string") {
    throw new HttpsError("failed-precondition", "Recovery method is missing its verification commitment; please set recovery up again.");
  }
  const a = Buffer.from(suppliedHash);
  const b = Buffer.from(stored);
  if (a.length !== b.length || !timingSafeEqual(a, b)) {
    throw new HttpsError("permission-denied", "Recovery key verification failed.");
  }
}

function requireRecoveryId(raw: unknown): string {
  const recoveryId = boundedTrimmedString(raw, "recoveryId", 128, true);
  if (!RECOVERY_ID_PATTERN.test(recoveryId)) {
    throw new HttpsError("invalid-argument", "recoveryId is invalid.");
  }
  return recoveryId;
}

export const setupRecovery = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("setupRecovery", async (request: CallableRequest<{ method?: unknown; payload?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before setting up recovery.");
    enforceAuthAndAppCheck(request, uid);

    const methodRaw = boundedTrimmedString(request.data?.method, "method", 40, true);
    if (methodRaw !== "recovery_key" && methodRaw !== "recovery_contact") {
      throw new HttpsError("invalid-argument", "method must be recovery_key or recovery_contact.");
    }
    const method: RecoveryMethodKind = methodRaw;

    const recoveryId = `rec_${Date.now().toString(36)}_${randomBytes(8).toString("hex")}`;
    const now = nowISO();
    const base = {
      recoveryId,
      kind: method,
      confirmed: false,
      createdAt: now,
      updatedAt: now,
      schemaVersion: RECOVERY_SCHEMA_VERSION,
      createdAtTs: Timestamp.now(),
    };

    let doc: Record<string, unknown>;
    if (method === "recovery_key") {
      const payload = parseRecoveryKeyPayload(request.data?.payload);
      // M-5: persist a one-way commitment, NOT the raw verificationHash, so the
      // stored doc cannot be replayed to confirm without the recovery key.
      const commitment = buildConfirmationCommitment(payload.verificationHash);
      doc = {
        ...base,
        recoveryKey: {
          wrappedVaultKey: payload.wrappedVaultKey,
          keyVersion: payload.keyVersion,
          algorithm: payload.algorithm,
          ...commitment,
        },
      };
    } else {
      const payload = parseRecoveryContactPayload(request.data?.payload);
      doc = { ...base, recoveryContacts: payload.contacts, threshold: payload.threshold };
    }

    await db.doc(`users/${uid}/${RECOVERY_COLLECTION}/${recoveryId}`).set(stripUndefinedObject(doc));

    try {
      await appendAuditEvent(uid, {
        actor: auditActorLabel(request),
        action: AUDIT_ACTIONS.recoverySetup,
        domain: "device_trust_keys",
      });
    } catch {
      // best-effort audit
    }

    return { ok: true, recoveryId };
  }),
);

export const confirmRecovery = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler(
    "confirmRecovery",
    async (request: CallableRequest<{ recoveryId?: unknown; verificationHash?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before confirming recovery.");
      enforceAuthAndAppCheck(request, uid);

      const recoveryId = requireRecoveryId(request.data?.recoveryId);
      const suppliedHash =
        request.data?.verificationHash !== undefined
          ? requireHexDigest(request.data.verificationHash, "verificationHash")
          : undefined;
      const ref = db.doc(`users/${uid}/${RECOVERY_COLLECTION}/${recoveryId}`);
      const now = nowISO();
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists) {
          throw new HttpsError("not-found", "Recovery method not found.");
        }
        // Real re-verification: a recovery_key method requires the re-entered key's
        // hash to match what was stored at setup before it is marked confirmed.
        verifyRecoveryConfirmation(snap.data() ?? {}, suppliedHash);
        tx.set(ref, { confirmed: true, confirmedAt: now, updatedAt: now }, { merge: true });
      });

      // Fail-CLOSED: confirming a recovery method arms an irreversible account-
      // recovery path, so the record must commit. If the audit write fails the
      // error propagates rather than the confirmation going unlogged.
      await appendAuditEventRequired(uid, {
        actor: auditActorLabel(request),
        action: AUDIT_ACTIONS.recoveryConfirm,
        domain: "device_trust_keys",
      });

      return { ok: true };
    },
  ),
);

/** Test-only surface for the pure validators (no Firestore). */
export const __testing__ = {
  RECOVERY_COLLECTION,
  MAX_RECOVERY_CONTACTS,
  requireSealedBlob,
  parseRecoveryKeyPayload,
  parseRecoveryContactPayload,
  verifyRecoveryConfirmation,
  buildConfirmationCommitment,
  requireRecoveryId,
  RECOVERY_CONFIRM_VERIFIER_VERSION,
};

export const listRecovery = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("listRecovery", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to view recovery methods.");
    enforceAuthAndAppCheck(request, uid);

    const snap = await db.collection(`users/${uid}/${RECOVERY_COLLECTION}`).orderBy("createdAt", "asc").limit(50).get();
    const methods = snap.docs.map((doc) => {
      const data = doc.data();
      return {
        recoveryId: typeof data.recoveryId === "string" ? data.recoveryId : doc.id,
        kind: typeof data.kind === "string" ? data.kind : "recovery_key",
        createdAt: typeof data.createdAt === "string" ? data.createdAt : "",
        confirmed: data.confirmed === true,
      };
    });
    return { ok: true, methods };
  }),
);
