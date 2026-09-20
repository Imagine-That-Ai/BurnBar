#!/usr/bin/env node
/**
 * Self-test for scripts/ci/check-npm-audit-fail-closed.mjs.
 */

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import {
  ADVISORY_ALLOWLIST,
  AUDIT_DIRS,
  AUDIT_ATTEMPTS,
  AUDIT_CONCURRENCY,
  classifyAuditResult,
  runAuditGate,
  runWithRetries,
} from "./check-npm-audit-fail-closed.mjs";

// The pooled-runner block below uses top-level await, which .mjs supports.

let passed = 0;
let failed = 0;

function expect(label, input, wantOk, wantMessagePattern = null, options = undefined) {
  const result = classifyAuditResult(
    { dir: "fixture", stderr: "", ...input },
    options,
  );
  const message = result.messages.join("\n");
  const messageMatches = wantMessagePattern
    ? wantMessagePattern.test(message)
    : true;
  if (result.ok === wantOk && messageMatches) {
    console.log(`  ✓ ${label}`);
    passed += 1;
    return;
  }
  console.error(
    `  ✗ ${label}: got ok=${result.ok}, messages=${JSON.stringify(result.messages)}`,
  );
  failed += 1;
}

console.log("Self-test: check-npm-audit-fail-closed.mjs\n");

// Discover every package-lock.json root in the repo at runtime. A static list
// cannot guard "every root": a new lockfile created without scanner wiring
// would slip through unnoticed. This walk is the source of truth, so both
// scanners (npm-audit AUDIT_DIRS and the OSV --lockfile= entries) are checked
// against the discovered set and redden automatically when a lockfile appears
// that neither scanner was wired for.
//
// Skips node_modules, .git, and hidden directories (dot-prefixed, which also
// covers worktree metadata) so the walk stays cheap and never invents roots
// from vendored or metadata trees. The walk always recurses past a lockfile
// root because node_modules is skipped globally; this finds genuine first-party
// lockfiles in sibling and nested directories without double-counting.
function discoverLockfileRoots(repoRoot) {
  const roots = [];
  // Vendor contains pinned upstream gitlinks whose own test fixtures may ship
  // package locks when submodules are initialized locally. They are not
  // first-party npm workspaces and are audited by their dedicated provenance
  // and supply-chain gates.
  const SKIP = new Set(["node_modules", ".git", "Vendor"]);
  function walk(absDir) {
    let entries = [];
    try {
      entries = readdirSync(absDir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.name === "package-lock.json" && entry.isFile()) {
        const rel = relative(repoRoot, absDir) || ".";
        roots.push(rel);
        break;
      }
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      if (SKIP.has(entry.name)) continue;
      if (entry.name.startsWith(".")) continue;
      walk(join(absDir, entry.name));
    }
  }
  walk(repoRoot);
  return roots.sort();
}

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, "..", "..");
const DISCOVERED_ROOTS = discoverLockfileRoots(REPO_ROOT);

{
  const label = "AUDIT_DIRS covers every discovered package-lock root exactly";
  const sameLength = AUDIT_DIRS.length === DISCOVERED_ROOTS.length;
  const sameMembers =
    sameLength &&
    DISCOVERED_ROOTS.every((dir, index) => AUDIT_DIRS[index] === dir);
  if (sameMembers) {
    console.log(`  ✓ ${label}`);
    passed += 1;
  } else {
    console.error(
      `  ✗ ${label}: expected ${JSON.stringify(DISCOVERED_ROOTS)}, got ${JSON.stringify(AUDIT_DIRS)}`,
    );
    failed += 1;
  }
}

