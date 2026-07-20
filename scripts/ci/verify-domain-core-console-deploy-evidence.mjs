#!/usr/bin/env node

import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { buildDeploymentIdentity } from "./create-domain-core-deployment-identity.mjs";
import { readRegularFileSync } from "../lib/atomic-regular-file.mjs";
import {
  canonicalSha256,
  exactObject,
  sha256File,
} from "../lib/domain-core-release-evidence.mjs";

const REQUIRED_JOBS = new Set([
  "build-hosting-artifacts",
  "deploy-hosting",
  "hosting-smoke-result",
  "dispatch-domain-core-console-evidence",
]);

function parseArguments(argv) {
  const required = new Set([
    "--deploy-run",
    "--deploy-jobs",
    "--expected-run-id",
    "--expected-run-attempt",
    "--expected-commit",
    "--expected-tag",
    "--identity",
    "--runtime-manifest",
    "--profile-receipt",
    "--release-gate",
    "--health",
    "--output",
  ]);
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!required.has(flag))
      throw new Error(`unknown argument: ${String(flag)}`);
    if (!value || value.startsWith("--"))
      throw new Error(`${flag} requires a value`);
    if (values.has(flag)) throw new Error(`duplicate argument: ${flag}`);
    values.set(flag, value);
  }
  for (const flag of required) {
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  }
  return values;
}

