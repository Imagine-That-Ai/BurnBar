#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
source scripts/lib/resolve-repo-path.sh
# shellcheck source=scripts/lib/exact-candidate-git.sh
source scripts/lib/exact-candidate-git.sh
# shellcheck source=scripts/lib/libsignal-swift-compat.sh
source scripts/lib/libsignal-swift-compat.sh
# shellcheck source=scripts/lib/pinned-xcodegen.sh
source scripts/lib/pinned-xcodegen.sh
# shellcheck source=scripts/lib/xcode-source-classification.sh
source scripts/lib/xcode-source-classification.sh
openburnbar_configure_xcode_process_tmpdir
openburnbar_configure_exact_candidate_git "$repo_root"
export FIREBASE_SOURCE_FIRESTORE=1

bash scripts/ci/verify-apple-appcheck-release-env.sh
bash scripts/ci/verify-iroh-release-artifact.sh

team_id="${OPENBURNBAR_APPLE_TEAM_ID:-4Y367DF25B}"
entitlements="AgentLens/Resources/OpenBurnBarMAS.entitlements"
configuration="${OPENBURNBAR_CONFIGURATION:-Release}"
scheme="${OPENBURNBAR_SCHEME:-OpenBurnBar}"
project="${OPENBURNBAR_PROJECT:-OpenBurnBar.xcodeproj}"
upload="${OPENBURNBAR_UPLOAD_MAC_APP_STORE:-0}"
asc_key_id=""
asc_issuer_id=""
asc_key_path=""
asc_key_payload=""
asc_app_apple_id="${OPENBURNBAR_ASC_APPLE_ID:-${APP_STORE_ASC_APPLE_ID:-}}"
expected_app_group="group.com.openburnbar.app"
expected_source_keychain_group='$(AppIdentifierPrefix)com.openburnbar.app'
expected_signed_keychain_group="${team_id}.com.openburnbar.app"

if [[ "$upload" == "1" ]]; then
  bash scripts/require-agpl-store-legal-review.sh
fi

cleanup() {
  local original_status="${1:-0}"
  local google_restore_status=0
  local libsignal_restore_status=0
  openburnbar_restore_google_sign_in_macos_compat || google_restore_status=$?
  openburnbar_restore_libsignal_swift_compat || libsignal_restore_status=$?
  local restore_status="$google_restore_status"
  if ((restore_status == 0)); then
    restore_status="$libsignal_restore_status"
  fi
  if ((original_status == 0 && restore_status != 0)); then
    return "$restore_status"
  fi
  return "$original_status"
}
cleanup_on_exit() {
  local original_status=$?
  trap - EXIT
  cleanup "$original_status"
  exit $?
}
trap cleanup_on_exit EXIT

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
candidate_commit="${OPENBURNBAR_CANDIDATE_COMMIT:-}"
candidate_tree="${OPENBURNBAR_CANDIDATE_TREE:-}"
release_dir="$(
  resolve_fresh_release_output_dir \
    "$repo_root" \
    "${OPENBURNBAR_MAC_APP_STORE_BUILD_DIR:-build/macos-app-store-${version}-${build}}" \
    "Mac App Store release directory"
)"
archive_path="$release_dir/OpenBurnBar.xcarchive"
export_path="$release_dir/export"
export_options="$release_dir/ExportOptions.plist"
log_path="$release_dir/archive.log"
package_cache="${OPENBURNBAR_MAC_APP_STORE_PACKAGE_CACHE:-$repo_root/.spm-cache}"
artifact_receipt="$release_dir/mas-archive-export-receipt.json"

