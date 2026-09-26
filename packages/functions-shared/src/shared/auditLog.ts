/**
 * @fileoverview Tamper-evident audit-log core: hash-chain helpers, append,
 * verify, OTS anchoring, and action vocabulary. Moved from callables/auditLog
 * (3.5 shared runtime); the deployed `getAuditLog`/`verifyAuditLog` callables
 * stay in callables/auditLog.ts and import this module.
 */

import { Timestamp } from "firebase-admin/firestore";
import { type CallableRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { logError, logInfo } from "../logging.js";
import { stripUndefinedObject } from "../guards.js";
import { boundedTrimmedString, sha256Hex } from "./validators.js";
import { runOtsStamp } from "./otsStamping.js";


const AUDIT_LOG_SCHEMA_VERSION = 1;
export const AUDIT_LOG_COLLECTION = "unified_audit_log";
/** Per-user collection holding the single `head` doc that pins the chain length. */
const AUDIT_META_COLLECTION = "audit_meta";
/** Doc id of the head pointer inside {@link AUDIT_META_COLLECTION}. */
const AUDIT_META_HEAD_DOC = "head";
/** Genesis prevHash: the empty-string sentinel for the first chain link. */
export const AUDIT_GENESIS_PREV_HASH = "";

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

/** Firestore ref for the per-user head pointer (transactional length anchor). */
function auditHeadRef(uid: string) {
  return db.doc(`users/${uid}/${AUDIT_META_COLLECTION}/${AUDIT_META_HEAD_DOC}`);
}

/**
 * The persisted shape of `audit_meta/head`. `maxSeq` / `headHash` move forward
 * on every append; the `anchored*` fields are stamped by the daily OTS anchor.
 */
export interface AuditHead {
  maxSeq: number;
  headHash: string;
  /** Highest seq covered by a committed OpenTimestamps proof (or -1 if none). */
  anchoredSeq?: number;
  anchoredHash?: string;
  anchoredOtsProofBase64?: string;
}

/**
 * Append one event to the user's tamper-evident audit chain inside a
 * transaction (so concurrent appends can't fork the chain) and advance
 * `audit_meta/head` in the SAME transaction, so a tail delete leaves
 * `head.maxSeq` pointing past the surviving rows (a detectable gap). Returns the
 * committed event including its hash + seq.
 *
 * This function THROWS on failure. Best-effort callers (non-irreversible
 * actions) wrap it in try/catch; irreversible actions must instead use
 * {@link appendAuditEventRequired}, which refuses the action when the audit
 * write fails.
 */
export async function appendAuditEvent(
  uid: string,
  event: { actor: string; action: string; domain: string },
): Promise<AuditEvent> {
  const collection = db.collection(`users/${uid}/${AUDIT_LOG_COLLECTION}`);
  const headRef = auditHeadRef(uid);
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
    // Same-transaction head advance: monotonic length pin for truncation detection.
    tx.set(
      headRef,
      { maxSeq: seq, headHash: hash, schemaVersion: AUDIT_LOG_SCHEMA_VERSION, updatedAt: Timestamp.now() },
      { merge: true },
    );
    return { ...core, hash };
  });
}

/**
 * Fail-CLOSED append for IRREVERSIBLE actions (data.export, access.revoke_all,
 * recovery.confirm). Semantically identical write to {@link appendAuditEvent},
 * but named to make the contract explicit at the call site: callers must NOT
 * wrap it in try/catch. If the audit write fails the error propagates and the
 * action is refused, so a server can never silently suppress the record of an
 * irreversible privacy operation.
 */
export async function appendAuditEventRequired(
  uid: string,
  event: { actor: string; action: string; domain: string },
): Promise<AuditEvent> {
  return appendAuditEvent(uid, event);
}


/** Outcome of {@link verifyAuditChain}: a broken link, a truncated tail, or valid. */
type AuditVerifyResult =
  | { valid: false; brokenAt: number; reason: "link" }
  | { valid: false; brokenAt: number; reason: "truncated"; expectedMaxSeq: number }
  | { valid: true; verifiedMaxSeq: number };

/**
 * Pure chain verifier. Walks `events` (already in ascending chain order) and
 * confirms every prevHash link + recomputed hash + contiguous seq. Then, given
 * the recorded `head`, asserts the chain reaches `max(maxSeq, anchoredSeq)` — so
 * a server that deletes the tail (leaving a self-consistent prefix) still FAILS
 * verification because the surviving chain stops short of the pinned/anchored
 * length. Kept side-effect-free so it is unit-testable without Firestore.
 */
export function verifyAuditChain(
  events: Array<AuditEventCore & { hash: string }>,
  head: AuditHead | null,
): AuditVerifyResult {
  let prevHash = AUDIT_GENESIS_PREV_HASH;
  let expectedSeq = 0;

  for (const event of events) {
    const core: AuditEventCore = {
      seq: event.seq,
      ts: event.ts,
      actor: event.actor,
      action: event.action,
      domain: event.domain,
      prevHash: event.prevHash,
    };
    if (core.seq !== expectedSeq || core.prevHash !== prevHash || computeAuditHash(core) !== event.hash) {
      return { valid: false, brokenAt: Number.isFinite(core.seq) ? core.seq : expectedSeq, reason: "link" };
    }
    prevHash = event.hash;
    expectedSeq += 1;
  }

  // Highest seq the surviving chain actually reached (-1 when empty).
  const reachedSeq = expectedSeq - 1;
  // The chain MUST cover both the transactional head pointer and any OTS anchor.
  const requiredSeq = Math.max(
    head && Number.isFinite(head.maxSeq) ? head.maxSeq : -1,
    head && typeof head.anchoredSeq === "number" && Number.isFinite(head.anchoredSeq) ? head.anchoredSeq : -1,
  );
  if (requiredSeq > reachedSeq) {
    return { valid: false, brokenAt: reachedSeq + 1, reason: "truncated", expectedMaxSeq: requiredSeq };
  }

  return { valid: true, verifiedMaxSeq: reachedSeq };
}

