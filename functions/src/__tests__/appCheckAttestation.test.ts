/**
 * Unit tests for App Check attestation custom-claim helpers (WS4) and the
 * single-use high-risk action nonce replay-defense helpers (B-SEC-4).
 */

import { describe, expect, it, vi } from "vitest";

// In-memory Firestore double shared by the hoisted `db` mock and the
// `firebase-admin/firestore` Timestamp mock. Keyed by full doc path, holding the
// last-written nonce document so issue → consume → re-consume can be asserted.
const { store, dbMock, FakeTimestamp } = vi.hoisted(() => {
  const store = new Map<string, Record<string, unknown>>();
  class FakeTimestamp {
    constructor(public readonly ms: number) {}
    static fromMillis(ms: number): FakeTimestamp {
      return new FakeTimestamp(ms);
    }
    toMillis(): number {
      return this.ms;
    }
  }
  const makeRef = (path: string) => ({
    path,
    async set(data: Record<string, unknown>) {
      store.set(path, { ...data });
    },
    async get() {
      const data = store.get(path);
      return { exists: data !== undefined, data: () => data };
    },
  });
  const dbMock = {
    doc: (path: string) => makeRef(path),
    async runTransaction<T>(fn: (tx: unknown) => Promise<T>): Promise<T> {
      const tx = {
        async get(ref: { path: string }) {
          const data = store.get(ref.path);
          return { exists: data !== undefined, data: () => data };
        },
        update(ref: { path: string }, patch: Record<string, unknown>) {
          const existing = store.get(ref.path);
          if (!existing) throw new Error(`update on missing doc ${ref.path}`);
          store.set(ref.path, { ...existing, ...patch });
        },
      };
      return fn(tx);
    },
  };
  return { store, dbMock, FakeTimestamp };
});

vi.mock("../adminRuntime.js", () => ({ db: dbMock, auth: {} }));
vi.mock("firebase-admin/firestore", () => ({ Timestamp: FakeTimestamp }));

// Stub the auth assertions so `enforceHighRiskComputerUseCallableWithNonce`
// reaches the nonce-branch logic without a real auth/App-Check context. The
// staged-rollout decision under test is driven purely by config + the supplied
// nonce, not by these guards (covered separately).
vi.mock("../auth.js", () => ({
  assertAuth: vi.fn(),
  assertAppCheck: vi.fn(),
  assertOwnership: vi.fn(),
  enforceAuthAndAppCheck: vi.fn(),
}));

const { configMock } = vi.hoisted(() => ({
  configMock: { enforceAppCheck: true, requireHighRiskNonce: false },
}));
vi.mock("../config.js", () => ({ getConfig: () => configMock }));

import {
  APP_CHECK_ATTESTATION_CLAIM_KEY,
  HIGH_RISK_NONCE_TTL_MS,
  consumeHighRiskNonceForUid,
  enforceHighRiskComputerUseCallableWithNonce,
  isAppCheckAttestationClaimFresh,
  issueHighRiskNonceForUid,
  readAppCheckAttestationClaim,
  readAppIdFromCallableRequest,
} from "../appCheckAttestation.js";

// A request that satisfies `assertAppAttestBoundClaims`: live App Check app id
// plus a fresh, matching bound claim. The auth assertions are mocked to no-ops;
// the attestation check inside the module under test is real, so the claim must
// be valid for the staged-rollout branches to be exercised.
const fakeRequest = {
  app: { appId: "1:123:ios:abc" },
  auth: {
    uid: "userA",
    token: {
      [APP_CHECK_ATTESTATION_CLAIM_KEY]: { v: 1, appId: "1:123:ios:abc", boundAtMillis: Date.now() },
    },
  },
} as never;

describe("appCheckAttestation", () => {
  it("reads app id from callable App Check metadata", () => {
    expect(readAppIdFromCallableRequest({ app: { appId: "1:123:ios:abc" } } as never)).toBe("1:123:ios:abc");
    expect(readAppIdFromCallableRequest({} as never)).toBeUndefined();
  });

  it("reads and validates attestation claims from auth tokens", () => {
    const claim = readAppCheckAttestationClaim({
      [APP_CHECK_ATTESTATION_CLAIM_KEY]: {
        v: 1,
        appId: "1:123:ios:abc",
        boundAtMillis: Date.now() - 60_000,
      },
    });
    expect(claim?.appId).toBe("1:123:ios:abc");
    expect(isAppCheckAttestationClaimFresh(claim!)).toBe(true);
    expect(
      isAppCheckAttestationClaimFresh({
        v: 1,
        appId: "1:123:ios:abc",
        boundAtMillis: Date.now() - 31 * 24 * 60 * 60 * 1000,
      }),
    ).toBe(false);
  });
});

