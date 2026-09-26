#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

pkg="packages/entitlements"

if [[ ! -x "$pkg/node_modules/.bin/tsc" ]]; then
  npm ci --prefix "$pkg"
fi

npm run build --prefix "$pkg"

# See build-functions-shared.sh: tsc/vitest-only jobs never trigger a
# codebase prebuild, so every package build re-syncs what is built so far.
node scripts/sync-functions-vendors.mjs
