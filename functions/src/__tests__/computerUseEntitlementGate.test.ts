/**
 * Server-side Agent Control entitlement gate.
 *
 * Product surfaces already gate Agent Control/Computer Use client-side, but the
 * cloud write boundary must fail closed too: a caller with auth, App Check,
 * high-risk nonce, and even trusted-device material still cannot publish pairing
 * or grant state without Cloud Pro/Ultra entitlement.
 */

import { describe, expect, it, vi } from "vitest";

const dbAccesses = vi.hoisted(() => new Array<string>());
const entitlementAllowedUids = vi.hoisted(() => new Set<string>());

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc(path: string) {
      dbAccesses.push(path);
      return {
        path,
        get: async () => ({ exists: false, get: () => undefined, data: () => undefined }),
        set: async () => undefined,
        delete: async () => undefined,
      };
    },
    runTransaction: async (fn: (transaction: unknown) => Promise<unknown>) =>
      fn({
        get: async (ref: { path?: string }) => {
          dbAccesses.push(ref.path ?? "<unknown>");
          return { exists: false, get: () => undefined, data: () => undefined };
        },
        set: () => undefined,
        create: () => undefined,
        update: () => undefined,
        delete: () => undefined,
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
  it.each([
    "publishIrohPairingPublicKey",
    "publishIrohPairingRecord",
    "revokeIrohPairingRecord",
    "publishPhoneControlAuthority",
    "publishRelaySenderKey",
    "publishAgentGrantAuthority",
    "queueAgentCapabilityGrantRequest",
    "respondMissionApproval",
  ] as const)("%s fails closed before Firestore state access for non-entitled callers", async (exportedName) => {
    entitlementAllowedUids.clear();
    dbAccesses.length = 0;
    const mod = await import("../callables/computerUseSecurity.js");
    const callable = mod[exportedName];

    await expect(run(callable)).rejects.toMatchObject({
      code: "permission-denied",
    });
    expect(dbAccesses).toEqual([]);
  });
});
