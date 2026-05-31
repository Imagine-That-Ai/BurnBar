/**
 * @fileoverview Runtime environment configuration for OpenBurnBar functions.
 *
 * Reads from `firebase functions:config:set` values and process env, providing
 * typed defaults and validation on cold start.
 */

import type { EnvConfig } from "./types.js";
import { readFirebaseFunctionsConfig } from "./firebaseRuntime.js";
import { isRecord, stringValue } from "./guards.js";

function configBucket(cfg: Record<string, unknown>, key: string): Record<string, unknown> {
  const value = cfg[key];
  return isRecord(value) ? value : {};
}

function configString(cfg: Record<string, unknown>, key: string): string | undefined {
  return stringValue(cfg[key]);
}

function parseAppStoreEnvironmentValue(raw: unknown): EnvConfig["appStore"]["environment"] {
  switch (raw) {
    case "Production":
    case "Sandbox":
    case "Xcode":
    case "LocalTesting":
      return raw;
    default:
      return "Sandbox";
  }
}

/** Cached config object computed once per function instance. */
let cached: EnvConfig | undefined;

/**
 * Build the runtime configuration from Firebase Functions config and
 * environment variables.  Falls back to safe defaults for local emulation.
 */
function buildConfig(): EnvConfig {
  // firebase-functions config is injected at runtime via functions.config().
  // For local dev use FIREBASE_CONFIG or plain env vars.
  const cfg = readFirebaseFunctionsConfig();
  const project = configBucket(cfg, "project");
  const openburnbar = configBucket(cfg, "openburnbar");
  const stripe = configBucket(cfg, "stripe");
  const googleplay = configBucket(cfg, "googleplay");
  const appstore = configBucket(cfg, "appstore");

  const projectId =
    process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || configString(project, "id") || "demo-project";

  const kmsKeyName = process.env.KMS_KEY_NAME || configString(openburnbar, "kms_key_name") || "";

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
    enforceAppCheck: toBool(process.env.ENFORCE_APP_CHECK ?? configString(openburnbar, "enforce_app_check"), true),
    maxCredentialLength: toNum(
      process.env.MAX_CREDENTIAL_LENGTH ?? configString(openburnbar, "max_credential_length"),
      8192,
    ),
    refreshRateLimitSeconds: toNum(
      process.env.REFRESH_RATE_LIMIT_SECONDS ?? configString(openburnbar, "refresh_rate_limit_seconds"),
      60,
    ),
    rollupBatchSize: toNum(process.env.ROLLUP_BATCH_SIZE ?? configString(openburnbar, "rollup_batch_size"), 50),
    quotaRefreshBatchSize: toNum(
      process.env.QUOTA_REFRESH_BATCH_SIZE ?? configString(openburnbar, "quota_refresh_batch_size"),
      20,
    ),
    hostedQuotaProductID:
      process.env.HOSTED_QUOTA_PRODUCT_ID ??
      configString(openburnbar, "hosted_quota_product_id") ??
      "com.openburnbar.hostedQuotaSync.cloud.monthly",
    burnBarProProductID:
      process.env.BURNBAR_PRO_PRODUCT_ID ??
      configString(openburnbar, "burnbar_pro_product_id") ??
      "com.openburnbar.pro.monthly",
    burnBarProAnnualProductID:
      process.env.BURNBAR_PRO_ANNUAL_PRODUCT_ID ??
      configString(openburnbar, "burnbar_pro_annual_product_id") ??
      "com.openburnbar.pro.annual",
    burnBarProMaxProductID:
      process.env.BURNBAR_PRO_MAX_PRODUCT_ID ??
      configString(openburnbar, "burnbar_pro_max_product_id") ??
      "com.openburnbar.proMax.v2.monthly",
    burnBarProMaxAnnualProductID:
      process.env.BURNBAR_PRO_MAX_ANNUAL_PRODUCT_ID ??
      configString(openburnbar, "burnbar_pro_max_annual_product_id") ??
      "com.openburnbar.proMax.annual",
    agentControl100ActionsProductID:
      process.env.AGENT_CONTROL_100_ACTIONS_PRODUCT_ID ??
      configString(openburnbar, "agent_control_100_actions_product_id") ??
      "com.openburnbar.agentControl.actions100",
    flooRelay50GBProductID:
      process.env.FLOO_RELAY_50GB_PRODUCT_ID ??
      configString(openburnbar, "floo_relay_50gb_product_id") ??
      "com.openburnbar.floo.relay50gb",
    stripeBurnBarProPriceID:
      process.env.STRIPE_BURNBAR_PRO_PRICE_ID ?? configString(stripe, "burnbar_pro_price_id") ?? "",
    stripeBurnBarCloudMonthlyPriceID:
      process.env.STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID ??
      configString(stripe, "burnbar_cloud_monthly_price_id") ??
      process.env.STRIPE_BURNBAR_PRO_PRICE_ID ??
      configString(stripe, "burnbar_pro_price_id") ??
      "",
    stripeBurnBarCloudAnnualPriceID:
      process.env.STRIPE_BURNBAR_CLOUD_ANNUAL_PRICE_ID ?? configString(stripe, "burnbar_cloud_annual_price_id") ?? "",
    stripeBurnBarCloudProMonthlyPriceID:
      process.env.STRIPE_BURNBAR_CLOUD_PRO_MONTHLY_PRICE_ID ??
      configString(stripe, "burnbar_cloud_pro_monthly_price_id") ??
      "",
    stripeBurnBarCloudProAnnualPriceID:
      process.env.STRIPE_BURNBAR_CLOUD_PRO_ANNUAL_PRICE_ID ??
      configString(stripe, "burnbar_cloud_pro_annual_price_id") ??
      "",
    stripeAgentControl100ActionsPriceID:
      process.env.STRIPE_AGENT_CONTROL_100_ACTIONS_PRICE_ID ??
      configString(stripe, "agent_control_100_actions_price_id") ??
      "",
    stripeFlooRelay50GBPriceID:
      process.env.STRIPE_FLOO_RELAY_50GB_PRICE_ID ?? configString(stripe, "floo_relay_50gb_price_id") ?? "",
    stripeSecretKey: process.env.STRIPE_SECRET_KEY ?? configString(stripe, "secret_key") ?? "",
    stripeWebhookSecret: process.env.STRIPE_WEBHOOK_SECRET ?? configString(stripe, "webhook_secret") ?? "",
    googlePlayPackageName:
      process.env.GOOGLE_PLAY_PACKAGE_NAME ?? configString(googleplay, "package_name") ?? "com.openburnbar",
    googlePlaySubscriptionProductID:
      process.env.GOOGLE_PLAY_SUBSCRIPTION_PRODUCT_ID ??
      configString(googleplay, "subscription_product_id") ??
      "com.openburnbar.pro.monthly",
    googlePlayCloudMonthlyProductID:
      process.env.GOOGLE_PLAY_CLOUD_MONTHLY_PRODUCT_ID ??
      configString(googleplay, "cloud_monthly_product_id") ??
      "com.openburnbar.pro.monthly",
    googlePlayCloudAnnualProductID:
      process.env.GOOGLE_PLAY_CLOUD_ANNUAL_PRODUCT_ID ??
      configString(googleplay, "cloud_annual_product_id") ??
      "com.openburnbar.pro.annual",
    googlePlayCloudProMonthlyProductID:
      process.env.GOOGLE_PLAY_CLOUD_PRO_MONTHLY_PRODUCT_ID ??
      configString(googleplay, "cloud_pro_monthly_product_id") ??
      "com.openburnbar.proMax.v2.monthly",
    googlePlayCloudProAnnualProductID:
      process.env.GOOGLE_PLAY_CLOUD_PRO_ANNUAL_PRODUCT_ID ??
      configString(googleplay, "cloud_pro_annual_product_id") ??
      "com.openburnbar.proMax.annual",
    googlePlayAgentControl100ActionsProductID:
      process.env.GOOGLE_PLAY_AGENT_CONTROL_100_ACTIONS_PRODUCT_ID ??
      configString(googleplay, "agent_control_100_actions_product_id") ??
      "com.openburnbar.agentControl.actions100",
    googlePlayFlooRelay50GBProductID:
      process.env.GOOGLE_PLAY_FLOO_RELAY_50GB_PRODUCT_ID ??
      configString(googleplay, "floo_relay_50gb_product_id") ??
      "com.openburnbar.floo.relay50gb",
    encryptedSessionBlobMaxBytes: toNum(
      process.env.ENCRYPTED_SESSION_BLOB_MAX_BYTES ?? configString(openburnbar, "encrypted_session_blob_max_bytes"),
      10 * 1024 * 1024,
    ),
    hostedQuotaRunnerURL:
      process.env.HOSTED_QUOTA_RUNNER_URL ?? configString(openburnbar, "hosted_quota_runner_url") ?? "",
    hostedQuotaRunnerToken:
      process.env.HOSTED_QUOTA_RUNNER_TOKEN ?? configString(openburnbar, "hosted_quota_runner_token") ?? "",
    hostedQuotaDailyRefreshLimit: toNum(
      process.env.HOSTED_QUOTA_DAILY_REFRESH_LIMIT ?? configString(openburnbar, "hosted_quota_daily_refresh_limit"),
      30,
    ),
    hostedQuotaMonthlyRefreshLimit: toNum(
      process.env.HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT ?? configString(openburnbar, "hosted_quota_monthly_refresh_limit"),
      300,
    ),
    appStore: {
      bundleId: process.env.APP_STORE_BUNDLE_ID ?? configString(appstore, "bundle_id") ?? "com.openburnbar.app",
      // `appAppleId` MUST be `undefined` in Sandbox (library v1.1.0+
      // forbids passing 0 for non-production). The numeric is required
      // for Production-environment notification verification.
      appAppleId: parseAppleId(process.env.APP_STORE_APPLE_APP_ID ?? configString(appstore, "apple_app_id")),
      environment: parseAppStoreEnvironmentValue(
        process.env.APP_STORE_ENV ?? configString(appstore, "environment") ?? "Sandbox",
      ),
      enableOnlineChecks: toBool(
        process.env.APP_STORE_ENABLE_ONLINE_CHECKS ?? configString(appstore, "enable_online_checks"),
        true,
      ),
      autoFallbackEnvironment: toBool(
        process.env.APP_STORE_AUTO_FALLBACK_ENV ?? configString(appstore, "auto_fallback_environment"),
        true,
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
