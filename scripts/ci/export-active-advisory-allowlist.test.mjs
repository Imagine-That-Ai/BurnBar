#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

import {
  parseOsvIgnoredVulnerabilities,
  resolveActiveAdvisoryAllowlist,
} from "./export-active-advisory-allowlist.mjs";

const ID = "GHSA-mh99-v99m-4gvg";
const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, "..", "..");
const EXPORTER = join(SCRIPT_DIR, "export-active-advisory-allowlist.mjs");
const NPM_ALLOWLIST = {
  [ID]: {
    reason: "fixture reason for the time-boxed exception",
    expires: "2026-08-21",
  },
};
const OSV_CONFIG = `
[[IgnoredVulns]]
id = "${ID}"
ignoreUntil = 2026-08-21T00:00:00Z
# reason: fixture
reason = "fixture reason for the time-boxed exception"
`;

test("parses the OSV ignored-vulnerability policy", () => {
  assert.deepEqual(parseOsvIgnoredVulnerabilities(OSV_CONFIG), [
    {
      id: ID,
      ignoreUntil: "2026-08-21T00:00:00Z",
      reason: "fixture reason for the time-boxed exception",
    },
  ]);
});

test("exports an advisory only while both paired policies are active", () => {
  const osvEntries = parseOsvIgnoredVulnerabilities(OSV_CONFIG);
  assert.deepEqual(
    resolveActiveAdvisoryAllowlist({
      npmAllowlist: NPM_ALLOWLIST,
      osvEntries,
      now: new Date("2026-07-29T00:00:00Z"),
    }),
    [ID],
  );
  assert.deepEqual(
    resolveActiveAdvisoryAllowlist({
      npmAllowlist: NPM_ALLOWLIST,
      osvEntries,
      now: new Date("2026-08-21T00:00:00Z"),
    }),
    [],
  );
});

test("fails closed when the npm and OSV advisory sets drift", () => {
  assert.throws(
    () =>
      resolveActiveAdvisoryAllowlist({
        npmAllowlist: NPM_ALLOWLIST,
        osvEntries: [],
      }),
    /out of sync/u,
  );
});

test("fails closed when paired expiries drift", () => {
  const osvEntries = parseOsvIgnoredVulnerabilities(
    OSV_CONFIG.replace("2026-08-21T00:00:00Z", "2026-08-22T00:00:00Z"),
  );
  assert.throws(
    () =>
      resolveActiveAdvisoryAllowlist({
        npmAllowlist: NPM_ALLOWLIST,
        osvEntries,
      }),
    /expiry mismatch/u,
  );
});

test("fails closed on malformed OSV entries", () => {
  assert.throws(
    () =>
      resolveActiveAdvisoryAllowlist({
        npmAllowlist: NPM_ALLOWLIST,
        osvEntries: [
          { id: ID, ignoreUntil: "not-a-date", reason: "fixture reason" },
        ],
      }),
    /Malformed/u,
  );
});

test("CLI loads advisory data from explicit trusted policy paths", () => {
  const root = mkdtempSync(join(tmpdir(), "trusted-advisory-policy-"));
  try {
    const trustedPolicy = join(root, "check-npm-audit-fail-closed.mjs");
    const trustedOsv = join(root, "osv-scanner.toml");
    const githubOutput = join(root, "github-output.txt");
    const farFutureAllowlist = {
      [ID]: {
        reason: "trusted base fixture exception",
        expires: "2999-12-31",
      },
    };
    writeFileSync(
      trustedPolicy,
      `export const ADVISORY_ALLOWLIST = ${JSON.stringify(farFutureAllowlist)};\n`,
    );
    writeFileSync(
      trustedOsv,
      `[[IgnoredVulns]]
id = "${ID}"
ignoreUntil = 2999-12-31T00:00:00Z
reason = "trusted base fixture exception"
`,
    );

    const result = spawnSync(
      process.execPath,
      [
        EXPORTER,
        "--npm-policy-module",
        trustedPolicy,
        "--osv-config",
        trustedOsv,
      ],
      {
        cwd: REPO_ROOT,
        encoding: "utf8",
        env: { ...process.env, GITHUB_OUTPUT: githubOutput },
      },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(githubOutput, "utf8"), `allow-ghsas=${ID}\n`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("Dependency Review resolves exceptions from the exact trusted base", () => {
  const workflow = readFileSync(
    join(REPO_ROOT, ".github", "workflows", "security-pr.yml"),
    "utf8",
  );
  const start = workflow.indexOf("  dependency-review:");
  const end = workflow.indexOf("\n  npm-audit:", start);
  assert.notEqual(start, -1);
  assert.notEqual(end, -1);
  const job = workflow.slice(start, end);

  assert.match(job, /ref: \$\{\{ github\.event\.pull_request\.base\.sha \}\}/u);
  assert.match(job, /path: \.trusted-advisory-policy/u);
  assert.match(job, /persist-credentials: false/u);
  assert.match(job, /scripts\/ci\/check-npm-audit-fail-closed\.mjs/u);
  assert.match(job, /osv-scanner\.toml/u);
  assert.match(
    job,
    /--npm-policy-module[\s\S]*\.trusted-advisory-policy\/scripts\/ci\/check-npm-audit-fail-closed\.mjs/u,
  );
  assert.match(
    job,
    /--osv-config[\s\S]*\.trusted-advisory-policy\/osv-scanner\.toml/u,
  );
});
