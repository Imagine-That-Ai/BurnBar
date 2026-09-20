import { beforeEach, describe, expect, it, vi } from "vitest";

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
      runTransaction: async (fn: Parameters<typeof import("./fakeFirestoreTransaction.js").runFakeFirestoreTransaction>[0]) => {
        const { runFakeFirestoreTransaction: runTx } = await import("./fakeFirestoreTransaction.js");
        return runTx(fn);
      },
      batch: () => {
        const ops: Array<() => void> = [];
        return {
          set: (ref: { path?: string }, data: Record<string, unknown>) => {
            const path = ref.path;
            if (typeof path === "string") {
              ops.push(() => store.set(path, applyWrite(store.get(path), data)));
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
  requireTrustedDeviceActionProof: vi.fn((args: {
    deviceId: string;
    allowedPlatforms: ReadonlySet<string>;
  }) => ({
    deviceId: args.deviceId,
    platform: args.allowedPlatforms.has("macOS") ? "macOS" : "iOS",
    signalIdentityKeyId: "sig-1",
  })),
}));

import { cloudVaultAADContext } from "../callables/shared.js";
import { createCliAgentMissionGroup } from "../callables/cliAgentMissions.js";
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

const runCreateGroup = callableRunner(createCliAgentMissionGroup);

function groupPayload(groupId: string, overrides: Record<string, unknown> = {}) {
  return {
    groupId,
    deviceId: "iphone-1",
    nonce: "nonce-group",
    actionProof: { ok: true },
    contentSealed: true,
    sealedSchemaVersion: 2,
    vaultKeyID: VAULT,
    sealedPayload: sealed(ALICE_UID, "mission_groups", groupId, "sealedPayload"),
    childMissionIDs: ["child-1"],
    runtimeTokens: ["codex"],
    parallelismLimit: 1,
    missionKind: "diligence",
    mergeStrategy: "pick_one",
    phase: "queued",
    schemaVersion: 1,
    source: "ios-hermes-square",
    forecast: {
      tokensLow: 1,
      tokensHigh: 2,
      costLowUSD: 0,
      costHighUSD: 0,
      etaLow: 0,
      etaHigh: 0,
    },
    createdAt: "2026-09-13T00:00:00.000Z",
    updatedAt: "2026-09-13T00:00:00.000Z",
    ...overrides,
  };
}

describe("createCliAgentMissionGroup", () => {
  beforeEach(() => {
    store.clear();
  });

  it("writes a sealed group doc via admin and does not require client rules", async () => {
    await expect(runCreateGroup(authed(groupPayload("grp-1")))).resolves.toMatchObject({
      ok: true,
      groupId: "grp-1",
      idempotent: false,
    });
    const doc = store.get(`users/${ALICE_UID}/mission_groups/grp-1`);
    expect(doc?.contentSealed).toBe(true);
    expect(doc?.sealedSchemaVersion).toBe(2);
    expect(doc?.childMissionIDs).toEqual(["child-1"]);
    expect(doc?.runtimeTokens).toEqual(["codex"]);
    expect(doc?.title).toBeUndefined();
    expect(doc?.prompt).toBeUndefined();
    expect(doc?.phase).toBe("queued");
  });

  it("is idempotent when the same children already exist", async () => {
    await runCreateGroup(authed(groupPayload("grp-dup")));
    await expect(runCreateGroup(authed(groupPayload("grp-dup")))).resolves.toMatchObject({
      ok: true,
      groupId: "grp-dup",
      idempotent: true,
    });
    await expect(
      runCreateGroup(
        authed(
          groupPayload("grp-dup", {
            childMissionIDs: ["other-child"],
            runtimeTokens: ["claude"],
          }),
        ),
      ),
    ).rejects.toMatchObject({ code: "already-exists" });
  });

  it("rejects a sealed payload bound to the wrong collection", async () => {
    await expect(
      runCreateGroup(
        authed(
          groupPayload("grp-aad", {
            sealedPayload: sealed(ALICE_UID, "cli_agent_mission_requests", "grp-aad", "sealedPayload"),
          }),
        ),
      ),
    ).rejects.toMatchObject({ code: "invalid-argument" });
    expect(store.get(`users/${ALICE_UID}/mission_groups/grp-aad`)).toBeUndefined();
  });

  it("rejects a free-tier group wider than the Wand cap", async () => {
    await expect(
      runCreateGroup(
        authed(
          groupPayload("grp-wide", {
            childMissionIDs: ["child-1", "child-2"],
            runtimeTokens: ["codex", "claude"],
            parallelismLimit: 2,
          }),
        ),
      ),
    ).rejects.toMatchObject({ code: "invalid-argument" });
    expect(store.get(`users/${ALICE_UID}/mission_groups/grp-wide`)).toBeUndefined();
  });

  it("group create uses phone + mac platforms", async () => {
    store.clear();
    const mocked = vi.mocked(requireTrustedDeviceActionProof);
    mocked.mockClear();
    await runCreateGroup(authed(groupPayload("plat-group")));
    const groupCall = mocked.mock.calls[0]?.[0];
    expect(groupCall?.actionKind).toBe("cli_agent_mission_group_create");
    expect(groupCall?.subjectId).toBe("plat-group");
    expect([...(groupCall?.allowedPlatforms ?? [])]).toEqual(expect.arrayContaining(["iOS", "Android", "macOS"]));
  });
});
