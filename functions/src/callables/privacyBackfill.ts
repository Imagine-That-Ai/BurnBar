/**
 * @fileoverview Idempotent privacy backfill — strips legacy plaintext fields
 * from cloud docs ONCE a sealed copy exists, and bumps a per-user reseal
 * watermark so native clients re-seal any surface that needs a fresh sealed
 * copy on their next sync.
 *
 * This is the migration arm of the privacy-leak remediation. It is deliberately
 * SAFE-BY-CONSTRUCTION and idempotent:
 *
 *  1. A legacy plaintext field is deleted ONLY when the doc already carries the
 *     sealed field that supersedes it (the `requires` gate). We never strip a
 *     plaintext value that has no sealed replacement, so no data is lost in the
 *     window before a device has re-sealed — the legacy doc still renders.
 *     Two explicit, reviewed exceptions exist:
 *       (a) a documented retire-only field whose current writers omit it and
 *           whose rules now reject it (`ungatedReason`), and
 *       (b) Hermes Gateway RELAYED content (`gatewayRelayed`). Gateway docs are
 *           server-written and relayed end-to-end; the server never holds an
 *           entitled sealed copy, so its plaintext sibling is pure leak and is
 *           stripped for both sealed and legacy docs. The previous
 *           `requires:"relayEnvelope"` gate was a structural no-op for legacy
 *           schema<2 server docs (they never gain a relayEnvelope), leaving the
 *           plaintext stored AND served forever — the audit BLOCKER this closes.
 *  2. Re-running is a no-op once a doc is clean (the gated fields are absent),
 *     so the scheduled sweep and any manual run converge to the same fixed point.
 *  3. The reseal watermark (`privacy_reseal_state/current.resealEpoch`) is bumped
 *     to the current epoch the FIRST time a user is swept, signalling native
 *     clients (which compare their last-applied epoch) to re-seal any surface
 *     that has no sealed copy yet. This is how project memory / chat mirrors get
 *     a sealed copy written so a later sweep can drop their plaintext.
 *
 * Disjoint from the `scrub-chat-cloud-plaintext.mjs` operator script: that one is
 * an unconditional admin scrub for incident response; this runs in-product,
 * owner-scoped, and is gated on "sealed copy exists" so it is always safe to run.
 */

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import type {
  CollectionReference,
  DocumentReference,
  Firestore,
  QueryDocumentSnapshot,
} from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";

import { db } from "../adminRuntime.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { HERMES_GATEWAY_SCHEMA_VERSION } from "../hermesGateway.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

/**
 * Current reseal epoch. Bump this when a NEW sealed surface ships that needs the
 * fleet to re-seal legacy docs; native clients that recorded a lower epoch will
 * re-seal on next sync. Keep in lockstep with the client watermark check.
 */
export const PRIVACY_RESEAL_EPOCH = 2;

/** A legacy plaintext field and the sealed field whose presence gates its deletion. */
interface GatedField {
  /** The legacy plaintext field to delete. */
  readonly field: string;
  /**
   * Delete `field` only when this sealed field is present on the same doc.
   */
  readonly requires?: string;
  /**
   * Required when `requires` is omitted: explains why deleting this field cannot
   * remove live cross-device functionality. Keep this list tiny and reviewed.
   */
  readonly ungatedReason?: string;
  /**
   * Hermes Gateway relayed content (text / senderDisplayName / threadId /
   * fileName). Gateway docs are SERVER-WRITTEN and RELAYED, not vault-sealed on
   * the server: the readable content lives end-to-end between the phone and the
   * agent, sealed inside `relayEnvelope`. The server is never the entitled holder
   * of a readable copy, so its plaintext sibling is pure leak with no sealed
   * server replacement to wait for.
   *
   * The original `requires: "relayEnvelope"` gate was a STRUCTURAL NO-OP for the
   * exact leak: legacy schema<2 gateway docs were written server-side and never
   * gain a `relayEnvelope`, so the gate never fired and the plaintext was stored
   * AND served (serializeHermesGatewayEvent schema-1 fallback) forever until an
   * operator hand-ran the scrubber (audit BLOCKER, privacyBackfill.ts:169 / 234).
   *
   * `gatewayRelayed` deletes the plaintext whenever the doc is either:
   *   • sealed   — carries a `relayEnvelope` OR advertises schemaVersion >= 2
   *                (matches the read-path "isSealedDoc" predicate in
   *                hermesGateway.ts), or
   *   • legacy   — has no/old schemaVersion (< HERMES_GATEWAY_SCHEMA_VERSION).
   * Those two cases partition every gateway doc, so the effect is "always strip
   * the relayed plaintext," which is correct precisely because the server holds
   * no entitled sealed copy of relayed content. Encoded as an explicit gate (not
   * a bare ungated delete) so the safety argument is reviewed and test-asserted.
   */
  readonly gatewayRelayed?: boolean;
}

