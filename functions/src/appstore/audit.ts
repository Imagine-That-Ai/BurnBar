/**
 * @fileoverview Append-only entitlement event audit log.
 *
 * Every verified entitlement event — whether sourced from a client
 * callable, an Apple S2S notification, or the daily reconciler — is
 * recorded here for forensics. Idempotency keys are caller-supplied so
 * Apple retries (which reuse `notificationUUID`) collapse into a single
 * write.
 *
 * Server-only writer: `firestore.rules` denies client writes to
 * `users/{uid}/entitlement_events/*`.
 */

import { createHash } from "node:crypto";
import type { Firestore } from "firebase-admin/firestore";

import type {
  AppStoreEnvironment,
  EntitlementEventDoc,
} from "../types.js";

const SCHEMA_VERSION = 1;

export interface AuditWriteInput {
  uid: string;
  eventId: string;
  source: EntitlementEventDoc["source"];
  notificationType?: string;
  notificationSubtype?: string;
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  environment: AppStoreEnvironment;
  expiresAt?: string;
  revokedAt?: string;
  revocationReason?: number;
  rawJWS: string;
  decoded: Record<string, unknown>;
}

/**
 * Write an audit event. Idempotent via Firestore `create()` — the second
 * write of the same `(uid, eventId)` pair is a no-op.
 */
export async function appendEntitlementEvent(
  db: Firestore,
  input: AuditWriteInput
): Promise<EntitlementEventDoc> {
  const docId = sanitizeDocId(input.eventId);
  const now = new Date().toISOString();
  const doc: EntitlementEventDoc = {
    id: docId,
    uid: input.uid,
    source: input.source,
    notificationType: input.notificationType,
    notificationSubtype: input.notificationSubtype,
    transactionId: input.transactionId,
    originalTransactionId: input.originalTransactionId,
    productId: input.productId,
    environment: input.environment,
    expiresAt: input.expiresAt,
    revokedAt: input.revokedAt,
    revocationReason: input.revocationReason,
    rawJWSHash: createHash("sha256").update(input.rawJWS).digest("hex"),
    observedAt: now,
    decoded: redact(input.decoded),
    schemaVersion: SCHEMA_VERSION,
  };
  const cleaned = stripUndefined(doc as unknown as Record<string, unknown>) as unknown as EntitlementEventDoc;
  const ref = db.doc(`users/${input.uid}/entitlement_events/${docId}`);
  try {
    await ref.create(cleaned);
  } catch (err) {
    // Already-exists is the success case for idempotency. Re-throw any
    // other error so operators learn about real Firestore problems.
    if ((err as { code?: number }).code === 6) {
      // 6 = ALREADY_EXISTS
      return cleaned;
    }
    throw err;
  }
  return cleaned;
}

/**
 * Strip values we don't want to persist verbatim (e.g. raw signed JWS
 * substrings nested inside the decoded payload). The audit doc keeps
 * decoded fields for forensics; sensitive blobs are forbidden.
 */
function redact(input: Record<string, unknown>): Record<string, unknown> {
  const banned = new Set([
    "signedTransactionInfo",
    "signedRenewalInfo",
    "signedPayload",
    "signedDate", // keep timestamps in numeric form below; redact the raw string if any
  ]);
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input)) {
    if (banned.has(k) && typeof v === "string") {
      out[`${k}Hash`] = createHash("sha256").update(v).digest("hex");
      continue;
    }
    if (v === undefined) continue;
    out[k] = v;
  }
  return out;
}

function stripUndefined<T extends Record<string, unknown>>(value: T): T {
  return Object.fromEntries(
    Object.entries(value).filter(([, v]) => v !== undefined)
  ) as T;
}

function sanitizeDocId(raw: string): string {
  // Firestore doc IDs cannot contain `/`. Coerce safely; cap at 1500 bytes.
  return raw
    .replace(/[\\/]+/g, "_")
    .replace(/[^a-zA-Z0-9_.\-]/g, "-")
    .slice(0, 200);
}

// ---------------------------------------------------------------------------
// Test-only exports
// ---------------------------------------------------------------------------

/**
 * Internals reachable from `scripts/test-appstore.mjs`. Not part of the
 * public surface — do not import outside tests.
 */
export const __testing__ = {
  redact,
  sanitizeDocId,
  SCHEMA_VERSION,
};