verify_exact_candidate_state() {
  if [[ ! "$candidate_commit" =~ ^[0-9a-f]{40}$ || ! "$candidate_tree" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: Mac App Store archive/export requires full lowercase OPENBURNBAR_CANDIDATE_COMMIT and OPENBURNBAR_CANDIDATE_TREE values." >&2
    exit 1
  fi
  local actual_candidate_commit actual_candidate_tree commit_candidate_tree
  actual_candidate_commit="$(openburnbar_candidate_git rev-parse 'HEAD^{commit}')"
  actual_candidate_tree="$(openburnbar_candidate_git rev-parse 'HEAD^{tree}')"
  commit_candidate_tree="$(openburnbar_candidate_git rev-parse "$candidate_commit^{tree}")"
  if [[ "$candidate_commit" != "$actual_candidate_commit" \
    || "$candidate_tree" != "$actual_candidate_tree" \
    || "$candidate_tree" != "$commit_candidate_tree" ]]; then
    echo "ERROR: Mac App Store candidate binding does not match the exact checked-out commit/tree." >&2
    echo "  supplied: $candidate_commit $candidate_tree" >&2
    echo "  actual:   $actual_candidate_commit $actual_candidate_tree" >&2
    echo "  commit:   $commit_candidate_tree" >&2
    exit 1
  fi
  if [[ -n "$(openburnbar_candidate_git status --porcelain=v1 --untracked-files=all)" ]]; then
    echo "ERROR: Mac App Store archive/export requires a clean exact-candidate checkout." >&2
    exit 1
  fi
}

verify_exact_candidate_state

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

validate_app_store_connect_auth_configuration() {
  local -a key_candidates=()

  asc_key_id="${APP_STORE_ASC_KEY_ID:-${ASC_KEY_ID:-}}"
  asc_issuer_id="${APP_STORE_ASC_ISSUER_ID:-${ASC_ISSUER_ID:-}}"
  asc_key_path="${APP_STORE_ASC_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"
  asc_key_payload="${APP_STORE_ASC_KEY_P8:-}"

  if [[ -n "$asc_key_path" && -n "$asc_key_payload" ]]; then
    echo "ERROR: Provide APP_STORE_ASC_KEY_PATH or APP_STORE_ASC_KEY_P8, not both." >&2
    exit 1
  fi
  if [[ -n "$asc_key_id" && ! "$asc_key_id" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "ERROR: App Store Connect key ID must be alphanumeric." >&2
    exit 1
  fi
  if [[ -z "$asc_key_path" && -z "$asc_key_payload" && -n "$asc_key_id" ]]; then
    key_candidates=(
      "$PWD/private_keys/AuthKey_${asc_key_id}.p8"
      "$HOME/private_keys/AuthKey_${asc_key_id}.p8"
      "$HOME/.private_keys/AuthKey_${asc_key_id}.p8"
      "$HOME/.appstoreconnect/private_keys/AuthKey_${asc_key_id}.p8"
    )
    if [[ -n "${API_PRIVATE_KEYS_DIR:-}" ]]; then
      key_candidates+=("$API_PRIVATE_KEYS_DIR/AuthKey_${asc_key_id}.p8")
    fi
    for candidate in "${key_candidates[@]}"; do
      if [[ -f "$candidate" && ! -L "$candidate" ]]; then
        if [[ -n "$asc_key_path" ]]; then
          echo "ERROR: Multiple discoverable App Store Connect keys match AuthKey_${asc_key_id}.p8." >&2
          exit 1
        fi
        asc_key_path="$candidate"
      fi
    done
  fi

  if [[ -n "$asc_key_id" || -n "$asc_issuer_id" || -n "$asc_key_path" || -n "$asc_key_payload" ]]; then
    if [[ -z "$asc_key_id" || -z "$asc_issuer_id" || ( -z "$asc_key_path" && -z "$asc_key_payload" ) ]]; then
      echo "ERROR: App Store Connect authentication is partially configured; key ID, issuer ID, and private key are all required." >&2
      exit 1
    fi
    if [[ -n "$asc_key_path" && ( ! -s "$asc_key_path" || -L "$asc_key_path" ) ]]; then
      echo "ERROR: App Store Connect authentication key path must be a real file: $asc_key_path" >&2
      exit 1
    fi
    # Keep the private ASC key out of the long-running build process. The
    # upload helper below materializes it only in an owner-only temp directory.
    if [[ "$upload" != "1" ]]; then
      echo "ERROR: App Store Connect credentials are configured but upload is disabled; refusing an unused secret surface." >&2
      exit 1
    fi
  fi
  if [[ "$upload" == "1" ]]; then
    if [[ -z "$asc_key_id" || -z "$asc_issuer_id" || ( -z "$asc_key_path" && -z "$asc_key_payload" ) ]]; then
      echo "ERROR: App Store upload requires an App Store Connect key ID, issuer ID, and private key." >&2
      exit 1
    fi
    if [[ ! "$asc_app_apple_id" =~ ^[0-9]+$ ]]; then
      echo "ERROR: App Store upload requires numeric OPENBURNBAR_ASC_APPLE_ID." >&2
      exit 1
    fi
  fi
  unset APP_STORE_ASC_KEY_ID ASC_KEY_ID
  unset APP_STORE_ASC_ISSUER_ID ASC_ISSUER_ID
  unset APP_STORE_ASC_KEY_PATH ASC_PRIVATE_KEY_PATH APP_STORE_ASC_KEY_P8
}

if [[ ! -f "$entitlements" ]]; then
  echo "ERROR: Missing MAS entitlements at $entitlements" >&2
  exit 1
fi
require_entitlement_bool "$entitlements" "com.apple.security.app-sandbox" "true"
require_entitlement_value "$entitlements" "com.apple.developer.applesignin" "Default"
require_entitlement_value \
  "$entitlements" \
  "com.apple.security.application-groups" \
  "$expected_app_group"
require_entitlement_value \
  "$entitlements" \
  "keychain-access-groups" \
  "$expected_source_keychain_group"
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.network.server" "$entitlements" >/dev/null 2>&1; then
  echo "MAS entitlements must not include com.apple.security.network.server unless the app exposes reviewer-visible server functionality." >&2
  exit 1
fi
validate_app_store_connect_auth_configuration

openburnbar_without_candidate_git_environment \
  bash scripts/test-openburnbar-safari-extension.sh
verify_exact_candidate_state
openburnbar_prepare_libsignal_swift_compat "$repo_root"

openburnbar_verify_xcode_project_sync "$repo_root"

create_fresh_release_output_dir \
  "$repo_root" \
  "$release_dir" \
  "Mac App Store release directory"
mkdir -p "$package_cache"

openburnbar_without_candidate_git_environment \
  bash scripts/prepare-openburnbar-app-swiftpm.sh \
  --project "$project" \
  --scheme "$scheme" \
  --cache-dir "$package_cache" \
  --derived-data "$release_dir/DerivedData"
openburnbar_prepare_google_sign_in_macos_compat "$package_cache"

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
openburnbar_without_candidate_git_environment \
  xcodebuild archive \
  -project "$project" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "generic/platform=macOS" \
  -archivePath "$archive_path" \
  -clonedSourcePackagesDirPath "$package_cache" \
  -derivedDataPath "$release_dir/DerivedData" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -allowProvisioningUpdates \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  DEVELOPMENT_TEAM="$team_id" \
  CODE_SIGN_STYLE=Automatic \
  OPENBURNBAR_HOST_CODE_SIGN_ENTITLEMENTS="$entitlements" \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) DISTRIBUTION_MAS=1' \
  OTHER_SWIFT_FLAGS='$(inherited) -D DISTRIBUTION_MAS' \
  "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[@]}" \
  2>&1 | tee "$log_path" | tail -120

archive_path="$(
  python3 scripts/ci/select-openburnbar-mas-artifact.py \
    --root "$release_dir" \
    --kind archive \
    --expected "$archive_path"
)"
app_path="$archive_path/Products/Applications/OpenBurnBar.app"
app_path="$(
  python3 scripts/ci/select-openburnbar-mas-artifact.py \
    --root "$archive_path/Products/Applications" \
    --kind app \
    --expected "$app_path" \
    --bundle-id com.openburnbar.app \
    --version "$version" \
    --build "$build"
)"

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
require_entitlement_value \
  "$actual_entitlements" \
  "com.apple.security.application-groups" \
  "$expected_app_group"
require_entitlement_value \
  "$actual_entitlements" \
  "keychain-access-groups" \
  "$expected_signed_keychain_group"
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.network.server" "$actual_entitlements" >/dev/null 2>&1; then
  echo "Exported MAS app still has com.apple.security.network.server entitlement." >&2
  exit 1
fi
bash scripts/ci/verify-openburnbar-mas-artifact.sh \
  "$app_path" \
  "$team_id" \
  "$version" \
  "$build"

bash scripts/ci/verify-apple-appcheck-release-artifact.sh "$archive_path"

openburnbar_without_candidate_git_environment \
  xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates \
  2>&1 | tee "$release_dir/export.log" | tail -120

export_artifact="$(
  python3 scripts/ci/select-openburnbar-mas-artifact.py \
    --root "$export_path" \
    --kind pkg
)"

