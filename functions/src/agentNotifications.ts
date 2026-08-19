/**
 * @fileoverview Cross-surface agent reply notifications.
 *
 * This module owns the durable notification event and push fan-out layer.
 * Runtime execution remains client-owned: inline notification replies are
 * stored as idempotent reply commands so the platform that already knows how
 * to talk to Hermes/Pi/CLI relay can drain them through the normal chat path.
 *
 * The event collection is shared by every "something happened while you were
 * away" surface — agent replies and AI Inbox P1 alerts — so all of them inherit
 * one device fan-out, one per-device error containment policy, and one stuck
 * event sweeper. `sourceKind` is the discriminator; see `aiInboxNotifications.ts`
 * for the inbox producer.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { getMessaging, type Message } from "firebase-admin/messaging";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { logError, logInfo } from "./logging.js";
import { errorCode, isRecord } from "./guards.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const REGION = FUNCTIONS_REGION;
const EVENT_COLLECTION = "agent_notification_events";
const DEVICE_COLLECTION = "devices";
const ACTIVE_TTL_MS = 90_000;
const GENERIC_PREVIEW = "OpenBurnBar has a new agent reply.";
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
const MAX_AGENT_FANOUT_ATTEMPTS = 8;
/** Max stuck events handled per scheduled tick. */
const AGENT_FANOUT_SWEEP_BATCH_LIMIT = 50;

export const AGENT_NOTIFICATION_EVENT_TTL_MS = 30 * 24 * 60 * 60 * 1000;

// Module-private: consumers pass string literals that are checked against
// this union through createNotificationEvent's parameter type.
type AgentNotificationSourceKind = "cli_session" | "mobile_assistant_chat" | "ai_inbox_item";

// A Set<string> accepts an `unknown` narrowed to string without any cast, so
// the membership test alone establishes the type.
const NOTIFICATION_SOURCE_KINDS: ReadonlySet<string> = new Set<string>([
  "cli_session",
  "mobile_assistant_chat",
  "ai_inbox_item",
] satisfies readonly AgentNotificationSourceKind[]);

function isNotificationSourceKind(raw: unknown): raw is AgentNotificationSourceKind {
  return typeof raw === "string" && NOTIFICATION_SOURCE_KINDS.has(raw);
}

interface AgentReplyMessage {
  id: string;
  role: string;
  text?: string;
  timestamp?: unknown;
  isError?: boolean;
}

// Module-private: every use is inside this module, and the tests derive the
// shape structurally via Parameters<typeof buildFcmMessage>[0]["event"]
// rather than importing the name. Keeping it unexported holds the
// hand-maintained schema surface at its cap
// (budgets/hand-maintained-ts-baseline.json).
interface AgentReplyNotificationEvent {
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
  /** Firestore TTL field — the doc self-deletes once this passes (F-RR09-007). */
  expireAt: FirebaseFirestore.Timestamp;
  status: "pending" | "fanout_complete" | "fanout_failed";
  fanoutAttemptCount: number;
  replyEnabled: boolean;
  schemaVersion: 1;
  /**
   * AI Inbox routing, present only on `ai_inbox_item` events. The document body
   * at `users/{uid}/ai_inbox_items/{itemId}` is sealed, so the function cannot
   * read the title — the client hydrates and decrypts after delivery. Only the
   * opaque id plus the bounded `kind`/`priority` enums travel.
   */
  inboxItemId?: string;
  inboxKind?: string;
  inboxPriority?: number;
}

