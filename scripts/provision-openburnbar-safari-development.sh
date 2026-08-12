#!/usr/bin/env bash

# Build one exact OpenBurnBar candidate with target-scoped Apple Development
# automatic provisioning, export the embedded host/Safari profiles byte-for-byte,
# verify the signed product, and emit a sanitized candidate-bound receipt.
#
# This command is intentionally fail-closed:
# - candidate commit, candidate tree, team, and identity are mandatory;
# - the exact candidate must be clean and checked out;
# - exactly one valid keychain identity must match the requested full name;
# - output and DerivedData are fresh, caller-owned, and outside the source tree;
# - there is no unsigned, ad-hoc, or "first available identity" fallback.

set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
# shellcheck source=scripts/lib/exact-candidate-git.sh
source "$repo_root/scripts/lib/exact-candidate-git.sh"

candidate_commit=""
candidate_tree=""
team_id=""
signing_identity=""
output_dir=""
derived_data_dir=""
package_cache="$repo_root/.spm-cache"
project_path="$repo_root/OpenBurnBar.xcodeproj"
configuration="Release"
host_target="OpenBurnBar"
safari_target="OpenBurnBarSafariExtension"

usage() {
  cat <<'EOF'
Usage: scripts/provision-openburnbar-safari-development.sh \
  --candidate-commit <40-character Git SHA> \
  --candidate-tree <40-character Git tree SHA> \
  --team-id <10-character Apple team ID> \
  --signing-identity "Apple Development: Name (CERTIFICATE-ID)" \
  --output-dir <absolute fresh directory> \
  [--derived-data <absolute fresh directory>] \
  [--package-cache <path>] \
  [--project <path>] \
  [--configuration <name>]

The command uses Xcode automatic provisioning for exactly the
OpenBurnBarSafariExtension and OpenBurnBar macOS targets. It may create or
download development profiles and register the current Mac when Apple permits
that operation. It never falls back to another identity or an unsigned build.

Outputs:
  <output-dir>/OpenBurnBar.app
  <output-dir>/profiles/OpenBurnBar-host.provisionprofile
  <output-dir>/profiles/OpenBurnBar-Safari.provisionprofile
  <output-dir>/development-receipt.json
  <output-dir>/xcodebuild.log

Environment overrides are intended only for deterministic fixture tests:
  OPENBURNBAR_GIT_BIN
  OPENBURNBAR_SECURITY_BIN
  OPENBURNBAR_XCODEBUILD_BIN
  OPENBURNBAR_DITTO_BIN
  OPENBURNBAR_PYTHON_BIN
  OPENBURNBAR_PLIST_BUDDY_BIN
  OPENBURNBAR_SYSTEM_PROFILER_BIN
  OPENBURNBAR_PREPARE_SWIFTPM_SCRIPT
  OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_SCRIPT
  OPENBURNBAR_LIBSIGNAL_COMPAT_SCRIPT
  OPENBURNBAR_DEVELOPMENT_SIGNING_VERIFIER
  OPENBURNBAR_DEVELOPMENT_RECEIPT_WRITER
  OPENBURNBAR_MAC_UDID_PARSER
EOF
}

fail_usage() {
  echo "ERROR: $*" >&2
  usage >&2
  exit 64
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --candidate-commit)
      candidate_commit="${2:-}"
      shift 2
      ;;
    --candidate-tree)
      candidate_tree="${2:-}"
      shift 2
      ;;
    --team-id)
      team_id="${2:-}"
      shift 2
      ;;
    --signing-identity)
      signing_identity="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --derived-data)
      derived_data_dir="${2:-}"
      shift 2
      ;;
    --package-cache)
      package_cache="${2:-}"
      shift 2
      ;;
    --project)
      project_path="${2:-}"
      shift 2
      ;;
    --configuration)
      configuration="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail_usage "Unknown option: $1"
      ;;
  esac
done

for required_name in \
  candidate_commit \
  candidate_tree \
  team_id \
  signing_identity \
  output_dir; do
  if [[ -z "${!required_name}" ]]; then
    fail_usage "--${required_name//_/-} is required."
  fi
done

if [[ ! "$candidate_commit" =~ ^[0-9a-f]{40}$ ]]; then
  fail_usage "--candidate-commit must be a full lowercase 40-character Git SHA."
