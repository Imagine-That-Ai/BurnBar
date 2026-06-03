/**
 * @fileoverview Agent notification reply callable.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";

import { assertAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { errorCode, isRecord } from "../guards.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import type { AgentNotificationReplyCommand, AgentReplyNotificationEvent } from "../agentNotifications.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const REGION = FUNCTIONS_REGION;
const EVENT_COLLECTION = "agent_notification_events";
const REPLY_COLLECTION = "agent_notification_replies";

export const submitAgentNotificationReply = onCall(
  { region: REGION, enforceAppCheck: getConfig().enforceAppCheck },
  wrapCallableHandler("submitAgentNotificationReply", async (request) => {
    assertAppCheck(request);
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Sign in before replying.");
    }
    const uid = request.auth.uid;
    const data = parseSubmitReplyRequest(request.data);
    const eventId = boundedString(data.eventId, "eventId", 512);
    const sealedReplyPayload = parseSealedPayload(data.sealedReplyPayload);
    const vaultKeyID = boundedString(data.vaultKeyID, "vaultKeyID", 128);
    if (sealedReplyPayload.vaultKeyID !== vaultKeyID) {
      throw new HttpsError("invalid-argument", "vaultKeyID must match sealedReplyPayload.vaultKeyID.");
    }
    const deviceId = optionalBoundedString(data.deviceId, "deviceId", 160);
    const clientReplyId = optionalBoundedString(data.clientReplyId, "clientReplyId", 160);
    const firestore = getFirestore();
    const eventRef = firestore.collection("users").doc(uid).collection(EVENT_COLLECTION).doc(eventId);
    const eventSnap = await eventRef.get();
    if (!eventSnap.exists) {
      throw new HttpsError("not-found", "Notification event not found.");
    }
    const event = parseNotificationEvent(eventSnap.data());
    if (!event) {
      throw new HttpsError("failed-precondition", "Notification event is invalid.");
    }
    const replyId = clientReplyId ?? `${eventId}_${safeId(deviceId ?? "device")}`;
    const now = Timestamp.now();
    const command: AgentNotificationReplyCommand = {
      id: replyId,
      uid,
      eventId,
      threadId: event.threadId,
      runtime: event.runtime,
      sourceKind: event.sourceKind,
      contentSealed: true,
      sealedSchemaVersion: 1,
      vaultKeyID,
      sealedReplyPayload,
      deviceId,
      status: "queued",
      createdAt: now,
      updatedAt: now,
      schemaVersion: 1,
    };
    await firestore
      .collection("users")
      .doc(uid)
      .collection(REPLY_COLLECTION)
      .doc(replyId)
      .set(command, { merge: false })
      .catch(async (err: unknown) => {
        const code = errorCode(err);
        if (code === 6 || code === "already-exists") return;
        throw err;
      });
    logInfo({
      event: "callable_info",
      message: "agent_notification_reply_queued",
      event_id: eventId,
      reply_id: replyId,
      source_kind: event.sourceKind,
    });
    return { ok: true, replyId };
  }),
);

function parseNotificationEvent(raw: unknown): AgentReplyNotificationEvent | undefined {
  if (!isRecord(raw)) return undefined;
  if (
    typeof raw.id !== "string" ||
    typeof raw.uid !== "string" ||
    (raw.sourceKind !== "cli_session" && raw.sourceKind !== "mobile_assistant_chat") ||
    typeof raw.sourcePath !== "string" ||
    typeof raw.threadId !== "string" ||
    typeof raw.messageId !== "string" ||
    typeof raw.runtime !== "string" ||
    typeof raw.providerLabel !== "string" ||
    typeof raw.title !== "string" ||
    typeof raw.preview !== "string" ||
    !(raw.createdAt instanceof Timestamp) ||
    !(raw.updatedAt instanceof Timestamp) ||
    (raw.status !== "pending" && raw.status !== "fanout_complete" && raw.status !== "fanout_failed") ||
    typeof raw.fanoutAttemptCount !== "number" ||
    typeof raw.replyEnabled !== "boolean" ||
    raw.schemaVersion !== 1
  ) {
    return undefined;
  }
  return {
    id: raw.id,
    uid: raw.uid,
    sourceKind: raw.sourceKind,
    sourcePath: raw.sourcePath,
    threadId: raw.threadId,
    messageId: raw.messageId,
    runtime: raw.runtime,
    providerLabel: raw.providerLabel,
    title: raw.title,
    preview: raw.preview,
    createdAt: raw.createdAt,
    createdAtMillis: numberValue(raw.createdAtMillis) ?? 0,
    updatedAt: raw.updatedAt,
    updatedAtMillis: numberValue(raw.updatedAtMillis) ?? 0,
    status: raw.status,
    fanoutAttemptCount: raw.fanoutAttemptCount,
    replyEnabled: raw.replyEnabled,
    schemaVersion: 1,
  };
}

function parseSubmitReplyRequest(raw: unknown): {
  eventId: unknown;
  sealedReplyPayload: unknown;
  vaultKeyID: unknown;
  deviceId?: string;
  clientReplyId?: string;
} {
  return isRecord(raw)
    ? {
        eventId: raw.eventId,
        sealedReplyPayload: raw.sealedReplyPayload,
        vaultKeyID: raw.vaultKeyID,
        deviceId: stringValue(raw.deviceId),
        clientReplyId: stringValue(raw.clientReplyId),
      }
    : {
        eventId: undefined,
        sealedReplyPayload: undefined,
        vaultKeyID: undefined,
      };
}

function parseSealedPayload(raw: unknown): AgentNotificationReplyCommand["sealedReplyPayload"] {
  if (!isRecord(raw)) {
    throw new HttpsError("invalid-argument", "sealedReplyPayload is required.");
  }
  const schemaVersion = numberValue(raw.schemaVersion);
  const keyVersion = numberValue(raw.keyVersion);
  const algorithm = stringValue(raw.algorithm);
  const vaultKeyID = stringValue(raw.vaultKeyID);
  const sealedBoxBase64 = stringValue(raw.sealedBoxBase64);
  if (
    schemaVersion !== 1 ||
    algorithm !== "AES-256-GCM" ||
    keyVersion !== 1 ||
    !vaultKeyID ||
    !sealedBoxBase64 ||
    sealedBoxBase64.length > 32_000
  ) {
    throw new HttpsError("invalid-argument", "sealedReplyPayload is invalid.");
  }
  return {
    schemaVersion,
    algorithm,
    keyVersion,
    vaultKeyID,
    sealedBoxBase64,
  };
}

function boundedString(raw: unknown, field: string, max: number): string {
  const value = String(raw ?? "").trim();
  if (!value) throw new HttpsError("invalid-argument", `${field} is required.`);
  if (value.length > max) {
    throw new HttpsError("invalid-argument", `${field} is too long.`);
  }
  return value;
}

function optionalBoundedString(raw: unknown, field: string, max: number): string | undefined {
  if (raw === undefined || raw === null) return undefined;
  return boundedString(raw, field, max);
}

function stringValue(raw: unknown): string | undefined {
  return typeof raw === "string" && raw.trim() ? raw.trim() : undefined;
}

function numberValue(raw: unknown): number | undefined {
  return typeof raw === "number" && Number.isFinite(raw) ? raw : undefined;
}

function safeId(raw: string): string {
  return raw.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 240);
}
