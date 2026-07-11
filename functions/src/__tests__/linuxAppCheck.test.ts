import { createHash } from "node:crypto";

import { describe, expect, it } from "vitest";

import { __testing__, type AppCheckTokenMinter } from "../callables/linuxAppCheck.js";
import { PLACEHOLDER_LINUX_APP_CHECK_APP_ID } from "../config.js";
import {
  LINUX_APP_CHECK_TOKEN_TTL_MS,
  LINUX_ATTESTATION_CHALLENGE_TTL_MS,
  type LinuxAttestationBinding,
  type LinuxAttestationChallenge,
  type LinuxAttestationDecision,
  type LinuxAttestationVerifier,
} from "../security/linuxAttestation.js";

const {
  buildLinuxAttestationVerifiers,
  issueLinuxAppCheckChallengeCore,
  mintLinuxAppCheckTokenCore,
  mockMac,
  assertProductionPolicyConfigured,
  assertProductionAppIDAllowlisted,
  runtimePolicy,
  MOCK_ATTESTATION_KIND,
} = __testing__;

const NOW = 1_900_000_000_000;
const UID = "linux-user-1";
const APP_ID = PLACEHOLDER_LINUX_APP_CHECK_APP_ID;

interface Stored extends LinuxAttestationBinding {
  protocolVersion: 1;
  challengeHashSha256: string;
  createdAtMillis: number;
  expiresAtMillis: number;
  consumedAtMillis?: number;
}

class SharedChallengeStore {
  constructor(private readonly values = new Map<string, Stored>()) {}

  async create(binding: LinuxAttestationBinding, nowMillis: number): Promise<LinuxAttestationChallenge> {
    const challengeId = `challenge-${this.values.size + 1}`;
    const challenge = `fixture-challenge-${"x".repeat(32)}`;
    const expiresAtMillis = nowMillis + LINUX_ATTESTATION_CHALLENGE_TTL_MS;
    this.values.set(`${binding.uid}/${challengeId}`, {
      ...binding,
      protocolVersion: 1,
      challengeHashSha256: sha256(challenge),
      createdAtMillis: nowMillis,
      expiresAtMillis,
    });
    return { ...binding, protocolVersion: 1, challengeId, challenge, expiresAtMillis };
  }

  async load(uid: string, challengeId: string): Promise<Stored | undefined> {
    return this.values.get(`${uid}/${challengeId}`);
  }

