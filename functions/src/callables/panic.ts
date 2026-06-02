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
import { appendAuditEvent, auditActorLabel, AUDIT_ACTIONS } from "./auditLog.js";

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
  collectionPath: string,
  handlePage: (docs: FirebaseFirestore.QueryDocumentSnapshot[]) => Promise<number>,
): Promise<number> {
  const coll = db.collection(collectionPath);
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

/** Flip every non-revoked doc in a connection collection to revoked. Returns count. */
async function revokeConnectionCollection(uid: string, collection: string): Promise<number> {
  const now = Timestamp.now();
  return drainCollection(`users/${uid}/${collection}`, async (docs) => {
    const batch = db.batch();
    let writes = 0;
    for (const doc of docs) {
      if (doc.get("status") === "revoked") continue;
      batch.set(doc.ref, { status: "revoked", updatedAt: now.toDate().toISOString(), revokeReason: REVOKE_REASON }, { merge: true });
      writes += 1;
    }
    if (writes > 0) await batch.commit();
    return writes;
  });
}

/** Flip every trusted escrow device to revoked (trustState field, not status). */
async function revokeEscrowDevices(uid: string): Promise<number> {
  const now = Timestamp.now();
  return drainCollection(`users/${uid}/escrow_devices`, async (docs) => {
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

/** Destroy every provider credential secret + mark the account deleted. Returns count. */
async function revokeProviderCredentials(uid: string): Promise<number> {
  const now = new Date().toISOString();
  return drainCollection(`users/${uid}/provider_accounts`, async (docs) => {
    let revoked = 0;
    for (const account of docs) {
      if (account.get("status") === "deleted") continue;
      const accountID = account.id;
    const privateRef = db.doc(providerAccountSecretRefPath(uid, accountID));
    const privateSnap = await privateRef.get();
    const secretVersionName = privateSnap.exists
      ? (typeof privateSnap.get("secretVersionName") === "string" ? privateSnap.get("secretVersionName") : undefined)
      : undefined;
    if (secretVersionName) {
      try {
        await destroyCredential(secretVersionName);
      } catch (err) {
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
    revoked += 1;
    }
    return revoked;
  });
}

export const revokeAllAccess = onCall(
  {
    region: "us-central1",
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
    // the others (this is a panic button — revoke as much as possible).
    const safe = async <T>(label: string, fn: () => Promise<T>, fallback: T): Promise<T> => {
      try {
        return await fn();
      } catch (err) {
        logError({ event: "callable_warn", message: `panic revoke ${label} failed`, detail: String(err) });
        return fallback;
      }
    };

    const [mcp, hermes, hermesGateway, pi, escrowDevices] = await Promise.all([
      safe("mcp", () => revokeAllRemoteMcpGrantsForUser(db, uid, REVOKE_REASON), { clientsRevoked: 0, grantsRevoked: 0 }),
      safe("hermes", () => revokeConnectionCollection(uid, "hermes_connections"), 0),
      safe("hermes_gateway", () => revokeConnectionCollection(uid, "hermes_gateway_clients"), 0),
      safe("pi_agent", () => revokeConnectionCollection(uid, "pi_agent_connections"), 0),
      safe("escrow_devices", () => revokeEscrowDevices(uid), 0),
    ]);

    const providers = scope === "all" ? await safe("providers", () => revokeProviderCredentials(uid), 0) : 0;

    const revoked = {
      mcpClients: mcp.clientsRevoked,
      devices: hermes + hermesGateway + pi,
      escrowDevices,
      providers,
    };

    try {
      await appendAuditEvent(uid, {
        actor: auditActorLabel(request),
        action: AUDIT_ACTIONS.panicRevoke,
        domain: scope === "all" ? "all" : "connected_devices",
      });
    } catch {
      // best-effort audit
    }

    return { ok: true, revoked };
  }),
);
