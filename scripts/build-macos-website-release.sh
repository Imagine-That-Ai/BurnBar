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

notary_work_dir=""
app_notary_artifact_name=""
app_notary_artifact_sha256=""
app_notary_artifact_size=""
dmg_notary_artifact_name=""
dmg_notary_artifact_sha256=""
dmg_notary_artifact_size=""
cleanup() {
  local original_status="${1:-0}"
  local notary_cleanup_status=0
  local google_restore_status=0
  local libsignal_restore_status=0
  if [[ -n "$notary_work_dir" ]]; then
    rm -rf "$notary_work_dir" || notary_cleanup_status=$?
  fi
  openburnbar_restore_google_sign_in_macos_compat || google_restore_status=$?
  openburnbar_restore_libsignal_swift_compat || libsignal_restore_status=$?
  local restore_status="$notary_cleanup_status"
  if ((restore_status == 0)); then
    restore_status="$google_restore_status"
  fi
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

bash scripts/ci/verify-apple-appcheck-release-env.sh
bash scripts/ci/verify-iroh-release-artifact.sh

configuration="${OPENBURNBAR_CONFIGURATION:-Release}"
scheme="${OPENBURNBAR_SCHEME:-OpenBurnBar}"
project="${OPENBURNBAR_PROJECT:-OpenBurnBar.xcodeproj}"
destination="${OPENBURNBAR_DESTINATION:-platform=macOS,arch=arm64}"
entitlements="AgentLens/Resources/OpenBurnBarRelease.entitlements"
app_profile="${OPENBURNBAR_APP_PROFILE:-build/app-direct-profile/OpenBurnBar-MAC_APP_DIRECT.provisionprofile}"
safari_extension_profile="${OPENBURNBAR_SAFARI_EXTENSION_PROFILE:-build/app-direct-profile/OpenBurnBarSafariExtension-MAC_APP_DIRECT.provisionprofile}"
privileged_input_entitlements="OpenBurnBarDaemon/Resources/PrivilegedInputExecution/OpenBurnBarPrivilegedInputExecution.entitlements"
privileged_input_profile="${OPENBURNBAR_PRIVILEGED_INPUT_PROFILE:-build/hid-managed-profile/OpenBurnBarPrivilegedInputExecution-MAC_APP_DIRECT.provisionprofile}"
expected_host_bundle_id="com.openburnbar.app"
expected_app_group="group.com.openburnbar.app"
expected_source_keychain_group='$(AppIdentifierPrefix)com.openburnbar.app'

require_entitlement_value() {
  local entitlement_file="$1"
  local entitlement_key="$2"
  local expected_value="$3"
  local actual_value

  actual_value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement_key" "$entitlement_file" 2>/dev/null | tr '\n' ' ' || true)"
  if [[ "$actual_value" != *"$expected_value"* ]]; then
    echo "ERROR: $entitlement_file must include $entitlement_key value '$expected_value'; found '${actual_value:-missing}'." >&2
    exit 1
  fi
}

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
release_dir="$(
  resolve_fresh_release_output_dir \
    "$repo_root" \
    "${OPENBURNBAR_WEBSITE_RELEASE_DIR:-build/macos-website-${version}-${build}}" \
    "Developer ID release directory"
)"
derived_data="$release_dir/DerivedData"
package_cache="${OPENBURNBAR_WEBSITE_PACKAGE_CACHE:-$repo_root/.spm-cache}"
app_path="$derived_data/Build/Products/$configuration/OpenBurnBar.app"
dmg_name="OpenBurnBar-${version}-macOS.dmg"
dmg_path="$release_dir/$dmg_name"
zip_name="OpenBurnBar-${version}-macOS.zip"
zip_path="$release_dir/$zip_name"
checksums_path="$release_dir/checksums-v${version}.txt"
metadata_path="$release_dir/release-metadata.json"
sbom_path="$release_dir/sbom-v${version}.spdx.json"
signing_receipt_path="$release_dir/developer-id-signing-receipt.json"
release_receipt_path="$release_dir/developer-id-release-receipt.json"
app_notary_result_path="$release_dir/app-notarization-result.json"
dmg_notary_result_path="$release_dir/dmg-notarization-result.json"
default_update_base_url="$(
  # Do not derive release-feed payload URLs from SITE.macDownloadBaseUrl: the website
  # can temporarily fall back to an older public asset while new artifacts are rebuilt.
  printf "%s\n" "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download"
)"
update_base_url="${OPENBURNBAR_MAC_UPDATE_BASE_URL:-${OPENBURNBAR_R2_PUBLIC_BASE_URL:-$default_update_base_url}}"
appcast_name="appcast.xml"
appcast_path="$release_dir/$appcast_name"
latest_name="latest-macos.json"
latest_path="$release_dir/$latest_name"
source_archive_name="OpenBurnBar-${version}-corresponding-source.tar.gz"
source_archive_path="$release_dir/$source_archive_name"
candidate_commit="${OPENBURNBAR_CANDIDATE_COMMIT:-$(openburnbar_candidate_git rev-parse HEAD)}"
candidate_tree="${OPENBURNBAR_CANDIDATE_TREE:-$(openburnbar_candidate_git rev-parse 'HEAD^{tree}')}"

