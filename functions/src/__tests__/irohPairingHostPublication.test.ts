import { generateKeyPairSync, randomBytes } from "node:crypto";

import { beforeEach, describe, expect, it, vi } from "vitest";

import { callableRequest, callableRunner, rawEd25519PublicKey } from "./irohControllerRouteTestSupport.js";

const { store } = vi.hoisted(() => ({ store: new Map<string, Record<string, unknown>>() }));
const FIELD_DELETE = { __delete: true } as const;

type Ref = { path: string };

function snapshot(path: string) {
  const data = store.get(path);
  return {
    exists: data !== undefined,
    data: () => data,
    get: (field: string) => data?.[field],
    ref: { path },
  };
}

function mergeWrite(path: string, data: Record<string, unknown>, merge = false): void {
  const next = merge ? { ...(store.get(path) ?? {}) } : {};
  for (const [key, value] of Object.entries(data)) {
    if (value === FIELD_DELETE) {
      delete next[key];
    } else {
      next[key] = value;
    }
  }
  store.set(path, next);
}

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc(path: string) {
      return {
        path,
        get: async () => snapshot(path),
        set: async (data: Record<string, unknown>, options?: { merge?: boolean }) =>
          mergeWrite(path, data, options?.merge),
      };
    },
    runTransaction: async (handler: (transaction: unknown) => Promise<unknown>) =>
      handler({
        get: async (ref: Ref) => snapshot(ref.path),
        set: (ref: Ref, data: Record<string, unknown>, options?: { merge?: boolean }) =>
          mergeWrite(ref.path, data, options?.merge),
      }),
  },
  auth: {},
}));

vi.mock("firebase-admin/firestore", () => ({
  FieldValue: {
    delete: () => FIELD_DELETE,
    serverTimestamp: () => ({ __serverTimestamp: true }),
  },
}));
vi.mock("../config.js", () => ({
  getConfig: () => ({ enforceAppCheck: true, linuxAppCheckAppID: "1:123:linux:route-test" }),
}));
vi.mock("../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  readAppIdFromCallableRequest: (request: { app?: { appId?: string } }) => request.app?.appId,
}));
vi.mock("../callables/shared/entitlements.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared/entitlements.js")>(
    "../callables/shared/entitlements.js",
  );
  return { ...actual, assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined) };
});
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: vi.fn(), logWarn: vi.fn() };
});

import {
  publishIrohPairingPublicKey,
  publishIrohPairingRecord,
} from "../callables/phoneControlCallables.js";
import { parseEscrowPlatform } from "../callables/computerUseSecurityCodecs.js";

const UID = "route-owner";
const CONNECTION_ID = "linux-browser-cu";
const HOST_DEVICE_ID = "linux-host-fixture";

function invokeCallable(callable: unknown, data: Record<string, unknown>): Promise<unknown> {
  return callableRunner(callable)(callableRequest(UID, data));
}

describe("iroh pairing host publication", () => {
  beforeEach(() => store.clear());

  it("admits attested Linux escrow hosts to publish the signed iroh pairing root", async () => {
    const host = generateKeyPairSync("ed25519");
    const hostNodeId = randomBytes(32).toString("hex");
    store.set(`users/${UID}/escrow_devices/${HOST_DEVICE_ID}`, {
      deviceId: HOST_DEVICE_ID,
      platform: parseEscrowPlatform("Linux"),
      trustState: "trusted",
    });
    await expect(
      invokeCallable(publishIrohPairingPublicKey, {
        deviceId: HOST_DEVICE_ID,
        roleId: "host",
        publicKeyBase64: rawEd25519PublicKey(host.publicKey).toString("base64"),
        nonce: "linux-host-key-nonce",
      }),
    ).resolves.toEqual({ ok: true, roleId: "host" });
    await expect(
      invokeCallable(publishIrohPairingRecord, {
        deviceId: HOST_DEVICE_ID,
        connectionId: CONNECTION_ID,
        nodeId: hostNodeId,
        directAddresses: [],
        publishedAtMillis: Date.now(),
        protocolVersion: 1,
        signature: randomBytes(64).toString("base64"),
        nonce: "linux-host-pairing-nonce",
      }),
    ).resolves.toEqual({ ok: true, connectionId: CONNECTION_ID });
    expect(store.get(`users/${UID}/iroh_pairing/${CONNECTION_ID}`)?.publishedByDeviceId).toBe(HOST_DEVICE_ID);
  });

  it("admits an approved Linux App Check host without granting CloudVault escrow trust", async () => {
    const host = generateKeyPairSync("ed25519");
    store.set(`users/${UID}/linux_app_check_devices/${HOST_DEVICE_ID}`, {
      appId: "1:123:linux:route-test",
      deviceId: HOST_DEVICE_ID,
      platform: "Linux",
      trustState: "approved",
    });
    expect(store.has(`users/${UID}/escrow_devices/${HOST_DEVICE_ID}`)).toBe(false);
    await expect(
      callableRunner(publishIrohPairingPublicKey)(
        callableRequest(
          UID,
          {
            deviceId: HOST_DEVICE_ID,
            roleId: "host",
            publicKeyBase64: rawEd25519PublicKey(host.publicKey).toString("base64"),
            nonce: "approved-linux-host-nonce",
          },
          "1:123:linux:route-test",
        ),
      ),
    ).resolves.toEqual({ ok: true, roleId: "host" });
  });
});
