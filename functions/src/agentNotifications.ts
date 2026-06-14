/**
 * @fileoverview Cross-surface agent reply notifications.
 *
 * This module owns the durable notification event and push fan-out layer.
 * Runtime execution remains client-owned: inline notification replies are
 * stored as idempotent reply commands so the platform that already knows how
 * to talk to Hermes/Pi/CLI relay can drain them through the normal chat path.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { getMessaging, type Message } from "firebase-admin/messaging";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { errorCode, isRecord } from "./guards.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const REGION = FUNCTIONS_REGION;
const EVENT_COLLECTION = "agent_notification_events";
const DEVICE_COLLECTION = "devices";
const ACTIVE_TTL_MS = 90_000;
const GENERIC_PREVIEW = "OpenBurnBar has a new agent reply.";
/**
 * Firestore TTL for `agent_notification_events` (T-PRV-06). A notification event
 * is ephemeral signalling: once fanned out (or sealed failed) it has no lasting
 * value, so it self-expires after 7 days. The matching `expireAt` ttl:true index
 * in `firestore.indexes.json` performs the deletion. The field is stamped at
 * write time below.
 */
const AGENT_NOTIFICATION_EVENT_TTL_MS = 7 * 24 * 60 * 60 * 1000;
/**
 * A `pending` event older than this is considered stuck (the create-trigger
 * fan-out aborted or partially failed). The sweeper retries it. 2 minutes is
 * long enough that the inline fan-out from the document trigger has settled but
 * short enough that a recovered push plane delivers quickly.
 */
const STUCK_EVENT_GRACE_MS = 2 * 60_000;
/**
 * Stop retrying after this many attempts and seal the event `fanout_failed` so a
 * permanently-undeliverable event becomes operator-visible instead of churning
 * the sweeper forever.
 */
export const MAX_AGENT_FANOUT_ATTEMPTS = 8;
/** Max stuck events handled per scheduled tick. */
const AGENT_FANOUT_SWEEP_BATCH_LIMIT = 50;

export type AgentNotificationSourceKind = "cli_session" | "mobile_assistant_chat";

export interface AgentReplyMessage {
  id: string;
  role: string;
  text?: string;
  timestamp?: unknown;
  isError?: boolean;
}

export interface AgentReplyNotificationEvent {
  id: string;
  uid: string;
  sourceKind: AgentNotificationSourceKind;
  sourcePath: string;
  threadId: string;
  messageId: string;
  runtime: string;
  providerLabel: string;
  title: string;
  preview: string;
  createdAt: FirebaseFirestore.Timestamp;
  createdAtMillis: number;
  updatedAt: FirebaseFirestore.Timestamp;
  updatedAtMillis: number;
  /** Firestore TTL anchor (T-PRV-06); the event self-expires after this time. */
  expireAt: FirebaseFirestore.Timestamp;
  status: "pending" | "fanout_complete" | "fanout_failed";
  fanoutAttemptCount: number;
  replyEnabled: boolean;
  schemaVersion: 1;
}

export interface DeviceNotificationState {
  id: string;
  platform: string;
  fcmToken?: string;
  notificationsEnabled: boolean;
  appLifecycle: "active" | "background" | "inactive" | "terminated" | "unknown";
  activeThreadId?: string;
  activeSurface?: string;
  activeRuntime?: string;
  lastSeenAtMillis: number;
  invalidatedAtMillis?: number;
}

export interface SubmitAgentNotificationReplyRequest {
  eventId: string;
  sealedReplyPayload: CloudVaultSealedPayload;
  vaultKeyID: string;
  deviceId?: string;
  clientReplyId?: string;
}

interface CloudVaultSealedPayload {
  schemaVersion: number;
  algorithm: "AES-256-GCM";
  keyVersion: number;
  vaultKeyID: string;
  sealedBoxBase64: string;
  aad?: string;
}