if [[ ! "$candidate_commit" =~ ^[0-9a-f]{40}$ || ! "$candidate_tree" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: Direct-release candidate commit and tree must be full lowercase Git SHAs." >&2
  exit 1
fi
actual_candidate_commit="$(openburnbar_candidate_git rev-parse HEAD)"
if [[ "$actual_candidate_commit" != "$candidate_commit" ]]; then
  echo "ERROR: Direct-release candidate commit $candidate_commit does not match checked-out HEAD $actual_candidate_commit." >&2
  exit 1
fi
if [[ "$(openburnbar_candidate_git rev-parse "$candidate_commit^{tree}")" != "$candidate_tree" ]]; then
  echo "ERROR: Direct-release candidate tree $candidate_tree does not belong to commit $candidate_commit." >&2
  exit 1
fi
if [[ -n "$(openburnbar_candidate_git status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "ERROR: Direct-release builds require a clean exact-candidate checkout; commit or remove candidate drift before signing." >&2
  exit 1
fi

if [[ ! -f "$entitlements" ]]; then
  echo "ERROR: Missing release entitlements at $entitlements" >&2
  exit 1
fi
require_entitlement_value \
  "$entitlements" \
  "com.apple.security.application-groups" \
  "$expected_app_group"
require_entitlement_value \
  "$entitlements" \
  "keychain-access-groups" \
  "$expected_source_keychain_group"
if [[ ! -f "$app_profile" ]]; then
  echo "ERROR: Missing app Developer ID provisioning profile at $app_profile. Set OPENBURNBAR_APP_PROFILE to the MAC_APP_DIRECT profile for com.openburnbar.app." >&2
  exit 1
fi
if [[ ! -f "$safari_extension_profile" ]]; then
  echo "ERROR: Missing Safari extension Developer ID provisioning profile at $safari_extension_profile. Set OPENBURNBAR_SAFARI_EXTENSION_PROFILE to the dedicated MAC_APP_DIRECT profile for com.openburnbar.app.safari-extension." >&2
  exit 1
fi
if [[ ! -f "$privileged_input_entitlements" ]]; then
  echo "ERROR: Missing privileged input entitlements at $privileged_input_entitlements" >&2
  exit 1
fi
if [[ ! -f "$privileged_input_profile" ]]; then
  echo "ERROR: Missing privileged input provisioning profile at $privileged_input_profile. Set OPENBURNBAR_PRIVILEGED_INPUT_PROFILE to the managed-capability profile." >&2
  exit 1
fi

identity="${OPENBURNBAR_SIGNING_IDENTITY:-}"
bash scripts/test-openburnbar-safari-extension.sh
openburnbar_prepare_libsignal_swift_compat "$repo_root"

openburnbar_verify_xcode_project_sync "$repo_root"

mkdir -p "$release_dir"
chmod 700 "$release_dir"
mkdir -p "$package_cache"

bash scripts/prepare-openburnbar-app-swiftpm.sh \
  --project "$project" \
  --scheme "$scheme" \
  --cache-dir "$package_cache" \
  --derived-data "$derived_data"
openburnbar_prepare_google_sign_in_macos_compat "$package_cache"

privileged_input_profile_plist="$release_dir/privileged-input-profile.plist"
privileged_input_signing_entitlements="$release_dir/privileged-input-entitlements.plist"
app_profile_plist="$release_dir/app-profile.plist"
app_signing_entitlements="$release_dir/app-signing-entitlements.plist"
security cms -D -i "$app_profile" > "$app_profile_plist"
if [[ "$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$app_profile_plist" 2>/dev/null || true)" != "true" ]]; then
  echo "ERROR: App profile must be a Developer ID / MAC_APP_DIRECT all-devices profile." >&2
  exit 1
fi
app_profile_team_id="$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$app_profile_plist" 2>/dev/null || true)"
app_profile_identifier="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$app_profile_plist" 2>/dev/null || true)"
expected_app_identifier="${app_profile_team_id}.${expected_host_bundle_id}"
if [[ ! "$app_profile_team_id" =~ ^[A-Z0-9]{10}$ || "$app_profile_identifier" != "$expected_app_identifier" ]]; then
  echo "ERROR: App profile must authorize $expected_host_bundle_id for team ${app_profile_team_id:-<missing>}; found application identifier '${app_profile_identifier:-missing}'." >&2
  exit 1
fi
if [[ -z "$identity" ]]; then
  echo "ERROR: OPENBURNBAR_SIGNING_IDENTITY must name the exact Developer ID Application identity for team $app_profile_team_id; first-identity fallback is forbidden." >&2
  exit 1
fi
if [[ "$identity" != "Developer ID Application:"* || "$identity" != *"($app_profile_team_id)" ]]; then
  echo "ERROR: OPENBURNBAR_SIGNING_IDENTITY must be a Developer ID Application identity for exact team $app_profile_team_id; found '$identity'." >&2
  exit 1
fi
identity_matches=0
while IFS= read -r available_identity; do
  if [[ "$available_identity" == "$identity" ]]; then
    identity_matches=$((identity_matches + 1))
  fi
done < <(security find-identity -v -p codesigning | sed -n 's/.*"\([^"]*\)".*/\1/p')
if [[ "$identity_matches" -ne 1 ]]; then
  echo "ERROR: Expected exactly one installed codesigning identity named '$identity'; found $identity_matches." >&2
  exit 1
fi
security cms -D -i "$privileged_input_profile" > "$privileged_input_profile_plist"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" \
  "$privileged_input_profile_plist" > "$privileged_input_signing_entitlements"
if ! /usr/libexec/PlistBuddy -c "Print :com.apple.developer.hid.virtual.device" \
  "$privileged_input_signing_entitlements" 2>/dev/null | grep -q "true"; then
  echo "ERROR: Privileged input profile is missing com.apple.developer.hid.virtual.device." >&2
  exit 1
fi

swift build --package-path OpenBurnBarDaemon -c release --product OpenBurnBarDaemon
swift build --package-path OpenBurnBarDaemon -c release --product OpenBurnBarCLI

set -o pipefail
xcodebuild build \
  -project "$project" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "$destination" \
  -clonedSourcePackagesDirPath "$package_cache" \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[@]}" \
  2>&1 | tee "$release_dir/build.log" | tail -120

if [[ ! -d "$app_path" ]]; then
  echo "ERROR: App build missing at $app_path" >&2
  exit 1
fi

helpers_dir="$app_path/Contents/Helpers"
frameworks_dir="$app_path/Contents/Frameworks"
mkdir -p "$helpers_dir" "$frameworks_dir"

daemon_bin="OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon"
daemon_cli_bin="OpenBurnBarDaemon/.build/release/OpenBurnBarCLI"
daemon_core_dylib="OpenBurnBarDaemon/.build/release/libOpenBurnBarCore.dylib"
if [[ ! -x "$daemon_bin" ]]; then
  echo "ERROR: Daemon binary missing at $daemon_bin" >&2
  exit 1
fi
if [[ ! -x "$daemon_cli_bin" ]]; then
  echo "ERROR: Daemon CLI binary missing at $daemon_cli_bin" >&2
  exit 1
fi
cp "$daemon_bin" "$helpers_dir/OpenBurnBarDaemon"
cp "$daemon_cli_bin" "$helpers_dir/OpenBurnBarCLI"
chmod +x "$helpers_dir/OpenBurnBarDaemon" "$helpers_dir/OpenBurnBarCLI"
if [[ -f "$daemon_core_dylib" ]]; then
  cp "$daemon_core_dylib" "$helpers_dir/libOpenBurnBarCore.dylib"
fi
daemon_resource_bundle="$app_path/Contents/Resources/OpenBurnBarCore_OpenBurnBarCore.bundle"
daemon_helper_resource_bundle="$helpers_dir/OpenBurnBarCore_OpenBurnBarCore.bundle"
# Core-decomposition P-02: the Kernel target gained its own resource bundle
# (catalog.json + secret-pattern-corpus.json). Stage it IN ADDITION to the Core bundle.
daemon_kernel_resource_bundle="$app_path/Contents/Resources/OpenBurnBarCore_OpenBurnBarKernel.bundle"
daemon_helper_kernel_resource_bundle="$helpers_dir/OpenBurnBarCore_OpenBurnBarKernel.bundle"
project_code_memory_dir="$app_path/Contents/Resources/ProjectCodeMemory"
if [[ ! -d "$daemon_resource_bundle" ]]; then
  echo "ERROR: OpenBurnBarDaemon resource bundle missing at $daemon_resource_bundle" >&2
  exit 1
fi
if [[ ! -d "$daemon_kernel_resource_bundle" ]]; then
  echo "ERROR: OpenBurnBarDaemon Kernel resource bundle missing at $daemon_kernel_resource_bundle" >&2
  exit 1
fi
if [[ ! -d "$project_code_memory_dir" ]]; then
  echo "ERROR: OpenBurnBarDaemon Project Code Memory resources missing at $project_code_memory_dir" >&2
  exit 1
fi
rm -rf "$daemon_helper_resource_bundle" "$daemon_helper_kernel_resource_bundle" "$helpers_dir/ProjectCodeMemory"
cp -R "$daemon_resource_bundle" "$daemon_helper_resource_bundle"
cp -R "$daemon_kernel_resource_bundle" "$daemon_helper_kernel_resource_bundle"
if otool -L "$helpers_dir/OpenBurnBarDaemon" | grep -q 'SQLCipher.framework'; then
  if [[ ! -d "$frameworks_dir/SQLCipher.framework" ]]; then
    echo "ERROR: OpenBurnBarDaemon links SQLCipher.framework but the app bundle is missing Contents/Frameworks/SQLCipher.framework" >&2
    exit 1
  fi
  if ! otool -l "$helpers_dir/OpenBurnBarDaemon" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$helpers_dir/OpenBurnBarDaemon"
  fi
fi
if otool -L "$helpers_dir/OpenBurnBarCLI" | grep -q 'SQLCipher.framework'; then
  if [[ ! -d "$frameworks_dir/SQLCipher.framework" ]]; then
    echo "ERROR: OpenBurnBarCLI links SQLCipher.framework but the app bundle is missing Contents/Frameworks/SQLCipher.framework" >&2
    exit 1
  fi
  if ! otool -l "$helpers_dir/OpenBurnBarCLI" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$helpers_dir/OpenBurnBarCLI"
  fi
fi

core_framework="$derived_data/Build/Products/$configuration/PackageFrameworks/OpenBurnBarCore.framework"
if [[ -d "$core_framework" ]]; then
  rm -rf "$frameworks_dir/OpenBurnBarCore.framework"
  cp -R "$core_framework" "$frameworks_dir/"
fi

bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist")"
app_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app_path/Contents/Info.plist")"
if [[ "$bundle_id" != "$expected_host_bundle_id" || "$app_version" != "$version" || "$app_build" != "$build" ]]; then
  echo "ERROR: App metadata mismatch: bundle=$bundle_id version=$app_version build=$app_build expected $expected_host_bundle_id $version $build" >&2
  exit 1
fi
app_profile_keychain_groups="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups" "$app_profile_plist" 2>/dev/null || true)"
if ! grep -q "${app_profile_team_id}\\.\\*\\|${expected_app_identifier}" <<<"$app_profile_keychain_groups"; then
  echo "ERROR: App profile does not authorize the $expected_app_identifier Keychain access group." >&2
  printf '%s\n' "$app_profile_keychain_groups" >&2
  exit 1
fi
app_profile_app_groups="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.security.application-groups" "$app_profile_plist" 2>/dev/null || true)"
if ! grep -Fq "$expected_app_group" <<<"$app_profile_app_groups"; then
  echo "ERROR: App profile does not authorize shared Safari App Group $expected_app_group." >&2
  printf '%s\n' "$app_profile_app_groups" >&2
  exit 1
