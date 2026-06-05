#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

team_id="${OPENBURNBAR_APPLE_TEAM_ID:-4Y367DF25B}"
entitlements="AgentLens/Resources/OpenBurnBarMAS.entitlements"
configuration="${OPENBURNBAR_CONFIGURATION:-Release}"
scheme="${OPENBURNBAR_SCHEME:-OpenBurnBar}"
project="${OPENBURNBAR_PROJECT:-OpenBurnBar.xcodeproj}"
upload="${OPENBURNBAR_UPLOAD_MAC_APP_STORE:-0}"
auth_key_file=""
auth_args=()

if [[ "$upload" == "1" ]]; then
  bash scripts/require-agpl-store-legal-review.sh
fi

cleanup() {
  if [[ -n "$auth_key_file" && -f "$auth_key_file" ]]; then
    rm -f "$auth_key_file"
  fi
}
trap cleanup EXIT

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
release_dir="${OPENBURNBAR_MAC_APP_STORE_BUILD_DIR:-build/macos-app-store-${version}-${build}}"
archive_path="$release_dir/OpenBurnBar.xcarchive"
export_path="$release_dir/export"
export_options="$release_dir/ExportOptions.plist"
log_path="$release_dir/archive.log"

require_entitlement_bool() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: $file must set $key to $expected; found '${actual:-missing}'." >&2
    exit 1
  fi
}

require_entitlement_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null | tr '\n' ' ' || true)"
  if [[ "$actual" != *"$expected"* ]]; then
    echo "ERROR: $file must include $key value '$expected'; found '${actual:-missing}'." >&2
    exit 1
  fi
}

prepare_app_store_connect_auth() {
  local key_id="${APP_STORE_ASC_KEY_ID:-${ASC_KEY_ID:-}}"
  local issuer_id="${APP_STORE_ASC_ISSUER_ID:-${ASC_ISSUER_ID:-}}"
  local key_path="${APP_STORE_ASC_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"

  if [[ -z "$key_id" ]] && command -v firebase >/dev/null 2>&1; then
    key_id="$(firebase functions:secrets:access APP_STORE_ASC_KEY_ID --project burnbar 2>/dev/null || true)"
  fi
  if [[ -z "$issuer_id" ]] && command -v firebase >/dev/null 2>&1; then
    issuer_id="$(firebase functions:secrets:access APP_STORE_ASC_ISSUER_ID --project burnbar 2>/dev/null || true)"
  fi

  if [[ -z "$key_path" && -n "${APP_STORE_ASC_KEY_P8:-}" ]]; then
    auth_key_file="$(mktemp /tmp/openburnbar-asc-key.XXXXXX)"
    chmod 600 "$auth_key_file"
    printf "%s" "$APP_STORE_ASC_KEY_P8" > "$auth_key_file"
    key_path="$auth_key_file"
  fi

  if [[ -z "$key_path" && -n "$key_id" ]]; then
    local default_key="$HOME/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
    if [[ -f "$default_key" ]]; then
      key_path="$default_key"
    fi
  fi

  if [[ -z "$key_path" ]] && command -v firebase >/dev/null 2>&1; then
    auth_key_file="$(mktemp /tmp/openburnbar-asc-key.XXXXXX)"
    chmod 600 "$auth_key_file"
    if firebase functions:secrets:access APP_STORE_ASC_KEY_P8 --project burnbar > "$auth_key_file" 2>/dev/null; then
      key_path="$auth_key_file"
    else
      rm -f "$auth_key_file"
      auth_key_file=""
    fi
  fi

  if [[ -n "$key_id" && -n "$issuer_id" && -n "$key_path" ]]; then
    auth_args=(
      -authenticationKeyPath "$key_path"
      -authenticationKeyID "$key_id"
      -authenticationKeyIssuerID "$issuer_id"
    )
  fi
}

if [[ ! -f "$entitlements" ]]; then
  echo "ERROR: Missing MAS entitlements at $entitlements" >&2
  exit 1
fi
require_entitlement_bool "$entitlements" "com.apple.security.app-sandbox" "true"
require_entitlement_value "$entitlements" "com.apple.developer.applesignin" "Default"
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.network.server" "$entitlements" >/dev/null 2>&1; then
  echo "MAS entitlements must not include com.apple.security.network.server unless the app exposes reviewer-visible server functionality." >&2
  exit 1
