/**
 * AI Inbox P1 push notifications.
 *
 * Two things are load-bearing here and neither fails loudly in production:
 *
 * 1. **The alert gate.** The Mac already rate-limits (P1 only, one per tick, an
 *    hour of cooldown per fingerprint). A trigger that fired on more than a
 *    genuinely-new P1 would defeat that gate and train the user to mute
 *    notifications — while a trigger that fired on less would silently drop a
 *    real alert. Both look identical from the outside.
 * 2. **The payload boundary.** The mirror document is sealed, so the function
 *    cannot read the title. If a future edit ever put decrypted-looking content
 *    into the push, nothing would break — it would just quietly ship the user's
 *    work to a third-party push provider.
 */
import { describe, expect, it, vi } from "vitest";
import { Timestamp } from "firebase-admin/firestore";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

// Hoisted so the module factory below can close over it: the sweeper resolves
// Firestore through `getFirestore()`, so replacing that is how a test double
// gets in without casting a literal to the full `Firestore` interface.
const { getFirestoreMock } = vi.hoisted(() => ({ getFirestoreMock: vi.fn() }));

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return { ...actual, getFirestore: getFirestoreMock };
});
vi.mock("firebase-admin/messaging", () => ({ getMessaging: () => ({ send: vi.fn() }) }));

import { buildFcmMessage, shouldSuppressForDevice } from "../agentNotifications.js";
import { inboxAlertRouting, inboxEventIdFor, inboxKindLabel } from "../aiInboxNotifications.js";

type BuildFcmMessageArgs = Parameters<typeof buildFcmMessage>[0];
type AgentReplyNotificationEvent = BuildFcmMessageArgs["event"];
type DeviceNotificationState = BuildFcmMessageArgs["device"];

const NOW = 1_700_000_000_000;

/** A freshly-mirrored P1 item, exactly as the Mac publisher writes it. */
function mirrorDocument(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "inb_abc",
    fingerprint: "ci_waste:openburnbar:nightly-matrix",
    kind: "ci_waste",
    priority: 1,
    state: "new",
    occurrenceCount: 1,
    firstSeenAt: Timestamp.fromMillis(NOW - 60_000),
    lastSeenAt: Timestamp.fromMillis(NOW - 60_000),
    modelProvenance: "local-rules",
    hasMemoryCandidates: false,
    schemaVersion: 1,
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: "vault-key-1",
    sealedPayload: { schemaVersion: 2, algorithm: "AES-256-GCM", sealedBoxBase64: "…" },
    updatedAt: Timestamp.fromMillis(NOW - 60_000),
    ...overrides,
  };
}

function inboxEvent(overrides: Partial<AgentReplyNotificationEvent> = {}): AgentReplyNotificationEvent {
  const now = Timestamp.fromMillis(NOW);
  return {
    id: "ai_inbox_inb_abc",
    uid: "user-123",
    sourceKind: "ai_inbox_item",
    sourcePath: "ai_inbox_items/inb_abc",
    threadId: "",
    messageId: "inb_abc",
    runtime: "inbox",
    providerLabel: "OpenBurnBar",
    title: "Wasted CI",
    preview: "Open OpenBurnBar to see what needs you.",
    createdAt: now,
    createdAtMillis: NOW,
    updatedAt: now,
    updatedAtMillis: NOW,
    expireAt: Timestamp.fromMillis(NOW + 30 * 24 * 60 * 60 * 1000),
    status: "pending",
    fanoutAttemptCount: 0,
    replyEnabled: false,
    schemaVersion: 1,
    inboxItemId: "inb_abc",
    inboxKind: "ci_waste",
    inboxPriority: 1,
    ...overrides,
  };
}

function device(overrides: Partial<DeviceNotificationState> = {}): DeviceNotificationState {
  return {
    id: "iphone",
    platform: "ios",
    fcmToken: "token-123",
    notificationsEnabled: true,
    appLifecycle: "background",
    lastSeenAtMillis: NOW,
    ...overrides,
  };
}