fi
python3 - "$entitlements" "$app_signing_entitlements" "$app_profile_team_id" "$bundle_id" <<'PY'
import plistlib
import sys
from pathlib import Path

source, destination, team_id, bundle_id = sys.argv[1:5]

def expand(value):
    if isinstance(value, str):
        return (
            value
            .replace("$(AppIdentifierPrefix)", f"{team_id}.")
            .replace("$(TeamIdentifierPrefix)", team_id)
            .replace("$(PRODUCT_BUNDLE_IDENTIFIER)", bundle_id)
        )
    if isinstance(value, list):
        return [expand(item) for item in value]
    if isinstance(value, dict):
        return {key: expand(item) for key, item in value.items()}
    return value

with Path(source).open("rb") as file:
    entitlements = plistlib.load(file)
with Path(destination).open("wb") as file:
    plistlib.dump(expand(entitlements), file)
PY

bash scripts/ci/verify-apple-appcheck-release-artifact.sh "$app_path"
python3 scripts/ci/verify-openburnbar-safari-extension-layout.py \
  "$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"

sign_one() {
  local path="$1"
  local options="${2:-runtime}"
  local identifier="${3:-}"
  [[ -e "$path" ]] || return 0
  local args=(--force --timestamp --options "$options" --sign "$identity")
  if [[ -n "$identifier" ]]; then
    args+=(--identifier "$identifier")
  fi
  codesign "${args[@]}" "$path"
}

