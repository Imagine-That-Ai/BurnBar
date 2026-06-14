import assert from "node:assert/strict";
import test from "node:test";
import { authenticateRequest, type IdTokenVerifier, type RelayRequest } from "./auth.js";
import type { EntitlementVerifier } from "./entitlements.js";

function request(headers: Record<string, string>): RelayRequest {
  return { headers };
}

const activeEntitlement: EntitlementVerifier = {
  assertActive: async () => ({ productID: "com.openburnbar.pro.monthly", expiresAtMs: 9_999_999_999_999, source: "firestore" }),
};

const validHeaders = {
  authorization: "Bearer valid-token",
  "x-openburnbar-relay-role": "client",
};

test("threads verifyRevokedIdTokens through to the Firebase verifier", async () => {
  let observedCheckRevoked: boolean | undefined;
  const idTokenVerifier: IdTokenVerifier = async (_token, checkRevoked) => {
    observedCheckRevoked = checkRevoked;
    return { uid: "user-123" };
  };

  const result = await authenticateRequest(request(validHeaders), {
    enforceAppCheck: false,
    verifyRevokedIdTokens: true,
    entitlementVerifier: activeEntitlement,
    allowedAppIDs: [],
    idTokenVerifier,
  });

  assert.equal(observedCheckRevoked, true);
  assert.equal(result.uid, "user-123");
  assert.equal(result.role, "client");
});

test("rejects a revoked Firebase ID token", async () => {
  const revokedVerifier: IdTokenVerifier = async () => {
    // Object.assign yields `Error & { code: string }` with no cast.
    throw Object.assign(new Error("Firebase ID token has been revoked."), {
      code: "auth/id-token-revoked",
    });
  };

  await assert.rejects(
    authenticateRequest(request(validHeaders), {
      enforceAppCheck: false,
      verifyRevokedIdTokens: true,
      entitlementVerifier: activeEntitlement,
      allowedAppIDs: [],
      idTokenVerifier: revokedVerifier,
    }),
    /revoked/i
  );
});

test("rejects a request with no Firebase token before verification runs", async () => {
  let verifierCalled = false;
  const idTokenVerifier: IdTokenVerifier = async () => {
    verifierCalled = true;
    return { uid: "should-not-happen" };
  };

  await assert.rejects(
    authenticateRequest(request({ "x-openburnbar-relay-role": "client" }), {
      enforceAppCheck: false,
      verifyRevokedIdTokens: true,
      entitlementVerifier: activeEntitlement,
      allowedAppIDs: [],
      idTokenVerifier,
    }),
    /Missing Firebase ID token/
  );
  assert.equal(verifierCalled, false);
});
