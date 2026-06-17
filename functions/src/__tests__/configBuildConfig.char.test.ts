import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

/**
 * Characterization test (behavior pin) for buildConfig() via its exported
 * caller getConfig(). Captures the CURRENT observable behavior across two
 * representative inputs before the complexity refactor:
 *
 *   1. A demo/test project with no env overrides — every typed default is
 *      asserted (numeric defaults, StoreKit / Stripe / Google Play product
 *      ids, hosted-quota runner defaults, App Store defaults, and the
 *      fail-OPEN security posture for non-production projects).
 *   2. A production-looking project with App Check disabled — asserts the
 *      thrown Error message (fail-closed guard) is byte-identical.
 *
 * These assertions must remain green after the refactor; the extracted
 * helpers are pure relocations.
 */

const TOUCHED = [
  "GCLOUD_PROJECT",
  "GOOGLE_CLOUD_PROJECT",
  "KMS_KEY_NAME",
  "ENFORCE_APP_CHECK",
  "REQUIRE_HIGH_RISK_NONCE",
  "FUNCTIONS_EMULATOR",
  "FIRESTORE_EMULATOR_HOST",
  "FIREBASE_CONFIG",
  "MAX_CREDENTIAL_LENGTH",
  "REFRESH_RATE_LIMIT_SECONDS",
  "ROLLUP_BATCH_SIZE",
  "ROLLUP_REPAIR_PAGE_SIZE",
  "ROLLUP_MAX_CONSECUTIVE_FULL_REBUILD_FAILURES",
  "ROLLUP_FULL_REBUILD_CIRCUIT_BREAKER_MINUTES",
  "ROLLUP_FORCE_REBUILD_MIN_INTERVAL_MINUTES",
  "ROLLUP_PENDING_DELTA_DRAIN_MAX_PAGES",
  "QUOTA_REFRESH_BATCH_SIZE",
  "ENCRYPTED_SESSION_BLOB_MAX_BYTES",
  "HOSTED_QUOTA_DAILY_REFRESH_LIMIT",
  "HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT",
  "STRIPE_BURNBAR_PRO_PRICE_ID",
  "STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID",
  "APP_STORE_ENV",
  "APP_STORE_APPLE_APP_ID",
  "APP_STORE_BUNDLE_ID",
] as const;

