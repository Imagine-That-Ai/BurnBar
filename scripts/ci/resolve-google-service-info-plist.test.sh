#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
resolver="scripts/ci/resolve-google-service-info-plist.sh"
chmod +x "$resolver"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

write_plist() {
  local path="$1"
  local reversed="$2"
  local app_id="$3"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>GOOGLE_APP_ID</key>
	<string>${app_id}</string>
	<key>REVERSED_CLIENT_ID</key>
	<string>${reversed}</string>
</dict>
</plist>
PLIST
}

pass() {
  echo "ok - $1"
}

fail() {
  echo "not ok - $1" >&2
  exit 1
}

preferred="$tmpdir/checkout/GoogleService-Info.plist"
cache="$tmpdir/home/.openburnbar/GoogleService-Info.plist"
override="$tmpdir/override.plist"
write_plist "$preferred" "com.googleusercontent.apps.preferred" "1:1:ios:preferred"
write_plist "$cache" "com.googleusercontent.apps.cache" "1:1:ios:cache"
write_plist "$override" "com.googleusercontent.apps.override" "1:1:ios:override"
write_plist "$tmpdir/example.plist" "com.googleusercontent.apps.YOUR_CLIENT_ID_SUFFIX" "YOUR_GOOGLE_APP_ID"

HOME="$tmpdir/home"
export HOME
unset CI GITHUB_ACTIONS OPENBURNBAR_GOOGLE_SERVICE_INFO_PLIST

got="$("$resolver" "$preferred")"
[[ "$got" == "$preferred" ]] || fail "preferred checkout path should win, got $got"
pass "preferred checkout path wins"

got="$("$resolver" "$tmpdir/missing.plist")"
[[ "$got" == "$cache" ]] || fail "home cache should win when checkout is missing, got $got"
pass "home cache used when checkout is missing"

export OPENBURNBAR_GOOGLE_SERVICE_INFO_PLIST="$override"
got="$("$resolver" "$tmpdir/missing.plist")"
[[ "$got" == "$override" ]] || fail "explicit override should win over home cache, got $got"
pass "explicit override wins over home cache"
unset OPENBURNBAR_GOOGLE_SERVICE_INFO_PLIST

got="$("$resolver" "$tmpdir/example.plist")"
[[ "$got" == "$cache" ]] || fail "placeholder preferred path should fall through to cache, got $got"
pass "placeholder plist falls through to cache"

empty_home="$tmpdir/empty-home"
mkdir -p "$empty_home"
HOME="$empty_home"
if "$resolver" "$tmpdir/example.plist" >/dev/null; then
  fail "placeholder example plist should be rejected when no usable fallback exists"
fi
pass "placeholder plist is rejected without a fallback"
HOME="$tmpdir/home"

export CI=true
if "$resolver" "$tmpdir/missing.plist" >/dev/null; then
  fail "CI should not read the home-directory cache"
fi
pass "CI ignores the home-directory cache"
unset CI

export GITHUB_ACTIONS=true
if "$resolver" "$tmpdir/missing.plist" >/dev/null; then
  fail "GITHUB_ACTIONS should not read the home-directory cache"
fi
pass "GITHUB_ACTIONS ignores the home-directory cache"

echo "All resolve-google-service-info-plist checks passed."
