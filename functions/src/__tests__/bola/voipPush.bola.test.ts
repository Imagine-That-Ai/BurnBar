/**
 * BOLA negative coverage — triggerVoIPCall must not fan out to another user's device.
 */
import { describe, expect, it, vi } from "vitest";

import {
  ALICE_UID,
  BOB_UID,
  callableRequest,
  callableRunner,
  seedDoc,
} from "./callableBolaHarness.js";

const store: Map<string, Record<string, unknown>> = vi.hoisted(() => new Map());
const outboundWrites: Array<{ collection: string; payload: Record<string, unknown> }> = vi.hoisted(() => []);

process.env.ENFORCE_APP_CHECK = "false";

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
  });
});
