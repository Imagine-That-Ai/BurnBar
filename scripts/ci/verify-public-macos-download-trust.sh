#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
site_config="${1:-$repo_root/website/src/data/site.ts}"

if [[ ! -f "$site_config" ]]; then
  echo "::error::SITE config not found at $site_config" >&2
  exit 66
fi

read_site_metadata() {
  OPENBURNBAR_REPO_ROOT="$repo_root" node --input-type=module - "$site_config" <<'NODE'
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const siteConfig = process.argv[2];
const source = readFileSync(siteConfig, "utf8");
const require = createRequire(import.meta.url);
const repoRoot = process.env.OPENBURNBAR_REPO_ROOT;
if (!repoRoot) {
  throw new Error("OPENBURNBAR_REPO_ROOT must be set by the verifier wrapper");
}
const ts = require(resolve(repoRoot, "website/node_modules/typescript"));
const sourceFile = ts.createSourceFile(siteConfig, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);

function unwrapExpression(expression) {
  let current = expression;
  while (
    ts.isAsExpression(current) ||
    ts.isTypeAssertionExpression(current) ||
    ts.isSatisfiesExpression(current) ||
    ts.isParenthesizedExpression(current)
  ) {
    current = current.expression;
  }
  return current;
}

function exportedSiteObject() {
  for (const statement of sourceFile.statements) {
    if (!ts.isVariableStatement(statement)) {
      continue;
    }
    const isExported = statement.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword);
    if (!isExported) {
      continue;
    }
    for (const declaration of statement.declarationList.declarations) {
      if (declaration.name.getText(sourceFile) !== "SITE" || !declaration.initializer) {
        continue;
      }
      const initializer = unwrapExpression(declaration.initializer);
      if (!ts.isObjectLiteralExpression(initializer)) {
        throw new Error("website/src/data/site.ts must export SITE as a declarative object literal");
      }
      return initializer;
    }
  }
  throw new Error("website/src/data/site.ts must export a declarative SITE object");
}

const siteObject = exportedSiteObject();

function propertyNameText(name) {
  if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)) {
    return name.text;
  }
  return undefined;
}

function stringField(name) {
  const property = siteObject.properties.find(
    (entry) => ts.isPropertyAssignment(entry) && propertyNameText(entry.name) === name,
  );
  if (!property) {
    throw new Error(`SITE.${name} must be a literal string`);
  }
  const value = unwrapExpression(property.initializer);
  if (!ts.isStringLiteral(value) && !ts.isNoSubstitutionTemplateLiteral(value)) {
    throw new Error(`SITE.${name} must be a literal string`);
  }
  return value.text;
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
}

if [[ "${OPENBURNBAR_PRINT_PUBLIC_MACOS_DOWNLOAD_METADATA:-}" == "1" ]]; then
  read_site_metadata
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "::error::Public macOS download trust verification must run on macOS." >&2
  exit 78
fi

site_metadata="$(read_site_metadata)"
download_url="$(printf '%s\n' "$site_metadata" | sed -n '1p')"
expected_version="$(printf '%s\n' "$site_metadata" | sed -n '2p')"
mac_release_file="$(printf '%s\n' "$site_metadata" | sed -n '3p')"
# SemVer build metadata identifies the immutable release tag, but Apple does
# not permit '+' metadata in CFBundleShortVersionString.  Compare the mounted
# app against the Apple-visible base version while keeping the full tagged
# version bound in the public feed and asset names.
apple_expected_version="${expected_version%%+*}"

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

download_sha256="$(shasum -a 256 "$dmg_path" | awk '{print toupper($1)}')"
if [[ ! "$download_sha256" =~ ^[0-9A-F]{64}$ ]]; then
  echo "::error::Unable to calculate a valid SHA-256 digest for $download_url." >&2
  exit 1
fi
echo "Downloaded public macOS DMG SHA256=$download_sha256"

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
if [[ "$app_version" != "$apple_expected_version" ]]; then
  echo "::error::Public DMG app version ($app_version build $app_build) does not match Apple-visible release version ($apple_expected_version) derived from SITE.macReleaseLatest ($expected_version) for $mac_release_file." >&2
  exit 1
fi

fail_gate "App bundle code signature verification" \
  codesign --verify --deep --strict --verbose=4 "$app_path"

bash "$repo_root/scripts/ci/verify-apple-release-firebase-config.sh" "$app_path"
bash "$repo_root/scripts/ci/verify-apple-appcheck-release-artifact.sh" "$app_path"

entitlements_plist="$tmpdir/app-entitlements.plist"
codesign -d --entitlements :- "$app_path" > "$entitlements_plist" 2>/dev/null
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
expected_app_identifier="${expected_team_id}.${bundle_id}"
actual_app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$entitlements_plist" 2>/dev/null || true)"
actual_team_identifier="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$entitlements_plist" 2>/dev/null || true)"
actual_keychain_groups="$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$entitlements_plist" 2>/dev/null || true)"
if [[ "$actual_app_identifier" != "$expected_app_identifier" || "$actual_team_identifier" != "$expected_team_id" ]]; then
  echo "::error::Public app identity entitlements are wrong: app='${actual_app_identifier:-missing}' team='${actual_team_identifier:-missing}' expected app='$expected_app_identifier' team='$expected_team_id'." >&2
  exit 1
fi
if ! grep -q "$expected_app_identifier" <<<"$actual_keychain_groups"; then
  echo "::error::Public app is missing Firebase Auth Keychain group $expected_app_identifier." >&2
  printf '%s\n' "$actual_keychain_groups" >&2
  exit 1
fi

daemon_path="$app_path/Contents/Helpers/OpenBurnBarDaemon"
if [[ ! -x "$daemon_path" ]]; then
  echo "::error::Public app is missing the OpenBurnBarDaemon helper." >&2
  exit 1
fi
bash "$repo_root/scripts/ci/verify-daemon-release-signing.sh" "$app_path" "$expected_team_id"

embedded_profile="$app_path/Contents/embedded.provisionprofile"
if [[ ! -f "$embedded_profile" ]]; then
  echo "::error::Public app is missing embedded MAC_APP_DIRECT provisioning profile." >&2
  exit 1
fi
embedded_profile_plist="$tmpdir/embedded-profile.plist"
security cms -D -i "$embedded_profile" > "$embedded_profile_plist"
profile_all_devices="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$embedded_profile_plist" 2>/dev/null || true)"
profile_app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$embedded_profile_plist" 2>/dev/null || true)"
profile_keychain_groups="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups' "$embedded_profile_plist" 2>/dev/null || true)"
if [[ "$profile_all_devices" != "true" || "$profile_app_identifier" != "$expected_app_identifier" ]]; then
  echo "::error::Embedded profile must be all-devices and authorize $expected_app_identifier; found allDevices='${profile_all_devices:-missing}' app='${profile_app_identifier:-missing}'." >&2
  exit 1
fi
if ! grep -q "${expected_team_id}\\.\\*\\|${expected_app_identifier}" <<<"$profile_keychain_groups"; then
  echo "::error::Embedded profile does not authorize the $expected_app_identifier Keychain group." >&2
  printf '%s\n' "$profile_keychain_groups" >&2
  exit 1
fi
bash "$repo_root/scripts/ci/verify-signing-profile-certificate.sh" \
  "$app_path" \
  "$embedded_profile" \
  "$download_sha256" \
  "$expected_version"

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

echo "PASS: public macOS download is Developer ID signed by team $expected_team_id, version $expected_version (Apple $apple_expected_version), notarized, stapled, Firebase-configured, App-Check-clean, Firebase-Keychain-profiled, and Gatekeeper accepted."