  async consume(uid: string, challengeId: string, expectedHash: string, nowMillis: number): Promise<void> {
    const value = this.values.get(`${uid}/${challengeId}`);
    if (!value || value.challengeHashSha256 !== expectedHash) throw new Error("challenge missing");
    if (value.expiresAtMillis < nowMillis) throw new Error("challenge expired");
    if (value.consumedAtMillis != null) throw new Error("challenge replayed");
    value.consumedAtMillis = nowMillis;
  }
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function binding(overrides: Partial<LinuxAttestationBinding> = {}): LinuxAttestationBinding {
  return {
    uid: UID,
    appId: APP_ID,
    deviceId: "linux-device-1",
    appVersion: "1.0.30",
    architecture: "x86_64",
    releaseDigestSha256: "a".repeat(64),
    policyId: "openburnbar-linux-test-v1",
    attestationKind: MOCK_ATTESTATION_KIND,
    ...overrides,
  };
}

function stubMinter(): AppCheckTokenMinter & { calls: Array<{ appId: string; ttlMillis?: number }> } {
  const calls: Array<{ appId: string; ttlMillis?: number }> = [];
  const fn: AppCheckTokenMinter = async (appId, options) => {
    calls.push({ appId, ttlMillis: options?.ttlMillis });
    return { token: `linux-appcheck-token-for-${appId}`, ttlMillis: options?.ttlMillis ?? 0 };
  };
  return Object.assign(fn, { calls });
}

async function challengeFor(store: SharedChallengeStore): Promise<LinuxAttestationChallenge> {
  return issueLinuxAppCheckChallengeCore({ binding: binding(), store, nowMillis: NOW });
}

function evidence(challenge: LinuxAttestationChallenge, mac = mockMac(challenge)): Record<string, unknown> {
  return {
    challengeId: challenge.challengeId,
    challenge: challenge.challenge,
    kind: MOCK_ATTESTATION_KIND,
    evidence: { mac },
  };
}

describe("Linux App Check durable challenge boundary", () => {
  it("mints exactly a 30-minute lower-trust token and returns absolute expiry", async () => {
    const store = new SharedChallengeStore();
    const challenge = await challengeFor(store);
    const minter = stubMinter();
    const sessions: LinuxAttestationDecision[] = [];

    const result = await mintLinuxAppCheckTokenCore({
      uid: UID,
      rawEvidence: evidence(challenge),
      store,
      verifiers: buildLinuxAttestationVerifiers({
        allowMock: true,
        policy: { mintEnabled: false, appId: APP_ID, policyId: challenge.policyId },
      }),
      allowedAppIDs: [APP_ID],
      createToken: minter,
      recordSession: async (decision) => {
        sessions.push(decision);
      },
      nowMillis: NOW,
    });

    expect(result).toEqual({
      appCheckToken: `linux-appcheck-token-for-${APP_ID}`,
      issuedAtMillis: NOW,
      expireTimeMillis: NOW + LINUX_APP_CHECK_TOKEN_TTL_MS,
      appId: APP_ID,
      trustClass: "linux_lower_trust",
    });
    expect(minter.calls).toEqual([{ appId: APP_ID, ttlMillis: LINUX_APP_CHECK_TOKEN_TTL_MS }]);
    expect(sessions).toHaveLength(1);
  });

  it("anchors reported expiry conservatively before token creation latency", async () => {
    const store = new SharedChallengeStore();
    const challenge = await challengeFor(store);
    let currentTime = NOW;
    const result = await mintLinuxAppCheckTokenCore({
      uid: UID,
      rawEvidence: evidence(challenge),
      store,
      verifiers: buildLinuxAttestationVerifiers({
        allowMock: true,
        policy: { mintEnabled: false, appId: APP_ID, policyId: challenge.policyId },
      }),
      allowedAppIDs: [APP_ID],
      createToken: async () => {
        currentTime += 5_000;
        return { token: "delayed-token", ttlMillis: LINUX_APP_CHECK_TOKEN_TTL_MS };
      },
      recordSession: async () => undefined,
      nowMillis: NOW,
      currentTimeMillis: () => currentTime,
    });

    expect(result.issuedAtMillis).toBe(NOW);
    expect(result.expireTimeMillis).toBe(NOW + LINUX_APP_CHECK_TOKEN_TTL_MS);
    expect(result.expireTimeMillis).toBeLessThan(currentTime + LINUX_APP_CHECK_TOKEN_TTL_MS);
  });

  it("rejects forged evidence before consuming or minting", async () => {
    const store = new SharedChallengeStore();
    const challenge = await challengeFor(store);
    const minter = stubMinter();

    await expect(
      mintLinuxAppCheckTokenCore({
        uid: UID,
        rawEvidence: evidence(challenge, "0".repeat(64)),
        store,
        verifiers: buildLinuxAttestationVerifiers({
          allowMock: true,
          policy: { mintEnabled: false, appId: APP_ID, policyId: challenge.policyId },
        }),
        allowedAppIDs: [APP_ID],
        createToken: minter,
        recordSession: async () => undefined,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/did not verify/i);
    expect(minter.calls).toHaveLength(0);
  });

  it("rejects replay across service instances sharing durable state", async () => {
    const durable = new Map<string, Stored>();
    const firstStore = new SharedChallengeStore(durable);
    const secondStore = new SharedChallengeStore(durable);
    const challenge = await challengeFor(firstStore);
    const minter = stubMinter();
    const params = {
      uid: UID,
      rawEvidence: evidence(challenge),
      verifiers: buildLinuxAttestationVerifiers({
        allowMock: true,
        policy: { mintEnabled: false, appId: APP_ID, policyId: challenge.policyId },
      }),
      allowedAppIDs: [APP_ID],
      createToken: minter,
      recordSession: async () => undefined,
      nowMillis: NOW,
    };

    await expect(mintLinuxAppCheckTokenCore({ ...params, store: firstStore })).resolves.toMatchObject({
      appId: APP_ID,
    });
    await expect(mintLinuxAppCheckTokenCore({ ...params, store: secondStore })).rejects.toThrow(/already consumed/i);
    expect(minter.calls).toHaveLength(1);
  });

  it("allows exactly one winner when two instances mint concurrently", async () => {
    const durable = new Map<string, Stored>();
    const challenge = await challengeFor(new SharedChallengeStore(durable));
    const minter = stubMinter();
    const common = {
      uid: UID,
      rawEvidence: evidence(challenge),
      verifiers: buildLinuxAttestationVerifiers({
        allowMock: true,
        policy: { mintEnabled: false, appId: APP_ID, policyId: challenge.policyId },
      }),
      allowedAppIDs: [APP_ID],
      createToken: minter,
      recordSession: async () => undefined,
      nowMillis: NOW,
    };

    const outcomes = await Promise.allSettled([
      mintLinuxAppCheckTokenCore({ ...common, store: new SharedChallengeStore(durable) }),
      mintLinuxAppCheckTokenCore({ ...common, store: new SharedChallengeStore(durable) }),
    ]);

    expect(outcomes.filter((outcome) => outcome.status === "fulfilled")).toHaveLength(1);
    expect(outcomes.filter((outcome) => outcome.status === "rejected")).toHaveLength(1);
    expect(minter.calls).toHaveLength(1);
  });

  it("rechecks challenge freshness after a suspended verifier returns", async () => {
    const store = new SharedChallengeStore();
    const challenge = await challengeFor(store);
    const minter = stubMinter();
    let currentTime = NOW;
    let releaseVerifier: (() => void) | undefined;
    const verifierGate = new Promise<void>((resolve) => {
      releaseVerifier = resolve;
    });
    const verifier: LinuxAttestationVerifier = {
      kind: MOCK_ATTESTATION_KIND,
      async verify({ challenge: boundChallenge }) {
        await verifierGate;
        return {
          ...boundChallenge,
          trustClass: "linux_lower_trust",
          verifierReceiptHash: "b".repeat(64),
          attestedAtMillis: NOW,
          expiresAtMillis: boundChallenge.expiresAtMillis,
        };
      },
    };

    const mint = mintLinuxAppCheckTokenCore({
      uid: UID,
      rawEvidence: evidence(challenge),
      store,
      verifiers: new Map([[MOCK_ATTESTATION_KIND, verifier]]),
      allowedAppIDs: [APP_ID],
      createToken: minter,
      recordSession: async () => undefined,
      nowMillis: NOW,
      currentTimeMillis: () => currentTime,
    });
    currentTime = challenge.expiresAtMillis + 1;
    releaseVerifier?.();

    await expect(mint).rejects.toThrow(/mismatched identity binding/i);
    expect(minter.calls).toHaveLength(0);
  });

  it("derives a unique session id even when the verifier reuses a receipt hash", async () => {
    const store = new SharedChallengeStore();
    const verifier: LinuxAttestationVerifier = {
      kind: MOCK_ATTESTATION_KIND,
      async verify({ challenge }) {
        return {
          ...challenge,
          trustClass: "linux_lower_trust",
          verifierReceiptHash: "c".repeat(64),
          attestedAtMillis: NOW,
          expiresAtMillis: challenge.expiresAtMillis,
        };
      },
    };
    const sessionIDs: string[] = [];
    for (let index = 0; index < 2; index += 1) {
      const challenge = await challengeFor(store);
      await mintLinuxAppCheckTokenCore({
        uid: UID,
        rawEvidence: evidence(challenge),
        store,
        verifiers: new Map([[MOCK_ATTESTATION_KIND, verifier]]),
        allowedAppIDs: [APP_ID],
        createToken: stubMinter(),
        recordSession: async (_decision, sessionID) => {
          sessionIDs.push(sessionID);
        },
        nowMillis: NOW,
      });
    }
    expect(sessionIDs).toHaveLength(2);
    expect(new Set(sessionIDs).size).toBe(2);
    expect(sessionIDs.every((sessionID) => /^[a-f0-9]{64}$/u.test(sessionID))).toBe(true);
  });

  it("rejects expired, wrong-user, wrong-kind, and non-allowlisted challenges", async () => {
    const store = new SharedChallengeStore();
    const challenge = await challengeFor(store);
    const verifierMap = buildLinuxAttestationVerifiers({
      allowMock: true,
      policy: { mintEnabled: false, appId: APP_ID, policyId: challenge.policyId },
    });
    const base = {
      store,
      verifiers: verifierMap,
      allowedAppIDs: [APP_ID],
      createToken: stubMinter(),
      recordSession: async () => undefined,
    };
    await expect(
      mintLinuxAppCheckTokenCore({
        ...base,
        uid: UID,
        rawEvidence: evidence(challenge),
        nowMillis: challenge.expiresAtMillis + 1,
      }),
    ).rejects.toThrow(/expired/i);
    await expect(
      mintLinuxAppCheckTokenCore({ ...base, uid: "other-user", rawEvidence: evidence(challenge), nowMillis: NOW }),
    ).rejects.toThrow(/missing or does not belong/i);
    await expect(
      mintLinuxAppCheckTokenCore({
        ...base,
        uid: UID,
        rawEvidence: { ...evidence(challenge), kind: "unsupported" },
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/does not match/i);

    const otherStore = new SharedChallengeStore();
    const other = await challengeFor(otherStore);
    await expect(
      mintLinuxAppCheckTokenCore({
        ...base,
        store: otherStore,
        uid: UID,
        rawEvidence: evidence(other),
        allowedAppIDs: [],
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/not allowlisted/i);
  });

  it("keeps production disabled for placeholders or incomplete verifier configuration", () => {
    expect(() =>
      assertProductionPolicyConfigured({
        mintEnabled: false,
        appId: APP_ID,
        policyId: "policy",
      }),
    ).toThrow(/disabled/i);
    expect(() =>
      assertProductionPolicyConfigured({
        mintEnabled: true,
        appId: APP_ID,
        policyId: "policy",
      }),
    ).toThrow(/dedicated Firebase Web app id/i);
    expect(() =>
      assertProductionPolicyConfigured({
        mintEnabled: true,
        appId: "1:123456:web:abcdef",
        policyId: "policy",
      }),
    ).toThrow(/incomplete/i);

    const completePolicy = {
      mintEnabled: true,
      appId: "1:123456:web:abcdef",
      policyId: "policy",
      verifierURL: new URL("https://verifier.example.test/verify"),
      verifierOIDCAudience: "https://verifier.example.test",
      verifierPublicKeyBase64: "configured",
      verifierKeyID: "key-1",
      verifierIssuer: "issuer",
      verifierAudience: "audience",
    };
    expect(() => assertProductionAppIDAllowlisted(completePolicy, [])).toThrow(/not operator-allowlisted/i);
    expect(() => assertProductionAppIDAllowlisted(completePolicy, [completePolicy.appId])).not.toThrow();
    expect(() =>
      assertProductionPolicyConfigured({
        ...completePolicy,
        verifierOIDCAudience: "https://different-verifier.example.test",
      }),
    ).toThrow(/OIDC audience.*exactly match/i);
  });

  it("accepts only a fixed HTTPS verifier endpoint from runtime configuration", () => {
    expect(
      runtimePolicy({
        LINUX_APP_CHECK_VERIFIER_URL: "http://verifier.example.test/verify",
        LINUX_APP_CHECK_VERIFIER_OIDC_AUDIENCE: "http://verifier.example.test",
      }).verifierURL,
    ).toBeUndefined();
    expect(
      runtimePolicy({
        LINUX_APP_CHECK_VERIFIER_URL: "https://verifier.example.test/verify?redirect=other",
        LINUX_APP_CHECK_VERIFIER_OIDC_AUDIENCE: "https://verifier.example.test",
      }).verifierURL,
    ).toBeUndefined();

    const policy = runtimePolicy({
      LINUX_APP_CHECK_VERIFIER_URL: "https://verifier.example.test/verify",
      LINUX_APP_CHECK_VERIFIER_OIDC_AUDIENCE: "https://verifier.example.test",
    });
    expect(policy.verifierURL?.href).toBe("https://verifier.example.test/verify");
    expect(policy.verifierOIDCAudience).toBe("https://verifier.example.test");
  });

  it("registers mock verification only when explicitly allowed", () => {
    const policy = { mintEnabled: false, appId: APP_ID, policyId: "policy" };
    expect(buildLinuxAttestationVerifiers({ allowMock: true, policy }).has(MOCK_ATTESTATION_KIND)).toBe(true);
    expect(buildLinuxAttestationVerifiers({ allowMock: false, policy }).size).toBe(0);
  });
});
