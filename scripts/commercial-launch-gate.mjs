#!/usr/bin/env node
/**
 * Commercial launch gate for OpenBurnBar.
 *
 * This is a read-only operator command. It gathers the live state that decides
 * whether the commercial launch can proceed, then prints one JSON verdict.
 */

import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import process from "node:process";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import {
  REQUIRED_FIREBASE_APP_CHECK_SERVICE_IDS,
  evaluateFirebaseAppCheckEnforcement,
  evaluateFirebaseAppCheckServiceSet,
} from "./lib/evaluate-firebase-app-check-enforcement.mjs";
import {
  VERIFIABLE_CHANNEL_TYPES,
  checkBillingAlerts,
  checkOpsAlerts,
} from "./lib/ops-alerts-gate.mjs";
import { validateLaunchEvidenceBundle } from "./validate-launch-evidence-bundle.mjs";

export {
  REQUIRED_FIREBASE_APP_CHECK_SERVICE_IDS,
  evaluateFirebaseAppCheckEnforcement,
  evaluateFirebaseAppCheckServiceSet,
};

const REPO = process.env.OPENBURNBAR_GITHUB_REPO || "Imagine-That-Ai/BurnBar";
const PROJECT = process.env.OPENBURNBAR_FIREBASE_PROJECT || "burnbar";
const REGION = process.env.OPENBURNBAR_GCP_REGION || "us-central1";
const REQUIRED_IOS_STATE = "PENDING_DEVELOPER_RELEASE";
const LIVE_IOS_STATE = "READY_FOR_SALE";
const LAUNCH_EVIDENCE_MANIFEST =
  process.env.OPENBURNBAR_LAUNCH_EVIDENCE_MANIFEST ||
  "launch-evidence/final-launch-evidence.json";
const ALERT_DELIVERY_EVIDENCE_PATH =
  process.env.OPENBURNBAR_ALERT_DELIVERY_EVIDENCE ||
  "launch-evidence/alert-channel-verified.json";
const ALERT_DELIVERY_TTL_HOURS = Number(
  process.env.OPENBURNBAR_ALERT_DELIVERY_TTL_HOURS || "168",
);
const LEGACY_HOSTED_QUOTA_PRODUCT_ID =
  "com.openburnbar.hostedQuotaSync.cloud.monthly";
export const COMMERCIAL_PRODUCTS = Object.freeze({
  legacyHostedQuota: LEGACY_HOSTED_QUOTA_PRODUCT_ID,
  cloudMonthly: "com.openburnbar.pro.monthly",
  cloudAnnual: "com.openburnbar.pro.annual",
  cloudProMonthly: "com.openburnbar.proMax.v2.monthly",
  legacyAppleCloudProBundleMonthly: "com.openburnbar.proMax.bundle.monthly",
  cloudProAnnual: "com.openburnbar.proMax.annual",
  ultraMonthly: "com.openburnbar.ultra.monthly",
  ultraAnnual: "com.openburnbar.ultra.annual.v2",
  agentControlActions100: "com.openburnbar.agentControl.actions100",
  flooRelay50GB: "com.openburnbar.floo.relay50gb",
  elderWandSearches100: "com.openburnbar.elderWand.searches100",
  elderWandSearches500: "com.openburnbar.elderWand.searches500",
});
export const GOOGLE_PLAY_PRODUCTS = Object.freeze({
  cloudMonthly: "com.openburnbar.pro.monthly",
  cloudAnnual: "com.openburnbar.pro.annual",
  cloudProMonthly: "com.openburnbar.promax.v2.monthly",
  cloudProAnnual: "com.openburnbar.promax.annual",
  ultraMonthly: "com.openburnbar.ultra.monthly",
  ultraAnnual: "com.openburnbar.ultra.annual",
  agentControlActions100: "com.openburnbar.agentcontrol.actions100",
  flooRelay50GB: "com.openburnbar.floo.relay50gb",
  elderWandSearches100: "com.openburnbar.elderwand.searches100",
  elderWandSearches500: "com.openburnbar.elderwand.searches500",
});
const REQUIRED_APP_STORE_SUBSCRIPTION_PRODUCT_IDS = [
  COMMERCIAL_PRODUCTS.cloudMonthly,
  COMMERCIAL_PRODUCTS.cloudAnnual,
  COMMERCIAL_PRODUCTS.cloudProMonthly,
  COMMERCIAL_PRODUCTS.cloudProAnnual,
  COMMERCIAL_PRODUCTS.ultraMonthly,
  COMMERCIAL_PRODUCTS.ultraAnnual,
];
const REQUIRED_TOP_UP_PRODUCT_IDS = [
  COMMERCIAL_PRODUCTS.agentControlActions100,
  COMMERCIAL_PRODUCTS.flooRelay50GB,
  COMMERCIAL_PRODUCTS.elderWandSearches100,
  COMMERCIAL_PRODUCTS.elderWandSearches500,
];
const ELDER_WAND_HOSTED_SEARCH_FUNCTION = "performElderWandHostedSearch";
const REQUIRED_ELDER_WAND_HOSTED_SEARCH_ENV = {
  ENFORCE_APP_CHECK: "true",
};
const REQUIRED_ELDER_WAND_HOSTED_SEARCH_SECRETS = [
  "PERPLEXITY_API_KEY",
  "TAVILY_API_KEY",
];
const REQUIRED_COMMERCIAL_PRODUCT_IDS = [
  ...REQUIRED_APP_STORE_SUBSCRIPTION_PRODUCT_IDS,
  ...REQUIRED_TOP_UP_PRODUCT_IDS,
];
const APP_STORE_PRODUCT_READY_STATES = new Set([
  "READY_TO_SUBMIT",
  "WAITING_FOR_REVIEW",
  "IN_REVIEW",
  "APPROVED",
  "READY_FOR_SALE",
]);
const RETIRED_HERMES_REALTIME_RELAY_SERVICE = "hermes-realtime-relay";
const REQUIRED_CLOUD_RUN_SERVICES = [
  "openburnbar-quota-runner",
  "openburnbar-hosted-mcp",
];
const RETIRED_HERMES_REALTIME_REDIS_INSTANCE =
  process.env.OPENBURNBAR_RETIRED_REDIS_INSTANCE_NAME ||
  "hermes-realtime-relay-redis-prod-secure";
// The required-status-check set is NOT hand-maintained here. It is read from the
// governance source of truth (governance/branch-protection.main.json) so this
// gate can never pass while live branch protection has drifted BELOW the desired
// policy — the exact failure a stale local copy would hide (a check added to the
// JSON but forgotten here). Only `required_status_checks.contexts` is consumed;
// the segregated `_pending_required_status_checks` placeholders (e.g.
// `diff-coverage (PR)`) live under a different key and are intentionally excluded
// because no workflow emits them yet.
const BRANCH_PROTECTION_SOURCE_OF_TRUTH =
  process.env.OPENBURNBAR_BRANCH_PROTECTION_SOURCE ||
  join(
    dirname(fileURLToPath(import.meta.url)),
    "..",
    "governance",
    "branch-protection.main.json",
  );

