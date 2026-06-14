/**
 * F-RR10-027 — submitAgentNotificationReply must write sealedSchemaVersion 2
 * and reject v1 sealed payloads, matching the Firestore rules.
 */
import { describe, expect, it, vi, beforeEach } from "vitest";
import type { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";

process.env.ENFORCE_APP_CHECK = "false";

type TimestampFactory = { fromMillis(ms: number): Timestamp };
type StoredReply = { id: string; data: Record<string, unknown> };
type TestState = {
  Timestamp: TimestampFactory | null;
  storedReplies: StoredReply[];
};

const state = vi.hoisted<TestState>(() => ({
  Timestamp: null,
  storedReplies: [],
}));

function testTimestamp(): TimestampFactory {
  if (state.Timestamp === null) throw new Error("Timestamp mock not initialized.");
  return state.Timestamp;
}

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
  createdAt: testTimestamp().fromMillis(1_700_000_000_000),
  createdAtMillis: 1_700_000_000_000,
  updatedAt: testTimestamp().fromMillis(1_700_000_000_000),
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

type SubmitReplyRequest = Parameters<typeof submitAgentNotificationReply.run>[0];

function decodedIdToken(uid: string) {
  return Object.assign(Object.create(null), {
    aud: "burnbar-test",
    auth_time: 1,
    exp: 2,
    firebase: { identities: {}, sign_in_provider: "custom" },
    iat: 1,
    iss: "https://securetoken.google.com/burnbar-test",
    sub: uid,
    uid,
  });
}

function callableRequest(data: Record<string, unknown>): CallableRequest<Record<string, unknown>> {
  const request: CallableRequest<Record<string, unknown>> = Object.create(null);
  request.auth = { uid: "u1", token: decodedIdToken("u1"), rawToken: "test-id-token" };
  request.app = { appId: "test-app", token: Object.create(null) };
  request.rawRequest = Object.assign(Object.create(null), { headers: {} });
  request.acceptsStreaming = false;
  request.data = data;
  return request;
}

function authedRequest(data: Record<string, unknown>): SubmitReplyRequest {
  return callableRequest(data);
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
    await submitAgentNotificationReply.run(
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
      submitAgentNotificationReply.run(
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
      submitAgentNotificationReply.run(
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
