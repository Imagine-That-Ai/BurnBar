/**
 * @fileoverview RR-5 — CloudVault rotation resilience (server side of a
 * client-pickup design).
 *
 * When `revokeEscrowDeviceTrust` revokes a device it writes a
 * `users/{uid}/cloud_vault_rotation_requirements/{receiptId}` doc with
 * `status: "pending"`, the surviving `survivorDeviceIds`, and
 * `rotateCallable: "rotateCloudVaultKey"`. Rotation itself is client-driven —
 * the server is zero-access and holds no vault key, so it can NEVER rotate.
 * The original design only had the iOS *revoking* client run the rewrap, so a
 * revoke initiated from Android (or a revoking device that goes offline) left
 * the requirement `pending` forever while the revoked device's cached vault key
 * kept decrypting.
 *
 * This module closes that gap from the server side without ever touching a
 * vault key:
 *
 *   1. `listPendingCloudVaultRotationRequirements` — an owner-scoped callable so
 *      ANY surviving trusted device can discover the pending requirement on its
 *      next launch/foreground and complete the rewrap via `rotateCloudVaultKey`.
 *   2. `detectStalePendingCloudVaultRotations` — a scheduled detector that does
 *      NOT rotate (it cannot) but (a) emits a structured warning metric for ops
 *      visibility and (b) best-effort nudges surviving devices with a silent
 *      data push so they run rotation, reusing the durable `fcm_outbound` plane.
 */

import { FieldValue, getFirestore, Timestamp } from "firebase-admin/firestore";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { randomBytes } from "node:crypto";

import { db } from "./adminRuntime.js";
import { enforceAuthAndAppCheck } from "./auth.js";
import { getConfig } from "./config.js";
import { recordOrUndefined } from "./guards.js";
import { logInfo, logWarn, onCallProduction } from "./logging.js";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { runScheduledJob } from "./scheduledOps.js";
import { boundedTrimmedString } from "./callables/shared.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const ROTATION_REQUIREMENT_COLLECTION = "cloud_vault_rotation_requirements";
/**
 * A pending rotation requirement older than this is considered stale: the
 * client pickup never landed (revoking device offline, Android-initiated
 * revoke, app never relaunched). 1 hour gives the foreground-launch pickup
 * room to complete while keeping the revoked device's window bounded.
 */
const STALE_PENDING_GRACE_MS = 60 * 60_000;
/** Max stale requirements handled per scheduled tick. */
const STALE_PENDING_SWEEP_BATCH_LIMIT = 100;
/** Don't re-nudge a requirement more often than this (avoid push spam). */
const NUDGE_MIN_INTERVAL_MS = 60 * 60_000;

interface PendingRotationRequirementSummary {
  requirementId: string;
  reason: string;
  revokedDeviceId: string | null;
  currentVaultKeyID: string;
  currentVaultGeneration: number;
  survivorDeviceIds: string[];
  rotateCallable: string;
  nextRotationReason: string;
  createdAtMillis: number;
}

/**
 * Owner-scoped: confirm the caller controls a trusted escrow device before
 * surfacing rotation requirements to it. Scoped to the caller's own
 * collection — never a cross-tenant read.
 */
async function requireCallerTrustedDevice(uid: string, deviceId: string): Promise<void> {
  const snap = await db.doc(`users/${uid}/escrow_devices/${deviceId}`).get();
  if (!snap.exists || snap.get("trustState") !== "trusted") {
    throw new HttpsError("permission-denied", "Listing CloudVault rotation requirements requires a trusted escrow device.");
  }
}

