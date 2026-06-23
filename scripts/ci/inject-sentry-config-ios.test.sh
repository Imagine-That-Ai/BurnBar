#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

tmpdir="$(mktemp -d)"
restore_paths=(
  "AgentLens/Resources/OpenBurnBar-Info.plist"
  "OpenBurnBarMobile/Info.plist"
  "AgentLens/Resources/GoogleService-Info.plist"
  "OpenBurnBarMobile/Resources/GoogleService-Info.plist"
)

cleanup() {
  for rel in "${restore_paths[@]}"; do
    rm -f "$rel"
    backup="$tmpdir/backup/${rel}"
    if [[ -f "$backup" ]]; then
      mkdir -p "$(dirname "$rel")"
      mv "$backup" "$rel"
    fi
  done
  rm -rf "$tmpdir"
}
trap cleanup EXIT

for rel in "${restore_paths[@]}"; do
  if [[ -f "$rel" ]]; then
    mkdir -p "$tmpdir/backup/$(dirname "$rel")"
    cp "$rel" "$tmpdir/backup/$rel"
  fi
  mkdir -p "$(dirname "$rel")"
  python3 - "$rel" <<'PY'
import plistlib
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(plistlib.dumps({"CFBundleIdentifier": "test"}))
PY
done

valid_dsn='https://public@example.ingest.sentry.io/12345?note=quote%27and%5Cnnewline&marker=$&replacement=%24%7Bnot_code%7D'

OPENBURNBAR_SENTRY_DSN="$valid_dsn" \
  bash scripts/ci/inject-sentry-config-ios.sh >"$tmpdir/inject-ios.out"

python3 - "$valid_dsn" <<'PY'
import plistlib
import sys
from pathlib import Path

expected = sys.argv[1]
for rel in (
    "AgentLens/Resources/OpenBurnBar-Info.plist",
    "OpenBurnBarMobile/Info.plist",
    "AgentLens/Resources/GoogleService-Info.plist",
    "OpenBurnBarMobile/Resources/GoogleService-Info.plist",
):
    payload = plistlib.loads(Path(rel).read_bytes())
    if payload.get("sentry.dsn") != expected:
        raise SystemExit(f"{rel} sentry.dsn mismatch: {payload.get('sentry.dsn')!r}")
PY

if OPENBURNBAR_SENTRY_DSN='https://public:password@example.ingest.sentry.io/12345' \
  bash scripts/ci/inject-sentry-config-ios.sh >/dev/null 2>&1; then
  echo "expected password-bearing iOS DSN to be rejected" >&2
  exit 1
fi

if OPENBURNBAR_SENTRY_DSN=$'https://public@example.ingest.sentry.io/12345\nINJECTED=1' \
  bash scripts/ci/inject-sentry-config-ios.sh >/dev/null 2>&1; then
  echo "expected control-character iOS DSN to be rejected" >&2
  exit 1
fi

echo "inject-sentry-config-ios tests passed"
