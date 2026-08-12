#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
# shellcheck source=scripts/lib/libsignal-swift-compat.sh
source scripts/lib/libsignal-swift-compat.sh
# shellcheck source=scripts/lib/pinned-xcodegen.sh
source scripts/lib/pinned-xcodegen.sh
# shellcheck source=scripts/lib/xcode-source-classification.sh
source scripts/lib/xcode-source-classification.sh
openburnbar_configure_xcode_process_tmpdir

derived_data="${OPENBURNBAR_MAS_DERIVED_DATA:-build/macos-app-store-readiness-derived}"
log_path="${OPENBURNBAR_MAS_LOG_PATH:-/tmp/openburnbar-macos-app-store-readiness.log}"
entitlements="AgentLens/Resources/OpenBurnBarMAS.entitlements"
direct_entitlements="AgentLens/Resources/OpenBurnBarRelease.entitlements"
expected_app_group="group.com.openburnbar.app"
expected_source_keychain_group='$(AppIdentifierPrefix)com.openburnbar.app'
configuration="${OPENBURNBAR_CONFIGURATION:-Release}"
scheme="${OPENBURNBAR_SCHEME:-OpenBurnBar}"
project="${OPENBURNBAR_PROJECT:-OpenBurnBar.xcodeproj}"
package_cache="${OPENBURNBAR_MAS_PACKAGE_CACHE:-$repo_root/.spm-cache}"

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

if [[ ! -f "$entitlements" ]]; then
  echo "ERROR: Missing Mac App Store entitlements at $entitlements." >&2
  exit 1
fi

require_entitlement_bool "$entitlements" "com.apple.security.app-sandbox" "true"
require_entitlement_bool "$entitlements" "com.apple.security.network.client" "true"
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

if [[ -f "$direct_entitlements" ]]; then
  require_entitlement_bool "$direct_entitlements" "com.apple.security.app-sandbox" "false"
  require_entitlement_value \
    "$direct_entitlements" \
    "com.apple.security.application-groups" \
    "$expected_app_group"
  require_entitlement_value \
    "$direct_entitlements" \
    "keychain-access-groups" \
    "$expected_source_keychain_group"
fi

if [[ "${OPENBURNBAR_MAS_CLEAN:-1}" == "1" ]]; then
  rm -rf "$derived_data"
fi
mkdir -p "$(dirname "$log_path")"

bash scripts/test-openburnbar-safari-extension.sh
openburnbar_prepare_libsignal_swift_compat "$repo_root"
openburnbar_verify_xcode_project_sync "$repo_root"
bash scripts/prepare-openburnbar-app-swiftpm.sh \
  --project "$project" \
  --scheme "$scheme" \
  --cache-dir "$package_cache" \
  --derived-data "$derived_data"
openburnbar_prepare_google_sign_in_macos_compat "$package_cache"

set -o pipefail
xcodebuild build \
  -project "$project" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "generic/platform=macOS" \
  -clonedSourcePackagesDirPath "$package_cache" \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  OPENBURNBAR_HOST_CODE_SIGN_ENTITLEMENTS="$entitlements" \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) DISTRIBUTION_MAS=1' \
  OTHER_SWIFT_FLAGS='$(inherited) -D DISTRIBUTION_MAS' \
  "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[@]}" \
  2>&1 | tee "$log_path" | tail -120

app_path="$(
  python3 scripts/ci/select-openburnbar-mas-artifact.py \
    --root "$derived_data/Build/Products/$configuration" \
    --kind app \
    --bundle-id com.openburnbar.app
)"
python3 scripts/ci/verify-openburnbar-safari-extension-layout.py \
  "$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"

echo "Mac App Store readiness build passed."
echo "Log: $log_path"
