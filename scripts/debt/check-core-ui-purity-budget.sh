#!/usr/bin/env bash
# Shrink-only OpenBurnBarCore UI-purity gate (audit 2026-06-30 finding #4).
#
# The privileged/daemon binaries transitively link the OpenBurnBarCore main
# module, which today contains SwiftUI views and AppKit launchers. This gate
# freezes that surface so kernel extraction can only make progress:
#
# Fails CI if EITHER:
#   - a file in Sources/OpenBurnBarCore imports SwiftUI/AppKit and is NOT in
#     the baseline (or adds a framework the baseline does not record for it), or
#   - any file in the pure sibling targets (ComputerUseCore, Media, IrohRelay,
#     SignalCore, SignalSessionTransport, FirestoreModels, Analytics,
#     LinuxSecurity, Data, RemoteEngine, CoreCAbi) imports SwiftUI/AppKit at all
#     (assert-zero; these targets are UI-free today and must stay that way).
#
# Baselined files may only disappear (moved out of Core or de-UI'd). When they
# do, regenerate the baseline to ratchet down:
#   scripts/debt/check-core-ui-purity-budget.sh --update
#
# The canonical budget is budgets/core-ui-purity-baseline.json.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/core-ui-purity-baseline.json"
mode="check"
if [[ "${1:-}" == "--update" ]]; then
  mode="update"
fi

node - "${repo_root}" "${baseline_path}" "${mode}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [repoRoot, baselinePath, mode] = process.argv.slice(2);
const sourcesRoot = path.join(repoRoot, "OpenBurnBarCore", "Sources");
const monolithTarget = "OpenBurnBarCore";
const pureTargets = [
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
const importPattern = /^\s*(?:@_exported\s+)?(?:@preconcurrency\s+)?import\s+(SwiftUI|AppKit)\b/;

function uiImports(filePath) {
  const found = new Set();
  for (const line of fs.readFileSync(filePath, "utf8").split("\n")) {
    const m = line.match(importPattern);
    if (m) found.add(m[1]);
  }
  return [...found].sort();
}

function scanTarget(target) {
  const root = path.join(sourcesRoot, target);
  if (!fs.existsSync(root)) return [];
  const hits = [];
  for (const entry of fs.readdirSync(root, { recursive: true })) {
    const rel = String(entry);
    if (!rel.endsWith(".swift")) continue;
    const abs = path.join(root, rel);
    if (!fs.statSync(abs).isFile()) continue;
    const frameworks = uiImports(abs);
    if (frameworks.length) {
      hits.push({
        path: path.relative(repoRoot, abs),
        frameworks,
      });
    }
  }
  return hits.sort((a, b) => a.path.localeCompare(b.path));
}

const monolithLive = scanTarget(monolithTarget);

if (mode === "update") {
  const baseline = {
    note: "Files in OpenBurnBarCore/Sources/OpenBurnBarCore importing SwiftUI/AppKit. Shrink-only: entries may only be removed (audit 2026-06-30 finding #4, kernel extraction). Regenerate via scripts/debt/check-core-ui-purity-budget.sh --update.",
    total: monolithLive.length,
    files: monolithLive,
  };
  fs.writeFileSync(baselinePath, JSON.stringify(baseline, null, 2) + "\n");
  console.log(`Wrote ${path.relative(repoRoot, baselinePath)}: ${monolithLive.length} UI-importing file(s) in ${monolithTarget}.`);
  process.exit(0);
}

if (!fs.existsSync(baselinePath)) {
  console.error(`Missing Core UI-purity baseline: ${baselinePath}`);
  console.error("Run scripts/debt/check-core-ui-purity-budget.sh --update to capture the current budget.");
  process.exit(1);
}
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
const baseByPath = new Map(baseline.files.map((f) => [f.path, new Set(f.frameworks)]));

let failed = false;

const newFiles = [];
const widened = [];
for (const hit of monolithLive) {
  const allowed = baseByPath.get(hit.path);
  if (!allowed) {
    newFiles.push(hit);
    continue;
  }
  const extra = hit.frameworks.filter((f) => !allowed.has(f));
  if (extra.length) widened.push({ path: hit.path, extra });
}
const liveSet = new Set(monolithLive.map((f) => f.path));
const removed = [...baseByPath.keys()].filter((p) => !liveSet.has(p));

console.log(`Core UI-purity budget: baselined=${baseline.files.length} live=${monolithLive.length}`);

if (newFiles.length) {
  failed = true;
  console.error(`\nFAIL: ${newFiles.length} NEW SwiftUI/AppKit-importing file(s) in ${monolithTarget} (put UI in the app targets or an OpenBurnBarUI product, not Core):`);
  for (const f of newFiles) console.error(`  [${f.frameworks.join(",")}]  ${f.path}`);
}
if (widened.length) {
  failed = true;
  console.error(`\nFAIL: ${widened.length} baselined file(s) added a UI framework import:`);
  for (const f of widened) console.error(`  +${f.extra.join(",+")}  ${f.path}`);
}

for (const target of pureTargets) {
  const hits = scanTarget(target);
  if (hits.length) {
    failed = true;
    console.error(`\nFAIL: ${target} must stay SwiftUI/AppKit-free (assert-zero):`);
    for (const f of hits) console.error(`  [${f.frameworks.join(",")}]  ${f.path}`);
  }
}

if (removed.length) {
  console.log(`\nImproved: ${removed.length} file(s) left the UI-import set — regenerate the baseline to ratchet down:`);
  for (const p of removed) console.log(`  ${p}`);
}

if (failed) {
  console.error("\nThe canonical budget is budgets/core-ui-purity-baseline.json.");
  process.exit(1);
}
console.log("OK: no new UI imports in Core and all pure targets are clean.");
NODE
