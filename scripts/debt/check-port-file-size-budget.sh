#!/usr/bin/env bash
# Shrink-only file-size gate for the cross-platform ports (Kotlin / Rust / TS).
#
# The Swift ratchet (check-swift-file-size-budget.sh) drove the macOS/iOS god
# files to zero; this is its port-side analogue. Fails CI if EITHER:
#   - a NEW production port file crosses the size target (not in the baseline), or
#   - a baselined file GROWS beyond its recorded line count.
# Baselined files may only shrink. As they drop below the target, regenerate the
# baseline (scripts/debt/update-port-file-size-baseline.sh) to ratchet down.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/port-file-size-baseline.json"
counter_path="${repo_root}/tools/error-debt/count-port-file-size.py"

if [[ ! -f "${baseline_path}" ]]; then
  echo "Missing port file-size baseline: ${baseline_path}" >&2
  echo "Run scripts/debt/update-port-file-size-baseline.sh to capture the current budget." >&2
  exit 1
fi

target="$(node -e "console.log(JSON.parse(require('node:fs').readFileSync(process.argv[1],'utf8')).target)" "${baseline_path}")"

live_report="$(mktemp "${TMPDIR:-/tmp}/port-file-size-live.XXXXXX")"
trap 'rm -f "${live_report}"' EXIT
python3 "${counter_path}" --repo-root "${repo_root}" --target "${target}" --format json > "${live_report}"

node - "${baseline_path}" "${live_report}" <<'NODE'
const fs = require("node:fs");
const [baselinePath, livePath] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
const live = JSON.parse(fs.readFileSync(livePath, "utf8"));

const baseByPath = new Map(baseline.files.map((f) => [f.path, f.lines]));
const liveByPath = new Map(live.files.map((f) => [f.path, f.lines]));

const newViolations = [];
const grown = [];
for (const [path, lines] of liveByPath) {
  if (!baseByPath.has(path)) {
    newViolations.push({ path, lines });
  } else if (lines > baseByPath.get(path)) {
    grown.push({ path, from: baseByPath.get(path), to: lines });
  }
}
const removed = [...baseByPath.keys()].filter((p) => !liveByPath.has(p));

console.log(`Port file-size budget: target=${baseline.target} baselined=${baseline.files.length} live-over-target=${live.files.length}`);

let failed = false;
if (newViolations.length) {
  failed = true;
  console.error(`\nFAIL: ${newViolations.length} NEW port file(s) over ${baseline.target} lines (decompose before merging):`);
  for (const v of newViolations) console.error(`  ${v.lines}  ${v.path}`);
}
if (grown.length) {
  failed = true;
  console.error(`\nFAIL: ${grown.length} baselined file(s) GREW (they may only shrink):`);
  for (const g of grown) console.error(`  ${g.from} -> ${g.to}  ${g.path}`);
}
if (removed.length) {
  console.log(`\nImproved: ${removed.length} file(s) dropped below ${baseline.target} lines — regenerate the baseline to ratchet down:`);
  for (const p of removed) console.log(`  ${p}`);
}
if (failed) {
  console.error("\nThe canonical budget is budgets/port-file-size-baseline.json.");
  process.exit(1);
}
console.log("OK: no new oversized port files and no baselined file grew.");
NODE
