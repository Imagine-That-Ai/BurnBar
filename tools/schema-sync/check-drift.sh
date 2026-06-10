#!/usr/bin/env bash
# Verify generated schema bindings are current.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

generated_paths=(
  functions/src/types/generated
  OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels
  android/app/src/main/java/com/openburnbar/data/models/generated
)

before_diff="$(mktemp)"
after_diff="$(mktemp)"
trap 'rm -f "$before_diff" "$after_diff"' EXIT

git diff --binary -- "${generated_paths[@]}" > "$before_diff"

echo "==> Emitting schema bindings…"
npm --prefix tools/schema-sync run emit

echo "==> Checking for drift…"
git diff --binary -- "${generated_paths[@]}" > "$after_diff"
if ! cmp -s "$before_diff" "$after_diff"; then
  echo "::error::Schema drift detected. Run: npm --prefix tools/schema-sync run emit" >&2
  git diff --stat -- "${generated_paths[@]}" || true
  exit 1
fi
if [[ -s "$after_diff" ]]; then
  echo "::notice::Generated schema bindings have uncommitted changes relative to HEAD; emit is idempotent for the current worktree."
fi

echo "==> Checking hand-maintained schema mirrors…"
node tools/schema-sync/check-hand-mirror.mjs

echo "==> Checking hand-maintained TS surface budget…"
node tools/schema-sync/check-legacy-budget.mjs

echo "==> Checking Firestore collection-group index coverage…"
node tools/firestore-indexes/check-collection-group-coverage.mjs

echo "==> Schema sync check passed ==="
