#!/usr/bin/env bash
# Shrink-only mission split-brain gate (audit 2026-06-30 finding #5).
#
# The GUI app carries a parallel mission authority (trust validation, approval
# gating, backend resolution, direct CLI execution) in the
# CLIAgentMissionRequestListener cluster, duplicating the daemon's
# BurnBarMissionControlService on a security-sensitive path. Remediation
# designates the daemon as the single authority and reduces the GUI cluster to
# a transport/relay. This gate freezes the GUI cluster so it can only shrink:
#
# Fails CI if EITHER:
#   - a NEW file matching AgentLens/Services/CloudSync/CLIAgentMission*.swift
#     appears that is not in the baseline, or
#   - a baselined file GROWS beyond its recorded line count.
#
# The prefix is CLIAgentMission, not CLIAgentMissionRequestListener, because the
# narrower glob was in fact evaded: PR #2362 renamed +ApprovalFlow, +DirectExecution
# and +Handling out of the `RequestListener` prefix, and the gate then reported their
# 1387 baselined lines as a 1387-line IMPROVEMENT while the same code grew to 2076
# lines under the new names. A rename is no longer a way out of the cluster; only
# actually moving authority to the daemon is.
#
# Baselined files may only shrink or disappear. Regenerate to ratchet down:
#   scripts/debt/check-mission-splitbrain-budget.sh --update
#
# The canonical budget is budgets/mission-splitbrain-baseline.json.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/mission-splitbrain-baseline.json"
mode="check"
if [[ "${1:-}" == "--update" ]]; then
  mode="update"
fi

node - "${repo_root}" "${baseline_path}" "${mode}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [repoRoot, baselinePath, mode] = process.argv.slice(2);
const clusterDir = path.join(repoRoot, "AgentLens", "Services", "CloudSync");
const clusterPrefix = "CLIAgentMission";

function scanCluster() {
  if (!fs.existsSync(clusterDir)) return [];
  return fs
    .readdirSync(clusterDir, { recursive: true })
    .map(String)
    .filter((rel) => path.basename(rel).startsWith(clusterPrefix) && rel.endsWith(".swift"))
    .filter((rel) => fs.statSync(path.join(clusterDir, rel)).isFile())
    .map((rel) => {
      const abs = path.join(clusterDir, rel);
      const lines = fs.readFileSync(abs, "utf8").split("\n").length - 1;
      return { path: path.relative(repoRoot, abs), lines };
    })
    .sort((a, b) => a.path.localeCompare(b.path));
}

const live = scanCluster();
const liveTotal = live.reduce((sum, f) => sum + f.lines, 0);

if (mode === "update") {
  const baseline = {
    note: "GUI-side mission-authority cluster (audit 2026-06-30 finding #5, split-brain mission execution). Shrink-only: files may only shrink or disappear as authority moves to the daemon BurnBarMissionControlService. Regenerate via scripts/debt/check-mission-splitbrain-budget.sh --update. RE-BASELINED 2026-08-20: the glob was widened from CLIAgentMissionRequestListener to CLIAgentMission after PR #2362 renamed +ApprovalFlow/+DirectExecution/+Handling out of the narrower prefix, which the gate then scored as a 1387-line improvement while the same code grew to 2076 lines under the new names. This baseline records the cluster's TRUE size for the first time; the jump from 3506 to 4320 is previously-hidden debt plus #2362's new backends, not debt this PR added. Re-run after merging main at 7781db4866: 4320 -> 4323, the +3 being #2384's version of CLIAgentMissionHostHandling arriving, not new debt.",
    totalLines: liveTotal,
    files: live,
  };
  fs.writeFileSync(baselinePath, JSON.stringify(baseline, null, 2) + "\n");
  console.log(`Wrote ${path.relative(repoRoot, baselinePath)}: ${live.length} file(s), ${liveTotal} lines.`);
  process.exit(0);
}

if (!fs.existsSync(baselinePath)) {
  console.error(`Missing mission split-brain baseline: ${baselinePath}`);
  console.error("Run scripts/debt/check-mission-splitbrain-budget.sh --update to capture the current budget.");
  process.exit(1);
}
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
const baseByPath = new Map(baseline.files.map((f) => [f.path, f.lines]));

const newFiles = [];
const grown = [];
for (const f of live) {
  if (!baseByPath.has(f.path)) {
    newFiles.push(f);
  } else if (f.lines > baseByPath.get(f.path)) {
    grown.push({ path: f.path, from: baseByPath.get(f.path), to: f.lines });
  }
}
const liveSet = new Set(live.map((f) => f.path));
const removed = [...baseByPath.keys()].filter((p) => !liveSet.has(p));

console.log(`Mission split-brain budget: baselined=${baseline.files.length} files/${baseline.totalLines} lines, live=${live.length} files/${liveTotal} lines`);

let failed = false;
if (newFiles.length) {
  failed = true;
  console.error(`\nFAIL: ${newFiles.length} NEW file(s) in the GUI mission-authority cluster (authority belongs in the daemon MissionControl, not the GUI listener):`);
  for (const f of newFiles) console.error(`  ${f.lines}  ${f.path}`);
}
if (grown.length) {
  failed = true;
  console.error(`\nFAIL: ${grown.length} cluster file(s) GREW (the GUI mission authority may only shrink):`);
  for (const g of grown) console.error(`  ${g.from} -> ${g.to}  ${g.path}`);
}
if (removed.length) {
  console.log(`\nImproved: ${removed.length} cluster file(s) removed — regenerate the baseline to ratchet down:`);
  for (const p of removed) console.log(`  ${p}`);
}
if (failed) {
  console.error("\nThe canonical budget is budgets/mission-splitbrain-baseline.json.");
  process.exit(1);
}
console.log("OK: the GUI mission-authority cluster did not grow.");
NODE
