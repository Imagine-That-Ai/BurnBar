#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

valid_dsn='https://public@example.ingest.sentry.io/12345?note=quote%27and%5Cnnewline&marker=$&replacement=%24%7Bnot_code%7D'

actual="$(TEST_SENTRY_DSN="$valid_dsn" python3 "$ROOT/scripts/ci/sentry_dsn.py" validate TEST_SENTRY_DSN)"
if [[ "$actual" != "$valid_dsn" ]]; then
  echo "expected DSN to round-trip through validator" >&2
  printf 'actual: %s\n' "$actual" >&2
  exit 1
fi

for invalid in \
  'http://public@example.ingest.sentry.io/12345' \
  'https://public:password@example.ingest.sentry.io/12345' \
  'https://public@example.ingest.sentry.io/not-numeric'; do
  if TEST_SENTRY_DSN="$invalid" python3 "$ROOT/scripts/ci/sentry_dsn.py" validate TEST_SENTRY_DSN >/dev/null 2>&1; then
    echo "expected invalid DSN to fail: $invalid" >&2
    exit 1
  fi
done

if TEST_SENTRY_DSN=$'https://public@example.ingest.sentry.io/12345\nINJECTED=1' \
  python3 "$ROOT/scripts/ci/sentry_dsn.py" validate TEST_SENTRY_DSN >/dev/null 2>&1; then
  echo "expected control-character DSN to fail" >&2
  exit 1
fi

plist="$TMPDIR/Info.plist"
python3 - "$plist" <<'PY'
import plistlib
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(plistlib.dumps({"CFBundleIdentifier": "test"}))
PY

TEST_SENTRY_DSN="$valid_dsn" \
  python3 "$ROOT/scripts/ci/sentry_dsn.py" plist-env TEST_SENTRY_DSN "$plist" >/dev/null

python3 - "$plist" "$valid_dsn" <<'PY'
import plistlib
import sys
from pathlib import Path

payload = plistlib.loads(Path(sys.argv[1]).read_bytes())
if payload.get("sentry.dsn") != sys.argv[2]:
    raise SystemExit("sentry.dsn did not round-trip as plist data")
PY

echo "sentry_dsn helper tests passed"
