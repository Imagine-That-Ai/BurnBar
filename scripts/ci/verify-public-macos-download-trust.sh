#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
site_config="$repo_root/website/src/data/site.ts"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "::error::Public macOS download trust verification must run on macOS." >&2
  exit 78
fi

if [[ ! -f "$site_config" ]]; then
  echo "::error::SITE config not found at $site_config" >&2
  exit 66
fi

site_metadata="$(
  node --input-type=module - "$site_config" <<'NODE'
import { readFileSync } from "node:fs";

const siteConfig = process.argv[2];
const text = readFileSync(siteConfig, "utf8");

function stringField(name) {
  const match = text.match(new RegExp(`${name}:\\s*"([^"]*)"`));
  if (!match) {
    throw new Error(`SITE.${name} was not found`);
  }
  return match[1];
}

const base = stringField("macDownloadBaseUrl").replace(/\/+$/, "");
const file = stringField("macReleaseFile");
const expectedVersion = stringField("macReleaseLatest");
if (!base) {
  throw new Error("SITE.macDownloadBaseUrl must be an https URL for public trust verification");
}
if (!expectedVersion) {
  throw new Error("SITE.macReleaseLatest must be non-empty for public trust verification");
}
if (!file.includes(expectedVersion)) {
  throw new Error(`SITE.macReleaseFile (${file}) must include SITE.macReleaseLatest (${expectedVersion})`);
}

const url = new URL(`${base}/${file}`);
if (url.protocol !== "https:") {
  throw new Error(`Public macOS download must use https, got ${url.protocol}`);
}
if (!url.pathname.endsWith(".dmg")) {
  throw new Error(`Public macOS download must point at a DMG, got ${url.href}`);
}

console.log(url.href);
console.log(expectedVersion);
console.log(file);
NODE
)"
download_url="$(printf '%s\n' "$site_metadata" | sed -n '1p')"
expected_version="$(printf '%s\n' "$site_metadata" | sed -n '2p')"
mac_release_file="$(printf '%s\n' "$site_metadata" | sed -n '3p')"

expected_team_id="${OPENBURNBAR_EXPECTED_APPLE_TEAM_ID:-}"
if [[ -z "$expected_team_id" ]]; then
  expected_team_id="$(
    sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM:[[:space:]]*//p' "$repo_root/project.yml" \
      | sed -n '1p' \
      | tr -d '"[:space:]'
  )"
fi
if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "::error::Expected Apple team id is missing or invalid. Set OPENBURNBAR_EXPECTED_APPLE_TEAM_ID or project.yml DEVELOPMENT_TEAM." >&2
  exit 66
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-public-mac-trust.XXXXXX")"
dmg_path="$tmpdir/OpenBurnBar-public-macOS.dmg"
mountpoint="$tmpdir/mount"
mounted=0

cleanup() {
  if [[ "$mounted" == "1" ]]; then
    hdiutil detach "$mountpoint" -quiet -force >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

run_gate() {
  local label="$1"
  shift

  echo "==> $label"
  "$@"
}

fail_gate() {
  local label="$1"
  shift

  echo "==> $label"
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    printf '%s\n' "$output"
    return 0
  fi

  echo "::error::$label failed for $download_url" >&2
  printf '%s\n' "$output" >&2
  return "$status"
}

echo "Downloading public macOS DMG: $download_url"
curl --fail --location --show-error --silent \
  --retry 3 \
  --connect-timeout 15 \
  --max-time 300 \
  --proto '=https' \
  --tlsv1.2 \
  --output "$dmg_path" \
  "$download_url"

if [[ ! -s "$dmg_path" ]]; then
  echo "::error::Downloaded DMG is empty: $download_url" >&2
  exit 1
fi

fail_gate "Gatekeeper DMG assessment" \
  spctl -a -vv -t open --context context:primary-signature "$dmg_path"
fail_gate "DMG notarization staple validation" \
  xcrun stapler validate "$dmg_path"

mkdir -p "$mountpoint"
run_gate "Mount DMG read-only" \
  hdiutil attach "$dmg_path" -mountpoint "$mountpoint" -nobrowse -readonly -quiet
mounted=1

app_path="$(find "$mountpoint" -maxdepth 1 -type d -name "*.app" -print -quit)"
if [[ -z "$app_path" ]]; then
  echo "::error::Mounted public DMG does not contain a top-level .app bundle." >&2
  exit 1
fi

info_plist="$app_path/Contents/Info.plist"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true)"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null || true)"
if [[ "$app_version" != "$expected_version" ]]; then
  echo "::error::Public DMG app version ($app_version build $app_build) does not match SITE.macReleaseLatest ($expected_version) for $mac_release_file." >&2
  exit 1
fi

fail_gate "App bundle code signature verification" \
  codesign --verify --deep --strict --verbose=4 "$app_path"

bash "$repo_root/scripts/ci/verify-apple-release-firebase-config.sh" "$app_path"
bash "$repo_root/scripts/ci/verify-apple-appcheck-release-artifact.sh" "$app_path"

signature="$(
  codesign -dv --verbose=4 "$app_path" 2>&1 || true
)"
if ! grep -q "Authority=Developer ID Application" <<<"$signature"; then
  echo "::error::App bundle is not signed with a Developer ID Application certificate." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if grep -q "Signature=adhoc" <<<"$signature"; then
  echo "::error::App bundle is ad-hoc signed, not Developer ID signed." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if ! grep -q "TeamIdentifier=$expected_team_id" <<<"$signature"; then
  echo "::error::App bundle is not signed by expected Apple team $expected_team_id." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi

fail_gate "Gatekeeper app execution assessment" \
  spctl -a -vv --type execute "$app_path"

echo "PASS: public macOS download is Developer ID signed by team $expected_team_id, version $expected_version, notarized, stapled, Firebase-configured, App-Check-clean, and Gatekeeper accepted."