/** Read the per-user head pointer, or null when no events have been written. */
export async function readAuditHead(uid: string): Promise<AuditHead | null> {
  const snap = await auditHeadRef(uid).get();
  if (!snap.exists) return null;
  const data = snap.data() ?? {};
  return {
    maxSeq: typeof data.maxSeq === "number" ? data.maxSeq : -1,
    headHash: typeof data.headHash === "string" ? data.headHash : AUDIT_GENESIS_PREV_HASH,
    anchoredSeq: typeof data.anchoredSeq === "number" ? data.anchoredSeq : undefined,
    anchoredHash: typeof data.anchoredHash === "string" ? data.anchoredHash : undefined,
    anchoredOtsProofBase64: typeof data.anchoredOtsProofBase64 === "string" ? data.anchoredOtsProofBase64 : undefined,
  };
}

/**
 * verifyAuditLog — walk the whole chain and confirm every link, then assert the
 * chain reaches the recorded head / OTS anchor. Reports `valid:false` plus the
 * first broken seq if a prevHash link or a recomputed hash mismatches
 * (server-side tamper), if a seq is skipped/duplicated, or if the tail was
 * truncated below the anchored length (server-side suppression).
 */

/** Action-name constants so every appender uses the same vocabulary. */
export const AUDIT_ACTIONS = {
  dataExport: "data.export",
  /** @deprecated Use {@link domainDeleteIntent} + {@link domainDeleteComplete}. */
  domainDelete: "data.delete",
  domainDeleteIntent: "data.delete.intent",
  domainDeleteComplete: "data.delete.complete",
  accountDeleteIntent: "account.delete.intent",
  accountDeleteComplete: "account.delete.complete",
  recoverySetup: "recovery.setup",
  recoveryConfirm: "recovery.confirm",
  panicRevoke: "access.revoke_all",
  browserEscrowRegister: "escrow.browser_register",
  highRiskOwnerAction: "security.high_risk_owner_action",
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

/** Outcome of anchoring one user's head (logged by the daily sweep). */
type AuditAnchorOutcome = "anchored" | "already_anchored" | "no_head" | "ots_stamper_unavailable" | "ots_stamp_failed";

/**
 * Anchor one user's audit head: stamp `head.headHash` with OpenTimestamps and
 * record { anchoredSeq, anchoredHash, anchoredOtsProofBase64 } onto the head
 * doc. Reuses the existing OTS infra ({@link runOtsStamp}) — no new crypto. The
 * head hash IS the raw SHA-256 digest in hex, so stamping submits only the
 * 32-byte digest (chain content never leaves the device boundary).
 *
 * Idempotent: re-anchoring the same head returns `already_anchored`. When the
 * stamper is unavailable (no service URL and no local `ots` binary) it reports
 * `ots_stamper_unavailable` and advances nothing — the head pointer alone still
 * detects truncation; the OTS anchor hardens it against a colluding server.
 */
async function anchorAuditHead(uid: string): Promise<AuditAnchorOutcome> {
  const head = await readAuditHead(uid);
  if (!head || head.maxSeq < 0 || !head.headHash) return "no_head";
  if (head.anchoredSeq === head.maxSeq && head.anchoredHash === head.headHash) return "already_anchored";

  // The head hash is the lowercase hex of a SHA-256 digest → 32 raw bytes.
  const digest = Buffer.from(head.headHash, "hex");
  const stamp = await runOtsStamp(digest);
  if (stamp.status !== "stamped" || !stamp.proofBytes) {
    return stamp.status === "ots_stamper_unavailable" ? "ots_stamper_unavailable" : "ots_stamp_failed";
  }

  await auditHeadRef(uid).set(
    {
      anchoredSeq: head.maxSeq,
      anchoredHash: head.headHash,
      anchoredOtsProofBase64: stamp.proofBytes.toString("base64"),
      anchoredAt: Timestamp.now(),
    },
    { merge: true },
  );
  return "anchored";
}

/** Max per-user heads anchored per scheduled sweep (bounds runtime + OTS load). */
const AUDIT_ANCHOR_BATCH_LIMIT = 500;

/**
 * Daily sweep: anchor every user audit head that has advanced past its last OTS
 * anchor. Enumerates `audit_meta` head docs via a collection-group query and
 * stamps each one whose `maxSeq` moved since the last anchor. Best-effort per
 * user (one user's OTS failure never aborts the sweep); the head pointer keeps
 * truncation detectable even when anchoring is skipped.
 */
export async function anchorAuditHeads(): Promise<{ scanned: number; anchored: number }> {
  const snap = await db
    .collectionGroup(AUDIT_META_COLLECTION)
    .where("maxSeq", ">", -1)
    .limit(AUDIT_ANCHOR_BATCH_LIMIT)
    .get();

  let anchored = 0;
  for (const doc of snap.docs) {
    // Path: users/{uid}/audit_meta/head — only the head doc carries `maxSeq`.
    if (doc.id !== AUDIT_META_HEAD_DOC) continue;
    const uid = doc.ref.path.split("/")[1];
    if (!uid) continue;
    try {
      const outcome = await anchorAuditHead(uid);
      if (outcome === "anchored") anchored += 1;
    } catch (error) {
      logError({ event: "audit_anchor_failed", uid, error: String(error) });
    }
  }

  logInfo({ event: "audit_anchor_sweep", scanned: snap.size, anchored });
  return { scanned: snap.size, anchored };
}
