#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-appcast-rollback-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

write_feed() {
  local path="$1"
  local latest_pub="$2"
  local target_pub="$3"
  local old_pub="$4"

  cat >"${path}" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenBurnBar Test Feed</title>
    <item>
      <title>OpenBurnBar 1.0.2</title>
      <sparkle:shortVersionString>1.0.2</sparkle:shortVersionString>
      <sparkle:version>102</sparkle:version>
      <pubDate>${latest_pub}</pubDate>
      <enclosure url="https://example.test/OpenBurnBar-1.0.2.dmg" sparkle:edSignature="bad-build-signature" />
    </item>
    <item>
      <title>OpenBurnBar 1.0.1</title>
      <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
      <sparkle:version>101</sparkle:version>
      <pubDate>${target_pub}</pubDate>
      <enclosure url="https://example.test/OpenBurnBar-1.0.1.dmg" sparkle:edSignature="known-good-signature" />
    </item>
    <item>
      <title>OpenBurnBar 1.0.0</title>
      <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
      <sparkle:version>100</sparkle:version>
      <pubDate>${old_pub}</pubDate>
      <enclosure url="https://example.test/OpenBurnBar-1.0.0.dmg" sparkle:edSignature="older-signature" />
    </item>
  </channel>
</rss>
XML
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "${needle}" "${file}"; then
    echo "FAIL: expected ${file} to contain ${needle}" >&2
    cat "${file}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq "${needle}" "${file}"; then
    echo "FAIL: expected ${file} not to contain ${needle}" >&2
    cat "${file}" >&2
    exit 1
  fi
}

assert_order() {
  local file="$1"
  local first="$2"
  local second="$3"
  python3 - "$file" "$first" "$second" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
left = text.find(sys.argv[2])
right = text.find(sys.argv[3])
if left == -1 or right == -1 or left >= right:
    sys.stderr.write(f"FAIL: expected {sys.argv[2]!r} before {sys.argv[3]!r} in {sys.argv[1]}\n")
    sys.exit(1)
PY
}

run_appcast_rollback() {
  bash scripts/ops/rollback-macos-appcast.sh "$@"
}

rfc822_days_ago() {
  python3 - "$1" <<'PY'
import sys
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime

days = int(sys.argv[1])
dt = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(days=days)
print(format_datetime(dt, usegmt=True))
PY
}

recent_latest="$(rfc822_days_ago 0)"
recent_target="$(rfc822_days_ago 1)"
old_target="Sat, 01 Jan 2000 12:00:00 +0000"
recent_old="$(rfc822_days_ago 2)"

downloads="${TMP_DIR}/downloads"
mkdir -p "${downloads}"
arm_feed="${downloads}/appcast.xml"
write_feed "${arm_feed}" "${recent_latest}" "${recent_target}" "${recent_old}"

cp "${arm_feed}" "${TMP_DIR}/arm.before"

if OPENBURNBAR_DOWNLOADS_DIR="${downloads}" run_appcast_rollback --dry-run >"${TMP_DIR}/missing-target.out" 2>"${TMP_DIR}/missing-target.err"; then
  echo "FAIL: rollback accepted a missing --to-version" >&2
  exit 1
fi
assert_contains "${TMP_DIR}/missing-target.err" "this script refuses to guess a target"

if OPENBURNBAR_DOWNLOADS_DIR="${downloads}" run_appcast_rollback --to-version 2026.6.5 >"${TMP_DIR}/calver.out" 2>"${TMP_DIR}/calver.err"; then
  echo "FAIL: rollback accepted a year-shaped version target" >&2
  exit 1
fi
assert_contains "${TMP_DIR}/calver.err" "is not a valid SemVer version"

OPENBURNBAR_DOWNLOADS_DIR="${downloads}" run_appcast_rollback --list >"${TMP_DIR}/list.out"
assert_contains "${TMP_DIR}/list.out" "1.0.2"
assert_contains "${TMP_DIR}/list.out" "<- latest"

OPENBURNBAR_DOWNLOADS_DIR="${downloads}" run_appcast_rollback --to-version 1.0.1 >"${TMP_DIR}/dry-run.out"
assert_contains "${TMP_DIR}/dry-run.out" "DRY RUN: no feed modified"
assert_contains "${TMP_DIR}/dry-run.out" "drop:    1.0.2"
cmp -s "${arm_feed}" "${TMP_DIR}/arm.before" || {
  echo "FAIL: dry-run modified the appcast" >&2
  exit 1
}

OPENBURNBAR_DOWNLOADS_DIR="${downloads}" \
OPENBURNBAR_R2_PUBLIC_BASE_URL="https://downloads.example.test/openburnbar" \
  run_appcast_rollback --to-version 1.0.1 --yes >"${TMP_DIR}/apply.out"
assert_contains "${TMP_DIR}/apply.out" "Pinned latest: 1.0.1"
assert_contains "${TMP_DIR}/apply.out" "scripts/publish-macos-appcast-rollback-r2.sh"
assert_contains "${TMP_DIR}/apply.out" "OPENBURNBAR_ROLLBACK_CONFIRM=publish-appcast-rollback"
assert_contains "${TMP_DIR}/apply.out" "OPENBURNBAR_EXPECTED_LIVE_VERSION=<bad-live-version>"
assert_contains "${TMP_DIR}/apply.out" "https://downloads.example.test/openburnbar/appcast.xml"
assert_not_contains "${arm_feed}" "1.0.2"
assert_contains "${arm_feed}" "known-good-signature"
assert_contains "${arm_feed}" "1.0.0"
assert_order "${arm_feed}" "1.0.1" "1.0.0"

stale_feed="${TMP_DIR}/stale-appcast.xml"
write_feed "${stale_feed}" "${recent_latest}" "${old_target}" "${recent_old}"
if STALE_VERSION_MAX_AGE_DAYS=1 run_appcast_rollback --feed "${stale_feed}" --to-version 1.0.1 >"${TMP_DIR}/stale.out" 2>"${TMP_DIR}/stale.err"; then
  echo "FAIL: stale appcast rollback target was accepted without --allow-stale" >&2
  exit 1
fi
assert_contains "${TMP_DIR}/stale.err" "freshness window"
assert_contains "${stale_feed}" "1.0.2"

STALE_VERSION_MAX_AGE_DAYS=1 run_appcast_rollback --feed "${stale_feed}" --to-version 1.0.1 --allow-stale >"${TMP_DIR}/allow-stale.out"
assert_contains "${TMP_DIR}/allow-stale.out" "DRY RUN: no feed modified"

echo "macOS appcast rollback test: all green"