describe("inboxAlertRouting — which items raise a push", () => {
  it("alerts on a new P1", () => {
    expect(inboxAlertRouting({ itemId: "inb_abc", data: mirrorDocument(), now: NOW })).toEqual({
      itemId: "inb_abc",
      kind: "ci_waste",
      priority: 1,
    });
  });

  it("stays silent for P2 and below", () => {
    for (const priority of [2, 3, 4]) {
      expect(inboxAlertRouting({ itemId: "inb_abc", data: mirrorDocument({ priority }), now: NOW })).toBeUndefined();
    }
  });

  it("stays silent for a non-new state", () => {
    // `updated` is what an occurrence bump writes. Alerting on it would re-fire
    // on every tick for an item the user has already seen.
    for (const state of ["updated", "resolved", "expired"]) {
      expect(inboxAlertRouting({ itemId: "inb_abc", data: mirrorDocument({ state }), now: NOW })).toBeUndefined();
    }
  });

  it("stays silent for a stale item", () => {
    // A Mac that has been offline syncs its backlog all at once. Without this,
    // that first sync fans out every historical P1 as a simultaneous push storm.
    const stale = mirrorDocument({ lastSeenAt: Timestamp.fromMillis(NOW - 7 * 60 * 60 * 1000) });
    expect(inboxAlertRouting({ itemId: "inb_abc", data: stale, now: NOW })).toBeUndefined();
  });

  it("stays silent for a document with no seal", () => {
    expect(
      inboxAlertRouting({ itemId: "inb_abc", data: mirrorDocument({ contentSealed: false }), now: NOW }),
    ).toBeUndefined();
    expect(inboxAlertRouting({ itemId: "inb_abc", data: undefined, now: NOW })).toBeUndefined();
  });

  it("narrows an unknown kind instead of forwarding it to FCM", () => {
    const routing = inboxAlertRouting({
      itemId: "inb_abc",
      data: mirrorDocument({ kind: "kind_from_a_newer_mac" }),
      now: NOW,
    });
    expect(routing?.kind).toBe("system");
    expect(inboxKindLabel("kind_from_a_newer_mac")).toBe("OpenBurnBar");
  });

  it("derives a deterministic event id so a redelivered trigger cannot re-alert", () => {
    expect(inboxEventIdFor("inb_abc")).toBe("ai_inbox_inb_abc");
    expect(inboxEventIdFor("inb/a b")).toBe("ai_inbox_inb_a_b");
  });
});

describe("buildFcmMessage — AI Inbox payload boundary", () => {
  it("carries only the opaque id and the bounded enums", () => {
    const data = buildFcmMessage({ event: inboxEvent(), device: device() }).data ?? {};
    expect(data.type).toBe("ai_inbox_item");
    expect(data.item_id).toBe("inb_abc");
    expect(data.kind).toBe("ci_waste");
    expect(data.priority).toBe("1");
    expect(data.deep_link).toBe("burnbar://inbox/inb_abc");
    expect(data.uid).toBe("user-123");
    expect(String(data.expires_at_millis)).toMatch(/^\d+$/);
    // The sealed half must never appear, under any key.
    expect(data).not.toHaveProperty("summary");
    expect(data).not.toHaveProperty("summaryMarkdown");
    expect(data).not.toHaveProperty("projectName");
    expect(data).not.toHaveProperty("evidence");
    expect(data).not.toHaveProperty("thread_id");
  });

  it("keeps the body generic even when the event title is a kind label", () => {
    const message = buildFcmMessage({ event: inboxEvent(), device: device() });
    expect(message.notification?.title).toBe("Wasted CI");
    expect(message.notification?.body).toBe("Open OpenBurnBar to see what needs you.");
  });

  it("uses the inbox APNs category so iOS routes it to the inbox handler", () => {
    const payload = buildFcmMessage({ event: inboxEvent(), device: device() }).apns?.payload;
    const aps = payload && typeof payload === "object" ? Reflect.get(payload, "aps") : {};
    expect(aps).toMatchObject({ category: "AI_INBOX_ITEM" });
  });

  it("sends Android a data-only message with a per-item collapse key", () => {
    // Per-item, not constant: two different P1 alerts must both land, while a
    // sweeper retry of the same item replaces rather than duplicates.
    const message = buildFcmMessage({ event: inboxEvent(), device: device({ platform: "android" }) });
    expect(message.notification).toBeUndefined();
    expect(message.android?.collapseKey).toBe("ai-inbox-inb_abc");
    const other = buildFcmMessage({
      event: inboxEvent({ id: "ai_inbox_inb_xyz", inboxItemId: "inb_xyz", messageId: "inb_xyz" }),
      device: device({ platform: "android" }),
    });
    expect(other.android?.collapseKey).not.toBe(message.android?.collapseKey);
  });

  it("leaves the agent-reply payload shape untouched", () => {
    const reply = buildFcmMessage({
      event: inboxEvent({
        sourceKind: "cli_session",
        runtime: "codex",
        providerLabel: "Codex",
        threadId: "thread-1",
        replyEnabled: true,
        inboxItemId: undefined,
        inboxKind: undefined,
        inboxPriority: undefined,
      }),
      device: device(),
    });
    expect(reply.data?.type).toBe("agent_reply");
    expect(reply.data).not.toHaveProperty("item_id");
    expect(reply.android?.collapseKey).toBe("agent-reply");
  });
});