export function loadRequiredBranchChecks(
  sourcePath = BRANCH_PROTECTION_SOURCE_OF_TRUTH,
) {
  let raw;
  try {
    raw = readFileSync(sourcePath, "utf8");
  } catch (error) {
    throw new Error(
      `cannot read branch-protection source of truth at ${sourcePath}: ${error.message}`,
    );
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`invalid JSON in ${sourcePath}: ${error.message}`);
  }
  const contexts = parsed?.required_status_checks?.contexts;
  if (!Array.isArray(contexts) || contexts.length === 0) {
    // Fail closed: an empty/absent required set must halt the gate, never let it
    // pass against a shorter (or empty) list of checks.
    throw new Error(
      `${sourcePath} has no required_status_checks.contexts; refusing to run the launch gate with an empty required-check set`,
    );
  }
  return [...contexts];
}
const REQUIRED_CODEQL_CHECKS = [
  "Analyze (javascript-typescript)",
  "Analyze (python)",
];
const REQUIRED_MAIN_GATE_CHECK = "openburnbar-pr";
const GITHUB_ACTIONS_APP_SLUG = "github-actions";
const REQUIRED_MAIN_GATE_WORKFLOW_PATHS = [
  ".github/workflows/openburnbar-pr-harness.yml",
];
const REQUIRED_CODEQL_WORKFLOW_PATHS = [
  ".github/workflows/codeql.yml",
  ".github/workflows/codeql-pr.yml",
];
const REQUIRED_GITHUB_SECURITY_SETTINGS = [
  "dependabot_security_updates",
  "secret_scanning",
  "secret_scanning_ai_detection",
  "secret_scanning_non_provider_patterns",
  "secret_scanning_push_protection",
  "secret_scanning_validity_checks",
];
const REQUIRED_FIREBASE_FUNCTIONS = [
  "appStoreServerNotificationsV2",
  "approveEscrowDeviceTrust",
  "bindAppCheckAttestation",
  "beginEntitlementBinding",
  "connectHostedQuotaAccount",
  "consumeCredentialTransfer",
  "createStripeBurnBarProCheckoutSession",
  "createStripeBurnBarProPortalSession",
  "deleteUserCloudData",
  "deleteHostedQuotaCredentials",
  "deleteProviderAccount",
  "evaluateComputerUseBudget",
  "evaluateMediaBudget",
  "computeTierCogsDaily",
  "onUsageWritten",
  "performElderWandHostedSearch",
  "rebuildRollups",
  "reconcileHostedEntitlementsDaily",
  "recomputeComputerUseQuotaUsage",
  "recomputeMediaQuotaUsage",
  "refreshAllProviderQuotas",
  "refreshProviderAccountQuota",
  "registerBrowserEscrowDevice",
  "registerEscrowDevice",
  "reserveAgentControlActionBudget",
  "reserveFlooRelayBudget",
  "restoreHostedQuotaEntitlement",
  "revokeAllAccess",
  "revokeEscrowDeviceTrust",
  "rollupComputerUseDaily",
  "rollupMediaSessionDaily",
  "searchStreams",
  "stripeBurnBarProWebhook",
  "verifyCloudProTopUp",
  "googlePlayDeveloperNotifications",
  "verifyGooglePlayCloudProTopUp",
  "verifyGooglePlayBurnBarProSubscription",
  "verifyHostedQuotaEntitlement",
];
const FORBIDDEN_FIREBASE_FUNCTIONS = [
  // Legacy local-JWS-shape entitlement sync. The launch path must use the
  // Apple-server-verified callables above.
  "syncHostedQuotaEntitlement",
];
const REQUIRED_HOSTED_QUOTA_FUNCTIONS = [
  {
    id: "refreshProviderAccountQuota",
    requiresRunnerToken: true,
  },
  {
    id: "refreshAllProviderQuotas",
    requiresRunnerToken: true,
  },
  {
    id: "connectHostedQuotaAccount",
    requiresRunnerToken: false,
  },
  {
    id: "deleteHostedQuotaCredentials",
    requiresRunnerToken: false,
  },
  {
    id: "deleteProviderAccount",
    requiresRunnerToken: false,
  },
];
const REQUIRED_HOSTED_QUOTA_ENV = {
  ENFORCE_APP_CHECK: "true",
  HOSTED_QUOTA_DAILY_REFRESH_LIMIT: "30",
  HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT: "300",
  HOSTED_QUOTA_PRODUCT_ID: LEGACY_HOSTED_QUOTA_PRODUCT_ID,
  BURNBAR_PRO_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudMonthly,
  BURNBAR_PRO_MAX_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudProMonthly,
};

export function parseHostedQuotaRunnerAllowedHosts(raw) {
  return String(raw || "")
    .split(/[\s,]+/u)
    .map((host) => host.trim().toLowerCase().replace(/\.$/u, ""))
    .filter(Boolean);
}

function parseURL(raw) {
  try {
    return new URL(raw || "");
  } catch {
    return undefined;
  }
}

export function evaluateHostedQuotaRunnerEndpoint({
  configuredURL,
  allowedHosts,
  cloudRunURL,
}) {
  const runnerURL = parseURL(configuredURL);
  const serviceURL = parseURL(cloudRunURL);
  const allowed = parseHostedQuotaRunnerAllowedHosts(allowedHosts);
  const allowedHostSet = new Set(allowed);
  const host = runnerURL?.hostname.toLowerCase().replace(/\.$/u, "") || null;
  const serviceHost =
    serviceURL?.hostname.toLowerCase().replace(/\.$/u, "") || null;
  const usesHTTPS = runnerURL?.protocol === "https:";
  const noUserInfo = Boolean(
    runnerURL && !runnerURL.username && !runnerURL.password,
  );
  const defaultHTTPSPort = Boolean(
    runnerURL && (!runnerURL.port || runnerURL.port === "443"),
  );
  const allowedHostConfigured = Boolean(host && allowedHostSet.has(host));
  const matchesCloudRunService = Boolean(
    host && serviceHost && host === serviceHost,
  );
  return {
    ok:
      usesHTTPS &&
      noUserInfo &&
      defaultHTTPSPort &&
      allowedHostConfigured &&
      matchesCloudRunService,
    host,
    cloudRunHost: serviceHost,
    allowedHosts: allowed,
    usesHTTPS,
    noUserInfo,
    defaultHTTPSPort,
    allowedHostConfigured,
    matchesCloudRunService,
  };
}
const REQUIRED_COMMERCIAL_ENV_VALUES = {
  STRIPE_BURNBAR_PRO_PRICE_ID: "alias:STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID",
  STRIPE_REDIRECT_URL_ALLOWLIST:
    "burnbar.ai,www.burnbar.ai,burnbar.web.app,burnbar.firebaseapp.com",
  BURNBAR_PRO_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudMonthly,
  BURNBAR_PRO_ANNUAL_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudAnnual,
  BURNBAR_PRO_MAX_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudProMonthly,
  BURNBAR_PRO_MAX_ANNUAL_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudProAnnual,
  BURNBAR_ULTRA_PRODUCT_ID: COMMERCIAL_PRODUCTS.ultraMonthly,
  BURNBAR_ULTRA_ANNUAL_PRODUCT_ID: COMMERCIAL_PRODUCTS.ultraAnnual,
  AGENT_CONTROL_100_ACTIONS_PRODUCT_ID:
    COMMERCIAL_PRODUCTS.agentControlActions100,
  FLOO_RELAY_50GB_PRODUCT_ID: COMMERCIAL_PRODUCTS.flooRelay50GB,
  ELDER_WAND_SEARCHES_100_PRODUCT_ID:
    COMMERCIAL_PRODUCTS.elderWandSearches100,
  ELDER_WAND_SEARCHES_500_PRODUCT_ID:
    COMMERCIAL_PRODUCTS.elderWandSearches500,
  GOOGLE_PLAY_PACKAGE_NAME: "com.openburnbar",
  GOOGLE_PLAY_RTDN_TOPIC: "play-billing-notifications",
  GOOGLE_PLAY_CLOUD_MONTHLY_PRODUCT_ID: GOOGLE_PLAY_PRODUCTS.cloudMonthly,
  GOOGLE_PLAY_CLOUD_ANNUAL_PRODUCT_ID: GOOGLE_PLAY_PRODUCTS.cloudAnnual,
  GOOGLE_PLAY_CLOUD_PRO_MONTHLY_PRODUCT_ID:
    GOOGLE_PLAY_PRODUCTS.cloudProMonthly,
  GOOGLE_PLAY_CLOUD_PRO_ANNUAL_PRODUCT_ID: GOOGLE_PLAY_PRODUCTS.cloudProAnnual,
  GOOGLE_PLAY_ULTRA_MONTHLY_PRODUCT_ID: GOOGLE_PLAY_PRODUCTS.ultraMonthly,
  GOOGLE_PLAY_ULTRA_ANNUAL_PRODUCT_ID: GOOGLE_PLAY_PRODUCTS.ultraAnnual,
  GOOGLE_PLAY_AGENT_CONTROL_100_ACTIONS_PRODUCT_ID:
    GOOGLE_PLAY_PRODUCTS.agentControlActions100,
  GOOGLE_PLAY_FLOO_RELAY_50GB_PRODUCT_ID: GOOGLE_PLAY_PRODUCTS.flooRelay50GB,
  GOOGLE_PLAY_ELDER_WAND_SEARCHES_100_PRODUCT_ID:
    GOOGLE_PLAY_PRODUCTS.elderWandSearches100,
  GOOGLE_PLAY_ELDER_WAND_SEARCHES_500_PRODUCT_ID:
    GOOGLE_PLAY_PRODUCTS.elderWandSearches500,
};
const REQUIRED_COMMERCIAL_ENV_PRESENT = [
  "STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID",
  "STRIPE_BURNBAR_CLOUD_ANNUAL_PRICE_ID",
  "STRIPE_BURNBAR_CLOUD_PRO_MONTHLY_PRICE_ID",
  "STRIPE_BURNBAR_CLOUD_PRO_ANNUAL_PRICE_ID",
  "STRIPE_BURNBAR_ULTRA_MONTHLY_PRICE_ID",
  "STRIPE_BURNBAR_ULTRA_ANNUAL_PRICE_ID",
  "STRIPE_AGENT_CONTROL_100_ACTIONS_PRICE_ID",
  "STRIPE_FLOO_RELAY_50GB_PRICE_ID",
  "STRIPE_ELDER_WAND_SEARCHES_100_PRICE_ID",
  "STRIPE_ELDER_WAND_SEARCHES_500_PRICE_ID",
];
const REQUIRED_REMOTE_CONFIG_DEFAULTS = {
  media_budget_soft_usd: "600",
  media_budget_hard_usd: "1000",
  media_kill_switch: "false",
  computer_use_budget_soft_usd: "1500",
  computer_use_budget_hard_usd: "2500",
  computer_use_kill_switch: "false",
  hosted_quota_daily_refresh_limit: "30",
  hosted_quota_monthly_refresh_limit: "300",
  cloud_pro_included_hosted_actions_monthly: "500",
  cloud_pro_action_topup_unit: "100",
  cloud_pro_monthly_hosted_action_cap: "2000",
  cloud_pro_included_relay_gb_monthly: "50",
  cloud_pro_relay_topup_unit_gb: "50",
  cloud_pro_monthly_relay_gb_cap: "300",
  cloud_pro_included_fusion_searches_monthly: "100",
  cloud_ultra_included_fusion_searches_monthly: "300",
  cloud_pro_fusion_search_topup_unit: "100",
  cloud_pro_fusion_search_large_topup_unit: "500",
  cloud_pro_monthly_fusion_search_cap: "1000",
  cloud_ultra_monthly_fusion_search_cap: "2000",
};
const FIREBASE_APP_CHECK_API_BASE =
  "https://firebaseappcheck.googleapis.com/v1beta";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || process.cwd(),
    env: options.env || process.env,
    encoding: "utf8",
    timeout: options.timeout ?? 120_000,
    // git file lists exceed node's default 1MB maxBuffer (ENOBUFS) on this tree.
    maxBuffer: 256 * 1024 * 1024,
  });
  return {
    ok: result.status === 0,
    status: result.status,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error?.message,
  };
}

