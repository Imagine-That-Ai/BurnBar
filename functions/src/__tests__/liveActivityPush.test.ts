import { describe, expect, it, vi } from "vitest";
import { Timestamp } from "firebase-admin/firestore";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

vi.mock("../../../packages/functions-shared/src/resilienceHelpers.js", () => ({
  firestoreWithResilience: async (_label: string, fn: () => Promise<unknown>) => fn(),
  pushWithResilience: async (_label: string, fn: () => Promise<unknown>) => fn(),
}));

import { DEFAULT_LIVEACTIVITY_APNS_TOPIC } from "../../../functions-media/src/domains/push/apnsSender.js";
import {
  buildLiveActivityApsPayload,
  fanoutLiveActivityUpdate,
  liveActivityChangeFromAction,
  liveActivityChangeFromSession,
  selectLiveActivityDevices,
} from "../../../functions-media/src/domains/push/liveActivityPush.js";

type LiveActivityPushArgs = Parameters<NonNullable<Parameters<typeof fanoutLiveActivityUpdate>[0]["push"]>>[0];

/** Reads the APNs content-state from a push payload, narrowing without a cast. */
function contentStateOf(payload: Record<string, unknown>): unknown {
  const aps = payload["aps"];
  if (typeof aps !== "object" || aps === null) return undefined;
  return "content-state" in aps ? aps["content-state"] : undefined;
}

const NOW = Date.parse("2026-08-21T18:00:00.000Z");
const STARTED = Timestamp.fromMillis(NOW - 90_000);
const TOKEN = "ab".repeat(32);

const FORBIDDEN_PAYLOAD_KEYS = [
  "screenshot",
  "pixel",
  "frame",
  "png",
  "blake3",
  "hash",
  "token",
  "secret",
  "denyReason",
  "actionKind",
  "scopeRuleId",
  "pendingApprovalId",
  "approvalId",
  "manifestHashHex",
  "auditHeadHashHex",
];

function flattenKeys(value: unknown, prefix = ""): string[] {
  if (!value || typeof value !== "object") return prefix ? [prefix] : [];
  return Object.entries(value).flatMap(([key, child]) => {
    const path = prefix ? `${prefix}.${key}` : key;
    if (child && typeof child === "object") return [path, ...flattenKeys(child, path)];
    return [path];
  });
}

describe("liveActivityChangeFromSession", () => {
  it("emits an update on session create", () => {
    const change = liveActivityChangeFromSession({
      sessionId: "sess-1",
      after: { mode: "agent_watch", actionCount: 0, startedAt: STARTED },
      nowMs: NOW,
    });
    expect(change).toMatchObject({
      event: "update",
      sessionId: "sess-1",
      state: {
        appName: "Agent Live",
        lastAction: "Watching Mac",
        actionsCount: 0,
        approvalPending: false,
        elapsed: 90,
        remoteRefreshEnabled: true,
      },
    });
  });

  it("emits end + Halted on panic/user halt and ignores a second end write", () => {
    const first = liveActivityChangeFromSession({
      sessionId: "sess-1",
      before: { mode: "agent_watch", actionCount: 3, startedAt: STARTED },
      after: {
        mode: "agent_watch",
        actionCount: 3,
        startedAt: STARTED,
        endedAt: Timestamp.fromMillis(NOW),
        endReason: "user_halt",
      },
      nowMs: NOW,
    });
    expect(first).toMatchObject({ event: "end", state: { lastAction: "Halted", approvalPending: false } });

    const replay = liveActivityChangeFromSession({
      sessionId: "sess-1",
      before: { endedAt: Timestamp.fromMillis(NOW), endReason: "user_halt" },
      after: { endedAt: Timestamp.fromMillis(NOW), endReason: "user_halt", actionCount: 3 },
      nowMs: NOW,
    });
    expect(replay).toBeUndefined();
  });

  it("ignores metering-only session updates while the session is still live", () => {
    expect(
      liveActivityChangeFromSession({
        sessionId: "sess-1",
        before: { mode: "browser", actionCount: 0, startedAt: STARTED },
        after: { mode: "browser", actionCount: 0, startedAt: STARTED, quotaStartMeteredEventId: "e1" },
        nowMs: NOW,
      }),
    ).toBeUndefined();
  });
});

