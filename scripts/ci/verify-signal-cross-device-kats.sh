#!/usr/bin/env bash
#
# Phase 2.5 — Node/Linux-enforceable legs of the cross-device + bidirectional E2EE correctness
# proof. The native cross-device OPEN runs in the Swift/Kotlin platform suites (the macOS PR
# harness + Android unit tests, a different lane); this script pins the fixtures + structural KATs
# they consume so a silent drift fails CI. Self-bootstraps so it is runnable both locally
# (`make signal-cross-device-kats`) and from CI.
#
# Legs:
#   G1  reverse-direction interop fixture: 3 byte-identical copies + structure (Swift+Android open it)
#   G6  + at-rest: crypto-proof harness — bindingToAAD A/A2 (incl. transport), HPKE B, recognizer C,
#       cross-language fixture pins D (incl. the Swift transport AAD copy)
#   contract directory cases: signal-envelope-contracts node --test suite
set -euo pipefail

cd "$(dirname "$0")/../.."

ci_if_missing() {
  local pkg="$1"
  if [[ ! -x "$pkg/node_modules/.bin/tsc" ]]; then
    echo "==> npm ci --prefix $pkg"
    npm ci --prefix "$pkg"
  fi
}

# The harness builds signal-envelope-contracts + libsignal-protocol from source; libsignal-protocol's
# tsc resolves @openburnbar/libsignal-bridge, so the bridge must be installed + built first.
ci_if_missing packages/libsignal-bridge
ci_if_missing packages/signal-envelope-contracts
ci_if_missing packages/libsignal-protocol
echo "==> npm run build --prefix packages/libsignal-bridge"
npm run build --prefix packages/libsignal-bridge >/dev/null

echo "==> [G1] reverse-direction interop fixture: presence + byte-identity + structure"
node scripts/ci/check-reverse-interop-fixture.mjs

echo "==> [G6 + at-rest] crypto-proof harness (bindingToAAD A/A2, HPKE B, recognizer C, fixture pins D)"
node scripts/ci/crypto-proof-harness.mjs

echo "==> [contracts] signal-envelope-contracts directory cases"
npm test --prefix packages/signal-envelope-contracts

echo "✓ signal cross-device KATs passed"
