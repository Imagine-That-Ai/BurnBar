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
import { createHash } from "node:crypto";
import { errorCode, isRecord } from "./guards.js";

const REGION = "us-central1";
const EVENT_COLLECTION = "agent_notification_events";
const REPLY_COLLECTION = "agent_notification_replies";
const DEVICE_COLLECTION = "devices";
const ACTIVE_TTL_MS = 90_000;
const MAX_PREVIEW_CHARS = 180;

export type AgentNotificationSourceKind = "cli_session" | "mobile_assistant_chat";

export interface AgentReplyMessage {
  id: string;
  role: string;
  text: string;
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
  replyText: string;
  deviceId?: string;
  clientReplyId?: string;
}

export interface AgentNotificationReplyCommand {
  id: string;
  uid: string;
  eventId: string;
  threadId: string;
  runtime: string;
  sourceKind: AgentNotificationSourceKind;
  replyText: string;
  deviceId?: string;
  status: "queued";
  createdAt: FirebaseFirestore.Timestamp;
  updatedAt: FirebaseFirestore.Timestamp;
  schemaVersion: 1;
}

export function latestAssistantReply(
  data: Record<string, unknown> | undefined
): AgentReplyMessage | undefined {
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
  return !before || before.id !== after.id || before.text !== after.text;
}

export function normalizeRuntime(
  sourceKind: AgentNotificationSourceKind,
  data: Record<string, unknown>
): string {
  const raw = String(data.agent ?? data.runtime ?? data.provider ?? "").trim().toLowerCase();
  if (raw) return raw;
  return sourceKind === "cli_session" ? "codex" : "hermes";
}

export function providerLabel(runtime: string): string {
  switch (runtime.toLowerCase()) {
    case "codex": return "Codex";
    case "claude": return "Claude";
    case "openclaw": return "OpenClaw";
    case "antigravity": return "Antigravity";
    case "droid":
    case "factory": return "Droid";
    case "forge": return "Forge";
    case "pi":
    case "piagent":
    case "pi_agent": return "Pi";
    case "hermes": return "Hermes";
    default: return runtime || "Agent";
  }
}

export function eventIdFor(args: {
  sourceKind: AgentNotificationSourceKind;
  threadId: string;
  messageId: string;
  messageText?: string;
}): string {
  const contentHash = args.messageText
    ? `_${createHash("sha256").update(args.messageText).digest("hex").slice(0, 16)}`
    : "";
  return `${args.sourceKind}_${safeId(args.threadId)}_${safeId(args.messageId)}${contentHash}`;
}

export function truncatePreview(text: string): string {
  const normalized = text.replace(/\s+/g, " ").trim();
  if (normalized.length <= MAX_PREVIEW_CHARS) return normalized;
  return `${normalized.slice(0, MAX_PREVIEW_CHARS - 1).trimEnd()}…`;
}

export function shouldSuppressForDevice(device: DeviceNotificationState, event: {
  threadId: string;
  runtime: string;
}, nowMillis: number = Date.now()): boolean {
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
    messageText: reply.text,
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
    preview: truncatePreview(reply.text),
    createdAt: now,
    createdAtMillis: nowMillis,
    updatedAt: now,
    updatedAtMillis: nowMillis,
    status: "pending",
    fanoutAttemptCount: 0,
    replyEnabled: true,
    schemaVersion: 1,
  };

  const ref = firestore
    .collection("users").doc(args.uid)
    .collection(EVENT_COLLECTION).doc(eventId);
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
}): Promise<{ sent: number; suppressed: number; rejected: number }> {
  const firestore = args.firestore ?? getFirestore();
  const messaging = args.messaging ?? getMessaging();
  const eventRef = firestore
    .collection("users").doc(args.uid)
    .collection(EVENT_COLLECTION).doc(args.eventId);
  const eventSnap = await eventRef.get();
  if (!eventSnap.exists) return { sent: 0, suppressed: 0, rejected: 0 };
  const event = parseNotificationEvent(eventSnap.data());
  if (!event) return { sent: 0, suppressed: 0, rejected: 0 };
  if (event.status !== "pending") return { sent: 0, suppressed: 0, rejected: 0 };

  const devices = await firestore
    .collection("users").doc(args.uid)
    .collection(DEVICE_COLLECTION)
    .get();
  let sent = 0;
  let suppressed = 0;
  let rejected = 0;
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
        await doc.ref.set({
          pushTokenInvalidatedAtMillis: nowMillis,
          pushTokenInvalidationReason: code,
          updated_at_millis: nowMillis,
        }, { merge: true });
      } else {
        throw err;
      }
    }
  }

  await eventRef.set({
    status: "fanout_complete",
    updatedAt: Timestamp.now(),
    updatedAtMillis: Date.now(),
    fanoutAttemptCount: (event.fanoutAttemptCount ?? 0) + 1,
    fanout: { sent, suppressed, rejected },
  }, { merge: true });
  return { sent, suppressed, rejected };
}

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
  }
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
  }
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
    lastSeenAtMillis: numberValue(data.lastSeenAtMillis)
      ?? numberValue(data.updated_at_millis)
      ?? numberValue(data.updatedAtMillis)
      ?? 0,
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
