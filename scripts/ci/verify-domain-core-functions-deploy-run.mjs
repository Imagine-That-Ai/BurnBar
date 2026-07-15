#!/usr/bin/env node

import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  canonicalJson,
  regularFile,
} from "../lib/domain-core-release-evidence.mjs";

const FULL_SHA = /^[0-9a-f]{40}$/u;
const POSITIVE_INTEGER = /^[1-9]\d*$/u;
const STABLE_TAG = /^v\d+\.\d+\.\d+(?:\+[0-9A-Za-z.-]+)?$/u;
const REPOSITORY = "Imagine-That-Ai/BurnBar";
const WORKFLOW_PATH = ".github/workflows/deploy-production.yml";
const PROFILES = new Set(["public-production", "public-production-rollback"]);

function parseArguments(argv) {
  const required = new Set([
    "--run",
    "--jobs",
    "--tag",
    "--commit",
    "--deploy-run-id",
    "--deploy-run-attempt",
    "--profile",
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
    return JSON.parse(readFileSync(regularFile(path, label), "utf8"));
  } catch (error) {
    throw new Error(`unable to read ${label}: ${error.message}`);
  }
}

function positiveInteger(value, label) {
  if (!POSITIVE_INTEGER.test(String(value)))
    throw new Error(`${label} must be a positive integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed))
    throw new Error(`${label} exceeds the safe integer range`);
  return parsed;
}

function expectedConclusions(profile) {
  const authorization =
    profile === "public-production-rollback" ? "success" : "skipped";
  return new Map([
    ["authorize-domain-core-rollback", authorization],
    ["deploy-functions", "success"],
    ["functions-health-gate", "success"],
    ["dispatch-domain-core-functions-evidence", "success"],
  ]);
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
    const stat = lstatSync(output);
    if (
      !stat.isFile() ||
      stat.isSymbolicLink() ||
      readFileSync(output, "utf8") !== contents
    ) {
      throw new Error(
        `refusing to replace non-identical Functions deploy-run verification: ${output}`,
      );
    }
  }
  return output;
}

export function verifyFunctionsDeployRun({
  run,
  jobsDocument,
  tag,
  commit,
  deployRunId,
  deployRunAttempt,
  profile,
}) {
  if (!STABLE_TAG.test(tag)) throw new Error("stable release tag is invalid");
  if (!FULL_SHA.test(commit)) throw new Error("release commit is invalid");
  if (!PROFILES.has(profile)) throw new Error("Functions profile is invalid");
  const runId = positiveInteger(deployRunId, "deploy run ID");
  const runAttempt = positiveInteger(deployRunAttempt, "deploy run attempt");
  const expectedEvent =
    profile === "public-production-rollback" ? "workflow_dispatch" : undefined;
  if (
    run?.id !== runId ||
    run?.repository?.full_name !== REPOSITORY ||
    run?.path !== WORKFLOW_PATH ||
    run?.head_sha !== commit ||
    (run?.head_branch !== tag && run?.head_branch !== null) ||
    !new Set(["push", "workflow_dispatch"]).has(run?.event) ||
    (expectedEvent !== undefined && run?.event !== expectedEvent) ||
    run?.run_attempt !== runAttempt ||
    run?.status !== "completed" ||
    run?.conclusion !== "success"
  ) {
    throw new Error(
      "deploy run is not the exact completed successful production attempt",
    );
  }

  const jobs = jobsDocument?.jobs;
  if (
    !Number.isSafeInteger(jobsDocument?.total_count) ||
    !Array.isArray(jobs) ||
    jobsDocument.total_count !== jobs.length
  ) {
    throw new Error("deploy jobs response is incomplete");
  }
  const expected = expectedConclusions(profile);
  if (jobs.length !== expected.size)
    throw new Error(
      "deploy attempt does not contain the exact required job set",
    );

  const seen = new Set();
  const normalizedJobs = [];
  for (const job of jobs) {
    const name = job?.name;
    if (typeof name !== "string" || seen.has(name) || !expected.has(name)) {
      throw new Error(
        "deploy attempt contains an invalid or duplicate job name",
      );
    }
    seen.add(name);
    if (
      job.run_id !== runId ||
      job.head_sha !== commit ||
      job.status !== "completed" ||
      job.conclusion !== expected.get(name)
    ) {
      throw new Error(`deploy job ${name} has invalid identity or conclusion`);
    }
    normalizedJobs.push({
      name,
      status: job.status,
      conclusion: job.conclusion,
      runId: job.run_id,
      headSha: job.head_sha,
    });
  }
  if ([...expected.keys()].some((name) => !seen.has(name))) {
    throw new Error("deploy attempt is missing a required job");
  }
  normalizedJobs.sort((left, right) => left.name.localeCompare(right.name));
  const jobSetSha256 = createHash("sha256")
    .update(canonicalJson(normalizedJobs))
    .digest("hex");
  return {
    schemaVersion: 1,
    verificationKind: "domain-core-functions-deploy-run",
    deployRun: {
      repository: REPOSITORY,
      workflowPath: WORKFLOW_PATH,
      runId,
      runAttempt,
      event: run.event,
      ref: `refs/tags/${tag}`,
      headSha: commit,
      jobSetSha256,
    },
  };
}

export function run(argv) {
  const args = parseArguments(argv);
  const verification = verifyFunctionsDeployRun({
    run: readJson(resolve(args.get("--run")), "Functions deploy run"),
    jobsDocument: readJson(
      resolve(args.get("--jobs")),
      "Functions deploy jobs",
    ),
    tag: args.get("--tag"),
    commit: args.get("--commit"),
    deployRunId: args.get("--deploy-run-id"),
    deployRunAttempt: args.get("--deploy-run-attempt"),
    profile: args.get("--profile"),
  });
  const output = writeCreateOnly(
    args.get("--output"),
    `${JSON.stringify(verification, null, 2)}\n`,
  );
  process.stdout.write(
    `${JSON.stringify({ ok: true, output, verification })}\n`,
  );
  return verification;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
