import { createHash } from "node:crypto";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { runFakeFirestoreTransaction } from "./fakeFirestoreTransaction.js";
import { ALICE_UID, callableRunner } from "./bola/callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const hoisted = vi.hoisted(() => {
  const store = new Map<string, Record<string, unknown>>();
  function applyWrite(
    existing: Record<string, unknown> | undefined,
    data: Record<string, unknown>,
    merge?: boolean,
  ) {
    return merge ? { ...(existing ?? {}), ...data } : { ...data };
  }
  function makeDb() {
    const db = {
      doc(path: string) {
        return {
          path,
          get: async () => {
            const data = store.get(path);
            return {
              exists: data !== undefined,
              id: path.split("/").pop(),
              data: () => data,
              get: (field: string) => data?.[field],
            };
          },
          set: async (data: Record<string, unknown>, options?: { merge?: boolean }) => {
            store.set(path, applyWrite(store.get(path), data, options?.merge === true));
          },
          collection: (sub: string) => db.collection(`${path}/${sub}`),
        };
      },
      collection(path: string) {
        return {
          doc: (id: string) => db.doc(`${path}/${id}`),
          where(field: string, op: string, value: unknown) {
            return {
              limit: () => ({
                get: async () => {
                  const prefix = `${path}/`;
                  const docs = [...store.entries()]
                    .filter(([p, data]) => {
                      if (!p.startsWith(prefix)) return false;
                      const rest = p.slice(prefix.length);
                      if (rest.includes("/")) return false;
                      return op === "==" ? data[field] === value : false;
                    })
                    .map(([p, data]) => ({
                      id: p.slice(prefix.length),
                      exists: true,
                      data: () => data,
                      get: (f: string) => data[f],
                    }));
                  return { docs, empty: docs.length === 0 };
                },
              }),
            };
          },
        };
      },
      runTransaction: async (fn: (tx: unknown) => Promise<unknown>) =>
        (await import("./fakeFirestoreTransaction.js")).runFakeFirestoreTransaction(
          fn as Parameters<typeof runFakeFirestoreTransaction>[0],
        ),
      batch: () => {
        const ops: Array<() => void> = [];
        return {
          set: (ref: { path?: string }, data: Record<string, unknown>) => {
            if (ref.path) {
              ops.push(() => store.set(ref.path as string, applyWrite(store.get(ref.path as string), data)));
            }
          },
          commit: async () => {
            for (const op of ops) op();
          },
        };
      },
    };
    return db;
  }
  return { store, db: makeDb() };
});
const store = hoisted.store;

vi.mock("../adminRuntime.js", () => ({ db: hoisted.db }));

vi.mock("../config.js", () => ({
  getConfig: () => ({ enforceAppCheck: false, requireHighRiskNonce: false }),
}));

vi.mock("../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: false })),
}));

vi.mock("../callables/computerUseSecurityFirestore.js", () => ({
  requireTrustedDeviceActionProof: vi.fn(async (args: { deviceId: string; allowedPlatforms: Set<string> }) => ({
    deviceId: args.deviceId,
    platform: args.allowedPlatforms.has("macOS") ? "macOS" : "iOS",
    signalIdentityKeyId: "sig-1",
  })),
  requireTrustedEscrowDevice: vi.fn(),
  appendComputerUseAuditEvent: vi.fn(),
}));

import { cloudVaultAADContext } from "../callables/shared.js";
import {
  appendCliAgentMissionEvent,
  cancelCliAgentMission,
  claimCliAgentMission,
  createCliAgentMission,
  updateCliAgentMissionStatus,
} from "../callables/cliAgentMissions.js";
import { writeSignalAtRestDocument } from "../callables/writeSignalAtRestDocument.js";
import { requireTrustedDeviceActionProof } from "../callables/computerUseSecurityFirestore.js";

const VAULT = `v1_${"ab".repeat(16)}`;
const SEALED_BOX = Buffer.from("sealed-box").toString("base64");

function sealed(uid: string, collection: string, docId: string, field: string) {
  return {
    schemaVersion: 2,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    vaultKeyID: VAULT,
    sealedBoxBase64: SEALED_BOX,
    aad: cloudVaultAADContext(uid, collection, docId, field),
  };
}

function authed(data: Record<string, unknown>, uid = ALICE_UID) {
  return {
    auth: { uid, token: {} },
    app: { appId: "test-app" },
    rawRequest: { headers: {} },
    data,
  };
}

