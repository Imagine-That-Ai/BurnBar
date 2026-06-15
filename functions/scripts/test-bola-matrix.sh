#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BOLA_TESTS=()
while IFS= read -r file; do
  BOLA_TESTS+=("$file")
done < <(find src/__tests__/bola -name '*.bola.test.ts' | sort)
BOLA_TESTS+=("src/__tests__/bolaCoverage.test.ts")

npx vitest run "${BOLA_TESTS[@]}"