sign_one_with_entitlements() {
  local path="$1"
  local entitlements_path="$2"
  local options="${3:-runtime}"
  local identifier="${4:-}"
  [[ -e "$path" ]] || return 0
  local args=(--force --timestamp --options "$options" --entitlements "$entitlements_path" --sign "$identity")
  if [[ -n "$identifier" ]]; then
    args+=(--identifier "$identifier")
  fi
  codesign "${args[@]}" "$path"
}

assert_peer_signature() {
  local path="$1"
  local expected_identifier="$2"
  local signature

  [[ -e "$path" ]] || return 0
  signature="$(codesign -d -vvv "$path" 2>&1)"
  if ! grep -q "Identifier=$expected_identifier" <<<"$signature"; then
    echo "ERROR: $path is signed with the wrong identifier; expected $expected_identifier." >&2
    printf '%s\n' "$signature" >&2
    exit 1
  fi
  if ! grep -q "flags=.*runtime" <<<"$signature" || ! grep -q "flags=.*library-validation" <<<"$signature"; then
    echo "ERROR: $path must be signed with hardened runtime and library validation for privileged socket policy." >&2
    printf '%s\n' "$signature" >&2
    exit 1
  fi
}

wrap_privileged_input_execution_helper() {
  local executable_path="$1"
  local helper_app="$2"
  local contents_dir="$helper_app/Contents"
  local macos_dir="$contents_dir/MacOS"

  [[ -x "$executable_path" ]] || return 0
  rm -rf "$helper_app"
  mkdir -p "$macos_dir"
  cp "$executable_path" "$macos_dir/OpenBurnBarPrivilegedInputExecution"
  chmod 755 "$macos_dir/OpenBurnBarPrivilegedInputExecution"
  cp "$privileged_input_profile" "$contents_dir/embedded.provisionprofile"
  cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>OpenBurnBar Privileged Input Execution</string>
  <key>CFBundleExecutable</key>
  <string>OpenBurnBarPrivilegedInputExecution</string>
  <key>CFBundleIdentifier</key>
  <string>com.openburnbar.privileged-input-execution</string>
  <key>CFBundleName</key>
  <string>OpenBurnBarPrivilegedInputExecution</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$app_version</string>
  <key>CFBundleVersion</key>
  <string>$app_build</string>
  <key>LSBackgroundOnly</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
PLIST
  codesign --force --timestamp --options runtime,library \
    --entitlements "$privileged_input_signing_entitlements" \
    --sign "$identity" \
    "$helper_app"
  bash scripts/ci/verify-signing-profile-certificate.sh \
    "$helper_app" \
    "$privileged_input_profile"
  codesign --verify --deep --strict --verbose=2 "$helper_app"
  assert_peer_signature "$helper_app" "com.openburnbar.privileged-input-execution"
}

