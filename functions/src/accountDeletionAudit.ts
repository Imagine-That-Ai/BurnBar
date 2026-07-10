/**
 * Durable account-erasure receipts retained outside the deleted user tree.
 */

import { createHash } from "node:crypto";
import { AUDIT_ACTIONS, computeAuditHash, type AuditEventCore } from "./callables/auditLog.js";
import { ACCOUNT_ERASURE_TOMBSTONE_COLLECTION } from "./accountErasureConstants.js";

export { ACCOUNT_ERASURE_TOMBSTONE_COLLECTION } from "./accountErasureConstants.js";

interface AccountDeletionCollection {
  listDocuments(): Promise<AccountDeletionDocumentReference[]>;
}

interface AccountDeletionDocumentReference {
  readonly path?: string;
  listCollections(): Promise<AccountDeletionCollection[]>;
  get?(): Promise<AccountDeletionDocumentSnapshot>;
  set?(data: Record<string, unknown>, options?: { merge?: boolean }): Promise<unknown>;
}

interface AccountDeletionDocumentSnapshot {
  readonly exists: boolean;
  get(field: string): unknown;
}

interface AccountDeletionWriteBatch {
  create?(ref: AccountDeletionDocumentReference, data: Record<string, unknown>): void;
  delete(ref: AccountDeletionDocumentReference): void;
  set?(ref: AccountDeletionDocumentReference, data: Record<string, unknown>, options?: { merge?: boolean }): void;
  commit(): Promise<unknown>;
}

interface AccountDeletionFirestore {
  doc(path: string): AccountDeletionDocumentReference;
  batch(): AccountDeletionWriteBatch;
}

interface AccountDeletionAudit {
  actor: string;
  domain: string;
}

const ACCOUNT_ERASURE_AUDIT_COLLECTION = "account_erasure_audit";
const ACCOUNT_ERASURE_AUDIT_SCHEMA_VERSION = 2;

const RESUMABLE_ACCOUNT_ERASURE_STATUSES = new Set([
  "intent_recorded",
  "external_cleanup_incomplete",
  "cloud_data_cleanup_failed",
  "cloud_data_deleted",
  "auth_delete_failed",
  "session_revoke_failed",
]);

interface RetainedAuditEvent extends AuditEventCore {
  hash: string;
}

export function verifyRetainedAccountErasureEvents(
  events: readonly RetainedAuditEvent[],
  retainedHeadHash: string,
): boolean {
  if (events.length !== 2) return false;
  const [intent, completion] = events;
  if (!intent || !completion) return false;
  if (intent.action !== AUDIT_ACTIONS.accountDeleteIntent) return false;
  if (completion.action !== AUDIT_ACTIONS.accountDeleteComplete) return false;
  if (completion.seq !== intent.seq + 1 || completion.prevHash !== intent.hash) return false;
  return (
    computeAuditHash(intent) === intent.hash &&
    computeAuditHash(completion) === completion.hash &&
    completion.hash === retainedHeadHash
  );
}

function accountErasureAuditDocumentID(uid: string): string {
  return createHash("sha256").update(uid, "utf8").digest("hex");
}

function accountErasureAuditRef(db: AccountDeletionFirestore, uid: string): AccountDeletionDocumentReference {
  return db.doc(`${ACCOUNT_ERASURE_AUDIT_COLLECTION}/${accountErasureAuditDocumentID(uid)}`);
}

function accountErasureAuditEventRef(
  db: AccountDeletionFirestore,
  uid: string,
  eventID: "intent" | "completion",
): AccountDeletionDocumentReference {
  return db.doc(`${ACCOUNT_ERASURE_AUDIT_COLLECTION}/${accountErasureAuditDocumentID(uid)}/events/${eventID}`);
}

/**
 * A server-only nonterminal audit record proves the same authenticated uid
 * already authorized erasure after a partial cleanup removed device proofs.
 */
