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
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall, onRequest, type CallableRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";

import { db } from "../adminRuntime.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { wrapCallableHandler } from "../logging.js";
import { runScheduledJob } from "../scheduledOps.js";
import {
  assertActiveBurnBarCloudProEntitlement,
  boundedTrimmedString,
  safeCloudDocumentID,
} from "./shared.js";

export const KNOWLEDGE_GITHUB_WEBHOOK_SECRET = defineSecret("KNOWLEDGE_GITHUB_WEBHOOK_SECRET");

/** Staleness window: a connected repo not synced within this is flagged for re-sync. */
const RECONCILE_STALE_MS = 24 * 60 * 60 * 1000;

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
  { region: "us-central1", maxInstances: 20, secrets: [KNOWLEDGE_GITHUB_WEBHOOK_SECRET], invoker: "public" },
  async (req, res): Promise<void> => {
    const secret = KNOWLEDGE_GITHUB_WEBHOOK_SECRET.value();
    if (!secret) {
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

    // Map repo → owner(s) via the collection-group of connected repos.
    const now = Timestamp.now();
    const repos = await db.collectionGroup("knowledge_repos").where("repoFullName", "==", repoFullName).get();
    let flagged = 0;
    for (const repoDoc of repos.docs) {
      const uid = repoDoc.ref.parent.parent?.id;
      const sourceSlug = repoDoc.get("sourceSlug");
      if (!uid || typeof sourceSlug !== "string") continue;
      await db.doc(`users/${uid}/knowledge_sync_manifests/${sourceSlug}`).set(
        { needsResync: true, lastDirtyAt: now, schemaVersion: 1 },
        { merge: true },
      );
      flagged += 1;
    }
    res.status(200).json({ ok: true, flagged });
  },
);

/** Register a repo as a Pensieve source for the dirty signal. */
export const connectKnowledgeRepo = onCall(
  { region: "us-central1", enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
  wrapCallableHandler(
    "connectKnowledgeRepo",
    async (request: CallableRequest<{ repoFullName?: unknown; sourceSlug?: unknown; installId?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in to connect a repo.");
      enforceAuthAndAppCheck(request, uid);
      await assertActiveBurnBarCloudProEntitlement(uid);

      const repoFullName = boundedTrimmedString(request.data.repoFullName, "repoFullName", 256, true);
      const sourceSlug = safeCloudDocumentID(request.data.sourceSlug, "sourceSlug");
      const installId = boundedTrimmedString(request.data.installId, "installId", 128, false);
      const repoId = safeCloudDocumentID(repoFullName.replace(/[^A-Za-z0-9_.-]/g, "_"), "repoId");

      await db.doc(`users/${uid}/knowledge_repos/${repoId}`).set(
        { uid, repoId, repoFullName, sourceSlug, installId, connectedAt: Timestamp.now(), schemaVersion: 1 },
        { merge: true },
      );
      return { ok: true, repoId };
    },
  ),
);

/** Unregister a connected repo. */
export const disconnectKnowledgeRepo = onCall(
  { region: "us-central1", enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
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

/**
 * Daily drift backstop. Flags manifests whose last sync is older than the
 * staleness window for re-sync by the device. Mirrors wiki-mem0-reconcile's
 * nightly safety net; it never re-embeds (no plaintext server-side).
 */
export const reconcileKnowledgeMemoryDaily = onSchedule(
  { schedule: "30 9 * * *", timeZone: "UTC", region: "us-central1", timeoutSeconds: 300 },
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
