/**
 * @fileoverview Runtime environment configuration for OpenBurnBar functions.
 *
 * Reads from `firebase functions:config:set` values and process env, providing
 * typed defaults and validation on cold start.
 */

import type { EnvConfig } from "./types.js";
import { readFirebaseFunctionsConfig } from "./firebaseRuntime.js";
import { isRecord, stringValue } from "./guards.js";
import { logWarn } from "./logging.js";

function configBucket(cfg: Record<string, unknown>, key: string): Record<string, unknown> {
  const value = cfg[key];
  return isRecord(value) ? value : {};
}

function configString(cfg: Record<string, unknown>, key: string): string | undefined {
  return stringValue(cfg[key]);
}

function parseStringList(raw: unknown): string[] {
  const source = typeof raw === "string" ? raw : stringValue(raw);
  if (!source) return [];
  return source
    .split(/[\s,]+/u)
    .map((value) => value.trim())
    .filter(Boolean);
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

function toBool(v: unknown, def: boolean): boolean {
  if (v === undefined || v === null) return def;
  if (typeof v === "boolean") return v;
  // Treat empty or whitespace-only string as absent (→ use the secure default).
  // An explicit "true" or "false" is the only accepted opt-in/opt-out signal.
  // This prevents an operator from accidentally disabling a fail-closed security
  // control by setting the secret/env-var to "" instead of removing it entirely.
  const s = String(v).trim().toLowerCase();
  if (s === "") return def;
  return s === "true";
}

function toNum(v: unknown, def: number): number {
  if (v === undefined || v === null) return def;
  const n = Number(v);
  return Number.isFinite(n) ? n : def;
}

function parseAppleId(raw: unknown): number | undefined {
  if (raw === undefined || raw === null || raw === "") return undefined;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) return undefined;
  return Math.floor(n);
}

/** Cached config object computed once per function instance. */
let cached: EnvConfig | undefined;

/** Buckets and resolved identity/security fields shared across config sub-builders. */
type ConfigContext = {
  openburnbar: Record<string, unknown>;
  stripe: Record<string, unknown>;
  googleplay: Record<string, unknown>;
  appstore: Record<string, unknown>;
};

/** Numeric tuning knobs (rollup, quota refresh, and blob/runner limits). */
function buildNumericSettings(
  openburnbar: Record<string, unknown>,
): Pick<
  EnvConfig,
  | "maxCredentialLength"
  | "refreshRateLimitSeconds"
  | "rollupBatchSize"
  | "rollupRepairPageSize"
  | "rollupMaxConsecutiveFullRebuildFailures"
  | "rollupFullRebuildCircuitBreakerMinutes"
  | "rollupForceRebuildMinIntervalMinutes"
  | "rollupPendingDeltaDrainMaxPages"
  | "quotaRefreshBatchSize"
  | "encryptedSessionBlobMaxBytes"
  | "hostedQuotaDailyRefreshLimit"
  | "hostedQuotaMonthlyRefreshLimit"
> {
  return {
    maxCredentialLength: toNum(
      process.env.MAX_CREDENTIAL_LENGTH ?? configString(openburnbar, "max_credential_length"),
      8192,
    ),
    refreshRateLimitSeconds: toNum(
      process.env.REFRESH_RATE_LIMIT_SECONDS ?? configString(openburnbar, "refresh_rate_limit_seconds"),
      60,
    ),
    rollupBatchSize: toNum(process.env.ROLLUP_BATCH_SIZE ?? configString(openburnbar, "rollup_batch_size"), 1000),
    rollupRepairPageSize: toNum(
      process.env.ROLLUP_REPAIR_PAGE_SIZE ?? configString(openburnbar, "rollup_repair_page_size"),
      500,
    ),
    rollupMaxConsecutiveFullRebuildFailures: toNum(
      process.env.ROLLUP_MAX_CONSECUTIVE_FULL_REBUILD_FAILURES ??
        configString(openburnbar, "rollup_max_consecutive_full_rebuild_failures"),
      3,
    ),
    rollupFullRebuildCircuitBreakerMinutes: toNum(
      process.env.ROLLUP_FULL_REBUILD_CIRCUIT_BREAKER_MINUTES ??
        configString(openburnbar, "rollup_full_rebuild_circuit_breaker_minutes"),
      60,
    ),
    rollupForceRebuildMinIntervalMinutes: toNum(
      process.env.ROLLUP_FORCE_REBUILD_MIN_INTERVAL_MINUTES ??
        configString(openburnbar, "rollup_force_rebuild_min_interval_minutes"),
      10,
    ),
    rollupPendingDeltaDrainMaxPages: toNum(
      process.env.ROLLUP_PENDING_DELTA_DRAIN_MAX_PAGES ??
        configString(openburnbar, "rollup_pending_delta_drain_max_pages"),
      20,
    ),
    quotaRefreshBatchSize: toNum(
      process.env.QUOTA_REFRESH_BATCH_SIZE ?? configString(openburnbar, "quota_refresh_batch_size"),
      20,
    ),
    encryptedSessionBlobMaxBytes: toNum(
      process.env.ENCRYPTED_SESSION_BLOB_MAX_BYTES ?? configString(openburnbar, "encrypted_session_blob_max_bytes"),
      10 * 1024 * 1024,
    ),
    hostedQuotaDailyRefreshLimit: toNum(
      process.env.HOSTED_QUOTA_DAILY_REFRESH_LIMIT ?? configString(openburnbar, "hosted_quota_daily_refresh_limit"),
      30,
    ),
    hostedQuotaMonthlyRefreshLimit: toNum(
      process.env.HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT ?? configString(openburnbar, "hosted_quota_monthly_refresh_limit"),
      300,
    ),
  };
}

