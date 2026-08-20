import { generateKeyPairSync, createSign } from "node:crypto";

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
      runTransaction: async (
        fn: (tx: {
          get: (ref: { get: () => Promise<unknown> }) => Promise<unknown>;
          set: (
            ref: { set: (data: Record<string, unknown>, options?: { merge?: boolean }) => Promise<void> },
            data: Record<string, unknown>,
            options?: { merge?: boolean },
          ) => Promise<void>;
        }) => Promise<unknown>,
      ) => {
        const tx = {
          get: (ref: { get: () => Promise<unknown> }) => ref.get(),
          set: (
            ref: { set: (data: Record<string, unknown>, options?: { merge?: boolean }) => Promise<void> },
            data: Record<string, unknown>,
            options?: { merge?: boolean },
          ) => ref.set(data, options),
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
  requireTrustedDeviceActionProof: vi.fn(async () => ({ deviceId: "dev", platform: "iOS" })),
  appendComputerUseAuditEvent: vi.fn(async () => undefined),
}));
vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return { ...actual, assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined) };
});
vi.mock("../callables/publicRateLimit.js", () => ({
  recordCallableApprovalFailure: vi.fn(async () => undefined),
  assertCallableApprovalNotLocked: vi.fn(async () => undefined),
}));

import { callableRunner } from "./bola/callableBolaHarness.js";
import { ALICE_UID } from "./bola/callableBolaHarness.js";
import {
  canonicalCeilingBytes,
  ceilingDigest,
  publishMissionApprovalCeiling,
  redeemMissionApprovalAnswer,
} from "../callables/missionApprovalAnswers.js";

const runPublish = callableRunner(publishMissionApprovalCeiling);
const runRedeem = callableRunner(redeemMissionApprovalAnswer);

function authed(data: Record<string, unknown>) {
  return {
    auth: { uid: ALICE_UID, token: {} },
    app: { appId: "test" },
    rawRequest: { headers: {} },
    data: { nonce: "n", deviceId: "iphone-1", actionProof: {}, ...data },
  };
}

