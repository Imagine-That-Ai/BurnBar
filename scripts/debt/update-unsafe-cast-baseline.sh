#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/unsafe-cast-baseline.json"
scanner_path="${repo_root}/tools/type-debt/audit-unsafe-casts.mjs"
tmp_path="$(mktemp "${TMPDIR:-/tmp}/unsafe-cast-baseline.XXXXXX")"

trap 'rm -f "${tmp_path}"' EXIT

node "${scanner_path}" --repo-root "${repo_root}" --format json --ts-mode token-fallback > "${tmp_path}"
mkdir -p "$(dirname "${baseline_path}")"
mv "${tmp_path}" "${baseline_path}"
chmod 644 "${baseline_path}"

total="$(node -e "const fs=require('node:fs'); console.log(JSON.parse(fs.readFileSync(process.argv[1], 'utf8')).total)" "${baseline_path}")"
echo "Updated ${baseline_path} with ${total} unsafe cast violations."