describe("shouldSuppressForDevice — inbox alerts ignore the active-thread window", () => {
  it("delivers to a device that is actively in a chat", () => {
    // The active-chat suppression exists so a reply does not double-notify the
    // thread you are reading. An inbox alert is unrelated to any thread, so that
    // window must not swallow it.
    const active = device({ appLifecycle: "active", activeThreadId: "", activeRuntime: "inbox" });
    expect(shouldSuppressForDevice(active, inboxEvent(), NOW)).toBe(false);
  });

  it("still respects a disabled or invalidated device", () => {
    expect(shouldSuppressForDevice(device({ notificationsEnabled: false }), inboxEvent(), NOW)).toBe(true);
    expect(shouldSuppressForDevice(device({ invalidatedAtMillis: NOW }), inboxEvent(), NOW)).toBe(true);
  });

  it("preserves agent-reply suppression", () => {
    const active = device({ appLifecycle: "active", activeThreadId: "thread-1", activeRuntime: "codex" });
    const reply = inboxEvent({ sourceKind: "cli_session", threadId: "thread-1", runtime: "codex" });
    expect(shouldSuppressForDevice(active, reply, NOW)).toBe(true);
  });
});

describe("inbox events ride the shared durable-event machinery", () => {
  it("parses an ai_inbox_item event so the stuck-event sweeper can retry it", async () => {
    // The sweeper is a collection-group query over `agent_notification_events`
    // that drops any document `parseNotificationEvent` rejects. If the parser
    // did not accept the inbox `sourceKind`, a P1 whose first fan-out failed
    // would be silently unrecoverable — and the only symptom would be a
    // notification that never arrives.
    const parsed = await parseEventForSweeper({
      ...inboxEvent(),
      // Firestore hands the sweeper plain data, not the typed object.
      sourceKind: "ai_inbox_item",
    });
    expect(parsed).toBe(true);
  });
});

/**
 * Drives the real `sweepStuckAgentReplyEvents` against a Firestore double
 * holding one stuck inbox event, and reports whether the sweeper recognized it.
 * `parseNotificationEvent` is module-private, so this exercises it through the
 * only path that matters: recovery.
 */
async function parseEventForSweeper(event: Record<string, unknown>): Promise<boolean> {
  const { sweepStuckAgentReplyEvents } = await import("../agentNotifications.js");
  const eventRef = {
    async get() {
      return { exists: true, data: () => event };
    },
    async set() {
      /* status write */
    },
  };
  // Injected through the `getFirestore` module mock rather than passed as a
  // typed argument. That mirrors agentNotifications.test.ts and keeps the
  // double honest: a literal cannot satisfy the full `Firestore` interface, and
  // forcing it with `as unknown as` is what the unsafe-cast gate forbids.
  const firestoreDouble = vi.fn(() => ({
    collection: () => ({
      doc: () => ({
        collection: (name: string) =>
          name === "devices"
            ? {
                async get() {
                  return { docs: [] };
                },
              }
            : { doc: () => eventRef },
      }),
    }),
    collectionGroup: () => {
      const query = {
        where: () => query,
        orderBy: () => query,
        limit: () => query,
        async get() {
          return { docs: [{ id: String(event.id), data: () => event, ref: eventRef }] };
        },
      };
      return query;
    },
  }));
  getFirestoreMock.mockImplementation(firestoreDouble);

  const tally = await sweepStuckAgentReplyEvents({
    messaging: {
      async send() {
        return "ok";
      },
    },
    now: NOW + 10 * 60_000,
  });
  // `skipped` is what an unparseable document produces; anything else means the
  // sweeper understood the event and acted on it.
  return tally.skipped === 0;
}
