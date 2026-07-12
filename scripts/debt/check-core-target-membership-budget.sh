#!/usr/bin/env bash
# Core-decomposition regrowth gate #1 (docs/CORE_DECOMPOSITION_PROGRAM.md).
#
# The OpenBurnBarCore main target is being dissolved into narrow sibling targets.
# This gate makes it impossible for new code to grow the main target back, and
# stops any extracted sibling from becoming the next god module:
#
# Fails CI if ANY of:
#   - a .swift file exists in OpenBurnBarCore/Sources/OpenBurnBarCore/ that is NOT
#     in the baseline (new code must land in a sibling target — see the program
#     doc), or
#   - the main target's total line count or file count exceeds the baseline
#     (blocks growth inside existing files), or
#   - any sibling target exceeds its per-target {files, LOC} ceiling (set at
#     1.25x the S0 extraction size so no sibling becomes the next monolith).
#
# NON-FATAL shrink (mirrors scripts/debt/check-swift-file-size-budget.sh): when
# the live main target is SMALLER than the baseline (files moved out), the gate
# prints "Improved: ... run --update to ratchet down" and exits 0, so parallel
# move packets merge without a baseline race. The integrator lands standalone
# JSON-only ratchet-down PRs per merged wave:
#   scripts/debt/check-core-target-membership-budget.sh --update
#
# The canonical budget is budgets/core-target-membership-baseline.json.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/core-target-membership-baseline.json"
mode="check"
if [[ "${1:-}" == "--update" ]]; then
  mode="update"
fi

node - "${repo_root}" "${baseline_path}" "${mode}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [repoRoot, baselinePath, mode] = process.argv.slice(2);
const sourcesRoot = path.join(repoRoot, "OpenBurnBarCore", "Sources");
const mainTarget = "OpenBurnBarCore";

// Sibling targets carved from (or living beside) the monolith get {files, LOC}
// ceilings so no one of them grows into the next god module. This is every
// first-party non-main target in the package with real Swift sources. Vendored
// C targets (CSQLite/Czlib/COpenBurnBarSecretService) and binary-target Generated
// dirs are not Swift-source targets and are skipped.
const siblingTargets = [
  "OpenBurnBarKernel",
  "OpenBurnBarSQLiteReader",
  "OpenBurnBarLogParsers",
  "OpenBurnBarQuota",
  "OpenBurnBarVectorKit",
  "OpenBurnBarInsights",
  "OpenBurnBarHermes",
  "OpenBurnBarPretext",
  "OpenBurnBarTextExpansion",
  "OpenBurnBarLaunchServices",
  "OpenBurnBarUI",
  "OpenBurnBarEngine",
  "OpenBurnBarComputerUseCore",
  "OpenBurnBarMedia",
  "OpenBurnBarIrohRelay",
  "OpenBurnBarSignalCore",
  "OpenBurnBarSignalSessionTransport",
  "OpenBurnBarFirestoreModels",
  "OpenBurnBarAnalytics",
  "OpenBurnBarLinuxSecurity",
  "OpenBurnBarData",
  "BurnBarRemoteEngine",
  "OpenBurnBarCoreCAbi",
];

function countLines(absPath) {
  const text = fs.readFileSync(absPath, "utf8");
  if (text.length === 0) return 0;
  const nl = text.split("\n").length;
  // Match `wc -l` semantics: a trailing newline does not add a phantom line.
  return text.endsWith("\n") ? nl - 1 : nl;
}

function scanTarget(target) {
  const root = path.join(sourcesRoot, target);
  if (!fs.existsSync(root)) return { files: [], totalLines: 0, fileCount: 0 };
  const files = [];
  let totalLines = 0;
  for (const entry of fs.readdirSync(root, { recursive: true })) {
    const rel = String(entry);
    if (!rel.endsWith(".swift")) continue;
    const abs = path.join(root, rel);
    if (!fs.statSync(abs).isFile()) continue;
    const lines = countLines(abs);
    files.push({ path: path.relative(repoRoot, abs), lines });
    totalLines += lines;
  }
  files.sort((a, b) => a.path.localeCompare(b.path));
  return { files, totalLines, fileCount: files.length };
}

const mainLive = scanTarget(mainTarget);

// Per-sibling ceilings at ceil(1.25 x current size).
function ceilings() {
  const out = {};
  for (const t of siblingTargets) {
    const s = scanTarget(t);
    out[t] = {
      maxFiles: Math.ceil(s.fileCount * 1.25),
      maxLines: Math.ceil(s.totalLines * 1.25),
    };
  }
  return out;
}