interface DeviceNotificationState {
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

function sealedAssistantReply(data: Record<string, unknown> | undefined): AgentReplyMessage | undefined {
  const isSealed = data?.contentSealed === true || data?.sealedPayload !== undefined;
  if (!isSealed) return undefined;
  const sealedRole = stringValue(data?.lastMessageRole);
  if (sealedRole !== "assistant") return undefined;
  const sealedMessageId = stringValue(data?.lastAssistantMessageID);
  if (!sealedMessageId) return undefined;
  return {
    id: sealedMessageId,
    role: "assistant",
    timestamp: data?.updatedAt ?? data?.updatedAtMillis,
    isError: false,
  };
}

function assistantReplyFromMessage(raw: Record<string, unknown> | undefined): AgentReplyMessage | undefined {
  const role = String(raw?.role ?? "");
  if (role !== "assistant") return undefined;
  const text = String(raw?.text ?? raw?.content ?? "").trim();
  if (!text) return undefined;
  const id = String(raw?.id ?? "").trim();
  if (!id) return undefined;
  return {
    id,
    role,
    text,
    timestamp: raw?.timestamp,
    isError: raw?.isError === true,
  };
}

function latestAssistantReplyFromMessages(data: Record<string, unknown> | undefined): AgentReplyMessage | undefined {
  const messages = Array.isArray(data?.messages) ? data?.messages : [];
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const raw = isRecord(messages[index]) ? messages[index] : undefined;
    const reply = assistantReplyFromMessage(raw);
    if (reply) return reply;
  }
  return undefined;
}

