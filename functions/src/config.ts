/**
 * @fileoverview Runtime environment configuration for OpenBurnBar functions.
 *
 * Reads from `firebase functions:config:set` values and process env, providing
 * typed defaults and validation on cold start.
 */

import type { EnvConfig } from "./types.js";

/** Cached config object computed once per function instance. */
let cached: EnvConfig | undefined;

/**
 * Build the runtime configuration from Firebase Functions config and
 * environment variables.  Falls back to safe defaults for local emulation.
 */
function buildConfig(): EnvConfig {
  // firebase-functions config is injected at runtime via functions.config().
  // For local dev use FIREBASE_CONFIG or plain env vars.
  const cfg =
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (globalThis as any).functions?.config?.() || {};

  const projectId =
    process.env.GCLOUD_PROJECT ||
    process.env.GOOGLE_CLOUD_PROJECT ||
    cfg.project?.id ||
    "demo-project";

  const kmsKeyName =
    process.env.KMS_KEY_NAME ||
    cfg.openburnbar?.kms_key_name ||
    "";

  const toBool = (v: unknown, def: boolean): boolean => {
    if (v === undefined || v === null) return def;
    if (typeof v === "boolean") return v;
    return String(v).toLowerCase() === "true";
  };

  const toNum = (v: unknown, def: number): number => {
    if (v === undefined || v === null) return def;
    const n = Number(v);
    return Number.isFinite(n) ? n : def;
  };

  return {
    projectId,
    kmsKeyName,
    enforceAppCheck: toBool(
      process.env.ENFORCE_APP_CHECK ?? cfg.openburnbar?.enforce_app_check,
      true
    ),
    maxCredentialLength: toNum(
      process.env.MAX_CREDENTIAL_LENGTH ?? cfg.openburnbar?.max_credential_length,
      8192
    ),
    refreshRateLimitSeconds: toNum(
      process.env.REFRESH_RATE_LIMIT_SECONDS ??
        cfg.openburnbar?.refresh_rate_limit_seconds,
      60
    ),
    rollupBatchSize: toNum(
      process.env.ROLLUP_BATCH_SIZE ?? cfg.openburnbar?.rollup_batch_size,
      50
    ),
    quotaRefreshBatchSize: toNum(
      process.env.QUOTA_REFRESH_BATCH_SIZE ??
        cfg.openburnbar?.quota_refresh_batch_size,
      20
    ),
    hostedQuotaProductID:
      process.env.HOSTED_QUOTA_PRODUCT_ID ??
      cfg.openburnbar?.hosted_quota_product_id ??
      "hosted_quota_sync",
    appStore: {
      bundleId:
        process.env.APP_STORE_BUNDLE_ID ??
        cfg.appstore?.bundle_id ??
        "com.burnbar.app",
      appAppleId: toNum(
        process.env.APP_STORE_APPLE_APP_ID ?? cfg.appstore?.apple_app_id,
        0
      ),
      environment:
        (process.env.APP_STORE_ENV ??
          cfg.appstore?.environment ??
          "Sandbox") as EnvConfig["appStore"]["environment"],
      enableOnlineChecks: toBool(
        process.env.APP_STORE_ENABLE_ONLINE_CHECKS ??
          cfg.appstore?.enable_online_checks,
        true
      ),
      autoFallbackEnvironment:
        (process.env.APP_STORE_AUTO_FALLBACK_ENV ??
          cfg.appstore?.auto_fallback_environment) as
          | EnvConfig["appStore"]["autoFallbackEnvironment"]
          | undefined,
      asc: {
        issuerId: process.env.APP_STORE_ASC_ISSUER_ID ?? "",
        keyId: process.env.APP_STORE_ASC_KEY_ID ?? "",
        privateKeyP8: process.env.APP_STORE_ASC_KEY_P8 ?? "",
      },
    },
  };
}

/**
 * Return the singleton runtime configuration.
 *
 * @returns Validated EnvConfig object.
 */
export function getConfig(): EnvConfig {
  if (!cached) {
    cached = buildConfig();
  }
  return cached;
}
