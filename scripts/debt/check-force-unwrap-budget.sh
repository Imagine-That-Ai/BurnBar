#!/usr/bin/env bash
# Shrink-only force-unwrap budget ratchet (Operation 9 P-CQ-6).
#
# Force-unwraps (`optional!`) are the one documented debt with no driving-down
# mechanism (diligence 2026-07-12 finding #10, .swiftlint.yml records 715 sites
# but never enabled force_unwrapping because the count was too high for a
# blocking rule). This ratchet freezes the measured count shrink-only so every
# removal is locked in and every addition fails CI — without enabling the rule
# globally (which would block the build at 715 today).
#
# Counts force-unwrap `!` sites across the four scan roots:
#   AgentLens/
#   OpenBurnBarMobile/
#   OpenBurnBarCore/Sources/
#   OpenBurnBarDaemon/Sources/
#
# Excludes try! and as! (governed by force_try / force_cast), != and !==
# (comparison operators), and comment/string contexts.
#
# The gate fails when the live count EXCEEDS budgets/force-unwrap-baseline.json.
# As each site is removed, lower the baseline with --update to lock the win in.
# --update is shrink-only: it refuses to write a baseline that is higher than
# the current one.
#
# The canonical budget is budgets/force-unwrap-baseline.json.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/force-unwrap-baseline.json"
mode="${1:-}"

node - "${repo_root}" "${baseline_path}" "${mode}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [repoRoot, baselinePath, mode] = process.argv.slice(2);

const scanRoots = [
  "AgentLens",
  "OpenBurnBarMobile",
  "OpenBurnBarCore/Sources",
  "OpenBurnBarDaemon/Sources",
];

const excludedParts = new Set([
  ".build",
  ".derived-data",
  ".swiftpm",
  "Preview Content",
  "build",
]);

function findSwiftFiles(dir) {
  const results = [];
  if (!fs.existsSync(dir)) return results;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (excludedParts.has(entry.name)) continue;
      results.push(...findSwiftFiles(full));
    } else if (entry.name.endsWith(".swift")) {
      results.push(full);
    }
  }
  return results;
}

// Strip comments and string/character literals so force-unwraps inside them
// are not counted. Handles line comments (//), block comments (/* */),
// string literals ("..."), and multi-line string literals ("""...""").
function stripCommentsAndStrings(src) {
  let result = "";
  let i = 0;
  const len = src.length;
  let inLineComment = false;
  let inBlockComment = false;
  let inString = false;
  let inMultilineString = false;

  while (i < len) {
    const ch = src[i];
    const next = src[i + 1] || "";
    const next2 = src[i + 2] || "";

    if (inLineComment) {
      if (ch === "\n") {
        inLineComment = false;
        result += ch;
      }
      i++;
      continue;
    }
    if (inBlockComment) {
      if (ch === "*" && next === "/") {
        inBlockComment = false;
        i += 2;
        continue;
      }
      if (ch === "\n") result += ch;
      i++;
      continue;
    }
    if (inMultilineString) {
      if (ch === '"' && next === '"' && next2 === '"') {
        inMultilineString = false;
        i += 3;
        continue;
      }
      i++;
      continue;
    }
    if (inString) {
      if (ch === "\\" && next) {
        i += 2;
        continue;
      }
      if (ch === '"') {
        inString = false;
        i++;
        continue;
      }
      i++;
      continue;
    }

    // Not in any comment/string context
    if (ch === "/" && next === "/") {
      inLineComment = true;
      i += 2;
      continue;
    }
    if (ch === "/" && next === "*") {
      inBlockComment = true;
      i += 2;
      continue;
    }
    if (ch === '"' && next === '"' && next2 === '"') {
      inMultilineString = true;
      i += 3;
      continue;
    }
    if (ch === '"') {
      inString = true;
      i++;
      continue;
    }

    result += ch;
    i++;
  }
  return result;
}

