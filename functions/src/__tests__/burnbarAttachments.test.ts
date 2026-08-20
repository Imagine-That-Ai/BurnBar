import { beforeEach, describe, expect, it, vi } from "vitest";

process.env.ENFORCE_APP_CHECK = "false";

const hoisted = vi.hoisted(() => {
  const store = new Map<string, Record<string, unknown>>();
  function apply(existing: Record<string, unknown> | undefined, data: Record<string, unknown>, merge?: boolean) {
    return merge ? { ...(existing ?? {}), ...data } : { ...data };
  }
  function makeDb() {
    const db = {
      doc(path: string) {
        return {
          path,
          get: async () => {
            const data = store.get(path);
            return { exists: data !== undefined, data: () => data, get: (f: string) => data?.[f] };
          },
          set: async (data: Record<string, unknown>, options?: { merge?: boolean }) => {
            store.set(path, apply(store.get(path), data, options?.merge === true));
          },
        };
      },
      collection() {
        return { doc: (id: string) => db.doc(id) };
      },
      runTransaction: async (fn: (tx: { get: Function; set: Function }) => Promise<unknown>) => {
        const tx = {
          get: (ref: { get: () => Promise<unknown> }) => ref.get(),
          set: (ref: { set: Function }, data: Record<string, unknown>, options?: { merge?: boolean }) =>
            ref.set(data, options),
        };
        return fn(tx);
      },
    };
    return db;
  }
  return { store, db: makeDb() };
});

vi.mock("../adminRuntime.js", () => ({ db: hoisted.db }));
vi.mock("../config.js", () => ({ getConfig: () => ({ enforceAppCheck: false }) }));
vi.mock("../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: false })),
}));
vi.mock("../callables/computerUseSecurityFirestore.js", () => ({
  requireTrustedDeviceActionProof: vi.fn(async () => ({ deviceId: "dev", platform: "iOS", signalIdentityKeyId: "s" })),
}));

import { callableRunner } from "./bola/callableBolaHarness.js";
import {
  beginBurnbarAttachment,
  composeBurnbarAttachment,
  composeParts,
  FILE_CAP_BYTES,
  finalizeBurnbarAttachment,
  memoryStoragePort,
  planComposeHierarchy,
  COMPOSE_FANIN,
  takeComposeLog,
} from "../callables/burnbarAttachments.js";

const runBegin = callableRunner(beginBurnbarAttachment);
const runCompose = callableRunner(composeBurnbarAttachment);
const runFinalize = callableRunner(finalizeBurnbarAttachment);

function authed(data: Record<string, unknown>) {
  return {
    auth: { uid: "alice-bola-uid", token: {} },
    app: { appId: "test" },
    rawRequest: { headers: {} },
    data: { nonce: "n", deviceId: "iphone-1", actionProof: {}, ...data },
  };
}

describe("burnbarAttachments", () => {
  beforeEach(() => {
    hoisted.store.clear();
    takeComposeLog();
  });

  it("caps files at 10GiB", () => {
    expect(FILE_CAP_BYTES).toBe(10 * 1024 * 1024 * 1024);
  });

  it("compose hierarchy never exceeds 32 sources (33 parts)", () => {
    const groups = planComposeHierarchy(33);
    expect(groups.every((g) => g.length <= COMPOSE_FANIN)).toBe(true);
    expect(groups.some((g) => g.length === 32)).toBe(true);
  });

  it("composeParts records ≤32 sources including 33-part fan-in", async () => {
    const uid = "alice-bola-uid";
    const id = "att-33";
    for (let i = 0; i < 33; i += 1) {
      await memoryStoragePort.mintPutUrl(`users/${uid}/burnbar_attachments/${id}/parts/${i}`, 10, 60);
    }
    await composeParts(uid, id, 33, memoryStoragePort);
    const log = takeComposeLog();
    expect(log.length).toBeGreaterThan(0);
    expect(log.every((call) => call.sources.length <= 32)).toBe(true);
    expect(log.every((call) => call.ifGenerationMatch === 0)).toBe(true);
    expect(log.some((call) => call.sources.length === 32)).toBe(true);
  });

  it("finalize meters metadata.size not the client lie", async () => {
    const begun = (await runBegin(
      authed({ byteCount: 100, contentBlake3: "a".repeat(64), transport: "cloud" }),
    )) as { id: string };
    const path = `users/alice-bola-uid/burnbar_attachments/${begun.id}/final`;
    await memoryStoragePort.mintPutUrl(path, 500, 60);
    const result = await runFinalize(authed({ id: begun.id }));
    expect(result).toMatchObject({ ok: true, size: 500 });
    const quota = [...hoisted.store.entries()].find(([k]) => k.includes("burnbar_attach_") && k.endsWith("_in"));
    expect(quota?.[1].meteredBytes).toBe(500);
  });

  it("second finalize of same generation returns 200; swapped bytes fail", async () => {
    const begun = (await runBegin(
      authed({ byteCount: 64, contentBlake3: "b".repeat(64) }),
    )) as { id: string };
    const finalPath = `users/alice-bola-uid/burnbar_attachments/${begun.id}/final`;
    await memoryStoragePort.mintPutUrl(finalPath, 64, 60);
    const first = await runFinalize(authed({ id: begun.id }));
    expect(first).toMatchObject({ ok: true });
    const second = await runFinalize(authed({ id: begun.id }));
    expect(second).toMatchObject({ ok: true, idempotent: true });
    await memoryStoragePort.mintPutUrl(finalPath, 99, 60);
    await expect(runFinalize(authed({ id: begun.id }))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });
});
