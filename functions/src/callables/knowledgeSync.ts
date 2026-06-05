/**
 * @fileoverview Pensieve repo-connector + reconciliation.
 *
 * - onKnowledgeRepoPush: a GitHub push webhook that ONLY sets a dirty flag
 *   (enqueue-only). It never chunks/embeds/decrypts — that all happens on the
 *   member's device (the webhook never sees plaintext), preserving E2EE. The
 *   Mac daemon (PensieveKnowledgeWatcher) reacts to the flag and re-syncs.
 * - connectKnowledgeRepo / disconnectKnowledgeRepo: register/unregister a repo
 *   source for the dirty signal (gated on Cloud Pro).
 * - reconcileKnowledgeMemoryDaily: a daily backstop that flags manifests whose
 *   connected repo hasn't synced within the staleness window so the device
 *   re-syncs (it cannot re-embed server-side — no plaintext).
 */

import { createHmac, timingSafeEqual } from "node:crypto";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall, onRequest, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";

import { db } from "../adminRuntime.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { stripUndefinedObject } from "../guards.js";
import { wrapCallableHandler } from "../logging.js";
import { runScheduledJob } from "../scheduledOps.js";
import {
  assertActiveBurnBarCloudProEntitlement,
  boundedTrimmedString,
  requireSealedText,
  safeCloudDocumentID,
} from "./shared.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

export const KNOWLEDGE_GITHUB_WEBHOOK_SECRET = defineSecret("KNOWLEDGE_GITHUB_WEBHOOK_SECRET");
/**
 * Server-held HMAC key for the opaque repo MATCH token (privacy-leak-
 * remediation-2026-06-02 §4). The GitHub-push webhook has no vault key and no
 * user context — it can only equality-match the incoming repo full name, never
 * needs the name back — so we store `repoMatchToken = HMAC(this, normalized
 * full_name)` instead of the cleartext name. Both the connect callable (which
 * receives the name over an authed HTTPS call) and the webhook (which receives
 * the GitHub-signed `full_name`) recompute the same token with this key; a
 * Firestore-only adversary sees only an opaque token.
 */
export const KNOWLEDGE_REPO_MATCH_KEY = defineSecret("KNOWLEDGE_REPO_MATCH_KEY");

/** Staleness window: a connected repo not synced within this is flagged for re-sync. */
const RECONCILE_STALE_MS = 24 * 60 * 60 * 1000;

/**
 * Normalize a GitHub `owner/repo` full name to a canonical form so the same repo
 * always maps to the same match token regardless of case/whitespace. GitHub repo
 * full names are case-insensitive, so we lower-case and trim.
 */
function normalizeRepoFullName(raw: string): string {
  return raw.trim().toLowerCase();
}

/** Server-keyed match token: HMAC_SHA256(KNOWLEDGE_REPO_MATCH_KEY, normalize(full_name)) → hex. */
function repoMatchTokenFor(repoFullName: string): string {
  const secret = KNOWLEDGE_REPO_MATCH_KEY.value();
  if (!secret) {
    throw new HttpsError("failed-precondition", "Knowledge repo match key is not configured.");
  }
  return createHmac("sha256", secret).update(normalizeRepoFullName(repoFullName), "utf8").digest("hex");
}

/**
 * Server-keyed, owner-namespaced manifest-key token:
 * HMAC_SHA256(KNOWLEDGE_REPO_MATCH_KEY, "manifest|<uid>|<cleartext slug>") → hex.
 *
 * The console derives `sourceSlug` deterministically from the repo full name
 * (e.g. `repo-acme-handbook`), which is reversible cleartext repo identity. We
 * MUST NOT persist it (privacy-leak-remediation §4 + firestore.rules bans it on
 * client writes and comments claim it is never stored; the Admin-SDK callable
 * formerly bypassed that promise). Instead we store/route on this opaque token,
 * which is non-reversible to a Firestore-only adversary yet deterministic so the
 * connect callable, the webhook, and the list/resync reads all derive the SAME
 * manifest doc id. The `uid` is folded in so the same repo across two members
 * never collides to the same global manifest token. Reuses the existing
 * repoMatchToken vault-keyed-token pattern (same secret, distinct domain prefix).
 */
function sourceSlugTokenFor(uid: string, sourceSlug: string): string {
  const secret = KNOWLEDGE_REPO_MATCH_KEY.value();
  if (!secret) {
    throw new HttpsError("failed-precondition", "Knowledge repo match key is not configured.");
  }
  return createHmac("sha256", secret).update(`manifest|${uid}|${sourceSlug}`, "utf8").digest("hex");
}