if [[ -d "$frameworks_dir" ]]; then
  while IFS= read -r -d '' item; do
    sign_one "$item"
  done < <(
    find "$frameworks_dir" -mindepth 1 \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" \) -print0 \
      | python3 -c 'import sys; paths=[p for p in sys.stdin.buffer.read().split(b"\0") if p]; paths.sort(key=lambda p: (p.count(b"/"), len(p)), reverse=True); sys.stdout.buffer.write(b"\0".join(paths) + (b"\0" if paths else b""))'
  )
fi
if [[ -d "$helpers_dir" ]]; then
  while IFS= read -r -d '' item; do
    sign_one "$item"
  done < <(
    find "$helpers_dir" -mindepth 1 \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" \) -print0 \
      | python3 -c 'import sys; paths=[p for p in sys.stdin.buffer.read().split(b"\0") if p]; paths.sort(key=lambda p: (p.count(b"/"), len(p)), reverse=True); sys.stdout.buffer.write(b"\0".join(paths) + (b"\0" if paths else b""))'
  )
fi
sign_one "$helpers_dir/libOpenBurnBarCore.dylib"
sign_one "$helpers_dir/OpenBurnBarDaemon" "runtime,library" "com.openburnbar.app"
sign_one "$helpers_dir/OpenBurnBarCLI" "runtime,library" "com.openburnbar.cli"
sign_one "$helpers_dir/OpenBurnBarVirtualHIDBridge" "runtime,library" "com.openburnbar.virtual-hid-bridge"
sign_one \
  "$helpers_dir/OpenBurnBarPrivilegedInputKillSwitchWatchdog" \
  "runtime,library" \
  "com.openburnbar.privileged-input-killswitch-watchdog"
sign_one_with_entitlements \
  "$helpers_dir/OpenBurnBarPrivilegedInputExecution" \
  "$privileged_input_signing_entitlements" \
  "runtime,library" \
  "com.openburnbar.privileged-input-execution"
wrap_privileged_input_execution_helper \
  "$helpers_dir/OpenBurnBarPrivilegedInputExecution" \
  "$helpers_dir/OpenBurnBarPrivilegedInputExecution.app"

bash scripts/ci/sign-openburnbar-safari-extension.sh \
  "$app_path" \
  "$identity" \
  "$safari_extension_profile" \
  "$app_profile_team_id"

cp "$app_profile" "$app_path/Contents/embedded.provisionprofile"
codesign --force --timestamp --options runtime,library \
  --entitlements "$app_signing_entitlements" \
  --sign "$identity" \
  "$app_path"