/** One top-level collection's legacy plaintext fields, each with its sealed gate. */
interface CollectionPlan {
  readonly collection: string;
  readonly fields: readonly GatedField[];
}

/**
 * The sealable surfaces. Each plaintext field is deleted only once its sealed
 * replacement is present, so a partially-migrated doc keeps rendering until the
 * device has written the sealed copy. Mirrors CONTRACT §1/§2/§7/§8 plus the
 * Hermes Square W3 sealed surfaces.
 */
const COLLECTION_PLANS: readonly CollectionPlan[] = [
  // §1 usage / budget project text → sealedProjectName / sealedLabel.
  { collection: "usage", fields: [{ field: "projectName", requires: "sealedProjectName" }] },
  {
    collection: "budgetRules",
    fields: [
      { field: "projectName", requires: "sealedProjectName" },
      { field: "label", requires: "sealedLabel" },
    ],
  },
  {
    collection: "budgetEvents",
    fields: [
      {
        field: "detailJSON",
        ungatedReason: "retired local-only diagnostic detail; current cloud writers omit it and rules reject it",
      },
    ],
  },
  // §7 chat mirrors → sealedPayload. Top-level customTitle/title/preview are
  // dropped once the whole record is sealed.
  {
    collection: "mobile_assistant_chats",
    fields: [
      { field: "customTitle", requires: "sealedPayload" },
      { field: "title", requires: "sealedPayload" },
      { field: "preview", requires: "sealedPayload" },
    ],
  },
  {
    collection: "cli_sessions",
    fields: [
      { field: "customTitle", requires: "sealedPayload" },
      { field: "title", requires: "sealedPayload" },
      { field: "preview", requires: "sealedPayload" },
    ],
  },
  {
    collection: "chat_threads",
    fields: [
      { field: "title", requires: "sealedPayload" },
      { field: "preview", requires: "sealedPayload" },
      { field: "messages", requires: "sealedPayload" },
    ],
  },
  // §2 project memory: projectDisplayName/projectSlug are pure duplication of
  // data already inside the always-present sealed snapshot; delete once sealed.
  {
    collection: "project_memory_snapshots",
    fields: [
      { field: "projectDisplayName", requires: "sealedSnapshot" },
      { field: "projectSlug", requires: "sealedSnapshot" },
    ],
  },
  {
    collection: "approval_policies",
    fields: [
      { field: "id", requires: "sealedDisplayLabel" },
      { field: "displayLabel", requires: "sealedDisplayLabel" },
      { field: "fileGlob", requires: "sealedFileGlob" },
      { field: "targetProject", requires: "sealedTargetProject" },
    ],
  },
  {
    collection: "rollback_requests",
    fields: [
      { field: "scopeJSON", requires: "sealedScope" },
      { field: "errorMessage", requires: "sealedErrorMessage" },
    ],
  },
  {
    collection: "agent_identities",
    fields: [
      { field: "displayName", requires: "sealedDisplayName" },
      { field: "tagline", requires: "sealedTagline" },
      { field: "personas", requires: "sealedPersonas" },
    ],
  },
  {
    collection: "subscription_topics",
    fields: [
      { field: "agentURI", requires: "sealedAgentURI" },
      { field: "topicID", requires: "sealedTopicID" },
      { field: "displayName", requires: "sealedDisplayName" },
      { field: "description", requires: "sealedDescription" },
    ],
  },
  // §gateway Hermes Gateway relayed content. Deletion is NOT gated on a sealed
  // server copy (the server never holds one) — see GatedField.gatewayRelayed.
  // This closes the audit BLOCKER where `requires:"relayEnvelope"` never fired
  // for legacy schema<2 server-written docs, leaving plaintext stored + served.
  {
    collection: "hermes_gateway_events",
    fields: [
      { field: "text", gatewayRelayed: true },
      { field: "senderDisplayName", gatewayRelayed: true },
      { field: "threadId", gatewayRelayed: true },
    ],
  },
  {
    collection: "hermes_gateway_messages",
    fields: [
      { field: "text", gatewayRelayed: true },
      { field: "threadId", gatewayRelayed: true },
      { field: "replyToEventId", gatewayRelayed: true },
    ],
  },
  {
    collection: "hermes_gateway_attachments",
    fields: [{ field: "fileName", gatewayRelayed: true }],
  },
  {
    collection: "media_attachment_manifests",
    fields: [{ field: "filename", requires: "sealedFilename" }],
  },
];