/** StoreKit / Apple product identifiers and the hosted-quota product id. */
function buildAppleProductIds(
  openburnbar: Record<string, unknown>,
): Pick<
  EnvConfig,
  | "hostedQuotaProductID"
  | "burnBarProProductID"
  | "burnBarProAnnualProductID"
  | "burnBarProMaxProductID"
  | "burnBarProMaxAnnualProductID"
  | "burnBarUltraProductID"
  | "burnBarUltraAnnualProductID"
  | "agentControl100ActionsProductID"
  | "flooRelay50GBProductID"
  | "elderWandSearches100ProductID"
  | "elderWandSearches500ProductID"
> {
  return {
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
    burnBarUltraProductID:
      process.env.BURNBAR_ULTRA_PRODUCT_ID ??
      configString(openburnbar, "burnbar_ultra_product_id") ??
      "com.openburnbar.ultra.monthly",
    burnBarUltraAnnualProductID:
      process.env.BURNBAR_ULTRA_ANNUAL_PRODUCT_ID ??
      configString(openburnbar, "burnbar_ultra_annual_product_id") ??
      "com.openburnbar.ultra.annual.v2",
    agentControl100ActionsProductID:
      process.env.AGENT_CONTROL_100_ACTIONS_PRODUCT_ID ??
      configString(openburnbar, "agent_control_100_actions_product_id") ??
      "com.openburnbar.agentControl.actions100",
    flooRelay50GBProductID:
      process.env.FLOO_RELAY_50GB_PRODUCT_ID ??
      configString(openburnbar, "floo_relay_50gb_product_id") ??
      "com.openburnbar.floo.relay50gb",
    elderWandSearches100ProductID:
      process.env.ELDER_WAND_SEARCHES_100_PRODUCT_ID ??
      configString(openburnbar, "elder_wand_searches_100_product_id") ??
      "com.openburnbar.elderWand.searches100",
    elderWandSearches500ProductID:
      process.env.ELDER_WAND_SEARCHES_500_PRODUCT_ID ??
      configString(openburnbar, "elder_wand_searches_500_product_id") ??
      "com.openburnbar.elderWand.searches500",
  };
}

/** Stripe price identifiers and webhook/secret keys. */
function buildStripeSettings(
  stripe: Record<string, unknown>,
): Pick<
  EnvConfig,
  | "stripeBurnBarProPriceID"
  | "stripeBurnBarCloudMonthlyPriceID"
  | "stripeBurnBarCloudAnnualPriceID"
  | "stripeBurnBarCloudProMonthlyPriceID"
  | "stripeBurnBarCloudProAnnualPriceID"
  | "stripeAgentControl100ActionsPriceID"
  | "stripeFlooRelay50GBPriceID"
  | "stripeElderWandSearches100PriceID"
  | "stripeElderWandSearches500PriceID"
  | "stripeSecretKey"
  | "stripeWebhookSecret"
> {
  return {
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
    stripeElderWandSearches100PriceID:
      process.env.STRIPE_ELDER_WAND_SEARCHES_100_PRICE_ID ??
      configString(stripe, "elder_wand_searches_100_price_id") ??
      "",
    stripeElderWandSearches500PriceID:
      process.env.STRIPE_ELDER_WAND_SEARCHES_500_PRICE_ID ??
      configString(stripe, "elder_wand_searches_500_price_id") ??
      "",
    stripeSecretKey: process.env.STRIPE_SECRET_KEY ?? configString(stripe, "secret_key") ?? "",
    stripeWebhookSecret: process.env.STRIPE_WEBHOOK_SECRET ?? configString(stripe, "webhook_secret") ?? "",
  };
}

