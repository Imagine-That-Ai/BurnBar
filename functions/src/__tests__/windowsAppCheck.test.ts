/**
 * VAL-P0-AC-011 — Windows-port App Check mint backend + MOCK verifier +
 * attestation-gated production fence.
 *
 * Proves:
 *   (a) mint SUCCESS on a valid mock claim under dev/test config,
 *   (b) REJECTION of invalid / forged / replayed (and wrong-app / stale /
 *       not-allowlisted) claims,
 *   (c) under PRODUCTION config the mock verifier is ABSENT, so a mock claim
 *       cannot verify and cannot mint (no accepting verifier) — while the mint
 *       PATH stays available for a future real verifier (AC-013).
 *
 * The mint core takes an injected `createToken`, so no live Firebase project is
 * needed and macOS runs it fully.
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import {
  __testing__,
  type AppCheckTokenMinter,
  type WindowsAttestationClaim,
  type WindowsAttestationVerifier,
  type WindowsAttestationChallengeStore,
} from "../callables/windowsAppCheck.js";
import { PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID } from "../config.js";

const {
  buildWindowsAttestationVerifiers,
  mintWindowsAppCheckTokenCore,
  signMockAttestation,
  MOCK_ATTESTATION_KIND,
  MOCK_ATTESTATION_MAX_AGE_MS,
  DEFAULT_MINT_TTL_MS,
  TPM_ATTESTATION_KIND,
  issueWindowsAppCheckChallengeCore,
  MAX_TPM_PLATFORM_CLAIM_BASE64_LENGTH,
  MAX_TPM_SUBJECT_PUBLIC_KEY_BASE64_LENGTH,
  MAX_TPM_CHALLENGE_ID_LENGTH,
} = __testing__;

const NOW = 1_900_000_000_000;
const APP_ID = PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID;

/** A well-formed, freshly-signed mock claim bound to `appId`. */
function validClaim(overrides: Partial<WindowsAttestationClaim> = {}): WindowsAttestationClaim {
  const appId = overrides.appId ?? APP_ID;
  const nonce = overrides.nonce ?? "nonce-0123456789abcdef";
  const issuedAtMs = overrides.issuedAtMs ?? NOW;
  const base: WindowsAttestationClaim = {
    kind: MOCK_ATTESTATION_KIND,
    appId,
    nonce,
    issuedAtMs,
    mac: signMockAttestation({ appId, nonce, issuedAtMs }),
  };
  return { ...base, ...overrides };
}

/** createToken stub that records its args and echoes a deterministic token. */
function stubMinter(): AppCheckTokenMinter & { calls: Array<{ appId: string; ttlMillis?: number }> } {
  const calls: Array<{ appId: string; ttlMillis?: number }> = [];
  const fn: AppCheckTokenMinter = async (appId, options) => {
    calls.push({ appId, ttlMillis: options?.ttlMillis });
    return { token: `appcheck-token-for-${appId}`, ttlMillis: options?.ttlMillis ?? DEFAULT_MINT_TTL_MS };
  };
  return Object.assign(fn, { calls });
}

/** Dev/test verifier registry: the mock verifier IS registered. */
function devVerifiers(replayStore = new Set<string>()): Map<string, WindowsAttestationVerifier> {
  return buildWindowsAttestationVerifiers({ allowMock: true, expectedAppId: APP_ID, replayStore });
}

