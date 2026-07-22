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
  "OpenBurnBarDomainCoreRuntime",
  "OpenBurnBarKernel",
  // Phase-2 WS-K (Kernel diet, docs/CORE_DECOMPOSITION_PROGRAM.md): the 4
  // sub-targets carved from OpenBurnBarKernel. Each has a PLANNED end-state
  // ceiling below (a --update never ratchets those down; a slice growing past
  // its planned end-state still FAILS).
  "OpenBurnBarKernelPlatform",
  "OpenBurnBarKernelModels",
  "OpenBurnBarKernelCrypto",
  "OpenBurnBarKernelContracts",
  "OpenBurnBarParserSupport",
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

// PLANNED ceilings for the decomposition-DESTINATION siblings (the targets the
// move packets FILL). Captured at S0 the marker files are ~8 LOC, so a measured
// 1.25x ceiling (2 files / 10 LOC) makes it impossible for the very first packet
// to move real code in — the gate would fail on its own program (Codex PR #1559
// thread 1 / P-01 named-blocker on PR #1561). Seed each destination's ceiling at
// ~1.25x its ARCHITECTURE end-state size (docs/CORE_DECOMPOSITION_PROGRAM.md
// "End-state target map") so a packet FILLING a sibling passes, while a sibling
// growing past its planned end-state still FAILS (no sibling becomes the next
// god module). `--update` must NOT clobber these with the measured 1.25x — a
// planned ceiling always WINS over the measured one (a destination sibling at
// marker size would otherwise ratchet its own ceiling back down to 10 LOC on the
// first integrator ratchet-down PR and re-block the program). Non-destination
// siblings (Kernel's peers that are NOT decomposition targets — Media, IrohRelay,
// SignalCore, etc.) keep the measured 1.25x ceiling.
//
// Kernel WAS a phase-1 decomposition destination (P-02/P-03/P-04a/P-04b/P-11
// moved ~35 files + several thousand LOC into it), seeded from the ~37k
// end-state (1.25x = 46250 LOC) with file headroom. Phase-2 WS-K (Kernel diet)
// now SPLITS the Kernel into 4 sub-targets. At K0 (scaffold) NO files have moved
// out of the Kernel yet, so its temporary ceiling is 185/46280: the mandatory
// 26-line KernelUmbrella.swift sits on top of main's 46250-line floor. The FINAL
// WS-K move packet
// reduces OpenBurnBarKernel to the umbrella file only and drops this ceiling to
// 3 files / 200 LOC in that same PR.
const PLANNED_CEILINGS = {
  // Shared-Rust rollout authority stays a narrow Foundation-only leaf. The
  // ceiling covers profiles, candidate identity, evidence comparison, and the
  // generic shadow selector without allowing domain business logic to move in.
  OpenBurnBarDomainCoreRuntime: { maxFiles: 8, maxLines: 1000 },
  // K0's required KernelUmbrella.swift is 26 LOC; the four move packets remove
  // it from this ceiling as they drain the old target.
  OpenBurnBarKernel: { maxFiles: 185, maxLines: 46280 },
  // Phase-2 WS-K (Kernel diet, docs/CORE_DECOMPOSITION_PROGRAM.md): the 4 Kernel
  // sub-targets, seeded at ~1.12x their measured K0-mapping end-state size
  // (Platform 12f/2430L, Models 90f/23785L, Crypto 12f/5172L, Contracts
  // 30f/11678L) so the FILLING packet (K1–K4) passes while a slice growing past
  // its end-state still FAILS. Models carries the widest headroom because it is
  // the largest AE-IMPORT sink (moved files gain `import OpenBurnBarKernelPlatform`
  // lines). Mapping is proven ACYCLIC (Platform < Models < Crypto, and
  // {Models, Crypto} < Contracts): CLILaunchAdapter/CLITerminalSessionSupervisor/
  // LinuxSubstrateSupport landed in Models (they consume SwitcherProfile/RGBA/
  // SubstrateFamily); BurnBarRunCreateMetadata/FusionSessionSpend/
  // CLIAgentResumePresentation landed in Contracts (they consume Contracts types).
  // A --update never ratchets these down (planned wins).
  OpenBurnBarKernelPlatform: { maxFiles: 14, maxLines: 2900 },
  OpenBurnBarKernelModels: { maxFiles: 95, maxLines: 24600 },
  OpenBurnBarKernelCrypto: { maxFiles: 14, maxLines: 5900 },
  OpenBurnBarKernelContracts: { maxFiles: 34, maxLines: 13100 },
  OpenBurnBarParserSupport: { maxFiles: 5, maxLines: 1000 },
  OpenBurnBarSQLiteReader: { maxFiles: 3, maxLines: 450 },
  OpenBurnBarLogParsers: { maxFiles: 35, maxLines: 11800 },
  OpenBurnBarQuota: { maxFiles: 55, maxLines: 13000 },
  // VectorKit gains OpenBurnBarSearchContracts.swift (P-03 re-slice / FIX 4) on
  // top of the vector indexes + SearchPlanner + Pensieve, so its ceiling covers
  // SearchContracts too.
  OpenBurnBarVectorKit: { maxFiles: 12, maxLines: 5800 },
  // Phase-2 WS-K: trimmed from 100/20000 to ~1.1x the measured 83f/16528L
  // actual now that phase-1 Insights extraction has fully landed.
  OpenBurnBarInsights: { maxFiles: 90, maxLines: 18200 },
  OpenBurnBarHermes: { maxFiles: 10, maxLines: 1800 },
  OpenBurnBarPretext: { maxFiles: 5, maxLines: 850 },
  OpenBurnBarTextExpansion: { maxFiles: 8, maxLines: 1100 },
  OpenBurnBarLaunchServices: { maxFiles: 12, maxLines: 6100 },
  // Phase-2 WS-K: trimmed from 160/40000 to ~1.1x the measured 130f/33710L
  // actual now that phase-1 UI (K4) extraction has fully landed.
  OpenBurnBarUI: { maxFiles: 145, maxLines: 37000 },
  OpenBurnBarEngine: { maxFiles: 3, maxLines: 60 },
};