fi
prepare_app_store_connect_auth

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --spec project.yml
fi

rm -rf "$release_dir"
mkdir -p "$release_dir"

cat > "$export_options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>export</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>teamID</key>
	<string>$team_id</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

set -o pipefail
xcodebuild archive \
  -project "$project" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "generic/platform=macOS" \
  -archivePath "$archive_path" \
  -derivedDataPath "$release_dir/DerivedData" \
  -allowProvisioningUpdates \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  DEVELOPMENT_TEAM="$team_id" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_ENTITLEMENTS="$entitlements" \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) DISTRIBUTION_MAS=1' \
  OTHER_SWIFT_FLAGS='$(inherited) -D DISTRIBUTION_MAS' \
  2>&1 | tee "$log_path" | tail -120

app_path="$archive_path/Products/Applications/OpenBurnBar.app"
if [[ ! -d "$app_path" ]]; then
  echo "ERROR: Archive did not contain OpenBurnBar.app at $app_path" >&2
  exit 1
fi

bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist")"
archive_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist")"
archive_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app_path/Contents/Info.plist")"

if [[ "$bundle_id" != "com.openburnbar.app" || "$archive_version" != "$version" || "$archive_build" != "$build" ]]; then
  echo "ERROR: Archive metadata mismatch: bundle=$bundle_id version=$archive_version build=$archive_build expected com.openburnbar.app $version $build" >&2
  exit 1
fi

if find "$app_path/Contents" -name "OpenBurnBarDaemon*" -print -quit | grep -q .; then
  echo "ERROR: MAS archive contains OpenBurnBarDaemon; direct helper must not ship in the sandboxed App Store build." >&2
  exit 1
fi

actual_entitlements="$release_dir/archive-entitlements.plist"
codesign -d --entitlements :- "$app_path" > "$actual_entitlements" 2>/dev/null
require_entitlement_bool "$actual_entitlements" "com.apple.security.app-sandbox" "true"
require_entitlement_value "$actual_entitlements" "com.apple.developer.applesignin" "Default"
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.network.server" "$actual_entitlements" >/dev/null 2>&1; then
  echo "Exported MAS app still has com.apple.security.network.server entitlement." >&2
  exit 1
fi
codesign --verify --strict --verbose=2 "$app_path"

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates \
  "${auth_args[@]}" \
  2>&1 | tee "$release_dir/export.log" | tail -120

export_artifact="$(find "$export_path" -maxdepth 1 -type f \( -name "*.pkg" -o -name "*.ipa" \) -print -quit)"
if [[ -z "$export_artifact" ]]; then
  echo "ERROR: Export succeeded but no .pkg/.ipa was found in $export_path" >&2
  find "$export_path" -maxdepth 2 -type f -print >&2
  exit 1
fi

echo "MAS archive/export ready:"
echo "  Version: $version ($build)"
echo "  App: $app_path"
echo "  Export: $export_artifact"

if [[ "$upload" == "1" ]]; then
  key_id="${APP_STORE_ASC_KEY_ID:-${ASC_KEY_ID:-}}"
  issuer_id="${APP_STORE_ASC_ISSUER_ID:-${ASC_ISSUER_ID:-}}"

  if [[ -z "$key_id" ]] && command -v firebase >/dev/null 2>&1; then
    key_id="$(firebase functions:secrets:access APP_STORE_ASC_KEY_ID --project burnbar)"
  fi
  if [[ -z "$issuer_id" ]] && command -v firebase >/dev/null 2>&1; then
    issuer_id="$(firebase functions:secrets:access APP_STORE_ASC_ISSUER_ID --project burnbar)"
  fi
  if [[ -z "$key_id" || -z "$issuer_id" ]]; then
    echo "ERROR: Upload requested, but APP_STORE_ASC_KEY_ID/APP_STORE_ASC_ISSUER_ID are unavailable." >&2
    exit 1
  fi

  xcrun altool --validate-app -f "$export_artifact" --type macos --apiKey "$key_id" --apiIssuer "$issuer_id"
  xcrun altool --upload-app -f "$export_artifact" --type macos --apiKey "$key_id" --apiIssuer "$issuer_id"
fi