// Count force-unwrap `!` sites in stripped source.
// A force-unwrap is `!` preceded by an expression-ending character (letter,
// digit, _, ), ]) and NOT followed by `=` (excludes !=, !==).
// Excludes `try!` and `as!` (governed by force_try / force_cast rules).
function countForceUnwraps(stripped) {
  let count = 0;
  for (let j = 0; j < stripped.length; j++) {
    if (stripped[j] !== "!") continue;
    // Skip != and !==
    if (stripped[j + 1] === "=") continue;

    const prev = stripped[j - 1] || "";
    if (!/[a-zA-Z0-9_)\]]/.test(prev)) continue;

    // Find the word preceding `!` to exclude `try!` and `as!`
    let k = j - 1;
    while (k >= 0 && /[a-zA-Z_]/.test(stripped[k])) k--;
    const word = stripped.substring(k + 1, j);
    if (word === "try" || word === "as") continue;

    count++;
  }
  return count;
}

function scanAll() {
  const byFile = [];
  let total = 0;

  for (const root of scanRoots) {
    const absRoot = path.join(repoRoot, root);
    const files = findSwiftFiles(absRoot);
    for (const f of files) {
      const src = fs.readFileSync(f, "utf8");
      const stripped = stripCommentsAndStrings(src);
      const c = countForceUnwraps(stripped);
      if (c > 0) {
        const rel = path.relative(repoRoot, f);
        byFile.push({ path: rel, count: c });
        total += c;
      }
    }
  }

  byFile.sort((a, b) => b.count - a.count || a.path.localeCompare(b.path));
  return { total, byFile };
}

const live = scanAll();

if (mode === "--print-live") {
  console.log(
    JSON.stringify(
      { total: live.total, files: live.byFile },
      null,
      2,
    ) + "\n",
  );
  process.exit(0);
}

if (mode === "--update") {
  // Shrink-only: refuse to raise the baseline.
  if (fs.existsSync(baselinePath)) {
    const current = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
    if (live.total > current.total) {
      console.error(
        `::error::Force-unwrap --update refused: live ${live.total} > current baseline ${current.total}. The baseline may only shrink — remove force-unwrap sites first.`,
      );
      process.exit(1);
    }
  }
  const baseline = {
    note: "Force-unwrap (!) site budget across AgentLens/, OpenBurnBarMobile/, OpenBurnBarCore/Sources/, OpenBurnBarDaemon/Sources/. Shrink-only: count may only decrease as sites are removed. Excludes try! and as! (governed by force_try / force_cast). Regenerate via scripts/debt/check-force-unwrap-budget.sh --update.",
    total: live.total,
    files: live.byFile,
  };
  fs.writeFileSync(baselinePath, JSON.stringify(baseline, null, 2) + "\n");
  console.log(
    `Wrote ${path.relative(repoRoot, baselinePath)}: ${live.total} force-unwrap sites across ${live.byFile.length} file(s).`,
  );
  process.exit(0);
}

// Check mode
if (!fs.existsSync(baselinePath)) {
  console.error(`Missing force-unwrap baseline: ${baselinePath}`);
  console.error(
    "Run scripts/debt/check-force-unwrap-budget.sh --update to capture the current budget.",
  );
  process.exit(1);
}

const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));

console.log(
  `Force-unwrap budget: live=${live.total} baseline=${baseline.total}`,
);

const top = live.byFile.slice(0, 10);
if (top.length) {
  console.log("Top offending files:");
  for (const f of top) console.log(`  ${String(f.count).padStart(3)}  ${f.path}`);
}

if (live.total > baseline.total) {
  console.error(
    `::error::Force-unwrap count rose from ${baseline.total} to ${live.total}. Remove the new force-unwrap site(s) or use guard/if-let instead.`,
  );
  process.exit(1);
}

if (live.total < baseline.total) {
  console.log(
    `::notice::Force-unwrap count dropped from ${baseline.total} to ${live.total} — run scripts/debt/check-force-unwrap-budget.sh --update to lock it in.`,
  );
}

console.log("Force-unwrap ratchet OK.");
NODE