// Per-sibling ceilings: PLANNED wins for decomposition destinations, else
// ceil(1.25 x current measured size). A `planned: true` flag makes it obvious in
// the JSON which ceilings are end-state-seeded (and must not be ratcheted down).
function ceilings() {
  const out = {};
  for (const t of siblingTargets) {
    if (PLANNED_CEILINGS[t]) {
      out[t] = { ...PLANNED_CEILINGS[t], planned: true };
      continue;
    }
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
      "OpenBurnBarCore main-target membership snapshot (per-file line counts) + " +
      "per-sibling {files, LOC} ceilings (docs/CORE_DECOMPOSITION_PROGRAM.md). " +
      "Deny-gate: no NEW .swift file may be added to " +
      "OpenBurnBarCore/Sources/OpenBurnBarCore/ (new code lands in a sibling target); " +
      "main-target totals may only shrink AND no individual baselined main-target " +
      "file may grow (per-file check — a removed big file cannot mask regrowth in " +
      "another file); no sibling may exceed its ceiling (decomposition-destination " +
      "siblings use a PLANNED end-state ceiling that --update never ratchets down, " +
      "others use 1.25x measured). Shrink is non-fatal (run --update to ratchet " +
      "down). Regenerate via scripts/debt/check-core-target-membership-budget.sh " +
      "--update.",
    main: {
      target: mainTarget,
      totalLines: mainLive.totalLines,
      fileCount: mainLive.fileCount,
      files: mainLive.files.map((f) => f.path),
      // Per-file line counts so existing-file growth cannot hide behind an
      // unrelated file move (Codex PR #1559 thread: "Compare Core files per-file,
      // not only aggregate LOC"). Path -> line count.
      fileLines: Object.fromEntries(mainLive.files.map((f) => [f.path, f.lines])),
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
const baseFileLines = baseline.main.fileLines || {};
const liveMainFiles = new Set(mainLive.files.map((f) => f.path));
const liveLineByPath = new Map(mainLive.files.map((f) => [f.path, f.lines]));

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

// Per-file growth check (Codex PR #1559 thread: aggregate LOC alone lets a
// removed big file mask regrowth in another file during the exact extraction PRs
// this gate polices). For every baselined main-target file that STILL lives in
// the main target, its live line count may not exceed its baselined count.
// Removed files are handled by the shrink path below; new files already FAIL
// above. Baselines predating fileLines skip this (fall back to aggregate only)
// until the integrator runs --update once.
if (Object.keys(baseFileLines).length) {
  const grown = [];
  for (const [p, baseLines] of Object.entries(baseFileLines)) {
    if (!liveMainFiles.has(p)) continue; // moved out — non-fatal shrink path
    const live = liveLineByPath.get(p);
    if (typeof live === "number" && live > baseLines) {
      grown.push({ path: p, from: baseLines, to: live });
    }
  }
  if (grown.length) {
    failed = true;
    console.error(
      `\nFAIL: ${grown.length} baselined ${mainTarget} file(s) grew in place ` +
        "(existing-file growth may not hide behind an unrelated file move — new code " +
        "lands in a sibling target; see docs/CORE_DECOMPOSITION_PROGRAM.md):"
    );
    for (const g of grown) console.error(`  ${g.path} (${g.from} -> ${g.to} lines)`);
  }
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
