#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
extension_root="$repo_root/extensions/safari"

if [[ ! -f "$extension_root/package.json" ]]; then
  echo "ERROR: Safari extension package is missing at $extension_root/package.json." >&2
  exit 66
fi
if [[ ! -f "$extension_root/package-lock.json" ]]; then
  echo "ERROR: Safari extension lockfile is missing at $extension_root/package-lock.json; deterministic npm ci is required." >&2
  exit 66
fi

echo "==> Installing locked Safari extension dependencies"
npm ci --prefix "$extension_root"

echo "==> Running the canonical Safari extension CI suite"
npm run test:ci --prefix "$extension_root"

echo "==> Verifying deterministic Safari certification fixtures"
node "$repo_root/tools/safari-certification-fixtures/verify.mjs"
node --test "$repo_root"/tools/safari-certification-fixtures/*.test.mjs

echo "PASS: OpenBurnBar Safari extension CI suite"
