#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
source scripts/lib/resolve-repo-path.sh

bash scripts/ci/verify-apple-appcheck-release-env.sh
bash scripts/ci/verify-iroh-release-artifact.sh

configuration="${OPENBURNBAR_CONFIGURATION:-Release}"
scheme="${OPENBURNBAR_SCHEME:-OpenBurnBar}"
project="${OPENBURNBAR_PROJECT:-OpenBurnBar.xcodeproj}"
destination="${OPENBURNBAR_DESTINATION:-platform=macOS,arch=arm64}"
entitlements="AgentLens/Resources/OpenBurnBarRelease.entitlements"
# The appex claims App Groups and Keychain Sharing, both profile-restricted for
# Developer ID, so it carries its own MAC_APP_DIRECT profile. See the
# entitlements file for the full reasoning.
safari_extension_entitlements="OpenBurnBarSafariExtension/Resources/OpenBurnBarSafariExtension.entitlements"
safari_extension_profile="${OPENBURNBAR_SAFARI_EXTENSION_PROFILE:-build/safari-extension-profile/OpenBurnBarSafariExtension-MAC_APP_DIRECT.provisionprofile}"
safari_extension_bundle_id="com.openburnbar.app.safari-extension"
app_profile="${OPENBURNBAR_APP_PROFILE:-build/app-direct-profile/OpenBurnBar-MAC_APP_DIRECT.provisionprofile}"
privileged_input_entitlements="OpenBurnBarDaemon/Resources/PrivilegedInputExecution/OpenBurnBarPrivilegedInputExecution.entitlements"
privileged_input_profile="${OPENBURNBAR_PRIVILEGED_INPUT_PROFILE:-build/hid-managed-profile/OpenBurnBarPrivilegedInputExecution-MAC_APP_DIRECT.provisionprofile}"

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
  resolve_repo_path \
    "$repo_root" \
    "${OPENBURNBAR_WEBSITE_RELEASE_DIR:-build/macos-website-${version}-${build}}"
)"
derived_data="$release_dir/DerivedData"
app_path="$derived_data/Build/Products/$configuration/OpenBurnBar.app"
dmg_name="OpenBurnBar-${version}-macOS.dmg"
dmg_path="$release_dir/$dmg_name"
zip_name="OpenBurnBar-${version}-macOS.zip"
zip_path="$release_dir/$zip_name"
checksums_path="$release_dir/checksums-v${version}.txt"
metadata_path="$release_dir/release-metadata.json"
sbom_path="$release_dir/sbom-v${version}.spdx.json"
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

if [[ ! -f "$entitlements" ]]; then
  echo "ERROR: Missing release entitlements at $entitlements" >&2
  exit 1
fi
if [[ ! -f "$safari_extension_profile" ]]; then
  echo "ERROR: Missing Safari extension provisioning profile at $safari_extension_profile. Set OPENBURNBAR_SAFARI_EXTENSION_PROFILE to the MAC_APP_DIRECT profile for $safari_extension_bundle_id." >&2
  exit 1
fi
if [[ ! -f "$safari_extension_entitlements" ]]; then
  echo "ERROR: Missing Safari extension entitlements at $safari_extension_entitlements" >&2
  exit 1
fi
if [[ ! -f "$app_profile" ]]; then
  echo "ERROR: Missing app Developer ID provisioning profile at $app_profile. Set OPENBURNBAR_APP_PROFILE to the MAC_APP_DIRECT profile for com.openburnbar.app." >&2
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

if [[ "${OPENBURNBAR_SKIP_XCODE_BUILD:-0}" != "1" ]]; then
  rm -rf "$release_dir"
fi
mkdir -p "$release_dir"

privileged_input_profile_plist="$release_dir/privileged-input-profile.plist"
privileged_input_signing_entitlements="$release_dir/privileged-input-entitlements.plist"
app_profile_plist="$release_dir/app-profile.plist"
app_signing_entitlements="$release_dir/app-signing-entitlements.plist"
security cms -D -i "$app_profile" > "$app_profile_plist"
if [[ "$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$app_profile_plist" 2>/dev/null || true)" != "true" ]]; then
  echo "ERROR: App profile must be a Developer ID / MAC_APP_DIRECT all-devices profile." >&2
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
if [[ "${OPENBURNBAR_SKIP_XCODE_BUILD:-0}" != "1" ]]; then
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
else
  echo "WARNING: OPENBURNBAR_SKIP_XCODE_BUILD=1; reusing existing app at $app_path." >&2
fi

if [[ ! -d "$app_path" ]]; then
  echo "ERROR: App build missing at $app_path" >&2
  exit 1
fi

helpers_dir="$app_path/Contents/Helpers"
frameworks_dir="$app_path/Contents/Frameworks"
safari_extension_appex="$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
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
for helper in "$helpers_dir/OpenBurnBarDaemon" "$helpers_dir/OpenBurnBarCLI"; do
  if otool -L "$helper" | grep -Eq 'libsqlcipher[^/]*\.dylib'; then
    echo "ERROR: $(basename "$helper") links an external libsqlcipher dylib; Apple releases must use the embedded SQLCipher.framework only." >&2
    otool -L "$helper" >&2
    exit 1
  fi
done
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
if [[ "$bundle_id" != "com.openburnbar.app" || "$app_version" != "$version" || "$app_build" != "$build" ]]; then
  echo "ERROR: App metadata mismatch: bundle=$bundle_id version=$app_version build=$app_build expected com.openburnbar.app $version $build" >&2
  exit 1
fi
app_profile_team_id="$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$app_profile_plist" 2>/dev/null || true)"
app_profile_identifier="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$app_profile_plist" 2>/dev/null || true)"
expected_app_identifier="${app_profile_team_id}.${bundle_id}"
if [[ ! "$app_profile_team_id" =~ ^[A-Z0-9]{10}$ || "$app_profile_identifier" != "$expected_app_identifier" ]]; then
  echo "ERROR: App profile must authorize $bundle_id for team ${app_profile_team_id:-<missing>}; found application identifier '${app_profile_identifier:-missing}'." >&2
  exit 1
