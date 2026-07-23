#!/usr/bin/env node
/**
 * Fail-closed npm audit gate for PR security checks.
 *
 * npm audit exits non-zero both for high/critical findings and for service or
 * transport errors. This wrapper parses the JSON report when available, but it
 * never converts audit execution failures into a passing check.
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const AUDIT_DIRS = [
  ".",
  "apps/console",
  "apps/linux-desktop",
  "extensions/openburnbar",
  "firestore-rules-tests",
  "functions",
  "packages/design-tokens",
  "packages/entitlements",
  "packages/libsignal-bridge",
  "packages/libsignal-protocol",
  "packages/signal-envelope-contracts",
  "quota-runner",
  "services/hermes-realtime-relay",
  "services/hosted-mcp",
  "tools/app-store-connect",
  "tools/openburnbar-mcp-remote",
  "tools/schema-sync",
  "website",
];

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function severeVulnerabilities(report) {
  const vulnerabilities = isObject(report.vulnerabilities)
    ? report.vulnerabilities
    : {};
  return Object.entries(vulnerabilities).filter(
    ([, vulnerability]) =>
      isObject(vulnerability) &&
      (vulnerability.severity === "high" ||
        vulnerability.severity === "critical"),
  );
}

export function classifyAuditResult({ dir, status, stdout, stderr, error }) {
  if (error) {
    return {
      ok: false,
      retryable: true,
      messages: [`npm audit could not start for ${dir}: ${error.message}`],
    };
  }

  const raw = (stdout ?? "").trim();
  if (!raw) {
    return {
      ok: false,
      retryable: true,
      messages: [
        `npm audit produced no JSON for ${dir} (exit ${status ?? "unknown"}).`,
        (stderr ?? "").trim(),
      ].filter(Boolean),
    };
  }

  let report;
  try {
    report = JSON.parse(raw);
  } catch (parseError) {
    return {
      ok: false,
      retryable: true,
      messages: [
        `npm audit produced invalid JSON for ${dir} (exit ${status ?? "unknown"}): ${parseError.message}`,
        (stderr ?? "").trim(),
      ].filter(Boolean),
    };
  }

  const severe = severeVulnerabilities(report);
  if (severe.length > 0) {
    return {
      ok: false,
      retryable: false,
      messages: [
        `High/critical vulnerabilities found in ${dir}:`,
        ...severe.map(
          ([name, vulnerability]) => `  ${name}: ${vulnerability.severity}`,
        ),
      ],
    };
  }

  if (status !== 0) {
    return {
      ok: false,
      retryable: true,
      messages: [
        `npm audit exited ${status ?? "unknown"} for ${dir} without high/critical findings in JSON; failing closed.`,
        (stderr ?? "").trim(),
      ].filter(Boolean),
    };
  }

  return {
    ok: true,
    retryable: false,
    messages: [`No high/critical vulnerabilities in ${dir}.`],
  };
}

export const AUDIT_ATTEMPTS = 3;
const RETRY_BACKOFF_SECONDS = [5, 15];

function runAuditOnce(absoluteDir, dir) {
  // registry.npmjs.org's audit endpoint intermittently answers 400/429/5xx.
  // npm surfaces that as a non-zero exit with no findings, which this gate
  // (correctly) fails closed on -- so a registry hiccup ejects merge-queue
  // candidates. Retry only outcomes that indicate a transport/service problem.
  // A high/critical finding is marked non-retryable and still fails on the
  // first attempt, so retries can never launder a real vulnerability.
  let result = runAuditOnce(absoluteDir, dir);
  for (let attempt = 1; attempt < AUDIT_ATTEMPTS && result.retryable; attempt += 1) {
    const backoff = RETRY_BACKOFF_SECONDS[attempt - 1] ?? 15;
    console.log(
      `    npm audit for ${dir} failed transiently; retrying in ${backoff}s ` +
        `(attempt ${attempt + 1}/${AUDIT_ATTEMPTS})`,
    );
    spawnSync("sleep", [String(backoff)]);
    result = runAuditOnce(absoluteDir, dir);
  }
  return result;
}

function auditDirectory(repoRoot, dir) {
  const absoluteDir = join(repoRoot, dir);
  if (!existsSync(join(absoluteDir, "package-lock.json"))) {
    return {
      ok: false,
      retryable: false,
      messages: [`Configured npm audit directory is missing package-lock.json: ${dir}`],
    };
  }

  // registry.npmjs.org's audit endpoint intermittently answers 400/429/5xx.
  // npm surfaces that as a non-zero exit with no findings, which this gate
  // (correctly) fails closed on -- so a registry hiccup ejects merge-queue
  // candidates. Retry only outcomes that indicate a transport/service problem.
  // A high/critical finding is marked non-retryable and still fails on the
  // first attempt, so retries can never launder a real vulnerability.
  let result = runAuditOnce(absoluteDir, dir);
  for (let attempt = 1; attempt < AUDIT_ATTEMPTS && result.retryable; attempt += 1) {
    const backoff = RETRY_BACKOFF_SECONDS[attempt - 1] ?? 15;
    console.log(
      `    npm audit for ${dir} failed transiently; retrying in ${backoff}s ` +
        `(attempt ${attempt + 1}/${AUDIT_ATTEMPTS})`,
    );
    spawnSync("sleep", [String(backoff)]);
    result = runAuditOnce(absoluteDir, dir);
  }
  return result;
}

export function runAuditGate(repoRoot = REPO_ROOT, dirs = AUDIT_DIRS) {
  let ok = true;
  for (const dir of dirs) {
    console.log(`==> npm audit: ${dir}`);
    const result = auditDirectory(repoRoot, dir);
    for (const message of result.messages) {
      const writer = result.ok ? console.log : console.error;
      writer(message);
    }
    ok = ok && result.ok;
  }
  return ok;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(runAuditGate() ? 0 : 1);
}
