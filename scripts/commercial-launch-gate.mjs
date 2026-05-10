#!/usr/bin/env node
/**
 * Commercial launch gate for OpenBurnBar.
 *
 * This is a read-only operator command. It gathers the live state that decides
 * whether the commercial launch can proceed, then prints one JSON verdict.
 */

import { spawnSync } from "node:child_process";
import process from "node:process";
import { BILLING_ALERT_POLICIES } from "../functions/scripts/billing-alert-policy-definitions.mjs";

const REPO = process.env.OPENBURNBAR_GITHUB_REPO || "Imagine-That-Ai/BurnBar";
const PROJECT = process.env.OPENBURNBAR_FIREBASE_PROJECT || "burnbar";
const REGION = process.env.OPENBURNBAR_GCP_REGION || "us-central1";
const REQUIRED_IOS_STATE = "PENDING_DEVELOPER_RELEASE";
const LIVE_IOS_STATE = "READY_FOR_SALE";
const PRODUCT_ID = "com.openburnbar.hostedQuotaSync.monthly";
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
  "beginEntitlementBinding",
  "connectHostedQuotaAccount",
  "deleteUserCloudData",
  "deleteHostedQuotaCredentials",
  "deleteProviderAccount",
  "onUsageWritten",
  "rebuildRollups",
  "reconcileHostedEntitlementsDaily",
  "refreshAllProviderQuotas",
  "refreshProviderAccountQuota",
  "restoreHostedQuotaEntitlement",
  "searchStreams",
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
  HOSTED_QUOTA_PRODUCT_ID: PRODUCT_ID,
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
      throw new Error(`failed to read Firebase secret ${key}: ${result.stderr || result.stdout}`);
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
  const subscriptionMatches = status.subscription?.productId === PRODUCT_ID;
  return {
    ok:
      manualRelease &&
      buildReady &&
      subscriptionMatches &&
      ["WAITING_FOR_REVIEW", REQUIRED_IOS_STATE, LIVE_IOS_STATE].includes(state) &&
      ["WAITING_FOR_REVIEW", "APPROVED", "READY_FOR_SALE"].includes(subscriptionState),
    state,
    subscriptionState,
    manualRelease,
    buildReady,
    subscriptionMatches,
    versionString: status.iosVersion?.versionString,
    versionId: status.iosVersion?.id,
  };
}

function appStoreNotificationProof(environment) {
  const result = run(
    "node",
    ["tools/app-store-connect/asc-api.js", "test-server-notifications", environment],
    {
      env: secretEnv(),
      timeout: 90_000,
    }
  );
  const payload = result.stdout ? firstJSON(result.stdout) : null;
  const proof = payload?.results?.find(
    (item) => item.environment?.toLowerCase() === environment.toLowerCase()
  );
  return {
    ok: result.ok && proof?.delivered === true,
    requestStatus: proof?.requestStatus ?? null,
    requestOk: proof?.requestOk ?? false,
    hasToken: proof?.hasToken ?? false,
    delivered: proof?.delivered ?? false,
    firstSendAttemptResult: proof?.firstSendAttemptResult ?? null,
    sendAttempts: proof?.sendAttempts ?? [],
    error: proof?.error || (result.ok ? undefined : result.stderr || result.stdout || result.error),
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
        reason: "Production notification proof is required after App Store release.",
      };
  return {
    ok: sandbox.ok && production.ok,
    sandbox,
    productionRequired,
    production,
  };
}

function checkFirebaseAppCheckEnforcement() {
  const projectNumber = run("gcloud", [
    "projects",
    "describe",
    PROJECT,
    "--format=value(projectNumber)",
  ]);
  if (!projectNumber.ok) {
    return {
      ok: false,
      error: projectNumber.stderr || projectNumber.stdout || projectNumber.error,
    };
  }

  const token = run("gcloud", ["auth", "print-access-token"]);
  if (!token.ok) {
    return { ok: false, error: token.stderr || token.stdout || token.error };
  }

  const serviceName = `projects/${projectNumber.stdout.trim()}/services/firestore.googleapis.com`;
  const result = run("curl", [
    "-fsS",
    "-H",
    `Authorization: Bearer ${token.stdout.trim()}`,
    "-H",
    `x-goog-user-project: ${PROJECT}`,
    `https://firebaseappcheck.googleapis.com/v1beta/${serviceName}`,
  ]);
  if (!result.ok) {
    return {
      ok: false,
      serviceName,
      error: result.stderr || result.stdout || result.error,
    };
  }

  const config = JSON.parse(result.stdout);
  return {
    ok: config.enforcementMode === "ENFORCED",
    serviceName,
    enforcementMode: config.enforcementMode || null,
    updateTime: config.updateTime || null,
  };
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
      protection.required_pull_request_reviews?.required_approving_review_count === 1 &&
      ["openburnbar-pr", ...REQUIRED_CODEQL_CHECKS].every((check) => checks.includes(check)),
    requiredChecks: checks,
    reviewCount:
      protection.required_pull_request_reviews?.required_approving_review_count ?? 0,
    adminsEnforced: protection.enforce_admins?.enabled === true,
    forcePushesAllowed: protection.allow_force_pushes?.enabled === true,
    deletionsAllowed: protection.allow_deletions?.enabled === true,
  };
}