/**
 * Resolve the manifest doc id for a connected-repo row with a LAZY DUAL-READ:
 *  - New rows (post-§4-slug-migration) carry an opaque `sourceSlugToken`.
 *  - Legacy rows carry only the cleartext `sourceSlug`; their manifest is still
 *    keyed by that cleartext value, so we fall back to it on read so existing
 *    manifests keep resolving WITHOUT a server backfill (the device holds the
 *    key; the slug is regenerated client-side on the next connect, which upgrades
 *    the row to the token form). Returns undefined when neither is present.
 */
function manifestKeyForRepoRow(row: {
  sourceSlugToken?: unknown;
  sourceSlug?: unknown;
}): string | undefined {
  if (typeof row.sourceSlugToken === "string" && row.sourceSlugToken.length > 0) {
    return row.sourceSlugToken;
  }
  if (typeof row.sourceSlug === "string" && row.sourceSlug.length > 0) {
    return row.sourceSlug; // legacy slug-keyed manifest (read-only fallback)
  }
  return undefined;
}

/** Verify a GitHub `x-hub-signature-256: sha256=<hex>` HMAC over the raw body. */
function verifyGitHubSignature(rawBody: Buffer, signatureHeader: string | undefined, secret: string): boolean {
  if (!signatureHeader || !signatureHeader.startsWith("sha256=")) return false;
  const expected = `sha256=${createHmac("sha256", secret).update(rawBody).digest("hex")}`;
  const a = Buffer.from(signatureHeader);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * GitHub push webhook → set a dirty flag on the matching member's source(s).
 * Enqueue-only; never reads repo contents (preserves E2EE).
 */
export const onKnowledgeRepoPush = onRequest(
  {
    region: FUNCTIONS_REGION,
    maxInstances: 20,
    secrets: [KNOWLEDGE_GITHUB_WEBHOOK_SECRET, KNOWLEDGE_REPO_MATCH_KEY],
    invoker: "public",
  },
  async (req, res): Promise<void> => {
    const secret = KNOWLEDGE_GITHUB_WEBHOOK_SECRET.value();
    if (!secret || !KNOWLEDGE_REPO_MATCH_KEY.value()) {
      res.status(503).send("Knowledge webhook is not configured.");
      return;
    }
    const rawBody = Buffer.isBuffer(req.rawBody) ? req.rawBody : Buffer.from(JSON.stringify(req.body ?? {}));
    if (!verifyGitHubSignature(rawBody, req.header("x-hub-signature-256"), secret)) {
      res.status(400).send("Invalid signature.");
      return;
    }
    const event = req.header("x-github-event");
    if (event === "ping") {
      res.status(200).send("pong");
      return;
    }
    const repoFullName: string | undefined = req.body?.repository?.full_name;
    if (!repoFullName) {
      res.status(202).send("No repository in payload; nothing to enqueue.");
      return;
    }

    // Map repo → owner(s) via the collection-group of connected repos. The rows
    // store only an opaque `repoMatchToken` (no cleartext repo name); the webhook
    // recomputes the same server-keyed token from the GitHub-signed `full_name`
    // and matches on it, so a Firestore-only adversary never sees the repo
    // identity (privacy-leak-remediation-2026-06-02 §4).
    const now = Timestamp.now();
    const repoMatchToken = repoMatchTokenFor(repoFullName);
    const repos = await db.collectionGroup("knowledge_repos").where("repoMatchToken", "==", repoMatchToken).get();
    let flagged = 0;
    for (const repoDoc of repos.docs) {
      const uid = repoDoc.ref.parent.parent?.id;
      // Manifest is keyed by the opaque `sourceSlugToken` (new rows) with a
      // read-only fallback to a legacy cleartext `sourceSlug`; no cleartext slug
      // is read into a stored path for new rows.
      const manifestKey = manifestKeyForRepoRow({
        sourceSlugToken: repoDoc.get("sourceSlugToken"),
        sourceSlug: repoDoc.get("sourceSlug"),
      });
      if (!uid || !manifestKey) continue;
      await db
        .doc(`users/${uid}/knowledge_sync_manifests/${manifestKey}`)
        .set({ needsResync: true, lastDirtyAt: now, schemaVersion: 1 }, { merge: true });
      flagged += 1;
    }
    res.status(200).json({ ok: true, flagged });
  },
);

/** Register a repo as a Pensieve source for the dirty signal. */
export const connectKnowledgeRepo = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
    secrets: [KNOWLEDGE_REPO_MATCH_KEY],
  },
  wrapCallableHandler(
    "connectKnowledgeRepo",
    async (
      request: CallableRequest<{
        repoFullName?: unknown;
        sealedRepoFullName?: unknown;
        sourceSlug?: unknown;
        installId?: unknown;
      }>,
    ) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in to connect a repo.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarCloudProEntitlement(uid);

      // The cleartext `repoFullName` arrives over the authed HTTPS callable but is
      // NEVER persisted — we keep only the server-keyed match token plus a
      // vault-sealed display name the client supplies for its own later display
      // (privacy-leak-remediation-2026-06-02 §4).
      const repoFullName = boundedTrimmedString(request.data.repoFullName, "repoFullName", 256, true);
      const sealedRepoFullName =
        request.data.sealedRepoFullName !== undefined
          ? requireSealedText(request.data.sealedRepoFullName, "sealedRepoFullName")
          : undefined;
      // The console derives `sourceSlug` deterministically from the repo full
      // name (e.g. `repo-acme-handbook`) — reversible cleartext repo identity.
      // We validate it transiently to derive the opaque manifest-key token, then
      // DISCARD the cleartext: the stored row carries only `sourceSlugToken`, so
      // a Firestore-only adversary never sees the repo-name-derived slug. This is
      // what firestore.rules already promises for client writes (it bans
      // `sourceSlug`); the Admin-SDK callable formerly broke that promise (§4).
      const sourceSlug = safeCloudDocumentID(request.data.sourceSlug, "sourceSlug");
      const sourceSlugToken = sourceSlugTokenFor(uid, sourceSlug);
      const installId = boundedTrimmedString(request.data.installId, "installId", 128, false);
      const repoMatchToken = repoMatchTokenFor(repoFullName);
      // Doc id derived from the opaque token (never the repo name).
      const repoId = safeCloudDocumentID(repoMatchToken, "repoId");

      await db.doc(`users/${uid}/knowledge_repos/${repoId}`).set(
        stripUndefinedObject({
          uid,
          repoId,
          repoMatchToken,
          sealedRepoFullName,
          // Opaque, server-keyed manifest routing token (replaces cleartext
          // `sourceSlug`). MIGRATION: legacy rows that still hold `sourceSlug` are
          // read via manifestKeyForRepoRow's fallback; a re-connect upgrades them
          // to the token form (no server backfill — device holds the key).
          sourceSlugToken,
          // Defensively clear any legacy cleartext slug on re-connect (merge:true
          // would otherwise leave a stale plaintext field behind).
          sourceSlug: FieldValue.delete(),
          installId,
          connectedAt: Timestamp.now(),
          schemaVersion: 1,
        }),
        { merge: true },
      );
      return { ok: true, repoId };
    },
  ),
);

