#!/usr/bin/env bash
# Build the Functions shared runtime package (3.5 deploy codebases).
set -euo pipefail

cd "$(dirname "$0")/.."

pkg="packages/functions-shared"

if [[ ! -x "$pkg/node_modules/.bin/tsc" ]]; then
  npm ci --prefix "$pkg"
fi

npm run build --prefix "$pkg"
