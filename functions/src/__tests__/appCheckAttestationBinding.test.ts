import { describe, expect, it } from "vitest";

import {
  APP_CHECK_ATTESTATION_CLAIM_KEY,
  APP_CHECK_ATTESTATION_MAX_AGE_MS,
  appCheckAttestationDigestHex,
  isAppCheckAttestationClaimFresh,
  readAppCheckAttestationClaim,
} from "../appCheckAttestation.js";

describe("appCheckAttestation binding", () => {
  it("parses obb_app_check claim from auth token", () => {
    const claim = readAppCheckAttestationClaim({
      [APP_CHECK_ATTESTATION_CLAIM_KEY]: {
        v: 1,
        appId: "1:123:ios:abc",
        boundAtMillis: 1_700_000_000_000,
      },
    });
    expect(claim?.appId).toBe("1:123:ios:abc");
    expect(claim?.boundAtMillis).toBe(1_700_000_000_000);
  });

  it("matches Swift golden digest vector", () => {
    expect(appCheckAttestationDigestHex("1:123:ios:abc", 1_700_000_000_000)).toBe(
      "fd33c159e0a5e24cdbb037c2d0be37e43dfde84c4adcfa711e59f1a039a4c1ce",
    );
  });

  it("rejects stale bindings", () => {
    const claim = {
      v: 1 as const,
      appId: "1:123:ios:abc",
      boundAtMillis: 0,
    };
    const now = APP_CHECK_ATTESTATION_MAX_AGE_MS + 1;
    expect(isAppCheckAttestationClaimFresh(claim, now)).toBe(false);
  });
});