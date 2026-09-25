#!/usr/bin/env bash
# Build all Functions deploy codebases (3.5): local packages first, then every
# codebase. Installs are the caller's job (CI runs npm ci per package); this
# script only builds, so it stays hermetic on warm checkouts.
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/build-signal-envelope-contracts.sh
./scripts/build-entitlements.sh
./scripts/build-functions-shared.sh
node scripts/sync-functions-vendors.mjs

for codebase in functions-identity functions-sync functions-media functions; do
  npm run build --prefix "$codebase"
done