function curlConfigValue(value, label) {
  const source = String(value || "");
  if (/[\r\n]/u.test(source)) {
    throw new Error(`${label} must be a single line`);
  }
  return source.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}

export function buildFirebaseAppCheckCurlConfig(
  serviceName,
  accessToken,
  options = {},
) {
  const userProject = options.userProject || PROJECT;
  const url = `${options.baseURL || FIREBASE_APP_CHECK_API_BASE}/${serviceName}`;
  const authHeader = `Authorization: Bearer ${accessToken}`;
  const projectHeader = `x-goog-user-project: ${userProject}`;
  return [
    "fail",
    "show-error",
    "silent",
    "connect-timeout = 15",
    "max-time = 45",
    "retry = 2",
    "retry-delay = 2",
    "retry-all-errors",
    `header = "${curlConfigValue(authHeader, "authorization header")}"`,
    `header = "${curlConfigValue(projectHeader, "user project header")}"`,
    `url = "${curlConfigValue(url, "request URL")}"`,
    "",
  ].join("\n");
}

export function firebaseAppCheckCurlArgs(configPath) {
  return ["--config", configPath];
}

function fetchFirebaseAppCheckServiceConfig(serviceName, accessToken) {
  const tempDir = mkdtempSync(join(tmpdir(), "openburnbar-appcheck-curl-"));
  const configPath = join(tempDir, "curl.conf");
  try {
    writeFileSync(
      configPath,
      buildFirebaseAppCheckCurlConfig(serviceName, accessToken, {
        userProject: PROJECT,
      }),
      { mode: 0o600 },
    );
    const result = run("curl", firebaseAppCheckCurlArgs(configPath), {
      timeout: 180_000,
    });
    if (!result.ok) {
      return { ok: false, error: result.stderr || result.stdout || result.error };
    }
    try {
      return { ok: true, config: JSON.parse(result.stdout) };
    } catch (error) {
      return {
        ok: false,
        error: `invalid Firebase App Check service response: ${error.message}`,
      };
    }
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

function firstJSON(text) {
  const source = String(text || "");
  const start = source.indexOf("{");
  if (start < 0) throw new Error("no JSON object found in command output");
  return JSON.parse(source.slice(start));
}

export function evaluateRequiredProductIDs(
  observedProductIDs,
  requiredProductIDs,
) {
  const observed = [
    ...new Set((observedProductIDs || []).filter(Boolean)),
  ].sort();
  const observedSet = new Set(observed);
  const missing = requiredProductIDs.filter(
    (productID) => !observedSet.has(productID),
  );
  return {
    ok: missing.length === 0,
    required: requiredProductIDs,
    observed,
    missing,
  };
}

function appStoreProductIDsFromStatus(status) {
  const ids = [];
  const push = (value) => {
    if (typeof value === "string" && value.trim()) ids.push(value.trim());
  };
  push(status.subscription?.productId);
  for (const item of status.subscriptions || [])
    push(item?.productId || item?.productID);
  for (const item of status.inAppPurchases || [])
    push(item?.productId || item?.productID);
  for (const item of status.products || [])
    push(item?.productId || item?.productID);
  for (const item of status.commercialProducts || [])
    push(item?.productId || item?.productID);
  return ids;
}

export function evaluateAppStoreProductReadiness(status, requiredProductIDs) {
  const products = [];
  if (status.subscription) products.push(status.subscription);
  for (const item of status.subscriptions || []) products.push(item);
  for (const item of status.inAppPurchases || []) products.push(item);
  for (const item of status.products || []) products.push(item);
  for (const item of status.commercialProducts || []) products.push(item);
  const byProductID = new Map();
  for (const product of products) {
    const productId = product?.productId || product?.productID;
    if (typeof productId === "string" && productId.trim())
      byProductID.set(productId.trim(), product);
  }
  const checks = requiredProductIDs.map((productId) => {
    const product = byProductID.get(productId);
    const state = product?.state || null;
    return {
      productId,
      ok: APP_STORE_PRODUCT_READY_STATES.has(state),
      state,
      id: product?.id || null,
      name: product?.name || null,
    };
  });
  return {
    ok: checks.every((check) => check.ok),
    allowedStates: [...APP_STORE_PRODUCT_READY_STATES],
    checks,
  };
}

export function evaluateEnvRequirements(
  env,
  requiredValues,
  requiredPresent = [],
) {
  const valueChecks = Object.entries(requiredValues).map(([name, expected]) => {
    const actual = env[name] ?? null;
    if (typeof expected === "string" && expected.startsWith("alias:")) {
      const alias = expected.slice("alias:".length);
      const aliasValue = env[alias] ?? null;
      return {
        name,
        ok: Boolean(actual) && actual === aliasValue,
        actual,
        expected: `same as ${alias}`,
        aliasValue,
      };
    }
    return { name, ok: actual === expected, actual, expected };
  });
  const presenceChecks = requiredPresent.map((name) => ({
    name,
    ok: typeof env[name] === "string" && env[name].trim().length > 0,
    present: typeof env[name] === "string" && env[name].trim().length > 0,
  }));
  return {
    ok:
      valueChecks.every((check) => check.ok) &&
      presenceChecks.every((check) => check.ok),
    valueChecks,
    presenceChecks,
  };
}

function remoteConfigDefaultValue(parameter) {
  const raw = parameter?.defaultValue;
  if (!raw || typeof raw !== "object") return undefined;
  if (typeof raw.value === "string") return raw.value;
  if (raw.useInAppDefault === true) return "USE_IN_APP_DEFAULT";
  return undefined;
}

export function evaluateRemoteConfigDefaults(template, requiredDefaults) {
  const parameters = template?.parameters || {};
  const checks = Object.entries(requiredDefaults).map(([name, expected]) => {
    const actual = remoteConfigDefaultValue(parameters[name]);
    return { name, ok: actual === expected, actual: actual ?? null, expected };
  });
  return {
    ok: checks.every((check) => check.ok),
    checks,
  };
}

function secretEnv() {
  const env = { ...process.env };
  const keys = [
    "APP_STORE_ASC_KEY_ID",
    "APP_STORE_ASC_ISSUER_ID",
    "APP_STORE_ASC_KEY_P8",
  ];
  for (const key of keys) {
    if (env[key]) continue;
    const result = run("firebase", [
      "functions:secrets:access",
      key,
      "--project",
      PROJECT,
    ]);
    if (!result.ok) {
      throw new Error(
        `failed to read Firebase secret ${key}: ${result.stderr || result.stdout}`,
      );
    }
    env[key] = result.stdout.trim();
  }
  return env;
}

function checkRepo() {
  const head = run("git", ["rev-parse", "HEAD"]);
  const originMain = run("git", ["rev-parse", "origin/main"]);
  const status = run("git", ["status", "--short", "--branch"]);
  const diff = run("git", ["diff", "--quiet", "HEAD"]);
  const untracked = run("git", ["ls-files", "--others", "--exclude-standard"]);
  return {
    ok:
      head.ok &&
      originMain.ok &&
      head.stdout.trim() === originMain.stdout.trim() &&
      diff.ok &&
      untracked.stdout.trim() === "",
    head: head.stdout.trim(),
    originMain: originMain.stdout.trim(),
    status: status.stdout.trim(),
    clean: diff.ok && untracked.stdout.trim() === "",
  };
}

function checkAppStore() {
  const result = run("node", ["tools/app-store-connect/asc-api.js", "status"], {
    env: secretEnv(),
    timeout: 120_000,
  });
  if (!result.ok) {
    return { ok: false, error: result.stderr || result.stdout || result.error };
  }
  const status = firstJSON(result.stdout);
  const state = status.iosVersion?.state;
  const subscriptionState = status.subscription?.state;
  const manualRelease = status.iosVersion?.releaseType === "MANUAL";
  const buildReady =
    status.linkedBuild?.processingState === "VALID" &&
    status.linkedBuild?.buildAudienceType === "APP_STORE_ELIGIBLE" &&
    status.linkedBuild?.usesNonExemptEncryption === false;
  const observedProductIDs = appStoreProductIDsFromStatus(status);
  const productCoverage = evaluateRequiredProductIDs(
    observedProductIDs,
    REQUIRED_COMMERCIAL_PRODUCT_IDS,
  );
  const productReadiness = evaluateAppStoreProductReadiness(
    status,
    REQUIRED_COMMERCIAL_PRODUCT_IDS,
  );
  const legacyGrandfatherPresent = observedProductIDs.includes(
    LEGACY_HOSTED_QUOTA_PRODUCT_ID,
  );
  return {
    ok:
      manualRelease &&
      buildReady &&
      productCoverage.ok &&
      productReadiness.ok &&
      legacyGrandfatherPresent &&
      ["WAITING_FOR_REVIEW", REQUIRED_IOS_STATE, LIVE_IOS_STATE].includes(
        state,
      ) &&
      ["WAITING_FOR_REVIEW", "APPROVED", "READY_FOR_SALE"].includes(
        subscriptionState,
      ),
    state,
    subscriptionState,
    manualRelease,
    buildReady,
    productCoverage,
    productReadiness,
    legacyGrandfatherPresent,
    versionString: status.iosVersion?.versionString,
    versionId: status.iosVersion?.id,
  };
}

function appStoreNotificationProof(environment) {
  const result = run(
    "node",
    [
      "tools/app-store-connect/asc-api.js",
      "test-server-notifications",
      environment,
    ],
    {
      env: secretEnv(),
      timeout: 90_000,
    },
  );
  const payload = result.stdout ? firstJSON(result.stdout) : null;
  const proof = payload?.results?.find(
    (item) => item.environment?.toLowerCase() === environment.toLowerCase(),
  );
  return {
    ok: result.ok && proof?.delivered === true,
    requestStatus: proof?.requestStatus ?? null,
    requestOk: proof?.requestOk ?? false,
    hasToken: proof?.hasToken ?? false,
    delivered: proof?.delivered ?? false,
    firstSendAttemptResult: proof?.firstSendAttemptResult ?? null,
    sendAttempts: proof?.sendAttempts ?? [],
    error:
      proof?.error ||
      (result.ok ? undefined : result.stderr || result.stdout || result.error),
  };
}

function checkAppStoreServerNotifications(appStore) {
  const sandbox = appStoreNotificationProof("sandbox");
  const productionRequired = appStore?.state === LIVE_IOS_STATE;
  const production = productionRequired
    ? appStoreNotificationProof("production")
    : {
        ok: true,
        skipped: true,
        reason:
          "Production notification proof is required after App Store release.",
      };
  return {
    ok: sandbox.ok && production.ok,
    sandbox,
    productionRequired,
    production,
  };
}

function checkFirebaseAppCheckEnforcement() {
  if (process.env.OPENBURNBAR_SKIP_LIVE_APP_CHECK_GATE === "1") {
    return {
      ok: true,
      skipped: true,
      reason: "OPENBURNBAR_SKIP_LIVE_APP_CHECK_GATE=1",
      probe: "skipped",
    };
  }

  const projectNumber = run("gcloud", [
    "projects",
    "describe",
    PROJECT,
    "--format=value(projectNumber)",
  ]);
  if (!projectNumber.ok) {
    return {
      ok: false,
      error:
        projectNumber.stderr || projectNumber.stdout || projectNumber.error,
    };
  }

  const token = run("gcloud", ["auth", "print-access-token"]);
  if (!token.ok) {
    return { ok: false, error: token.stderr || token.stdout || token.error };
  }

  const configs = [];
  for (const serviceId of REQUIRED_FIREBASE_APP_CHECK_SERVICE_IDS) {
    const serviceName = `projects/${projectNumber.stdout.trim()}/services/${serviceId}`;
    const result = fetchFirebaseAppCheckServiceConfig(
      serviceName,
      token.stdout.trim(),
    );
    if (!result.ok) {
      return {
        ok: false,
        serviceId,
        serviceName,
        error: result.error,
      };
    }

    const config = result.config;
    configs.push({
      serviceId,
      serviceName,
      enforcementMode: config.enforcementMode || null,
      updateTime: config.updateTime || null,
    });
  }

  return evaluateFirebaseAppCheckServiceSet(configs);
}

function checkProtection() {
  const result = run("gh", [
    "api",
    "-H",
    "Accept: application/vnd.github+json",
    `/repos/${REPO}/branches/main/protection`,
  ]);
  if (!result.ok) return { ok: false, error: result.stderr || result.stdout };
  const protection = JSON.parse(result.stdout);
  const checks = [
    ...new Set([
      ...(protection.required_status_checks?.contexts || []),
      ...((protection.required_status_checks?.checks || [])
        .map((check) => check.context)
        .filter(Boolean)),
    ]),
  ];
  const requiredBranchChecks = loadRequiredBranchChecks();
  const missingRequiredChecks = requiredBranchChecks.filter(
    (check) => !checks.includes(check),
  );
  const pullRequestReviews = protection.required_pull_request_reviews || {};
  const reviewCount =
    pullRequestReviews.required_approving_review_count ?? 0;
  const bypass = pullRequestReviews.bypass_pull_request_allowances || {};
  const bypassAllowanceCount =
    (bypass.users || []).length +
    (bypass.teams || []).length +
    (bypass.apps || []).length;
  const staleReviewsDismissed =
    pullRequestReviews.dismiss_stale_reviews === true;
  const latestPushApprovalRequired =
    pullRequestReviews.require_last_push_approval === true;
  return {
    ok:
      protection.enforce_admins?.enabled === true &&
      protection.allow_force_pushes?.enabled === false &&
      protection.allow_deletions?.enabled === false &&
      protection.required_conversation_resolution?.enabled === true &&
      reviewCount === 1 &&
      pullRequestReviews.require_code_owner_reviews === true &&
      staleReviewsDismissed &&
      latestPushApprovalRequired &&
      bypassAllowanceCount === 0 &&
      missingRequiredChecks.length === 0,
    requiredChecks: checks,
    desiredRequiredChecks: requiredBranchChecks,
    missingRequiredChecks,
    codeOwnerReviewsRequired:
      pullRequestReviews.require_code_owner_reviews === true,
    staleReviewsDismissed,
    latestPushApprovalRequired,
    bypassAllowanceCount,
    reviewCount,
    adminsEnforced: protection.enforce_admins?.enabled === true,
    conversationResolutionRequired:
      protection.required_conversation_resolution?.enabled === true,
    forcePushesAllowed: protection.allow_force_pushes?.enabled === true,
    deletionsAllowed: protection.allow_deletions?.enabled === true,
  };
}

function ghJSON(path, options = {}) {
  const result = run(
    "gh",
    ["api", "-H", "Accept: application/vnd.github+json", path],
    options,
  );
  if (!result.ok) {
    return { ok: false, error: result.stderr || result.stdout || result.error };
  }
  return { ok: true, value: JSON.parse(result.stdout) };
}

export function actionsRunIdFromCheckRun(check) {
  const detailsUrl = String(check?.details_url || check?.html_url || "");
  const match = /\/actions\/runs\/([0-9]+)(?:\/|$)/u.exec(detailsUrl);
  return match?.[1] || null;
}

export function evaluateTrustedGitHubActionsCheckRun(
  check,
  { sha, workflowRun, allowedWorkflowPaths },
) {
  if (!check) {
    return {
      ok: false,
      status: "missing",
      conclusion: null,
      completedAt: null,
      trust: "missing-check-run",
    };
  }

  const picked = pickCheck(check);
  const appSlug = check.app?.slug || null;
  if (appSlug !== GITHUB_ACTIONS_APP_SLUG) {
    return {
      ...picked,
      ok: false,
      appSlug,
      trust: "untrusted-check-app",
    };
  }

  if (!workflowRun) {
    return {
      ...picked,
      ok: false,
      appSlug,
      trust: "missing-workflow-run-metadata",
    };
  }

  const workflowPath = workflowRun.path || null;
  const headSha = workflowRun.head_sha || null;
  const workflowAllowed = allowedWorkflowPaths.includes(workflowPath);
  const shaMatches = !sha || headSha === sha;
  const ok =
    workflowAllowed &&
    shaMatches &&
    picked.status === "completed" &&
    picked.conclusion === "success";
  return {
    ...picked,
    ok,
    appSlug,
    workflowPath,
    workflowName: workflowRun.name || null,
    runId: workflowRun.id || null,
    headSha,
    trust: ok
      ? "trusted"
      : workflowAllowed
        ? shaMatches
          ? "check-not-successful"
          : "workflow-run-head-sha-mismatch"
        : "untrusted-workflow-path",
  };
}

function trustedCheckRunFor(check, sha, allowedWorkflowPaths) {
  if (!check) {
    return evaluateTrustedGitHubActionsCheckRun(null, {
      sha,
      workflowRun: null,
      allowedWorkflowPaths,
    });
  }

  const runId = actionsRunIdFromCheckRun(check);
  if (!runId) {
    return {
      ...pickCheck(check),
      ok: false,
      appSlug: check.app?.slug || null,
      trust: "missing-actions-run-id",
    };
  }

  const workflowRun = ghJSON(`/repos/${REPO}/actions/runs/${runId}`);
  if (!workflowRun.ok) {
    return {
      ...pickCheck(check),
      ok: false,
      appSlug: check.app?.slug || null,
      runId,
      trust: "workflow-run-read-failed",
      error: workflowRun.error,
    };
  }

  return evaluateTrustedGitHubActionsCheckRun(check, {
    sha,
    workflowRun: workflowRun.value,
    allowedWorkflowPaths,
  });
}

function findTrustedCheckRun(checkRuns, name, sha, allowedWorkflowPaths) {
  const candidates = checkRuns.filter((check) => check.name === name);
  if (candidates.length === 0) {
    return evaluateTrustedGitHubActionsCheckRun(null, {
      sha,
      workflowRun: null,
      allowedWorkflowPaths,
    });
  }
  const evaluated = candidates.map((check) =>
    trustedCheckRunFor(check, sha, allowedWorkflowPaths),
  );
  return evaluated.find((check) => check.ok) || evaluated[0];
}

export function evaluateLatestMergedPrForMain({ mainSha, merged }) {
  if (!merged?.head?.sha) return { ok: false, error: "no merged PR found" };
  if (!merged.merge_commit_sha) {
    return {
      ok: false,
      pr: merged.number,
      headSha: merged.head.sha,
      error: "merged PR has no merge commit SHA",
    };
  }
  if (merged.merge_commit_sha !== mainSha) {
    return {
      ok: false,
      pr: merged.number,
      headSha: merged.head.sha,
      mergeCommitSha: merged.merge_commit_sha,
      currentMainSha: mainSha,
      reason:
        "origin/main has advanced past the latest merged PR; require a new PR merge so launch QA is tied to current main.",
    };
  }
  return {
    ok: true,
    pr: merged.number,
    headSha: merged.head.sha,
    checkedSha: mainSha,
    mergeCommitSha: merged.merge_commit_sha,
  };
}

function checkGitHubSecuritySettings() {
  const repo = ghJSON(`/repos/${REPO}`);
  if (!repo.ok) return repo;

  const settings = repo.value.security_and_analysis || {};
  const requiredSettings = Object.fromEntries(
    REQUIRED_GITHUB_SECURITY_SETTINGS.map((name) => [
      name,
      settings[name]?.status === "enabled",
    ]),
  );

  const codeScanningAlerts = ghJSON(
    `/repos/${REPO}/code-scanning/alerts?state=open&per_page=100`,
  );
  const secretScanningAlerts = ghJSON(
    `/repos/${REPO}/secret-scanning/alerts?state=open&per_page=100`,
  );
  const dependabotAlerts = ghJSON(
    `/repos/${REPO}/dependabot/alerts?state=open&per_page=100`,
  );

  return {
    ok:
      Object.values(requiredSettings).every(Boolean) &&
      codeScanningAlerts.ok &&
      secretScanningAlerts.ok &&
      dependabotAlerts.ok &&
      codeScanningAlerts.value.length === 0 &&
      secretScanningAlerts.value.length === 0 &&
      dependabotAlerts.value.length === 0,
    requiredSettings,
    openAlerts: {
      codeScanning: codeScanningAlerts.ok
        ? codeScanningAlerts.value.length
        : null,
      secretScanning: secretScanningAlerts.ok
        ? secretScanningAlerts.value.length
        : null,
      dependabot: dependabotAlerts.ok ? dependabotAlerts.value.length : null,
    },
    errors: {
      codeScanning: codeScanningAlerts.ok
        ? undefined
        : codeScanningAlerts.error,
      secretScanning: secretScanningAlerts.ok
        ? undefined
        : secretScanningAlerts.error,
      dependabot: dependabotAlerts.ok ? undefined : dependabotAlerts.error,
    },
  };
}

function checkLatestMergedPrGate() {
  const originMain = run("git", ["rev-parse", "origin/main"]);
  if (!originMain.ok) {
    return {
      ok: false,
      error: originMain.stderr || originMain.stdout || originMain.error,
    };
  }
  const mainSha = originMain.stdout.trim();
  const pulls = run("gh", [
    "api",
    "-H",
    "Accept: application/vnd.github+json",
    `/repos/${REPO}/pulls?state=closed&sort=updated&direction=desc&per_page=20`,
  ]);
  if (!pulls.ok) return { ok: false, error: pulls.stderr || pulls.stdout };
  const merged = JSON.parse(pulls.stdout).find((pr) => pr.merged_at);
  const latestPr = evaluateLatestMergedPrForMain({ mainSha, merged });
  if (!latestPr.ok) return latestPr;

  const checkedSha = latestPr.checkedSha;
  const runs = run("gh", [
    "api",
    "-H",
    "Accept: application/vnd.github+json",
    `/repos/${REPO}/commits/${checkedSha}/check-runs?per_page=100`,
  ]);
  if (!runs.ok)
    return { ok: false, pr: merged.number, error: runs.stderr || runs.stdout };
  const checkRuns = JSON.parse(runs.stdout).check_runs || [];
  const required = findTrustedCheckRun(
    checkRuns,
    REQUIRED_MAIN_GATE_CHECK,
    checkedSha,
    REQUIRED_MAIN_GATE_WORKFLOW_PATHS,
  );
  return {
    ok: required.ok === true,
    pr: latestPr.pr,
    headSha: latestPr.headSha,
    mergeCommitSha: latestPr.mergeCommitSha,
    checkedSha,
    openburnbarPr: required,
  };
}

function checkMainRequiredGate() {
  const originMain = run("git", ["rev-parse", "origin/main"]);
  if (!originMain.ok) {
    return {
      ok: false,
      error: originMain.stderr || originMain.stdout || originMain.error,
    };
  }
  const sha = originMain.stdout.trim();
  const runs = run("gh", [
    "api",
    "-H",
    "Accept: application/vnd.github+json",
    `/repos/${REPO}/commits/${sha}/check-runs?per_page=100`,
  ]);
  if (!runs.ok) return { ok: false, sha, error: runs.stderr || runs.stdout };
  const checkRuns = JSON.parse(runs.stdout).check_runs || [];
  const required = findTrustedCheckRun(
    checkRuns,
    REQUIRED_MAIN_GATE_CHECK,
    sha,
    REQUIRED_MAIN_GATE_WORKFLOW_PATHS,
  );
  return {
    ok: required.ok === true,
    sha,
    openburnbarPr: required,
  };
}

function checkMainCodeQL() {
  const originMain = run("git", ["rev-parse", "origin/main"]);
  if (!originMain.ok) {
    return {
      ok: false,
      error: originMain.stderr || originMain.stdout || originMain.error,
    };
  }
  const sha = originMain.stdout.trim();
  const runs = run("gh", [
    "api",
    "-H",
    "Accept: application/vnd.github+json",
    `/repos/${REPO}/commits/${sha}/check-runs?per_page=100`,
  ]);
  if (!runs.ok) return { ok: false, sha, error: runs.stderr || runs.stdout };

  const checkRuns = JSON.parse(runs.stdout).check_runs || [];
  const checks = REQUIRED_CODEQL_CHECKS.map((name) => {
    const check = findTrustedCheckRun(
      checkRuns,
      name,
      sha,
      REQUIRED_CODEQL_WORKFLOW_PATHS,
    );
    return { name, ...check };
  });
  return {
    ok: checks.every((check) => check.ok === true),
    sha,
    checks,
  };
}

function pickCheck(check) {
  return {
    status: check.status,
    conclusion: check.conclusion,
    completedAt: check.completed_at,
  };
}

function checkCloudRun() {
  const serviceStates = REQUIRED_CLOUD_RUN_SERVICES.map(describeCloudRunService);
  const retiredRelay = describeCloudRunService(
    RETIRED_HERMES_REALTIME_RELAY_SERVICE,
  );
  const retiredRelayCheck = evaluateRetiredCloudRunServiceAbsence(
    RETIRED_HERMES_REALTIME_RELAY_SERVICE,
    retiredRelay,
  );
  return {
    ok:
      serviceStates.every((service) => service.exists && service.ready) &&
      retiredRelayCheck.absent,
    services: serviceStates,
    retiredServices: [retiredRelayCheck],
  };
}

export function evaluateCloudRunServiceReadiness(name, service) {
  const ready = (service?.status?.conditions || []).some(
    (condition) => condition.type === "Ready" && condition.status === "True",
  );
  return {
    name,
    exists: true,
    ready,
    url: service?.status?.url || null,
    serviceAccount: service?.spec?.template?.spec?.serviceAccountName || null,
    ingress: service?.metadata?.annotations?.["run.googleapis.com/ingress"] ||
      null,
  };
}

export function evaluateRetiredCloudRunServiceAbsence(name, state) {
  const exists =
    state.exists === true ||
    state.missing === false ||
    Boolean(state.service);
  return {
    name,
    absent: !exists && !state.error,
    ready: exists ? (state.ready ?? null) : null,
    url: state.url || state.service?.status?.url || null,
    error: state.error,
  };
}

function describeCloudRunService(name) {
  const result = run("gcloud", [
    "run",
    "services",
    "describe",
    name,
    "--project",
    PROJECT,
    "--region",
    REGION,
    "--format=json",
  ]);
  if (!result.ok) {
    const error = compactCommandOutput(
      result.stderr || result.stdout || result.error || "",
    );
    if (/not found|not_found|does not exist|cannot find service|NOT_FOUND/i.test(error)) {
      return { name, exists: false, ready: false, url: null };
    }
    return { name, exists: false, ready: false, url: null, error };
  }
  let service;
  try {
    service = JSON.parse(result.stdout);
  } catch (error) {
    return {
      name,
      exists: false,
      ready: false,
      url: null,
      error: `invalid Cloud Run service JSON: ${error.message}`,
    };
  }
  return {
    ...evaluateCloudRunServiceReadiness(name, service),
    name,
    exists: true,
  };
}

function compactCommandOutput(text) {
  return String(text || "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, 6)
    .join("\n")
    .slice(0, 1200);
}

function parseFirstJsonObject(output) {
  const text = String(output || "");
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end === -1 || end < start) {
    return { ok: false, error: "no JSON object found in command output" };
  }
  try {
    return { ok: true, value: JSON.parse(text.slice(start, end + 1)) };
  } catch (error) {
    return {
      ok: false,
      error: `invalid JSON object in command output: ${error.message}`,
    };
  }
}

function checkFirestoreDisasterRecovery() {
  const result = run("bash", ["scripts/ops/verify-firestore-disaster-recovery.sh"], {
    env: { ...process.env, FIRESTORE_DR_JSON_ONLY: "1" },
    timeout: 180_000,
  });
  const parsed = parseFirstJsonObject(result.stdout);
  if (!result.ok) {
    return {
      ok: false,
      ...(parsed.ok ? parsed.value : {}),
      error: compactCommandOutput(result.stderr || result.stdout || result.error || parsed.error),
    };
  }
  if (!parsed.ok) {
    return { ok: false, error: parsed.error };
  }
  return {
    ...parsed.value,
    ok: parsed.value?.ok === true,
  };
}

export function requiredVerifiableAlertChannels(...alertChecks) {
  const byName = new Map();
  for (const alertCheck of alertChecks) {
    for (const policy of alertCheck?.required || []) {
      for (const channel of policy.notificationChannelStatuses || []) {
        if (!VERIFIABLE_CHANNEL_TYPES.has(channel.type)) continue;
        if (!channel.name) continue;
        if (!byName.has(channel.name)) {
          byName.set(channel.name, {
            name: channel.name,
            type: channel.type,
            target: channel.target || channel.emailAddress || null,
            policyDisplayNames: [],
          });
        }
        byName.get(channel.name).policyDisplayNames.push(policy.displayName);
      }
    }
  }
  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));
}

