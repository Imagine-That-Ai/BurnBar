/**
 * F-RR10-027 — submitAgentNotificationReply must write sealedSchemaVersion 2
 * and reject v1 sealed payloads, matching the Firestore rules.
 */
import { describe, expect, it, vi, beforeEach } from "vitest";

process.env.ENFORCE_APP_CHECK = "false";

const state = vi.hoisted(() => ({
  Timestamp: null as unknown as typeof import("firebase-admin/firestore").Timestamp,
  storedReplies: [] as Array<{ id: string; data: Record<string, unknown> }>,
}));

const fakeEventData = () => ({
  id: "evt-1",
  uid: "u1",
  sourceKind: "cli_session",
  sourcePath: "users/u1/cli_sessions/thread-1",
  threadId: "thread-1",
  messageId: "msg-1",
  runtime: "codex",
  providerLabel: "Codex",
  title: "Codex replied",
  preview: "OpenBurnBar has a new agent reply.",
  createdAt: state.Timestamp.fromMillis(1_700_000_000_000),
  createdAtMillis: 1_700_000_000_000,
  updatedAt: state.Timestamp.fromMillis(1_700_000_000_000),
  updatedAtMillis: 1_700_000_000_000,
  status: "pending",
  fanoutAttemptCount: 0,
  replyEnabled: true,
  schemaVersion: 1,
});

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  state.Timestamp = actual.Timestamp;
  return {
    ...actual,
    getFirestore: () => ({
      collection: (name: string) => {
        if (name === "users") {
          return {
            doc: (_uid: string) => ({
              collection: (sub: string) => ({
                doc: (docId: string) => {
                  if (sub === "agent_notification_events" && docId === "evt-1") {
                    return {
                      get: async () => ({ exists: true, data: () => fakeEventData() }),
                    };
                  }
                  if (sub === "agent_notification_replies") {
                    return {
                      set: async (data: Record<string, unknown>) => {
                        state.storedReplies.push({ id: docId, data });
                      },
                    };
                  }
                  return { get: async () => ({ exists: false }) };
                },
              }),
            }),
          };
        }
        return { doc: () => ({}) };
      },
    }),
  };
});

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

vi.mock("../logging.js", () => ({
  logInfo: vi.fn(),
  logError: vi.fn(),
  wrapCallableHandler: (_name: string, handler: unknown) => handler,
}));

import { submitAgentNotificationReply } from "../callables/agentNotifications.js";

type Runnable = { run: (request: unknown) => Promise<unknown> };

function authedRequest(data: Record<string, unknown>) {
  return {
    auth: { uid: "u1", token: {} },
    app: { appId: "test-app" },
    rawRequest: { headers: {} },
    data,
  };
}

const validSealedPayloadV2 = {
  schemaVersion: 2,
  algorithm: "AES-256-GCM",
  keyVersion: 1,
  vaultKeyID: "vk-1",
  sealedBoxBase64: "c2VhbGVkLWJveA==",
  aad: "aad-1",
};

const sealedPayloadV1 = {
  schemaVersion: 1,
  algorithm: "AES-256-GCM",
  keyVersion: 1,
  vaultKeyID: "vk-1",
  sealedBoxBase64: "c2VhbGVkLWJveA==",
};

describe("submitAgentNotificationReply — F-RR10-027 schema version", () => {
  beforeEach(() => {
    state.storedReplies.length = 0;
  });

  it("writes sealedSchemaVersion 2 for a v2 sealed payload", async () => {
    await (submitAgentNotificationReply as unknown as Runnable).run(
      authedRequest({
        eventId: "evt-1",
        vaultKeyID: "vk-1",
        sealedReplyPayload: validSealedPayloadV2,
        deviceId: "mac-1",
      }),
    );

    expect(state.storedReplies).toHaveLength(1);
    const written = state.storedReplies[0].data;
    expect(written.sealedSchemaVersion).toBe(2);
    expect(written.schemaVersion).toBe(1);
    expect(written.contentSealed).toBe(true);
    expect(written.status).toBe("queued");
  });

  it("rejects a v1 sealed payload", async () => {
    await expect(
      (submitAgentNotificationReply as unknown as Runnable).run(
        authedRequest({
          eventId: "evt-1",
          vaultKeyID: "vk-1",
          sealedReplyPayload: sealedPayloadV1,
        }),
      ),
    ).rejects.toThrow(/sealed schema version 2/);

    expect(state.storedReplies).toHaveLength(0);
  });

  it("rejects a sealed payload without schemaVersion", async () => {
    await expect(
      (submitAgentNotificationReply as unknown as Runnable).run(
        authedRequest({
          eventId: "evt-1",
          vaultKeyID: "vk-1",
          sealedReplyPayload: {
            algorithm: "AES-256-GCM",
            keyVersion: 1,
            vaultKeyID: "vk-1",
            sealedBoxBase64: "c2VhbGVkLWJveA==",
          },
        }),
      ),
    ).rejects.toThrow(/sealed schema version 2/);
  });
});