describe("missionApprovalAnswers", () => {
  const keys = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const canonical = {
    missionID: "m1",
    requestedGrant: { commandsAllowed: false, fileEditsAllowed: false, additionalCapabilities: [] },
    grantCeiling: { commandsAllowed: false, fileEditsAllowed: false, additionalCapabilities: [] },
    promptSHA256: "aa".repeat(32),
    personaDigest: "bb".repeat(32),
    requestedRuntime: "codex",
    approvalMode: "existing_policy",
    issuedAt: "2026-08-19T00:00:00.000Z",
  };
  const digest = ceilingDigest(canonical);
  const signer = createSign("SHA256");
  signer.update(canonicalCeilingBytes(canonical));
  const signature = signer.sign(keys.privateKey, "base64");
  const publicKeyPem = keys.publicKey.export({ type: "pkcs1", format: "pem" }).toString();

  beforeEach(() => {
    hoisted.store.clear();
    hoisted.store.set(`users/${ALICE_UID}/cli_agent_mission_requests/m1`, {
      id: "m1",
      claimedBy: "mac-1",
      status: "accepted",
    });
    hoisted.store.set(`users/${ALICE_UID}/escrow_devices/mac-1`, {
      publicKeyPem,
      trustState: "trusted",
      platform: "macOS",
    });
  });

  it("refuses digest-as-signature and a wrong or missing signature", async () => {
    await expect(
      runPublish(
        authed({
          requestId: "m1",
          deviceId: "mac-1",
          canonical,
          ceilingDigest: digest,
          signature: digest,
        }),
      ),
    ).rejects.toMatchObject({ code: "permission-denied" });
    await expect(
      runPublish(
        authed({
          requestId: "m1",
          deviceId: "mac-1",
          canonical,
          ceilingDigest: digest,
          signature: Buffer.from("not-a-mac-signature").toString("base64"),
        }),
      ),
    ).rejects.toMatchObject({ code: "permission-denied" });
    await expect(
      runPublish(
        authed({
          requestId: "m1",
          deviceId: "mac-1",
          canonical,
          ceilingDigest: digest,
        }),
      ),
    ).rejects.toMatchObject({ code: "invalid-argument" });
  });

  it("refuses digest-as-signature when only a Signal identity is published", async () => {
    hoisted.store.set(`users/${ALICE_UID}/escrow_devices/mac-1`, {
      trustState: "trusted",
      platform: "macOS",
      targetSignalIdentityKeyId: "mac-1_1",
    });
    hoisted.store.set(`users/${ALICE_UID}/signal_identity_public_keys/mac-1_1`, {
      deviceId: "mac-1",
      identityKeyId: "mac-1_1",
      publicKeyData: Buffer.alloc(33, 5).toString("base64"),
    });
    await expect(
      runPublish(
        authed({
          requestId: "m1",
          deviceId: "mac-1",
          canonical,
          ceilingDigest: digest,
          signature: digest,
        }),
      ),
    ).rejects.toMatchObject({ code: "permission-denied" });
  });

  it("publishes a Mac-signed ceiling and redeems once", async () => {
    await expect(
      runPublish(
        authed({
          requestId: "m1",
          deviceId: "mac-1",
          canonical,
          ceilingDigest: digest,
          signature,
          publicKeyPem,
        }),
      ),
    ).resolves.toMatchObject({ ok: true, ceilingDigest: digest });

    await expect(
      runRedeem(
        authed({
          requestId: "m1",
          answerId: "ans-1",
          ceilingDigest: digest,
          requestedGrant: canonical.requestedGrant,
        }),
      ),
    ).resolves.toMatchObject({ consumed: true });

    await expect(
      runRedeem(
        authed({
          requestId: "m1",
          answerId: "ans-1",
          ceilingDigest: digest,
          requestedGrant: canonical.requestedGrant,
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });

  it("refuses a wider grant than the Mac-signed ceiling", async () => {
    await runPublish(
      authed({
        requestId: "m1",
        deviceId: "mac-1",
        canonical,
        ceilingDigest: digest,
        signature,
        publicKeyPem,
      }),
    );
    await expect(
      runRedeem(
        authed({
          requestId: "m1",
          answerId: "ans-wide",
          ceilingDigest: digest,
          requestedGrant: { commandsAllowed: true, fileEditsAllowed: false, additionalCapabilities: [] },
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });

  it("refusesExpiredCeiling", async () => {
    await runPublish(
      authed({
        requestId: "m1",
        deviceId: "mac-1",
        canonical,
        ceilingDigest: digest,
        signature,
      }),
    );
    const ceiling = hoisted.store.get(`users/${ALICE_UID}/mission_approval_ceilings/m1`);
    if (ceiling) ceiling.expiresAtMs = Date.now() - 1;
    await expect(
      runRedeem(
        authed({
          requestId: "m1",
          ceilingDigest: digest,
          requestedGrant: canonical.requestedGrant,
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });

  it("refusesPromptHashMismatch", async () => {
    await runPublish(
      authed({
        requestId: "m1",
        deviceId: "mac-1",
        canonical,
        ceilingDigest: digest,
        signature,
      }),
    );
    await expect(
      runRedeem(
        authed({
          requestId: "m1",
          ceilingDigest: "ff".repeat(32),
          requestedGrant: canonical.requestedGrant,
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });

  it("VAL-AGT-005 refuses extra requested capabilities when ceiling is empty", async () => {
    const extra = {
      ...canonical,
      grantCeiling: { commandsAllowed: false, fileEditsAllowed: false, additionalCapabilities: [] },
    };
    const extraDigest = ceilingDigest(extra);
    const extraSigner = createSign("SHA256");
    extraSigner.update(canonicalCeilingBytes(extra));
    const extraSig = extraSigner.sign(keys.privateKey, "base64");
    await runPublish(
      authed({
        requestId: "m1",
        deviceId: "mac-1",
        canonical: extra,
        ceilingDigest: extraDigest,
        signature: extraSig,
      }),
    );
    await expect(
      runRedeem(
        authed({
          requestId: "m1",
          ceilingDigest: extraDigest,
          requestedGrant: { commandsAllowed: false, fileEditsAllowed: false, additionalCapabilities: ["shell"] },
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });

  it("VAL-AGT-005 refuses replay, expiry, cross-device publish, and missing signature", async () => {
    await runPublish(
      authed({
        requestId: "m1",
        deviceId: "mac-1",
        canonical,
        ceilingDigest: digest,
        signature,
      }),
    );
    await runRedeem(
      authed({
        requestId: "m1",
        ceilingDigest: digest,
        requestedGrant: canonical.requestedGrant,
      }),
    );
    await expect(
      runRedeem(
        authed({
          requestId: "m1",
          ceilingDigest: digest,
          requestedGrant: canonical.requestedGrant,
        }),
      ),
    ).rejects.toMatchObject({ code: "failed-precondition" });

    hoisted.store.set(`users/${ALICE_UID}/cli_agent_mission_requests/m2`, {
      id: "m2",
      claimedBy: "mac-1",
      status: "accepted",
    });
    const m2Canonical = { ...canonical, missionID: "m2" };
    const m2Digest = ceilingDigest(m2Canonical);
    const m2Signer = createSign("SHA256");
    m2Signer.update(canonicalCeilingBytes(m2Canonical));
    const m2Sig = m2Signer.sign(keys.privateKey, "base64");
    await expect(
      runPublish(
        authed({
          requestId: "m2",
          deviceId: "mac-other",
          canonical: m2Canonical,
          ceilingDigest: m2Digest,
          signature: m2Sig,
        }),
      ),
    ).rejects.toMatchObject({ code: "permission-denied" });

    hoisted.store.set(`users/${ALICE_UID}/cli_agent_mission_requests/m3`, {
      id: "m3",
      claimedBy: "mac-1",
      status: "accepted",
    });
    const m3Canonical = { ...canonical, missionID: "m3" };
    const m3Digest = ceilingDigest(m3Canonical);
    await expect(
      runPublish(
        authed({
          requestId: "m3",
          deviceId: "mac-1",
          canonical: m3Canonical,
          ceilingDigest: m3Digest,
          signature: "not-a-signature",
        }),
      ),
    ).rejects.toMatchObject({ code: "permission-denied" });
  });
});