fi
app_profile_keychain_groups="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups" "$app_profile_plist" 2>/dev/null || true)"
if ! grep -q "${app_profile_team_id}\\.\\*\\|${expected_app_identifier}" <<<"$app_profile_keychain_groups"; then
  echo "ERROR: App profile does not authorize the $expected_app_identifier Keychain access group." >&2
  printf '%s\n' "$app_profile_keychain_groups" >&2
  exit 1
fi
# The appex profile must authorize exactly what its entitlements claim. Verifying
# the claims against the profile here means a mismatch fails the release rather
# than shipping a signature macOS refuses to launch.
safari_extension_profile_plist="$release_dir/safari-extension-profile.plist"
security cms -D -i "$safari_extension_profile" > "$safari_extension_profile_plist"
if [[ "$(/usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$safari_extension_profile_plist" 2>/dev/null || true)" != "true" ]]; then
  echo "ERROR: Safari extension profile must be a Developer ID / MAC_APP_DIRECT all-devices profile." >&2
  exit 1
fi
safari_extension_profile_team_id="$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$safari_extension_profile_plist" 2>/dev/null || true)"
safari_extension_profile_identifier="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$safari_extension_profile_plist" 2>/dev/null || true)"
expected_safari_extension_identifier="${safari_extension_profile_team_id}.${safari_extension_bundle_id}"
if [[ "$safari_extension_profile_team_id" != "$app_profile_team_id" ]]; then
  echo "ERROR: Safari extension profile team '${safari_extension_profile_team_id:-<missing>}' does not match the app profile team '$app_profile_team_id'; the appex could not share the app's group or Keychain." >&2
  exit 1
fi
if [[ "$safari_extension_profile_identifier" != "$expected_safari_extension_identifier" ]]; then
  echo "ERROR: Safari extension profile must authorize $safari_extension_bundle_id; found application identifier '${safari_extension_profile_identifier:-missing}'." >&2
  exit 1
fi
safari_extension_profile_groups="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.security.application-groups" "$safari_extension_profile_plist" 2>/dev/null || true)"
# Exact match on purpose. A team-prefixed wildcard (${team}.*) is a DIFFERENT
# application-group namespace and does not authorize the unprefixed group the
# appex claims, so accepting it would sign an extension macOS rejects at
# runtime — the failure this gate exists to prevent.
if ! grep -qx "[[:space:]]*group\.com\.openburnbar\.app[[:space:]]*" <<<"$safari_extension_profile_groups"; then
  echo "ERROR: Safari extension profile does not authorize the group.com.openburnbar.app App Group (a ${safari_extension_profile_team_id}.* wildcard does not count)." >&2
  printf '%s\n' "$safari_extension_profile_groups" >&2
  exit 1
fi
safari_extension_profile_keychain_groups="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups" "$safari_extension_profile_plist" 2>/dev/null || true)"
if ! grep -q "${safari_extension_profile_team_id}\.\*\|${expected_app_identifier}" <<<"$safari_extension_profile_keychain_groups"; then
  echo "ERROR: Safari extension profile does not authorize the $expected_app_identifier Keychain access group the appex shares with the host app." >&2
  printf '%s\n' "$safari_extension_profile_keychain_groups" >&2
  exit 1
fi
safari_extension_signing_entitlements="$release_dir/safari-extension-entitlements.plist"

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

python3 - "$safari_extension_entitlements" "$safari_extension_signing_entitlements" "$app_profile_team_id" "$safari_extension_bundle_id" <<'PY'
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

# The Safari web extension. Nested code must be signed before the bundle that
# contains it, so this runs ahead of the host signature below. The xcodebuild step
# above ran with CODE_SIGNING_ALLOWED=NO, which means the appex arrives unsigned:
# skipping it here would fail `codesign --verify --deep --strict` a few lines down
# and, worse, would reproduce the class of bug this target was added to fix — the
# extension being committed but reaching no release.
if [[ ! -d "$safari_extension_appex" ]]; then
  echo "ERROR: Safari extension missing at $safari_extension_appex. The OpenBurnBarSafariExtension target must build and embed into Contents/PlugIns." >&2
  exit 1
