#!/usr/bin/env node
// Guard the two ways .github/dependabot.yml has actually broken, both of which
// are silent: nothing in CI reads this file, so a bad edit is only discovered
// when dependency updates quietly stop arriving.
//
// 1. YAML ANCHORS / ALIASES
//    Dependabot rejects the ENTIRE file with "YAML aliases are not supported"
//    (dependabot/dependabot-core#1582, open since 2019). Standard YAML parsers
//    -- including js-yaml and Python's yaml.safe_load -- expand anchors happily,
//    so local validation passes while production silently disables every update
//    job in the file. The blast radius is the whole config, not the one entry.
//
// 2. LOCKFILES WITH NO AUTO-FIX OWNER
//    `OSV Scanner (open source vulnerabilities)` is a REQUIRED status check on
//    main and scans every package-lock.json in the tree. Any lockfile Dependabot
//    does not watch has no bot that can fix it, so a new advisory there red-lines
//    every open PR at once and stays red until a human patches it by hand. That
//    happened twice on 2026-07-24 (postcss/tar via #1968, then brace-expansion
//    GHSA-mh99-v99m-4gvg). This ratchet keeps "what can block a merge" and
//    "what a bot can fix" the same set.
//
// Exit 0 = clean, 1 = violation. Pure Node, no dependencies.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";

const CONFIG = ".github/dependabot.yml";
const IGNORED_DIRS = new Set([
  "node_modules", ".git", "Vendor", "build", "dist", "out", ".build",
  "DerivedData", ".derived-data", ".spm-cache", "artifacts", "output",
]);

const problems = [];

// ── 1. anchors / aliases ────────────────────────────────────────────────────
const raw = readFileSync(CONFIG, "utf8");
raw.split("\n").forEach((line, i) => {
  const code = line.split("#")[0];
  // Anchor definition (`&name`) or alias reference (`*name` / `<<: *name`).
  // Restricted to YAML value positions so prose in comments cannot trip it.
  if (/(?::\s|^\s*-\s|^\s{2,})[&*][A-Za-z0-9_-]+\s*$/.test(code) || /<<:\s*\*/.test(code)) {
    problems.push(
      `${CONFIG}:${i + 1}: YAML anchor/alias found -- Dependabot rejects the whole file ` +
        `("YAML aliases are not supported", dependabot-core#1582). Write the block out in full.\n` +
        `    ${line.trim()}`,
    );
  }
});

// ── parse (deliberately minimal: only what this check needs) ────────────────
// A real YAML parser would expand aliases and hide problem 1, so the anchor
// check above runs on raw text first and this reader stays literal.
function readUpdates(text) {
  const updates = [];
  let current = null;
  for (const line of text.split("\n")) {
    const code = line.replace(/\s+#.*$/, "");
    const entry = code.match(/^\s{2}-\s+package-ecosystem:\s*["']?([^"'\s]+)["']?\s*$/);
    if (entry) {
      current = { ecosystem: entry[1], directory: null };
      updates.push(current);
      continue;
    }
    if (!current) continue;
    const dir = code.match(/^\s{4}director(?:y|ies):\s*["']?([^"'\s]+)["']?\s*$/);
    if (dir) current.directory = dir[1];
  }
  return updates;
}

const updates = readUpdates(raw);
if (updates.length === 0) {
  problems.push(`${CONFIG}: parsed zero update entries -- the file shape changed and this check is blind.`);
}

// ── duplicate ecosystem+directory pairs ────────────────────────────────────
const seen = new Map();
for (const u of updates) {
  const key = `${u.ecosystem} ${u.directory}`;
  seen.set(key, (seen.get(key) ?? 0) + 1);
}
for (const [key, n] of seen) {
  if (n > 1) problems.push(`${CONFIG}: ${n} entries for "${key}" -- Dependabot treats duplicates as a config error.`);
}

// ── 2. every npm lockfile has an npm entry ─────────────────────────────────
function findLockfiles(dir, acc = []) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return acc;
  }
  for (const e of entries) {
    if (e.isDirectory()) {
      if (IGNORED_DIRS.has(e.name) || e.name.startsWith(".bb-")) continue;
      findLockfiles(join(dir, e.name), acc);
    } else if (e.name === "package-lock.json") {
      acc.push(dir);
    }
  }
  return acc;
}

const repoRoot = process.cwd();
const npmWatched = new Set(
  updates.filter((u) => u.ecosystem === "npm").map((u) => (u.directory ?? "").replace(/\/$/, "") || "/"),
);
const lockDirs = findLockfiles(repoRoot).map((d) => {
  const rel = relative(repoRoot, d);
  return rel === "" ? "/" : `/${rel.split(sep).join("/")}`;
});

const unwatched = lockDirs.filter((d) => !npmWatched.has(d)).sort();
if (unwatched.length) {
  problems.push(
    `${CONFIG}: ${unwatched.length} package-lock.json director${unwatched.length === 1 ? "y has" : "ies have"} ` +
      `no npm entry, so a new advisory there can red-line every open PR with no bot able to fix it:\n` +
      unwatched.map((d) => `    ${d}`).join("\n"),
  );
}

// Stale entries are a warning, not a failure: a directory can legitimately be
// added to the config just before its lockfile lands.
const stale = [...npmWatched].filter((d) => !lockDirs.includes(d)).sort();

if (problems.length) {
  console.error("FAIL: .github/dependabot.yml\n");
  for (const p of problems) console.error(`  - ${p}\n`);
  process.exit(1);
}

console.log(
  `OK: dependabot.yml has no YAML aliases, no duplicate targets, and all ${lockDirs.length} ` +
    `npm lockfiles have an auto-fix owner (${updates.length} update entries).` +
    (stale.length ? `\nNOTE: watched but no lockfile yet: ${stale.join(", ")}` : ""),
);
