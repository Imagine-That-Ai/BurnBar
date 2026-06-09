#!/usr/bin/env bash
# Supply chain audit for OpenBurnBar — npm audit + optional OSV-Scanner.
#
# Usage:
#   ./scripts/supply-chain-audit.sh
#
# Fails on high/critical npm audit findings in functions/ and extensions/openburnbar.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
failed=0

echo "=== Known vulnerable dependency floors ==="
if ! node "$repo_root/scripts/security/check-known-vulnerability-floors.mjs"; then
    failed=1
fi

audit_npm() {
    local dir="$1"
    local label="$2"
    echo "=== npm audit: $label ($dir) ==="
    if [[ ! -f "$dir/package-lock.json" && ! -f "$dir/package.json" ]]; then
        echo "Skipping — no package.json"
        return 0
    fi
    if ! npm --prefix "$dir" audit --audit-level=high 2>&1; then
        echo "::error::npm audit failed for $label" >&2
        failed=1
    fi
}

audit_npm "$repo_root/functions" "Cloud Functions"
audit_npm "$repo_root/extensions/openburnbar" "VS Code extension"

if command -v osv-scanner >/dev/null 2>&1; then
    echo "=== OSV-Scanner ==="
    if ! osv-scanner --lockfile="$repo_root/functions/package-lock.json" --lockfile="$repo_root/extensions/openburnbar/package-lock.json"; then
        failed=1
    fi
else
    echo "OSV-Scanner not installed — skipping (install via: brew install osv-scanner)"
fi

if [[ "$failed" -ne 0 ]]; then
    exit 1
fi

echo "=== Supply chain audit passed ==="
