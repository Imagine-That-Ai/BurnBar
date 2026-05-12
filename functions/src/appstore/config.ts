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
 * Bundle ID, product ID, and environment come through both Firebase
 * params and `getConfig()` (process env → functions:config). Params
 * are used by deployed Functions v2; process env/config remain the
 * local-emulator and backwards-compatible operator path.
 */

import { defineSecret, defineString } from "firebase-functions/params";

import { getConfig } from "../config.js";
import type { AppStoreConfig } from "../types.js";

type SecretParam = ReturnType<typeof defineSecret>;
type StringParam = ReturnType<typeof defineString>;

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

/** Bundle identifier override; defaults to the real App Store Connect app. */
export const APP_STORE_BUNDLE_ID: StringParam = defineString(
  "APP_STORE_BUNDLE_ID",
  { default: "com.openburnbar.app" }
);

/** Default environment override (`"Production"`, `"Sandbox"`, …). */
export const APP_STORE_ENV: StringParam = defineString("APP_STORE_ENV", {
  default: "Sandbox",
});

/** StoreKit product id for hosted quota sync. */
export const HOSTED_QUOTA_PRODUCT_ID: StringParam = defineString(
  "HOSTED_QUOTA_PRODUCT_ID",
  { default: "com.openburnbar.hostedQuotaSync.cloud.monthly" }
);

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
 *
 * MUST be called from inside a handler that declared the secrets via
 * `secrets: APP_STORE_SECRETS`. Firebase only injects the values when
 * the handler runs; at module-load time the `.value()` reads return the
 * empty string and we'd silently cache that forever.
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

/**
 * Build an `AppStoreConfig` with the ASC credentials freshly read from
 * Secret Manager. This is the canonical accessor for handlers — callable
 * functions, the S2S webhook, and the daily reconciliation job all use
 * this so the verifier and ASC client always see a populated `asc` block.
 *
 * Cheap: the underlying secret reads are memoized by Firebase's param
 * runtime; only the spread is per-call. Returning a fresh object each
 * call is intentional so a future config rotation does not get stuck on
 * stale singleton state inside the verifier cache.
 */
export function loadAppStoreRuntimeConfig(): AppStoreConfig {
  const base = getConfig().appStore;
  const asc = readAscCredentials();
  const appleAppIdRaw = APP_STORE_APPLE_APP_ID.value().trim();
  const appleAppId = appleAppIdRaw ? Number(appleAppIdRaw) : undefined;
  return {
    ...base,
    bundleId: APP_STORE_BUNDLE_ID.value().trim() || base.bundleId,
    appAppleId:
      appleAppId !== undefined && Number.isFinite(appleAppId)
        ? Math.floor(appleAppId)
        : base.appAppleId,
    environment: normalizeEnvironment(APP_STORE_ENV.value(), base.environment),
    asc,
  };
}

export function hostedQuotaProductID(): string {
  return (
    HOSTED_QUOTA_PRODUCT_ID.value().trim() ||
    getConfig().hostedQuotaProductID ||
    "com.openburnbar.hostedQuotaSync.cloud.monthly"
  );
}

function normalizeEnvironment(
  raw: string | undefined,
  fallback: AppStoreConfig["environment"]
): AppStoreConfig["environment"] {
  switch (raw) {
    case "Production":
    case "Sandbox":
    case "Xcode":
    case "LocalTesting":
      return raw;
    default:
      return fallback;
  }
}