function summarizeRequirement(id: string, raw: Record<string, unknown> | undefined): PendingRotationRequirementSummary | undefined {
  if (!raw) return undefined;
  if (raw.status !== "pending") return undefined;
  const currentVaultKeyID = typeof raw.currentVaultKeyID === "string" ? raw.currentVaultKeyID : "";
  if (!currentVaultKeyID) return undefined;
  const survivorDeviceIds = Array.isArray(raw.survivorDeviceIds)
    ? raw.survivorDeviceIds.filter((item): item is string => typeof item === "string")
    : [];
  return {
    requirementId: typeof raw.requirementId === "string" ? raw.requirementId : id,
    reason: typeof raw.reason === "string" ? raw.reason : "device_revoked",
    revokedDeviceId: typeof raw.revokedDeviceId === "string" ? raw.revokedDeviceId : null,
    currentVaultKeyID,
    currentVaultGeneration: typeof raw.currentVaultGeneration === "number" ? raw.currentVaultGeneration : 1,
    survivorDeviceIds,
    rotateCallable: typeof raw.rotateCallable === "string" ? raw.rotateCallable : "rotateCloudVaultKey",
    nextRotationReason: typeof raw.nextRotationReason === "string" ? raw.nextRotationReason : "revocation_rewrap",
    createdAtMillis: typeof raw.createdAtMillis === "number" ? raw.createdAtMillis : 0,
  };
}

