#!/usr/bin/env bash
# Shrink-only OpenBurnBarCoreTests population gate (Phase-2 WS-B test decomposition,
# plans/core-decomposition2/packets/B0 series).
#
# OpenBurnBarCoreTests is the dissolving god test target: every one of its files is
# mapped to a per-module destination test target (or classified INTEGRATION and kept)
# by the B0 mapping. This gate freezes the population so the decomposition can only
# make progress:
#
#   - FAILS if a .swift file exists under Tests/OpenBurnBarCoreTests that is not in
#     the baseline (new test files belong in the per-module test target that owns the
#     tested module — see the B* packet cards; genuinely cross-module INTEGRATION
#     tests may be added here only by ratcheting the baseline UP deliberately with
#     --update in the same PR and saying why).
#   - Shrink is NON-FATAL: when baselined files disappear (moved out by a B packet),
#     the gate prints a notice and passes. Regenerate to ratchet down:
#       scripts/debt/check-coretests-file-budget.sh --update
#
# The canonical budget is budgets/coretests-file-baseline.json.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/coretests-file-baseline.json"
mode="check"
if [[ "${1:-}" == "--update" ]]; then
  mode="update"
fi

node - "${repo_root}" "${baseline_path}" "${mode}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [repoRoot, baselinePath, mode] = process.argv.slice(2);
const testsRoot = path.join(
  repoRoot,
  "OpenBurnBarCore",
  "Tests",
  "OpenBurnBarCoreTests",
);

function liveFiles() {
  const files = [];
  for (const entry of fs.readdirSync(testsRoot, { recursive: true })) {
    const rel = String(entry);
    if (!rel.endsWith(".swift")) continue;
    const abs = path.join(testsRoot, rel);
    if (!fs.statSync(abs).isFile()) continue;
    files.push(rel.split(path.sep).join("/"));
  }
  return files.sort();
}

const live = liveFiles();

if (mode === "update") {
  const baseline = {
    note: "Swift files in OpenBurnBarCore/Tests/OpenBurnBarCoreTests (the dissolving god test target). Shrink-only: entries may only be removed as WS-B move packets carry them to per-module test targets (plans/core-decomposition2/packets/B* cards). New files fail CI. Regenerate via scripts/debt/check-coretests-file-budget.sh --update.",
    total: live.length,
    files: live,
  };
  fs.writeFileSync(baselinePath, JSON.stringify(baseline, null, 2) + "\n");
  console.log(
    `Wrote ${path.relative(repoRoot, baselinePath)}: ${live.length} .swift file(s) in OpenBurnBarCoreTests.`,
  );
  process.exit(0);
}

if (!fs.existsSync(baselinePath)) {
  console.error(`Missing OpenBurnBarCoreTests file baseline: ${baselinePath}`);
  console.error(
    "Run scripts/debt/check-coretests-file-budget.sh --update to capture the current budget.",
  );
  process.exit(1);
}
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
const baseSet = new Set(baseline.files);
const liveSet = new Set(live);

const added = live.filter((f) => !baseSet.has(f));
const removed = baseline.files.filter((f) => !liveSet.has(f));

console.log(
  `OpenBurnBarCoreTests file budget: baselined=${baseline.files.length} live=${live.length}`,
);

if (removed.length) {
  // Non-fatal by design: a WS-B move packet just carried files out. Ratcheting the
  // baseline down in the same PR keeps the budget honest but is not merge-blocking.
  console.log(
    `\nNOTICE: ${removed.length} baselined file(s) left OpenBurnBarCoreTests (decomposition progress).`,
  );
  console.log(
    "Ratchet the budget down: scripts/debt/check-coretests-file-budget.sh --update",
  );
  for (const f of removed) console.log(`  - ${f}`);
}

if (added.length) {
  console.error(
    `\nFAIL: ${added.length} NEW .swift file(s) in OpenBurnBarCoreTests (the dissolving god test target).`,
  );
  console.error(
    "Put new tests in the per-module test target that owns the tested module",
  );
  console.error(
    "(Tests/OpenBurnBar<Module>Tests — see plans/core-decomposition2/packets/B* cards).",
  );
  console.error(
    "Genuinely cross-module INTEGRATION tests may stay here: ratchet the baseline UP",
  );
  console.error(
    "deliberately with scripts/debt/check-coretests-file-budget.sh --update and justify it in the PR.",
  );
  for (const f of added) console.error(`  + ${f}`);
  console.error("\nThe canonical budget is budgets/coretests-file-baseline.json.");
  process.exit(1);
}

console.log("OK: no new files in OpenBurnBarCoreTests.");
NODE
