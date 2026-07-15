#!/usr/bin/env node

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { resolveDomainCoreCandidateIdentity } from "../lib/domain-core-candidate-receipt.mjs";
import {
  aggregateDomainCoreProofFragments,
  createDomainCoreProofFragment,
  loadFragments,
} from "../lib/domain-core-proof-fragments.mjs";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const DEFAULT_POLICY = resolve(REPO_ROOT, "config/domain-core-promotion-policy.json");

function writeJson(path, value) {
  const destination = resolve(path);
  mkdirSync(dirname(destination), { recursive: true });
  const temporary = `${destination}.tmp-${process.pid}`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporary, destination);
}

function parsePairs(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined || value.startsWith("--")) {
      throw new Error(`${String(flag)} requires a value`);
    }
    const list = values.get(flag) ?? [];
    list.push(value);
    values.set(flag, list);
  }
  return values;
}

function one(values, flag, required = true) {
  const entries = values.get(flag) ?? [];
  if (entries.length > 1) throw new Error(`${flag} cannot be repeated`);
  if (required && entries.length === 0) throw new Error(`${flag} is required`);
  return entries[0];
}

function specs(values, flag, separator = "=") {
  return (values.get(flag) ?? []).map((entry) => {
    const index = entry.indexOf(separator);
    if (index < 1 || index === entry.length - 1) throw new Error(`${flag} must be ID${separator}PATH`);
    return { id: entry.slice(0, index), path: entry.slice(index + 1) };
  });
}

function policy(values) {
  return JSON.parse(readFileSync(one(values, "--policy", false) ?? DEFAULT_POLICY, "utf8"));
}

function candidate(values) {
  return resolveDomainCoreCandidateIdentity({
    repoRoot: one(values, "--repo-root", false) ?? REPO_ROOT,
    expectedCandidateCommit: one(values, "--expected-candidate-commit"),
    requireClean: true,
    verifyArtifactIdentity: true,
  });
}

function githubRun() {
  if (process.env.GITHUB_ACTIONS !== "true") throw new Error("proof fragments require GitHub Actions");
  return {
    runId: process.env.GITHUB_RUN_ID,
    runAttempt: process.env.GITHUB_RUN_ATTEMPT,
    headSha: process.env.GITHUB_SHA,
  };
}

export function run(argv) {
  const command = argv[0];
  const values = parsePairs(argv.slice(1));
  const common = [
    "--expected-candidate-commit",
    "--output",
    "--policy",
    "--repo-root",
  ];
  const allowed = new Set(
    command === "emit"
      ? [...common, "--artifact", "--benchmark", "--job-id", "--rollback", "--suite"]
      : command === "aggregate"
        ? [...common, "--fragments", "--job-results"]
        : [],
  );
  if (allowed.size === 0) throw new Error("command must be emit or aggregate");
  for (const flag of values.keys()) {
    if (!allowed.has(flag)) throw new Error(`unknown ${command} argument: ${flag}`);
  }
  const activePolicy = policy(values);
  const identity = candidate(values);
  const workflow = githubRun();
  if (command === "emit") {
    const rollback = one(values, "--rollback", false);
    const fragment = createDomainCoreProofFragment({
      jobId: one(values, "--job-id"),
      ...workflow,
      candidate: identity,
      policy: activePolicy,
      suites: specs(values, "--suite").map(({ id, path }) => ({ id, reportPath: path })),
      artifacts: specs(values, "--artifact"),
      benchmarks: specs(values, "--benchmark").map(({ id, path }) => ({ id, reportPath: path })),
      rollback:
        rollback === undefined
          ? null
          : (() => {
              const [reportPath, restoredArtifactPath, extra] = rollback.split(",");
              if (!reportPath || !restoredArtifactPath || extra !== undefined) {
                throw new Error("--rollback must be REPORT_PATH,RESTORED_ARTIFACT_PATH");
              }
              return { reportPath, restoredArtifactPath };
            })(),
    });
    writeJson(one(values, "--output"), fragment);
    return fragment;
  }
  if (command === "aggregate") {
    const jobResults = JSON.parse(readFileSync(one(values, "--job-results"), "utf8"));
    const evidence = aggregateDomainCoreProofFragments({
      fragments: loadFragments(one(values, "--fragments")),
      jobResults,
      candidate: identity,
      runId: workflow.runId,
      runAttempt: workflow.runAttempt,
      policy: activePolicy,
    });
    writeJson(one(values, "--output"), evidence);
    return evidence;
  }
  throw new Error("unreachable proof-fragment command");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
