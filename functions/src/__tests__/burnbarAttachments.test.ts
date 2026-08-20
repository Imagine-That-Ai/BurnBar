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
vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return { ...actual, assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined) };
});

import { callableRunner } from "./bola/callableBolaHarness.js";
import {
  beginBurnbarAttachment,
  composeBurnbarAttachment,
  composeParts,
  FILE_CAP_BYTES,
  finalizeBurnbarAttachment,
  combineWithGenerationPin,
  memoryStoragePort,
  mintBurnbarAttachmentPartURL,
  putMemoryObject,
  planComposeHierarchy,
  COMPOSE_FANIN,
  setBurnbarStoragePort,
  takeComposeLog,
  ticketBurnbarAttachmentDownload,
} from "../callables/burnbarAttachments.js";
import { reapExpiredBurnbarAttachments, setReaperStoragePort } from "../scheduled/reapBurnbarAttachments.js";

const runBegin = callableRunner(beginBurnbarAttachment);
const runCompose = callableRunner(composeBurnbarAttachment);
const runFinalize = callableRunner(finalizeBurnbarAttachment);
const runMint = callableRunner(mintBurnbarAttachmentPartURL);
const runTicket = callableRunner(ticketBurnbarAttachmentDownload);

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
    setBurnbarStoragePort(memoryStoragePort);
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
      const path = `users/${uid}/burnbar_attachments/${id}/parts/${i}`;
      await memoryStoragePort.mintPutUrl(path, 10, 60);
      await putMemoryObject(path, 10);
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
    await putMemoryObject(path, 500);
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
    await putMemoryObject(finalPath, 64);
    const first = await runFinalize(authed({ id: begun.id }));
    expect(first).toMatchObject({ ok: true });
    const second = await runFinalize(authed({ id: begun.id }));
    expect(second).toMatchObject({ ok: true, idempotent: true });
    await memoryStoragePort.mintPutUrl(finalPath, 99, 60);
    await putMemoryObject(finalPath, 99);
    await expect(runFinalize(authed({ id: begun.id }))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  it("gcs compose adapter passes ifGenerationMatch into Bucket.combine", async () => {
    const combine = vi.fn(async () => [
      {
        getMetadata: async () => [{ size: 10, generation: "7" }],
      },
    ]);
    const result = await combineWithGenerationPin({ combine }, ["a", "b"], "dest", 0);
    expect(combine).toHaveBeenCalledWith(["a", "b"], "dest", { ifGenerationMatch: 0 });
    expect(result).toEqual({ size: 10, generation: "7" });
  });

  it("mint/PUT of a part after finalize is denied", async () => {
    const begun = (await runBegin(
      authed({ byteCount: 64, contentBlake3: "d".repeat(64) }),
    )) as { id: string };
    const finalPath = `users/alice-bola-uid/burnbar_attachments/${begun.id}/final`;
    const partPath = `users/alice-bola-uid/burnbar_attachments/${begun.id}/parts/0`;
    await memoryStoragePort.mintPutUrl(partPath, 64, 60);
    await putMemoryObject(partPath, 64);
    await memoryStoragePort.mintPutUrl(finalPath, 64, 60);
    await putMemoryObject(finalPath, 64);
    await runFinalize(authed({ id: begun.id }));
    await expect(runMint(authed({ id: begun.id, partIndex: 0, contentLength: 64 }))).rejects.toMatchObject({
      code: "failed-precondition",
    });
    await expect(memoryStoragePort.mintPutUrl(partPath, 64, 60)).rejects.toMatchObject({
      code: "permission-denied",
    });
  });

  it("ticket download meters outbound quota", async () => {
    const begun = (await runBegin(
      authed({ byteCount: 64, contentBlake3: "e".repeat(64) }),
    )) as { id: string };
    const finalPath = `users/alice-bola-uid/burnbar_attachments/${begun.id}/final`;
    await memoryStoragePort.mintPutUrl(finalPath, 64, 60);
    await putMemoryObject(finalPath, 64);
    await runFinalize(authed({ id: begun.id }));
    const ticket = await runTicket(authed({ id: begun.id }));
    expect(ticket).toMatchObject({ ok: true });
    const quota = [...hoisted.store.entries()].find(([k]) => k.includes("burnbar_attach_") && k.endsWith("_out"));
    expect(quota?.[1].meteredBytes).toBe(64);
  });

  it("reaper deletes stale pending attachments and expired gateway docs", async () => {
    setReaperStoragePort(memoryStoragePort);
    const stalePath = "users/alice-bola-uid/burnbar_attachments/old/final";
    await memoryStoragePort.mintPutUrl(stalePath, 8, 60);
    await putMemoryObject(stalePath, 8);
    hoisted.store.set("users/alice-bola-uid/burnbar_attachments/old", {
      state: "pending_upload",
      storagePath: stalePath,
      updatedAt: { toMillis: () => Date.now() - 48 * 60 * 60 * 1000 },
    });
    hoisted.store.set("users/alice-bola-uid/hermes_gateway_attachments/gw1", {
      expiresAt: { toMillis: () => Date.now() - 1000 },
      storagePath: "users/alice-bola-uid/hermes_gateway_attachments/gw1/obj",
    });
    const original = hoisted.db.collectionGroup;
    hoisted.db.collectionGroup = (name: string) => ({
      get: async () => {
        const docs = [...hoisted.store.entries()]
          .filter(([path]) => path.includes(`/${name}/`) && !path.split(`/${name}/`)[1]?.includes("/"))
          .map(([path, data]) => ({
            get: (f: string) => data[f],
            ref: {
              set: async (next: Record<string, unknown>, options?: { merge?: boolean }) => {
                hoisted.store.set(path, options?.merge ? { ...data, ...next } : next);
              },
              delete: async () => {
                hoisted.store.delete(path);
              },
            },
          }));
        return { docs };
      },
    });
    const result = await reapExpiredBurnbarAttachments(Date.now());
    expect(result.reaped).toBe(1);
    expect(result.gatewayReaped).toBe(1);
    expect(hoisted.store.get("users/alice-bola-uid/burnbar_attachments/old")?.state).toBe("expired");
    hoisted.db.collectionGroup = original;
  });

  it("mint does not materialize bytes; compose-before-PUT fails", async () => {
    const uid = "alice-bola-uid";
    const id = "att-mint-only";
    const partPath = `users/${uid}/burnbar_attachments/${id}/parts/0`;
    await memoryStoragePort.mintPutUrl(partPath, 10, 60);
    await expect(memoryStoragePort.compose([partPath], `users/${uid}/burnbar_attachments/${id}/final`, 0)).rejects.toMatchObject({
      code: "not-found",
    });
    await putMemoryObject(partPath, 10);
    await expect(memoryStoragePort.compose([partPath], `users/${uid}/burnbar_attachments/${id}/final`, 0)).resolves.toMatchObject({
      size: 10,
    });
  });

  it("refuses compose after finalize", async () => {
    const begun = (await runBegin(
      authed({ byteCount: 64, contentBlake3: "c".repeat(64) }),
    )) as { id: string };
    const finalPath = `users/alice-bola-uid/burnbar_attachments/${begun.id}/final`;
    await memoryStoragePort.mintPutUrl(finalPath, 64, 60);
    await putMemoryObject(finalPath, 64);
    await runFinalize(authed({ id: begun.id }));
    await expect(runCompose(authed({ id: begun.id }))).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });
});
