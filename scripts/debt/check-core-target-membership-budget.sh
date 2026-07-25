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
#   - any sibling target exceeds its per-target {files, LOC} ceiling. Non-decomposition
#     siblings use a measured 1.25x-of-current ceiling. Decomposition destinations
#     (the targets move packets fill) instead carry an explicit `plannedCeiling` seeded
#     at ~1.25x their architecture end-state, so a packet FILLING a destination is
#     allowed up to the planned size (but no further — no sibling becomes the next
#     monolith). --update preserves plannedCeiling verbatim (wave-1 learning: measuring
#     a marker-only destination at S0 gave a ~10-line ceiling that every fill packet
#     falsely tripped).
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

// PLANNED ceilings for the decomposition-destination siblings (wave-1 learnings).
//
// The S0 scaffold created these siblings holding only a ModuleMarker.swift stub, so
// measuring them at S0 gave a ~2-file/10-line ceiling. Every move packet that FILLS
// one of them (its entire purpose) would then blow that marker-sized ceiling — which
// is exactly how Wave-1's P-01/P-06 got a false gate FAIL. The fix: give each
// decomposition destination an EXPLICIT planned ceiling, seeded at ~1.25x the
// architecture end-state size (docs/CORE_DECOMPOSITION_PROGRAM.md end-state map), that
// `--update` MUST NOT clobber. When a target has a plannedCeiling the gate enforces IT
// (not measured x1.25), so a sibling can grow up to its end-state as move packets land,
// while still being blocked from becoming the next god module beyond the planned size.
//
// Non-decomposition siblings (already-real targets) are absent here and keep their
// measured x1.25 ceiling, ratcheting down on --update as before.
const plannedCeilings = {
  // Kernel is the single largest decomposition destination: wave-1 alone moves ~25
  // files / ~9.3k LOC into it (P-02 catalog+PII, P-03 root contracts, P-04a/P-04b
  // SharedModels), and P-11 adds MissionGroupContracts + MissionConsoleTypes. That
  // pushes Kernel to ~133 files / ~39.3k LOC — over its S0 measured ceiling of
  // 133 files / 35955 lines, so without an explicit planned ceiling the Kernel-ward
  // wave-1 packets (the majority of the wave) trip the LOC ceiling. End-state ~39.3k;
  // seed at ~1.25x. (Not in the integrator's original 11-item list, but required by the
  // same defect — see the Wave-1 learnings note in docs/CORE_DECOMPOSITION_PROGRAM.md.)
  OpenBurnBarKernel: { maxFiles: 166, maxLines: 49000 },
  OpenBurnBarSQLiteReader: { maxFiles: 3, maxLines: 450 },
  OpenBurnBarLogParsers: { maxFiles: 35, maxLines: 11700 },
  OpenBurnBarQuota: { maxFiles: 55, maxLines: 13000 },
  // VectorKit end-state includes OpenBurnBarSearchContracts.swift (P-03 re-slice —
  // it depends on VectorKit-bound types, see docs/CORE_DECOMPOSITION_PROGRAM.md).
  OpenBurnBarVectorKit: { maxFiles: 12, maxLines: 5800 },
  OpenBurnBarInsights: { maxFiles: 100, maxLines: 20000 },
  OpenBurnBarHermes: { maxFiles: 10, maxLines: 1800 },
  OpenBurnBarPretext: { maxFiles: 5, maxLines: 850 },
  OpenBurnBarTextExpansion: { maxFiles: 8, maxLines: 1100 },
  OpenBurnBarLaunchServices: { maxFiles: 12, maxLines: 6100 },
  OpenBurnBarUI: { maxFiles: 160, maxLines: 40000 },
  OpenBurnBarEngine: { maxFiles: 3, maxLines: 60 },
};

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

// Per-sibling ceilings. Non-decomposition siblings ratchet to ceil(1.25 x current
// size). Decomposition destinations (plannedCeilings) instead carry an explicit
// `plannedCeiling` seeded at ~1.25x their architecture end-state, which `--update`
// preserves verbatim so a partial fill can never ratchet the ceiling below the
// end-state. The measured `maxFiles`/`maxLines` are still recorded for visibility.
function ceilings() {
  const out = {};
  for (const t of siblingTargets) {
    const s = scanTarget(t);
    const entry = {
      maxFiles: Math.ceil(s.fileCount * 1.25),
      maxLines: Math.ceil(s.totalLines * 1.25),
    };
    if (plannedCeilings[t]) {
      entry.plannedCeiling = {
        maxFiles: plannedCeilings[t].maxFiles,
        maxLines: plannedCeilings[t].maxLines,
      };
    }
    out[t] = entry;
  }
  return out;
}

// The ceiling the gate actually enforces: the planned end-state ceiling when a target
// has one (decomposition destination), else the measured x1.25 ratchet.
function effectiveCeiling(target, baselineEntry) {
  const planned =
    plannedCeilings[target] ||
    (baselineEntry && baselineEntry.plannedCeiling);
  if (planned) {
    return { maxFiles: planned.maxFiles, maxLines: planned.maxLines };
  }
  return { maxFiles: baselineEntry.maxFiles, maxLines: baselineEntry.maxLines };
}

if (mode === "update") {
  const baseline = {
    note:
      "OpenBurnBarCore main-target membership snapshot + per-sibling {files, LOC} " +
      "ceilings (docs/CORE_DECOMPOSITION_PROGRAM.md). Deny-gate: no NEW .swift file " +
      "may be added to OpenBurnBarCore/Sources/OpenBurnBarCore/ (new code lands in a " +
      "sibling target); main-target totals may only shrink. Non-decomposition siblings " +
      "keep a measured 1.25x ceiling. Decomposition destinations carry an explicit " +
      "`plannedCeiling` (seeded at ~1.25x their architecture end-state) that the gate " +
      "enforces and that --update preserves, so a partial fill can never ratchet a " +
      "destination's ceiling below its end-state (wave-1 learning). Shrink is non-fatal " +
      "(run --update to ratchet down). Regenerate via " +
      "scripts/debt/check-core-target-membership-budget.sh --update.",
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
  const baselineEntry = baseline.siblingCeilings[target];
  if (!baselineEntry) continue; // targets added after baseline are covered on next --update
  const ceiling = effectiveCeiling(target, baselineEntry);
  const planned =
    plannedCeilings[target] || baselineEntry.plannedCeiling ? " (planned end-state)" : "";
  const live = scanTarget(target);
  if (live.fileCount > ceiling.maxFiles) {
    failed = true;
    console.error(
      `\nFAIL: sibling ${target} exceeded its file ceiling${planned} (${live.fileCount} > ${ceiling.maxFiles}); ` +
        "decompose it or raise the ceiling with rationale (docs/CORE_DECOMPOSITION_PROGRAM.md)."
    );
  }
  if (live.totalLines > ceiling.maxLines) {
    failed = true;
    console.error(
      `\nFAIL: sibling ${target} exceeded its LOC ceiling${planned} (${live.totalLines} > ${ceiling.maxLines}); ` +
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
