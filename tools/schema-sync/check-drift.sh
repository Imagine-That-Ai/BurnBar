#!/usr/bin/env bash
# Verify generated schema bindings match committed output.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

echo "==> Emitting schema bindings…"
npm --prefix tools/schema-sync run emit

echo "==> Checking for drift…"
if ! git diff --quiet -- \
  functions/src/types/generated \
  OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels \
  android/app/src/main/java/com/openburnbar/data/models/generated; then
  echo "::error::Schema drift detected. Run: npm --prefix tools/schema-sync run emit" >&2
  git diff --stat -- \
    functions/src/types/generated \
    OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels \
    android/app/src/main/java/com/openburnbar/data/models/generated || true
  exit 1
fi

echo "==> Checking hand-maintained schema mirrors…"
node tools/schema-sync/check-hand-mirror.mjs

echo "==> Checking hand-maintained TS surface budget…"
node tools/schema-sync/check-legacy-budget.mjs

echo "==> Schema sync check passed ==="