export async function isAccountErasureResumable(db: AccountDeletionFirestore, uid: string): Promise<boolean> {
  if (!uid.trim()) return false;
  const ref = accountErasureAuditRef(db, uid);
  if (typeof ref.get !== "function") {
    throw new Error("Account erasure audit reference does not support get().");
  }
  const snapshot = await ref.get();
  if (!snapshot.exists) return false;
  if (snapshot.get("schemaVersion") !== ACCOUNT_ERASURE_AUDIT_SCHEMA_VERSION) return false;
  const status = snapshot.get("status");
  return typeof status === "string" && RESUMABLE_ACCOUNT_ERASURE_STATUSES.has(status);
}

export async function requireResumableAccountErasure(db: AccountDeletionFirestore, uid: string): Promise<void> {
  if (!(await isAccountErasureResumable(db, uid))) {
    throw new Error("Account erasure cannot resume without a schema-v2 nonterminal receipt.");
  }
}

export async function requireFreshAccountErasure(db: AccountDeletionFirestore, uid: string): Promise<void> {
  const ref = accountErasureAuditRef(db, uid);
  if (typeof ref.get !== "function") throw new Error("Account erasure audit reference does not support get().");
  const snapshot = await ref.get();
  if (snapshot.exists) {
    throw new Error(
      "An account-erasure receipt already exists. Legacy, terminal, and malformed receipts require operator review and cannot be overwritten.",
    );
  }
}

function retainedAuditEvent(result: unknown): RetainedAuditEvent {
  if (!isRecord(result)) throw new Error("Account erasure audit append did not return a canonical event.");
  const candidate: RetainedAuditEvent = {
    seq: typeof result.seq === "number" ? result.seq : Number.NaN,
    ts: typeof result.ts === "string" ? result.ts : "",
    actor: typeof result.actor === "string" ? result.actor : "",
    action: typeof result.action === "string" ? result.action : "",
    domain: typeof result.domain === "string" ? result.domain : "",
    prevHash: typeof result.prevHash === "string" ? result.prevHash : "",
    hash: typeof result.hash === "string" ? result.hash : "",
  };
  if (
    !Number.isSafeInteger(candidate.seq) ||
    candidate.seq < 0 ||
    !candidate.ts ||
    !candidate.actor ||
    !candidate.action ||
    !candidate.domain ||
    !/^[a-f0-9]{64}$/u.test(candidate.hash) ||
    computeAuditHash(candidate) !== candidate.hash
  ) {
    throw new Error("Account erasure audit append returned an unverifiable canonical event.");
  }
  return candidate;
}

export async function writeAccountErasureAuditIntent(
  db: AccountDeletionFirestore,
  uid: string,
  audit: AccountDeletionAudit,
  intentAudit: unknown,
): Promise<void> {
  const now = new Date().toISOString();
  const retainedIntentEvent = retainedAuditEvent(intentAudit);
  const receipt = {
    schemaVersion: ACCOUNT_ERASURE_AUDIT_SCHEMA_VERSION,
    uidHash: accountErasureAuditDocumentID(uid),
    status: "intent_recorded",
    actor: audit.actor,
    domain: audit.domain,
    intentAction: AUDIT_ACTIONS.accountDeleteIntent,
    completionAction: AUDIT_ACTIONS.accountDeleteComplete,
    intentRecordedAt: now,
    updatedAt: now,
    retainedIntentEvent,
    retainedHeadHash: retainedIntentEvent.hash,
    retainedMaxSeq: retainedIntentEvent.seq,
  };
  const batch = db.batch();
  if (typeof batch.create !== "function") throw new Error("Account erasure batch does not support create().");
  batch.create(accountErasureAuditRef(db, uid), receipt);
  batch.create(accountErasureAuditEventRef(db, uid, "intent"), {
    schemaVersion: ACCOUNT_ERASURE_AUDIT_SCHEMA_VERSION,
    eventKind: "intent",
    uidHash: accountErasureAuditDocumentID(uid),
    ...retainedIntentEvent,
  });
  await batch.commit();
}

