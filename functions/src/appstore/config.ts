/**
 * @fileoverview App Store JWS / Server API secret + parameter wiring.
 *
 * The Apple verification pipeline needs three sensitive bits of data:
 *
 *   1. The App Store Connect (ASC) API key ID  — opaque, ~10 chars.
 *   2. The ASC issuer ID                       — UUID.
 *   3. The ASC private key (`.p8`) PEM body    — sensitive, ES256 EC key.
 *
 * (1) and (2) are not strictly secret, but we surface them through the
 * same `defineSecret(...)` parameter pipeline so that "where does this
 * value come from" is one consistent answer everywhere in the codebase.
 *
 * Cold-start cost: each `secret.value()` call is a no-op once Firebase
 * has materialized the param into the function instance's environment.
 *
 * Bundle ID and environment come through `getConfig()` (process env →
 * functions:config) because they are not credentials and operators want
 * to flip them per-environment without touching Secret Manager.
 */

import { defineSecret, defineString } from "firebase-functions/params";
import type { SecretParam, StringParam } from "firebase-functions/params";

/**
 * App Store Connect API key id. Visible in the App Store Connect "Keys"
 * page; not technically secret, but treated as sensitive for parity with
 * the ASC private key.
 */
export const APP_STORE_ASC_KEY_ID: SecretParam = defineSecret(
  "APP_STORE_ASC_KEY_ID"
);

/**
 * App Store Connect API issuer id (UUID). Sourced from the same
 * App Store Connect "Keys" page.
 */
export const APP_STORE_ASC_ISSUER_ID: SecretParam = defineSecret(
  "APP_STORE_ASC_ISSUER_ID"
);

/**
 * PEM-encoded ASC API private key (the `.p8` file body, including
 * `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines).
 * Used to sign ES256 JWTs for App Store Server API calls.
 *
 * MUST be created with `firebase functions:secrets:set APP_STORE_ASC_KEY_P8`.
 */
export const APP_STORE_ASC_KEY_P8: SecretParam = defineSecret(
  "APP_STORE_ASC_KEY_P8"
);

/**
 * Numeric `appAppleId` for production. Optional in sandbox; required for
 * production verification of App Store Server Notifications V2.
 *
 * Surfaced as a non-secret string param so it is visible in the deployed
 * function configuration without revealing key material.
 */
export const APP_STORE_APPLE_APP_ID: StringParam = defineString(
  "APP_STORE_APPLE_APP_ID",
  { default: "" }
);

/** Bundle identifier override; defaults to `com.burnbar.app`. */
export const APP_STORE_BUNDLE_ID: StringParam = defineString(
  "APP_STORE_BUNDLE_ID",
  { default: "com.burnbar.app" }
);

/** Default environment override (`"Production"`, `"Sandbox"`, …). */
export const APP_STORE_ENV: StringParam = defineString("APP_STORE_ENV", {
  default: "Sandbox",
});

/**
 * The set of secrets each callable / webhook / scheduled job must declare
 * so Firebase Functions provisions Secret Manager access at deploy time.
 * Centralised so we never forget one.
 */
export const APP_STORE_SECRETS: SecretParam[] = [
  APP_STORE_ASC_KEY_ID,
  APP_STORE_ASC_ISSUER_ID,
  APP_STORE_ASC_KEY_P8,
];

/**
 * Resolve the active ASC credentials at runtime. Throws with a precise
 * "missing credential" error if any are absent — operators should see
 * this on the first failed call after a misconfigured deploy, not as a
 * silent verification regression.
 */
export function readAscCredentials(): {
  keyId: string;
  issuerId: string;
  privateKeyP8: string;
} {
  const keyId = APP_STORE_ASC_KEY_ID.value().trim();
  const issuerId = APP_STORE_ASC_ISSUER_ID.value().trim();
  const privateKeyP8 = APP_STORE_ASC_KEY_P8.value();
  if (!keyId) throw new Error("APP_STORE_ASC_KEY_ID is not set");
  if (!issuerId) throw new Error("APP_STORE_ASC_ISSUER_ID is not set");
  if (!privateKeyP8 || !privateKeyP8.includes("PRIVATE KEY")) {
    throw new Error(
      "APP_STORE_ASC_KEY_P8 is missing or does not look like a PEM body"
    );
  }
  return { keyId, issuerId, privateKeyP8 };
}
