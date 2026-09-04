#!/usr/bin/env node
/**
 * Fail-closed npm audit gate for PR security checks.
 *
 * npm audit exits non-zero both for high/critical findings and for service or
 * transport errors. This wrapper parses the JSON report when available, but it
 * never converts audit execution failures into a passing check.
 */

import { spawn, spawnSync } from "node:child_process";
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
// Every entry must be time-boxed ({ reason, expires: "YYYY-MM-DD" }, keyed by
// GHSA id) and kept in sync with the paired osv-scanner.toml ignore (same id,
// same expiry) plus the rationale in docs/LINT_RATIONALE.md. The previous entry
// (GHSA-mh99-v99m-4gvg, brace-expansion DoS) was retired when the vendored
// callable shim in functions/vendor/openburnbar/brace-expansion-cjs removed the
// final vulnerable 1.x copies from the dependency tree.
export const ADVISORY_ALLOWLIST = {
  "GHSA-528h-pc64-c93x": {
    // reason: quadratic path-recompute DoS in stream-json's pick/ignore/filter/
    // replace filters. Only firebase-tools depends on it, as a devDependency,
    // and it requires the 1.x CommonJS entry points. The only fixed line
    // (3.5.0+) is pure ESM with renamed exports and stream-chain 4 factory
    // links; forcing it through an override was measured and breaks
    // `firebase database:import`, `firebase auth:import` and the Next.js
    // framework integration with MODULE_NOT_FOUND. firebase-tools 15.29.0 still
    // declares `stream-json: ^1.7.3`, and no patched 1.x release exists, so
    // there is nothing to bump to. Unreachable in this consumer: the filters
    // only see developer-selected local files from a CLI, never untrusted
    // request bodies on a served event loop, and the package is never part of a
    // deployed functions bundle. Re-evaluate when firebase-tools migrates.
    reason:
      "stream-json filter DoS: dev-only transitive of firebase-tools, which requires the 1.x CommonJS entry points; the only fix (3.5.0+) is ESM-only with renamed exports and breaks database:import/auth:import/Next.js at load time, and no patched 1.x exists.",
    expires: "2026-12-03",
  },
};

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

/**
 * Bounded parallelism for the pooled runner. Four concurrent audits keeps a
 * degraded registry from serialising ~20 lockfile audits into an hour-plus of
 * wall time (2026-09-03/04 incident) while staying gentle on the audit
 * endpoint and the runner's own CPU (each npm audit is mostly network wait).
 */
export const AUDIT_CONCURRENCY = 4;
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

/**
 * Async variant used by the pooled runner: identical args and classification
 * as runAuditOnce, just through child_process.spawn so multiple audits can be
 * in flight at once. Verdicts are byte-for-byte the same classifier.
 */
function runAuditOnceAsync(absoluteDir, dir) {
  return new Promise((resolve) => {
    const child = spawn(
      "npm",
      ["audit", "--prefix", absoluteDir, "--audit-level=high", "--json"],
      { encoding: "utf8" },
    );
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (stdout.length > 20 * 1024 * 1024) child.kill();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      resolve(
        classifyAuditResult({ dir, status: null, stdout, stderr, error }),
      );
    });
    child.on("close", (status) => {
      resolve(classifyAuditResult({ dir, status, stdout, stderr }));
    });
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

/**
 * Pooled variant: same preflight check and retry budget as auditDirectory,
 * but awaits the async audit subprocess. Used by runAuditGate's worker pool.
 */
async function auditDirectoryAsync(repoRoot, dir) {
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

  // runWithRetries drives a synchronous attempt; the async variant needs the
  // same bounded-attempt loop expressed as a promise chain. Same budget, same
  // backoff, same non-retryable-on-findings semantics.
  const attempt = () => runAuditOnceAsync(absoluteDir, dir);
  const sleep = (seconds) =>
    new Promise((resolve) => {
      setTimeout(resolve, seconds * 1000);
    });
  let result = await attempt();
  for (let index = 1; index < AUDIT_ATTEMPTS && result.retryable; index += 1) {
    const backoff = RETRY_BACKOFF_SECONDS[index - 1] ?? 15;
    console.log(
      `    npm audit for ${dir} failed transiently; retrying in ${backoff}s ` +
        `(attempt ${index + 1}/${AUDIT_ATTEMPTS})`,
    );
    await sleep(backoff);
    result = await attempt();
  }
  return result;
}

export function runAuditGate(
  repoRoot = REPO_ROOT,
  dirs = AUDIT_DIRS,
  { concurrency = AUDIT_CONCURRENCY, auditRunner = auditDirectoryAsync } = {},
) {
  // The audits are independent subprocesses, so a bounded pool across
  // directories does not change any verdict: every directory keeps its own
  // fail-closed classification and attempt/retry budget, and the gate fails
  // if ANY directory fails. Serial execution spent 3-7 minutes per directory
  // during the 2026-09-03/04 npm registry degradation (~20 dirs = over an
  // hour of wall time), turning a transport slowdown into required-check
  // failures on every PR. Concurrency shortens wall time only; it never
  // converts a failure into a pass. auditRunner is the test seam.
  const queue = [...dirs];
  const results = new Map();

  async function worker() {
    for (let dir = queue.shift(); dir !== undefined; dir = queue.shift()) {
      console.log(`==> npm audit: ${dir}`);
      results.set(dir, await auditRunner(repoRoot, dir));
    }
  }

  return (async () => {
    const lanes = Math.min(concurrency, dirs.length);
    await Promise.all(Array.from({ length: lanes }, worker));
    // Report in the configured order so the log stays deterministic
    // regardless of which lane finished first.
    let ok = true;
    for (const dir of dirs) {
      const result = results.get(dir);
      for (const message of result.messages) {
        const writer = result.ok ? console.log : console.error;
        writer(message);
      }
      ok = ok && result.ok;
    }
    return ok;
  })();
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  runAuditGate().then((ok) => process.exit(ok ? 0 : 1));
}
