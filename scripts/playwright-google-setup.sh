#!/usr/bin/env bash
# Opens official Firebase/Google setup pages in a Playwright session (CLI-first).
# Requires: npx (Node). Uses Codex playwright wrapper if present.
#
# Usage:
#   ./scripts/playwright-google-setup.sh           # headless (good for doc screenshots)
#   ./scripts/playwright-google-setup.sh --headed  # visible browser (sign in to Firebase / GCP)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/output/playwright/google-setup"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PWCLI="${PWCLI:-$CODEX_HOME/skills/playwright/scripts/playwright_cli.sh}"

HEADED_ARGS=()
if [[ "${1:-}" == "--headed" ]]; then
  HEADED_ARGS=(--headed)
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required. Install Node.js/npm (NodeSource, nvm, or brew install node)." >&2
  exit 1
fi

if [[ ! -x "$PWCLI" ]] && [[ ! -f "$PWCLI" ]]; then
  echo "Playwright wrapper not found at: $PWCLI" >&2
  echo "Set PWCLI to your playwright_cli.sh path, or install the Codex playwright skill." >&2
  exit 1
fi

mkdir -p "$OUT"
cd "$OUT"

SESSION="${PLAYWRIGHT_CLI_SESSION:-agentlens-google}"

"$PWCLI" --session "$SESSION" open "${HEADED_ARGS[@]}" "https://firebase.google.com/docs/auth/ios/google-signin"
"$PWCLI" --session "$SESSION" snapshot | tee snapshot-firebase-docs.txt
"$PWCLI" --session "$SESSION" screenshot --filename firebase-docs-google-signin-apple.png --full-page true

"$PWCLI" --session "$SESSION" open "${HEADED_ARGS[@]}" "https://console.firebase.google.com/project/_/authentication/providers"
"$PWCLI" --session "$SESSION" snapshot | tee snapshot-firebase-console-auth.txt
"$PWCLI" --session "$SESSION" screenshot --filename firebase-console-auth-providers.png --full-page true

"$PWCLI" --session "$SESSION" open "${HEADED_ARGS[@]}" "https://console.cloud.google.com/apis/credentials"
"$PWCLI" --session "$SESSION" snapshot | tee snapshot-google-cloud-credentials.txt
"$PWCLI" --session "$SESSION" screenshot --filename google-cloud-credentials.png --full-page true

echo ""
echo "Done. See: $OUT/CHECKLIST.txt"
echo "Sign in in the browser window if you need to change Firebase/Google settings."
