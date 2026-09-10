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
  "OpenBurnBarAssistantModels",
  "OpenBurnBarProjectCodeContracts",
  "OpenBurnBarKernel",
  "OpenBurnBarParserSupport",
  "OpenBurnBarSQLiteReader",
  "OpenBurnBarLogParsers",
  "OpenBurnBarQuota",
  "OpenBurnBarVectorKit",
  "OpenBurnBarInsights",
  "OpenBurnBarRecap",
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
// Kernel IS a decomposition destination (P-02/P-03/P-04a/P-04b/P-11 move ~35
// files + several thousand LOC into it); its marker-era measured ceiling
// (133 files / 35955 LOC) has ZERO headroom for those moves, so it is seeded
// from the ~37k end-state with file headroom. Operation 10 adds the generalized
// execution-source usage contract to Kernel and the evidence-backed Codex
// history/cache attribution to LogParsers. Those are the owning modules, so the
// planned ceilings include the measured 272/302-LOC feature growth plus less
// than 160 lines of bounded headroom instead of creating artificial leaf targets.
const PLANNED_CEILINGS = {
  // Shared-Rust rollout authority stays a narrow Foundation-only leaf. The
  // ceiling covers profiles, candidate identity, evidence comparison, and the
  // generic shadow selector without allowing domain business logic to move in.
  OpenBurnBarDomainCoreRuntime: { maxFiles: 8, maxLines: 1000 },
  // Assistant identity and interaction contracts stay in a Foundation-only
  // leaf below Kernel. The ceiling leaves modest file/LOC headroom without
  // allowing the extracted slice to become another monolith.
  OpenBurnBarAssistantModels: { maxFiles: 15, maxLines: 2700 },
  // Project-code intelligence wire contracts, carved out of Kernel's
  // `BurnBarProjectCodeMemoryContracts.swift` (which held two unrelated contract
  // families) when Kernel hit its LOC ceiling. Seeded just above the measured
  // 866 LOC: this leaf holds ONE contract family, so a second file or a few
  // hundred more lines should have to argue for itself rather than turn the leaf
  // into the next dumping ground.
  OpenBurnBarProjectCodeContracts: { maxFiles: 2, maxLines: 1000 },
  // Linux parity adds daemon-owned cloud/privacy/trusted-device/media contracts
  // after the assistant-model extraction. Keep the ceiling below the next
  // monolith while accounting for those cross-platform authority surfaces.
  // 191, exactly the current count, for KeychainInteractionGate.swift — the gate
  // that keeps the first-run keychain prompt from firing once per caller. No
  // headroom on purpose: this target is supposed to dissolve, so the next file
  // added to it should have to argue for itself.
  OpenBurnBarKernel: { maxFiles: 191, maxLines: 54000 },
  OpenBurnBarParserSupport: { maxFiles: 5, maxLines: 1200 },
  OpenBurnBarSQLiteReader: { maxFiles: 3, maxLines: 450 },
  // The final local-parser catalog adds bounded corpus parsers for the Linux
  // provider matrix; the ceiling remains below a general-purpose god target.
  // Idle usage/quota parse mining (#2244) lands in these owning modules rather
  // than a new leaf; keep the file ceiling at 35 and the LOC ceiling just
  // above the measured 16,472.
  // One parser per supported harness is this target's shape, so each new harness
  // costs it a file by design — decomposing "parsers" further would be arbitrary.
  // Raised for FxParser.swift (fx harness). 40/18500 leaves room for ~4 more
  // harnesses before this needs re-examining.
  OpenBurnBarLogParsers: { maxFiles: 40, maxLines: 18500 },
  OpenBurnBarQuota: { maxFiles: 55, maxLines: 13000 },
  // VectorKit gains OpenBurnBarSearchContracts.swift (P-03 re-slice / FIX 4) on
  // top of the vector indexes + SearchPlanner + Pensieve, so its ceiling covers
  // SearchContracts too.
  OpenBurnBarVectorKit: { maxFiles: 12, maxLines: 5800 },
  OpenBurnBarInsights: { maxFiles: 100, maxLines: 20000 },
  // Recap carved out of Insights: the monthly deck feature landed as 26 files /
  // 5312 lines, which pushed Insights past 20000. Ceiling is ~1.13x the measured
  // size so the feature can settle without becoming the next god module.
  OpenBurnBarRecap: { maxFiles: 30, maxLines: 6000 },
  OpenBurnBarHermes: { maxFiles: 10, maxLines: 1800 },
  OpenBurnBarPretext: { maxFiles: 5, maxLines: 850 },
  OpenBurnBarTextExpansion: { maxFiles: 8, maxLines: 1100 },
  OpenBurnBarLaunchServices: { maxFiles: 12, maxLines: 6100 },
  OpenBurnBarUI: { maxFiles: 160, maxLines: 40000 },
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
