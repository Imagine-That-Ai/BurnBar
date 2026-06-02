/**
 * @fileoverview deleteDomainData — scoped, genuine deletion of one data domain.
 *
 * Removes every Firestore doc under the domain's `firestoreCollections` and every
 * Cloud Storage object under its `storagePrefixes`, derived from the canonical
 * registry path map (dataExport.ts → DATA_DOMAIN_PATHS, drift-guarded). For E2E
 * domains this is genuine ciphertext deletion (the only deletion that means
 * anything when the server never held the key).
 *
 * Reuses the Firestore batched-delete pattern (knowledgeMemory.ts deleteQueryInBatches)
 * and getStorage().bucket().deleteFiles for Cloud Storage prefixes. Appends a
 * tamper-evident audit event (auditLog.ts).
 *
 * Some domains are NOT client-deletable through this generic callable because
 * deletion would orphan server-managed state or destroy the keys that make
 * recovery possible — those route through their dedicated revoke/erase callables
 * instead (see UNDELETABLE_DOMAINS). The registry encodes which domains expose a
 * `delete` action; we enforce that here.
 */

import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import type { Query, WriteBatch } from "firebase-admin/firestore";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import { commitBatchedWrites } from "./shared.js";
import { DATA_DOMAIN_PATHS } from "./dataExport.js";
import { appendAuditEvent, auditActorLabel, AUDIT_ACTIONS } from "./auditLog.js";

/**
 * Domains whose deletion is intentionally NOT exposed through deleteDomainData.
 * These either have no registry `delete` action or must route through a
 * dedicated revoke/erase path to avoid orphaning server-managed state or
 * destroying recovery-critical keys:
 *   - provider_accounts / connected_devices / external_mcp: revoke callables
 *     (they also destroy Secret Manager material / cascade grants).
 *   - device_trust_keys: deleting the wrapped vault keys would brick recovery;
 *     route through revokeAllAccess / per-device revoke.
 *   - entitlements_billing / audit_timeline: server-owned, append-only.
 */
export const UNDELETABLE_DOMAINS = new Set<string>([
  "provider_accounts",
  "connected_devices",
  "external_mcp",
  "device_trust_keys",
  "entitlements_billing",
  "audit_timeline",
]);

/** Delete every doc matched by `query`, in Firestore-batch-sized pages. */
async function deleteQueryInBatches(query: Query): Promise<number> {
  let deleted = 0;
  for (;;) {
    const snap = await query.limit(400).get();
    if (snap.empty) break;
    await commitBatchedWrites(snap.docs.map((doc) => (batch: WriteBatch) => batch.delete(doc.ref)));
    deleted += snap.size;
    if (snap.size < 400) break;
  }
  return deleted;
}

export const deleteDomainData = onCall(
  {
    region: "us-central1",
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
    timeoutSeconds: 300,
    memory: "512MiB",
  },
  wrapCallableHandler(
    "deleteDomainData",
    async (request: CallableRequest<{ domainId?: unknown; confirm?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before deleting your data.");
      enforceAuthAndAppCheck(request, uid);

      const domainId = typeof request.data?.domainId === "string" ? request.data.domainId : "";
      const paths = DATA_DOMAIN_PATHS[domainId];
      if (!paths) {
        throw new HttpsError("invalid-argument", `Unknown data domain "${domainId}".`);
      }
      if (UNDELETABLE_DOMAINS.has(domainId)) {
        throw new HttpsError(
          "failed-precondition",
          `The "${domainId}" domain is not deletable here; use its revoke/erase action instead.`,
        );
      }
      if (request.data?.confirm !== true) {
        throw new HttpsError("failed-precondition", "Set confirm: true to delete this domain's data.");
      }

      let firestoreDocs = 0;
      for (const collection of paths.firestoreCollections) {
        firestoreDocs += await deleteQueryInBatches(db.collection(`users/${uid}/${collection}`));
      }

      let storageObjects = 0;
      if (paths.storagePrefixes.length > 0) {
        const bucket = getStorage().bucket();
        for (const prefix of paths.storagePrefixes) {
          const fullPrefix = `users/${uid}/${prefix}/`;
          const [files] = await bucket.getFiles({ prefix: fullPrefix });
          storageObjects += files.length;
          await bucket.deleteFiles({ prefix: fullPrefix, force: true });
        }
      }

      try {
        await appendAuditEvent(uid, {
          actor: auditActorLabel(request),
          action: AUDIT_ACTIONS.domainDelete,
          domain: domainId,
        });
      } catch {
        // Audit-write failure must not fail the deletion itself.
      }

      return { ok: true, domainId, deleted: { firestoreDocs, storageObjects } };
    },
  ),
);