export interface AgentNotificationReplyCommand {
  id: string;
  uid: string;
  eventId: string;
  threadId: string;
  runtime: string;
  sourceKind: AgentNotificationSourceKind;
  contentSealed: true;
  sealedSchemaVersion: 1;
  vaultKeyID: string;
  sealedReplyPayload: CloudVaultSealedPayload;
  deviceId?: string;
  status: "queued";
  createdAt: FirebaseFirestore.Timestamp;
  updatedAt: FirebaseFirestore.Timestamp;
  schemaVersion: 1;
}

export function latestAssistantReply(data: Record<string, unknown> | undefined): AgentReplyMessage | undefined {
  const sealedRole = stringValue(data?.lastMessageRole);
  const sealedMessageId = stringValue(data?.lastAssistantMessageID);
  if (
    (data?.contentSealed === true || data?.sealedPayload !== undefined) &&
    sealedRole === "assistant" &&
    sealedMessageId
  ) {
    return {
      id: sealedMessageId,
      role: "assistant",
      timestamp: data?.updatedAt ?? data?.updatedAtMillis,
      isError: false,
    };
  }
  const messages = Array.isArray(data?.messages) ? data?.messages : [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const raw = isRecord(messages[index]) ? messages[index] : undefined;
    const role = String(raw?.role ?? "");
    const text = String(raw?.text ?? raw?.content ?? "").trim();
    const id = String(raw?.id ?? "").trim();
    if (role === "assistant" && text && id) {
      return {
        id,
        role,
        text,
        timestamp: raw?.timestamp,
        isError: raw?.isError === true,
      };
    }
  }
  return undefined;
}

export function shouldCreateNotificationEvent(args: {
  before?: Record<string, unknown>;
  after?: Record<string, unknown>;
}): boolean {
  const after = latestAssistantReply(args.after);
  if (!after || after.isError) return false;
  const before = latestAssistantReply(args.before);
  return !before || before.id !== after.id;
}

export function normalizeRuntime(sourceKind: AgentNotificationSourceKind, data: Record<string, unknown>): string {
  const raw = String(data.agent ?? data.runtime ?? data.provider ?? "")
    .trim()
    .toLowerCase();
  if (raw) return raw;
  return sourceKind === "cli_session" ? "codex" : "hermes";
}

export function providerLabel(runtime: string): string {
  switch (runtime.toLowerCase()) {
    case "codex":
      return "Codex";
    case "claude":
      return "Claude";
    case "openclaw":
      return "OpenClaw";
    case "antigravity":
      return "Antigravity";
    case "droid":
    case "factory":
      return "Droid";
    case "forge":
      return "Forge";
    case "pi":
    case "piagent":
    case "pi_agent":
      return "Pi";
    case "hermes":
      return "Hermes";
    default:
      return runtime || "Agent";
  }
}

export function eventIdFor(args: {
  sourceKind: AgentNotificationSourceKind;
  threadId: string;
  messageId: string;
}): string {
  return `${args.sourceKind}_${safeId(args.threadId)}_${safeId(args.messageId)}`;
}

export function shouldSuppressForDevice(
  device: DeviceNotificationState,
  event: {
    threadId: string;
    runtime: string;
  },
  nowMillis: number = Date.now(),
): boolean {
  if (!device.notificationsEnabled) return true;
  if (device.invalidatedAtMillis) return true;
  const fresh = nowMillis - device.lastSeenAtMillis <= ACTIVE_TTL_MS;
  if (!fresh) return false;
  if (device.appLifecycle !== "active") return false;
  if (device.activeThreadId !== event.threadId) return false;
  if (device.activeRuntime && device.activeRuntime !== event.runtime) return false;
  return true;
}

