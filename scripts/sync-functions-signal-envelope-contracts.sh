#!/usr/bin/env bash
# Keep the Cloud Functions deploy-local copy of the Signal envelope contracts in sync.
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-sync}"
SOURCE="packages/signal-envelope-contracts"
TARGET="functions/vendor/signal-envelope-contracts"

if [[ "$MODE" != "sync" && "$MODE" != "--check" ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi

if [[ ! -x "$SOURCE/node_modules/.bin/tsc" ]]; then
  npm ci --prefix "$SOURCE"
fi
npm run build --prefix "$SOURCE"

sync_package() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest"
  rsync -a \
    --exclude node_modules \
    --exclude package-lock.json \
    --exclude '*.tsbuildinfo' \
    "$SOURCE/" "$dest/"
}

if [[ "$MODE" == "--check" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  sync_package "$tmp/signal-envelope-contracts"
  if ! diff -ru "$tmp/signal-envelope-contracts" "$TARGET" >/tmp/functions-signal-envelope-contracts.diff; then
    echo "ERROR: $TARGET is out of sync with $SOURCE." >&2
    echo "Run: scripts/sync-functions-signal-envelope-contracts.sh" >&2
    sed -n '1,120p' /tmp/functions-signal-envelope-contracts.diff >&2
    exit 1
  fi
  echo "PASS: $TARGET matches $SOURCE"
  exit 0
fi

sync_package "$TARGET"
echo "Synced $TARGET from $SOURCE"
