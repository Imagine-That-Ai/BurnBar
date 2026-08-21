#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
counter_path="${repo_root}/tools/error-debt/count-error-debt.py"

live_report="$(mktemp "${TMPDIR:-/tmp}/grdb-row-cast-live.XXXXXX")"
trap 'rm -f "${live_report}"' EXIT

python3 "${counter_path}" --repo-root "${repo_root}" --metric grdb-row-cast --format json > "${live_report}"

node - "${live_report}" <<'NODE'
const fs = require("node:fs");

const [livePath] = process.argv.slice(2);
const live = JSON.parse(fs.readFileSync(livePath, "utf8"));
const count = live.grdbRowCast?.total;

if (!Number.isInteger(count)) {
  console.error(`Invalid live GRDB row-cast count in ${livePath}`);
  process.exit(1);
}

console.log(`grdb row-cast assert-zero: live=${count} target=0`);
if (count === 0) {
  process.exit(0);
}

for (const site of live.grdbRowCast.sites ?? []) {
  console.error(`  ${site}`);
}
console.error("");
console.error("Untyped GRDB row casts must stay at zero.");
console.error("`row[\"c\"]` returns the raw SQLite storage value — Int64 for INTEGER, Double for REAL —");
console.error("so `as? Int`, `as? Bool` and `as? Date` always yield nil, and `as? Double` yields nil on");
console.error("any INTEGER column. The `?? default` beside the cast then hides the failure.");
console.error("");
console.error("Read through the typed subscript instead:");
console.error("  let count: Int = row[\"messageCount\"] ?? 0");
console.error("  let isLocal: Bool = row[\"isLocal\"] ?? false");
console.error("  let createdAt = OpenBurnBarDatabase.parseDateValue(row[\"createdAt\"])");
console.error("");
console.error("Add a reviewed `// grdb-row-ok(<reason>)` tag only when the value genuinely is not a GRDB row.");
process.exit(1);
NODE
