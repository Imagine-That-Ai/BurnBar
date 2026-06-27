/**
 * BOLA negative coverage — triggerVoIPCall must not fan out to another user's device.
 */
import { describe, expect, it, vi } from "vitest";

import { ALICE_UID, BOB_UID, callableRequest, callableRunner, seedDoc } from "./callableBolaHarness.js";

const store: Map<string, Record<string, unknown>> = vi.hoisted(() => new Map());
const outboundWrites: Array<{ collection: string; payload: Record<string, unknown> }> = vi.hoisted(() => []);
const userDocWrites: Array<{ path: string; payload: Record<string, unknown> }> = vi.hoisted(() => []);

process.env.ENFORCE_APP_CHECK = "false";

function expectRecord(value: unknown): asserts value is Record<string, unknown> {
  expect(typeof value).toBe("object");
  expect(value).not.toBeNull();
  expect(Array.isArray(value)).toBe(false);
}

vi.mock("../../auth.js", () => ({
  assertAppCheck: vi.fn(),
}));
vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    doc: (path: string) => ({
      get: async () => {
        const data = store.get(path);
        return {
          exists: data !== undefined,
          data: () => data,
        };
      },
    }),
    collection: (name: string) => ({
      doc: (docId: string) => ({
        collection: (subcollection: string) => ({
          doc: (subdocId: string) => ({
            set: async (payload: Record<string, unknown>) => {
              userDocWrites.push({
                path: `${name}/${docId}/${subcollection}/${subdocId}`,
                payload,
              });
            },
          }),
        }),
      }),
      add: async (payload: Record<string, unknown>) => {
        outboundWrites.push({ collection: name, payload });
        return { id: `out-${outboundWrites.length}` };
      },
    }),
  }),
  Timestamp: {
    now: () => ({ toMillis: () => Date.now() }),
    fromMillis: (ms: number) => ({ toMillis: () => ms }),
  },
}));
vi.mock("../../voipPush.js", async () => {
  const actual = await vi.importActual<typeof import("../../voipPush.js")>("../../voipPush.js");
  return {
    ...actual,
    macHasActiveMediaEntitlement: vi.fn(async () => true),
  };
});

export const BOLA_MANIFEST = {
  triggerVoIPCall: ["triggerVoIPCall rejects cross-user object access"],
} as const;

describe("BOLA — voipPush", () => {
  it("triggerVoIPCall rejects cross-user object access", async () => {
    store.clear();
    outboundWrites.length = 0;
    userDocWrites.length = 0;
    seedDoc(store, `users/${BOB_UID}/devices/bob-paired`, {
      voipDeviceToken: "bob-voip-token",
      platform: "ios",
    });

    const mod = await import("../../callables/voipPush.js");
    const run = callableRunner(mod.triggerVoIPCall);

    await expect(
      run(
        callableRequest(ALICE_UID, {
          callId: "call-00000001",
          connectionId: "conn-00000001",
          pairedDeviceId: "bob-paired",
          displayName: "Alice",
          isVideo: false,
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });

    expect(outboundWrites).toEqual([]);
    expect(userDocWrites).toEqual([]);
  });

  it("triggerVoIPCall writes Android routing context without exposing connection id to FCM", async () => {
    store.clear();
    outboundWrites.length = 0;
    userDocWrites.length = 0;
    seedDoc(store, `users/${ALICE_UID}/devices/alice-phone`, {
      fcm_token: "alice-fcm-token",
      platform: "android",
    });

    const mod = await import("../../callables/voipPush.js");
    const run = callableRunner(mod.triggerVoIPCall);

    await expect(
      run(
        callableRequest(ALICE_UID, {
          callId: "call-00000001",
          connectionId: "conn-00000001",
          pairedDeviceId: "alice-phone",
          displayName: "Alice Mac",
          isVideo: true,
        }),
      ),
    ).resolves.toMatchObject({ ok: true, channels: { fcm: true } });

    expect(outboundWrites).toHaveLength(1);
    expect(outboundWrites[0]?.collection).toBe("fcm_outbound");
    const payload = outboundWrites[0]?.payload.payload;
    expectRecord(payload);
    expect(payload).toMatchObject({
      type: "media_incoming_call",
      call_id: "call-00000001",
      caller_name: "Incoming call",
      caller_initial: "I",
      feature: "videoCall",
    });
    expect(payload.connection_id).toBeUndefined();
    expect(payload.connectionId).toBeUndefined();
    expect(payload.correlation_id).toEqual(expect.any(String));

    expect(userDocWrites).toHaveLength(1);
    const contextWrite = userDocWrites[0];
    expect(contextWrite?.path).toBe(`users/${ALICE_UID}/incoming_call_contexts/${payload.correlation_id}`);
    expect(contextWrite?.payload).toMatchObject({
      id: payload.correlation_id,
      callId: "call-00000001",
      connectionId: "conn-00000001",
      schemaVersion: 1,
    });
    expect(contextWrite?.payload.expireAt).toBeDefined();
  });
});
