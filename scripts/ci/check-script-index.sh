#!/usr/bin/env bash
# Fail if scripts/INDEX.md is missing or no longer names the live doors.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
index="${repo_root}/scripts/INDEX.md"
if [[ ! -f "${index}" ]]; then
  echo "missing scripts/INDEX.md" >&2
  exit 1
fi
required=(
  "scripts/test-openburnbar-app.sh"
  "scripts/test-openburnbar-swift.sh"
  "scripts/ci/verify-callable-logging.sh"
  "scripts/debt/check-swift-file-size-budget.sh"
  "scripts/debt/check-string-any-boundary-budget.sh"
  "scripts/debt/check-sqlite-writer-ownership.sh"
  ".github/actions/ops-failure-issue"
  "OPENBURNBAR_DECLARED_XCFRAMEWORKS"
  "scripts/ci/verify-vendor-xcframework-checksums.sh"
  "docs/runbooks/functions-break-glass.md"
)
missing=0
for token in "${required[@]}"; do
  if ! grep -Fq "${token}" "${index}"; then
    echo "scripts/INDEX.md missing door: ${token}" >&2
    missing=1
  fi
done
if [[ "${missing}" -ne 0 ]]; then
  exit 1
fi
echo "script index OK"