function parseEvidenceTime(value) {
  if (typeof value !== "string" || value.trim() === "") return null;
  const millis = Date.parse(value);
  return Number.isFinite(millis) ? new Date(millis) : null;
}

export function evaluateAlertDeliverabilityEvidence(evidence, requiredChannels, options = {}) {
  const now = options.now instanceof Date ? options.now : new Date(options.now || Date.now());
  const ttlHours = Number(options.ttlHours ?? ALERT_DELIVERY_TTL_HOURS);
  const ttlMs = ttlHours * 60 * 60 * 1000;
  const failures = [];
  const generatedAt = parseEvidenceTime(evidence?.generatedAt);
  const channels = Array.isArray(evidence?.channels) ? evidence.channels : [];

  if (!Number.isFinite(ttlHours) || ttlHours <= 0) {
    failures.push("alert-delivery TTL must be a positive number of hours");
  }
  if (!generatedAt) {
    failures.push("evidence.generatedAt is missing or invalid");
  } else if (now.getTime() - generatedAt.getTime() > ttlMs) {
    failures.push(`evidence.generatedAt is older than ${ttlHours}h`);
  }
  if (!Array.isArray(requiredChannels) || requiredChannels.length === 0) {
    failures.push("no verifiable alert notification channels were present in ops/billing alert checks");
  }

  const evidenceByName = new Map(
    channels
      .filter((channel) => typeof channel?.name === "string")
      .map((channel) => [channel.name, channel]),
  );
  const checkedChannels = (requiredChannels || []).map((required) => {
    const channel = evidenceByName.get(required.name);
    const deliveredAt = parseEvidenceTime(channel?.deliveredAt || channel?.confirmedAt);
    const problems = [];
    if (!channel) {
      problems.push("missing from evidence");
    } else {
      if (channel.deliveryConfirmed !== true) {
        problems.push("deliveryConfirmed is not true");
      }
      if (!deliveredAt) {
        problems.push("deliveredAt is missing or invalid");
      } else if (now.getTime() - deliveredAt.getTime() > ttlMs) {
        problems.push(`deliveredAt is older than ${ttlHours}h`);
      }
      if (required.type && channel.type && channel.type !== required.type) {
        problems.push(`type mismatch: expected ${required.type}, saw ${channel.type}`);
      }
    }
    failures.push(...problems.map((problem) => `${required.name}: ${problem}`));
    return {
      ...required,
      deliveredAt: deliveredAt?.toISOString() || null,
      verifiedBy: channel?.verifiedBy || null,
      ok: problems.length === 0,
      problems,
    };
  });

  return {
    ok: failures.length === 0,
    generatedAt: generatedAt?.toISOString() || evidence?.generatedAt || null,
    ttlHours,
    requiredChannels: checkedChannels,
    failures,
  };
}