describe("liveActivityChangeFromAction", () => {
  it("marks approval pending without inventing an approval id", () => {
    const change = liveActivityChangeFromAction({
      action: {
        sessionId: "sess-1",
        status: "awaiting_approval",
        entryIndex: 2,
        actionKind: "click Submit on bank.example",
        denyReason: "user secret",
      },
      session: { mode: "system", startedAt: STARTED, actionCount: 1 },
      nowMs: NOW,
    });
    expect(change).toMatchObject({
      event: "update",
      state: {
        appName: "System",
        lastAction: "Approval pending",
        approvalPending: true,
        actionsCount: 3,
      },
    });
    expect(change?.state).not.toHaveProperty("pendingApprovalId");
  });

  it("clears pending on an executed action and ends if the session already halted", () => {
    const live = liveActivityChangeFromAction({
      action: { sessionId: "sess-1", status: "executed", entryIndex: 4 },
      session: { mode: "agent_watch", startedAt: STARTED },
      nowMs: NOW,
    });
    expect(live).toMatchObject({
      event: "update",
      state: { lastAction: "Action done", approvalPending: false, actionsCount: 5 },
    });

    const halted = liveActivityChangeFromAction({
      action: { sessionId: "sess-1", status: "executed", entryIndex: 4 },
      session: { endReason: "panic_phone_gesture", startedAt: STARTED },
      nowMs: NOW,
    });
    expect(halted).toMatchObject({ event: "end", state: { lastAction: "Halted", approvalPending: false } });
  });
});

describe("DEFAULT_LIVEACTIVITY_APNS_TOPIC", () => {
  it("matches the iOS app bundle id plus Apple's liveactivity suffix", () => {
    expect(DEFAULT_LIVEACTIVITY_APNS_TOPIC).toBe("com.openburnbar.app.push-type.liveactivity");
  });
});

describe("buildLiveActivityApsPayload", () => {
  it("uses ActivityKit content-state keys and omits secrets, pixels, and approval ids", () => {
    const payload = buildLiveActivityApsPayload({
      event: "update",
      timestampSeconds: 1_700_000_000,
      state: {
        appName: "Agent Live",
        lastAction: "Approval pending",
        actionsCount: 2,
        approvalPending: true,
        elapsed: 12,
        remoteRefreshEnabled: true,
      },
    });
    expect(payload).toEqual({
      aps: {
        timestamp: 1_700_000_000,
        event: "update",
        "content-state": {
          appName: "Agent Live",
          lastAction: "Approval pending",
          actionsCount: 2,
          approvalPending: true,
          elapsed: 12,
          remoteRefreshEnabled: true,
        },
      },
    });
    const keys = flattenKeys(payload).join(" ");
    for (const forbidden of FORBIDDEN_PAYLOAD_KEYS) {
      expect(keys).not.toContain(forbidden);
    }
  });
});

describe("selectLiveActivityDevices", () => {
  it("binds only iOS tokens for the matching session", () => {
    const selected = selectLiveActivityDevices(
      [
        {
          id: "phone",
          data: {
            platform: "ios",
            liveActivityPushToken: TOKEN,
            liveActivitySessionId: "sess-1",
          },
        },
        {
          id: "other-session",
          data: {
            platform: "iOS",
            liveActivityPushToken: TOKEN,
            liveActivitySessionId: "sess-2",
          },
        },
        {
          id: "android",
          data: {
            platform: "Android",
            liveActivityPushToken: TOKEN,
            liveActivitySessionId: "sess-1",
          },
        },
        {
          id: "bad-token",
          data: {
            platform: "ios",
            liveActivityPushToken: "not-hex",
            liveActivitySessionId: "sess-1",
          },
        },
      ],
      "sess-1",
    );
    expect(selected.map((device) => device.id)).toEqual(["phone"]);
  });
});

