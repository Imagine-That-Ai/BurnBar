#!/usr/bin/env bash
# Assert resilienceHelpers.ts owns the canonical fetch() call all wrappers build on.
# Wave 4: the raw-fetch BAN moved to ESLint (no-restricted-globals +
# no-restricted-properties in each codebase's eslint.config.mjs, enforced on
# the PR door by fast-feedback). AST analysis catches spellings the old regex
# missed (globalThis.fetch). This script keeps only the structural half the
# linter cannot express: the canonical fetch must live in resilienceHelpers.
set -euo pipefail
cd "$(dirname "$0")/../.."

helpers="packages/functions-shared/src/resilienceHelpers.ts"
if ! grep -q "resilientFetch" "$helpers" || ! grep -q "fetch(url" "$helpers"; then
  echo "FAIL: resilienceHelpers.ts must own the canonical fetch() call" >&2
  exit 1
fi
echo "PASS: resilienceHelpers.ts owns the canonical fetch() call"
