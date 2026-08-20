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
  "extensions/safari",
  "firestore-rules-tests",
  "functions",
  "packages/design-tokens",
  "packages/entitlements",
  "packages/libsignal-bridge",
  "packages/libsignal-protocol",
  "packages/signal-envelope-contracts",
  "quota-runner",
  "scripts/linux-port",
  "services/hermes-realtime-relay",
  "services/hosted-mcp",
  "tools/app-store-connect",
  "tools/hermes-platform-burnbar/signal-runtime",
  "tools/openburnbar-mcp-remote",
  "tools/schema-sync",
  "website",
];

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

/**
 * Time-boxed advisory allowlist for findings with NO actionable fix.
 *
 * An entry only ever tolerates a finding whose ENTIRE via-chain resolves to
 * allowlisted advisories, and only until its `expires` date (UTC): past that
 * date the gate fails closed again, forcing re-evaluation instead of letting a
 * suppression rot. Keep entries in sync with the osv-scanner.toml ignore list
 * (same id, same expiry) and the rationale in docs/LINT_RATIONALE.md.
 */
// No advisories are currently tolerated. Every entry must be time-boxed
// ({ reason, expires: "YYYY-MM-DD" }, keyed by GHSA id) and kept in sync with
// the paired osv-scanner.toml ignore (same id, same expiry) plus the rationale
// in docs/LINT_RATIONALE.md. The last entry (GHSA-mh99-v99m-4gvg,
// brace-expansion DoS) was retired when the vendored callable shim in
// functions/vendor/openburnbar/brace-expansion-cjs removed the final
// vulnerable 1.x copies from the dependency tree.
export const ADVISORY_ALLOWLIST = {};

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

const GHSA_RE =
  /GHSA-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}-[23456789cfghjmpqrvwx]{4}/i;

export function activeAllowlistEntry(ghsaId, allowlist, now) {
  const entry = allowlist[ghsaId];
  if (!isObject(entry)) return null;
  // An unparseable expiry is treated as already expired: fail closed.
  const expires = Date.parse(`${entry.expires}T23:59:59Z`);
  if (Number.isNaN(expires) || now.getTime() > expires) return null;
  return entry;
}

/**
 * A vulnerability entry is tolerated iff EVERY advisory object in its
 * transitive via-chain resolves to an active allowlist entry. String vias name
 * another vulnerable package; that package's own entry must itself be fully
 * tolerated. Anything unresolvable (missing package, cycle, advisory without a
 * GHSA id) fails closed.
 */
function isTolerated(
  name,
  vulnerabilities,
  allowlist,
  now,
  visiting = new Set(),
) {
  if (visiting.has(name)) return false;
  const vulnerability = vulnerabilities[name];
  if (
    !isObject(vulnerability) ||
    !Array.isArray(vulnerability.via) ||
    vulnerability.via.length === 0
  ) {
    return false;
  }
  visiting.add(name);
  try {
    for (const via of vulnerability.via) {
      if (typeof via === "string") {
        if (!isTolerated(via, vulnerabilities, allowlist, now, visiting))
          return false;
        continue;
      }
      if (!isObject(via)) return false;
      const ghsa = `${via.url ?? ""}`.match(GHSA_RE);
      if (!ghsa || !activeAllowlistEntry(ghsa[0], allowlist, now)) return false;
    }
    return true;
  } finally {
    visiting.delete(name);
  }
}

export function classifyAuditResult(
  { dir, status, stdout, stderr, error },
  { allowlist = ADVISORY_ALLOWLIST, now = new Date() } = {},
) {
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
  const vulnerabilities = isObject(report.vulnerabilities)
    ? report.vulnerabilities
    : {};
  const tolerated = severe.filter(([name]) =>
    isTolerated(name, vulnerabilities, allowlist, now),
  );
  const blocking = severe.filter(
    ([name]) => !tolerated.some(([toleratedName]) => toleratedName === name),
  );
  if (blocking.length > 0) {
    return {
      ok: false,
      retryable: false,
      messages: [
        `High/critical vulnerabilities found in ${dir}:`,
        ...blocking.map(
          ([name, vulnerability]) => `  ${name}: ${vulnerability.severity}`,
        ),
      ],
    };
  }

  if (tolerated.length > 0) {
    // npm audit exits non-zero for these findings, but every one of them
    // resolves to a time-boxed allowlist entry: pass, loudly.
    return {
      ok: true,
      retryable: false,
      messages: [
        `Tolerated allowlisted advisories in ${dir} (time-boxed, see ADVISORY_ALLOWLIST):`,
        ...tolerated.map(
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

function sleepSeconds(seconds) {
  spawnSync("sleep", [String(seconds)]);
}

/**
 * Run `attempt` until it yields a non-retryable outcome or the budget is spent.
 *
 * registry.npmjs.org's audit endpoint intermittently answers 400/429/5xx. npm
 * surfaces that as a non-zero exit with no findings, which this gate correctly
 * fails closed on -- so a registry hiccup ejects merge-queue candidates and
 * discards hours of gate work. Only transport/service outcomes are retryable;
 * a high/critical finding is non-retryable and still fails on attempt 1, so a
 * retry can never launder a real vulnerability.
 *
 * Kept pure (attempt/sleep/log injected) so the self-test can prove the attempt
 * count directly instead of hitting the network.
 */
export function runWithRetries(
  attempt,
  {
    attempts = AUDIT_ATTEMPTS,
    sleep = sleepSeconds,
    log = console.log,
    label = "npm audit",
  } = {},
) {
  let result = attempt();
  for (let index = 1; index < attempts && result.retryable; index += 1) {
    const backoff = RETRY_BACKOFF_SECONDS[index - 1] ?? 15;
    log(
      `    ${label} failed transiently; retrying in ${backoff}s ` +
        `(attempt ${index + 1}/${attempts})`,
    );
    sleep(backoff);
    result = attempt();
  }
  return result;
}

function runAuditOnce(absoluteDir, dir) {
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

function auditDirectory(repoRoot, dir) {
  const absoluteDir = join(repoRoot, dir);
  if (!existsSync(join(absoluteDir, "package-lock.json"))) {
    return {
      ok: false,
      retryable: false,
      messages: [
        `Configured npm audit directory is missing package-lock.json: ${dir}`,
      ],
    };
  }

  return runWithRetries(() => runAuditOnce(absoluteDir, dir), {
    label: `npm audit for ${dir}`,
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
