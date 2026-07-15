#!/usr/bin/env node

import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { resolveDomainCoreCandidateIdentity } from "../lib/domain-core-candidate-receipt.mjs";
import { createUnsignedDeterministicCandidateBundle } from "../lib/domain-core-deterministic-candidate-bundle.mjs";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const DEFAULT_POLICY = resolve(
  REPO_ROOT,
  "config/domain-core-promotion-policy.json",
);
const POSITIVE_INTEGER = /^[1-9]\d*$/u;

export function parseArguments(argv) {
  const allowed = new Set([
    "--repo-root",
    "--expected-candidate-commit",
    "--evidence",
    "--policy",
    "--output",
    "--generated-at",
  ]);
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag)) throw new Error(`unknown argument: ${String(flag)}`);
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`${flag} requires a value`);
    }
    const key = flag.slice(2);
    if (Object.hasOwn(result, key)) throw new Error(`duplicate argument: ${flag}`);
    result[key] = value;
  }
  for (const required of [
    "expected-candidate-commit",
    "evidence",
    "output",
  ]) {
    if (!result[required]) throw new Error(`--${required} is required`);
  }
  return result;
}

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(resolve(path), "utf8"));
  } catch (error) {
    throw new Error(
      `unable to read ${label}: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

function positiveInteger(value, name) {
  if (typeof value !== "string" || !POSITIVE_INTEGER.test(value)) {
    throw new Error(`${name} must be a positive integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    throw new Error(`${name} exceeds the safe integer range`);
  }
  return parsed;
}

export function githubActionsWorkflowContext(environment, policy, candidate) {
  if (environment.GITHUB_ACTIONS !== "true") {
    throw new Error("unsigned candidate bundles can only be created in GitHub Actions");
  }
  const expected = {
    GITHUB_REPOSITORY: policy.workflow.repository,
    GITHUB_WORKFLOW: policy.workflow.workflowName,
    GITHUB_EVENT_NAME: "push",
    GITHUB_REF: policy.workflow.requiredRef,
    GITHUB_SHA: candidate.candidateCommit,
    GITHUB_WORKFLOW_REF:
      `${policy.workflow.repository}/${policy.workflow.workflowPath}` +
      `@${policy.workflow.requiredRef}`,
  };
  for (const [name, value] of Object.entries(expected)) {
    if (environment[name] !== value) {
      throw new Error(`${name} must equal ${value}`);
    }
  }
  return {
    repository: environment.GITHUB_REPOSITORY,
    workflowPath: policy.workflow.workflowPath,
    workflowName: environment.GITHUB_WORKFLOW,
    runId: positiveInteger(environment.GITHUB_RUN_ID, "GITHUB_RUN_ID"),
    runAttempt: positiveInteger(
      environment.GITHUB_RUN_ATTEMPT,
      "GITHUB_RUN_ATTEMPT",
    ),
    event: environment.GITHUB_EVENT_NAME,
    ref: environment.GITHUB_REF,
    headSha: environment.GITHUB_SHA,
  };
}

function writeAtomically(path, contents) {
  const destination = resolve(path);
  mkdirSync(dirname(destination), { recursive: true });
  const temporary = `${destination}.tmp-${process.pid}`;
  writeFileSync(temporary, contents, { encoding: "utf8", mode: 0o600 });
  renameSync(temporary, destination);
}

export function run(argv, { environment = process.env } = {}) {
  const args = parseArguments(argv);
  const policy = readJson(args.policy ?? DEFAULT_POLICY, "policy");
  const repoRoot = resolve(args["repo-root"] ?? REPO_ROOT);
  const verifiedCandidateIdentity = resolveDomainCoreCandidateIdentity({
    repoRoot,
    expectedCandidateCommit: args["expected-candidate-commit"],
    requireClean: true,
    verifyArtifactIdentity: true,
  });
  const workflow = githubActionsWorkflowContext(
    environment,
    policy,
    verifiedCandidateIdentity,
  );
  const evidence = readJson(args.evidence, "deterministic evidence");
  const bundle = createUnsignedDeterministicCandidateBundle({
    verifiedCandidateIdentity,
    workflow,
    evidence,
    policy,
    generatedAt: args["generated-at"] ?? new Date().toISOString(),
  });
  const serialized = `${JSON.stringify(bundle, null, 2)}\n`;
  writeAtomically(args.output, serialized);
  process.stdout.write(serialized);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