export const listPendingCloudVaultRotationRequirements = onCallProduction(
  "listPendingCloudVaultRotationRequirements",
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  async (request: CallableRequest<{ callerDeviceId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before listing CloudVault rotation requirements.");
    // Read-only owner-scoped discovery — no high-risk nonce, but the caller
    // must be a trusted escrow device of this account and may only see
    // requirements for which it is a listed survivor (so it can actually
    // complete the rewrap).
    enforceAuthAndAppCheck(request, uid);
    const callerDeviceId = boundedTrimmedString(request.data.callerDeviceId, "callerDeviceId", 256, true);
    await requireCallerTrustedDevice(uid, callerDeviceId);

    const snap = await db.collection(`users/${uid}/${ROTATION_REQUIREMENT_COLLECTION}`).where("status", "==", "pending").get();
    const requirements: PendingRotationRequirementSummary[] = [];
    for (const doc of snap.docs) {
      const summary = summarizeRequirement(doc.id, recordOrUndefined(doc.data()));
      if (!summary) continue;
      // Survivor-eligible only: the caller must be able to rotate, i.e. it is
      // one of the surviving trusted devices the rewrap will wrap the next key
      // to.
      if (!summary.survivorDeviceIds.includes(callerDeviceId)) continue;
      requirements.push(summary);
    }

    logInfo({
      event: "cloud_vault.rotation_requirements_listed",
      user_id_hash: uid.slice(0, 8),
      caller_device_id: callerDeviceId,
      pending_count: requirements.length,
    });
    return { ok: true, requirements };
  },
);

type StaleRotationOutcome = "flagged" | "nudged" | "skipped";

/**
 * Best-effort silent data push to a surviving device. Reuses the durable
 * `fcm_outbound` plane (its create trigger delivers and its retry sweeper
 * recovers transient failures) rather than calling FCM inline, so a transient
 * messaging outage does not strand the nudge. Data-only (no `notification`
 * block) so the OS wakes the app to run rotation silently.
 */
async function enqueueRotationNudge(
  firestore: FirebaseFirestore.Firestore,
  args: { uid: string; deviceId: string; fcmToken: string; requirementId: string; currentVaultKeyID: string },
): Promise<boolean> {
  const docId = `cvrotnudge_${Date.now()}_${randomBytes(6).toString("hex")}`;
  try {
    await firestore
      .collection("fcm_outbound")
      .doc(docId)
      .create({
        status: "pending",
        fcmToken: args.fcmToken,
        payload: {
          type: "cloud_vault_rotation_required",
          requirement_id: args.requirementId,
          current_vault_key_id: args.currentVaultKeyID,
          rotate_callable: "rotateCloudVaultKey",
          next_rotation_reason: "revocation_rewrap",
        },
        uid: args.uid,
        targetDeviceId: args.deviceId,
        createdAt: Timestamp.now(),
      });
    return true;
  } catch {
    // Best-effort: a failed enqueue must not abort the sweep for the other
    // survivors. The next tick re-evaluates the still-pending requirement.
    return false;
  }
}

/**
 * Sweep `cloud_vault_rotation_requirements` left `pending` past the staleness
 * grace window. The server cannot rotate (zero-access), so this only DETECTS:
 * it emits a structured warning metric per stale requirement and best-effort
 * nudges each surviving trusted device with a silent data push. Mirrors the
 * `sweepStuckAgentReplyEvents` collection-group sweeper shape.
 */
export async function sweepStalePendingCloudVaultRotations(args: {
  firestore?: FirebaseFirestore.Firestore;
  now?: number;
}): Promise<Record<StaleRotationOutcome, number>> {
  const firestore = args.firestore ?? getFirestore();
  const nowMillis = args.now ?? Date.now();
  const cutoff = nowMillis - STALE_PENDING_GRACE_MS;

  const snapshot = await firestore
    .collectionGroup(ROTATION_REQUIREMENT_COLLECTION)
    .where("status", "==", "pending")
    .where("createdAtMillis", "<=", cutoff)
    .orderBy("createdAtMillis", "asc")
    .limit(STALE_PENDING_SWEEP_BATCH_LIMIT)
    .get();

  const tally: Record<StaleRotationOutcome, number> = { flagged: 0, nudged: 0, skipped: 0 };

  for (const doc of snapshot.docs) {
    // Path: users/{uid}/cloud_vault_rotation_requirements/{requirementId}
    const uid = doc.ref.path.split("/")[1];
    const summary = summarizeRequirement(doc.id, recordOrUndefined(doc.data()));
    if (!uid || !summary) {
      tally.skipped += 1;
      continue;
    }

    // Structured warning metric — stable jsonPayload.event key for ops
    // alerting. A revoked device's cached vault key keeps decrypting until a
    // survivor completes rotation; surface that window.
    logWarn({
      event: "cloud_vault.rotation_pending_stale",
      user_id_hash: uid.slice(0, 8),
      requirement_id: summary.requirementId,
      revoked_device_id: summary.revokedDeviceId ?? undefined,
      survivor_count: summary.survivorDeviceIds.length,
      age_ms: nowMillis - summary.createdAtMillis,
    });
    tally.flagged += 1;

    // Throttle re-nudges so a long-pending requirement does not push every
    // tick.
    const lastNudgedAtMillis = typeof doc.get("lastNudgedAtMillis") === "number" ? doc.get("lastNudgedAtMillis") : 0;
    if (nowMillis - lastNudgedAtMillis < NUDGE_MIN_INTERVAL_MS) {
      continue;
    }

    let nudged = 0;
    for (const deviceId of summary.survivorDeviceIds) {
      const deviceSnap = await firestore.doc(`users/${uid}/devices/${deviceId}`).get();
      const deviceData = recordOrUndefined(deviceSnap.data());
      const fcmToken =
        (typeof deviceData?.fcmToken === "string" && deviceData.fcmToken.trim()) ||
        (typeof deviceData?.fcm_token === "string" && deviceData.fcm_token.trim()) ||
        "";
      if (!fcmToken) continue;
      const enqueued = await enqueueRotationNudge(firestore, {
        uid,
        deviceId,
        fcmToken,
        requirementId: summary.requirementId,
        currentVaultKeyID: summary.currentVaultKeyID,
      });
      if (enqueued) nudged += 1;
    }

    await doc.ref
      .set(
        {
          lastNudgedAtMillis: nowMillis,
          lastNudgedAt: Timestamp.now(),
          nudgeAttemptCount: FieldValue.increment(1),
        },
        { merge: true },
      )
      .catch(() => undefined);
    if (nudged > 0) tally.nudged += 1;
  }

  return tally;
}

export const detectStalePendingCloudVaultRotations = onSchedule(
  {
    schedule: "every 30 minutes",
    region: FUNCTIONS_REGION,
  },
  async () =>
    runScheduledJob("detectStalePendingCloudVaultRotations", async () => {
      const tally = await sweepStalePendingCloudVaultRotations({});
      if (tally.flagged || tally.nudged || tally.skipped) {
        logInfo({ event: "cloud_vault.rotation_stale_sweep", ...tally });
      }
    }),
);