/** Unregister a connected repo. */
export const disconnectKnowledgeRepo = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
  wrapCallableHandler("disconnectKnowledgeRepo", async (request: CallableRequest<{ repoId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to disconnect a repo.");
    enforceAuthAndAppCheck(request, uid);
    await assertActiveBurnBarCloudProEntitlement(uid);
    const repoId = safeCloudDocumentID(request.data.repoId, "repoId");
    await db.doc(`users/${uid}/knowledge_repos/${repoId}`).delete();
    return { ok: true };
  }),
);

/** Firestore Timestamp → ISO string (or undefined) for wire-safe responses. */
function tsToIso(value: unknown): string | undefined {
  return value instanceof Timestamp ? value.toDate().toISOString() : undefined;
}

/**
 * List the caller's connected repos for the console's Sources panel. Returns the
 * vault-sealed `sealedRepoFullName` (decrypted client-side for display — the
 * server never holds the cleartext name) plus each source's sync health from its
 * manifest, so the UI can show "Synced", "Re-sync queued", or "Waiting for your
 * Mac". Read-only and ungated: a free member simply has no rows.
 */
export const listKnowledgeRepos = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
  wrapCallableHandler("listKnowledgeRepos", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to view connected repos.");
    enforceAuthAndAppCheck(request, uid);

    const reposSnap = await db.collection(`users/${uid}/knowledge_repos`).limit(200).get();
    const repos = await Promise.all(
      reposSnap.docs.map(async (repoDoc) => {
        // Manifest doc id is the opaque `sourceSlugToken` (new rows) with a
        // read-only fallback to a legacy cleartext `sourceSlug` (lazy dual-read).
        const manifestKey = manifestKeyForRepoRow({
          sourceSlugToken: repoDoc.get("sourceSlugToken"),
          sourceSlug: repoDoc.get("sourceSlug"),
        });
        let manifest: FirebaseFirestore.DocumentData | undefined;
        if (manifestKey) {
          const snap = await db.doc(`users/${uid}/knowledge_sync_manifests/${manifestKey}`).get();
          manifest = snap.exists ? snap.data() : undefined;
        }
        return {
          repoId: repoDoc.id,
          sealedRepoFullName: repoDoc.get("sealedRepoFullName") ?? null,
          // Opaque routing token only — the server never returns the cleartext
          // repo-name-derived slug. The console keys off `repoId` for actions.
          // `sourceSlug` stays in the response shape (back-compat) but is always
          // null now: the cleartext slug is no longer stored or echoed.
          sourceSlug: null,
          sourceSlugToken: repoDoc.get("sourceSlugToken") ?? null,
          installId: repoDoc.get("installId") ?? null,
          connectedAt: tsToIso(repoDoc.get("connectedAt")) ?? null,
          chunkCount: Number(manifest?.chunkCount ?? 0),
          byteCount: Number(manifest?.byteCount ?? 0),
          lastSyncAt: tsToIso(manifest?.lastSyncAt) ?? null,
          lastDirtyAt: tsToIso(manifest?.lastDirtyAt) ?? null,
          needsResync: manifest?.needsResync === true,
        };
      }),
    );
    // Newest first; rows without connectedAt sort last.
    repos.sort((a, b) => (b.connectedAt ?? "").localeCompare(a.connectedAt ?? ""));
    return { ok: true, repos };
  }),
);

