/**
 * Server-side Agent Control entitlement gate.
 *
 * Product surfaces already gate Agent Control/Computer Use client-side, but the
 * cloud write boundary must fail closed too: a caller with auth, App Check,
 * high-risk nonce, and even trusted-device material still cannot publish pairing
 * or grant state without Cloud Pro/Ultra entitlement.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";

const { dbAccesses, entitlementAllowedUids, firestoreDocs } = vi.hoisted(() => ({
  dbAccesses: new Array<string>(),
  entitlementAllowedUids: new Set<string>(),
  firestoreDocs: new Map<string, Record<string, unknown>>(),
}));

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc(path: string) {
      dbAccesses.push(path);
      return {
        path,
        get: async () => {
          const data = firestoreDocs.get(path);
          return { exists: data !== undefined, get: (field: string) => data?.[field], data: () => data };
        },
        set: async (data: Record<string, unknown>) => {
          firestoreDocs.set(path, { ...data });
        },
        delete: async () => {
          firestoreDocs.delete(path);
        },
      };
    },
    runTransaction: async (fn: (transaction: unknown) => Promise<unknown>) =>
      fn({
        get: async (ref: { path?: string }) => {
          const path = ref.path ?? "<unknown>";
          dbAccesses.push(path);
          const data = firestoreDocs.get(path);
          return { exists: data !== undefined, get: (field: string) => data?.[field], data: () => data };
        },
        set: (ref: { path?: string }, data: Record<string, unknown>) => {
          if (ref.path) firestoreDocs.set(ref.path, { ...data });
        },
        create: () => undefined,
        update: (ref: { path?: string }, data: Record<string, unknown>) => {
          if (ref.path) firestoreDocs.set(ref.path, { ...(firestoreDocs.get(ref.path) ?? {}), ...data });
        },
        delete: (ref: { path?: string }) => {
          if (ref.path) firestoreDocs.delete(ref.path);
        },
      }),
  },
  auth: {},
}));

vi.mock("firebase-admin/firestore", () => ({
  FieldValue: { serverTimestamp: () => ({ __serverTimestamp: true }) },
  Timestamp: {
    now: () => ({ toMillis: () => Date.now() }),
    fromMillis: (ms: number) => ({ toMillis: () => ms }),
  },
}));

vi.mock("../auth.js", () => ({
  assertAuth: vi.fn(),
  assertAppCheck: vi.fn(),
  assertOwnership: vi.fn(),
  enforceAuthAndAppCheck: vi.fn(),
}));

vi.mock("../config.js", () => ({
  getConfig: () => ({ enforceAppCheck: true, requireHighRiskNonce: true }),
}));

vi.mock("../appCheckAttestation.js", async () => {
  const actual = await vi.importActual<typeof import("../appCheckAttestation.js")>("../appCheckAttestation.js");
  return {
    ...actual,
    enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  };
});

vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  const { HttpsError } = await import("firebase-functions/v2/https");
  return {
    ...actual,
    assertActiveBurnBarCloudProEntitlement: vi.fn(async (uid: string): Promise<void> => {
      if (!entitlementAllowedUids.has(uid)) {
        throw new HttpsError(
          "permission-denied",
          "BurnBar Cloud Pro or Ultra is required for Floo, hosted Agent Control, and Elder Wand Fusion search.",
        );
      }
    }),
  };
});

vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: vi.fn(), logWarn: vi.fn() };
});

vi.mock("../signalDirectoryRuntime.js", () => ({ revokeSignalSessionsForDevice: vi.fn(async () => 0) }));

const UID = "uid-no-agent-control";
const MAC_DEVICE_ID = "mac-cleanup";
const CONNECTION_ID = "conn-cleanup";

function request(data: Record<string, unknown> = {}) {
  return {
    auth: { uid: UID, token: {} },
    app: { appId: "1:123:ios:abc" },
    data: { nonce: "n".repeat(64), ...data },
    rawRequest: { headers: {} },
  };
}

function run(callable: unknown, data?: Record<string, unknown>): Promise<unknown> {
  return (callable as { run: (request: unknown) => Promise<unknown> }).run(request(data));
}

describe("Computer Use callables require hosted Agent Control entitlement", () => {
  beforeEach(() => {
    entitlementAllowedUids.clear();
    dbAccesses.length = 0;
    firestoreDocs.clear();
  });

  it.each([
    "publishIrohPairingPublicKey",
    "publishIrohPairingRecord",
    "publishPhoneControlAuthority",
    "publishRelaySenderKey",
    "publishAgentGrantAuthority",
    "queueAgentCapabilityGrantRequest",
    "respondMissionApproval",
  ] as const)("%s fails closed before Firestore state access for non-entitled callers", async (exportedName) => {
    const mod = await import("../callables/computerUseSecurity.js");
    const callable = mod[exportedName];

    await expect(run(callable)).rejects.toMatchObject({
      code: "permission-denied",
    });
    expect(dbAccesses).toEqual([]);
  });

  it("revokeIrohPairingRecord remains available for cleanup after entitlement expiry", async () => {
    firestoreDocs.set(`users/${UID}/escrow_devices/${MAC_DEVICE_ID}`, {
      platform: "macOS",
      trustState: "trusted",
      keyVersion: 1,
    });
    firestoreDocs.set(`users/${UID}/iroh_pairing/${CONNECTION_ID}`, {
      id: CONNECTION_ID,
      publishedByDeviceId: MAC_DEVICE_ID,
    });
    const { revokeIrohPairingRecord } = await import("../callables/computerUseSecurity.js");

    await expect(
      run(revokeIrohPairingRecord, {
        deviceId: MAC_DEVICE_ID,
        connectionId: CONNECTION_ID,
      }),
    ).resolves.toEqual({ ok: true, connectionId: CONNECTION_ID });

    expect(firestoreDocs.has(`users/${UID}/iroh_pairing/${CONNECTION_ID}`)).toBe(false);
    expect(dbAccesses).toContain(`users/${UID}/escrow_devices/${MAC_DEVICE_ID}`);
  });
});