/** §4 knowledge_repos: cleartext repoFullName is dropped once the sealed name exists. */
const KNOWLEDGE_REPO_FIELDS: readonly GatedField[] = [{ field: "repoFullName", requires: "sealedRepoFullName" }];

const ROLLBACK_SNAPSHOT_FIELDS: readonly GatedField[] = [
  { field: "actionLabel", requires: "sealedActionLabel" },
  { field: "touchedFiles", requires: "sealedTouchedFiles" },
  { field: "macSnapshotPath", requires: "sealedMacSnapshotPath" },
];

/**
 * True for a Hermes Gateway doc whose relayed plaintext may be stripped: either
 * it is SEALED (carries a `relayEnvelope` OR advertises schemaVersion >= the
 * current gateway schema) or it is LEGACY (no/old schemaVersion). These two
 * cases partition every gateway doc, so this returns true for all of them —
 * which is correct because the server is never the entitled holder of a readable
 * copy of relayed content (see GatedField.gatewayRelayed). Kept explicit rather
 * than a constant `true` so the sealed and legacy branches are both test-visible
 * and a future schema change can re-tighten one branch without touching callers.
 */
export function gatewayRelayedPlaintextStrippable(data: Record<string, unknown>): boolean {
  const hasRelayEnvelope = Object.prototype.hasOwnProperty.call(data, "relayEnvelope");
  const schemaVersion = typeof data.schemaVersion === "number" ? data.schemaVersion : NaN;
  const isSealed = hasRelayEnvelope || schemaVersion >= HERMES_GATEWAY_SCHEMA_VERSION;
  const isLegacy = !(schemaVersion >= HERMES_GATEWAY_SCHEMA_VERSION);
  return isSealed || isLegacy;
}

/**
 * Pure gating decision: which gated plaintext fields on a doc may be deleted
 * (the sealed gate is satisfied and the field is present). Exported for tests so
 * the safe-by-construction property is asserted without a live Firestore.
 */
export function gatedDeletions(data: Record<string, unknown>, fields: readonly GatedField[]): string[] {
  const deletions: string[] = [];
  for (const { field, requires, gatewayRelayed } of fields) {
    if (!Object.prototype.hasOwnProperty.call(data, field)) continue;
    if (gatewayRelayed) {
      // Relayed gateway content: strip the plaintext for sealed AND legacy docs;
      // the server holds no sealed copy to preserve. Never blocks on a `requires`
      // gate (legacy docs would never satisfy one — the original NO-OP bug).
      if (!gatewayRelayedPlaintextStrippable(data)) continue;
      deletions.push(field);
      continue;
    }
    if (requires && !Object.prototype.hasOwnProperty.call(data, requires)) continue;
    deletions.push(field);
  }
  return deletions;
}

interface BackfillStats {
  scannedDocs: number;
  updatedDocs: number;
  deletedFields: number;
  resealBumped: boolean;
}

function emptyStats(): BackfillStats {
  return { scannedDocs: 0, updatedDocs: 0, deletedFields: 0, resealBumped: false };
}

function mergeStats(into: BackfillStats, from: BackfillStats): void {
  into.scannedDocs += from.scannedDocs;
  into.updatedDocs += from.updatedDocs;
  into.deletedFields += from.deletedFields;
  into.resealBumped = into.resealBumped || from.resealBumped;
}

/**
 * Sweep a single collection: for each doc, delete every gated plaintext field
 * whose sealed gate is satisfied. Returns per-collection stats.
 */
async function sweepCollection(
  ref: CollectionReference,
  fields: readonly GatedField[],
  stats: BackfillStats,
): Promise<void> {
  const docs = await ref.listDocuments();
  for (const docRef of docs) {
    await sweepDocument(docRef, fields, stats);
  }
}

async function sweepDocument(
  docRef: DocumentReference,
  fields: readonly GatedField[],
  stats: BackfillStats,
): Promise<void> {
  const snap = await docRef.get();
  if (!snap.exists) return;
  stats.scannedDocs += 1;
  const data = (snap.data() ?? {}) as Record<string, unknown>;
  const toDelete = gatedDeletions(data, fields);
  if (toDelete.length === 0) return;
  const update: Record<string, FieldValue> = {};
  for (const field of toDelete) update[field] = FieldValue.delete();
  await docRef.update(update);
  stats.updatedDocs += 1;
  stats.deletedFields += toDelete.length;
}