/**
 * Manually queue a re-sync of every connected repo: flag each source's manifest
 * `needsResync` exactly as the GitHub push webhook does, so the member's Mac
 * daemon re-reads, re-chunks, and re-seals on-device on its next pass. The server
 * never touches plaintext — this only raises the dirty flag.
 */
export const requestKnowledgeResync = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
  wrapCallableHandler("requestKnowledgeResync", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to request a re-sync.");
    enforceAuthAndAppCheck(request, uid);

    const reposSnap = await db.collection(`users/${uid}/knowledge_repos`).limit(200).get();
    const now = Timestamp.now();
    let flagged = 0;
    for (const repoDoc of reposSnap.docs) {
      // Opaque `sourceSlugToken` (new rows) with legacy cleartext `sourceSlug`
      // read-only fallback (lazy dual-read; no server backfill).
      const manifestKey = manifestKeyForRepoRow({
        sourceSlugToken: repoDoc.get("sourceSlugToken"),
        sourceSlug: repoDoc.get("sourceSlug"),
      });
      if (!manifestKey) continue;
      await db
        .doc(`users/${uid}/knowledge_sync_manifests/${manifestKey}`)
        .set({ needsResync: true, lastDirtyAt: now, schemaVersion: 1 }, { merge: true });
      flagged += 1;
    }
    return { ok: true, flagged };
  }),
);

/**
 * Daily drift backstop. Flags manifests whose last sync is older than the
 * staleness window for re-sync by the device. Mirrors wiki-mem0-reconcile's
 * nightly safety net; it never re-embeds (no plaintext server-side).
 */
export const reconcileKnowledgeMemoryDaily = onSchedule(
  { schedule: "30 9 * * *", timeZone: "UTC", region: FUNCTIONS_REGION, timeoutSeconds: 300 },
  async () => {
    await runScheduledJob("reconcileKnowledgeMemoryDaily", async () => {
      const firestore = getFirestore();
      const cutoff = Timestamp.fromMillis(Date.now() - RECONCILE_STALE_MS);
      const manifests = await firestore
        .collectionGroup("knowledge_sync_manifests")
        .where("lastSyncAt", "<", cutoff)
        .limit(500)
        .get();
      let flagged = 0;
      for (const manifest of manifests.docs) {
        if (manifest.get("needsResync") === true) continue;
        await manifest.ref.set({ needsResync: true, reconciledAt: Timestamp.now() }, { merge: true });
        flagged += 1;
      }
      return { scanned: manifests.size, flagged };
    });
  },
);