export function buildFcmMessage(args: {
  event: AgentReplyNotificationEvent;
  device: DeviceNotificationState;
}): Message {
  const title = `${args.event.providerLabel} replied`;
  const data: Record<string, string> = {
    type: "agent_reply",
    event_id: args.event.id,
    thread_id: args.event.threadId,
    runtime: args.event.runtime,
    source_kind: args.event.sourceKind,
    title,
    preview: args.event.preview,
    reply_enabled: args.event.replyEnabled ? "true" : "false",
    deep_link: `burnbar://assistants/${encodeURIComponent(args.event.runtime)}?threadId=${encodeURIComponent(args.event.threadId)}`,
  };

  const base: Message = {
    token: args.device.fcmToken ?? "",
    data,
    android: {
      priority: "high",
      collapseKey: `agent-${args.event.threadId}`,
      ttl: 10 * 60 * 1000,
    },
  };

  if (args.device.platform.toLowerCase() === "android") {
    return base;
  }

  return {
    ...base,
    notification: {
      title,
      body: args.event.preview,
    },
    apns: {
      payload: {
        aps: {
          category: "AGENT_REPLY",
          sound: "default",
          "thread-id": args.event.threadId,
        },
      },
      headers: {
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
    },
  };
}

export async function createEventFromThreadWrite(args: {
  uid: string;
  threadId: string;
  sourceKind: AgentNotificationSourceKind;
  sourcePath: string;
  before?: Record<string, unknown>;
  after?: Record<string, unknown>;
  firestore?: FirebaseFirestore.Firestore;
}): Promise<string | undefined> {
  if (!args.after || !shouldCreateNotificationEvent({ before: args.before, after: args.after })) {
    return undefined;
  }
  const reply = latestAssistantReply(args.after);
  if (!reply) return undefined;

  const firestore = args.firestore ?? getFirestore();
  const runtime = normalizeRuntime(args.sourceKind, args.after);
  const label = providerLabel(runtime);
  const eventId = eventIdFor({
    sourceKind: args.sourceKind,
    threadId: args.threadId,
    messageId: reply.id,
  });
  const now = Timestamp.now();
  const nowMillis = Date.now();
  const event: AgentReplyNotificationEvent = {
    id: eventId,
    uid: args.uid,
    sourceKind: args.sourceKind,
    sourcePath: args.sourcePath,
    threadId: args.threadId,
    messageId: reply.id,
    runtime,
    providerLabel: label,
    title: `${label} replied`,
    preview: GENERIC_PREVIEW,
    createdAt: now,
    createdAtMillis: nowMillis,
    updatedAt: now,
    updatedAtMillis: nowMillis,
    expireAt: Timestamp.fromMillis(nowMillis + AGENT_NOTIFICATION_EVENT_TTL_MS),
    status: "pending",
    fanoutAttemptCount: 0,
    replyEnabled: true,
    schemaVersion: 1,
  };

  const ref = firestore.collection("users").doc(args.uid).collection(EVENT_COLLECTION).doc(eventId);
  await ref.create(event).catch(async (err: unknown) => {
    const code = errorCode(err);
    if (code === 6 || code === "already-exists") return;
    throw err;
  });
  return eventId;
}

export async function fanoutAgentReplyEvent(args: {
  uid: string;
  eventId: string;
  firestore?: FirebaseFirestore.Firestore;
  messaging?: Pick<ReturnType<typeof getMessaging>, "send">;
}): Promise<{ sent: number; suppressed: number; rejected: number; failed: number }> {
  const firestore = args.firestore ?? getFirestore();
  const messaging = args.messaging ?? getMessaging();
  const eventRef = firestore.collection("users").doc(args.uid).collection(EVENT_COLLECTION).doc(args.eventId);
  const eventSnap = await eventRef.get();
  if (!eventSnap.exists) return { sent: 0, suppressed: 0, rejected: 0, failed: 0 };
  const event = parseNotificationEvent(eventSnap.data());
  if (!event) return { sent: 0, suppressed: 0, rejected: 0, failed: 0 };
  if (event.status !== "pending") return { sent: 0, suppressed: 0, rejected: 0, failed: 0 };

  const devices = await firestore.collection("users").doc(args.uid).collection(DEVICE_COLLECTION).get();
  let sent = 0;
  let suppressed = 0;
  let rejected = 0;
  let failed = 0;
  const nowMillis = Date.now();

  for (const doc of devices.docs) {
    const device = decodeDevice(doc.id, doc.data());
    if (!device.fcmToken) continue;
    if (shouldSuppressForDevice(device, event, nowMillis)) {
      suppressed += 1;
      continue;
    }
    try {
      await messaging.send(buildFcmMessage({ event, device }));
      sent += 1;
    } catch (err) {
      const code = errorCode(err);
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token" ||
        code === "messaging/mismatched-credential"
      ) {
        rejected += 1;
        await doc.ref.set(
          {
            pushTokenInvalidatedAtMillis: nowMillis,
            pushTokenInvalidationReason: code,
            updated_at_millis: nowMillis,
          },
          { merge: true },
        );
      } else {
        // Per-device error capture: a transient/unhandled send error on ONE
        // device must NOT abort the whole fan-out (the previous `throw err`
        // left the event permanently `pending`, so a single down APNs/FCM
        // path or one bad device wedged notifications for every other device —
        // and the open APNs gate guarantees this error on day one). Record the
        // reason on the device doc and continue; the sweeper retries the event
        // while it stays unsent.
        failed += 1;
        await doc.ref
          .set(
            {
              lastPushErrorAtMillis: nowMillis,
              lastPushErrorReason: String(code ?? "unknown"),
              updated_at_millis: nowMillis,
            },
            { merge: true },
          )
          .catch(() => undefined);
      }
    }
  }

  // Leave the event `pending` (so the sweeper retries) whenever a device
  // errored without being delivered, suppressed, or rejected; otherwise mark it
  // complete. This is what makes the stuck-event sweeper reachable.
  const status: AgentReplyNotificationEvent["status"] = failed > 0 ? "pending" : "fanout_complete";
  await eventRef.set(
    {
      status,
      updatedAt: Timestamp.now(),
      updatedAtMillis: Date.now(),
      fanoutAttemptCount: (event.fanoutAttemptCount ?? 0) + 1,
      fanout: { sent, suppressed, rejected, failed },
    },
    { merge: true },
  );
  return { sent, suppressed, rejected, failed };
}

