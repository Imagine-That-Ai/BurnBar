#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REPOSITORY = "Imagine-That-Ai/BurnBar";
const REQUIRED_CONTEXTS = Object.freeze(["BurnBar CI Gate"]);
const REQUIRED_UMBRELLA_CONTEXTS = Object.freeze([
  "Android PR Gate",
  "Domain Core PR Gate",
  "Domain Core Trusted Deletion Guard",
  "PR Native Gate",
  "PR Windows Full Gate",
  "PR Windows Gate",
]);
const MAIN_REFS = new Set(["refs/heads/main", "~DEFAULT_BRANCH"]);

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

export function verifyUmbrellaInventory(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("BurnBar CI Gate inventory must be an object");
  }
  if (value.context !== "BurnBar CI Gate") {
    throw new Error("umbrella inventory must emit BurnBar CI Gate");
  }
  if (!Array.isArray(value.required_contexts)) {
    throw new Error("umbrella required contexts must be an array");
  }
  const contexts = new Set(value.required_contexts);
  if (contexts.size !== value.required_contexts.length) {
    throw new Error("umbrella required contexts must be unique");
  }
  const missing = REQUIRED_UMBRELLA_CONTEXTS.filter(
    (context) => !contexts.has(context),
  );
  if (missing.length > 0) {
    throw new Error(
      `BurnBar CI Gate must require safety contexts: ${missing.join(", ")}`,
    );
  }
  return { umbrellaRequiredContexts: REQUIRED_UMBRELLA_CONTEXTS };
}

export function verifyMergeQueueRulesets(value) {
  if (!Array.isArray(value)) {
    throw new Error("repository rulesets response must be an array");
  }
  const ruleset = value.find((candidate) => {
    if (
      candidate?.target !== "branch" ||
      candidate.enforcement !== "active" ||
      !Array.isArray(candidate.bypass_actors) ||
      candidate.bypass_actors.length !== 0
    ) {
      return false;
    }
    const include = candidate.conditions?.ref_name?.include;
    const exclude = candidate.conditions?.ref_name?.exclude ?? [];
    if (
      !Array.isArray(include) ||
      !include.some((ref) => MAIN_REFS.has(ref)) ||
      !Array.isArray(exclude) ||
      exclude.some((ref) => MAIN_REFS.has(ref))
    ) {
      return false;
    }
    return candidate.rules?.some(
      (rule) =>
        rule?.type === "merge_queue" &&
        rule.parameters?.grouping_strategy === "ALLGREEN",
    );
  });
  if (!ruleset) {
    throw new Error(
      "main must use an active ALLGREEN merge queue without bypass actors",
    );
  }
  return { mergeQueueRuleset: ruleset.id };
}

function liveJson(path) {
  return JSON.parse(
    execFileSync("gh", ["api", path], {
      encoding: "utf8",
    }),
  );
}

function liveRulesets() {
  const summaries = liveJson(
    `repos/${REPOSITORY}/rulesets?includes_parents=true`,
  );
  if (!Array.isArray(summaries)) {
    throw new Error("repository rulesets response must be an array");
  }
  return summaries
    .filter(
      (ruleset) =>
        ruleset?.target === "branch" && ruleset.enforcement === "active",
    )
    .map((ruleset) => liveJson(`repos/${REPOSITORY}/rulesets/${ruleset.id}`));
}

export function run(argv) {
  const snapshotIndex = argv.indexOf("--snapshot");
  if (argv.length !== 0 && (snapshotIndex !== 0 || argv.length !== 2)) {
    throw new Error(
      "usage: verify-domain-core-default-branch-controls.mjs [--snapshot PATH]",
    );
  }
  const snapshot =
    snapshotIndex === 0
      ? JSON.parse(readFileSync(argv[1], "utf8"))
      : undefined;
  const protection =
    snapshot?.protection ??
    liveJson(`repos/${REPOSITORY}/branches/main/protection`);
  const umbrella =
    snapshot?.umbrella ??
    JSON.parse(
      readFileSync(
        new URL("../../governance/burnbar-ci-gate.json", import.meta.url),
        "utf8",
      ),
    );
  const rulesets = snapshot?.rulesets ?? liveRulesets();
  const result = {
    ...verifyDefaultBranchControls(protection),
    ...verifyUmbrellaInventory(umbrella),
    ...verifyMergeQueueRulesets(rulesets),
  };
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
