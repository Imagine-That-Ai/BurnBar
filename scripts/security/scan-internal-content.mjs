#!/usr/bin/env node
// Confidentiality guard for the OpenBurnBar PUBLIC repository.
//
// Classifies every file in the publishable tree against the declarative policy
// in internal-content-policy.mjs and fails if internal-only content (pricing,
// GTM strategy, open-vuln working notes, or anything self-declared confidential)
// is present. This is the layer the secret scanners cannot provide: it flags
// content that is sensitive but is not a credential.
//
// Usage:
//   node scripts/security/scan-internal-content.mjs            # full tracked tree (CI / release)
//   node scripts/security/scan-internal-content.mjs --staged   # staged files only (pre-commit)
//   node scripts/security/scan-internal-content.mjs --strict   # treat warnings as failures
//   node scripts/security/scan-internal-content.mjs --json      # machine-readable report
//
// Exit codes: 0 = clean, 1 = block-severity violation(s) (or any violation with --strict),
//             2 = usage/internal error.

import { execFileSync } from "node:child_process";
import { readFileSync, openSync, readSync, closeSync, fstatSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
import {
  INTERNAL_RULES,
  PUBLIC_ALLOWLIST,
  SELF_DECLARE_MARKERS,
  CONTENT_SCAN_EXEMPT,
  BINARY_OR_SKIP_CONTENT,
  MAX_CONTENT_BYTES,
  PRIVATE_HOME,
} from "./internal-content-policy.mjs";

// ── pure classification core (unit-tested directly) ───────────────────────

/** True if `path` is explicitly allowlisted as public. */
export function isAllowlisted(path) {
  return PUBLIC_ALLOWLIST.some((rule) => rule.paths.some((re) => re.test(path)));
}

/** Path-based rule match (first matching rule wins). Returns rule or null. */
export function matchPathRule(path) {
  for (const rule of INTERNAL_RULES) {
    if (rule.paths.some((re) => re.test(path))) return rule;
  }
  return null;
}

/** True if the file's content should be read for self-declared markers. */
export function shouldContentScan(path) {
  if (CONTENT_SCAN_EXEMPT.some((re) => re.test(path))) return false;
  if (BINARY_OR_SKIP_CONTENT.some((re) => re.test(path))) return false;
  return true;
}

/** True if text contains any self-declared confidentiality marker. */
export function hasSelfDeclaredMarker(text) {
  return SELF_DECLARE_MARKERS.some((re) => re.test(text));
}

/**
 * Classify one file given its path and a lazy content reader.
 * Returns a violation object or null. Allowlist always wins.
 * @param {string} path
 * @param {() => string|null} readContent  returns text or null if unreadable/binary
 */
export function classify(path, readContent) {
  if (isAllowlisted(path)) return null;

  const pathRule = matchPathRule(path);
  if (pathRule) {
    return {
      path,
      ruleId: pathRule.id,
      severity: pathRule.severity,
      reason: pathRule.reason,
      remediation: pathRule.remediation,
      matchedOn: "path",
    };
  }

  if (shouldContentScan(path)) {
    const text = readContent();
    if (text != null && hasSelfDeclaredMarker(text)) {
      return {
        path,
        ruleId: "self-declared",
        severity: "block",
        reason: "File carries a self-declared confidentiality banner.",
        remediation: `Move under ${PRIVATE_HOME} (the banner means it must not be public).`,
        matchedOn: "content",
      };
    }
  }
  return null;
}

/**
 * Scan a list of paths. `read` maps a path → text|null (injectable for tests).
 * Returns { violations, blocking, warnings }.
 */
export function scan(paths, read) {
  const violations = [];
  for (const path of paths) {
    const v = classify(path, () => read(path));
    if (v) violations.push(v);
  }
  return {
    violations,
    blocking: violations.filter((v) => v.severity === "block"),
    warnings: violations.filter((v) => v.severity === "warn"),
  };
}

// ── git + filesystem adapters (the impure edges) ──────────────────────────

function repoRoot() {
  return execFileSync("git", ["rev-parse", "--show-toplevel"], {
    encoding: "utf8",
  }).trim();
}

function trackedFiles(root) {
  return execFileSync("git", ["ls-files", "-z"], { cwd: root, encoding: "utf8" })
    .split("\0")
    .filter(Boolean);
}

function stagedFiles(root) {
  return execFileSync(
    "git",
    ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"],
    { cwd: root, encoding: "utf8" },
  )
    .split("\0")
    .filter(Boolean);
}

function makeReader(root) {
  return (path) => {
    const abs = join(root, path);
    let fd;
    try {
      fd = openSync(abs, "r");
      const size = fstatSync(fd).size;
      const len = Math.min(size, MAX_CONTENT_BYTES);
      const buf = Buffer.alloc(len);
      readSync(fd, buf, 0, len, 0);
      // NUL byte ⇒ binary; skip.
      if (buf.includes(0)) return null;
      return buf.toString("utf8");
    } catch {
      return null;
    } finally {
      if (fd !== undefined) closeSync(fd);
    }
  };
}

// ── CLI ────────────────────────────────────────────────────────────────────

function printHuman(result, { mode, fileCount }) {
  const { blocking, warnings } = result;
  if (blocking.length === 0 && warnings.length === 0) {
    console.log(
      `✓ Confidentiality guard: ${fileCount} ${mode} file(s) scanned, no internal-only content in the public tree.`,
    );
    return;
  }
  if (blocking.length > 0) {
    console.error(
      `\n✖ Confidentiality guard: ${blocking.length} file(s) must not be in the public tree.\n`,
    );
    for (const v of blocking) {
      console.error(`  ✖ ${v.path}`);
      console.error(`      rule:        ${v.ruleId} (${v.matchedOn})`);
      console.error(`      why:         ${v.reason}`);
      console.error(`      remediation: ${v.remediation}\n`);
    }
  }
  if (warnings.length > 0) {
    console.error(`⚠ ${warnings.length} file(s) to review (not blocking):`);
    for (const v of warnings) {
      console.error(`  ⚠ ${v.path} — ${v.reason} [${v.ruleId}]`);
    }
    console.error("");
  }
  if (blocking.length > 0) {
    console.error(
      "Fix: move the flagged files under internal/ (gitignored), or add the public allowlist\n" +
        "entry in scripts/security/internal-content-policy.mjs if they are intentionally public.\n" +
        "Docs: docs/security/CONFIDENTIALITY_POLICY.md\n",
    );
  }
}

function main(argv) {
  const args = new Set(argv.slice(2));
  const mode = args.has("--staged") ? "staged" : "tree";
  const strict = args.has("--strict");
  const asJson = args.has("--json");

  let root;
  try {
    root = repoRoot();
  } catch {
    console.error("scan-internal-content: not inside a git repository.");
    return 2;
  }

  const files = mode === "staged" ? stagedFiles(root) : trackedFiles(root);
  const read = makeReader(root);
  const result = scan(files, read);

  if (asJson) {
    console.log(
      JSON.stringify(
        { mode, fileCount: files.length, ...result },
        null,
        2,
      ),
    );
  } else {
    printHuman(result, { mode, fileCount: files.length });
  }

  if (result.blocking.length > 0) return 1;
  if (strict && result.warnings.length > 0) return 1;
  return 0;
}

// Run only when invoked directly (not when imported by tests).
const isMain =
  process.argv[1] &&
  resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url));
if (isMain) {
  process.exit(main(process.argv));
}

export { repoRoot, trackedFiles, stagedFiles, makeReader, main, dirname };
