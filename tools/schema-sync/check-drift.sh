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

echo "==> Schema sync check passed ==="
