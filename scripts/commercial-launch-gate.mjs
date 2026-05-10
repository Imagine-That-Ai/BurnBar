#!/usr/bin/env node
/**
 * Commercial launch gate for OpenBurnBar.
 *
 * This is a read-only operator command. It gathers the live state that decides
 * whether the commercial launch can proceed, then prints one JSON verdict.
 */

import { spawnSync } from "node:child_process";
import process from "node:process";

const REPO = process.env.OPENBURNBAR_GITHUB_REPO || "Imagine-That-Ai/BurnBar";
const PROJECT = process.env.OPENBURNBAR_FIREBASE_PROJECT || "burnbar";
const REGION = process.env.OPENBURNBAR_GCP_REGION || "us-central1";
const REQUIRED_IOS_STATE = "PENDING_DEVELOPER_RELEASE";
const LIVE_IOS_STATE = "READY_FOR_SALE";
const PRODUCT_ID = "com.openburnbar.hostedQuotaSync.monthly";

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
      checks.includes("openburnbar-pr"),
    requiredChecks: checks,
    reviewCount:
      protection.required_pull_request_reviews?.required_approving_review_count ?? 0,
    adminsEnforced: protection.enforce_admins?.enabled === true,
    forcePushesAllowed: protection.allow_force_pushes?.enabled === true,
    deletionsAllowed: protection.allow_deletions?.enabled === true,
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
  const checks = {
    repo: checkRepo(),
    appStore: checkAppStore(),
    branchProtection: checkProtection(),
    mainRequiredGate: checkMainRequiredGate(),
    latestMergedPrGate: checkLatestMergedPrGate(),
    cloudRun: checkCloudRun(),
    runnerReadyz: checkRunnerReadyz(),
    redis: checkRedis(),
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