/** Google Play package name and product identifiers. */
function buildGooglePlaySettings(
  googleplay: Record<string, unknown>,
): Pick<
  EnvConfig,
  | "googlePlayPackageName"
  | "googlePlaySubscriptionProductID"
  | "googlePlayCloudMonthlyProductID"
  | "googlePlayCloudAnnualProductID"
  | "googlePlayCloudProMonthlyProductID"
  | "googlePlayCloudProAnnualProductID"
  | "googlePlayUltraMonthlyProductID"
  | "googlePlayUltraAnnualProductID"
  | "googlePlayAgentControl100ActionsProductID"
  | "googlePlayFlooRelay50GBProductID"
  | "googlePlayElderWandSearches100ProductID"
  | "googlePlayElderWandSearches500ProductID"
> {
  return {
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
      "com.openburnbar.promax.v2.monthly",
    googlePlayCloudProAnnualProductID:
      process.env.GOOGLE_PLAY_CLOUD_PRO_ANNUAL_PRODUCT_ID ??
      configString(googleplay, "cloud_pro_annual_product_id") ??
      "com.openburnbar.promax.annual",
    googlePlayUltraMonthlyProductID:
      process.env.GOOGLE_PLAY_ULTRA_MONTHLY_PRODUCT_ID ??
      configString(googleplay, "ultra_monthly_product_id") ??
      "com.openburnbar.ultra.monthly",
    googlePlayUltraAnnualProductID:
      process.env.GOOGLE_PLAY_ULTRA_ANNUAL_PRODUCT_ID ??
      configString(googleplay, "ultra_annual_product_id") ??
      "com.openburnbar.ultra.annual",
    googlePlayAgentControl100ActionsProductID:
      process.env.GOOGLE_PLAY_AGENT_CONTROL_100_ACTIONS_PRODUCT_ID ??
      configString(googleplay, "agent_control_100_actions_product_id") ??
      "com.openburnbar.agentcontrol.actions100",
    googlePlayFlooRelay50GBProductID:
      process.env.GOOGLE_PLAY_FLOO_RELAY_50GB_PRODUCT_ID ??
      configString(googleplay, "floo_relay_50gb_product_id") ??
      "com.openburnbar.floo.relay50gb",
    googlePlayElderWandSearches100ProductID:
      process.env.GOOGLE_PLAY_ELDER_WAND_SEARCHES_100_PRODUCT_ID ??
      configString(googleplay, "elder_wand_searches_100_product_id") ??
      "com.openburnbar.elderwand.searches100",
    googlePlayElderWandSearches500ProductID:
      process.env.GOOGLE_PLAY_ELDER_WAND_SEARCHES_500_PRODUCT_ID ??
      configString(googleplay, "elder_wand_searches_500_product_id") ??
      "com.openburnbar.elderwand.searches500",
  };
}

/** Hosted-quota runner endpoint and shared bearer token. */
function buildHostedQuotaRunnerSettings(
  openburnbar: Record<string, unknown>,
): Pick<EnvConfig, "hostedQuotaRunnerURL" | "hostedQuotaRunnerAllowedHosts" | "hostedQuotaRunnerToken"> {
  return {
    hostedQuotaRunnerURL:
      process.env.HOSTED_QUOTA_RUNNER_URL ?? configString(openburnbar, "hosted_quota_runner_url") ?? "",
    hostedQuotaRunnerAllowedHosts: parseStringList(
      process.env.HOSTED_QUOTA_RUNNER_ALLOWED_HOSTS ?? configString(openburnbar, "hosted_quota_runner_allowed_hosts"),
    ),
    hostedQuotaRunnerToken:
      process.env.HOSTED_QUOTA_RUNNER_TOKEN ?? configString(openburnbar, "hosted_quota_runner_token") ?? "",
  };
}

