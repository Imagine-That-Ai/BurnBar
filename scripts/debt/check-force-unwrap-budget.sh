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
# Counts force-unwrap `!` sites across the six scan roots:
#   AgentLens/
#   OpenBurnBarMobile/
#   OpenBurnBarCore/Sources/
#   OpenBurnBarDaemon/Sources/
#   OpenBurnBarKeyboard/
#   OpenBurnBarWidget/
#
# Excludes:
#   - try! and as! (governed by force_try / force_cast rules)
#   - != and !== (comparison operators)
#   - Implicitly-unwrapped optional TYPE declarations (e.g. `var x: UILabel!`,
#     `navigation: WKNavigation!`) — governed by the separately-documented
#     `implicitly_unwrapped_optional` rule, not force_unwrapping
#   - Comment and string literal contexts (but NOT string interpolation, which
#     contains executable code — `"\(optional!)"` IS counted)
#
# The gate fails when:
#   - the TOTAL live count EXCEEDS the baseline total, OR
#   - any individual file's live count EXCEEDS its baseline count
#     (blocks one-for-one replacements that launder a new site behind a removal)
#
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
  "OpenBurnBarKeyboard",
  "OpenBurnBarWidget",
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
// string literals ("..."), multi-line string literals ("""...""").
//
// String interpolation `\(...)` is handled specially: the `\(` opens an
// interpolation expression that contains executable code, so the code inside
// is preserved (not stripped) while the surrounding string delimiters and
// non-interpolation string content are removed.
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
      // Multi-line strings can contain interpolation with \(...)
      if (ch === "\\" && next === "(") {
        // Interpolation in multi-line string: preserve the code inside
        result += " "; // placeholder for the string part
        i += 2; // skip \(
        let depth = 1;
        while (i < len && depth > 0) {
          if (src[i] === "(") depth++;
          else if (src[i] === ")") depth--;
          if (depth > 0) result += src[i];
          i++;
        }
        // i is now past the closing )
        continue;
      }
      if (ch === '"' && next === '"' && next2 === '"') {
        inMultilineString = false;
        i += 3;
        continue;
      }
      i++;
      continue;
    }
    if (inString) {
      if (ch === "\\" && next === "(") {
        // String interpolation: preserve the code inside \(...)
        result += " ";
        i += 2; // skip \(
        let depth = 1;
        while (i < len && depth > 0) {
          if (src[i] === "(") depth++;
          else if (src[i] === ")") depth--;
          if (depth > 0) result += src[i];
          i++;
        }
        continue;
      }
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
// Excludes:
//   - `try!` and `as!` (governed by force_try / force_cast rules)
//   - Implicitly-unwrapped optional type declarations (e.g. `var x: UILabel!`)
//     detected by: word before `!` starts with uppercase (type name) AND
//     a `:` precedes the type name on the same line (type annotation position)
//     AND `!` is NOT followed by `.` or `(` (which signal force-unwrap chaining)
function countForceUnwraps(stripped) {
  const lines = stripped.split("\n");
  let count = 0;

  for (const line of lines) {
    for (let j = 0; j < line.length; j++) {
      if (line[j] !== "!") continue;
      // Skip != and !==
      if (line[j + 1] === "=") continue;

      const prev = line[j - 1] || "";
      if (!/[a-zA-Z0-9_)\]]/.test(prev)) continue;

      // Find the word preceding `!` to exclude `try!` and `as!`
      let k = j - 1;
      while (k >= 0 && /[a-zA-Z_]/.test(line[k])) k--;
      const word = line.substring(k + 1, j);
      if (word === "try" || word === "as") continue;

      // Exclude implicitly-unwrapped optional TYPE declarations.
      // An IUO type has the form `: TypeName!` where the `!` is in type
      // annotation position, not expression position. Detected by:
      //   1. The type name starts with uppercase (Swift type naming convention)
      //   2. A `:` (followed by optional whitespace) precedes the type name
      //      on this line — placing the `!` in a type annotation, not an
      //      expression
      //   3. The `!` is NOT followed by `.` or `(` — those signal force-unwrap
      //      chaining (e.g. `optional!.foo`), which is always an operation
      const startsUpper = /^[A-Z]/.test(word);
      const beforeType = line.substring(0, k + 1);
      const hasColon = /:\s*$/.test(beforeType);
      const after = line[j + 1] || "";
      const isChaining = after === "." || after === "(";

      if (startsUpper && hasColon && !isChaining) continue;

      count++;
    }
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
    note: "Force-unwrap (!) site budget across AgentLens/, OpenBurnBarMobile/, OpenBurnBarCore/Sources/, OpenBurnBarDaemon/Sources/, OpenBurnBarKeyboard/, OpenBurnBarWidget/. Shrink-only: count may only decrease as sites are removed. Excludes try! and as! (governed by force_try / force_cast) and implicitly-unwrapped optional type declarations (governed by implicitly_unwrapped_optional). String interpolation expressions are counted (executable code). Regenerate via scripts/debt/check-force-unwrap-budget.sh --update.",
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
const baseByPath = new Map((baseline.files || []).map((f) => [f.path, f.count]));

console.log(
  `Force-unwrap budget: live=${live.total} baseline=${baseline.total}`,
);

const top = live.byFile.slice(0, 10);
if (top.length) {
  console.log("Top offending files:");
  for (const f of top) console.log(`  ${String(f.count).padStart(3)}  ${f.path}`);
}

let failed = false;

// Check 1: total must not exceed baseline
if (live.total > baseline.total) {
  console.error(
    `::error::Force-unwrap count rose from ${baseline.total} to ${live.total}. Remove the new force-unwrap site(s) or use guard/if-let instead.`,
  );
  failed = true;
}

// Check 2: per-file counts must not exceed baseline (blocks one-for-one
// replacements that launder a new site behind a removal elsewhere)
const grownFiles = [];
for (const f of live.byFile) {
  const baseCount = baseByPath.get(f.path);
  if (baseCount !== undefined && f.count > baseCount) {
    grownFiles.push({ path: f.path, from: baseCount, to: f.count });
  }
}
if (grownFiles.length) {
  failed = true;
  console.error(
    `\n::error::${grownFiles.length} file(s) grew beyond their per-file baseline (one-for-one replacements are blocked — remove sites, don't move them):`,
  );
  for (const g of grownFiles) {
    console.error(`  ${g.from} -> ${g.to}  ${g.path}`);
  }
}

if (live.total < baseline.total) {
  console.log(
    `::notice::Force-unwrap count dropped from ${baseline.total} to ${live.total} — run scripts/debt/check-force-unwrap-budget.sh --update to lock it in.`,
  );
}

if (failed) {
  console.error("\nThe canonical budget is budgets/force-unwrap-baseline.json.");
  process.exit(1);
}

console.log("Force-unwrap ratchet OK.");
NODE