fi
if [[ ! "$candidate_tree" =~ ^[0-9a-f]{40}$ ]]; then
  fail_usage "--candidate-tree must be a full lowercase 40-character Git SHA."
fi
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  fail_usage "--team-id must be exactly 10 uppercase letters or digits."
fi
if [[ "$signing_identity" == *$'\n'* || "$signing_identity" == *$'\r'* ]]; then
  fail_usage "--signing-identity must be exactly one line."
fi
identity_prefix="Apple Development: "
identity_subject="${signing_identity#"$identity_prefix"}"
if [[ "$identity_subject" == "$signing_identity" || -z "$identity_subject" ]]; then
  fail_usage "--signing-identity must be one exact Apple Development identity."
fi
if [[ -z "$configuration" || "$configuration" == *$'\n'* || "$configuration" == *$'\r'* ]]; then
  fail_usage "--configuration must be a non-empty single-line value."
fi

git_bin="${OPENBURNBAR_GIT_BIN:-git}"
security_bin="${OPENBURNBAR_SECURITY_BIN:-security}"
xcodebuild_bin="${OPENBURNBAR_XCODEBUILD_BIN:-xcodebuild}"
ditto_bin="${OPENBURNBAR_DITTO_BIN:-ditto}"
python_bin="${OPENBURNBAR_PYTHON_BIN:-python3}"
plist_buddy_bin="${OPENBURNBAR_PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"
system_profiler_bin="${OPENBURNBAR_SYSTEM_PROFILER_BIN:-/usr/sbin/system_profiler}"
prepare_swiftpm_script="${OPENBURNBAR_PREPARE_SWIFTPM_SCRIPT:-$repo_root/scripts/prepare-openburnbar-app-swiftpm.sh}"
google_compat_script="${OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_SCRIPT:-$repo_root/scripts/lib/googlesignin-macos-compat.sh}"
libsignal_compat_script="${OPENBURNBAR_LIBSIGNAL_COMPAT_SCRIPT:-$repo_root/scripts/lib/libsignal-swift-compat.sh}"
development_verifier="${OPENBURNBAR_DEVELOPMENT_SIGNING_VERIFIER:-$repo_root/scripts/ci/verify-openburnbar-development-signing.sh}"
receipt_writer="${OPENBURNBAR_DEVELOPMENT_RECEIPT_WRITER:-$repo_root/scripts/ci/create-openburnbar-development-receipt.py}"
mac_udid_parser="${OPENBURNBAR_MAC_UDID_PARSER:-$repo_root/scripts/lib/parse-macos-provisioning-udid.py}"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Required command is unavailable: $command_name"
  fi
}

for required_command in \
  "$git_bin" \
  "$security_bin" \
  "$xcodebuild_bin" \
  "$ditto_bin" \
  "$python_bin" \
  "$plist_buddy_bin" \
  "$system_profiler_bin"; do
  require_command "$required_command"
done
openburnbar_configure_exact_candidate_git "$repo_root"
for required_file in \
  "$prepare_swiftpm_script" \
  "$google_compat_script" \
  "$libsignal_compat_script" \
  "$development_verifier" \
  "$receipt_writer" \
  "$mac_udid_parser"; do
  if [[ ! -f "$required_file" || -L "$required_file" ]]; then
    fail "Required provisioning input must be a real file: $required_file"
  fi
done

