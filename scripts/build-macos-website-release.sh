#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

configuration="${OPENBURNBAR_CONFIGURATION:-Release}"
scheme="${OPENBURNBAR_SCHEME:-OpenBurnBar}"
project="${OPENBURNBAR_PROJECT:-OpenBurnBar.xcodeproj}"
destination="${OPENBURNBAR_DESTINATION:-platform=macOS,arch=arm64}"
team_id="${OPENBURNBAR_APPLE_TEAM_ID:-4Y367DF25B}"
entitlements="AgentLens/Resources/OpenBurnBarRelease.entitlements"

read_project_version() {
  python3 - <<'PY'
from pathlib import Path
import re

text = Path("project.yml").read_text()
block = re.search(r"settings:\n\s+base:\n(?P<body>.*?)(?:\n\S|\Z)", text, re.S)
if not block:
    raise SystemExit("Could not find settings.base in project.yml")
body = block.group("body")
version = re.search(r'MARKETING_VERSION:\s*"?([^"\n]+)"?', body)
build = re.search(r'CURRENT_PROJECT_VERSION:\s*"?([^"\n]+)"?', body)
if not version or not build:
    raise SystemExit("Could not find MARKETING_VERSION/CURRENT_PROJECT_VERSION in settings.base")
print(version.group(1).strip())
print(build.group(1).strip())
PY
}

version_info="$(read_project_version)"
version="${OPENBURNBAR_MAC_VERSION:-$(printf "%s\n" "$version_info" | sed -n "1p")}"
build="${OPENBURNBAR_MAC_BUILD:-$(printf "%s\n" "$version_info" | sed -n "2p")}"
release_dir="${OPENBURNBAR_WEBSITE_RELEASE_DIR:-build/macos-website-${version}-${build}}"
derived_data="$release_dir/DerivedData"
app_path="$derived_data/Build/Products/$configuration/OpenBurnBar.app"
dmg_name="OpenBurnBar-${version}-macOS.dmg"
dmg_path="$release_dir/$dmg_name"
zip_name="OpenBurnBar-${version}-macOS.zip"
zip_path="$release_dir/$zip_name"
checksums_path="$release_dir/checksums-v${version}.txt"
metadata_path="$release_dir/release-metadata.json"
sbom_path="$release_dir/sbom-v${version}.spdx.json"
source_archive_name="OpenBurnBar-${version}-corresponding-source.tar.gz"
source_archive_path="$release_dir/$source_archive_name"

if [[ ! -f "$entitlements" ]]; then
  echo "ERROR: Missing release entitlements at $entitlements" >&2
  exit 1
fi

identity="${OPENBURNBAR_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
fi
if [[ -z "$identity" ]]; then
  echo "ERROR: No Developer ID Application signing identity found. Set OPENBURNBAR_SIGNING_IDENTITY." >&2
  exit 1
fi

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec project.yml
fi

rm -rf "$release_dir"
mkdir -p "$release_dir"

swift build --package-path OpenBurnBarDaemon -c release

set -o pipefail
xcodebuild build \
  -project "$project" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "$destination" \
  -derivedDataPath "$derived_data" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$release_dir/build.log" | tail -120

if [[ ! -d "$app_path" ]]; then
  echo "ERROR: App build missing at $app_path" >&2
  exit 1
fi

helpers_dir="$app_path/Contents/Helpers"
frameworks_dir="$app_path/Contents/Frameworks"
mkdir -p "$helpers_dir" "$frameworks_dir"

daemon_bin="OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon"
daemon_core_dylib="OpenBurnBarDaemon/.build/release/libOpenBurnBarCore.dylib"
if [[ ! -x "$daemon_bin" ]]; then
  echo "ERROR: Daemon binary missing at $daemon_bin" >&2
  exit 1