export type StuckEventOutcome = "retried" | "delivered" | "failed_sealed" | "skipped";

/**
 * Sweep `agent_notification_events` left `pending` past the grace window and
 * re-run their fan-out. Mirrors `retryStuckFcmPushes` / `retryStuckVoIPPushes`:
 * the create-trigger fan-out runs once, so any transient error (now captured
 * per-device rather than thrown) leaves the event `pending` and only this
 * durable sweeper recovers it. Re-running `fanoutAgentReplyEvent` is safe —
 * it no-ops on non-`pending` events and FCM delivery is idempotent on
 * `event_id` via the Android `collapseKey` + client-side dedupe.
 */
export async function sweepStuckAgentReplyEvents(args: {
  firestore?: FirebaseFirestore.Firestore;
  messaging?: Pick<ReturnType<typeof getMessaging>, "send">;
  now?: number;
}): Promise<Record<StuckEventOutcome, number>> {
  const firestore = args.firestore ?? getFirestore();
  const messaging = args.messaging ?? getMessaging();
  const nowMillis = args.now ?? Date.now();
  const cutoff = nowMillis - STUCK_EVENT_GRACE_MS;

  const snapshot = await firestore
    .collectionGroup(EVENT_COLLECTION)
    .where("status", "==", "pending")
    .where("updatedAtMillis", "<=", cutoff)
    .orderBy("updatedAtMillis", "asc")
    .limit(AGENT_FANOUT_SWEEP_BATCH_LIMIT)
    .get();

  const tally: Record<StuckEventOutcome, number> = {
    retried: 0,
    delivered: 0,
    failed_sealed: 0,
    skipped: 0,
  };

  for (const doc of snapshot.docs) {
    const event = parseNotificationEvent(doc.data());
    if (!event) {
      tally.skipped += 1;
      continue;
    }
    if ((event.fanoutAttemptCount ?? 0) >= MAX_AGENT_FANOUT_ATTEMPTS) {
      await doc.ref
        .set(
          {
            status: "fanout_failed",
            updatedAt: Timestamp.now(),
            updatedAtMillis: Date.now(),
          },
          { merge: true },
        )
        .catch(() => undefined);
      tally.failed_sealed += 1;
      continue;
    }
    try {
      const result = await fanoutAgentReplyEvent({
        uid: event.uid,
        eventId: event.id,
        firestore,
        messaging,
      });
      tally[result.sent > 0 ? "delivered" : "retried"] += 1;
    } catch (err) {
      tally.skipped += 1;
      logger.error("sweepStuckAgentReplyEvents: failed to process event", {
        documentPath: doc.ref.path,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  return tally;
}

export const retryStuckAgentReplyEvents = onSchedule(
  {
    schedule: "every 1 minutes",
    region: REGION,
  },
  async () => {
    const tally = await sweepStuckAgentReplyEvents({});
    if (tally.retried || tally.delivered || tally.failed_sealed || tally.skipped) {
      logger.info("retryStuckAgentReplyEvents swept stuck agent-reply events", tally);
    }
  },
);

export const onCliSessionAgentReplyNotification = onDocumentWritten(
  {
    document: "users/{uid}/cli_sessions/{threadId}",
    region: REGION,
  },
  async (event) => {
    const eventId = await createEventFromThreadWrite({
      uid: String(event.params.uid),
      threadId: String(event.params.threadId),
      sourceKind: "cli_session",
      sourcePath: event.data?.after.ref.path ?? "",
      before: event.data?.before.exists ? event.data.before.data() : undefined,
      after: event.data?.after.exists ? event.data.after.data() : undefined,
    });
    if (eventId) {
      await fanoutAgentReplyEvent({ uid: String(event.params.uid), eventId });
    }
  },
);

export const onMobileAssistantAgentReplyNotification = onDocumentWritten(
  {
    document: "users/{uid}/mobile_assistant_chats/{threadId}",
    region: REGION,
  },
  async (event) => {
    const eventId = await createEventFromThreadWrite({
      uid: String(event.params.uid),
      threadId: String(event.params.threadId),
      sourceKind: "mobile_assistant_chat",
      sourcePath: event.data?.after.ref.path ?? "",
      before: event.data?.before.exists ? event.data.before.data() : undefined,
      after: event.data?.after.exists ? event.data.after.data() : undefined,
    });
    if (eventId) {
      await fanoutAgentReplyEvent({ uid: String(event.params.uid), eventId });
    }
  },
);

function decodeDevice(id: string, data: FirebaseFirestore.DocumentData): DeviceNotificationState {
  return {
    id,
    platform: String(data.platform ?? "unknown"),
    fcmToken: stringValue(data.fcmToken) ?? stringValue(data.fcm_token),
    notificationsEnabled: data.agentNotificationsEnabled !== false,
    appLifecycle: parseLifecycle(data.appLifecycle),
    activeThreadId: stringValue(data.activeThreadId) ?? stringValue(data.active_thread_id),
    activeSurface: stringValue(data.activeSurface) ?? stringValue(data.active_surface),
    activeRuntime: stringValue(data.activeRuntime) ?? stringValue(data.active_runtime),
    lastSeenAtMillis:
      numberValue(data.lastSeenAtMillis) ??
      numberValue(data.updated_at_millis) ??
      numberValue(data.updatedAtMillis) ??
      0,
    invalidatedAtMillis: numberValue(data.pushTokenInvalidatedAtMillis),
  };
}

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
    // Tolerate legacy events written before the TTL field existed: fall back to
    // a derived expiry so the sweeper still re-reads them. New events always
    // carry an explicit `expireAt`.
    expireAt:
      raw.expireAt instanceof Timestamp
        ? raw.expireAt
        : Timestamp.fromMillis((numberValue(raw.createdAtMillis) ?? Date.now()) + AGENT_NOTIFICATION_EVENT_TTL_MS),
    status: raw.status,
    fanoutAttemptCount: raw.fanoutAttemptCount,
    replyEnabled: raw.replyEnabled,
    schemaVersion: 1,
  };
}

function parseLifecycle(raw: unknown): DeviceNotificationState["appLifecycle"] {
  switch (raw) {
    case "active":
    case "background":
    case "inactive":
    case "terminated":
      return raw;
    default:
      return "unknown";
  }
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