assert_peer_signature "$app_path" "com.openburnbar.app"
assert_peer_signature "$helpers_dir/OpenBurnBarDaemon" "com.openburnbar.app"
assert_peer_signature "$helpers_dir/OpenBurnBarCLI" "com.openburnbar.cli"
assert_peer_signature "$helpers_dir/OpenBurnBarVirtualHIDBridge" "com.openburnbar.virtual-hid-bridge"
assert_peer_signature "$helpers_dir/OpenBurnBarPrivilegedInputExecution" "com.openburnbar.privileged-input-execution"
assert_peer_signature \
  "$helpers_dir/OpenBurnBarPrivilegedInputKillSwitchWatchdog" \
  "com.openburnbar.privileged-input-killswitch-watchdog"
bash scripts/ci/verify-openburnbar-direct-release.sh \
  "$app_path" \
  "$app_profile_team_id" \
  "$app_profile" \
  "$safari_extension_profile" \
  "$signing_receipt_path"

bash scripts/ci/verify-daemon-release-signing.sh "$app_path" "$app_profile_team_id"

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
    (umask 077 && printf "%s\n" "$payload" > "$destination")
  else
    (
      umask 077
      printf "%s" "$payload" \
        | python3 -c 'import base64, sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read(), validate=True))' \
        > "$destination"
    )
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

write_notary_receipt() {
  local raw_result_path="$1"
  local receipt_path="$2"
  local label="$3"
  local artifact_name="$4"
  local artifact_sha256="$5"
  local artifact_size="$6"
  python3 - \
    "$raw_result_path" \
    "$receipt_path" \
    "$repo_root/scripts/lib" \
    "$label" \
    "$artifact_name" \
    "$artifact_sha256" \
    "$artifact_size" <<'PY'
import json
import re
import sys
from pathlib import Path

raw_path = Path(sys.argv[1])
receipt_path = Path(sys.argv[2])
sys.path.insert(0, sys.argv[3])
from exclusive_json import write_exclusive_json

label = sys.argv[4]
artifact_name = sys.argv[5]
artifact_sha256 = sys.argv[6]
artifact_size = sys.argv[7]
try:
    result = json.loads(raw_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"ERROR: {label} notarization result is unreadable or invalid JSON: {error}")
if result.get("status") != "Accepted":
    raise SystemExit(
        f"ERROR: {label} notarization status must be 'Accepted'; found {result.get('status')!r}."
    )
submission_id = result.get("id")
if not isinstance(submission_id, str) or not re.fullmatch(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    submission_id,
):
    raise SystemExit(f"ERROR: {label} notarization result is missing a valid submission id.")
if not re.fullmatch(r"[0-9a-f]{64}", artifact_sha256):
    raise SystemExit(f"ERROR: {label} notarization artifact SHA-256 is invalid.")
if not artifact_size.isdigit() or int(artifact_size) <= 0:
    raise SystemExit(f"ERROR: {label} notarization artifact size must be positive.")
receipt = {
    "schemaVersion": 1,
    "artifact": {
        "fileName": artifact_name,
        "sha256": artifact_sha256,
        "sizeBytes": int(artifact_size),
    },
    "submission": {
        "id": submission_id.lower(),
        "status": "Accepted",
    },
}
write_exclusive_json(receipt_path, receipt)
PY
}

notarize_zip_and_staple_app() {
  local key_file="$notary_work_dir/AuthKey.p8"
  local notary_zip="$release_dir/OpenBurnBar-${version}-app-notary.zip"
  local credentials key_id issuer_id

  credentials="$(prepare_notary_credentials "$key_file")"
  key_id="$(printf "%s\n" "$credentials" | sed -n "1p")"
  issuer_id="$(printf "%s\n" "$credentials" | sed -n "2p")"

  ditto -c -k --keepParent "$app_path" "$notary_zip"
  app_notary_artifact_name="$(basename "$notary_zip")"
  app_notary_artifact_sha256="$(shasum -a 256 "$notary_zip" | awk '{print $1}')"
  app_notary_artifact_size="$(stat -f %z "$notary_zip")"
  xcrun notarytool submit "$notary_zip" \
    --key "$key_file" \
    --key-id "$key_id" \
    --issuer "$issuer_id" \
    --wait \
    --timeout 30m \
    --output-format json > "$notary_work_dir/app-notarytool-result.json"
  write_notary_receipt \
    "$notary_work_dir/app-notarytool-result.json" \
    "$app_notary_result_path" \
    "app" \
    "$app_notary_artifact_name" \
    "$app_notary_artifact_sha256" \
    "$app_notary_artifact_size"
  rm -f "$notary_zip"
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
}

if [[ "${OPENBURNBAR_SKIP_NOTARY:-0}" != "1" ]]; then
  notary_tmp_root="${OPENBURNBAR_NOTARY_TMPDIR:-${TMPDIR:-/tmp}}"
  notary_work_dir="$(mktemp -d "$notary_tmp_root/openburnbar-notary.XXXXXX")"
  chmod 700 "$notary_work_dir"
  python3 - "$notary_work_dir" "$release_dir" <<'PY'
