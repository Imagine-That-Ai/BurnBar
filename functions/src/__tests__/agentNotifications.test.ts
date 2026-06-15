/**
 * M-023 — the agent-reply notification sweeper must never leak a raw Firebase
 * UID into Cloud Logging.
 *
 * `sweepStuckAgentReplyEvents` catches a per-event fan-out failure and emits a
 * structured `logError`. The stuck event lives at
 * `users/<uid>/agent_notification_events/<id>`, so logging `doc.ref.path`
 * (the pre-fix behavior) pushed the full 28-char UID into Cloud Logging: the
 * scrubber only redacts uid when it is a *key-named* field (uid/userId/user_id),
 * never inside a path-shaped string value. The fix logs `doc.id` only.
 *
 * This test drives the REAL `sweepStuckAgentReplyEvents` against an in-memory
 * Firestore double whose collection-group query yields one stuck event, then
 * forces the per-event fan-out to throw so the catch-block logging runs. It then
 * parses the actual emitted `console.error` payload and asserts the raw UID and
 * the `users/<uid>/` path literal are both absent — and that the harness is a
 * real sentinel (logging the path WOULD have leaked the UID).
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Timestamp } from "firebase-admin/firestore";

const {
  getFirestoreMock,
  getCreatedEvent,
  resetCreatedEvent,
  setRealTimestamp,
  RAW_UID,
  EVENT_ID,
  EVENT_PATH,
  FANOUT_ERROR,
} = vi.hoisted(() => {
  // A realistic 28-char Firebase Auth UID (alphanumeric, the exact shape the
  // scrubber deliberately does NOT regex-match to avoid false positives).
  const RAW_UID = "AbCdEf0123456789AbCdEf0123";
  const EVENT_ID = "cli_session_thread-1_msg-1";
  const EVENT_PATH = `users/${RAW_UID}/agent_notification_events/${EVENT_ID}`;
  const FANOUT_ERROR = "forced fan-out failure for M-023 sweeper test";

  // `parseNotificationEvent` requires `createdAt`/`updatedAt` to be real
  // `Timestamp` instances before the sweep proceeds to fan-out. The real class
  // is only available inside the `vi.mock` factory (importActual runs after
  // hoisting), so capture it there and read it lazily when `data()` is called.
  let realTimestamp: { now: () => unknown } | undefined;
  let createdEvent: unknown;
  const setRealTimestamp = (ts: { now: () => unknown }) => {
    realTimestamp = ts;
  };
  const getCreatedEvent = () => createdEvent;
  const resetCreatedEvent = () => {
    createdEvent = undefined;
  };

  const eventData = () => {
    const now = realTimestamp?.now();
    return {
      id: EVENT_ID,
      uid: RAW_UID,
      sourceKind: "cli_session",
      sourcePath: `users/${RAW_UID}/cli_sessions/thread-1`,
      threadId: "thread-1",
      messageId: "msg-1",
      runtime: "codex",
      providerLabel: "Codex",
      title: "Codex replied",
      preview: "OpenBurnBar has a new agent reply.",
      createdAt: now,
      createdAtMillis: 1_700_000_000_000,
      updatedAt: now,
      updatedAtMillis: 1_700_000_000_000,
      status: "pending",
      fanoutAttemptCount: 0,
      replyEnabled: true,
      schemaVersion: 1,
    };
  };

  // The collection-group sweep returns one stuck event whose `.ref.path` is the
  // full user-scoped path. `fanoutAgentReplyEvent` then re-reads the per-uid
  // event doc; we throw there to drive the sweeper's catch -> logError path.
  const stuckSnapshot = {
    id: EVENT_ID,
    data: () => eventData(),
    ref: {
      path: EVENT_PATH,
      async set() {
        /* not reached on the failure path */
      },
    },
  };

  const collectionGroupQuery = {
    where() {
      return this;
    },
    orderBy() {
      return this;
    },
    limit() {
      return this;
    },
    async get() {
      return { docs: [stuckSnapshot], empty: false, size: 1 };
    },
  };

  const getFirestoreMock = vi.fn(() => ({
    collectionGroup: () => collectionGroupQuery,
    // `fanoutAgentReplyEvent` resolves the event ref through
    // collection("users").doc(uid).collection(...).doc(eventId). Make the event
    // read throw so the sweep falls into its catch block.
    collection: () => ({
      doc: () => ({
        collection: () => ({
          doc: () => ({
            async get(): Promise<never> {
              throw new Error(FANOUT_ERROR);
            },
            async create(data: unknown) {
              createdEvent = data;
            },
          }),
        }),
      }),
    }),
  }));

  return {
    getFirestoreMock,
    getCreatedEvent,
    resetCreatedEvent,
    setRealTimestamp,
    RAW_UID,
    EVENT_ID,
    EVENT_PATH,
    FANOUT_ERROR,
  };
});

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  setRealTimestamp(actual.Timestamp);
  return { ...actual, getFirestore: getFirestoreMock };
});
vi.mock("firebase-admin/messaging", () => ({ getMessaging: () => ({ send: vi.fn() }) }));

