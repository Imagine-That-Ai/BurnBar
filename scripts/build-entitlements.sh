#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

pkg="packages/entitlements"

if [[ ! -x "$pkg/node_modules/.bin/tsc" ]]; then
  npm ci --prefix "$pkg"
fi

npm run build --prefix "$pkg"