function checkAlertDeliverabilityEvidence(alertChecks) {
  const requiredChannels = requiredVerifiableAlertChannels(...alertChecks);
  if (!existsSync(ALERT_DELIVERY_EVIDENCE_PATH)) {
    return {
      ok: false,
      path: ALERT_DELIVERY_EVIDENCE_PATH,
      requiredChannels,
      failures: [`missing ${ALERT_DELIVERY_EVIDENCE_PATH}`],
    };
  }

  let evidence;
  try {
    evidence = JSON.parse(readFileSync(ALERT_DELIVERY_EVIDENCE_PATH, "utf8"));
  } catch (error) {
    return {
      ok: false,
      path: ALERT_DELIVERY_EVIDENCE_PATH,
      requiredChannels,
      failures: [`invalid JSON: ${error.message}`],
    };
  }

  return {
    path: ALERT_DELIVERY_EVIDENCE_PATH,
    ...evaluateAlertDeliverabilityEvidence(evidence, requiredChannels),
  };
}

function checkRunnerReadyz() {
  const describe = run("gcloud", [
    "run",
    "services",
    "describe",
    "openburnbar-quota-runner",
    "--project",
    PROJECT,
    "--region",
    REGION,
    "--format=value(status.url)",
  ]);
  if (!describe.ok)
    return { ok: false, error: describe.stderr || describe.stdout };
  const url = describe.stdout.trim();
  const curl = run("curl", ["-fsS", "-m", "10", `${url}/readyz`], {
    timeout: 15_000,
  });
  return {
    ok: curl.ok,
    url,
    body: curl.ok ? curl.stdout.trim() : undefined,
    error: curl.ok ? undefined : curl.stderr || curl.stdout,
  };
}