function ghJSON(path, options = {}) {
  const result = run("gh", [
    "api",
    "-H",
    "Accept: application/vnd.github+json",
    path,
  ], options);
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
    ])
  );

  const codeScanningAlerts = ghJSON(`/repos/${REPO}/code-scanning/alerts?state=open&per_page=100`);
  const secretScanningAlerts = ghJSON(`/repos/${REPO}/secret-scanning/alerts?state=open&per_page=100`);
  const dependabotAlerts = ghJSON(`/repos/${REPO}/dependabot/alerts?state=open&per_page=100`);

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
      codeScanning: codeScanningAlerts.ok ? codeScanningAlerts.value.length : null,
      secretScanning: secretScanningAlerts.ok ? secretScanningAlerts.value.length : null,
      dependabot: dependabotAlerts.ok ? dependabotAlerts.value.length : null,
    },
    errors: {
      codeScanning: codeScanningAlerts.ok ? undefined : codeScanningAlerts.error,
      secretScanning: secretScanningAlerts.ok ? undefined : secretScanningAlerts.error,
      dependabot: dependabotAlerts.ok ? undefined : dependabotAlerts.error,
    },
  };
}

function checkLatestMergedPrGate() {
  const pulls = run("gh", [
    "api",
    "-H",
    "Accept: application/vnd.github+json",
    `/repos/${REPO}/pulls?state=closed&sort=updated&direction=desc&per_page=20`,
  ]);
  if (!pulls.ok) return { ok: false, error: pulls.stderr || pulls.stdout };
  const merged = JSON.parse(pulls.stdout).find((pr) => pr.merged_at);
  if (!merged?.head?.sha) return { ok: false, error: "no merged PR found" };

  const runs = run("gh", [
    "api",
    "-H",
    "Accept: application/vnd.github+json",
    `/repos/${REPO}/commits/${merged.head.sha}/check-runs`,
  ]);
  if (!runs.ok) return { ok: false, pr: merged.number, error: runs.stderr || runs.stdout };
  const checkRuns = JSON.parse(runs.stdout).check_runs || [];
  const required = checkRuns.find((check) => check.name === "openburnbar-pr");
  const functional = checkRuns.find((check) => check.name === "functional-qa");
  return {
    ok: required?.conclusion === "success" && functional?.conclusion === "success",
    pr: merged.number,
    headSha: merged.head.sha,
    openburnbarPr: required ? pickCheck(required) : null,
    functionalQa: functional ? pickCheck(functional) : null,
  };
}