export_inspection="$release_dir/export-inspection"
if [[ -e "$export_inspection" || -L "$export_inspection" ]]; then
  echo "ERROR: Mac App Store export inspection path must be fresh: $export_inspection" >&2
  exit 1
fi
pkgutil --expand-full "$export_artifact" "$export_inspection"
exported_app_path="$(
  python3 scripts/ci/select-openburnbar-mas-artifact.py \
    --root "$export_inspection" \
    --kind app \
    --recursive \
    --bundle-id com.openburnbar.app \
    --version "$version" \
    --build "$build"
)"
exported_entitlements="$release_dir/exported-entitlements.plist"
codesign -d --entitlements :- "$exported_app_path" > "$exported_entitlements" 2>/dev/null
require_entitlement_bool "$exported_entitlements" "com.apple.security.app-sandbox" "true"
require_entitlement_value \
  "$exported_entitlements" \
  "com.apple.security.application-groups" \
  "$expected_app_group"
require_entitlement_value \
  "$exported_entitlements" \
  "keychain-access-groups" \
  "$expected_signed_keychain_group"
bash scripts/ci/verify-openburnbar-mas-artifact.sh \
  "$exported_app_path" \
  "$team_id" \
  "$version" \
  "$build" \
  "$export_artifact"

bash scripts/ci/verify-apple-appcheck-release-artifact.sh "$archive_path" "$export_path" "$export_artifact"