if (mode === "update") {
  const baseline = {
    note:
      "OpenBurnBarCore main-target membership snapshot + per-sibling {files, LOC} " +
      "ceilings (docs/CORE_DECOMPOSITION_PROGRAM.md). Deny-gate: no NEW .swift file " +
      "may be added to OpenBurnBarCore/Sources/OpenBurnBarCore/ (new code lands in a " +
      "sibling target); main-target totals may only shrink; no sibling may exceed its " +
      "1.25x ceiling. Shrink is non-fatal (run --update to ratchet down). Regenerate " +
      "via scripts/debt/check-core-target-membership-budget.sh --update.",
    main: {
      target: mainTarget,
      totalLines: mainLive.totalLines,
      fileCount: mainLive.fileCount,
      files: mainLive.files.map((f) => f.path),
    },
    siblingCeilings: ceilings(),
  };
  fs.writeFileSync(baselinePath, JSON.stringify(baseline, null, 2) + "\n");
  console.log(
    `Wrote ${path.relative(repoRoot, baselinePath)}: main ${mainLive.fileCount} file(s)/` +
      `${mainLive.totalLines} lines, ${siblingTargets.length} sibling ceiling(s).`
  );
  process.exit(0);
}

if (!fs.existsSync(baselinePath)) {
  console.error(`Missing Core target-membership baseline: ${baselinePath}`);
  console.error("Run scripts/debt/check-core-target-membership-budget.sh --update to capture the current budget.");
  process.exit(1);
}
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
const baseMainFiles = new Set(baseline.main.files);
const liveMainFiles = new Set(mainLive.files.map((f) => f.path));

let failed = false;

const newFiles = mainLive.files.map((f) => f.path).filter((p) => !baseMainFiles.has(p));
const removedFiles = [...baseMainFiles].filter((p) => !liveMainFiles.has(p));

console.log(
  `Core target-membership budget: main baselined=${baseline.main.fileCount} files/` +
    `${baseline.main.totalLines} lines, live=${mainLive.fileCount} files/${mainLive.totalLines} lines`
);

if (newFiles.length) {
  failed = true;
  console.error(
    `\nFAIL: ${newFiles.length} NEW .swift file(s) in ${mainTarget} — new code lands in a sibling ` +
      "target, not the dissolving monolith (see docs/CORE_DECOMPOSITION_PROGRAM.md):"
  );
  for (const p of newFiles) console.error(`  ${p}`);
}
if (mainLive.totalLines > baseline.main.totalLines) {
  failed = true;
  console.error(
    `\nFAIL: ${mainTarget} total lines grew (${baseline.main.totalLines} -> ${mainLive.totalLines}); ` +
      "the main target may only shrink."
  );
}
if (mainLive.fileCount > baseline.main.fileCount) {
  failed = true;
  console.error(
    `\nFAIL: ${mainTarget} file count grew (${baseline.main.fileCount} -> ${mainLive.fileCount}); ` +
      "the main target may only shrink."
  );
}

for (const target of siblingTargets) {
  const ceiling = baseline.siblingCeilings[target];
  if (!ceiling) continue; // targets added after baseline are covered on next --update
  const live = scanTarget(target);
  if (live.fileCount > ceiling.maxFiles) {
    failed = true;
    console.error(
      `\nFAIL: sibling ${target} exceeded its file ceiling (${live.fileCount} > ${ceiling.maxFiles}); ` +
        "decompose it or raise the ceiling with rationale (docs/CORE_DECOMPOSITION_PROGRAM.md)."
    );
  }
  if (live.totalLines > ceiling.maxLines) {
    failed = true;
    console.error(
      `\nFAIL: sibling ${target} exceeded its LOC ceiling (${live.totalLines} > ${ceiling.maxLines}); ` +
        "decompose it or raise the ceiling with rationale (docs/CORE_DECOMPOSITION_PROGRAM.md)."
    );
  }
}

// Non-fatal shrink: files moved OUT of the main target. Mirrors
// check-swift-file-size-budget.sh so parallel move packets merge without a race;
// the integrator ratchets the baseline down per wave.
if (removedFiles.length && !failed) {
  console.log(
    `\nImproved: ${removedFiles.length} file(s) left ${mainTarget} — run ` +
      "scripts/debt/check-core-target-membership-budget.sh --update to ratchet down:"
  );
  for (const p of removedFiles) console.log(`  ${p}`);
}

if (failed) {
  console.error("\nThe canonical budget is budgets/core-target-membership-baseline.json.");
  process.exit(1);
}
console.log("OK: no new files in the Core main target and no sibling exceeded its ceiling.");
NODE