function checkRedis() {
  const result = run("gcloud", [
    "redis",
    "instances",
    "describe",
    RETIRED_HERMES_REALTIME_REDIS_INSTANCE,
    "--project",
    PROJECT,
    "--region",
    REGION,
    "--format=json",
  ]);
  if (!result.ok) {
    const error = result.stderr || result.stdout || result.error || "";
    const notFound =
      error.includes("NOT_FOUND") || error.includes("was not found");
    return {
      ok: notFound,
      name: RETIRED_HERMES_REALTIME_REDIS_INSTANCE,
      state: notFound ? "absent" : "unknown",
      retired: true,
      error: notFound ? undefined : error,
    };
  }
  const redis = JSON.parse(result.stdout);
  return {
    ok: false,
    name: redis?.name || null,
    tier: redis?.tier || null,
    state: redis?.state || null,
    memorySizeGb: redis?.memorySizeGb || null,
    redisVersion: redis?.redisVersion || null,
    connectMode: redis?.connectMode || null,
    authEnabled: redis?.authEnabled === true,
    transitEncryptionMode: redis?.transitEncryptionMode || null,
    redisHost: redis?.host || null,
    retired: true,
    error:
      "Retired Hermes realtime Redis exists; delete it before declaring the commercial launch gate clean.",
  };
}