/**
 * Bump the reseal watermark so native clients re-seal surfaces that still lack a
 * sealed copy. Idempotent: only advances the epoch (never lowers it), and only
 * writes when the stored epoch is behind the current one.
 */
async function bumpResealWatermark(firestore: Firestore, uid: string, stats: BackfillStats): Promise<void> {
  const ref = firestore.doc(`users/${uid}/privacy_reseal_state/current`);
  const snap = await ref.get();
  const stored = snap.exists ? Number(snap.get("resealEpoch") ?? 0) : 0;
  if (Number.isFinite(stored) && stored >= PRIVACY_RESEAL_EPOCH) return;
  await ref.set({ resealEpoch: PRIVACY_RESEAL_EPOCH, updatedAt: Timestamp.now(), schemaVersion: 1 }, { merge: true });
  stats.resealBumped = true;
}

/** Run the full idempotent backfill for a single user. */
export async function backfillUserPrivacy(firestore: Firestore, uid: string): Promise<BackfillStats> {
  const stats = emptyStats();
  const userRef = firestore.collection("users").doc(uid);

  for (const plan of COLLECTION_PLANS) {
    await sweepCollection(userRef.collection(plan.collection), plan.fields, stats);
  }

  // knowledge_repos is keyed by an opaque repo id; sweep each doc directly.
  await sweepCollection(userRef.collection("knowledge_repos"), KNOWLEDGE_REPO_FIELDS, stats);

  const cliSessions = await userRef.collection("cli_sessions").listDocuments();
  for (const sessionRef of cliSessions) {
    await sweepCollection(sessionRef.collection("snapshots"), ROLLBACK_SNAPSHOT_FIELDS, stats);
  }

  await bumpResealWatermark(firestore, uid, stats);
  return stats;
}

/**
 * Owner-scoped callable. Idempotent: safe to call repeatedly (e.g. from the
 * Data & Privacy Control Center "tidy my cloud" affordance or after an upgrade).
 */
export const backfillPrivacyPlaintext = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
    timeoutSeconds: 300,
  },
  wrapCallableHandler("backfillPrivacyPlaintext", async (request: CallableRequest<void>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before running the privacy backfill.");
    }
    enforceAuthAndAppCheck(request, uid);

    const stats = await backfillUserPrivacy(db, uid);
    logInfo({
      event: "callable_info",
      message: "privacy plaintext backfill (callable)",
      ...stats,
    });
    return { ok: true, ...stats, resealEpoch: PRIVACY_RESEAL_EPOCH };
  }),
);

/**
 * Daily backstop. Walks a bounded page of users and runs the same idempotent
 * backfill so accounts converge to "no legacy plaintext where a sealed copy
 * exists" without requiring each client to invoke the callable.
 */
export const backfillPrivacyPlaintextScheduled = onSchedule(
  {
    region: FUNCTIONS_REGION,
    schedule: "every 24 hours",
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async () => {
    const startedAt = Date.now();
    const totals = emptyStats();
    let usersScanned = 0;
    let usersResealBumped = 0;
    let cursor: QueryDocumentSnapshot | undefined;
    let exhausted = false;
    while (Date.now() - startedAt < 500_000) {
      let query = db.collection("users").orderBy("__name__").limit(500);
      if (cursor) query = query.startAfter(cursor);
      const users = await query.get();
      if (users.empty) {
        exhausted = true;
        break;
      }
      for (const user of users.docs) {
        usersScanned += 1;
        const stats = await backfillUserPrivacy(db, user.id);
        if (stats.resealBumped) usersResealBumped += 1;
        mergeStats(totals, stats);
      }
      cursor = users.docs.at(-1);
      if (users.size < 500) {
        exhausted = true;
        break;
      }
    }
    logInfo({
      event: "callable_info",
      message: "privacy plaintext backfill (scheduled)",
      usersScanned,
      exhausted,
      nextUserCursor: exhausted ? undefined : cursor?.id,
      usersResealBumped,
      scannedDocs: totals.scannedDocs,
      updatedDocs: totals.updatedDocs,
      deletedFields: totals.deletedFields,
    });
  },
);

/** Test-only surface: the gating decision + the surface plans. */
export const __testing__ = {
  gatedDeletions,
  gatewayRelayedPlaintextStrippable,
  COLLECTION_PLANS,
  KNOWLEDGE_REPO_FIELDS,
  ROLLBACK_SNAPSHOT_FIELDS,
  PRIVACY_RESEAL_EPOCH,
  HERMES_GATEWAY_SCHEMA_VERSION,
  backfillUserPrivacy,
};
