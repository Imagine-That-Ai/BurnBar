/**
 * @fileoverview revokeAllAccess — the PANIC button.
 *
 * One callable that severs every external access path to the member's data,
 * aggregating the existing per-surface revoke logic so the UI doesn't have to
 * fan out N calls (and so a partial failure on one surface still revokes the
 * rest). Two scopes:
 *   - "sync": revoke the network-reachable surfaces — MCP clients/grants, Hermes
 *     + Pi agent device connections, and (escrow) trusted devices — leaving the
 *     account itself and provider credentials intact.
 *   - "all": everything in "sync" PLUS destroy connected provider credentials
 *     (Secret Manager) so no hosted call can run.
 *
 * Reuses revokeAllRemoteMcpGrantsForUser (remoteMcpGrant.ts) and mirrors the
 * status-flip patterns of revokeHermesConnection / revokePiAgentConnection /
 * revokeEscrowDeviceTrust / deleteProviderAccount rather than re-implementing
 * them. Appends a tamper-evident audit event (auditLog.ts).
 */

import { FieldPath, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { logError, wrapCallableHandler } from "../logging.js";
import { boundedTrimmedString } from "./shared.js";
import { revokeAllRemoteMcpGrantsForUser } from "../remoteMcpGrant.js";
import { providerAccountSecretRefPath } from "../quota.js";
import { destroyCredential } from "../secrets.js";
import { appendAuditEventRequired, auditActorLabel, AUDIT_ACTIONS } from "./auditLog.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

type PanicScope = "sync" | "all";

const REVOKE_REASON = "panic_revoke_all";
// Keep each WriteBatch comfortably under Firestore's 500-op commit limit.
const PAGE_LIMIT = 400;

/**
 * Iterate EVERY document in a per-user collection across pages (ordered by id,
 * startAfter cursor) so the panic button drains the whole collection — not just
 * the first 500. `handlePage` writes (batched, <=PAGE_LIMIT ops) and returns the
 * number revoked in that page.
 */
async function drainCollection(
  coll: FirebaseFirestore.Query,
  handlePage: (docs: FirebaseFirestore.QueryDocumentSnapshot[]) => Promise<number>,
): Promise<number> {
  let last: FirebaseFirestore.QueryDocumentSnapshot | undefined;
  let total = 0;
  for (;;) {
    let query = coll.orderBy(FieldPath.documentId()).limit(PAGE_LIMIT);
    if (last) query = query.startAfter(last);
    const snap = await query.get();
    if (snap.empty) break;
    total += await handlePage(snap.docs);
    last = snap.docs[snap.docs.length - 1];
    if (snap.size < PAGE_LIMIT) break;
  }
  return total;
}

/** Test-only surface for the pagination invariant (the panic-completeness fix). */
export const __testing__ = { drainCollection, PAGE_LIMIT };

/** Flip every non-revoked doc in a connection collection to revoked. Returns count. */
async function revokeConnectionCollection(uid: string, collection: string): Promise<number> {
  const now = Timestamp.now();
  return drainCollection(db.collection(`users/${uid}/${collection}`), async (docs) => {
    const batch = db.batch();
    let writes = 0;
    for (const doc of docs) {
      if (doc.get("status") === "revoked") continue;
      batch.set(
        doc.ref,
        { status: "revoked", updatedAt: now.toDate().toISOString(), revokeReason: REVOKE_REASON },
        { merge: true },
      );
      writes += 1;
    }
    if (writes > 0) await batch.commit();
    return writes;
  });
}

/** Flip every trusted escrow device to revoked (trustState field, not status). */
async function revokeEscrowDevices(uid: string): Promise<number> {
  const now = Timestamp.now();
  return drainCollection(db.collection(`users/${uid}/escrow_devices`), async (docs) => {
    const batch = db.batch();
    let writes = 0;
    for (const doc of docs) {
      if (doc.get("trustState") === "revoked") continue;
      batch.set(doc.ref, { trustState: "revoked", updatedAt: now }, { merge: true });
      writes += 1;
    }
    if (writes > 0) await batch.commit();
    return writes;
  });
}

/**
 * Destroy every provider credential secret + mark the account deleted. Returns
 * the count revoked AND the number of Secret Manager destroys that failed — a
 * failed destroy means the credential may still be usable, so the panic result
 * must NOT claim full success when secretFailures > 0.
 */
async function revokeProviderCredentials(uid: string): Promise<{ revoked: number; secretFailures: number }> {
  const now = new Date().toISOString();
  let secretFailures = 0;
  const revoked = await drainCollection(db.collection(`users/${uid}/provider_accounts`), async (docs) => {
    let pageRevoked = 0;
    for (const account of docs) {
      if (account.get("status") === "deleted") continue;
      const accountID = account.id;
      const privateRef = db.doc(providerAccountSecretRefPath(uid, accountID));
      const privateSnap = await privateRef.get();
      const secretVersionName = privateSnap.exists
        ? typeof privateSnap.get("secretVersionName") === "string"
          ? privateSnap.get("secretVersionName")
          : undefined
        : undefined;
      if (secretVersionName) {
        try {
          await destroyCredential(secretVersionName);
        } catch (err) {
          secretFailures += 1;
          logError({
            event: "callable_warn",
            message: `panic revoke: failed to destroy provider secret for ${accountID}`,
            detail: String(err),
          });
        }
      }
      const batch = db.batch();
      batch.delete(privateRef);
      batch.set(
        account.ref,
        { status: "deleted", lastValidatedAt: null, lastRefreshAt: null, updatedAt: now },
        { merge: true },
      );
      await batch.commit();
      pageRevoked += 1;
    }
    return pageRevoked;
  });
  return { revoked, secretFailures };
}

export const revokeAllAccess = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
    timeoutSeconds: 300,
    memory: "512MiB",
  },
  wrapCallableHandler("revokeAllAccess", async (request: CallableRequest<{ scope?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before revoking access.");
    enforceAuthAndAppCheck(request, uid);

    const scope = (boundedTrimmedString(request.data?.scope, "scope", 16, false) ?? "sync") as PanicScope;
    if (scope !== "sync" && scope !== "all") {
      throw new HttpsError("invalid-argument", "scope must be sync or all.");
    }

    // Each surface is best-effort + independent: a failure on one must not block
    // the others (this is a panic button — revoke as much as possible). But a
    // failed surface is RECORDED so the result reports partial failure instead of
    // a false "panic complete" — the UI can warn + offer retry.
    const failures: string[] = [];
    const safe = async <T>(label: string, fn: () => Promise<T>, fallback: T): Promise<T> => {
      try {
        return await fn();
      } catch (err) {
        logError({ event: "callable_warn", message: `panic revoke ${label} failed`, detail: String(err) });
        failures.push(label);
        return fallback;
      }
    };

    const [mcp, hermes, hermesGateway, pi, escrowDevices] = await Promise.all([
      safe("mcp", () => revokeAllRemoteMcpGrantsForUser(db, uid, REVOKE_REASON), {
        clientsRevoked: 0,
        grantsRevoked: 0,
      }),
      safe("hermes", () => revokeConnectionCollection(uid, "hermes_connections"), 0),
      safe("hermes_gateway", () => revokeConnectionCollection(uid, "hermes_gateway_clients"), 0),
      safe("pi_agent", () => revokeConnectionCollection(uid, "pi_agent_connections"), 0),
      safe("escrow_devices", () => revokeEscrowDevices(uid), 0),
    ]);

    const providerResult =
      scope === "all"
        ? await safe("providers", () => revokeProviderCredentials(uid), { revoked: 0, secretFailures: 0 })
        : { revoked: 0, secretFailures: 0 };
    // A swallowed Secret Manager destroy means the credential may still work —
    // that is a real partial failure, not a clean revoke.
    if (providerResult.secretFailures > 0) failures.push(`provider_secrets(${providerResult.secretFailures})`);

    const revoked = {
      mcpClients: mcp.clientsRevoked,
      devices: hermes + hermesGateway + pi,
      escrowDevices,
      providers: providerResult.revoked,
    };

    // Fail-CLOSED: revoke-all is irreversible, so the record of who pulled the
    // kill switch must commit. If the audit write fails the error propagates —
    // surfaces already revoked stay revoked, but the caller learns the action is
    // unproven rather than the record being silently dropped.
    await appendAuditEventRequired(uid, {
      actor: auditActorLabel(request),
      action: AUDIT_ACTIONS.panicRevoke,
      domain: scope === "all" ? "all" : "connected_devices",
    });

    // ok=false when any surface failed: the panic was NOT fully complete and the
    // member may still be exposed on the failed surface(s).
    return { ok: failures.length === 0, partial: failures.length > 0, failures, revoked };
  }),
);