python3 scripts/ci/verify-openburnbar-mas-app-store-connect.py artifact-receipt \
  --candidate-commit "$candidate_commit" \
  --candidate-tree "$candidate_tree" \
  --team-id "$team_id" \
  --version "$version" \
  --build "$build" \
  --archive "$archive_path" \
  --archive-app "$app_path" \
  --export-inspection "$export_inspection" \
  --exported-app "$exported_app_path" \
  --pkg "$export_artifact" \
  --artifact-verifier scripts/ci/verify-openburnbar-mas-artifact.sh \
  --output "$artifact_receipt"

echo "MAS archive/export ready:"
echo "  Version: $version ($build)"
echo "  App: $app_path"
echo "  Export: $export_artifact"
echo "  Receipt: $artifact_receipt"

if [[ "$upload" == "1" ]]; then
  APP_STORE_ASC_KEY_ID="$asc_key_id" \
  APP_STORE_ASC_ISSUER_ID="$asc_issuer_id" \
  APP_STORE_ASC_KEY_PATH="$asc_key_path" \
  APP_STORE_ASC_KEY_P8="$asc_key_payload" \
  OPENBURNBAR_ASC_APPLE_ID="$asc_app_apple_id" \
  bash scripts/ci/upload-openburnbar-mas-and-verify.sh \
    "$export_artifact" \
    "$archive_path" \
    "$exported_app_path" \
    "$artifact_receipt" \
    "$team_id" \
    "$version" \
    "$build" \
    "$candidate_commit" \
    "$candidate_tree" \
    "$release_dir/app-store-connect"
  asc_key_payload=""
fi