// The OSV-Scanner job in security-pr.yml must scan the same package-lock roots
// the npm-audit gate covers. A divergence here is the same class of bug as
// PR #1811 (a root silently dropped from one scanner but not the other). The
// assertion parses the workflow's `--lockfile=<root>/package-lock.json` entries
// (plus the bare `--lockfile=package-lock.json` form for the repo root) and
// requires the set of roots to match the discovered set exactly.
{
  const label =
    "security-pr.yml OSV --lockfile= entries match discovered roots exactly";
  const workflowPath = join(REPO_ROOT, ".github", "workflows", "security-pr.yml");
  const workflow = readFileSync(workflowPath, "utf8");
  const lockfileEntries = [
    ...workflow.matchAll(/--lockfile=([^\s]+)\/package-lock\.json/g),
  ]
    .map((match) => match[1])
    .sort();
  // The repo root (".") maps to a bare `--lockfile=package-lock.json` with no
  // leading directory; match that form too.
  if (/--lockfile=package-lock\.json(?!\S)/.test(workflow)) {
    lockfileEntries.push(".");
    lockfileEntries.sort();
  }
  const sameLength = lockfileEntries.length === DISCOVERED_ROOTS.length;
  const sameMembers =
    sameLength &&
    DISCOVERED_ROOTS.every((dir, index) => lockfileEntries[index] === dir);
  if (sameMembers) {
    console.log(`  ✓ ${label}`);
    passed += 1;
  } else {
    console.error(
      `  ✗ ${label}: expected ${JSON.stringify(DISCOVERED_ROOTS)}, got ${JSON.stringify(lockfileEntries)}`,
    );
    failed += 1;
  }
}

expect(
  "clean report passes",
  {
    status: 0,
    stdout: JSON.stringify({ vulnerabilities: {} }),
  },
  true,
);

expect(
  "low-only report passes",
  {
    status: 0,
    stdout: JSON.stringify({ vulnerabilities: { demo: { severity: "low" } } }),
  },
  true,
);

expect(
  "high vulnerability fails",
  {
    status: 1,
    stdout: JSON.stringify({ vulnerabilities: { demo: { severity: "high" } } }),
  },
  false,
  /High\/critical vulnerabilities/u,
);

expect(
  "critical vulnerability fails",
  {
    status: 1,
    stdout: JSON.stringify({
      vulnerabilities: { demo: { severity: "critical" } },
    }),
  },
  false,
  /High\/critical vulnerabilities/u,
);

// --- advisory allowlist -----------------------------------------------------
// A time-boxed allowlist entry tolerates a finding only while unexpired and
// only when the finding's ENTIRE via-chain resolves to allowlisted advisories.
// Everything else stays fail-closed.
const ALLOWLIST = {
  "GHSA-mh99-v99m-4gvg": { reason: "fixture reason", expires: "2026-08-21" },
};
const BEFORE_EXPIRY = { allowlist: ALLOWLIST, now: new Date("2026-07-24T00:00:00Z") };
const AFTER_EXPIRY = { allowlist: ALLOWLIST, now: new Date("2026-08-22T00:00:00Z") };
const ALLOWLISTED_ADVISORY = {
  url: "https://github.com/advisories/GHSA-mh99-v99m-4gvg",
  severity: "high",
};
const UNLISTED_ADVISORY = {
  url: "https://github.com/advisories/GHSA-2222-3333-4444",
  severity: "high",
};
const CHAINED_REPORT = JSON.stringify({
  vulnerabilities: {
    "brace-expansion": { severity: "high", via: [ALLOWLISTED_ADVISORY] },
    minimatch: { severity: "high", via: ["brace-expansion"] },
  },
});

expect(
  "allowlisted advisory chain is tolerated before expiry",
  { status: 1, stdout: CHAINED_REPORT },
  true,
  /Tolerated allowlisted advisories/u,
  BEFORE_EXPIRY,
);

expect(
  "allowlisted advisory fails again after expiry",
  { status: 1, stdout: CHAINED_REPORT },
  false,
  /High\/critical vulnerabilities/u,
  AFTER_EXPIRY,
);

expect(
  "a via-chain mixing allowlisted and unlisted advisories fails",
  {
    status: 1,
    stdout: JSON.stringify({
      vulnerabilities: {
        demo: { severity: "high", via: [ALLOWLISTED_ADVISORY, UNLISTED_ADVISORY] },
      },
    }),
  },
  false,
  /High\/critical vulnerabilities/u,
  BEFORE_EXPIRY,
);

expect(
  "a string via naming a package missing from the report fails closed",
  {
    status: 1,
    stdout: JSON.stringify({
      vulnerabilities: {
        demo: { severity: "high", via: ["not-in-report"] },
      },
    }),
  },
  false,
  /High\/critical vulnerabilities/u,
  BEFORE_EXPIRY,
);

