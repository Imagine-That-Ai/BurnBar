#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scanner_path="${repo_root}/tools/type-debt/audit-unsafe-casts.mjs"

live_report="$(mktemp "${TMPDIR:-/tmp}/unsafe-cast-live.XXXXXX")"
trap 'rm -f "${live_report}"' EXIT

# The scanner writes the file itself (--out): shell `>` redirection proved
# fragile under sandboxed $TMPDIR (0-byte reports despite exit 0). Belt and
# suspenders: if the report still lands empty (sandbox file interception),
# retry via a repo-local path, and fail LOUDLY rather than parse air.
node "${scanner_path}" --repo-root "${repo_root}" --ts-mode token-fallback --out "${live_report}"
if [[ ! -s "${live_report}" ]]; then
  live_report="${repo_root}/.unsafe-cast-live.json"
  trap 'rm -f "${live_report}"' EXIT
  node "${scanner_path}" --repo-root "${repo_root}" --ts-mode token-fallback --out "${live_report}"
fi
if [[ ! -s "${live_report}" ]]; then
  echo "unsafe-cast scanner produced an empty report — refusing to compare" >&2
  exit 1
fi

node - "${live_report}" <<'NODE'
const fs = require("node:fs");

const [livePath] = process.argv.slice(2);

function readJSON(filePath) {
  const text = fs.readFileSync(filePath, "utf8");
  if (text.trim().length === 0) {
    console.error(`Empty unsafe cast JSON: ${filePath}`);
    process.exit(1);
  }

  try {
    return JSON.parse(text);
  } catch (error) {
    console.error(`Invalid unsafe cast JSON: ${filePath}`);
    console.error(error.message);
    process.exit(1);
  }
}

const live = readJSON(livePath);
if (!Number.isInteger(live.total)) {
  console.error(`Invalid unsafe cast report total in ${livePath}`);
  process.exit(1);
}

console.log(`Unsafe cast assert-zero: live=${live.total} target=0`);

if (live.total !== 0) {
  console.error("Unsafe cast debt is no longer budgeted. Remove every violation before merging.");
  const byKind = Object.entries(live.byKind ?? {});
  if (byKind.length > 0) {
    console.error("By kind:");
    for (const [kind, count] of byKind) console.error(`  ${kind}: ${count}`);
  }
  const examples = Array.isArray(live.violations) ? live.violations.slice(0, 20) : [];
  if (examples.length > 0) {
    console.error("First violations:");
    for (const item of examples) {
      console.error(`  ${item.path}:${item.line}:${item.column} ${item.kind} ${item.snippet ?? ""}`.trimEnd());
    }
  }
  process.exit(1);
}
NODE
