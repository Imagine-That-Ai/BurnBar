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
      "com.openburnbar.hostedQuotaSync.cloud.monthly",
    hostedQuotaRunnerURL:
      process.env.HOSTED_QUOTA_RUNNER_URL ??
      cfg.openburnbar?.hosted_quota_runner_url ??
      "",
    hostedQuotaRunnerToken:
      process.env.HOSTED_QUOTA_RUNNER_TOKEN ??
      cfg.openburnbar?.hosted_quota_runner_token ??
      "",
    hostedQuotaDailyRefreshLimit: toNum(
      process.env.HOSTED_QUOTA_DAILY_REFRESH_LIMIT ??
        cfg.openburnbar?.hosted_quota_daily_refresh_limit,
      30
    ),
    hostedQuotaMonthlyRefreshLimit: toNum(
      process.env.HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT ??
        cfg.openburnbar?.hosted_quota_monthly_refresh_limit,
      300
    ),
    appStore: {
      bundleId:
        process.env.APP_STORE_BUNDLE_ID ??
        cfg.appstore?.bundle_id ??
        "com.openburnbar.app",
      // `appAppleId` MUST be `undefined` in Sandbox (library v1.1.0+
      // forbids passing 0 for non-production). The numeric is required
      // for Production-environment notification verification.
      appAppleId: parseAppleId(
        process.env.APP_STORE_APPLE_APP_ID ?? cfg.appstore?.apple_app_id
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
        toBool(
          process.env.APP_STORE_AUTO_FALLBACK_ENV ??
            cfg.appstore?.auto_fallback_environment,
          true
        ),
      // ASC credentials are populated at runtime by
      // `appstore/config.ts:readAscCredentials()` because secrets are
      // only injected into `process.env` *inside* the handler that
      // declared them via `secrets: APP_STORE_SECRETS`. Reading them at
      // module-load time (which is when `getConfig()` is first called
      // by `enforceAppCheck: getConfig().enforceAppCheck`) would
      // capture empty strings forever.
      //
      // Use `loadAppStoreRuntimeConfig()` from request handlers — it
      // shallow-clones this base config and fills in `asc` from
      // `defineSecret(...).value()` which Firebase guarantees works
      // at invocation time.
      asc: {
        issuerId: "",
        keyId: "",
        privateKeyP8: "",
      },
    },
  };
}

function parseAppleId(raw: unknown): number | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) return undefined;
  return Math.floor(n);
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
