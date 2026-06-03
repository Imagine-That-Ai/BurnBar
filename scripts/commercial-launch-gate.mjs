#!/usr/bin/env node
/**
 * Commercial launch gate for OpenBurnBar.
 *
 * This is a read-only operator command. It gathers the live state that decides
 * whether the commercial launch can proceed, then prints one JSON verdict.
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import process from "node:process";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { evaluateFirebaseAppCheckEnforcement } from "./lib/evaluate-firebase-app-check-enforcement.mjs";
import { checkBillingAlerts, checkOpsAlerts } from "./lib/ops-alerts-gate.mjs";
import { validateLaunchEvidenceBundle } from "./validate-launch-evidence-bundle.mjs";

export { evaluateFirebaseAppCheckEnforcement };

const REPO = process.env.OPENBURNBAR_GITHUB_REPO || "Imagine-That-Ai/BurnBar";
const PROJECT = process.env.OPENBURNBAR_FIREBASE_PROJECT || "burnbar";
const REGION = process.env.OPENBURNBAR_GCP_REGION || "us-central1";
const REQUIRED_IOS_STATE = "PENDING_DEVELOPER_RELEASE";
const LIVE_IOS_STATE = "READY_FOR_SALE";
const LAUNCH_EVIDENCE_MANIFEST =
  process.env.OPENBURNBAR_LAUNCH_EVIDENCE_MANIFEST ||
  "launch-evidence/final-launch-evidence.json";
const LEGACY_HOSTED_QUOTA_PRODUCT_ID =
  "com.openburnbar.hostedQuotaSync.cloud.monthly";
export const COMMERCIAL_PRODUCTS = Object.freeze({
  legacyHostedQuota: LEGACY_HOSTED_QUOTA_PRODUCT_ID,
  cloudMonthly: "com.openburnbar.pro.monthly",
  cloudAnnual: "com.openburnbar.pro.annual",
  cloudProMonthly: "com.openburnbar.proMax.v2.monthly",
  legacyAppleCloudProBundleMonthly: "com.openburnbar.proMax.bundle.monthly",
  cloudProAnnual: "com.openburnbar.proMax.annual",
  agentControlActions100: "com.openburnbar.agentControl.actions100",
  flooRelay50GB: "com.openburnbar.floo.relay50gb",
});
export const GOOGLE_PLAY_PRODUCTS = Object.freeze({
  cloudMonthly: "com.openburnbar.pro.monthly",
  cloudAnnual: "com.openburnbar.pro.annual",
  cloudProMonthly: "com.openburnbar.promax.v2.monthly",
  cloudProAnnual: "com.openburnbar.promax.annual",
  agentControlActions100: "com.openburnbar.agentcontrol.actions100",
  flooRelay50GB: "com.openburnbar.floo.relay50gb",
});
const REQUIRED_APP_STORE_SUBSCRIPTION_PRODUCT_IDS = [
  COMMERCIAL_PRODUCTS.cloudMonthly,
  COMMERCIAL_PRODUCTS.cloudAnnual,
  COMMERCIAL_PRODUCTS.cloudProMonthly,
  COMMERCIAL_PRODUCTS.cloudProAnnual,
];
const REQUIRED_TOP_UP_PRODUCT_IDS = [
  COMMERCIAL_PRODUCTS.agentControlActions100,
  COMMERCIAL_PRODUCTS.flooRelay50GB,
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
const RETIRED_HERMES_REALTIME_REDIS_INSTANCE =
  process.env.OPENBURNBAR_RETIRED_REDIS_INSTANCE_NAME ||
  "hermes-realtime-relay-redis-prod-secure";
const REQUIRED_CODEQL_CHECKS = [
  "Analyze (swift)",
  "Analyze (javascript-typescript)",
  "Analyze (python)",
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
const REQUIRED_COMMERCIAL_ENV_VALUES = {
  STRIPE_BURNBAR_PRO_PRICE_ID: "alias:STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID",
  BURNBAR_PRO_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudMonthly,
  BURNBAR_PRO_ANNUAL_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudAnnual,
  BURNBAR_PRO_MAX_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudProMonthly,
  BURNBAR_PRO_MAX_ANNUAL_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudProAnnual,
  AGENT_CONTROL_100_ACTIONS_PRODUCT_ID:
    COMMERCIAL_PRODUCTS.agentControlActions100,
  FLOO_RELAY_50GB_PRODUCT_ID: COMMERCIAL_PRODUCTS.flooRelay50GB,
  GOOGLE_PLAY_CLOUD_MONTHLY_PRODUCT_ID: GOOGLE_PLAY_PRODUCTS.cloudMonthly,
  GOOGLE_PLAY_CLOUD_ANNUAL_PRODUCT_ID: GOOGLE_PLAY_PRODUCTS.cloudAnnual,
  GOOGLE_PLAY_CLOUD_PRO_MONTHLY_PRODUCT_ID:
    GOOGLE_PLAY_PRODUCTS.cloudProMonthly,
  GOOGLE_PLAY_CLOUD_PRO_ANNUAL_PRODUCT_ID: GOOGLE_PLAY_PRODUCTS.cloudProAnnual,
  GOOGLE_PLAY_AGENT_CONTROL_100_ACTIONS_PRODUCT_ID:
    GOOGLE_PLAY_PRODUCTS.agentControlActions100,
  GOOGLE_PLAY_FLOO_RELAY_50GB_PRODUCT_ID: GOOGLE_PLAY_PRODUCTS.flooRelay50GB,
};
const REQUIRED_COMMERCIAL_ENV_PRESENT = [
  "STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID",
  "STRIPE_BURNBAR_CLOUD_ANNUAL_PRICE_ID",
  "STRIPE_BURNBAR_CLOUD_PRO_MONTHLY_PRICE_ID",
  "STRIPE_BURNBAR_CLOUD_PRO_ANNUAL_PRICE_ID",
  "STRIPE_AGENT_CONTROL_100_ACTIONS_PRICE_ID",
  "STRIPE_FLOO_RELAY_50GB_PRICE_ID",
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
};

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || process.cwd(),
    env: options.env || process.env,
    encoding: "utf8",
    timeout: options.timeout ?? 120_000,
  });
  return {
    ok: result.status === 0,
    status: result.status,
    stdout: result.stdout || "",
    stderr: result.stderr || "",
    error: result.error?.message,
  };
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

  const serviceName = `projects/${projectNumber.stdout.trim()}/services/firestore.googleapis.com`;
  const result = run(
    "curl",
    [
      "-fsS",
      "--connect-timeout",
      "15",
      "--max-time",
      "45",
      "--retry",
      "2",
      "--retry-delay",
      "2",
      "--retry-all-errors",
      "-H",
      `Authorization: Bearer ${token.stdout.trim()}`,
      "-H",
      `x-goog-user-project: ${PROJECT}`,
      `https://firebaseappcheck.googleapis.com/v1beta/${serviceName}`,
    ],
    { timeout: 180_000 },
  );
  if (!result.ok) {
    return {
      ok: false,
      serviceName,
      error: result.stderr || result.stdout || result.error,
    };
  }

  const config = JSON.parse(result.stdout);
  return evaluateFirebaseAppCheckEnforcement({
    serviceName,
    enforcementMode: config.enforcementMode || null,
    updateTime: config.updateTime || null,
  });
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
  const checks = protection.required_status_checks?.contexts || [];
  return {
    ok:
      protection.enforce_admins?.enabled === true &&
      protection.allow_force_pushes?.enabled === false &&
      protection.allow_deletions?.enabled === false &&
      protection.required_pull_request_reviews
        ?.required_approving_review_count === 1 &&
      ["openburnbar-pr", ...REQUIRED_CODEQL_CHECKS].every((check) =>
        checks.includes(check),
      ),
    requiredChecks: checks,
    reviewCount:
      protection.required_pull_request_reviews
        ?.required_approving_review_count ?? 0,
    adminsEnforced: protection.enforce_admins?.enabled === true,
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
  if (!merged?.head?.sha) return { ok: false, error: "no merged PR found" };

  if (mainSha && merged.head.sha !== mainSha) {
    const ancestor = run("git", [
      "merge-base",
      "--is-ancestor",
      merged.head.sha,
      mainSha,
    ]);
    if (ancestor.ok) {
      return {
        ok: true,
        pr: merged.number,
        headSha: merged.head.sha,
        supersededByMain: mainSha,
        skipped: true,
        reason:
          "Latest merged PR head is already contained in a newer origin/main commit; mainRequiredGate is authoritative.",
        openburnbarPr: null,
        functionalQa: null,
      };
    }
  }

  if (merged.merge_commit_sha && merged.merge_commit_sha !== mainSha) {
    return {
      ok: true,
      pr: merged.number,
      headSha: merged.head.sha,
      mergeCommitSha: merged.merge_commit_sha,
      supersededByMainSha: mainSha,
      note: "Latest merged PR is not main HEAD; mainRequiredGate and mainCodeQL cover the current direct/admin landing commit.",
    };
  }

  const runs = run("gh", [
    "api",
    "-H",
    "Accept: application/vnd.github+json",
    `/repos/${REPO}/commits/${merged.head.sha}/check-runs`,
  ]);
  if (!runs.ok)
    return { ok: false, pr: merged.number, error: runs.stderr || runs.stdout };
  const checkRuns = JSON.parse(runs.stdout).check_runs || [];
  const required = checkRuns.find((check) => check.name === "openburnbar-pr");
  const functional = checkRuns.find((check) => check.name === "functional-qa");
  return {
    ok:
      required?.conclusion === "success" &&
      functional?.conclusion === "success",
    pr: merged.number,
    headSha: merged.head.sha,
    openburnbarPr: required ? pickCheck(required) : null,
    functionalQa: functional ? pickCheck(functional) : null,
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
  const required = checkRuns.find((check) => check.name === "openburnbar-pr");
  return {
    ok: required?.status === "completed" && required?.conclusion === "success",
    sha,
    openburnbarPr: required ? pickCheck(required) : null,
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
  const byName = new Map(checkRuns.map((check) => [check.name, check]));
  const checks = REQUIRED_CODEQL_CHECKS.map((name) => {
    const check = byName.get(name);
    return {
      name,
      ...(check
        ? pickCheck(check)
        : { status: "missing", conclusion: null, completedAt: null }),
    };
  });
  return {
    ok: checks.every(
      (check) => check.status === "completed" && check.conclusion === "success",
    ),
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
  const required = ["openburnbar-quota-runner"];
  const serviceStates = required.map(describeCloudRunService);
  const retiredRelay = describeCloudRunService(
    RETIRED_HERMES_REALTIME_RELAY_SERVICE,
  );
  const retiredRelayState = evaluateRetiredCloudRunServiceAbsence(
    RETIRED_HERMES_REALTIME_RELAY_SERVICE,
    retiredRelay,
  );
  return {
    ok:
      serviceStates.every((service) => service.exists && service.ready) &&
      retiredRelayState.absent,
    services: serviceStates,
    retiredServices: [retiredRelayState],
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
  return evaluateCloudRunServiceReadiness(name, service);
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

function compactCommandOutput(text) {
  return String(text || "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(0, 6)
    .join("\n")
    .slice(0, 1200);
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

function checkFunctionHostedQuotaRuntime(fn) {
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
  let runnerURL;
  try {
    runnerURL = new URL(env.HOSTED_QUOTA_RUNNER_URL || "");
  } catch {
    runnerURL = undefined;
  }

  const envChecks = Object.entries(REQUIRED_HOSTED_QUOTA_ENV).map(
    ([name, expected]) => ({
      name,
      ok: env[name] === expected,
      actual: env[name] ?? null,
      expected,
    }),
  );
  const runnerURLCheck = {
    ok: runnerURL?.protocol === "https:",
    host: runnerURL?.host || null,
  };
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
  const functions = REQUIRED_HOSTED_QUOTA_FUNCTIONS.map(
    checkFunctionHostedQuotaRuntime,
  );
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
  if (runner.ok) {
    const service = JSON.parse(runner.stdout);
    const secretEnvVarNames = (service.spec?.template?.spec?.containers || [])
      .flatMap((container) => container.env || [])
      .filter((entry) => entry.valueFrom?.secretKeyRef?.name)
      .map((entry) => entry.name)
      .sort();
    runnerConfig = {
      ok: secretEnvVarNames.includes("RUNNER_SHARED_SECRET"),
      secretEnvVarNames,
    };
  }

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
  const appStoreTopUp = deployedFunctionEnvironment("verifyCloudProTopUp");
  const webhook = deployedFunctionEnvironment("stripeBurnBarProWebhook");

  const envSources = [
    checkout,
    googlePlay,
    googlePlayTopUp,
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
      appStoreTopUp.ok &&
      webhook.ok &&
      envRequirements.ok &&
      stripeSecrets.ok,
    functions: {
      checkout,
      googlePlay,
      googlePlayTopUp,
      appStoreTopUp,
      webhook,
    },
    envRequirements,
    stripeSecrets,
  };
}

function checkRemoteConfigCaps() {
  const tempDir = mkdtempSync(join(tmpdir(), "openburnbar-remote-config-"));
  const tempFile = join(tempDir, "remote-config.json");
  const result = run(
    "firebase",
    ["remoteconfig:get", "--project", PROJECT, "--output", tempFile],
    { timeout: 60_000 },
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
        "Run prove:paid-tier for Apple, Stripe, and Google Play Cloud/Cloud Pro users before canary.",
    };
  }
  return {
    status: "NO_GO",
    reason: `unhandled App Store state ${appStore.state}`,
  };
}

async function main() {
  const appStore = checkAppStore();
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
    remoteConfigCaps: checkRemoteConfigCaps(),
    opsAlerts: checkOpsAlerts(),
    billingAlerts: checkBillingAlerts(),
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
