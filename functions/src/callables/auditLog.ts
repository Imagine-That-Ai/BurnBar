/**
 * @fileoverview Tamper-evident unified access-audit log (the `audit_timeline`
 * data domain).
 *
 * Every privacy-relevant mutation (export, scoped delete, recovery setup, panic
 * revoke, browser-escrow registration) appends one event to
 * `users/{uid}/unified_audit_log` through {@link appendAuditEvent}. Each event
 * carries a per-user SHA-256 hash chain:
 *
 *   hash_n = sha256(prevHash_{n} + canonicalJSON(event_n))
 *
 * where `prevHash` for the genesis event is the empty string. `getAuditLog`
 * pages the chain in chain order; `verifyAuditLog` walks it and reports the
 * first seq where the recomputed hash or the prevHash link breaks — so any
 * server-side tampering (insert/edit/delete) is detectable by the client.
 *
 * The collection is SERVER-WRITE-ONLY (firestore.rules: owner-read, write:false).
 * All appends go through Cloud Functions, never direct client writes, so the
 * chain stays monotonic and unforgeable from the client.
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import { stripUndefinedObject } from "../guards.js";
import { sha256Hex, requireBoundedNumber, boundedTrimmedString } from "./shared.js";

export const AUDIT_LOG_SCHEMA_VERSION = 1;
const AUDIT_LOG_COLLECTION = "unified_audit_log";
/** Genesis prevHash: the empty-string sentinel for the first chain link. */
export const AUDIT_GENESIS_PREV_HASH = "";

const CALLABLE_OPTS = {
  region: "us-central1",
  enforceAppCheck: getConfig().enforceAppCheck,
  maxInstances: 50,
} as const;

/** The fields that participate in the hash chain (excludes `hash` itself). */
export interface AuditEventCore {
  seq: number;
  ts: string;
  actor: string;
  action: string;
  domain: string;
  prevHash: string;
}

export interface AuditEvent extends AuditEventCore {
  hash: string;
}

/**
 * Deterministic JSON used as the hash-chain payload. Keys are emitted in a fixed
 * order (never `Object.keys` order) so the digest is stable across runtimes and
 * reproducible on the client when it re-verifies the chain.
 */
export function canonicalAuditPayload(core: AuditEventCore): string {
  return JSON.stringify({
    seq: core.seq,
    ts: core.ts,
    actor: core.actor,
    action: core.action,
    domain: core.domain,
    prevHash: core.prevHash,
  });
}

/** hash_n = sha256(prevHash_n + canonical(event_n)). */
export function computeAuditHash(core: AuditEventCore): string {
  return sha256Hex(core.prevHash + canonicalAuditPayload(core));
}

/** Zero-padded doc id so lexical Firestore order matches numeric chain order. */
function auditDocID(seq: number): string {
  return seq.toString().padStart(12, "0");
}

/**
 * Append one event to the user's tamper-evident audit chain inside a
 * transaction (so concurrent appends can't fork the chain). Returns the
 * committed event including its hash + seq. Best-effort callers should wrap this
 * in try/catch — an audit-write failure must never fail the underlying action.
 */
export async function appendAuditEvent(
  uid: string,
  event: { actor: string; action: string; domain: string },
): Promise<AuditEvent> {
  const collection = db.collection(`users/${uid}/${AUDIT_LOG_COLLECTION}`);
  return db.runTransaction(async (tx) => {
    const tailSnap = await tx.get(collection.orderBy("seq", "desc").limit(1));
    const tail = tailSnap.docs[0]?.data();
    const prevSeq = typeof tail?.seq === "number" ? tail.seq : -1;
    const prevHash = typeof tail?.hash === "string" ? tail.hash : AUDIT_GENESIS_PREV_HASH;
    const seq = prevSeq + 1;
    const core: AuditEventCore = {
      seq,
      ts: new Date().toISOString(),
      actor: event.actor,
      action: event.action,
      domain: event.domain,
      prevHash,
    };
    const hash = computeAuditHash(core);
    const doc: AuditEvent & { schemaVersion: number; createdAt: Timestamp } = {
      ...core,
      hash,
      schemaVersion: AUDIT_LOG_SCHEMA_VERSION,
      createdAt: Timestamp.now(),
    };
    tx.set(collection.doc(auditDocID(seq)), stripUndefinedObject(doc));
    return { ...core, hash };
  });
}

/**
 * getAuditLog — page the chain in ascending chain order. The cursor is the next
 * `seq` to read (opaque to clients beyond "pass it back to continue").
 */
