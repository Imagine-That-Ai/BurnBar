#!/usr/bin/env bash
# Thin wrapper so CI / agents can call the Windows parity ledger gate like other
# scripts/ci honesty gates (see verify-windows-storage-architecture.sh).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

exec python3 scripts/ci/verify-windows-parity-ledger.py "$@"