function readJson(path, label) {
  try {
    return JSON.parse(
      readRegularFileSync(resolve(path), { encoding: "utf8", label }),
    );
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function positiveInteger(value, label) {
  if (!/^[1-9]\d*$/u.test(value))
    throw new Error(`${label} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed))
    throw new Error(`${label} exceeds the safe integer range`);
  return parsed;
}

function validateJobs(raw, profileName, runId, commit) {
  const pages = Array.isArray(raw) ? raw : [raw];
  if (pages.length === 0) throw new Error("deploy jobs API returned no pages");
  const jobs = pages.flatMap((page) => page.jobs ?? []);
  if (pages[0].total_count !== jobs.length) {
    throw new Error("deploy jobs API pagination is incomplete");
  }
  const byName = new Map();
  for (const job of jobs) {
    if (byName.has(job.name))
      throw new Error(`duplicate deploy job ${String(job.name)}`);
    if (job.run_id !== runId || job.head_sha !== commit) {
      throw new Error(
        `deploy job ${String(job.name)} is not bound to the exact run and commit`,
      );
    }
    byName.set(job.name, job);
  }
  if (jobs.length !== REQUIRED_JOBS.size + 1) {
    throw new Error("deploy workflow returned missing or unexpected jobs");
  }
  for (const name of REQUIRED_JOBS) {
    const job = byName.get(name);
    if (job?.status !== "completed" || job?.conclusion !== "success") {
      throw new Error(`required deploy job ${name} did not succeed`);
    }
  }
  const authorization = byName.get("authorize-domain-core-rollback");
  const expectedAuthorization =
    profileName === "public-production-rollback" ? "success" : "skipped";
  if (
    authorization?.status !== "completed" ||
    authorization?.conclusion !== expectedAuthorization
  ) {
    throw new Error(
      `rollback authorization must be ${expectedAuthorization} for ${profileName}`,
    );
  }
  return canonicalSha256(
    jobs
      .map((job) => ({
        name: job.name,
        runId: job.run_id,
        headSha: job.head_sha,
        status: job.status,
        conclusion: job.conclusion,
      }))
      .sort((left, right) => left.name.localeCompare(right.name)),
  );
}

function validateHealth(raw, runtimeManifestPath) {
  const health = exactObject(
    raw,
    [
      "provider",
      "project",
      "environment",
      "status",
      "healthChecks",
      "deployedArtifact",
      "providerCoordinates",
    ],
    "Console deployment health",
  );
  if (
    health.provider !== "firebase-hosting" ||
    health.project !== "burnbar" ||
    health.environment !== "production" ||
    health.status !== "healthy"
  ) {
    throw new Error(
      "Console deployment health does not identify healthy production Hosting",
    );
  }
  const expectedChecks = [
    "marketing-http-200-csp",
    "console-http-200-csp",
    "console-deployment-identity-no-redirect",
    "console-runtime-manifest-no-redirect",
    "console-runtime-files-sha256",
  ];
  assert.deepEqual(
    health.healthChecks,
    expectedChecks,
    "Console health checks are incomplete",
  );
  assert.deepEqual(
    health.deployedArtifact,
    {
      fileName: "domain-core-runtime-artifact-manifest.json",
      sha256: sha256File(runtimeManifestPath),
    },
    "Console health evidence does not bind the verified live identity bytes",
  );
  const sites = health.providerCoordinates?.sites;
  if (
    !Array.isArray(sites) ||
    sites.length !== 2 ||
    JSON.stringify(sites.map((site) => [site.target, site.site]).sort()) !==
      JSON.stringify([
        ["console", "burnbar-console"],
        ["marketing", "burnbar"],
      ]) ||
    sites.some(
      (site) =>
        typeof site.versionName !== "string" ||
        typeof site.releaseName !== "string" ||
        !site.versionName.startsWith(`sites/${site.site}/versions/`) ||
        !site.releaseName.startsWith(
          `sites/${site.site}/channels/live/releases/`,
        ),
    )
  ) {
    throw new Error(
      "Console health evidence lacks exact immutable Hosting versions and releases",
    );
  }
  return structuredClone(health);
}

function writeCreateOnly(path, contents) {
  const output = resolve(path);
  mkdirSync(dirname(output), { recursive: true });
  try {
    writeFileSync(output, contents, {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    let existing;
    try {
      existing = readRegularFileSync(output, {
        encoding: "utf8",
        label: "Console deploy verification receipt",
      });
    } catch {
      existing = undefined;
    }
    if (existing !== contents) {
      throw new Error(
        "refusing to replace non-identical Console deploy verification receipt",
      );
    }
  }
}

export function run(argv) {
  const args = parseArguments(argv);
  const runId = positiveInteger(args.get("--expected-run-id"), "deploy run ID");
  const runAttempt = positiveInteger(
    args.get("--expected-run-attempt"),
    "deploy run attempt",
  );
  const commit = args.get("--expected-commit");
  const tag = args.get("--expected-tag");
  const identityPath = resolve(args.get("--identity"));
  const expectedIdentity = buildDeploymentIdentity({
    consumer: "console",
    commit,
    tag,
    profileReceiptPath: args.get("--profile-receipt"),
    releaseGatePath: args.get("--release-gate"),
  });
  assert.deepEqual(
    readJson(identityPath, "deployed identity"),
    expectedIdentity,
    "deployed identity does not match the exact release inputs",
  );
  const deployRun = readJson(args.get("--deploy-run"), "deploy run");
  if (
    deployRun.id !== runId ||
    deployRun.run_attempt !== runAttempt ||
    deployRun.path !== ".github/workflows/deploy-hosting.yml" ||
    deployRun.head_sha !== commit ||
    deployRun.head_branch !== tag ||
    !new Set(["push", "workflow_dispatch"]).has(deployRun.event) ||
    deployRun.status !== "completed" ||
    deployRun.conclusion !== "success"
  ) {
    throw new Error(
      "deploy run does not bind the exact workflow, attempt, tag, and commit",
    );
  }
  const jobSetSha256 = validateJobs(
    readJson(args.get("--deploy-jobs"), "deploy jobs"),
    expectedIdentity.profile.name,
    runId,
    commit,
  );
  const healthPath = resolve(args.get("--health"));
  const runtimeManifestPath = resolve(args.get("--runtime-manifest"));
  const health = validateHealth(
    readJson(healthPath, "health evidence"),
    runtimeManifestPath,
  );
  const receipt = {
    provider: health.provider,
    project: health.project,
    environment: health.environment,
    status: health.status,
    healthChecks: health.healthChecks,
    deployedArtifact: health.deployedArtifact,
    providerCoordinates: health.providerCoordinates,
    deployRun: {
      repository: "Imagine-That-Ai/BurnBar",
      workflowPath: ".github/workflows/deploy-hosting.yml",
      runId,
      runAttempt,
      event: deployRun.event,
      ref: `refs/tags/${tag}`,
      headSha: commit,
      jobSetSha256,
    },
    healthArtifactSha256: sha256File(healthPath),
  };
  writeCreateOnly(
    args.get("--output"),
    `${JSON.stringify(receipt, null, 2)}\n`,
  );
  process.stdout.write(`${JSON.stringify(receipt)}\n`);
  return receipt;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