describe("fanoutLiveActivityUpdate", () => {
  function fakeFirestore(docs: Array<{ id: string; data: Record<string, unknown> }>) {
    const updates: Array<{ path: string; data: Record<string, unknown> }> = [];
    return {
      updates,
      firestore: {
        collection: (name: string) => {
          if (name !== "users") throw new Error(`unexpected collection ${name}`);
          return {
            doc: () => ({
              collection: (sub: string) => {
                if (sub !== "devices") throw new Error(`unexpected sub ${sub}`);
                // The production query narrows on `liveActivitySessionId`; the
                // double serves every doc so the in-memory filter stays under test.
                const query = {
                  where: () => query,
                  get: async () => ({
                    docs: docs.map((doc) => ({ id: doc.id, data: () => doc.data })),
                  }),
                };
                return query;
              },
            }),
          };
        },
        doc: (path: string) => ({
          set: async (data: Record<string, unknown>) => {
            updates.push({ path, data });
          },
        }),
      },
    };
  }

  it("pushes liveactivity APNs only to the bound device and clears a 410 token", async () => {
    const { firestore, updates } = fakeFirestore([
      {
        id: "phone",
        data: { platform: "ios", liveActivityPushToken: TOKEN, liveActivitySessionId: "sess-1" },
      },
      {
        id: "stale",
        data: { platform: "ios", liveActivityPushToken: TOKEN, liveActivitySessionId: "other" },
      },
    ]);
    const push = vi.fn(async (_args: LiveActivityPushArgs) => ({
      status: "rejected" as const,
      apnsStatusCode: 410,
      reason: "Unregistered",
    }));

    const tally = await fanoutLiveActivityUpdate({
      uid: "user-1",
      change: {
        event: "update",
        sessionId: "sess-1",
        state: {
          appName: "Agent Live",
          lastAction: "Watching Mac",
          actionsCount: 0,
          approvalPending: false,
          elapsed: 1,
          remoteRefreshEnabled: true,
        },
      },
      // @ts-expect-error reason: test double for Firestore
      firestore,
      push,
      nowMs: NOW,
    });

    expect(tally).toEqual({ sent: 0, skipped: 0, failed: 0, rejected: 1 });
    expect(push).toHaveBeenCalledTimes(1);
    expect(push).toHaveBeenCalledWith({
      deviceTokenHex: TOKEN,
      documentId: "user-1:phone:sess-1",
      pushType: "liveactivity",
      payload: expect.objectContaining({
        aps: expect.objectContaining({ event: "update" }),
      }),
    });
    const contentState = contentStateOf(push.mock.calls[0]?.[0].payload);
    expect(contentState).not.toHaveProperty("pendingApprovalId");
    expect(updates).toEqual([
      {
        path: "users/user-1/devices/phone",
        data: {
          liveActivityPushToken: null,
          liveActivitySessionId: null,
          updated_at_millis: expect.any(Number),
        },
      },
    ]);
  });

  it("counts a successful liveactivity send", async () => {
    const { firestore } = fakeFirestore([
      {
        id: "phone",
        data: { platform: "ios", liveActivityPushToken: TOKEN, liveActivitySessionId: "sess-1" },
      },
    ]);
    const push = vi.fn(async (_args: LiveActivityPushArgs) => ({ status: "sent" as const, apnsStatusCode: 200 }));
    const tally = await fanoutLiveActivityUpdate({
      uid: "user-1",
      change: {
        event: "end",
        sessionId: "sess-1",
        state: {
          appName: "Agent Live",
          lastAction: "Halted",
          actionsCount: 1,
          approvalPending: false,
          elapsed: 2,
          remoteRefreshEnabled: true,
        },
      },
      // @ts-expect-error reason: test double for Firestore
      firestore,
      push,
    });
    expect(tally).toEqual({ sent: 1, skipped: 0, failed: 0, rejected: 0 });
    expect(push.mock.calls[0]?.[0].pushType).toBe("liveactivity");
  });

  it("skips when no device holds the session token", async () => {
    const { firestore } = fakeFirestore([]);
    const push = vi.fn();
    const tally = await fanoutLiveActivityUpdate({
      uid: "user-1",
      change: {
        event: "end",
        sessionId: "sess-1",
        state: {
          appName: "Agent Live",
          lastAction: "Halted",
          actionsCount: 1,
          approvalPending: false,
          elapsed: 2,
          remoteRefreshEnabled: true,
        },
      },
      // @ts-expect-error reason: test double for Firestore
      firestore,
      push,
    });
    expect(tally.skipped).toBe(1);
    expect(push).not.toHaveBeenCalled();
  });
});