describe("VAL-P0-AC-011 mint success (dev/test config)", () => {
  it("mints an App Check token for a valid mock claim via createToken(appId,{ttlMillis})", async () => {
    const createToken = stubMinter();
    const result = await mintWindowsAppCheckTokenCore({
      claim: validClaim(),
      verifiers: devVerifiers(),
      allowedAppIDs: [APP_ID],
      createToken,
      nowMillis: NOW,
    });

    expect(result.appId).toBe(APP_ID);
    expect(result.appCheckToken).toBe(`appcheck-token-for-${APP_ID}`);
    expect(result.ttlMillis).toBe(DEFAULT_MINT_TTL_MS);
    // Minted through the real createToken surface with the placeholder app id.
    expect(createToken.calls).toEqual([{ appId: APP_ID, ttlMillis: DEFAULT_MINT_TTL_MS }]);
  });

  it("honours a caller ttl within Firebase's 30min..7day bounds and clamps out-of-range values", async () => {
    const createToken = stubMinter();
    await mintWindowsAppCheckTokenCore({
      claim: validClaim({ nonce: "nonce-within-bounds-000" }),
      verifiers: devVerifiers(),
      allowedAppIDs: [APP_ID],
      createToken,
      nowMillis: NOW,
      ttlMillis: 60 * 60 * 1000, // 1h, valid
    });
    // A 10-second ttl is clamped up to the 30-minute floor.
    await mintWindowsAppCheckTokenCore({
      claim: validClaim({ nonce: "nonce-too-small-ttl-001" }),
      verifiers: devVerifiers(),
      allowedAppIDs: [APP_ID],
      createToken,
      nowMillis: NOW,
      ttlMillis: 10_000,
    });
    expect(createToken.calls[0].ttlMillis).toBe(60 * 60 * 1000);
    expect(createToken.calls[1].ttlMillis).toBe(DEFAULT_MINT_TTL_MS);
  });
});

