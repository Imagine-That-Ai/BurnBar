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
 * instead (see UNDELETABLE_DOMAINS). The registry encodes which domains expose
 * a `delete` action; we enforce that here. Trusted-device step-up also guards
 * this callable.
 */

import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import { enforceHighRiskOwnerAction } from "./highRiskOwnerAction.js";
import { DATA_DOMAIN_PATHS } from "./dataExport.js";
import { appendAuditEvent, appendAuditEventRequired, auditActorLabel, AUDIT_ACTIONS } from "./auditLog.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

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
  // Team memory is a SHARED tenant, not this user's namespace. Erasing it from
  // one member's account-deletion path would delete every other member's facts
  // too. The member-facing action is to leave the team (which cuts their reads
  // at the roster and rotates the key) and to delete the individual facts they
  // authored, which `firestore.rules` permits by `resource.data.uid` — and
  // permits even on a lapsed subscription, so a billing state never traps a
  // user's own contributions.
  "team_pensieve",
]);

export const deleteDomainData = onCall(
  {
    region: FUNCTIONS_REGION,
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

      await enforceHighRiskOwnerAction(request, uid, {
        actionKind: "data_domain_delete",
        subjectId: domainId,
      });

      // Fail-closed intent: an irreversible deletion must leave a durable audit
      // record. If the intent cannot be persisted, refuse the action rather than
      // silently deleting data without evidence (codex-gpt-5 FINDING-006).
      await appendAuditEventRequired(uid, {
        actor: auditActorLabel(request),
        action: AUDIT_ACTIONS.domainDeleteIntent,
        domain: domainId,
      });

      // Recursive delete so nested subcollections are purged too (e.g.
      // knowledge_sync_manifests/{slug}/entries, cli_sessions/{id}/snapshots).
      // A top-level query-delete would orphan descendants — residual PII after a
      // "delete my data" call. recursiveDelete handles batching + descendants.
      let firestoreDocs = 0;
      for (const collection of paths.firestoreCollections) {
        const collRef = db.collection(`users/${uid}/${collection}`);
        const agg = await collRef.count().get();
        firestoreDocs += Number(agg.data().count ?? 0);
        await db.recursiveDelete(collRef);
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

      // Best-effort completion record: the intent is the fail-closed guard; the
      // completion record improves forensics but cannot undo the deletion.
      try {
        await appendAuditEvent(uid, {
          actor: auditActorLabel(request),
          action: AUDIT_ACTIONS.domainDeleteComplete,
          domain: domainId,
        });
      } catch {
        // Completion audit is best-effort; the intent audit already guarantees
        // a durable record of the irreversible action.
      }

      return { ok: true, domainId, deleted: { firestoreDocs, storageObjects } };
    },
  ),
);
