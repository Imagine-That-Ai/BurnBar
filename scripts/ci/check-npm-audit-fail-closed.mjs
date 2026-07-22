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
      messages: [`npm audit could not start for ${dir}: ${error.message}`],
    };
  }

  const raw = (stdout ?? "").trim();
  if (!raw) {
    return {
      ok: false,
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
      messages: [
        `npm audit exited ${status ?? "unknown"} for ${dir} without high/critical findings in JSON; failing closed.`,
        (stderr ?? "").trim(),
      ].filter(Boolean),
    };
  }

  return {
    ok: true,
    messages: [`No high/critical vulnerabilities in ${dir}.`],
  };
}

function auditDirectory(repoRoot, dir) {
  const absoluteDir = join(repoRoot, dir);
  if (!existsSync(join(absoluteDir, "package-lock.json"))) {
    return {
      ok: false,
      messages: [`Configured npm audit directory is missing package-lock.json: ${dir}`],
    };
  }

  const result = spawnSync(
    "npm",
    ["audit", "--prefix", absoluteDir, "--audit-level=high", "--json"],
    {
      encoding: "utf8",
      maxBuffer: 20 * 1024 * 1024,
    },
  );

  return classifyAuditResult({
    dir,
    status: result.status,
    stdout: result.stdout,
    stderr: result.stderr,
    error: result.error,
  });
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
