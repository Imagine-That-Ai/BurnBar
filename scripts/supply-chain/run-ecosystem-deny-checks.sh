#!/usr/bin/env bash
# Per-ecosystem dependency deny / audit checks (WS5).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
failed=0

echo "=== Ecosystem deny checks ==="

if command -v cargo-deny >/dev/null 2>&1; then
  echo ">> cargo-deny (crates/openburnbar-iroh)"
  if ! (cd "$repo_root/crates/openburnbar-iroh" && cargo deny check); then
    echo "::error::cargo-deny failed" >&2
    failed=1
  fi
else
  echo "cargo-deny not installed — skipping Rust deny (install: cargo install cargo-deny)"
fi

echo ">> npm audit (functions + extension)"
if ! "$repo_root/scripts/supply-chain-audit.sh"; then
  failed=1
fi

if command -v osv-scanner >/dev/null 2>&1; then
  echo ">> OSV-Scanner lockfiles"
  if ! osv-scanner \
    --lockfile="$repo_root/functions/package-lock.json" \
    --lockfile="$repo_root/extensions/openburnbar/package-lock.json"; then
    failed=1
  fi
else
  echo "OSV-Scanner not installed — covered in security-pr.yml on GitHub runners"
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "=== Ecosystem deny checks passed ==="