describe("high-risk action nonces", () => {
  it("issues a nonce doc with consumedAt:null and expiresAtMillis = now + TTL", async () => {
    store.clear();
    const now = 1_000_000;
    const { nonce, expiresAtMillis } = await issueHighRiskNonceForUid("userA", now);
    expect(nonce.length).toBeGreaterThanOrEqual(16);
    expect(expiresAtMillis).toBe(now + HIGH_RISK_NONCE_TTL_MS);
    const doc = store.get(`users/userA/high_risk_action_nonces/${nonce}`);
    expect(doc).toBeDefined();
    expect(doc?.consumedAt).toBeNull();
    expect(doc?.expiresAtMillis).toBe(now + HIGH_RISK_NONCE_TTL_MS);
  });

  it("consumes a nonce exactly once (second use is rejected)", async () => {
    store.clear();
    const now = 2_000_000;
    const { nonce } = await issueHighRiskNonceForUid("userA", now);
    await expect(consumeHighRiskNonceForUid("userA", nonce, now + 1)).resolves.toBeUndefined();
    await expect(consumeHighRiskNonceForUid("userA", nonce, now + 2)).rejects.toThrow(/expired or was already used/);
  });

  it("rejects an expired nonce", async () => {
    store.clear();
    const now = 3_000_000;
    const { nonce } = await issueHighRiskNonceForUid("userA", now);
    await expect(consumeHighRiskNonceForUid("userA", nonce, now + HIGH_RISK_NONCE_TTL_MS + 1)).rejects.toThrow(
      /expired or was already used/,
    );
  });

  it("scopes nonces per-uid (user B cannot consume user A's nonce)", async () => {
    store.clear();
    const now = 4_000_000;
    const { nonce } = await issueHighRiskNonceForUid("userA", now);
    await expect(consumeHighRiskNonceForUid("userB", nonce, now + 1)).rejects.toThrow(/expired or was already used/);
    // userA can still consume it.
    await expect(consumeHighRiskNonceForUid("userA", nonce, now + 1)).resolves.toBeUndefined();
  });

  it("rejects malformed nonce strings (fail-closed)", async () => {
    store.clear();
    await expect(consumeHighRiskNonceForUid("userA", "short", Date.now())).rejects.toThrow(
      /valid high-risk action nonce/,
    );
  });
});

describe("enforceHighRiskComputerUseCallableWithNonce — staged rollout", () => {
  it("flag off + no nonce resolves with nonceConsumed:false (back-compat with in-flight clients)", async () => {
    store.clear();
    configMock.enforceAppCheck = true;
    configMock.requireHighRiskNonce = false;
    await expect(enforceHighRiskComputerUseCallableWithNonce(fakeRequest, "userA", undefined)).resolves.toEqual({
      nonceConsumed: false,
    });
  });

  it("App Check disabled (emulator) resolves with nonceConsumed:false", async () => {
    store.clear();
    configMock.enforceAppCheck = false;
    configMock.requireHighRiskNonce = false;
    try {
      await expect(enforceHighRiskComputerUseCallableWithNonce(fakeRequest, "userA", undefined)).resolves.toEqual({
        nonceConsumed: false,
      });
    } finally {
      configMock.enforceAppCheck = true;
    }
  });

  it("flag on + no nonce throws", async () => {
    store.clear();
    configMock.enforceAppCheck = true;
    configMock.requireHighRiskNonce = true;
    try {
      await expect(enforceHighRiskComputerUseCallableWithNonce(fakeRequest, "userA", undefined)).rejects.toThrow(
        /issueHighRiskActionNonce/,
      );
    } finally {
      configMock.requireHighRiskNonce = false;
    }
  });

  it("a supplied-but-invalid nonce is rejected regardless of the flag (fail-closed)", async () => {
    store.clear();
    configMock.enforceAppCheck = true;
    configMock.requireHighRiskNonce = false;
    await expect(enforceHighRiskComputerUseCallableWithNonce(fakeRequest, "userA", "x".repeat(64))).rejects.toThrow(
      /expired or was already used/,
    );
  });

  it("a valid issued nonce is consumed and allows the action once", async () => {
    store.clear();
    configMock.enforceAppCheck = true;
    configMock.requireHighRiskNonce = true;
    try {
      const { nonce } = await issueHighRiskNonceForUid("userA", Date.now());
      await expect(enforceHighRiskComputerUseCallableWithNonce(fakeRequest, "userA", nonce)).resolves.toEqual({
        nonceConsumed: true,
      });
      // Replay of the same nonce now fails (single-use).
      await expect(enforceHighRiskComputerUseCallableWithNonce(fakeRequest, "userA", nonce)).rejects.toThrow(
        /expired or was already used/,
      );
    } finally {
      configMock.requireHighRiskNonce = false;
    }
  });
});