export async function writeAccountErasureCompletionRequired(
  db: AccountDeletionFirestore,
  uid: string,
  audit: AccountDeletionAudit,
  outcome: "account_deleted" | "auth_user_already_missing",
): Promise<void> {
  const ref = accountErasureAuditRef(db, uid);
  if (typeof ref.get !== "function") throw new Error("Account erasure audit reference does not support get().");
  const snapshot = await ref.get();
  const intent = retainedAuditEvent(snapshot.get("retainedIntentEvent"));
  const core: AuditEventCore = {
    seq: intent.seq + 1,
    ts: new Date().toISOString(),
    actor: audit.actor,
    action: AUDIT_ACTIONS.accountDeleteComplete,
    domain: audit.domain,
    prevHash: intent.hash,
  };
  const retainedCompletionEvent: RetainedAuditEvent = { ...core, hash: computeAuditHash(core) };
  const batch = db.batch();
  if (typeof batch.create !== "function" || typeof batch.set !== "function") {
    throw new Error("Account erasure completion batch lacks atomic create/set support.");
  }
  batch.create(accountErasureAuditEventRef(db, uid, "completion"), {
    schemaVersion: ACCOUNT_ERASURE_AUDIT_SCHEMA_VERSION,
    eventKind: "completion",
    uidHash: accountErasureAuditDocumentID(uid),
    outcome,
    ...retainedCompletionEvent,
  });
  batch.set(
    ref,
    {
      status: outcome,
      retryRequired: false,
      retainedCompletionEvent,
      retainedHeadHash: retainedCompletionEvent.hash,
      retainedMaxSeq: retainedCompletionEvent.seq,
      completionOutcome: outcome,
      completionRecordedAt: retainedCompletionEvent.ts,
      ...(outcome === "account_deleted"
        ? { authDeletedAt: retainedCompletionEvent.ts }
        : { authDeleteObservedAt: retainedCompletionEvent.ts }),
      updatedAt: retainedCompletionEvent.ts,
    },
    { merge: true },
  );
  batch.set(
    accountErasureTombstoneRef(db, uid),
    { pending: false, completedAt: retainedCompletionEvent.ts, updatedAt: retainedCompletionEvent.ts },
    { merge: true },
  );
  await batch.commit();
}

function accountErasureTombstoneRef(db: AccountDeletionFirestore, uid: string): AccountDeletionDocumentReference {
  return db.doc(`${ACCOUNT_ERASURE_TOMBSTONE_COLLECTION}/${uid}`);
}

export async function ensureAccountErasureTombstone(db: AccountDeletionFirestore, uid: string): Promise<void> {
  const ref = accountErasureTombstoneRef(db, uid);
  if (typeof ref.set !== "function") throw new Error("Account erasure tombstone does not support set().");
  const now = new Date().toISOString();
  await ref.set(
    {
      schemaVersion: ACCOUNT_ERASURE_AUDIT_SCHEMA_VERSION,
      uidHash: accountErasureAuditDocumentID(uid),
      pending: true,
      updatedAt: now,
      createdAt: now,
    },
    { merge: true },
  );
}

export async function updateAccountErasureAuditBestEffort(
  db: AccountDeletionFirestore,
  uid: string,
  patch: Record<string, unknown>,
): Promise<void> {
  try {
    await mergeAccountErasureAudit(db, uid, {
      ...patch,
      updatedAt: new Date().toISOString(),
    });
  } catch {
    // The fail-closed intent is durable. Later status updates improve operator
    // forensics but must not resurrect or block account erasure.
  }
}

export async function updateAccountErasureAuditRequired(
  db: AccountDeletionFirestore,
  uid: string,
  patch: Record<string, unknown>,
): Promise<void> {
  await mergeAccountErasureAudit(db, uid, {
    ...patch,
    updatedAt: new Date().toISOString(),
  });
}

async function mergeAccountErasureAudit(
  db: AccountDeletionFirestore,
  uid: string,
  data: Record<string, unknown>,
): Promise<void> {
  const ref = accountErasureAuditRef(db, uid);
  if (typeof ref.set !== "function") {
    throw new Error("Account erasure audit reference does not support set().");
  }
  await ref.set(stripUndefined(data), { merge: true });
}

function stripUndefined(value: Record<string, unknown>): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    if (item !== undefined) result[key] = item;
  }
  return result;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