import os
import sys
from pathlib import Path

notary_work_dir = Path(sys.argv[1]).resolve()
release_dir = Path(sys.argv[2]).resolve()
if os.path.commonpath((notary_work_dir, release_dir)) == str(release_dir):
    raise SystemExit(
        "ERROR: Ephemeral notarization credentials must be stored outside "
        "the release output directory."
    )
PY
  notarize_zip_and_staple_app
else
  echo "WARNING: OPENBURNBAR_SKIP_NOTARY=1; this invocation is an uncertified dry-run and cannot emit a release receipt." >&2
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
  key_file="$notary_work_dir/AuthKey.p8"
  credentials="$(prepare_notary_credentials "$key_file")"
  key_id="$(printf "%s\n" "$credentials" | sed -n "1p")"
  issuer_id="$(printf "%s\n" "$credentials" | sed -n "2p")"
  dmg_notary_artifact_name="$(basename "$dmg_path")"
  dmg_notary_artifact_sha256="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
  dmg_notary_artifact_size="$(stat -f %z "$dmg_path")"
  xcrun notarytool submit "$dmg_path" \
    --key "$key_file" \
    --key-id "$key_id" \
    --issuer "$issuer_id" \
    --wait \
    --timeout 30m \
    --output-format json > "$notary_work_dir/dmg-notarytool-result.json"
  write_notary_receipt \
    "$notary_work_dir/dmg-notarytool-result.json" \
    "$dmg_notary_result_path" \
    "DMG" \
    "$dmg_notary_artifact_name" \
    "$dmg_notary_artifact_sha256" \
    "$dmg_notary_artifact_size"
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
fi

cd "$(dirname "$app_path")"
ditto -c -k --keepParent "$(basename "$app_path")" "$zip_path"
cd "$repo_root"

require_unique_release_artifact() {
  local expected_path="$1"
  local pattern="$2"
  local label="$3"
  local matches=()
  local match

  while IFS= read -r -d '' match; do
    matches+=("$match")
  done < <(compgen -G "$pattern" | while IFS= read -r match; do printf '%s\0' "$match"; done)
  if [[ "${#matches[@]}" -ne 1 || "${matches[0]}" != "$expected_path" ]]; then
    echo "ERROR: Expected exactly one $label artifact at $expected_path; found ${#matches[@]} matching artifacts." >&2
    printf '  %s\n' "${matches[@]}" >&2
    exit 1
  fi
}

require_unique_release_artifact "$dmg_path" "$release_dir/OpenBurnBar-*-macOS.dmg" "DMG"
require_unique_release_artifact "$zip_path" "$release_dir/OpenBurnBar-*-macOS.zip" "ZIP"

bash scripts/ci/verify-apple-appcheck-release-artifact.sh "$dmg_path" "$zip_path"

bash scripts/create-corresponding-source.sh --version "$version" --output "$source_archive_path"

sparkle_ed_signature="${OPENBURNBAR_SPARKLE_ED_SIGNATURE:-}"
if [[ -z "$sparkle_ed_signature" ]]; then
  sparkle_sign_update="${SPARKLE_SIGN_UPDATE:-}"
  if [[ -z "$sparkle_sign_update" ]] && command -v sign_update >/dev/null 2>&1; then
    sparkle_sign_update="$(command -v sign_update)"
  fi
  if [[ -n "$sparkle_sign_update" && -x "$sparkle_sign_update" ]]; then
    sparkle_private_key_payload="${OPENBURNBAR_SPARKLE_PRIVATE_KEY:-}"
    if [[ -z "$sparkle_private_key_payload" && -n "${OPENBURNBAR_SPARKLE_PRIVATE_KEY_BASE64:-}" ]]; then
      sparkle_private_key_payload="$(
        python3 - <<'PY'
import base64
import os

print(base64.b64decode(os.environ["OPENBURNBAR_SPARKLE_PRIVATE_KEY_BASE64"]).decode(), end="")
PY
      )"
    fi
    if [[ -n "$sparkle_private_key_payload" ]]; then
      sign_update_output="$(printf "%s\n" "$sparkle_private_key_payload" | "$sparkle_sign_update" --ed-key-file - "$dmg_path")"
    else
      sign_update_output="$("$sparkle_sign_update" "$dmg_path")"
    fi
    sparkle_ed_signature="$(
      sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$sign_update_output" | head -n 1
    )"
  fi
fi