describe("VAL-P0-AC-011 rejects invalid / forged / replayed claims", () => {
  it("rejects a forged claim (bad MAC) and does NOT mint", async () => {
    const createToken = stubMinter();
    const forged = validClaim({ mac: "deadbeef".repeat(8) });
    await expect(
      mintWindowsAppCheckTokenCore({
        claim: forged,
        verifiers: devVerifiers(),
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/did not verify/i);
    expect(createToken.calls).toHaveLength(0);
  });

  it("rejects a claim forged under the wrong secret", async () => {
    const createToken = stubMinter();
    const claim = validClaim({
      nonce: "nonce-wrong-secret-0001",
      mac: signMockAttestation({ appId: APP_ID, nonce: "nonce-wrong-secret-0001", issuedAtMs: NOW, secret: "attacker" }),
    });
    await expect(
      mintWindowsAppCheckTokenCore({
        claim,
        verifiers: devVerifiers(),
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/did not verify/i);
    expect(createToken.calls).toHaveLength(0);
  });

  it("rejects a replayed claim (same nonce twice) — single-use", async () => {
    const createToken = stubMinter();
    const verifiers = devVerifiers(); // one shared replay store across both attempts
    const claim = validClaim({ nonce: "nonce-replay-me-0000001" });
    await expect(
      mintWindowsAppCheckTokenCore({ claim, verifiers, allowedAppIDs: [APP_ID], createToken, nowMillis: NOW }),
    ).resolves.toMatchObject({ appId: APP_ID });
    // Re-presenting the identical, still-fresh claim is rejected as replay.
    await expect(
      mintWindowsAppCheckTokenCore({ claim, verifiers, allowedAppIDs: [APP_ID], createToken, nowMillis: NOW }),
    ).rejects.toThrow(/already used/i);
    expect(createToken.calls).toHaveLength(1);
  });

  it("rejects a malformed claim (missing fields) and an empty attestation", async () => {
    const createToken = stubMinter();
    await expect(
      mintWindowsAppCheckTokenCore({
        claim: { kind: MOCK_ATTESTATION_KIND, appId: APP_ID },
        verifiers: devVerifiers(),
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/malformed/i);
    await expect(
      mintWindowsAppCheckTokenCore({
        claim: undefined,
        verifiers: devVerifiers(),
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/attestation claim is required/i);
    expect(createToken.calls).toHaveLength(0);
  });

  it("rejects a stale (replayed-old-timestamp) claim", async () => {
    const createToken = stubMinter();
    const stale = validClaim({ nonce: "nonce-stale-000000000000", issuedAtMs: NOW - (MOCK_ATTESTATION_MAX_AGE_MS + 1000) });
    await expect(
      mintWindowsAppCheckTokenCore({
        claim: stale,
        verifiers: devVerifiers(),
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/stale/i);
    expect(createToken.calls).toHaveLength(0);
  });

  it("rejects a claim bound to an unexpected app id", async () => {
    const createToken = stubMinter();
    const other = "1:999999999999:web:evilappid";
    const claim = validClaim({ appId: other, nonce: "nonce-wrong-app-00000000" });
    await expect(
      mintWindowsAppCheckTokenCore({
        claim,
        verifiers: devVerifiers(),
        allowedAppIDs: [APP_ID, other],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/unexpected app id/i);
    expect(createToken.calls).toHaveLength(0);
  });

  it("rejects a verified claim whose app id is NOT on the config allowlist (config-allowlist enforcement)", async () => {
    // Verifier is bound to `other`, so verification passes — but `other` is not
    // allowlisted, so the mint path refuses. Proves config.ts allowlist enforcement.
    const createToken = stubMinter();
    const other = "1:888888888888:web:nonallowlisted";
    const verifiers = buildWindowsAttestationVerifiers({
      allowMock: true,
      expectedAppId: other,
      replayStore: new Set(),
    });
    const claim = validClaim({ appId: other, nonce: "nonce-not-allowlisted-01" });
    await expect(
      mintWindowsAppCheckTokenCore({
        claim,
        verifiers,
        allowedAppIDs: [APP_ID], // does NOT include `other`
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/not allowlisted/i);
    expect(createToken.calls).toHaveLength(0);
  });
});

describe("VAL-P0-AC-011 attestation-gated production fence", () => {
  it("registers NO mock verifier under production config, so a valid mock claim cannot mint", async () => {
    const createToken = stubMinter();
    const prodVerifiers = buildWindowsAttestationVerifiers({
      allowMock: false, // production config
      expectedAppId: APP_ID,
      replayStore: new Set(),
    });
    expect(prodVerifiers.size).toBe(0);
    expect(prodVerifiers.has(MOCK_ATTESTATION_KIND)).toBe(false);

    await expect(
      mintWindowsAppCheckTokenCore({
        claim: validClaim({ nonce: "nonce-prod-fence-000001" }),
        verifiers: prodVerifiers,
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/No registered App Check attestation verifier/i);
    // Blocked by an ABSENT verifier, not a disabled endpoint — nothing minted.
    expect(createToken.calls).toHaveLength(0);
  });

  it("keeps the mint PATH available in production for a future (AC-013) real verifier", async () => {
    // Simulate AC-013 registering a real verifier into the SAME registry/mint
    // path under production config (allowMock=false). No prod-only guard removed.
    const createToken = stubMinter();
    const realVerifier: WindowsAttestationVerifier = {
      kind: "tpm",
      verify: () => ({ ok: true, appId: APP_ID }),
    };
    const prodVerifiers = buildWindowsAttestationVerifiers({
      allowMock: false,
      expectedAppId: APP_ID,
      replayStore: new Set(),
    });
    prodVerifiers.set(realVerifier.kind, realVerifier);

    const result = await mintWindowsAppCheckTokenCore({
      claim: { kind: "tpm", appId: APP_ID, nonce: "nonce-tpm-0000000000001", issuedAtMs: NOW, mac: "n/a" },
      verifiers: prodVerifiers,
      allowedAppIDs: [APP_ID],
      createToken,
      nowMillis: NOW,
    });
    expect(result.appId).toBe(APP_ID);
    expect(createToken.calls).toEqual([{ appId: APP_ID, ttlMillis: DEFAULT_MINT_TTL_MS }]);
  });
});

describe("VAL-P0-AC-013 production TPM verifier and challenge binding", () => {
  const realAppId = "1:123456789012:web:abcdef0123456789";
  const tpmClaim: WindowsAttestationClaim = {
    kind: TPM_ATTESTATION_KIND,
    appId: realAppId,
    nonce: "server-nonce-0123456789abcdef",
    issuedAtMs: NOW,
    mac: Buffer.alloc(64, 7).toString("base64"),
    challengeId: "challenge-0123456789abcdef",
    subjectPublicKey: Buffer.alloc(72, 9).toString("base64"),
  };

  it("registers TPM only for HTTPS, a strong service credential, and a non-placeholder app id", () => {
    expect(
      buildWindowsAttestationVerifiers({
        allowMock: false,
        expectedAppId: APP_ID,
        tpmVerifierURL: "https://attestation.example.test/verify",
        tpmVerifierToken: "a".repeat(32),
      }).has(TPM_ATTESTATION_KIND),
    ).toBe(false);
    expect(
      buildWindowsAttestationVerifiers({
        allowMock: false,
        expectedAppId: realAppId,
        tpmVerifierURL: "http://attestation.example.test/verify",
        tpmVerifierToken: "a".repeat(32),
      }).has(TPM_ATTESTATION_KIND),
    ).toBe(false);
    expect(
      buildWindowsAttestationVerifiers({
        allowMock: false,
        expectedAppId: realAppId,
        tpmVerifierURL: "https://attestation.example.test/verify",
        tpmVerifierToken: "short",
      }).has(TPM_ATTESTATION_KIND),
    ).toBe(false);
  });

  it("mints only after the Windows verifier binds uid/app/challenge/nonce and the challenge is consumed", async () => {
    const fetcher = async (_provider: string, _operation: string, _url: string | URL, init?: RequestInit) => {
      expect(init?.redirect).toBe("error");
      const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      expect(body).toMatchObject({
        uid: "user-1",
        appId: realAppId,
        challengeId: tpmClaim.challengeId,
        nonce: tpmClaim.nonce,
      });
      return new Response(
        JSON.stringify({
          valid: true,
          uid: "user-1",
          appId: realAppId,
          challengeId: tpmClaim.challengeId,
          nonce: tpmClaim.nonce,
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    };
    let consumeCalls = 0;
    const challengeStore: WindowsAttestationChallengeStore = {
      issue: async () => {
        throw new Error("not used");
      },
      consume: async (uid, appId, challengeId, nonce) => {
        consumeCalls += 1;
        expect({ uid, appId, challengeId, nonce }).toEqual({
          uid: "user-1",
          appId: realAppId,
          challengeId: tpmClaim.challengeId,
          nonce: tpmClaim.nonce,
        });
        return "ok";
      },
    };
    const verifiers = buildWindowsAttestationVerifiers({
      allowMock: false,
      expectedAppId: realAppId,
      tpmVerifierURL: "https://attestation.example.test/verify",
      tpmVerifierToken: "a".repeat(32),
      tpmVerifierFetch: fetcher,
    });
    const result = await mintWindowsAppCheckTokenCore({
      claim: tpmClaim,
      verifiers,
      allowedAppIDs: [realAppId],
      createToken: stubMinter(),
      nowMillis: NOW,
      uid: "user-1",
      challengeStore,
    });
    expect(result.appId).toBe(realAppId);
    expect(consumeCalls).toBe(1);
  });

  it("rejects oversized TPM fields before calling the verifier service", async () => {
    let fetchCalls = 0;
    const verifiers = buildWindowsAttestationVerifiers({
      allowMock: false,
      expectedAppId: realAppId,
      tpmVerifierURL: "https://attestation.example.test/verify",
      tpmVerifierToken: "d".repeat(32),
      tpmVerifierFetch: async () => {
        fetchCalls += 1;
        throw new Error("oversized claims must not reach the network");
      },
    });
    const oversizedClaims: WindowsAttestationClaim[] = [
      { ...tpmClaim, mac: "A".repeat(MAX_TPM_PLATFORM_CLAIM_BASE64_LENGTH + 1) },
      { ...tpmClaim, subjectPublicKey: "A".repeat(MAX_TPM_SUBJECT_PUBLIC_KEY_BASE64_LENGTH + 1) },
      { ...tpmClaim, challengeId: "c".repeat(MAX_TPM_CHALLENGE_ID_LENGTH + 1) },
    ];

    for (const claim of oversizedClaims) {
      await expect(
        mintWindowsAppCheckTokenCore({
          claim,
          verifiers,
          allowedAppIDs: [realAppId],
          createToken: stubMinter(),
          nowMillis: NOW,
          uid: "user-1",
          challengeStore: {
            issue: async () => {
              throw new Error("not used");
            },
            consume: async () => "ok",
          },
        }),
      ).rejects.toThrow(/malformed/i);
    }
    expect(fetchCalls).toBe(0);
  });

  it("fails closed when verifier service binding differs or the challenge was replayed", async () => {
    const bindingMismatch = async () =>
      new Response(
        JSON.stringify({
          valid: true,
          uid: "user-1",
          appId: realAppId,
          challengeId: tpmClaim.challengeId,
          nonce: "different-nonce-0123456789",
        }),
        { status: 200 },
      );
    const verifiers = buildWindowsAttestationVerifiers({
      allowMock: false,
      expectedAppId: realAppId,
      tpmVerifierURL: "https://attestation.example.test/verify",
      tpmVerifierToken: "b".repeat(32),
      tpmVerifierFetch: bindingMismatch,
    });
    await expect(
      mintWindowsAppCheckTokenCore({
        claim: tpmClaim,
        verifiers,
        allowedAppIDs: [realAppId],
        createToken: stubMinter(),
        nowMillis: NOW,
        uid: "user-1",
        challengeStore: {
          issue: async () => {
            throw new Error("not used");
          },
          consume: async () => "ok",
        },
      }),
    ).rejects.toThrow(/did not verify/i);

    const validFetch = async () =>
      new Response(
        JSON.stringify({
          valid: true,
          uid: "user-1",
          appId: realAppId,
          challengeId: tpmClaim.challengeId,
          nonce: tpmClaim.nonce,
        }),
        { status: 200 },
      );
    const replayVerifiers = buildWindowsAttestationVerifiers({
      allowMock: false,
      expectedAppId: realAppId,
      tpmVerifierURL: "https://attestation.example.test/verify",
      tpmVerifierToken: "c".repeat(32),
      tpmVerifierFetch: validFetch,
    });
    await expect(
      mintWindowsAppCheckTokenCore({
        claim: tpmClaim,
        verifiers: replayVerifiers,
        allowedAppIDs: [realAppId],
        createToken: stubMinter(),
        nowMillis: NOW,
        uid: "user-1",
        challengeStore: {
          issue: async () => {
            throw new Error("not used");
          },
          consume: async () => "replayed",
        },
      }),
    ).rejects.toThrow(/already used/i);
  });

  it("issues challenges only for the exact configured and allowlisted app id", async () => {
    const store: WindowsAttestationChallengeStore = {
      issue: async (uid, appId, nowMillis) => ({
        challengeId: `${uid}-challenge-0123456789`,
        nonce: `${appId}-nonce-0123456789`,
        expiresAtMs: nowMillis + 120_000,
      }),
      consume: async () => "ok",
    };
    await expect(
      issueWindowsAppCheckChallengeCore({
        uid: "user-1",
        appId: realAppId,
        expectedAppId: realAppId,
        allowedAppIDs: [realAppId],
        store,
        nowMillis: NOW,
      }),
    ).resolves.toMatchObject({ expiresAtMs: NOW + 120_000 });
    await expect(
      issueWindowsAppCheckChallengeCore({
        uid: "user-1",
        appId: "1:999:web:evil",
        expectedAppId: realAppId,
        allowedAppIDs: [realAppId],
        store,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/not allowed/i);
  });
});

describe("VAL-P0-AC-011B index.ts registration-presence (wiring)", () => {
  it("re-exports mintWindowsAppCheckToken from ./callables/windowsAppCheck.js", () => {
    const indexSource = readFileSync(resolve(__dirname, "../index.ts"), "utf8");
    expect(indexSource).toMatch(/issueWindowsAppCheckChallenge, mintWindowsAppCheckToken/);
  });

  it("exposes the callable object from the module", async () => {
    const mod = await import("../callables/windowsAppCheck.js");
    expect(mod.mintWindowsAppCheckToken).toBeDefined();
  });
});
