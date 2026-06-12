#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/unsafe-cast-baseline.json"
scanner_path="${repo_root}/tools/type-debt/audit-unsafe-casts.mjs"

if [[ ! -f "${baseline_path}" ]]; then
  echo "Missing unsafe cast baseline: ${baseline_path}" >&2
  echo "Run scripts/debt/update-unsafe-cast-baseline.sh to capture the current budget." >&2
  exit 1
fi

live_report="$(mktemp "${TMPDIR:-/tmp}/unsafe-cast-live.XXXXXX")"
trap 'rm -f "${live_report}"' EXIT

node "${scanner_path}" --repo-root "${repo_root}" --format json --ts-mode token-fallback > "${live_report}"

node - "${baseline_path}" "${live_report}" <<'NODE'
const fs = require("node:fs");

const [baselinePath, livePath] = process.argv.slice(2);

function readJSON(filePath, label) {
  const text = fs.readFileSync(filePath, "utf8");
  if (text.trim().length === 0) {
    console.error(`Empty unsafe cast ${label} JSON: ${filePath}`);
    process.exit(1);
  }

  try {
    return JSON.parse(text);
  } catch (error) {
    console.error(`Invalid unsafe cast ${label} JSON: ${filePath}`);
    console.error(error.message);
    process.exit(1);
  }
}

const baseline = readJSON(baselinePath, "baseline");
const live = readJSON(livePath, "live report");

if (!Number.isInteger(baseline.total)) {
  console.error(`Invalid unsafe cast baseline total in ${baselinePath}`);
  process.exit(1);
}

console.log(`Unsafe cast budget: live=${live.total} baseline=${baseline.total}`);

if (live.total > baseline.total) {
  console.error(`Unsafe cast budget exceeded by ${live.total - baseline.total}.`);
  console.error("Run the scanner locally and remove the new violations before merging.");
  process.exit(1);
}

if (live.total < baseline.total) {
  console.log(`Unsafe cast debt improved by ${baseline.total - live.total}; update the baseline intentionally.`);
}
NODE