import { createEventFromThreadWrite, sweepStuckAgentReplyEvents } from "../agentNotifications.js";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasToMillis(value: unknown): value is { toMillis: () => number } {
  return isRecord(value) && typeof value.toMillis === "function";
}

describe("M-023 agent-reply sweeper never logs a raw Firebase UID", () => {
  let errorSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    resetCreatedEvent();
    errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("emits the event document id, not the user-scoped path, on fan-out failure", async () => {
    const tally = await sweepStuckAgentReplyEvents({});

    // The forced failure drove the catch branch (status stays unrecovered).
    expect(tally.skipped).toBe(1);

    // Exactly one structured error record was emitted.
    expect(errorSpy).toHaveBeenCalledTimes(1);
    const raw = errorSpy.mock.calls[0]?.[0];
    const payload: unknown = JSON.parse(String(raw));
    if (!isRecord(payload)) {
      throw new Error("expected structured log payload");
    }
    const record = payload;

    expect(record.event).toBe("agent_reply_sweeper_event_failed");
    // The fix logs the bare event document id.
    expect(record.document_id).toBe(EVENT_ID);
    expect(record.error).toContain(FANOUT_ERROR);
    // The old field is gone entirely.
    expect(record.document_path).toBeUndefined();

    // The whole serialized record must contain NEITHER the raw 28-char UID NOR
    // any `users/<uid>/` path literal — the core M-023 assertion.
    const serialized = JSON.stringify(record);
    expect(serialized).not.toContain(RAW_UID);
    expect(serialized).not.toContain(`users/${RAW_UID}/`);
    expect(serialized).not.toContain(EVENT_PATH);
  });

  it("is a real sentinel: the pre-fix path literal WOULD have leaked the UID", () => {
    // Proves the scrubber does not redact a UID embedded in a path-shaped value,
    // so asserting the path's absence is a meaningful regression guard rather
    // than a vacuous check.
    const wouldLeak = JSON.stringify({ document_path: EVENT_PATH });
    expect(wouldLeak).toContain(RAW_UID);
    expect(wouldLeak).toContain(`users/${RAW_UID}/`);
  });

  it("stamps a valid expireAt on created notification event (F-RR09-007)", async () => {
    const eventId = await createEventFromThreadWrite({
      uid: "user-1",
      threadId: "thread-1",
      sourceKind: "cli_session",
      sourcePath: "users/user-1/cli_sessions/thread-1",
      before: undefined,
      after: {
        contentSealed: true,
        lastMessageRole: "assistant",
        lastAssistantMessageID: "msg-123",
      },
    });

    expect(eventId).toBe("cli_session_thread-1_msg-123");
    const createdEvent = getCreatedEvent();
    if (!isRecord(createdEvent)) {
      throw new Error("expected notification event to be created");
    }
    expect(createdEvent.expireAt).toBeDefined();
    expect(createdEvent.expireAt).toBeInstanceOf(Timestamp);
    if (!hasToMillis(createdEvent.expireAt)) {
      throw new Error("expected expireAt to expose toMillis()");
    }
    // expireAt should be ~30 days in the future (plus or minus a few seconds)
    const expectedExpiry = Date.now() + 30 * 24 * 60 * 60 * 1000;
    const diff = Math.abs(createdEvent.expireAt.toMillis() - expectedExpiry);
    expect(diff).toBeLessThan(10000); // within 10 seconds
  });
});