const runCreate = callableRunner(createCliAgentMission);
const runClaim = callableRunner(claimCliAgentMission);
const runStatus = callableRunner(updateCliAgentMissionStatus);
const runCancel = callableRunner(cancelCliAgentMission);
const runAppend = callableRunner(appendCliAgentMissionEvent);
const runSignal = callableRunner(writeSignalAtRestDocument);

function createPayload(requestId: string, overrides: Record<string, unknown> = {}) {
  return {
    requestId,
    remoteCommandID: `cmd-${requestId}`,
    deviceId: "iphone-1",
    nonce: "nonce-create",
    actionProof: { ok: true },
    publicFields: {
      missionKind: "chat",
      requestedRuntime: "codex",
      source: "ios",
      schemaVersion: 2,
    },
    sealedPayload: sealed(ALICE_UID, "cli_agent_mission_requests", requestId, "sealedPayload"),
    initialEvent: sealed(
      ALICE_UID,
      "cli_agent_mission_requests/events",
      `${requestId}/000001`,
      "sealedPayload",
    ),
    ...overrides,
  };
}

afterEach(() => {
  vi.useRealTimers();
});

describe("createCliAgentMission", () => {
  beforeEach(() => {
    store.clear();
  });

  it("writes a pending mission and queued event, and throttles the 11th create", async () => {
    for (let i = 0; i < 10; i += 1) {
      const id = `m-${i}`;
      await expect(runCreate(authed(createPayload(id)))).resolves.toMatchObject({ ok: true, requestId: id });
      expect(store.get(`users/${ALICE_UID}/cli_agent_mission_requests/${id}`)?.status).toBe("pending");
      expect(store.get(`users/${ALICE_UID}/cli_agent_mission_requests/${id}/events/000001`)).toBeDefined();
    }
    await expect(runCreate(authed(createPayload("m-10")))).rejects.toMatchObject({ code: "resource-exhausted" });
    expect(store.get(`users/${ALICE_UID}/cli_agent_mission_requests/m-10`)).toBeUndefined();
  });

  it("rejects an unknown runtime and does not write", async () => {
    store.clear();
    await expect(
      runCreate(
        authed(
          createPayload("unknown-runtime", {
            publicFields: { missionKind: "chat", requestedRuntime: "not-a-runtime", source: "ios", schemaVersion: 2 },
          }),
        ),
      ),
    ).rejects.toMatchObject({ code: "invalid-argument" });
    expect(store.get(`users/${ALICE_UID}/cli_agent_mission_requests/unknown-runtime`)).toBeUndefined();
  });

  it("is idempotent on remoteCommandID for a live mission", async () => {
    await runCreate(authed(createPayload("first")));
    const second = await runCreate(
      authed(createPayload("second", { remoteCommandID: "cmd-first" })),
    );
    expect(second).toMatchObject({ ok: true, requestId: "first", idempotent: true });
    expect(store.get(`users/${ALICE_UID}/cli_agent_mission_requests/second`)).toBeUndefined();
  });

  it("drops plaintext public fields", async () => {
    const id = "no-plain";
    await runCreate(
      authed(
        createPayload(id, {
          publicFields: {
            missionKind: "chat",
            requestedRuntime: "codex",
            source: "ios",
            schemaVersion: 2,
            title: "leak",
            prompt: "secret",
            liveSummary: "nope",
          },
        }),
      ),
    );
    const doc = store.get(`users/${ALICE_UID}/cli_agent_mission_requests/${id}`);
    expect(doc?.title).toBeUndefined();
    expect(doc?.prompt).toBeUndefined();
    expect(doc?.liveSummary).toBeUndefined();
  });

  it("rejects FieldValue sentinels in publicFields", async () => {
    await expect(
      runCreate(
        authed(
          createPayload("fv", {
            publicFields: {
              missionKind: "chat",
              requestedRuntime: "codex",
              source: "ios",
              schemaVersion: 2,
              depth: { _methodName: "serverTimestamp" },
            },
          }),
        ),
      ),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });
});

describe("claimCliAgentMission", () => {
  beforeEach(async () => {
    store.clear();
    await runCreate(authed(createPayload("race")));
  });

  it("lets exactly one Mac claim; the loser gets failed-precondition", async () => {
    const sealedState = sealed(ALICE_UID, "cli_agent_mission_requests", "race", "sealedStatePayload");
    const winner = await runClaim(
      authed({
        requestId: "race",
        deviceId: "mac-winner",
        nonce: "nonce-claim",
        actionProof: { ok: true },
        nextStatus: "accepted",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        sealedStatePayload: sealedState,
      }),
    );
    expect(winner).toMatchObject({ ok: true, claimedBy: "mac-winner", status: "accepted" });
    expect(typeof (winner as { hostWriteNonce: string }).hostWriteNonce).toBe("string");
    const doc = store.get(`users/${ALICE_UID}/cli_agent_mission_requests/race`);
    expect(doc?.claimedBy).toBe("mac-winner");
    expect(doc?.status).toBe("accepted");

    await expect(
      runClaim(
        authed({
          requestId: "race",
          deviceId: "mac-loser",
          nonce: "nonce-claim-2",
          actionProof: { ok: true },
          nextStatus: "accepted",
          selectedRuntime: "codex",
          selectedRuntimeName: "Codex",
          sealedStatePayload: sealedState,
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(store.get(`users/${ALICE_UID}/cli_agent_mission_requests/race`)?.claimedBy).toBe("mac-winner");
  });
});

describe("updateCliAgentMissionStatus", () => {
  let hostWriteNonce = "";

  beforeEach(async () => {
    store.clear();
    await runCreate(authed(createPayload("owned")));
    const claimed = (await runClaim(
      authed({
        requestId: "owned",
        deviceId: "mac-winner",
        nonce: "nonce-claim",
        actionProof: { ok: true },
        nextStatus: "accepted",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        sealedStatePayload: sealed(ALICE_UID, "cli_agent_mission_requests", "owned", "sealedStatePayload"),
      }),
    )) as { hostWriteNonce: string };
    hostWriteNonce = claimed.hostWriteNonce;
  });

  it("denies a loser fail() without the winner nonce", async () => {
    await expect(
      runStatus(
        authed({
          requestId: "owned",
          deviceId: "mac-loser",
          nonce: "nonce-status",
          actionProof: { ok: true },
          status: "failed",
          hostWriteNonce: "not-the-winner",
          sealedStatePayload: sealed(ALICE_UID, "cli_agent_mission_requests", "owned", "sealedStatePayload"),
        }),
      ),
    ).rejects.toMatchObject({ code: "permission-denied" });
    expect(store.get(`users/${ALICE_UID}/cli_agent_mission_requests/owned`)?.status).toBe("accepted");
  });

  it("allows the winner to move accepted → starting", async () => {
    await expect(
      runStatus(
        authed({
          requestId: "owned",
          deviceId: "mac-winner",
          nonce: "nonce-status",
          actionProof: { ok: true },
          status: "starting",
          hostWriteNonce,
          sealedStatePayload: sealed(ALICE_UID, "cli_agent_mission_requests", "owned", "sealedStatePayload"),
        }),
      ),
    ).resolves.toMatchObject({ status: "starting" });
  });
});

describe("cancelCliAgentMission", () => {
  beforeEach(() => {
    store.clear();
  });

  it("cancels pending and denies cancel-after-completed", async () => {
    await runCreate(authed(createPayload("live")));
    await expect(
      runCancel(
        authed({
          requestId: "live",
          deviceId: "iphone-1",
          nonce: "nonce-cancel",
          actionProof: { ok: true },
          sealedStatePayload: sealed(ALICE_UID, "cli_agent_mission_requests", "live", "sealedStatePayload"),
        }),
      ),
    ).resolves.toMatchObject({ status: "cancelled" });
    expect(store.get(`users/${ALICE_UID}/cli_agent_mission_requests/live`)?.status).toBe("cancelled");

    store.set(`users/${ALICE_UID}/cli_agent_mission_requests/done`, {
      id: "done",
      status: "completed",
      remoteCommandID: "cmd-done",
    });
    await expect(
      runCancel(
        authed({
          requestId: "done",
          deviceId: "iphone-1",
          nonce: "nonce-cancel",
          actionProof: { ok: true },
          sealedStatePayload: sealed(ALICE_UID, "cli_agent_mission_requests", "done", "sealedStatePayload"),
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(store.get(`users/${ALICE_UID}/cli_agent_mission_requests/done`)?.status).toBe("completed");
  });
});

describe("appendCliAgentMissionEvent", () => {
  let hostWriteNonce = "";

  beforeEach(async () => {
    store.clear();
    await runCreate(authed(createPayload("ev")));
    const claimed = (await runClaim(
      authed({
        requestId: "ev",
        deviceId: "mac-winner",
        nonce: "nonce-claim",
        actionProof: { ok: true },
        nextStatus: "accepted",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        sealedStatePayload: sealed(ALICE_UID, "cli_agent_mission_requests", "ev", "sealedStatePayload"),
      }),
    )) as { hostWriteNonce: string };
    hostWriteNonce = claimed.hostWriteNonce;
  });

  it("appends the next sequence and rejects a duplicate eventId or a losing Mac", async () => {
    const payload = {
      requestId: "ev",
      deviceId: "mac-winner",
      nonce: "nonce-append",
      actionProof: { ok: true },
      hostWriteNonce,
      eventId: "000002",
      sealedEvent: sealed(ALICE_UID, "cli_agent_mission_requests/events", "ev/000002", "sealedPayload"),
      publicEventShape: {
        sequence: 2,
        kind: "status",
        phase: "running",
        runtime: "kimi",
        source: "mac",
      },
    };
    await expect(runAppend(authed(payload))).resolves.toMatchObject({ eventId: "000002" });
    await expect(runAppend(authed(payload))).rejects.toMatchObject({ code: "already-exists" });
    await expect(
      runAppend(
        authed({
          ...payload,
          deviceId: "mac-loser",
          eventId: "000003",
          publicEventShape: { ...payload.publicEventShape, sequence: 3 },
          sealedEvent: sealed(ALICE_UID, "cli_agent_mission_requests/events", "ev/000003", "sealedPayload"),
        }),
      ),
    ).rejects.toMatchObject({ code: "permission-denied" });
  });
});

describe("writeSignalAtRestDocument", () => {
  it("refuses cli_agent_mission_requests", async () => {
    await expect(
      runSignal(
        authed({
          collection: "cli_agent_mission_requests",
          docId: "overwrite",
          data: { id: "overwrite", status: "pending" },
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(store.get(`users/${ALICE_UID}/cli_agent_mission_requests/overwrite`)).toBeUndefined();
  });
});

describe("hostWriteNonce hashing", () => {
  it("stores a hash, not the raw nonce", async () => {
    store.clear();
    await runCreate(authed(createPayload("hash-me")));
    const claimed = (await runClaim(
      authed({
        requestId: "hash-me",
        deviceId: "mac-winner",
        nonce: "nonce-claim",
        actionProof: { ok: true },
        nextStatus: "accepted",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        sealedStatePayload: sealed(ALICE_UID, "cli_agent_mission_requests", "hash-me", "sealedStatePayload"),
      }),
    )) as { hostWriteNonce: string };
    const doc = store.get(`users/${ALICE_UID}/cli_agent_mission_requests/hash-me`);
    expect(doc?.hostWriteNonceHash).toBe(
      createHash("sha256").update(claimed.hostWriteNonce, "utf8").digest("hex"),
    );
    expect(doc?.hostWriteNonceHash).not.toBe(claimed.hostWriteNonce);
  });
});

describe("requireTrustedDeviceActionProof platforms", () => {
  it("create uses phone platforms and claim uses macOS", async () => {
    store.clear();
    const mocked = vi.mocked(requireTrustedDeviceActionProof);
    mocked.mockClear();
    await runCreate(authed(createPayload("plat")));
    const createCall = mocked.mock.calls[0]?.[0] as { allowedPlatforms: Set<string>; actionKind: string };
    expect(createCall.actionKind).toBe("cli_agent_mission_create");
    expect([...createCall.allowedPlatforms]).toEqual(expect.arrayContaining(["iOS", "Android", "macOS"]));
    expect(createCall.allowedPlatforms.has("macOS")).toBe(true);

    await runClaim(
      authed({
        requestId: "plat",
        deviceId: "mac-winner",
        nonce: "nonce-claim",
        actionProof: { ok: true },
        nextStatus: "accepted",
        selectedRuntime: "codex",
        selectedRuntimeName: "Codex",
        sealedStatePayload: sealed(ALICE_UID, "cli_agent_mission_requests", "plat", "sealedStatePayload"),
      }),
    );
    const claimCall = mocked.mock.calls.at(-1)?.[0] as { allowedPlatforms: Set<string>; actionKind: string };
    expect(claimCall.actionKind).toBe("cli_agent_mission_claim");
    expect([...claimCall.allowedPlatforms]).toEqual(["macOS"]);
  });
});