/** App Store verification config (ASC secrets are filled in at request time). */
function buildAppStoreConfig(appstore: Record<string, unknown>): EnvConfig["appStore"] {
  return {
    bundleId: process.env.APP_STORE_BUNDLE_ID ?? configString(appstore, "bundle_id") ?? "com.openburnbar.app",
    // `appAppleId` MUST be `undefined` in Sandbox (library v1.1.0+
    // forbids passing 0 for non-production). The numeric is required
    // for Production-environment notification verification.
    appAppleId: parseAppleId(process.env.APP_STORE_APPLE_APP_ID ?? configString(appstore, "apple_app_id")),
    environment: parseAppStoreEnvironmentValue(
      process.env.APP_STORE_ENV ?? configString(appstore, "environment") ?? "Production",
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
  };
}

/**
 * Resolve App Check enforcement and the production fail-closed guard.
 * Throws (identical message) when a production project disables App Check.
 */
function resolveEnforceAppCheck(openburnbar: Record<string, unknown>, projectId: string, looksProd: boolean): boolean {
  const enforceAppCheck = toBool(process.env.ENFORCE_APP_CHECK ?? configString(openburnbar, "enforce_app_check"), true);

  // L-3: fail CLOSED in production. App Check enforcement is what keeps
  // non-app / non-attested traffic out of every callable and the relay; a real
  // deploy must never silently run with it disabled. Refuse to start if a
  // production project has App Check turned off. Emulator and demo/test/local
  // projects are exempt so local dev and CI still run.
  if (looksProd && !enforceAppCheck) {
    throw new Error(
      `[security] App Check enforcement is DISABLED for production project "${projectId}". ` +
        "Refusing to start: ENFORCE_APP_CHECK must be true in production (set ENFORCE_APP_CHECK=true " +
        "or openburnbar.enforce_app_check=true). Use a demo/emulator project for local testing.",
    );
  }
  return enforceAppCheck;
}

/**
 * Resolve the high-risk single-use nonce replay defense, warning (identical
 * message) when an operator explicitly opts out of the secure production default.
 */
function resolveRequireHighRiskNonce(
  openburnbar: Record<string, unknown>,
  projectId: string,
  looksProd: boolean,
  enforceAppCheck: boolean,
): boolean {
  // L1: default the high-risk single-use nonce replay defense ON in production
  // (fail-closed), matching App Check's posture above. It can still be explicitly
  // turned OFF via env/config for a controlled staged ramp, but the secure default
  // no longer leaves replay defense disabled just because the flag was unset.
  // Emulator/dev/test projects default OFF so local flows without nonce minting
  // keep working.
  const requireHighRiskNonce = toBool(
    process.env.REQUIRE_HIGH_RISK_NONCE ?? configString(openburnbar, "require_high_risk_nonce"),
    looksProd,
  );
  // If an operator EXPLICITLY disables the nonce defense in production, surface it
  // loudly — this is now an opt-out of a secure default, not the default itself.
  if (looksProd && enforceAppCheck && !requireHighRiskNonce) {
    logWarn({
      event: "security.high_risk_nonce_replay_defense_disabled",
      project_id: projectId,
      message:
        `[security] High-risk single-use nonce replay defense has been EXPLICITLY DISABLED for production project "${projectId}". ` +
        "This opts out of the secure default. Re-enable by unsetting REQUIRE_HIGH_RISK_NONCE / openburnbar.require_high_risk_nonce.",
    });
  }
  return requireHighRiskNonce;
}

/**
 * Build the runtime configuration from Firebase Functions config and
 * environment variables.  Falls back to safe defaults for local emulation.
 */
function buildConfig(): EnvConfig {
  // firebase-functions config is injected at runtime via functions.config().
  // For local dev use FIREBASE_CONFIG or plain env vars.
  const cfg = readFirebaseFunctionsConfig();
  const project = configBucket(cfg, "project");
  const ctx: ConfigContext = {
    openburnbar: configBucket(cfg, "openburnbar"),
    stripe: configBucket(cfg, "stripe"),
    googleplay: configBucket(cfg, "googleplay"),
    appstore: configBucket(cfg, "appstore"),
  };
  const { openburnbar } = ctx;

  const projectId =
    process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || configString(project, "id") || "demo-project";

  const kmsKeyName = process.env.KMS_KEY_NAME || configString(openburnbar, "kms_key_name") || "";

  const isEmulator = !!process.env.FUNCTIONS_EMULATOR || !!process.env.FIRESTORE_EMULATOR_HOST;
  const looksProd =
    !isEmulator && projectId !== "demo-project" && !/(^|-)(demo|test|local|dev|emulator)(-|$)/i.test(projectId);

  const enforceAppCheck = resolveEnforceAppCheck(openburnbar, projectId, looksProd);
  const requireHighRiskNonce = resolveRequireHighRiskNonce(openburnbar, projectId, looksProd, enforceAppCheck);

  return {
    projectId,
    kmsKeyName,
    enforceAppCheck,
    requireHighRiskNonce,
    ...buildNumericSettings(openburnbar),
    ...buildAppleProductIds(openburnbar),
    ...buildStripeSettings(ctx.stripe),
    ...buildGooglePlaySettings(ctx.googleplay),
    ...buildHostedQuotaRunnerSettings(openburnbar),
    appStore: buildAppStoreConfig(ctx.appstore),
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
