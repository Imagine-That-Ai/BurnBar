/**
 * @fileoverview Runtime environment configuration for OpenBurnBar functions.
 *
 * Reads from `firebase functions:config:set` values and process env, providing
 * typed defaults and validation on cold start.
 *
 * App Store Server JWS verification reads its credentials lazily from
 * `defineSecret(...)` parameters declared in `appstore/config.ts`; those
 * are not surfaced through this module so a hot path that does not need
 * them never causes a Secret Manager read.
 */

import type { AppStoreEnvironment, EnvConfig } from "./types.js";

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
    hostedQuotaRunnerURL:
      process.env.HOSTED_QUOTA_RUNNER_URL ||
      cfg.openburnbar?.hosted_quota_runner_url ||
      "",
    hostedQuotaRunnerToken:
      process.env.HOSTED_QUOTA_RUNNER_TOKEN ||
      cfg.openburnbar?.hosted_quota_runner_token ||
      "",
    hostedQuotaProductID:
      process.env.HOSTED_QUOTA_PRODUCT_ID ||
      cfg.openburnbar?.hosted_quota_product_id ||
      "com.burnbar.hostedQuotaSync.monthly",

    appStore: {
      bundleId:
        process.env.APP_STORE_BUNDLE_ID ||
        cfg.openburnbar?.app_store_bundle_id ||
        "com.burnbar.app",
      appAppleId: (() => {
        const raw =
          process.env.APP_STORE_APPLE_APP_ID ??
          cfg.openburnbar?.app_store_apple_app_id;
        if (raw == null || raw === "") return undefined;
        const n = Number(raw);
        return Number.isFinite(n) && n > 0 ? n : undefined;
      })(),
      environment: ((): AppStoreEnvironment => {
        const raw = String(
          process.env.APP_STORE_ENV ??
            cfg.openburnbar?.app_store_env ??
            "Sandbox"
        );
        if (
          raw === "Production" ||
          raw === "Sandbox" ||
          raw === "Xcode" ||
          raw === "LocalTesting"
        ) {
          return raw;
        }
        return "Sandbox";
      })(),
      enableOnlineChecks: toBool(
        process.env.APP_STORE_ENABLE_ONLINE_CHECKS ??
          cfg.openburnbar?.app_store_enable_online_checks,
        true
      ),
      webhookAllowedClockSkewMs: toNum(
        process.env.APP_STORE_CLOCK_SKEW_MS ??
          cfg.openburnbar?.app_store_clock_skew_ms,
        5_000
      ),
      autoFallbackEnvironment: toBool(
        process.env.APP_STORE_AUTO_FALLBACK_ENV ??
          cfg.openburnbar?.app_store_auto_fallback_env,
        true
      ),
      asc: {
        keyId: process.env.APP_STORE_ASC_KEY_ID || cfg.openburnbar?.app_store_asc_key_id || "",
        issuerId:
          process.env.APP_STORE_ASC_ISSUER_ID ||
          cfg.openburnbar?.app_store_asc_issuer_id ||
          "",
        privateKeyP8:
          process.env.APP_STORE_ASC_KEY_P8 ||
          cfg.openburnbar?.app_store_asc_key_p8 ||
          "",
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