expect(
  "an empty via-chain fails closed",
  {
    status: 1,
    stdout: JSON.stringify({
      vulnerabilities: { demo: { severity: "high", via: [] } },
    }),
  },
  false,
  /High\/critical vulnerabilities/u,
  BEFORE_EXPIRY,
);

{
  const label = "every real ADVISORY_ALLOWLIST entry carries a reason and a parseable expiry";
  const wellFormed = Object.entries(ADVISORY_ALLOWLIST).every(
    ([id, entry]) =>
      /^GHSA-/.test(id) &&
      typeof entry.reason === "string" &&
      entry.reason.length >= 8 &&
      !Number.isNaN(Date.parse(`${entry.expires}T23:59:59Z`)),
  );
  if (wellFormed) {
    console.log(`  ✓ ${label}`);
    passed += 1;
  } else {
    console.error(`  ✗ ${label}`);
    failed += 1;
  }
}

expect(
  "audit service failure with empty output fails closed",
  {
    status: 1,
    stdout: "",
    stderr: "npm ERR! audit endpoint unavailable",
  },
  false,
  /produced no JSON/u,
);

expect(
  "audit service failure with invalid JSON fails closed",
  {
    status: 1,
    stdout: "npm ERR! upstream reset",
    stderr: "npm ERR! upstream reset",
  },
  false,
  /invalid JSON/u,
);

expect(
  "nonzero audit without severe findings fails closed",
  {
    status: 1,
    stdout: JSON.stringify({
      vulnerabilities: { demo: { severity: "moderate" } },
    }),
    stderr: "npm ERR! registry warning",
  },
  false,
  /failing closed/u,
);

expect(
  "spawn failure fails closed",
  {
    status: null,
    stdout: "",
    error: new Error("spawn npm ENOENT"),
  },
  false,
  /could not start/u,
);

// --- retry classification -------------------------------------------------
// The gate retries transport/service failures because registry.npmjs.org's
// audit endpoint intermittently answers 400/429/5xx, and a fail-closed gate
// turns that hiccup into an ejected merge-queue candidate. Retries must never
// be able to launder a real finding, so severity results are non-retryable.
function expectRetryable(label, input, wantRetryable) {
  const result = classifyAuditResult({ dir: "fixture", stderr: "", ...input });
  if (result.retryable === wantRetryable) {
    console.log(`  \u2713 ${label}`);
    passed += 1;
    return;
  }
  console.error(
    `  \u2717 ${label}: got retryable=${result.retryable}, want ${wantRetryable}`,
  );
  failed += 1;
}

expectRetryable(
  "high/critical findings are NEVER retried",
  {
    status: 1,
    stdout: JSON.stringify({
      vulnerabilities: { demo: { severity: "critical" } },
    }),
  },
  false,
);

expectRetryable(
  "registry error without findings is retryable",
  {
    status: 1,
    stdout: JSON.stringify({ vulnerabilities: { demo: { severity: "moderate" } } }),
    stderr: "npm warn audit 400 Bad Request - POST .../security/audits/quick",
  },
  true,
);

expectRetryable(
  "empty audit output is retryable",
  { status: 1, stdout: "" },
  true,
);

expectRetryable(
  "invalid JSON is retryable",
  { status: 1, stdout: "<html>502</html>" },
  true,
);

expectRetryable(
  "spawn failure is retryable",
  { status: null, stdout: "", error: new Error("spawn npm ENOENT") },
  true,
);

expectRetryable("clean audit is not retryable", { status: 0, stdout: "{}" }, false);

// --- retry driver ---------------------------------------------------------
// runWithRetries takes the attempt as a callback so the attempt COUNT is
// provable here without touching the network. An earlier revision of this gate
// shipped a runner that called itself instead of running npm, which blew the
// stack in CI while these classifier tests still passed -- so assert on how
// many times the attempt actually runs.
function expectAttempts(label, outcomes, wantAttempts) {
  let calls = 0;
  const attempt = () => {
    const outcome = outcomes[Math.min(calls, outcomes.length - 1)];
    calls += 1;
    return outcome;
  };
  runWithRetries(attempt, { sleep: () => {}, log: () => {} });
  if (calls === wantAttempts) {
    console.log(`  \u2713 ${label}`);
    passed += 1;
    return;
  }
  console.error(`  \u2717 ${label}: attempted ${calls}x, want ${wantAttempts}`);
  failed += 1;
}