export function latestAssistantReply(data: Record<string, unknown> | undefined): AgentReplyMessage | undefined {
  return sealedAssistantReply(data) ?? latestAssistantReplyFromMessages(data);
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

function normalizeRuntime(sourceKind: AgentNotificationSourceKind, data: Record<string, unknown>): string {
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
    sourceKind?: AgentNotificationSourceKind;
  },
  nowMillis: number = Date.now(),
): boolean {
  if (!device.notificationsEnabled) return true;
  if (device.invalidatedAtMillis) return true;
  // Inbox alerts are not tied to a conversation, so the "you are already
  // looking at this thread" window never applies — a P1 that fired while the
  // user happens to have a chat open is exactly the case worth interrupting.
  if (event.sourceKind === "ai_inbox_item") return false;
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
  const inbox = args.event.sourceKind === "ai_inbox_item";
  const title = inbox ? args.event.title : `${args.event.providerLabel} replied`;
  const itemId = args.event.inboxItemId ?? args.event.messageId;
  // Privacy: push payloads must not carry stable conversation correlators, nor
  // any inbox content. The client resolves the conversation handle from the
  // durable agent_notification_events/{event_id} document, and the inbox body
  // from the SEALED ai_inbox_items/{item_id} document, after delivery
  // (OPUS-F-006). `kind`/`priority` are bounded enums, not user text.

  // The push must never outlive the event doc, and never sits open longer than
  // the 10-minute cap even when the event has no TTL of its own.
  const cappedExpiresAtMillis = Date.now() + 10 * 60 * 1000;
  const eventExpiresAtMillis = args.event.expireAt?.toMillis();
  const expiresAtMillis =
    eventExpiresAtMillis === undefined
      ? cappedExpiresAtMillis
      : Math.min(cappedExpiresAtMillis, eventExpiresAtMillis);
  const data: Record<string, string> = inbox
    ? {
        type: "ai_inbox_item",
        event_id: args.event.id,
        item_id: itemId,
        kind: args.event.inboxKind ?? "system",
        priority: String(args.event.inboxPriority ?? 1),
        source_kind: args.event.sourceKind,
        title,
        preview: args.event.preview,
        uid: args.event.uid,
        expires_at_millis: String(expiresAtMillis),
        deep_link: `burnbar://inbox/${encodeURIComponent(itemId)}`,
      }
    : {
        type: "agent_reply",
        event_id: args.event.id,
        runtime: args.event.runtime,
        source_kind: args.event.sourceKind,
        title,
        preview: args.event.preview,
        reply_enabled: args.event.replyEnabled ? "true" : "false",
        uid: args.event.uid,
        expires_at_millis: String(expiresAtMillis),
        deep_link: `burnbar://assistants/${encodeURIComponent(args.event.runtime)}?eventId=${encodeURIComponent(args.event.id)}`,
      };

  const base: Message = {
    token: args.device.fcmToken ?? "",
    data,
    android: {
      priority: "high",
      // A per-item collapse key so two different P1 alerts both land, while a
      // sweeper retry of the SAME item still replaces rather than duplicates.
      collapseKey: inbox ? `ai-inbox-${itemId}` : "agent-reply",
      ttl: 10 * 60 * 1000,
    },
  };

  if (args.device.platform.toLowerCase() === "android") {
    return base;
  }

  return {
    token: base.token,
    data: base.data,
    android: base.android,
    notification: {
      title,
      body: args.event.preview,
    },
    apns: {
      payload: {
        aps: {
          category: inbox ? "AI_INBOX_ITEM" : "AGENT_REPLY",
          sound: "default",
        },
      },
      headers: {
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
    },
  };
}

/**
 * Write one durable notification event, idempotently.
 *
 * `create` (not `set`) is what makes a re-delivered platform trigger a no-op:
 * the second attempt hits ALREADY_EXISTS and is swallowed, so a retried event
 * never re-alerts. Every producer — agent replies and AI Inbox alerts alike —
 * goes through here so they share that guarantee and the TTL stamp.
 */
export async function createNotificationEvent(args: {
  event: Omit<
    AgentReplyNotificationEvent,
    | "createdAt"
    | "createdAtMillis"
    | "updatedAt"
    | "updatedAtMillis"
    | "expireAt"
    | "status"
    | "fanoutAttemptCount"
    | "schemaVersion"
  >;
  firestore?: FirebaseFirestore.Firestore;
}): Promise<string | undefined> {
  const firestore = args.firestore ?? getFirestore();
  const now = Timestamp.now();
  const nowMillis = Date.now();
  const event: AgentReplyNotificationEvent = {
    ...args.event,
    createdAt: now,
    createdAtMillis: nowMillis,
    updatedAt: now,
    updatedAtMillis: nowMillis,
    expireAt: Timestamp.fromMillis(nowMillis + AGENT_NOTIFICATION_EVENT_TTL_MS),
    status: "pending",
    fanoutAttemptCount: 0,
    schemaVersion: 1,
  };

  const ref = firestore.collection("users").doc(event.uid).collection(EVENT_COLLECTION).doc(event.id);
  await ref.create(event).catch(async (err: unknown) => {
    const code = errorCode(err);
    if (code === 6 || code === "already-exists") return;
    throw err;
  });
  return event.id;
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

  const runtime = normalizeRuntime(args.sourceKind, args.after);
  const label = providerLabel(runtime);
  return createNotificationEvent({
    firestore: args.firestore,
    event: {
      id: eventIdFor({
        sourceKind: args.sourceKind,
        threadId: args.threadId,
        messageId: reply.id,
      }),
      uid: args.uid,
      sourceKind: args.sourceKind,
      sourcePath: args.sourcePath,
      threadId: args.threadId,
      messageId: reply.id,
      runtime,
      providerLabel: label,
      title: `${label} replied`,
      preview: GENERIC_PREVIEW,
      replyEnabled: true,
    },
  });
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

type StuckEventOutcome = "retried" | "delivered" | "failed_sealed" | "skipped";

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
      // Log the bare event document id, never `doc.ref.path` — the path is
      // `users/<uid>/agent_notification_events/<id>` and would carry the raw
      // UID into Cloud Logging (F-RR09-002). The scrubber also redacts
      // path-shaped UIDs as defense-in-depth.
      logError({
        event: "agent_reply_sweeper_event_failed",
        document_id: doc.id,
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
      logInfo({ event: "retry_stuck_agent_reply_events_swept", ...tally });
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
    !isNotificationSourceKind(raw.sourceKind) ||
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
    // Lenient for legacy docs written before the TTL field existed: derive a
    // sensible expireAt from createdAt so the in-memory object is well-formed
    // and a later write back-fills the TTL field (F-RR09-007).
    expireAt:
      raw.expireAt instanceof Timestamp
        ? raw.expireAt
        : Timestamp.fromMillis((numberValue(raw.createdAtMillis) ?? 0) + AGENT_NOTIFICATION_EVENT_TTL_MS),
    status: raw.status,
    fanoutAttemptCount: raw.fanoutAttemptCount,
    replyEnabled: raw.replyEnabled,
    schemaVersion: 1,
    inboxItemId: stringValue(raw.inboxItemId),
    inboxKind: stringValue(raw.inboxKind),
    inboxPriority: numberValue(raw.inboxPriority),
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
