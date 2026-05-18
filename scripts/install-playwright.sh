#!/bin/zsh
# scripts/install-playwright.sh
# Reproducible Playwright install used by OpenBurnBarPlaywrightLifecycle.
# Phase 9 of plans/2026-05-16-computer-use-master-plan.md.
#
# Pinned to playwright@1.49.x. Bumping requires updating
# OpenBurnBarPlaywrightLifecycle.pinnedPlaywrightVersion in sync.
#
# Idempotent: re-runs are no-ops once installation succeeds.

set -euo pipefail

PLAYWRIGHT_PIN="1.49.1"

if ! command -v node >/dev/null 2>&1; then
  echo "node not found on PATH. Install Node 20+ (brew install node) before running this script." >&2
  exit 2
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "npm not found on PATH." >&2
  exit 2
fi

CURRENT_VERSION=$(npm list -g --depth=0 playwright --json 2>/dev/null \
  | node -e 'try{const j=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(j.dependencies?.playwright?.version||"")}catch(e){}' \
  || true)

if [[ "$CURRENT_VERSION" == "$PLAYWRIGHT_PIN"* ]]; then
  echo "playwright $CURRENT_VERSION already installed; skipping install"
else
  echo "Installing playwright@$PLAYWRIGHT_PIN globally"
  npm install -g playwright@"$PLAYWRIGHT_PIN"
fi

echo "Installing Chromium browser binary"
playwright install chromium --with-deps

echo "Playwright bridge ready. Bridge script:" >&2
echo "  OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js" >&2