const RETRYABLE = { ok: false, retryable: true, messages: ["transient"] };
const FINDING = { ok: false, retryable: false, messages: ["critical"] };
const CLEAN = { ok: true, retryable: false, messages: ["clean"] };

expectAttempts("a high/critical finding is attempted exactly once", [FINDING], 1);
expectAttempts("a clean audit is attempted exactly once", [CLEAN], 1);
expectAttempts(
  "a persistent transport failure stops at the attempt budget",
  [RETRYABLE],
  AUDIT_ATTEMPTS,
);
expectAttempts(
  "a transient failure that recovers stops retrying",
  [RETRYABLE, CLEAN],
  2,
);

// --- pooled runner --------------------------------------------------------
// runAuditGate drives the same audits through a bounded pool (2026-09-03/04
// registry degradation: serial wall time exceeded every job budget). The
// pool must (a) bound concurrency, (b) keep every directory's own verdict,
// and (c) report in the configured order even when lanes finish out of order.
// auditRunner is the injected seam, so no network and no filesystem is
// touched: the fake runner resolves per-dir verdicts after controlled delays.
{
  const label = "runAuditGate pool: bounded lanes, per-dir verdicts, ordered reporting";

  // Fake audits: a resolves fast, b hangs a beat, c fails closed. The
  // in-flight probe proves at most `concurrency` audits run at once.
  const inFlight = { current: 0, max: 0 };
  const verdicts = new Map([
    ["a", { ok: true, retryable: false, messages: ["clean a"] }],
    ["b", { ok: true, retryable: false, messages: ["clean b"] }],
    ["c", { ok: false, retryable: false, messages: ["finding c"] }],
  ]);
  const delays = new Map([
    ["a", 5],
    ["b", 40],
    ["c", 15],
  ]);
  const fakeAudit = async (repoRoot, dir) => {
    inFlight.current += 1;
    inFlight.max = Math.max(inFlight.max, inFlight.current);
    await new Promise((resolve) => setTimeout(resolve, delays.get(dir)));
    inFlight.current -= 1;
    return verdicts.get(dir);
  };

  const events = [];
  const origLog = console.log;
  const origErr = console.error;
  console.log = (line) => events.push(["log", line]);
  console.error = (line) => events.push(["err", line]);
  try {
    const ok = await runAuditGate("/nonexistent-root", ["a", "b", "c"], {
      concurrency: 2,
      auditRunner: fakeAudit,
    });

    // c's finding fails the whole gate.
    if (ok === false) {
      passed += 1;
      origLog(`  \u2713 ${label}: gate fails when any directory fails`);
    } else {
      failed += 1;
      origErr(`  \u2717 ${label}: expected gate failure, got pass`);
    }

    // Bounded parallelism: with 3 dirs and concurrency 2, never 3 in flight.
    if (inFlight.max <= 2) {
      passed += 1;
      origLog(`  \u2713 ${label}: max in-flight ${inFlight.max} <= 2`);
    } else {
      failed += 1;
      origErr(`  \u2717 ${label}: concurrency exceeded bound (${inFlight.max})`);
    }

    // Ordered reporting: messages appear in a,b,c order regardless of delays.
    const messageOrder = events
      .map(([, line]) => line)
      .filter((line) => line.startsWith("clean ") || line.startsWith("finding "));
    const wantOrder = ["clean a", "clean b", "finding c"];
    if (JSON.stringify(messageOrder) === JSON.stringify(wantOrder)) {
      passed += 1;
      origLog(`  \u2713 ${label}: reporting order is deterministic`);
    } else {
      failed += 1;
      origErr(
        `  \u2717 ${label}: expected ${JSON.stringify(wantOrder)}, got ${JSON.stringify(messageOrder)}`,
      );
    }
  } finally {
    console.log = origLog;
    console.error = origErr;
  }
}

console.log(
  `\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`,
);
process.exit(failed === 0 ? 0 : 1);