if [[ "$project_path" != /* ]]; then
  project_path="$repo_root/$project_path"
fi
if [[ "$package_cache" != /* ]]; then
  package_cache="$repo_root/$package_cache"
fi
if [[ ! -d "$project_path" || -L "$project_path" ]]; then
  fail "Xcode project must be a real directory: $project_path"
fi
project_path="$(cd "$project_path" && pwd -P)"
case "$project_path/" in
  "$repo_root/"*) ;;
  *) fail "Xcode project must be inside the exact candidate checkout." ;;
esac

verify_exact_candidate_state() {
  if ! openburnbar_candidate_git cat-file -e "$candidate_commit^{commit}" 2>/dev/null; then
    fail "Candidate commit is missing from the exact checkout: $candidate_commit"
  fi
  if ! openburnbar_candidate_git cat-file -e "$candidate_tree^{tree}" 2>/dev/null; then
    fail "Candidate tree is missing from the exact checkout: $candidate_tree"
  fi

  local actual_commit actual_tree commit_tree worktree_state
  actual_commit="$(openburnbar_candidate_git rev-parse "HEAD^{commit}")"
  actual_tree="$(openburnbar_candidate_git rev-parse "HEAD^{tree}")"
  commit_tree="$(openburnbar_candidate_git rev-parse "$candidate_commit^{tree}")"
  if [[ "$actual_commit" != "$candidate_commit" ]]; then
    fail "Checked-out commit $actual_commit does not match candidate commit $candidate_commit."
  fi
  if [[ "$actual_tree" != "$candidate_tree" || "$commit_tree" != "$candidate_tree" ]]; then
    fail "Candidate tree mismatch: HEAD=$actual_tree commit=$commit_tree expected=$candidate_tree."
  fi
  worktree_state="$(
    openburnbar_candidate_git status \
      --porcelain=v1 \
      --untracked-files=normal \
      --ignore-submodules=none
  )"
  if [[ -n "$worktree_state" ]]; then
    echo "ERROR: Exact Apple Development provisioning requires a clean candidate checkout:" >&2
    printf '%s\n' "$worktree_state" >&2
    exit 1
  fi
}

verify_exact_candidate_state

identity_matches=()
while IFS= read -r identity_line; do
  if [[ "$identity_line" == *"\"$signing_identity\""* &&
    "$identity_line" =~ ([0-9A-Fa-f]{40}) ]]
  then
    identity_matches+=("$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')")
  fi
done < <("$security_bin" find-identity -v -p codesigning)
if ((${#identity_matches[@]} == 0)); then
  fail "The exact Apple Development identity is not available in the signing keychain: $signing_identity"
fi
if ((${#identity_matches[@]} != 1)); then
  fail "The exact Apple Development identity is ambiguous (${#identity_matches[@]} valid matches): $signing_identity"
fi
signing_identity_sha1="${identity_matches[0]}"

canonical_fresh_output() {
  local raw_path="$1"
  local label="$2"
  if [[ "$raw_path" != /* ]]; then
    fail "$label must be an absolute path."
  fi
  if [[ -e "$raw_path" || -L "$raw_path" ]]; then
    fail "$label must not already exist: $raw_path"
  fi
  local parent_path
  parent_path="$(dirname "$raw_path")"
  if [[ ! -d "$parent_path" || -L "$parent_path" ]]; then
    fail "$label parent must be a real existing directory: $parent_path"
  fi
  local parent_real
  parent_real="$(cd "$parent_path" && pwd -P)"
  printf '%s/%s\n' "$parent_real" "$(basename "$raw_path")"
}

output_dir="$(canonical_fresh_output "$output_dir" "Output directory")"
case "$output_dir/" in
  "$repo_root/"*) fail "Output directory must be outside the exact candidate checkout." ;;
esac
mkdir -m 700 "$output_dir"

if [[ -z "$derived_data_dir" ]]; then
  derived_data_dir="$output_dir/DerivedData"
else
  derived_data_dir="$(
    canonical_fresh_output "$derived_data_dir" "DerivedData directory"
  )"
  case "$derived_data_dir/" in
    "$repo_root/"*) fail "DerivedData directory must be outside the exact candidate checkout." ;;
  esac
fi
if [[ "$derived_data_dir" == "$output_dir" ]]; then
  fail "DerivedData and output directories must be distinct."
fi
mkdir -m 700 "$derived_data_dir"

if [[ -e "$package_cache" ]]; then
  if [[ ! -d "$package_cache" || -L "$package_cache" ]]; then
    fail "SwiftPM package cache must be a real directory: $package_cache"
  fi
  package_cache="$(cd "$package_cache" && pwd -P)"
else
  package_cache_parent="$(dirname "$package_cache")"
  if [[ ! -d "$package_cache_parent" || -L "$package_cache_parent" ]]; then
    fail "SwiftPM package-cache parent must be a real existing directory: $package_cache_parent"
  fi
  package_cache="$(cd "$package_cache_parent" && pwd -P)/$(basename "$package_cache")"
  mkdir -m 700 "$package_cache"
fi

# shellcheck source=/dev/null
source "$google_compat_script"
# shellcheck source=/dev/null
source "$libsignal_compat_script"
for required_function in \
  openburnbar_prepare_google_sign_in_macos_compat \
  openburnbar_restore_google_sign_in_macos_compat \
  openburnbar_prepare_libsignal_swift_compat \
  openburnbar_restore_libsignal_swift_compat; do
  if ! declare -F "$required_function" >/dev/null; then
    fail "Compatibility script did not define required function: $required_function"
  fi
done

cleanup() {
  local original_status="${1:-0}"
  local google_status=0
  local libsignal_status=0
  openburnbar_restore_google_sign_in_macos_compat || google_status=$?
  openburnbar_restore_libsignal_swift_compat || libsignal_status=$?
  local restore_status="$google_status"
  if ((restore_status == 0)); then
    restore_status="$libsignal_status"
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
trap 'exit 130' INT
trap 'exit 143' TERM

bash "$prepare_swiftpm_script" \
  --project "$project_path" \
  --scheme "$host_target" \
  --cache-dir "$package_cache" \
  --derived-data "$derived_data_dir"
openburnbar_prepare_google_sign_in_macos_compat "$package_cache"
openburnbar_prepare_libsignal_swift_compat "$repo_root"

build_products="$output_dir/build-products"
mkdir -m 700 "$build_products"
build_log="$output_dir/xcodebuild.log"
: >"$build_log"

common_build_args=(
  -project "$project_path"
  -configuration "$configuration"
  -sdk macosx
  -clonedSourcePackagesDirPath "$package_cache"
  -derivedDataPath "$derived_data_dir"
  -disableAutomaticPackageResolution
  -onlyUsePackageVersionsFromResolvedFile
  -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
  CONFIGURATION_BUILD_DIR="$build_products"
  CODE_SIGN_STYLE=Automatic
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGNING_REQUIRED=YES
  DEVELOPMENT_TEAM="$team_id"
  CODE_SIGN_IDENTITY="$signing_identity_sha1"
  PROVISIONING_PROFILE=
  PROVISIONING_PROFILE_SPECIFIER=
)

run_target_build() {
  local target="$1"
  {
    printf '=== target %s ===\n' "$target"
    "$xcodebuild_bin" build \
      "${common_build_args[@]}" \
      -target "$target"
  } 2>&1 | tee -a "$build_log"
}

# Provision the nested extension explicitly before the containing host. The
# second target build embeds the already provisioned appex into the signed app.
run_target_build "$safari_target"
run_target_build "$host_target"

built_app="$build_products/OpenBurnBar.app"
if [[ ! -d "$built_app" || -L "$built_app" ]]; then
  fail "Target-scoped build did not produce a real OpenBurnBar.app: $built_app"
fi
built_appex="$built_app/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
if [[ ! -d "$built_appex" || -L "$built_appex" ]]; then
  fail "Signed host is missing the real OpenBurnBar Safari appex: $built_appex"
fi

safari_appex_count="$(
  find "$built_app/Contents/PlugIns" \
    -type d \
    -name "OpenBurnBarSafariExtension.appex" \
    -print0 \
    | "$python_bin" -c 'import sys; print(len([item for item in sys.stdin.buffer.read().split(b"\0") if item]))'
)"
if [[ "$safari_appex_count" != "1" ]]; then
  fail "Signed host contains $safari_appex_count Safari appex candidates; exactly one is required."
fi
embedded_extension_profile_count="$(
  find "$built_app/Contents/PlugIns" \
    -type f \
    -name "embedded.provisionprofile" \
    -print0 \
    | "$python_bin" -c 'import sys; print(len([item for item in sys.stdin.buffer.read().split(b"\0") if item]))'
)"
if [[ "$embedded_extension_profile_count" != "1" ]]; then
  fail "Signed host contains $embedded_extension_profile_count embedded extension profiles; exactly one Safari profile is required."
fi

embedded_host_profile="$built_app/Contents/embedded.provisionprofile"
embedded_safari_profile="$built_appex/Contents/embedded.provisionprofile"
for profile_path in "$embedded_host_profile" "$embedded_safari_profile"; do
  if [[ ! -f "$profile_path" || -L "$profile_path" || ! -s "$profile_path" ]]; then
    fail "Expected a non-empty, real embedded Apple Development profile: $profile_path"
  fi
done

# Restore temporary package-source compatibility patches before provenance is
# re-checked or a candidate-bound artifact/receipt is materialized.
openburnbar_restore_google_sign_in_macos_compat
openburnbar_restore_libsignal_swift_compat
verify_exact_candidate_state

artifact_app="$output_dir/OpenBurnBar.app"
"$ditto_bin" "$built_app" "$artifact_app"
if [[ ! -d "$artifact_app" || -L "$artifact_app" ]]; then
  fail "Could not materialize the isolated signed development app: $artifact_app"
fi

profiles_dir="$output_dir/profiles"
mkdir -m 700 "$profiles_dir"
host_profile_export="$profiles_dir/OpenBurnBar-host.provisionprofile"
safari_profile_export="$profiles_dir/OpenBurnBar-Safari.provisionprofile"
install -m 600 \
  "$artifact_app/Contents/embedded.provisionprofile" \
  "$host_profile_export"
install -m 600 \
  "$artifact_app/Contents/PlugIns/OpenBurnBarSafariExtension.appex/Contents/embedded.provisionprofile" \
  "$safari_profile_export"
if ! cmp -s \
  "$host_profile_export" \
  "$artifact_app/Contents/embedded.provisionprofile"; then
  fail "Exported host profile bytes differ from the embedded profile."
fi
if ! cmp -s \
  "$safari_profile_export" \
  "$artifact_app/Contents/PlugIns/OpenBurnBarSafariExtension.appex/Contents/embedded.provisionprofile"; then
  fail "Exported Safari profile bytes differ from the embedded profile."
fi

bash "$development_verifier" \
  "$artifact_app" \
  "$team_id" \
  "$host_profile_export" \
  "$safari_profile_export" \
  "$signing_identity" \
  "$signing_identity_sha1"

if ! current_mac_provisioning_udid="$(
  "$system_profiler_bin" SPHardwareDataType -json 2>/dev/null \
    | "$python_bin" "$mac_udid_parser" 2>/dev/null
)"; then
  fail "Could not determine this Mac's exact provisioning UDID for the development receipt."
fi

app_info="$artifact_app/Contents/Info.plist"
if [[ ! -f "$app_info" || -L "$app_info" ]]; then
  fail "Signed development app is missing a real Info.plist: $app_info"
fi
version="$("$plist_buddy_bin" -c "Print :CFBundleShortVersionString" "$app_info")"
build="$("$plist_buddy_bin" -c "Print :CFBundleVersion" "$app_info")"
if [[ -z "$version" || -z "$build" ||
  "$version" == *$'\n'* || "$version" == *$'\r'* ||
  "$build" == *$'\n'* || "$build" == *$'\r'* ]]
then
  fail "Signed development app version/build metadata is missing or malformed."
fi

receipt_path="$output_dir/development-receipt.json"
"$python_bin" "$receipt_writer" \
  --output "$receipt_path" \
  --candidate-commit "$candidate_commit" \
  --candidate-tree "$candidate_tree" \
  --app "$artifact_app" \
  --host-profile "$host_profile_export" \
  --safari-profile "$safari_profile_export" \
  --team-id "$team_id" \
  --signing-identity "$signing_identity" \
  --signing-certificate-sha1 "$signing_identity_sha1" \
  --current-mac-provisioning-udid "$current_mac_provisioning_udid" \
  --version "$version" \
  --build "$build"
if [[ ! -f "$receipt_path" || -L "$receipt_path" || ! -s "$receipt_path" ]]; then
  fail "Development receipt writer did not produce a real non-empty receipt: $receipt_path"
fi

echo "PASS: exact OpenBurnBar Apple Development candidate provisioned and verified."
echo "  Candidate commit: $candidate_commit"
echo "  Candidate tree:   $candidate_tree"
echo "  Team:             $team_id"
echo "  Identity:         $signing_identity"
echo "  App:              $artifact_app"
echo "  Host profile:     $host_profile_export"
echo "  Safari profile:   $safari_profile_export"
echo "  Receipt:          $receipt_path"