export const getAuditLog = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler(
    "getAuditLog",
    async (request: CallableRequest<{ cursor?: unknown; limit?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in to view your access audit timeline.");
      enforceAuthAndAppCheck(request, uid);

      const limit = requireBoundedNumber(request.data?.limit ?? 50, "limit", 1, 200);
      const cursor = request.data?.cursor == null ? 0 : requireBoundedNumber(request.data.cursor, "cursor", 0, 2 ** 50);

      const snap = await db
        .collection(`users/${uid}/${AUDIT_LOG_COLLECTION}`)
        .orderBy("seq", "asc")
        .where("seq", ">=", cursor)
        .limit(limit)
        .get();

      const events = snap.docs.map((doc) => {
        const data = doc.data();
        return {
          seq: Number(data.seq ?? 0),
          ts: typeof data.ts === "string" ? data.ts : "",
          actor: typeof data.actor === "string" ? data.actor : "",
          action: typeof data.action === "string" ? data.action : "",
          domain: typeof data.domain === "string" ? data.domain : "",
          prevHash: typeof data.prevHash === "string" ? data.prevHash : "",
          hash: typeof data.hash === "string" ? data.hash : "",
        };
      });

      const nextCursor = snap.size === limit ? (events[events.length - 1].seq + 1) : undefined;
      return stripUndefinedObject({ ok: true, events, nextCursor });
    },
  ),
);

/**
 * verifyAuditLog — walk the whole chain and confirm every link. Reports
 * `valid:false` plus the first broken seq if a prevHash link or a recomputed
 * hash mismatches (server-side tamper), or if a seq is skipped/duplicated.
 */
export const verifyAuditLog = onCall(
  CALLABLE_OPTS,
  wrapCallableHandler("verifyAuditLog", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to verify your access audit timeline.");
    enforceAuthAndAppCheck(request, uid);

    let prevHash = AUDIT_GENESIS_PREV_HASH;
    let expectedSeq = 0;
    let cursor = 0;
    const pageSize = 500;

    for (;;) {
      const snap = await db
        .collection(`users/${uid}/${AUDIT_LOG_COLLECTION}`)
        .orderBy("seq", "asc")
        .where("seq", ">=", cursor)
        .limit(pageSize)
        .get();
      if (snap.empty) break;

      for (const doc of snap.docs) {
        const data = doc.data();
        const seq = Number(data.seq);
        const core: AuditEventCore = {
          seq,
          ts: typeof data.ts === "string" ? data.ts : "",
          actor: typeof data.actor === "string" ? data.actor : "",
          action: typeof data.action === "string" ? data.action : "",
          domain: typeof data.domain === "string" ? data.domain : "",
          prevHash: typeof data.prevHash === "string" ? data.prevHash : "",
        };
        const storedHash = typeof data.hash === "string" ? data.hash : "";
        if (seq !== expectedSeq || core.prevHash !== prevHash || computeAuditHash(core) !== storedHash) {
          return { ok: true, valid: false, brokenAt: Number.isFinite(seq) ? seq : expectedSeq };
        }
        prevHash = storedHash;
        expectedSeq += 1;
      }

      if (snap.size < pageSize) break;
      cursor = expectedSeq;
    }

    return { ok: true, valid: true };
  }),
);

/** Action-name constants so every appender uses the same vocabulary. */
export const AUDIT_ACTIONS = {
  dataExport: "data.export",
  domainDelete: "data.delete",
  recoverySetup: "recovery.setup",
  recoveryConfirm: "recovery.confirm",
  panicRevoke: "access.revoke_all",
  browserEscrowRegister: "escrow.browser_register",
} as const;

/** Resolve a stable actor label for audit events from the callable request. */
/**
 * The actor is ALWAYS the authenticated user — every event is written server-side
 * under users/{uid}/, so identity is trustworthy and not client-assertable. The
 * `x-burnbar-platform` suffix is a SELF-REPORTED device hint only (web/ios/macos),
 * never an identity claim; clamp it to a safe charset so a spoofed header cannot
 * inject control characters or markup into the audit display.
 */
export function auditActorLabel(request: CallableRequest): string {
  const raw = boundedTrimmedString(request.rawRequest?.headers?.["x-burnbar-platform"], "platform", 40, false);
  const hint = raw ? raw.replace(/[^A-Za-z0-9._-]/g, "").slice(0, 40) : "";
  return hint ? `user:${hint}` : "user";
}
