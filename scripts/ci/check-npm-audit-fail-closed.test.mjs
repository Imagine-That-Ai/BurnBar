#!/usr/bin/env node
/**
 * Self-test for scripts/ci/check-npm-audit-fail-closed.mjs.
 */

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { AUDIT_DIRS, classifyAuditResult } from "./check-npm-audit-fail-closed.mjs";

let passed = 0;
let failed = 0;

function expect(label, input, wantOk, wantMessagePattern = null) {
  const result = classifyAuditResult({ dir: "fixture", stderr: "", ...input });
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
  const SKIP = new Set(["node_modules", ".git"]);
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

console.log(
  `\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`,
);
process.exit(failed === 0 ? 0 : 1);