describe("buildConfig characterization (via getConfig)", () => {
  const saved: Record<string, string | undefined> = {};

  beforeEach(() => {
    vi.resetModules();
    for (const k of TOUCHED) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });
  afterEach(() => {
    for (const k of TOUCHED) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  it("returns all typed defaults for a demo project with no overrides", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    const { getConfig } = await import("../config.js");
    const cfg = getConfig();

    // Identity + security posture (non-production => fail-open defaults).
    expect(cfg.projectId).toBe("demo-project");
    expect(cfg.kmsKeyName).toBe("");
    expect(cfg.enforceAppCheck).toBe(true);
    expect(cfg.requireHighRiskNonce).toBe(false);

    // Numeric defaults.
    expect(cfg.maxCredentialLength).toBe(8192);
    expect(cfg.refreshRateLimitSeconds).toBe(60);
    expect(cfg.rollupBatchSize).toBe(1000);
    expect(cfg.rollupRepairPageSize).toBe(500);
    expect(cfg.rollupMaxConsecutiveFullRebuildFailures).toBe(3);
    expect(cfg.rollupFullRebuildCircuitBreakerMinutes).toBe(60);
    expect(cfg.rollupForceRebuildMinIntervalMinutes).toBe(10);
    expect(cfg.rollupPendingDeltaDrainMaxPages).toBe(20);
    expect(cfg.quotaRefreshBatchSize).toBe(20);
    expect(cfg.encryptedSessionBlobMaxBytes).toBe(10 * 1024 * 1024);
    expect(cfg.hostedQuotaDailyRefreshLimit).toBe(30);
    expect(cfg.hostedQuotaMonthlyRefreshLimit).toBe(300);

    // StoreKit / Apple product ids.
    expect(cfg.hostedQuotaProductID).toBe("com.openburnbar.hostedQuotaSync.cloud.monthly");
    expect(cfg.burnBarProProductID).toBe("com.openburnbar.pro.monthly");
    expect(cfg.burnBarProAnnualProductID).toBe("com.openburnbar.pro.annual");
    expect(cfg.burnBarProMaxProductID).toBe("com.openburnbar.proMax.v2.monthly");
    expect(cfg.burnBarProMaxAnnualProductID).toBe("com.openburnbar.proMax.annual");
    expect(cfg.burnBarUltraProductID).toBe("com.openburnbar.ultra.monthly");
    expect(cfg.burnBarUltraAnnualProductID).toBe("com.openburnbar.ultra.annual.v2");
    expect(cfg.agentControl100ActionsProductID).toBe("com.openburnbar.agentControl.actions100");
    expect(cfg.flooRelay50GBProductID).toBe("com.openburnbar.floo.relay50gb");
    expect(cfg.elderWandSearches100ProductID).toBe("com.openburnbar.elderWand.searches100");
    expect(cfg.elderWandSearches500ProductID).toBe("com.openburnbar.elderWand.searches500");

    // Stripe price ids / secrets (default empty unless configured).
    expect(cfg.stripeBurnBarProPriceID).toBe("");
    expect(cfg.stripeBurnBarCloudMonthlyPriceID).toBe("");
    expect(cfg.stripeBurnBarCloudAnnualPriceID).toBe("");
    expect(cfg.stripeBurnBarCloudProMonthlyPriceID).toBe("");
    expect(cfg.stripeBurnBarCloudProAnnualPriceID).toBe("");
    expect(cfg.stripeAgentControl100ActionsPriceID).toBe("");
    expect(cfg.stripeFlooRelay50GBPriceID).toBe("");
    expect(cfg.stripeElderWandSearches100PriceID).toBe("");
    expect(cfg.stripeElderWandSearches500PriceID).toBe("");
    expect(cfg.stripeSecretKey).toBe("");
    expect(cfg.stripeWebhookSecret).toBe("");

    // Google Play product ids.
    expect(cfg.googlePlayPackageName).toBe("com.openburnbar");
    expect(cfg.googlePlaySubscriptionProductID).toBe("com.openburnbar.pro.monthly");
    expect(cfg.googlePlayCloudMonthlyProductID).toBe("com.openburnbar.pro.monthly");
    expect(cfg.googlePlayCloudAnnualProductID).toBe("com.openburnbar.pro.annual");
    expect(cfg.googlePlayCloudProMonthlyProductID).toBe("com.openburnbar.promax.v2.monthly");
    expect(cfg.googlePlayCloudProAnnualProductID).toBe("com.openburnbar.promax.annual");
    expect(cfg.googlePlayUltraMonthlyProductID).toBe("com.openburnbar.ultra.monthly");
    expect(cfg.googlePlayUltraAnnualProductID).toBe("com.openburnbar.ultra.annual");
    expect(cfg.googlePlayAgentControl100ActionsProductID).toBe("com.openburnbar.agentcontrol.actions100");
    expect(cfg.googlePlayFlooRelay50GBProductID).toBe("com.openburnbar.floo.relay50gb");
    expect(cfg.googlePlayElderWandSearches100ProductID).toBe("com.openburnbar.elderwand.searches100");
    expect(cfg.googlePlayElderWandSearches500ProductID).toBe("com.openburnbar.elderwand.searches500");

    // Hosted quota runner.
    expect(cfg.hostedQuotaRunnerURL).toBe("");
    expect(cfg.hostedQuotaRunnerToken).toBe("");

    // App Store defaults.
    expect(cfg.appStore.bundleId).toBe("com.openburnbar.app");
    expect(cfg.appStore.appAppleId).toBeUndefined();
    expect(cfg.appStore.environment).toBe("Sandbox");
    expect(cfg.appStore.enableOnlineChecks).toBe(true);
    expect(cfg.appStore.autoFallbackEnvironment).toBe(true);
    expect(cfg.appStore.asc).toEqual({ issuerId: "", keyId: "", privateKeyP8: "" });
  });

  it("throws the fail-closed Error for a production project with App Check disabled", async () => {
    process.env.GCLOUD_PROJECT = "openburnbar-prod";
    process.env.ENFORCE_APP_CHECK = "false";
    const { getConfig } = await import("../config.js");
    expect(() => getConfig()).toThrow(
      '[security] App Check enforcement is DISABLED for production project "openburnbar-prod". ' +
        "Refusing to start: ENFORCE_APP_CHECK must be true in production (set ENFORCE_APP_CHECK=true " +
        "or openburnbar.enforce_app_check=true). Use a demo/emulator project for local testing.",
    );
  });

  it("honors env-var overrides for representative fields (third input)", async () => {
    process.env.GCLOUD_PROJECT = "demo-project";
    process.env.KMS_KEY_NAME = "projects/p/locations/l/keyRings/r/cryptoKeys/k";
    process.env.MAX_CREDENTIAL_LENGTH = "4096";
    process.env.ROLLUP_BATCH_SIZE = "notanumber"; // non-finite => default
    process.env.STRIPE_BURNBAR_PRO_PRICE_ID = "price_compat_123";
    process.env.APP_STORE_ENV = "Production";
    process.env.APP_STORE_APPLE_APP_ID = "1234567890";
    process.env.APP_STORE_BUNDLE_ID = "com.example.override";
    const { getConfig } = await import("../config.js");
    const cfg = getConfig();

    expect(cfg.kmsKeyName).toBe("projects/p/locations/l/keyRings/r/cryptoKeys/k");
    expect(cfg.maxCredentialLength).toBe(4096);
    expect(cfg.rollupBatchSize).toBe(1000); // non-finite override falls back to default
    expect(cfg.stripeBurnBarProPriceID).toBe("price_compat_123");
    // Compatibility fallthrough: cloud monthly inherits the legacy pro price id.
    expect(cfg.stripeBurnBarCloudMonthlyPriceID).toBe("price_compat_123");
    expect(cfg.appStore.environment).toBe("Production");
    expect(cfg.appStore.appAppleId).toBe(1234567890);
    expect(cfg.appStore.bundleId).toBe("com.example.override");
  });
});
