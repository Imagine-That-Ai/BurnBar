#!/usr/bin/env bash
# Verifies that the extension builds and tests pass from a clean install.
# Simulates what a first-time contributor or CI runner would experience.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
ext_dir="$repo_root/extensions/openburnbar"

echo "=== Clean-machine extension install verification ==="

# Check prerequisites
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not found. Install Node.js 18+ (see .nvmrc for pinned version)." >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "FAIL: npm not found." >&2
  exit 1
fi

node_version=$(node --version | sed 's/^v//' | cut -d. -f1)
if [[ "$node_version" -lt 18 ]]; then
  echo "FAIL: Node.js $node_version is too old. Requires 18+." >&2
  exit 1
fi

echo "Node: $(node --version)"
echo "npm:  $(npm --version)"

# Clean slate
echo ""
echo "--- Removing node_modules and dist (clean slate) ---"
rm -rf "$ext_dir/node_modules" "$ext_dir/dist"

# Deterministic install
echo ""
echo "--- npm ci (deterministic install from lockfile) ---"
npm ci --prefix "$ext_dir"

# Build
echo ""
echo "--- npm run build ---"
npm run --prefix "$ext_dir" build

# Verify dist output exists
if [[ ! -f "$ext_dir/dist/extension.js" ]]; then
  echo "FAIL: dist/extension.js not produced by build." >&2
  exit 1
fi

# Unit tests
echo ""
echo "--- npm run test:unit ---"
npm run --prefix "$ext_dir" test:unit

# Replay tests
echo ""
echo "--- npm run test:replay ---"
npm run --prefix "$ext_dir" test:replay

echo ""
echo "=== Clean-machine extension verification passed ==="