function checkMainRequiredGate() {
  const originMain = run("git", ["rev-parse", "origin/main"]);
  if (!originMain.ok) {
    return { ok: false, error: originMain.stderr || originMain.stdout || originMain.error };
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
    return { ok: false, error: originMain.stderr || originMain.stdout || originMain.error };
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
      ...(check ? pickCheck(check) : { status: "missing", conclusion: null, completedAt: null }),
    };
  });
  return {
    ok: checks.every((check) => check.status === "completed" && check.conclusion === "success"),
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
  const result = run("gcloud", [
    "run",
    "services",
    "list",
    "--project",
    PROJECT,
    "--region",
    REGION,
    "--format=json",
  ]);
  if (!result.ok) return { ok: false, error: result.stderr || result.stdout };
  const services = JSON.parse(result.stdout);
  const required = ["openburnbar-quota-runner", "hermes-realtime-relay"];
  const byName = new Map(services.map((service) => [service.metadata?.name, service]));
  const serviceStates = required.map((name) => {
    const service = byName.get(name);
    const ready = (service?.status?.conditions || []).some(
      (condition) => condition.type === "Ready" && condition.status === "True"
    );
    return { name, ready, url: service?.status?.url || null };
  });
  return {
    ok: serviceStates.every((service) => service.ready),
    services: serviceStates,
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
  if (!describe.ok) return { ok: false, error: describe.stderr || describe.stdout };
  const url = describe.stdout.trim();
  const curl = run("curl", ["-fsS", "-m", "10", `${url}/readyz`], { timeout: 15_000 });
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
    "list",
    "--project",
    PROJECT,
    "--region",
    REGION,
    "--format=json",
  ]);
  if (!result.ok) return { ok: false, error: result.stderr || result.stdout };
  const instances = JSON.parse(result.stdout);
  const redis = instances.find((instance) => instance.name?.includes("hermes-realtime-relay-redis-prod"));
  return {
    ok: redis?.state === "READY",
    name: redis?.name || null,
    tier: redis?.tier || null,
    state: redis?.state || null,
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
  const secretEnvVarNames = (details.serviceConfig?.secretEnvironmentVariables || [])
    .map((entry) => entry.key)
    .sort();
  let runnerURL;
  try {
    runnerURL = new URL(env.HOSTED_QUOTA_RUNNER_URL || "");
  } catch {
    runnerURL = undefined;
  }

  const envChecks = Object.entries(REQUIRED_HOSTED_QUOTA_ENV).map(([name, expected]) => ({
    name,
    ok: env[name] === expected,
    actual: env[name] ?? null,
    expected,
  }));
  const runnerURLCheck = {
    ok: runnerURL?.protocol === "https:",
    host: runnerURL?.host || null,
  };
  const runnerTokenCheck = {
    ok: !fn.requiresRunnerToken || secretEnvVarNames.includes("HOSTED_QUOTA_RUNNER_TOKEN"),
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
  const functions = REQUIRED_HOSTED_QUOTA_FUNCTIONS.map(checkFunctionHostedQuotaRuntime);
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

function metricTypesForPolicy(policy) {
  const filters = (policy.conditions || [])
    .map((condition) => condition.conditionThreshold?.filter || "")
    .filter(Boolean);
  const metricTypes = new Set();
  for (const filter of filters) {
    for (const match of filter.matchAll(/metric\.type="([^"]+)"/g)) {
      metricTypes.add(match[1]);
    }
  }
  return [...metricTypes].sort();
}

function checkBillingAlerts() {
  const result = run("gcloud", [
    "monitoring",
    "policies",
    "list",
    "--project",
    PROJECT,
    "--format=json",
  ]);
  if (!result.ok) return { ok: false, error: result.stderr || result.stdout };
  const policies = JSON.parse(result.stdout || "[]");
  const byDisplayName = new Map();
  for (const policy of policies) {
    const entries = byDisplayName.get(policy.displayName) || [];
    entries.push(policy);
    byDisplayName.set(policy.displayName, entries);
  }

  const required = BILLING_ALERT_POLICIES.map((expected) => {
    const matches = byDisplayName.get(expected.displayName) || [];
    const policy = matches[0];
    const metricTypes = policy ? metricTypesForPolicy(policy) : [];
    const missingMetricTypes = expected.requiredMetricTypes.filter(
      (metricType) => !metricTypes.includes(metricType)
    );
    return {
      displayName: expected.displayName,
      present: matches.length === 1,
      duplicateCount: Math.max(0, matches.length - 1),
      enabled: policy?.enabled === true,
      notificationChannels: policy?.notificationChannels || [],
      metricTypes,
      missingMetricTypes,
      ok:
        matches.length === 1 &&
        policy?.enabled === true &&
        (policy.notificationChannels || []).length > 0 &&
        missingMetricTypes.length === 0,
    };
  });

  return {
    ok: required.every((policy) => policy.ok),
    required,
  };
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
  const forbiddenPresent = FORBIDDEN_FIREBASE_FUNCTIONS.filter((id) => idSet.has(id));
  return {
    ok: missing.length === 0 && forbiddenPresent.length === 0,
    count: ids.length,
    missing,
    forbiddenPresent,
  };
}

function verdict(checks) {
  const failures = Object.entries(checks)
    .filter(([, value]) => value?.ok === false)
    .map(([name]) => name);
  if (failures.length) {
    return { status: "NO_GO", reason: `failed checks: ${failures.join(", ")}` };
  }
  const appStore = checks.appStore;
  if (appStore.state === "WAITING_FOR_REVIEW") {
    return { status: "WAITING_ON_APPLE", reason: "Apple review is still pending." };
  }
  if (appStore.state === REQUIRED_IOS_STATE) {
    return {
      status: "READY_FOR_MANUAL_RELEASE",
      reason: "Run release-approved-ios with the exact confirmation token, then run live paid proof.",
      confirmation: `${appStore.versionString}:${appStore.versionId}`,
    };
  }
  if (appStore.state === LIVE_IOS_STATE) {
    return {
      status: "READY_FOR_LIVE_PAID_PROOF",
      reason: "Run prove:hosted-quota against a real paid user before declaring launch complete.",
    };
  }
  return { status: "NO_GO", reason: `unhandled App Store state ${appStore.state}` };
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
    billingAlerts: checkBillingAlerts(),
    firebaseFunctionsInventory: checkFirebaseFunctionsInventory(),
  };
  const result = {
    generatedAt: new Date().toISOString(),
    verdict: verdict(checks),
    checks,
  };
  console.log(JSON.stringify(result, null, 2));
  process.exitCode = result.verdict.status === "NO_GO" ? 1 : 0;
}

main().catch((error) => {
  console.error(JSON.stringify({ ok: false, error: error.message }, null, 2));
  process.exitCode = 1;
});