fi
cp "$daemon_bin" "$helpers_dir/OpenBurnBarDaemon"
chmod +x "$helpers_dir/OpenBurnBarDaemon"
if [[ -f "$daemon_core_dylib" ]]; then
  cp "$daemon_core_dylib" "$helpers_dir/libOpenBurnBarCore.dylib"
fi

core_framework="$derived_data/Build/Products/$configuration/PackageFrameworks/OpenBurnBarCore.framework"
if [[ -d "$core_framework" ]]; then
  rm -rf "$frameworks_dir/OpenBurnBarCore.framework"
  cp -R "$core_framework" "$frameworks_dir/"
fi

bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist")"
app_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app_path/Contents/Info.plist")"
if [[ "$bundle_id" != "com.openburnbar.app" || "$app_version" != "$version" || "$app_build" != "$build" ]]; then
  echo "ERROR: App metadata mismatch: bundle=$bundle_id version=$app_version build=$app_build expected com.openburnbar.app $version $build" >&2
  exit 1
fi

sign_one() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  codesign --force --timestamp --options runtime --sign "$identity" "$path"
}

if [[ -d "$frameworks_dir" ]]; then
  while IFS= read -r -d '' item; do
    sign_one "$item"
  done < <(find "$frameworks_dir" -mindepth 1 \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" \) -print0 | sort -z)
fi
sign_one "$helpers_dir/libOpenBurnBarCore.dylib"
sign_one "$helpers_dir/OpenBurnBarDaemon"

codesign --force --timestamp --deep --options runtime \
  --entitlements "$entitlements" \
  --sign "$identity" \
  "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

actual_entitlements="$release_dir/direct-entitlements.plist"
codesign -d --entitlements :- "$app_path" > "$actual_entitlements" 2>/dev/null
app_sandbox="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$actual_entitlements" 2>/dev/null || true)"
if [[ "$app_sandbox" != "false" ]]; then
  echo "ERROR: Direct-download app must not be sandboxed; found '${app_sandbox:-missing}'." >&2
  exit 1
fi

write_notary_key() {
  local destination="$1"
  local payload="${APPLE_NOTARY_API_KEY_P8:-${APP_STORE_ASC_KEY_P8:-}}"

  if [[ -z "$payload" ]] && command -v firebase >/dev/null 2>&1; then
    payload="$(firebase functions:secrets:access APP_STORE_ASC_KEY_P8 --project burnbar)"
  fi
  if [[ -z "$payload" ]]; then
    return 1
  fi

  if grep -q "BEGIN PRIVATE KEY" <<<"$payload"; then
    printf "%s\n" "$payload" > "$destination"
  else
    printf "%s" "$payload" | base64 --decode > "$destination"
  fi
}

prepare_notary_credentials() {
  local key_file="$1"
  local key_id="${APPLE_NOTARY_KEY_ID:-${APP_STORE_ASC_KEY_ID:-${ASC_KEY_ID:-}}}"
  local issuer_id="${APPLE_NOTARY_ISSUER_ID:-${APP_STORE_ASC_ISSUER_ID:-${ASC_ISSUER_ID:-}}}"

  if [[ -z "$key_id" ]] && command -v firebase >/dev/null 2>&1; then
    key_id="$(firebase functions:secrets:access APP_STORE_ASC_KEY_ID --project burnbar)"
  fi
  if [[ -z "$issuer_id" ]] && command -v firebase >/dev/null 2>&1; then
    issuer_id="$(firebase functions:secrets:access APP_STORE_ASC_ISSUER_ID --project burnbar)"
  fi
  if [[ -z "$key_id" || -z "$issuer_id" ]] || ! write_notary_key "$key_file"; then
    echo "ERROR: Notarization credentials are unavailable. Set APPLE_NOTARY_KEY_ID/ISSUER/API_KEY_P8 or APP_STORE_ASC_*; use OPENBURNBAR_SKIP_NOTARY=1 only for local dry-runs." >&2
    exit 1
  fi
  chmod 600 "$key_file"
  printf "%s\n%s\n" "$key_id" "$issuer_id"
}

