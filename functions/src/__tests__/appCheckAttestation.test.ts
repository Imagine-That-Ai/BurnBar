/**
 * Unit tests for App Check attestation custom-claim helpers (WS4).
 */

import { describe, expect, it } from "vitest";
import {
  APP_CHECK_ATTESTATION_CLAIM_KEY,
  isAppCheckAttestationClaimFresh,
  readAppCheckAttestationClaim,
  readAppIdFromCallableRequest,
} from "../appCheckAttestation.js";

describe("appCheckAttestation", () => {
  it("reads app id from callable App Check metadata", () => {
    expect(readAppIdFromCallableRequest({ app: { appId: "1:123:ios:abc" } } as never)).toBe(
      "1:123:ios:abc",
    );
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
