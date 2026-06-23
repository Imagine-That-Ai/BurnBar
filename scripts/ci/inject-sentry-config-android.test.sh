#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

valid_dsn='https://public@example.ingest.sentry.io/12345?note=quote%27and%5Cnnewline&marker=$&replacement=%24%7Bnot_code%7D'
envfile="$TMPDIR/github-env"

ANDROID_SENTRY_DSN="$valid_dsn" \
  GITHUB_ENV="$envfile" \
  bash "$ROOT/scripts/ci/inject-sentry-config-android.sh" >"$TMPDIR/android.out"

python3 - "$envfile" "$valid_dsn" <<'PY'
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
expected = sys.argv[2]
if len(lines) != 3:
    raise SystemExit(f"expected multiline GitHub env record, got: {lines!r}")
prefix = "OPENBURNBAR_ANDROID_SENTRY_DSN<<"
if not lines[0].startswith(prefix):
    raise SystemExit(f"missing multiline env header: {lines!r}")
delimiter = lines[0][len(prefix):]
if lines[1] != expected:
    raise SystemExit("DSN did not round-trip in GitHub env payload")
if lines[2] != delimiter:
    raise SystemExit("GitHub env delimiter mismatch")
PY

empty_env="$TMPDIR/github-env-empty"
ANDROID_SENTRY_DSN="" \
  GITHUB_ENV="$empty_env" \
  bash "$ROOT/scripts/ci/inject-sentry-config-android.sh" >"$TMPDIR/android-empty.out"
if ! grep -qx 'OPENBURNBAR_ANDROID_SENTRY_DSN=' "$empty_env"; then
  echo "expected empty Android DSN to export an empty value" >&2
  cat "$empty_env" >&2
  exit 1
fi

if ANDROID_SENTRY_DSN='http://public@example.ingest.sentry.io/12345' \
  GITHUB_ENV="$TMPDIR/github-env-invalid-http" \
  bash "$ROOT/scripts/ci/inject-sentry-config-android.sh" >/dev/null 2>&1; then
  echo "expected non-https Android DSN to be rejected" >&2
  exit 1
fi

if ANDROID_SENTRY_DSN=$'https://public@example.ingest.sentry.io/12345\nINJECTED=1' \
  GITHUB_ENV="$TMPDIR/github-env-invalid-newline" \
  bash "$ROOT/scripts/ci/inject-sentry-config-android.sh" >/dev/null 2>&1; then
  echo "expected control-character Android DSN to be rejected" >&2
  exit 1
fi

echo "inject-sentry-config-android tests passed"
