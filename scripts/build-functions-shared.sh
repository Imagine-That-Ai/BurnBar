#!/usr/bin/env bash
# Build the Functions shared runtime package (3.5 deploy codebases).
set -euo pipefail

cd "$(dirname "$0")/.."

pkg="packages/functions-shared"

if [[ ! -x "$pkg/node_modules/.bin/tsc" ]]; then
  npm ci --prefix "$pkg"
fi

npm run build --prefix "$pkg"

# tsc --noEmit / vitest jobs never run a codebase `prebuild`, so sync here:
# postinstall's sync ran before this package was built and skipped it.
node scripts/sync-functions-vendors.mjs