if [[ -z "$sparkle_ed_signature" && "${OPENBURNBAR_SKIP_NOTARY:-0}" != "1" && "${OPENBURNBAR_ALLOW_UNSIGNED_APPCAST:-0}" != "1" ]]; then
  echo "ERROR: Direct-download releases must publish a signed Sparkle appcast. Install Sparkle's sign_update, set SPARKLE_SIGN_UPDATE, or provide OPENBURNBAR_SPARKLE_ED_SIGNATURE." >&2
  exit 1
fi

appcast_args=(
  --version "$version"
  --build "$build"
  --bundle-id "$bundle_id"
  --release-dir "$release_dir"
  --dmg-name "$dmg_name"
  --zip-name "$zip_name"
  --source-archive-name "$source_archive_name"
  --base-url "$update_base_url"
  --commit "$candidate_commit"
  --minimum-system-version "14.0"
  --appcast-name "$appcast_name"
  --latest-name "$latest_name"
)
if [[ -n "$sparkle_ed_signature" ]]; then
  appcast_args+=(--ed-signature "$sparkle_ed_signature")
fi
node scripts/generate-macos-appcast.mjs "${appcast_args[@]}"

python3 scripts/generate-sbom.py --version "$version" --repo-root "$repo_root" --output "$sbom_path"

{
  echo "# OpenBurnBar v${version} macOS release checksums"
  echo "# Generated at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Commit: $candidate_commit"
  echo ""
  shasum -a 256 "$dmg_path"
  shasum -a 512 "$dmg_path"
  shasum -a 256 "$zip_path"
  shasum -a 512 "$zip_path"
  shasum -a 256 "$source_archive_path"
  shasum -a 512 "$source_archive_path"
  shasum -a 256 "$appcast_path"
  shasum -a 512 "$appcast_path"
  shasum -a 256 "$latest_path"
  shasum -a 512 "$latest_path"
  shasum -a 256 "$sbom_path"
  shasum -a 512 "$sbom_path"
} > "$checksums_path"

python3 - <<PY > "$metadata_path"
import datetime
import json

metadata = {
    "version": "$version",
    "build": "$build",
    "bundleId": "$bundle_id",
    "channel": "direct-download",
    "dmg": "$dmg_name",
    "zip": "$zip_name",
    "appcast": "$appcast_name",
    "latestMetadata": "$latest_name",
    "developerIdReceipt": "$(basename "$release_receipt_path")",
    "updateBaseUrl": "$update_base_url",
    "correspondingSource": "$source_archive_name",
    "sparkleEdSignaturePresent": bool("$sparkle_ed_signature"),
    "commit": "$candidate_commit",
    "tree": "$candidate_tree",
    "createdAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
print(json.dumps(metadata, indent=2, sort_keys=True))
PY

if [[ "${OPENBURNBAR_SKIP_NOTARY:-0}" != "1" ]]; then
  spctl --assess --type execute --verbose=2 "$app_path"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
else
  echo "ERROR: OPENBURNBAR_SKIP_NOTARY=1 produced dry-run artifacts only; release certification fails closed." >&2
  exit 1
fi

bash scripts/ci/smoke-openburnbar-release-dmg.sh "$dmg_path"

python3 scripts/ci/create-openburnbar-direct-release-receipt.py \
  --output "$release_receipt_path" \
  --candidate-commit "$candidate_commit" \
  --candidate-tree "$candidate_tree" \
  --version "$version" \
  --build "$build" \
  --team-id "$app_profile_team_id" \
  --signing-receipt "$signing_receipt_path" \
  --app-notary-result "$app_notary_result_path" \
  --app-notary-artifact-name "$app_notary_artifact_name" \
  --app-notary-artifact-sha256 "$app_notary_artifact_sha256" \
  --app-notary-artifact-size "$app_notary_artifact_size" \
  --dmg-notary-result "$dmg_notary_result_path" \
  --dmg-notary-artifact-name "$dmg_notary_artifact_name" \
  --dmg-notary-artifact-sha256 "$dmg_notary_artifact_sha256" \
  --dmg-notary-artifact-size "$dmg_notary_artifact_size" \
  --artifact dmg "$dmg_path" \
  --artifact zip "$zip_path" \
  --artifact sbom "$sbom_path" \
  --artifact correspondingSource "$source_archive_path" \
  --artifact appcast "$appcast_path" \
  --artifact latestMetadata "$latest_path" \
  --artifact checksums "$checksums_path" \
  --artifact releaseMetadata "$metadata_path" \
  --smoke-script "scripts/ci/smoke-openburnbar-release-dmg.sh"

echo "Website/direct-download release ready:"
echo "  Version: $version ($build)"
echo "  App: $app_path"
echo "  DMG: $dmg_path"
echo "  ZIP: $zip_path"
echo "  Appcast: $appcast_path"
echo "  Latest metadata: $latest_path"
echo "  Checksums: $checksums_path"
echo "  SBOM: $sbom_path"
echo "  Corresponding source: $source_archive_path"
echo "  Developer ID receipt: $release_receipt_path"
