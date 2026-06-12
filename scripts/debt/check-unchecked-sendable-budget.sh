#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/unchecked-sendable-baseline.json"
counter_path="${repo_root}/tools/concurrency-debt/count-unchecked-sendable.sh"

if [[ ! -f "${baseline_path}" ]]; then
  echo "Missing @unchecked Sendable baseline: ${baseline_path}" >&2
  echo "Run scripts/debt/update-unchecked-sendable-baseline.sh to capture the current budget." >&2
  exit 1
fi

live_report="$(mktemp "${TMPDIR:-/tmp}/unchecked-sendable-live.XXXXXX")"
trap 'rm -f "${live_report}"' EXIT

bash "${counter_path}" --repo-root "${repo_root}" --format json > "${live_report}"

node - "${baseline_path}" "${live_report}" <<'NODE'
const fs = require("node:fs");

const [baselinePath, livePath] = process.argv.slice(2);
const baseline = JSON.parse(fs.readFileSync(baselinePath, "utf8"));
const live = JSON.parse(fs.readFileSync(livePath, "utf8"));
const count = live.total;

if (!Number.isInteger(count)) {
  console.error(`Invalid live @unchecked Sendable count in ${livePath}`);
  process.exit(1);
}
if (!Number.isInteger(baseline.total)) {
  console.error(`Invalid @unchecked Sendable baseline total in ${baselinePath}`);
  process.exit(1);
}

console.log(`@unchecked Sendable budget: live=${count} baseline=${baseline.total}`);

if (count > baseline.total) {
  console.error(`@unchecked Sendable budget exceeded by ${count - baseline.total}.`);
  console.error("Prefer a real Sendable conformance or isolation; only add @unchecked Sendable with an AUDIT comment and an intentional baseline bump.");
  process.exit(1);
}

if (count < baseline.total) {
  console.log(`@unchecked Sendable debt improved by ${baseline.total - count}; update the baseline intentionally.`);
}
NODE
