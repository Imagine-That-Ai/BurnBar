#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -x "$ROOT_DIR/functions/node_modules/.bin/firebase" ]]; then
  npm ci --prefix functions
fi

if [[ ! -d "$ROOT_DIR/firestore-rules-tests/node_modules" ]]; then
  npm ci --prefix firestore-rules-tests
fi

export PATH="$ROOT_DIR/functions/node_modules/.bin:$PATH"
npm --prefix firestore-rules-tests run test:storage-rules
