#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REPOSITORY = "Imagine-That-Ai/BurnBar";
const REQUIRED_CONTEXTS = Object.freeze([
  "Domain Core Trusted Deletion Guard",
]);

export function verifyDefaultBranchControls(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("branch protection response must be an object");
  }
  const rawContexts = value.required_status_checks?.contexts;
  const rawChecks = value.required_status_checks?.checks ?? [];
  if (!Array.isArray(rawContexts) || !Array.isArray(rawChecks)) {
    throw new Error("main required status checks response is malformed");
  }
  const contexts = new Set([
    ...rawContexts,
    ...rawChecks.map((check) => check?.context),
  ]);
  const missingContexts = REQUIRED_CONTEXTS.filter(
    (context) => !contexts.has(context),
  );
  if (missingContexts.length > 0) {
    throw new Error(
      `main must require status checks: ${missingContexts.join(", ")}`,
    );
  }
  if (value.required_status_checks?.strict !== true) {
    throw new Error(
      "main required checks must be strict and current with main",
    );
  }
  if (value.enforce_admins?.enabled !== true) {
    throw new Error("main protection must apply to administrators");
  }
  if (
    (value.required_pull_request_reviews?.required_approving_review_count ??
      0) < 1
  ) {
    throw new Error(
      "main must require at least one approving pull-request review",
    );
  }
  if (value.required_pull_request_reviews?.dismiss_stale_reviews !== true) {
    throw new Error(
      "main must dismiss approvals when the reviewed head changes",
    );
  }
  if (
    value.allow_force_pushes?.enabled === true ||
    value.allow_deletions?.enabled === true
  ) {
    throw new Error("main must reject force pushes and deletion");
  }
  return {
    repository: REPOSITORY,
    branch: "main",
    requiredContexts: REQUIRED_CONTEXTS,
  };
}

export function run(argv) {
  const snapshotIndex = argv.indexOf("--snapshot");
  if (argv.length !== 0 && (snapshotIndex !== 0 || argv.length !== 2)) {
    throw new Error(
      "usage: verify-domain-core-default-branch-controls.mjs [--snapshot PATH]",
    );
  }
  const value =
    snapshotIndex === 0
      ? JSON.parse(readFileSync(argv[1], "utf8"))
      : JSON.parse(
          execFileSync(
            "gh",
            ["api", `repos/${REPOSITORY}/branches/main/protection`],
            { encoding: "utf8" },
          ),
        );
  const result = verifyDefaultBranchControls(value);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return result;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