function checkFunctionHostedQuotaRuntime(fn, cloudRunURL) {
  const result = run("gcloud", [
    "functions",
    "describe",
    fn.id,
    "--gen2",
    "--region",
    REGION,
    "--project",
    PROJECT,
    "--format=json",
  ]);
  if (!result.ok) {
    return {
      id: fn.id,
      ok: false,
      error: result.stderr || result.stdout || result.error,
    };
  }

  const details = JSON.parse(result.stdout);
  const env = details.serviceConfig?.environmentVariables || {};
  const secretEnvVarNames = (
    details.serviceConfig?.secretEnvironmentVariables || []
  )
    .map((entry) => entry.key)
    .sort();
  const envChecks = Object.entries(REQUIRED_HOSTED_QUOTA_ENV).map(
    ([name, expected]) => ({
      name,
      ok: env[name] === expected,
      actual: env[name] ?? null,
      expected,
    }),
  );
  const runnerURLCheck = evaluateHostedQuotaRunnerEndpoint({
    configuredURL: env.HOSTED_QUOTA_RUNNER_URL,
    allowedHosts: env.HOSTED_QUOTA_RUNNER_ALLOWED_HOSTS,
    cloudRunURL,
  });
  const runnerTokenCheck = {
    ok:
      !fn.requiresRunnerToken ||
      secretEnvVarNames.includes("HOSTED_QUOTA_RUNNER_TOKEN"),
    required: fn.requiresRunnerToken,
    present: secretEnvVarNames.includes("HOSTED_QUOTA_RUNNER_TOKEN"),
  };

  return {
    id: fn.id,
    ok:
      envChecks.every((check) => check.ok) &&
      runnerURLCheck.ok &&
      runnerTokenCheck.ok,
    envChecks,
    runnerURL: runnerURLCheck,
    runnerTokenSecret: runnerTokenCheck,
    secretEnvVarNames,
  };
}

function checkHostedQuotaRuntime() {
  const runner = run("gcloud", [
    "run",
    "services",
    "describe",
    "openburnbar-quota-runner",
    "--region",
    REGION,
    "--project",
    PROJECT,
    "--format=json",
  ]);
  let runnerConfig = {
    ok: false,
    error: runner.stderr || runner.stdout || runner.error,
  };
  let runnerURL;
  if (runner.ok) {
    const service = JSON.parse(runner.stdout);
    runnerURL = service.status?.url;
    const secretEnvVarNames = (service.spec?.template?.spec?.containers || [])
      .flatMap((container) => container.env || [])
      .filter((entry) => entry.valueFrom?.secretKeyRef?.name)
      .map((entry) => entry.name)
      .sort();
    runnerConfig = {
      ok: secretEnvVarNames.includes("RUNNER_SHARED_SECRET"),
      url: runnerURL || null,
      secretEnvVarNames,
    };
  }
  const functions = REQUIRED_HOSTED_QUOTA_FUNCTIONS.map((fn) =>
    checkFunctionHostedQuotaRuntime(fn, runnerURL),
  );

  return {
    ok: functions.every((fn) => fn.ok) && runnerConfig.ok,
    functions,
    runner: runnerConfig,
  };
}

function deployedFunctionEnvironment(functionName) {
  const result = run("gcloud", [
    "functions",
    "describe",
    functionName,
    "--gen2",
    "--region",
    REGION,
    "--project",
    PROJECT,
    "--format=json",
  ]);
  if (!result.ok) {
    return {
      ok: false,
      functionName,
      error: result.stderr || result.stdout || result.error,
    };
  }
  const details = JSON.parse(result.stdout);
  return {
    ok: true,
    functionName,
    env: details.serviceConfig?.environmentVariables || {},
    secretEnvVarNames: (details.serviceConfig?.secretEnvironmentVariables || [])
      .map((entry) => entry.key)
      .sort(),
  };
}

function checkCommercialBillingRuntime() {
  const checkout = deployedFunctionEnvironment(
    "createStripeBurnBarProCheckoutSession",
  );
  const googlePlay = deployedFunctionEnvironment(
    "verifyGooglePlayBurnBarProSubscription",
  );
  const googlePlayTopUp = deployedFunctionEnvironment(
    "verifyGooglePlayCloudProTopUp",
  );
  const googlePlayRtdn = deployedFunctionEnvironment(
    "googlePlayDeveloperNotifications",
  );
  const appStoreTopUp = deployedFunctionEnvironment("verifyCloudProTopUp");
  const webhook = deployedFunctionEnvironment("stripeBurnBarProWebhook");

  const envSources = [
    checkout,
    googlePlay,
    googlePlayTopUp,
    googlePlayRtdn,
    appStoreTopUp,
  ].filter((source) => source.ok);
  const mergedEnv = Object.assign(
    {},
    ...envSources.map((source) => source.env),
  );
  const envRequirements = evaluateEnvRequirements(
    mergedEnv,
    REQUIRED_COMMERCIAL_ENV_VALUES,
    REQUIRED_COMMERCIAL_ENV_PRESENT,
  );

  const stripeSecretNames = new Set([
    ...(checkout.secretEnvVarNames || []),
    ...(webhook.secretEnvVarNames || []),
  ]);
  const stripeSecrets = {
    ok:
      stripeSecretNames.has("STRIPE_SECRET_KEY") &&
      stripeSecretNames.has("STRIPE_WEBHOOK_SECRET"),
    present: [...stripeSecretNames].sort(),
    required: ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"],
  };

  return {
    ok:
      checkout.ok &&
      googlePlay.ok &&
      googlePlayTopUp.ok &&
      googlePlayRtdn.ok &&
      appStoreTopUp.ok &&
      webhook.ok &&
      envRequirements.ok &&
      stripeSecrets.ok,
    functions: {
      checkout,
      googlePlay,
      googlePlayTopUp,
      googlePlayRtdn,
      appStoreTopUp,
      webhook,
    },
    envRequirements,
    stripeSecrets,
  };
}

