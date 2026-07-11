#!/usr/bin/env node
/**
 * Fail-closed structural gate for the Linux attestation facade CI surface.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = join(SCRIPT_DIR, "..", "..");

function extractJobs(source) {
  const jobs = new Map();
  const lines = source.split("\n");
  let inJobs = false;
  let currentName = null;
  let currentLines = [];

  for (const line of lines) {
    if (!inJobs) {
      if (line === "jobs:") inJobs = true;
      continue;
    }

    const match = /^  ([A-Za-z0-9_-]+):\s*$/u.exec(line);
    if (match) {
      if (currentName) jobs.set(currentName, currentLines.join("\n"));
      currentName = match[1];
      currentLines = [line];
      continue;
    }

    if (currentName) currentLines.push(line);
  }

  if (currentName) jobs.set(currentName, currentLines.join("\n"));
  return jobs;
}

function dependabotUpdateBlocks(source) {
  const blocks = [];
  let current = [];
  for (const line of source.split("\n")) {
    if (/^  - package-ecosystem:/u.test(line)) {
      if (current.length > 0) blocks.push(current.join("\n"));
      current = [line];
    } else if (current.length > 0) {
      current.push(line);
    }
  }
  if (current.length > 0) blocks.push(current.join("\n"));
  return blocks;
}

function auditDirectories(source) {
  const list = /export const AUDIT_DIRS = \[([\s\S]*?)\];/u.exec(source);
  if (!list) return [];
  return [...list[1].matchAll(/["']([^"']+)["']/gu)].map((match) => match[1]);
}

function hasRunCommand(block, command) {
  return block
    .split("\n")
    .some((line) => line.trim() === `run: ${command}`);
}

export function verifyLinuxAttestationFacadeCi({ workflow, dependabot, audit }) {
  const failures = [];
  const fail = (message) => failures.push(message);
  const jobs = extractJobs(workflow);
  const pathFilter = jobs.get("fast-feedback-path-filter") ?? "";
  const facadeJob = jobs.get("linux-attestation-facade-fast") ?? "";
  const aggregate = jobs.get("fast-feedback-gate") ?? "";

  if (!pathFilter) {
    fail("fast-feedback-path-filter job is missing");
  } else {
    for (const marker of [
      "linux_attestation_facade_changed: ${{ steps.changed.outputs.linux_attestation_facade_changed }}",
      "services/linux-attestation-facade/",
      "functions/src/(index|callables/linuxAppCheck|security/linuxAttestation(IngressTickets|IngressQuota)?)\\.ts",
      "tests/fixtures/linux-attestation/(broker-v2-golden|ingress-ticket-v1-golden)\\.json",
      "schemas/linux-attestation-(evidence-bundle-header-v1|ingress-ticket-v1)\\.schema\\.json",
      "dependabot\\.yml",
      "check-npm-audit-fail-closed",
      "verify-linux-attestation-facade-ci",
      'echo "linux_attestation_facade_changed=true" >> "$GITHUB_OUTPUT"',
      'echo "linux_attestation_facade_changed=false" >> "$GITHUB_OUTPUT"',
      "node scripts/ci/verify-linux-attestation-facade-ci.test.mjs",
      "node scripts/ci/verify-linux-attestation-facade-ci.mjs",
    ]) {
      if (!pathFilter.includes(marker)) {
        fail(`path filter is missing facade CI marker: ${marker}`);
      }
    }
  }

  if (!facadeJob) {
    fail("linux-attestation-facade-fast job is missing");
  } else {
    if (!/^    needs: fast-feedback-path-filter$/mu.test(facadeJob)) {
      fail("facade job must depend on fast-feedback-path-filter");
    }
    if (
      !/^    if: needs\.fast-feedback-path-filter\.outputs\.linux_attestation_facade_changed == 'true'$/mu.test(
        facadeJob,
      )
    ) {
      fail("facade job must be scoped by linux_attestation_facade_changed");
    }
    if (/continue-on-error:\s*true|\|\|\s*true/u.test(facadeJob)) {
      fail("facade job must not suppress command failures");
    }

    for (const command of [
      "npm ci --prefix services/linux-attestation-facade",
      "npm run typecheck --prefix services/linux-attestation-facade",
      "npm run lint --prefix services/linux-attestation-facade",
      "npm run test --prefix services/linux-attestation-facade",
      "npm run build --prefix services/linux-attestation-facade",
      "npm audit --prefix services/linux-attestation-facade --audit-level=high",
      "docker build --target ingress --tag openburnbar-linux-attestation-ingress:ci services/linux-attestation-facade",
      "docker build --target verifier --tag openburnbar-linux-attestation-verifier:ci services/linux-attestation-facade",
    ]) {
      if (!hasRunCommand(facadeJob, command)) {
        fail(`facade job is missing exact fail-closed command: ${command}`);
      }
    }

    if (!facadeJob.includes("services/linux-attestation-facade/package-lock.json")) {
      fail("facade job must key the npm cache from its package lock");
    }
  }

  if (!/^      - linux-attestation-facade-fast$/mu.test(aggregate)) {
    fail("Fast Feedback Gate must require linux-attestation-facade-fast");
  }
  if (!/^    if: always\(\)$/mu.test(aggregate)) {
    fail("Fast Feedback Gate must run with always() when a path-scoped job is skipped");
  }
  if (!/toJSON\(needs\)/u.test(aggregate)) {
    fail("Fast Feedback Gate must inspect every required job result");
  }
  if (!/not in \('success', 'skipped'\)/u.test(aggregate)) {
    fail("Fast Feedback Gate must accept skipped path-scoped jobs on unrelated PRs");
  }

  const facadeUpdates = dependabotUpdateBlocks(dependabot).filter((block) =>
    block.includes('directory: "/services/linux-attestation-facade"'),
  );
  if (facadeUpdates.length !== 1) {
    fail("Dependabot must contain exactly one Linux attestation facade update entry");
  } else if (!facadeUpdates[0].includes('package-ecosystem: "npm"')) {
    fail("Linux attestation facade Dependabot entry must use npm");
  }

  const facadeAuditEntries = auditDirectories(audit).filter(
    (directory) => directory === "services/linux-attestation-facade",
  );
  if (facadeAuditEntries.length !== 1) {
    fail("AUDIT_DIRS must contain the Linux attestation facade exactly once");
  }

  return { passed: failures.length === 0, failures };
}

function run(root) {
  const result = verifyLinuxAttestationFacadeCi({
    workflow: readFileSync(join(root, ".github/workflows/fast-feedback.yml"), "utf8"),
    dependabot: readFileSync(join(root, ".github/dependabot.yml"), "utf8"),
    audit: readFileSync(join(root, "scripts/ci/check-npm-audit-fail-closed.mjs"), "utf8"),
  });
  if (!result.passed) {
    console.error("Linux attestation facade CI verification failed:");
    for (const failure of result.failures) console.error(`- ${failure}`);
    return 1;
  }
  console.log("PASS: Linux attestation facade CI is path-scoped and fail closed.");
  return 0;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const root = process.env.LINUX_ATTESTATION_FACADE_CI_ROOT ?? DEFAULT_ROOT;
  process.exit(run(root));
}
