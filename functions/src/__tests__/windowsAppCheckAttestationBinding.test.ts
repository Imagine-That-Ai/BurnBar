/**
 * VAL-P0-AC-011B — appCheckAttestation.ts `assertAppAttestBoundClaims`
 * appId-equality enforcement (the :126 equality check), extended for the
 * placeholder Windows app id.
 *
 * Accept: a bound claim whose appId matches the live App Check app id (the
 * Windows placeholder) passes.
 * Reject: a bound claim whose appId does NOT match the live app id is rejected.
 *
 * The equality gate is generic, so the Windows placeholder binds exactly like
 * Apple — WITHOUT relaxing the gate for all platforms (a mismatched app id is
 * still rejected). The last test proves the existing Apple binding still works.
 */

import { describe, expect, it, vi } from "vitest";
import type { CallableRequest } from "firebase-functions/v2/https";

// The equality gate needs neither Firestore nor a live admin app; stub them so
// importing the module under test does not initialize Firebase.
vi.mock("../adminRuntime.js", () => ({ db: {}, auth: {} }));

// auth guards are covered elsewhere; here the assertion under test is the
// attestation appId-equality, so make the auth/App-Check guards no-ops.
vi.mock("../auth.js", () => ({
  assertAuth: vi.fn(),
  assertAppCheck: vi.fn(),
  assertOwnership: vi.fn(),
  enforceAuthAndAppCheck: vi.fn(),
}));

vi.mock("../config.js", () => ({ getConfig: () => ({ enforceAppCheck: true }) }));

import {
  APP_CHECK_ATTESTATION_CLAIM_KEY,
  enforceHighRiskComputerUseCallable,
} from "../appCheckAttestation.js";

const WINDOWS_PLACEHOLDER = "1:000000000000:windows:0000000000000000placeholder";
const APPLE_APP_ID = "1:123:ios:abc";

/** Build a request with a live App Check app id and a bound attestation claim. */
function boundRequest(liveAppId: string, claimAppId: string): CallableRequest {
  const request = {
    app: { appId: liveAppId },
    auth: {
      uid: "userA",
      token: {
        [APP_CHECK_ATTESTATION_CLAIM_KEY]: { v: 1, appId: claimAppId, boundAtMillis: Date.now() },
      },
    },
    data: {},
    rawRequest: { headers: {} },
    acceptsStreaming: false,
  };
  // @ts-expect-error reason: partial CallableRequest stub for attestation tests
  return request;
}

describe("VAL-P0-AC-011B appId-equality binding for the Windows placeholder", () => {
  it("ACCEPTS a Windows-placeholder claim bound to the live Windows-placeholder app id", () => {
    expect(() =>
      enforceHighRiskComputerUseCallable(boundRequest(WINDOWS_PLACEHOLDER, WINDOWS_PLACEHOLDER), "userA"),
    ).not.toThrow();
  });

  it("REJECTS a claim whose app id does not match the live Windows-placeholder app id", () => {
    expect(() =>
      enforceHighRiskComputerUseCallable(boundRequest(WINDOWS_PLACEHOLDER, "1:999999999999:web:evil"), "userA"),
    ).toThrow(/does not match this app instance/i);
  });

  it("REJECTS a Windows-placeholder claim presented against a different live app id (no all-platform relaxation)", () => {
    expect(() =>
      enforceHighRiskComputerUseCallable(boundRequest("1:777777777777:web:other", WINDOWS_PLACEHOLDER), "userA"),
    ).toThrow(/does not match this app instance/i);
  });

  it("leaves the existing Apple binding intact (equality gate unchanged for Apple clients)", () => {
    expect(() =>
      enforceHighRiskComputerUseCallable(boundRequest(APPLE_APP_ID, APPLE_APP_ID), "userA"),
    ).not.toThrow();
    // A mismatched Apple binding is still rejected — the gate was not weakened.
    expect(() =>
      enforceHighRiskComputerUseCallable(boundRequest(APPLE_APP_ID, "debug-app-id"), "userA"),
    ).toThrow(/does not match this app instance/i);
  });
});