reset_notary_cache() {
  rm -f "$HOME/Library/Caches/com.apple.gke.notary.tool/Cache.db"*
}

notarize_zip_and_staple_app() {
  local key_file="$release_dir/AuthKey.p8"
  local notary_zip="$release_dir/OpenBurnBar-${version}-app-notary.zip"
  local credentials key_id issuer_id

  credentials="$(prepare_notary_credentials "$key_file")"
  key_id="$(printf "%s\n" "$credentials" | sed -n "1p")"
  issuer_id="$(printf "%s\n" "$credentials" | sed -n "2p")"

  ditto -c -k --keepParent "$app_path" "$notary_zip"
  reset_notary_cache
  xcrun notarytool submit "$notary_zip" \
    --key "$key_file" \
    --key-id "$key_id" \
    --issuer "$issuer_id" \
    --wait \
    --timeout 30m
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
}

if [[ "${OPENBURNBAR_SKIP_NOTARY:-0}" != "1" ]]; then
  notarize_zip_and_staple_app
else
  echo "WARNING: OPENBURNBAR_SKIP_NOTARY=1; direct-download artifact will not be release-ready." >&2
fi

staging="$release_dir/dmg-staging"
rm -rf "$staging"
mkdir -p "$staging"
cp -R "$app_path" "$staging/"
ln -s /Applications "$staging/Applications"

hdiutil create -volname "OpenBurnBar" \
  -srcfolder "$staging" \
  -ov -format UDZO \
  "$dmg_path"
codesign --force --timestamp --sign "$identity" "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"

if [[ "${OPENBURNBAR_SKIP_NOTARY:-0}" != "1" ]]; then
  key_file="$release_dir/AuthKey.p8"
  credentials="$(prepare_notary_credentials "$key_file")"
  key_id="$(printf "%s\n" "$credentials" | sed -n "1p")"
  issuer_id="$(printf "%s\n" "$credentials" | sed -n "2p")"
  reset_notary_cache
  xcrun notarytool submit "$dmg_path" \
    --key "$key_file" \
    --key-id "$key_id" \
    --issuer "$issuer_id" \
    --wait \
    --timeout 30m
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
fi

cd "$(dirname "$app_path")"
ditto -c -k --keepParent "$(basename "$app_path")" "$repo_root/$zip_path"
cd "$repo_root"

bash scripts/create-corresponding-source.sh --version "$version" --output "$source_archive_path"

{
  echo "# OpenBurnBar v${version} macOS release checksums"
  echo "# Generated at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Commit: $(git rev-parse HEAD)"
  echo ""
  shasum -a 256 "$dmg_path"
  shasum -a 512 "$dmg_path"
  shasum -a 256 "$zip_path"
  shasum -a 512 "$zip_path"
  shasum -a 256 "$source_archive_path"
  shasum -a 512 "$source_archive_path"
} > "$checksums_path"

python3 scripts/generate-sbom.py --version "$version" --repo-root "$repo_root" --output "$sbom_path" || true

python3 - <<PY > "$metadata_path"
import datetime
import json
import subprocess

metadata = {
    "version": "$version",
    "build": "$build",
    "bundleId": "$bundle_id",
    "channel": "direct-download",
    "dmg": "$dmg_name",
    "zip": "$zip_name",
    "correspondingSource": "$source_archive_name",
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "createdAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
print(json.dumps(metadata, indent=2, sort_keys=True))
PY

if [[ "${OPENBURNBAR_SKIP_NOTARY:-0}" != "1" ]]; then
  spctl --assess --type execute --verbose=2 "$app_path"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
fi

echo "Website/direct-download release ready:"
echo "  Version: $version ($build)"
echo "  App: $app_path"
echo "  DMG: $dmg_path"
echo "  ZIP: $zip_path"
echo "  Checksums: $checksums_path"
echo "  SBOM: $sbom_path"
echo "  Corresponding source: $source_archive_path"
