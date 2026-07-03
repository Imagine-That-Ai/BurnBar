import assert from "node:assert/strict";
import test from "node:test";
import { authenticateRequest, type AppCheckVerifier, type IdTokenVerifier, type RelayRequest } from "./auth.js";
import type { EntitlementVerifier } from "./entitlements.js";

/**
 * VAL-P0-AC-011B — Hermes relay `allowedAppIDs` enforcement (auth.ts:58),
 * extended for the placeholder Windows App Check app id (accept + reject).
 *
 * The App Check verifier is injected so the allowlist path runs with App Check
 * enforced but no live Firebase project. Mirrors the `windows` placeholder used
 * by functions/src/config.ts (separate package — kept byte-identical here).
 */
const WINDOWS_PLACEHOLDER_APP_ID = "1:000000000000:windows:0000000000000000placeholder";

function request(headers: Record<string, string>): RelayRequest {
  return { headers };
}

const activeEntitlement: EntitlementVerifier = {
  assertActive: async () => ({
    productID: "com.openburnbar.pro.monthly",
    expiresAtMs: 9_999_999_999_999,
    source: "firestore",
  }),
};

const idTokenVerifier: IdTokenVerifier = async () => ({ uid: "user-123" });

const validHeaders = {
  authorization: "Bearer valid-token",
  "x-openburnbar-relay-role": "client",
  "x-firebase-appcheck": "appcheck-token",
};

function appCheckReturning(appId: string): AppCheckVerifier {
  return async () => ({ appId });
}

test("ACCEPTS the allowlisted Windows placeholder app id with App Check enforced", async () => {
  const result = await authenticateRequest(request(validHeaders), {
    enforceAppCheck: true,
    verifyRevokedIdTokens: true,
    entitlementVerifier: activeEntitlement,
    allowedAppIDs: [WINDOWS_PLACEHOLDER_APP_ID],
    idTokenVerifier,
    appCheckVerifier: appCheckReturning(WINDOWS_PLACEHOLDER_APP_ID),
  });

  assert.equal(result.appID, WINDOWS_PLACEHOLDER_APP_ID);
  assert.equal(result.uid, "user-123");
  assert.equal(result.role, "client");
});

test("REJECTS a non-allowlisted app id (403 app_check_app_denied)", async () => {
  await assert.rejects(
    authenticateRequest(request(validHeaders), {
      enforceAppCheck: true,
      verifyRevokedIdTokens: true,
      entitlementVerifier: activeEntitlement,
      allowedAppIDs: [WINDOWS_PLACEHOLDER_APP_ID],
      idTokenVerifier,
      appCheckVerifier: appCheckReturning("1:999999999999:web:evilappid"),
    }),
    (err: unknown) => {
      const e = err as { statusCode?: number; code?: string };
      assert.equal(e.statusCode, 403);
      assert.equal(e.code, "app_check_app_denied");
      return true;
    },
  );
});

test("rejects a request that is missing the App Check header when enforcement is on", async () => {
  await assert.rejects(
    authenticateRequest(
      request({ authorization: "Bearer valid-token", "x-openburnbar-relay-role": "client" }),
      {
        enforceAppCheck: true,
        verifyRevokedIdTokens: true,
        entitlementVerifier: activeEntitlement,
        allowedAppIDs: [WINDOWS_PLACEHOLDER_APP_ID],
        idTokenVerifier,
        appCheckVerifier: appCheckReturning(WINDOWS_PLACEHOLDER_APP_ID),
      },
    ),
    /Missing Firebase App Check token/,
  );
});

test("an empty allowlist accepts the Windows placeholder (allow-all back-compat)", async () => {
  // allowedAppIDs=[] means the relay does not restrict by app id — the Windows
  // placeholder is accepted, matching existing Apple/Android behavior.
  const result = await authenticateRequest(request(validHeaders), {
    enforceAppCheck: true,
    verifyRevokedIdTokens: true,
    entitlementVerifier: activeEntitlement,
    allowedAppIDs: [],
    idTokenVerifier,
    appCheckVerifier: appCheckReturning(WINDOWS_PLACEHOLDER_APP_ID),
  });
  assert.equal(result.appID, WINDOWS_PLACEHOLDER_APP_ID);
});