export function evaluateElderWandHostedSearchRuntime(runtime) {
  if (!runtime.ok) {
    return {
      ok: false,
      functionName: runtime.functionName || ELDER_WAND_HOSTED_SEARCH_FUNCTION,
      error: runtime.error,
    };
  }

  const envChecks = Object.entries(REQUIRED_ELDER_WAND_HOSTED_SEARCH_ENV).map(
    ([name, expected]) => ({
      name,
      ok: runtime.env?.[name] === expected,
      actual: runtime.env?.[name] ?? null,
      expected,
    }),
  );
  const secretNames = new Set(runtime.secretEnvVarNames || []);
  const secretChecks = REQUIRED_ELDER_WAND_HOSTED_SEARCH_SECRETS.map((name) => ({
    name,
    ok: secretNames.has(name),
  }));
  return {
    ok:
      envChecks.every((check) => check.ok) &&
      secretChecks.every((check) => check.ok),
    functionName: runtime.functionName,
    envChecks,
    secretChecks,
    secretEnvVarNames: [...secretNames].sort(),
  };
}

function checkElderWandHostedSearchRuntime() {
  return evaluateElderWandHostedSearchRuntime(
    deployedFunctionEnvironment(ELDER_WAND_HOSTED_SEARCH_FUNCTION),
  );
}

function checkRemoteConfigCaps() {
  const tempDir = mkdtempSync(join(tmpdir(), "openburnbar-remote-config-"));
  const tempFile = join(tempDir, "remote-config.json");
  const result = run(
    "firebase",
    ["remoteconfig:get", "--project", PROJECT, "--output", tempFile],
    {
      timeout: 60_000,
      // Firebase CLI authenticates this request with local ADC in operator
      // environments. Google requires an explicit quota project for the
      // Remote Config API, even when the access token already belongs to a
      // principal that can read the target project.
      env: {
        ...process.env,
        GOOGLE_CLOUD_QUOTA_PROJECT:
          process.env.GOOGLE_CLOUD_QUOTA_PROJECT || PROJECT,
      },
    },
  );
  try {
    if (!result.ok) {
      return {
        ok: false,
        error: result.stderr || result.stdout || result.error,
      };
    }
    const template = JSON.parse(readFileSync(tempFile, "utf8"));
    return evaluateRemoteConfigDefaults(
      template,
      REQUIRED_REMOTE_CONFIG_DEFAULTS,
    );
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

function checkFirebaseFunctionsInventory() {
  const result = run("firebase", [
    "functions:list",
    "--project",
    PROJECT,
    "--json",
  ]);
  if (!result.ok) return { ok: false, error: result.stderr || result.stdout };
  const payload = JSON.parse(result.stdout);
  const ids = (payload.result || []).map((fn) => fn.id).sort();
  const idSet = new Set(ids);
  const missing = REQUIRED_FIREBASE_FUNCTIONS.filter((id) => !idSet.has(id));
  const forbiddenPresent = FORBIDDEN_FIREBASE_FUNCTIONS.filter((id) =>
    idSet.has(id),
  );
  return {
    ok: missing.length === 0 && forbiddenPresent.length === 0,
    count: ids.length,
    missing,
    forbiddenPresent,
  };
}

function checkLaunchEvidence() {
  if (!existsSync(LAUNCH_EVIDENCE_MANIFEST)) {
    return {
      ok: true,
      skipped: true,
      path: LAUNCH_EVIDENCE_MANIFEST,
      reason: "Launch evidence manifest is not present yet.",
      stages: {
        paidProof: { ok: false, skipped: true },
        publicRelease: { ok: false, skipped: true },
        done: { ok: false, skipped: true },
      },
    };
  }

  let manifest;
  try {
    manifest = JSON.parse(readFileSync(LAUNCH_EVIDENCE_MANIFEST, "utf8"));
  } catch (error) {
    return {
      ok: false,
      path: LAUNCH_EVIDENCE_MANIFEST,
      error: error.message,
    };
  }

  const paidProof = validateLaunchEvidenceBundle(manifest, {
    manifestPath: LAUNCH_EVIDENCE_MANIFEST,
    stage: "paid-proof",
  });
  const publicRelease = validateLaunchEvidenceBundle(manifest, {
    manifestPath: LAUNCH_EVIDENCE_MANIFEST,
    stage: "public-release",
  });
  const done = validateLaunchEvidenceBundle(manifest, {
    manifestPath: LAUNCH_EVIDENCE_MANIFEST,
    stage: "done",
    requireDoneStamp: true,
  });

  return {
    ok: paidProof.ok,
    path: LAUNCH_EVIDENCE_MANIFEST,
    stages: {
      paidProof,
      publicRelease,
      done,
    },
  };
}

export function verdict(checks) {
  const failures = Object.entries(checks)
    .filter(([, value]) => value?.ok === false)
    .map(([name]) => name);
  if (failures.length) {
    return { status: "NO_GO", reason: `failed checks: ${failures.join(", ")}` };
  }
  const appStore = checks.appStore;
  if (appStore.state === "WAITING_FOR_REVIEW") {
    return {
      status: "WAITING_ON_APPLE",
      reason: "Apple review is still pending.",
    };
  }
  if (appStore.state === REQUIRED_IOS_STATE) {
    return {
      status: "READY_FOR_MANUAL_RELEASE",
      reason:
        "Run release-approved-ios with the exact confirmation token, then run live paid proof.",
      confirmation: `${appStore.versionString}:${appStore.versionId}`,
    };
  }
  if (appStore.state === LIVE_IOS_STATE) {
    const launchEvidence = checks.launchEvidence?.stages || {};
    if (launchEvidence.done?.ok === true) {
      return {
        status: "LAUNCH_DONE",
        reason: "Final launch evidence bundle and LAUNCH_DONE.md are complete.",
      };
    }
    if (launchEvidence.publicRelease?.ok === true) {
      return {
        status: "READY_FOR_PUBLIC_RELEASE",
        reason:
          "Canary evidence passed; publish public launch and final proof bundle.",
      };
    }
    if (launchEvidence.paidProof?.ok === true) {
      return {
        status: "READY_FOR_CANARY",
        reason:
          "Live paid proofs and cross-channel matrix are captured; start the controlled canary.",
      };
    }
    return {
      status: "READY_FOR_LIVE_PAID_PROOF",
      reason:
        "Run prove:paid-tier for Apple, Stripe, and Google Play Cloud/Cloud Pro users, plus Apple/Google Play Ultra users, before canary.",
    };
  }
  return {
    status: "NO_GO",
    reason: `unhandled App Store state ${appStore.state}`,
  };
}

async function main() {
  const appStore = checkAppStore();
  const opsAlerts = checkOpsAlerts();
  const billingAlerts = checkBillingAlerts();
  const checks = {
    repo: checkRepo(),
    appStore,
    appStoreServerNotifications: checkAppStoreServerNotifications(appStore),
    firebaseAppCheck: checkFirebaseAppCheckEnforcement(),
    branchProtection: checkProtection(),
    githubSecurity: checkGitHubSecuritySettings(),
    mainRequiredGate: checkMainRequiredGate(),
    mainCodeQL: checkMainCodeQL(),
    latestMergedPrGate: checkLatestMergedPrGate(),
    cloudRun: checkCloudRun(),
    runnerReadyz: checkRunnerReadyz(),
    redis: checkRedis(),
    hostedQuotaRuntime: checkHostedQuotaRuntime(),
    commercialBillingRuntime: checkCommercialBillingRuntime(),
    elderWandHostedSearchRuntime: checkElderWandHostedSearchRuntime(),
    remoteConfigCaps: checkRemoteConfigCaps(),
    opsAlerts,
    billingAlerts,
    alertDeliverability: checkAlertDeliverabilityEvidence([opsAlerts, billingAlerts]),
    firestoreDisasterRecovery: checkFirestoreDisasterRecovery(),
    firebaseFunctionsInventory: checkFirebaseFunctionsInventory(),
    launchEvidence: checkLaunchEvidence(),
  };
  const result = {
    generatedAt: new Date().toISOString(),
    verdict: verdict(checks),
    checks,
  };
  console.log(JSON.stringify(result, null, 2));
  process.exitCode = result.verdict.status === "NO_GO" ? 1 : 0;
}

const isMainModule = process.argv[1] === fileURLToPath(import.meta.url);
if (isMainModule) {
  main().catch((error) => {
    console.error(JSON.stringify({ ok: false, error: error.message }, null, 2));
    process.exitCode = 1;
  });
}
