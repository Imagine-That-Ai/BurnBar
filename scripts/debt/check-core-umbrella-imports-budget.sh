#!/usr/bin/env bash
# Core-decomposition regrowth gate #2 (docs/CORE_DECOMPOSITION_PROGRAM.md).
#
# The decomposition repoints privileged consumers off the OpenBurnBarCore umbrella
# onto narrow targets (daemon/CLI -> OpenBurnBarEngine at S17, Widget -> Kernel+
# Insights+UI at S18, Keyboard -> TextExpansion+Kernel at S19). Apps (AgentLens,
# OpenBurnBarMobile) deliberately KEEP importing the umbrella. This gate freezes
# umbrella imports per consumer root so they can only shrink:
#
# Fails CI if a NEW file in a tracked root contains `import OpenBurnBarCore` that
# is not in that root's baseline. After a root's repoint packet lands, the
# integrator ratchets its baseline down to zero (daemon after S17, widget after
# S18, keyboard after S19), and this gate then keeps it at zero.
#
# NON-FATAL shrink (mirrors scripts/debt/check-swift-file-size-budget.sh): when a
# root drops umbrella imports, the gate prints "Improved: ... run --update" and
# exits 0, so repoint packets merge without a baseline race:
#   scripts/debt/check-core-umbrella-imports-budget.sh --update
#
# The canonical budget is budgets/core-umbrella-imports-baseline.json.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/core-umbrella-imports-baseline.json"
mode="check"
if [[ "${1:-}" == "--update" ]]; then
  mode="update"
fi

node - "${repo_root}" "${baseline_path}" "${mode}" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [repoRoot, baselinePath, mode] = process.argv.slice(2);

// Consumer roots scanned for umbrella imports. AgentLens/OpenBurnBarMobile keep
// the umbrella (ratchet-only, never bulk-rewritten); the daemon/widget/keyboard
// roots ratchet to zero after their repoint packets. tools/ and scripts/ catch
// stray umbrella imports in automation.
const consumerRoots = [
  "OpenBurnBarDaemon",
  "OpenBurnBarWidget",
  "OpenBurnBarKeyboard",
  "AgentLens",
  "OpenBurnBarMobile",
  "tools",
  "scripts",
];

const importRe = /^\s*(?:@_[A-Za-z0-9_]+\s+)*import\s+OpenBurnBarCore\b/;

function scanRoot(root) {
  const absRoot = path.join(repoRoot, root);
  if (!fs.existsSync(absRoot)) return [];
  const hits = [];
  for (const entry of fs.readdirSync(absRoot, { recursive: true })) {
    const rel = String(entry);
    if (!rel.endsWith(".swift")) continue;
    const abs = path.join(absRoot, rel);
    let stat;
    try {
      stat = fs.statSync(abs);
    } catch {
      continue;
    }
    if (!stat.isFile()) continue;
    const text = fs.readFileSync(abs, "utf8");
    if (text.split("\n").some((line) => importRe.test(line))) {
      hits.push(path.relative(repoRoot, abs));
    }
  }
  return hits.sort((a, b) => a.localeCompare(b));
}

function scanAll() {
  const out = {};
  for (const root of consumerRoots) out[root] = scanRoot(root);
  return out;
}

const live = scanAll();

if (mode === "update") {
  const roots = {};
  let total = 0;
  for (const root of consumerRoots) {
    roots[root] = { count: live[root].length, files: live[root] };
    total += live[root].length;
  }
  const baseline = {
    note:
      "Per-consumer-root files importing the OpenBurnBarCore umbrella " +
      "(docs/CORE_DECOMPOSITION_PROGRAM.md). Shrink-only: no NEW file may import the " +
      "umbrella in a tracked root. Privileged roots (OpenBurnBarDaemon, " +
      "OpenBurnBarWidget, OpenBurnBarKeyboard) ratchet to zero after their repoint " +
      "packets (S17/S18/S19); AgentLens/OpenBurnBarMobile keep the umbrella " +
      "deliberately. Regenerate via " +
      "scripts/debt/check-core-umbrella-imports-budget.sh --update.",
    total,
    roots,
  };
  fs.writeFileSync(baselinePath, JSON.stringify(baseline, null, 2) + "\n");
  console.log(
    `Wrote ${path.relative(repoRoot, baselinePath)}: ${total} umbrella-importing file(s) across ` +
      `${consumerRoots.length} root(s).`
  );
  process.exit(0);
}

if (!fs.existsSync(baselinePath)) {
  console.error(`Missing Core umbrella-imports baseline: ${baselinePath}`);
  console.error("Run scripts/debt/check-core-umbrella-imports-budget.sh --update to capture the current budget.");
  process.exit(1);
}
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));

let failed = false;
const shrunk = [];

for (const root of consumerRoots) {
  const baseFiles = new Set((baseline.roots[root] && baseline.roots[root].files) || []);
  const liveFiles = live[root];
  const liveSet = new Set(liveFiles);
  const newFiles = liveFiles.filter((p) => !baseFiles.has(p));
  const removed = [...baseFiles].filter((p) => !liveSet.has(p));

  console.log(`  ${root}: baselined=${baseFiles.size} live=${liveFiles.length}`);

  if (newFiles.length) {
    failed = true;
    console.error(
      `\nFAIL: ${newFiles.length} NEW file(s) in ${root} import the OpenBurnBarCore umbrella ` +
        "(import a narrow target — Kernel/Engine/UI/… — see docs/CORE_DECOMPOSITION_PROGRAM.md):"
    );
    for (const p of newFiles) console.error(`  ${p}`);
  }
  if (removed.length) shrunk.push({ root, removed });
}

if (shrunk.length && !failed) {
  console.log("\nImproved: umbrella imports dropped — run scripts/debt/check-core-umbrella-imports-budget.sh --update to ratchet down:");
  for (const { root, removed } of shrunk) {
    for (const p of removed) console.log(`  [${root}] ${p}`);
  }
}

if (failed) {
  console.error("\nThe canonical budget is budgets/core-umbrella-imports-baseline.json.");
  process.exit(1);
}
console.log("OK: no new files import the OpenBurnBarCore umbrella in any tracked root.");
NODE
