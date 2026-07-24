import { describe, expect, it } from "vitest";

import {
  __testing__,
  type AppCheckTokenMinter,
  type LinuxAttestationClaim,
  type LinuxAttestationVerifier,
} from "../callables/linuxAppCheck.js";
import { PLACEHOLDER_LINUX_APP_CHECK_APP_ID } from "../config.js";

const {
  buildLinuxAttestationVerifiers,
  mintLinuxAppCheckTokenCore,
  signMockAttestation,
  MOCK_ATTESTATION_KIND,
  MOCK_ATTESTATION_MAX_AGE_MS,
  DEFAULT_MINT_TTL_MS,
} = __testing__;

const NOW = 1_900_000_000_000;
const APP_ID = PLACEHOLDER_LINUX_APP_CHECK_APP_ID;

function validClaim(overrides: Partial<LinuxAttestationClaim> = {}): LinuxAttestationClaim {
  const appId = overrides.appId ?? APP_ID;
  const nonce = overrides.nonce ?? "linux-nonce-0123456789abcdef";
  const issuedAtMs = overrides.issuedAtMs ?? NOW;
  const base: LinuxAttestationClaim = {
    kind: MOCK_ATTESTATION_KIND,
    appId,
    nonce,
    issuedAtMs,
    mac: signMockAttestation({ appId, nonce, issuedAtMs }),
  };
  return { ...base, ...overrides };
}

function stubMinter(): AppCheckTokenMinter & { calls: Array<{ appId: string; ttlMillis?: number }> } {
  const calls: Array<{ appId: string; ttlMillis?: number }> = [];
  const fn: AppCheckTokenMinter = async (appId, options) => {
    calls.push({ appId, ttlMillis: options?.ttlMillis });
    return { token: `linux-appcheck-token-for-${appId}`, ttlMillis: options?.ttlMillis ?? DEFAULT_MINT_TTL_MS };
  };
  return Object.assign(fn, { calls });
}

function devVerifiers(replayStore = new Set<string>()): Map<string, LinuxAttestationVerifier> {
  return buildLinuxAttestationVerifiers({ allowMock: true, expectedAppId: APP_ID, replayStore });
}

describe("Linux lower-trust App Check mint", () => {
  it("mints a lower-trust Linux App Check token for a valid non-production fixture claim", async () => {
    const createToken = stubMinter();
    const result = await mintLinuxAppCheckTokenCore({
      claim: validClaim(),
      verifiers: devVerifiers(),
      allowedAppIDs: [APP_ID],
      createToken,
      nowMillis: NOW,
    });

    expect(result.appId).toBe(APP_ID);
    expect(result.appCheckToken).toBe(`linux-appcheck-token-for-${APP_ID}`);
    expect(result.ttlMillis).toBe(DEFAULT_MINT_TTL_MS);
    expect(createToken.calls).toEqual([{ appId: APP_ID, ttlMillis: DEFAULT_MINT_TTL_MS }]);
  });

  it("rejects forged, stale, wrong-app, non-allowlisted, and replayed claims without minting", async () => {
    const createToken = stubMinter();
    await expect(
      mintLinuxAppCheckTokenCore({
        claim: validClaim({ mac: "deadbeef".repeat(8) }),
        verifiers: devVerifiers(),
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/did not verify/i);
    await expect(
      mintLinuxAppCheckTokenCore({
        claim: validClaim({ nonce: "linux-stale-0000000000", issuedAtMs: NOW - MOCK_ATTESTATION_MAX_AGE_MS - 1 }),
        verifiers: devVerifiers(),
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/stale/i);
    await expect(
      mintLinuxAppCheckTokenCore({
        claim: validClaim({ appId: "1:123:linux:evil", nonce: "linux-wrong-app-000000" }),
        verifiers: devVerifiers(),
        allowedAppIDs: [APP_ID, "1:123:linux:evil"],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/unexpected Linux app id/i);

    const otherApp = "1:123:linux:notallowlisted";
    await expect(
      mintLinuxAppCheckTokenCore({
        claim: validClaim({ appId: otherApp, nonce: "linux-not-allowlisted-000" }),
        verifiers: buildLinuxAttestationVerifiers({ allowMock: true, expectedAppId: otherApp }),
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toMatchObject({
      code: "permission-denied",
      details: { reason: "linux_app_not_allowlisted" },
    });

    const replayStore = new Set<string>();
    const claim = validClaim({ nonce: "linux-replay-0000000000" });
    await expect(
      mintLinuxAppCheckTokenCore({
        claim,
        verifiers: devVerifiers(replayStore),
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).resolves.toMatchObject({ appId: APP_ID });
    await expect(
      mintLinuxAppCheckTokenCore({
        claim,
        verifiers: devVerifiers(replayStore),
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/already used/i);
    expect(createToken.calls).toHaveLength(1);
  });

  it("registers no mock verifier in production, so fixture claims cannot mint", async () => {
    const createToken = stubMinter();
    const prodVerifiers = buildLinuxAttestationVerifiers({ allowMock: false, expectedAppId: APP_ID });
    expect(prodVerifiers.size).toBe(0);
    await expect(
      mintLinuxAppCheckTokenCore({
        claim: validClaim({ nonce: "linux-prod-fence-000000" }),
        verifiers: prodVerifiers,
        allowedAppIDs: [APP_ID],
        createToken,
        nowMillis: NOW,
      }),
    ).rejects.toThrow(/No registered Linux App Check attestation verifier/i);
    expect(createToken.calls).toHaveLength(0);
  });
});