fi
if [[ ! -f "$safari_extension_appex/Contents/Resources/manifest.json" ]]; then
  echo "ERROR: Safari extension at $safari_extension_appex has no Contents/Resources/manifest.json; the extensions/safari/dist copy did not run." >&2
  exit 1
fi
# An appex claiming profile-restricted entitlements must carry the profile that
# authorizes them, or macOS refuses to load the extension at runtime.
cp "$safari_extension_profile" "$safari_extension_appex/Contents/embedded.provisionprofile"
sign_one_with_entitlements \
  "$safari_extension_appex" \
  "$safari_extension_signing_entitlements" \
  "runtime,library" \
  "$safari_extension_bundle_id"
bash scripts/ci/verify-signing-profile-certificate.sh "$safari_extension_appex" "$safari_extension_profile"

cp "$app_profile" "$app_path/Contents/embedded.provisionprofile"
codesign --force --timestamp --options runtime,library \
  --entitlements "$app_signing_entitlements" \
  --sign "$identity" \
  "$app_path"
bash scripts/ci/verify-signing-profile-certificate.sh "$app_path" "$app_profile"
codesign --verify --deep --strict --verbose=2 "$app_path"
assert_peer_signature "$app_path" "com.openburnbar.app"
assert_peer_signature "$helpers_dir/OpenBurnBarDaemon" "com.openburnbar.app"
assert_peer_signature "$helpers_dir/OpenBurnBarCLI" "com.openburnbar.cli"
assert_peer_signature "$helpers_dir/OpenBurnBarVirtualHIDBridge" "com.openburnbar.virtual-hid-bridge"
assert_peer_signature "$helpers_dir/OpenBurnBarPrivilegedInputExecution" "com.openburnbar.privileged-input-execution"
assert_peer_signature \
  "$helpers_dir/OpenBurnBarPrivilegedInputKillSwitchWatchdog" \
  "com.openburnbar.privileged-input-killswitch-watchdog"
assert_peer_signature "$safari_extension_appex" "com.openburnbar.app.safari-extension"

bash scripts/ci/verify-daemon-release-signing.sh "$app_path" "$app_profile_team_id"

actual_entitlements="$release_dir/direct-entitlements.plist"
codesign -d --entitlements :- "$app_path" > "$actual_entitlements" 2>/dev/null
app_sandbox="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$actual_entitlements" 2>/dev/null || true)"
if [[ "$app_sandbox" != "false" ]]; then
  echo "ERROR: Direct-download app must not be sandboxed; found '${app_sandbox:-missing}'." >&2
  exit 1
fi
actual_app_identifier="$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" "$actual_entitlements" 2>/dev/null || true)"
actual_team_identifier="$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.team-identifier" "$actual_entitlements" 2>/dev/null || true)"
actual_keychain_groups="$(/usr/libexec/PlistBuddy -c "Print :keychain-access-groups" "$actual_entitlements" 2>/dev/null || true)"
if [[ "$actual_app_identifier" != "$expected_app_identifier" || "$actual_team_identifier" != "$app_profile_team_id" ]]; then
  echo "ERROR: Direct-download app identity entitlements are wrong: app='${actual_app_identifier:-missing}' team='${actual_team_identifier:-missing}' expected app='$expected_app_identifier' team='$app_profile_team_id'." >&2
  exit 1
fi
if ! grep -q "$expected_app_identifier" <<<"$actual_keychain_groups"; then
  echo "ERROR: Direct-download app is missing Firebase Auth Keychain group $expected_app_identifier." >&2
  printf '%s\n' "$actual_keychain_groups" >&2
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
ditto -c -k --keepParent "$(basename "$app_path")" "$zip_path"
cd "$repo_root"

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
  --commit "$(git rev-parse HEAD)"
  --minimum-system-version "14.0"
  --appcast-name "$appcast_name"
  --latest-name "$latest_name"
)
if [[ -n "$sparkle_ed_signature" ]]; then
  appcast_args+=(--ed-signature "$sparkle_ed_signature")
fi
node scripts/generate-macos-appcast.mjs "${appcast_args[@]}"

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
  shasum -a 256 "$appcast_path"
  shasum -a 512 "$appcast_path"
  shasum -a 256 "$latest_path"
  shasum -a 512 "$latest_path"
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
    "appcast": "$appcast_name",
    "latestMetadata": "$latest_name",
    "updateBaseUrl": "$update_base_url",
    "correspondingSource": "$source_archive_name",
    "sparkleEdSignaturePresent": bool("$sparkle_ed_signature"),
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
echo "  Appcast: $appcast_path"
echo "  Latest metadata: $latest_path"
echo "  Checksums: $checksums_path"
echo "  SBOM: $sbom_path"
echo "  Corresponding source: $source_archive_path"
