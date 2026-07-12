import { beforeEach, describe, expect, it, vi } from "vitest";

const { createToken, consumeChallenge } = vi.hoisted(() => ({
  createToken: vi.fn(async (appId: string, options?: { ttlMillis?: number }) => ({
    token: `token:${appId}`,
    ttlMillis: options?.ttlMillis ?? 1_800_000,
  })),
  consumeChallenge: vi.fn(async (args: { challengeId: string; uid: string }) => {
    if (args.uid === "alice-bola-uid" && args.challengeId === "bob-challenge") {
      throw Object.assign(new Error("challenge belongs to another account"), { code: "permission-denied" });
    }
  }),
}));

const APP_ID = "1:123:linux:production";

vi.mock("firebase-admin/app-check", () => ({ getAppCheck: () => ({ createToken }) }));
vi.mock("../callables/linuxAppCheckDevices.js", () => ({
  consumeLinuxAppCheckChallenge: consumeChallenge,
  LINUX_APP_CHECK_REJECTION_REASON: { appNotAllowlisted: "linux_app_not_allowlisted" },
}));
vi.mock("../config.js", () => ({
  getConfig: () => ({
    allowMockAppCheckAttestation: false,
    allowedAppCheckAppIDs: ["1:123:linux:production"],
    linuxAppCheckAppID: "1:123:linux:production",
  }),
  isAppCheckAppIdAllowed: (appId: unknown, config: { allowedAppCheckAppIDs: string[] }) =>
    typeof appId === "string" && config.allowedAppCheckAppIDs.includes(appId),
}));
vi.mock("../auth.js", () => ({ assertAuth: vi.fn() }));
vi.mock("../logging.js", () => ({
  logInfo: vi.fn(),
  wrapCallableHandler: (_name: string, handler: (request: unknown) => Promise<unknown>) => handler,
}));
vi.mock("../callables/publicRateLimit.js", () => ({ checkPublicHttpEndpointRateLimit: vi.fn(async () => undefined) }));

import { mintLinuxAppCheckToken } from "../callables/linuxAppCheck.js";
import { callableRunner, tier2CallableProof } from "./bola/callableBolaHarness.js";

const bolaStore = new Map<string, Record<string, unknown>>();

function invoke(data: Record<string, unknown>, uid = "linux-owner"): Promise<unknown> {
  return callableRunner(mintLinuxAppCheckToken)({ auth: { uid, token: {} }, data, rawRequest: { headers: {} } });
}

describe("production Linux device-key App Check mint handler", () => {
  beforeEach(() => {
    createToken.mockClear();
    consumeChallenge.mockClear();
    bolaStore.clear();
  });

  it("consumes the approved single-use challenge before minting the configured lower-trust token", async () => {
    const result = await invoke({
      attestation: {
        kind: "device-key-v1",
        appId: APP_ID,
        challengeId: "0123456789abcdef0123456789abcdef",
        deviceId: `linux_${"a".repeat(64)}`,
        signatureBase64: Buffer.alloc(64, 1).toString("base64"),
      },
      ttlMillis: 7 * 24 * 60 * 60 * 1000,
    });
    expect(consumeChallenge).toHaveBeenCalledWith({
      appId: APP_ID,
      challengeId: "0123456789abcdef0123456789abcdef",
      deviceId: `linux_${"a".repeat(64)}`,
      signatureBase64: Buffer.alloc(64, 1).toString("base64"),
      uid: "linux-owner",
    });
    expect(createToken).toHaveBeenCalledWith(APP_ID, { ttlMillis: 1_800_000 });
    expect(result).toMatchObject({
      ok: true,
      appCheckToken: `token:${APP_ID}`,
      appId: APP_ID,
      trustClass: "linux_lower_trust",
    });
    expect(consumeChallenge.mock.invocationCallOrder[0]).toBeLessThan(createToken.mock.invocationCallOrder[0]);
  });

  it("rejects wrong-app and fixture claims in production without consuming or minting", async () => {
    await expect(
      invoke({
        attestation: {
          kind: "device-key-v1",
          appId: "1:123:linux:evil",
          challengeId: "0123456789abcdef0123456789abcdef",
          deviceId: `linux_${"b".repeat(64)}`,
          signatureBase64: Buffer.alloc(64, 2).toString("base64"),
        },
      }),
    ).rejects.toMatchObject({
      code: "permission-denied",
      details: { reason: "linux_app_not_allowlisted" },
    });
    await expect(
      invoke({
        attestation: {
          kind: "mock",
          appId: APP_ID,
          nonce: "fixture-nonce-0123456789",
          issuedAtMs: Date.now(),
          mac: "deadbeef".repeat(8),
        },
      }),
    ).rejects.toMatchObject({ code: "permission-denied" });
    expect(consumeChallenge).not.toHaveBeenCalled();
    expect(createToken).not.toHaveBeenCalled();
  });

  it("requires Firebase Auth before any challenge or token work", async () => {
    await expect(invoke({}, "")).rejects.toMatchObject({ code: "unauthenticated" });
    expect(consumeChallenge).not.toHaveBeenCalled();
    expect(createToken).not.toHaveBeenCalled();
  });

  it("rejects cross-user challenge and device identifiers before minting", async () => {
    await tier2CallableProof(bolaStore, {
      exportedName: "mintLinuxAppCheckToken",
      run: callableRunner(mintLinuxAppCheckToken),
      payload: {
        attestation: {
          kind: "device-key-v1",
          appId: APP_ID,
          challengeId: "bob-challenge",
          deviceId: `linux_${"b".repeat(64)}`,
          signatureBase64: Buffer.alloc(64, 2).toString("base64"),
        },
      },
      expectedCode: "permission-denied",
      strictCode: true,
    });
    expect(createToken).not.toHaveBeenCalled();
  });
});
