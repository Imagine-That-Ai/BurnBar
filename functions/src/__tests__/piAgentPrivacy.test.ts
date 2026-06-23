import { beforeEach, describe, expect, it, vi } from "vitest";

import { callableRequest, callableRunner, pathKeyedFirestore, seedDoc } from "./bola/callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const piAgentStore = vi.hoisted(() => new Map<string, Record<string, unknown>>());

vi.mock("../adminRuntime.js", () => ({ db: pathKeyedFirestore(piAgentStore) }));
vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(piAgentStore),
  };
});
vi.mock("../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
  assertAppCheck: vi.fn(),
}));
vi.mock("../callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));
vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return {
    ...actual,
    assertActiveHostedQuotaEntitlement: vi.fn(async () => undefined),
    checkPiAgentRateLimit: vi.fn(async () => undefined),
    writePiAgentAuditEvent: vi.fn(async () => undefined),
  };
});

const uid = "pi-agent-privacy-user";
const pairingId = "pair_privacy";
const connectionId = "relay-privacy";
const pairingCode = "ABCD-EFGH";

describe("Pi Agent pairing privacy boundary", () => {
  beforeEach(() => {
    piAgentStore.clear();
    vi.clearAllMocks();
  });

  it("rejects client-supplied Redis URLs before pairing state is written", async () => {
    const mod = await import("../callables/piAgent.js");
    const run = callableRunner(mod.completePiAgentPairing);

    await expect(
      run(
        callableRequest(uid, {
          pairingId,
          code: pairingCode,
          connectionId,
          displayName: "Relay host",
          mode: "directURL",
          endpointURL: "https://pi.example.test",
          redisURL: "rediss://redis.internal.example:6379/0",
        }),
      ),
    ).rejects.toMatchObject({ code: "invalid-argument" });

    expect(piAgentStore.has(`users/${uid}/pi_agent_connections/${connectionId}`)).toBe(false);
  });

  it("removes legacy Redis URLs when completing a normal pairing", async () => {
    const mod = await import("../callables/piAgent.js");
    const { piAgentPairingCodeDigest } = await import("../piAgent.js");
    const run = callableRunner(mod.completePiAgentPairing);
    const now = new Date().toISOString();

    seedDoc(piAgentStore, `users/${uid}/pi_agent_pairings/${pairingId}`, {
      id: pairingId,
      codeHash: piAgentPairingCodeDigest(pairingCode),
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
      status: "pending",
      createdAt: now,
      updatedAt: now,
      schemaVersion: 2,
    });
    seedDoc(piAgentStore, `users/${uid}/pi_agent_connections/${connectionId}`, {
      id: connectionId,
      displayName: "Old Relay",
      mode: "relayLink",
      status: "offline",
      capabilities: ["remote_relay"],
      createdAt: now,
      updatedAt: now,
      schemaVersion: 2,
      redisURL: "rediss://redis.internal.example:6379/0",
    });

    const result = await run(
      callableRequest(uid, {
        pairingId,
        code: pairingCode,
        connectionId,
        displayName: "Relay host",
        mode: "directURL",
        endpointURL: "https://pi.example.test",
        capabilities: ["remote_relay"],
      }),
    );

    expect(result).not.toHaveProperty("redisURL");
    const stored = piAgentStore.get(`users/${uid}/pi_agent_connections/${connectionId}`);
    expect(stored).toMatchObject({
      id: connectionId,
      displayName: "Relay host",
      mode: "directURL",
      endpointURL: "https://pi.example.test",
      status: "online",
      capabilities: ["remote_relay"],
    });
    expect(stored).not.toHaveProperty("redisURL");
  });
});
