#!/usr/bin/env bash
#
# Ensure Xcode-based OpenBurnBar tests can link libsignal FFI.
#
# SwiftPM-only tests can pass an unsafe -L flag to Vendor/libsignal/target, but
# Xcode app/mobile targets resolve the Swift package as a normal dependency.
# Materializing the XCFramework lets Package.swift attach the binary target and
# keeps app/mobile test linking on the same path production builds use.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
libsignal_dir="$repo_root/Vendor/libsignal"
ios_xcframework="$repo_root/Vendor/OpenBurnBarSignalFfiIOS.xcframework"
macos_xcframework="$repo_root/Vendor/OpenBurnBarSignalFfiMac.xcframework"
legacy_xcframework="$repo_root/Vendor/OpenBurnBarSignalFfi.xcframework"
build_script="$repo_root/scripts/build-signal-ffi-xcframework.sh"
metadata_file_name=".openburnbar-signal-ffi-build.env"

# The build script historically writes small staging files under
# build/signal-ffi-xcframework and large Rust intermediates under the vendored
# submodule's target/.  Physical-device XCTest runs can redirect both roots to
# a caller-owned scratch directory.  Keep the aliases here so callers can set
# either the public SIGNAL_FFI_* names or the OpenBurnBar-prefixed names.
resolve_root_override() {
  local canonical_name="$1"
  local alias_name="$2"
  local raw=""

  if [[ "${!canonical_name+x}" == "x" ]]; then
    raw="${!canonical_name}"
  elif [[ "${!alias_name+x}" == "x" ]]; then
    raw="${!alias_name}"
  fi

  if [[ -z "$raw" ]]; then
    if [[ "${!canonical_name+x}" == "x" || "${!alias_name+x}" == "x" ]]; then
      echo "${canonical_name} cannot be empty." >&2
      exit 64
    fi
    return 0
  fi

  if [[ "$raw" != /* ]]; then
    echo "${canonical_name} must be an absolute path: ${raw}" >&2
    exit 64
  fi

  # Resolve existing symlink components before the child build script creates
  # anything. This keeps a configured scratch root from escaping through a
  # pre-existing symlink.
  python3 - "$raw" <<'PY'
import os
import sys

resolved = os.path.realpath(sys.argv[1])
if not resolved.startswith('/'):
    raise SystemExit(64)
print(resolved)
PY
}

signal_ffi_build_root="$(resolve_root_override SIGNAL_FFI_BUILD_ROOT OPENBURNBAR_SIGNAL_FFI_BUILD_ROOT)"
signal_ffi_cargo_target_root="$(resolve_root_override SIGNAL_FFI_CARGO_TARGET_ROOT OPENBURNBAR_SIGNAL_FFI_CARGO_TARGET_ROOT)"

# Supplying one root is enough to keep the entire FFI build isolated. Explicit
# values for both roots remain supported for callers that partition staging and
# Cargo output onto separate volumes.
if [[ -n "$signal_ffi_build_root" && -z "$signal_ffi_cargo_target_root" ]]; then
  signal_ffi_cargo_target_root="$signal_ffi_build_root/cargo-target"
elif [[ -z "$signal_ffi_build_root" && -n "$signal_ffi_cargo_target_root" ]]; then
  signal_ffi_build_root="$signal_ffi_cargo_target_root/build"
fi

resolve_requested_profile() {
  if [[ -n "${SIGNAL_FFI_BUILD_PROFILE:-}" ]]; then
    case "${SIGNAL_FFI_BUILD_PROFILE}" in
      debug | release) printf '%s\n' "${SIGNAL_FFI_BUILD_PROFILE}" ;;
      *)
        echo "Invalid SIGNAL_FFI_BUILD_PROFILE=${SIGNAL_FFI_BUILD_PROFILE}; expected debug or release." >&2
        exit 64
        ;;
    esac
    return
  fi

  if [[ "${CONFIGURATION:-}" == "Release" ]] || [[ "${CONFIG:-}" == "Release" ]] ||
    [[ "${OPENBURNBAR_RELEASE_BUILD:-}" == "1" ]] || [[ "${OPENBURNBAR_RELEASE_BUILD:-}" == "YES" ]] ||
    [[ "${GITHUB_WORKFLOW:-}" == "OpenBurnBar Release" ]]; then
    printf 'release\n'
  else
    printf 'debug\n'
  fi
}

requested_profile="$(resolve_requested_profile)"

DEFAULT_SIGNAL_FFI_BUILD_TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)
if [[ -n "${SIGNAL_FFI_BUILD_TARGETS:-}" ]]; then
  # shellcheck disable=SC2206
  requested_targets=(${SIGNAL_FFI_BUILD_TARGETS})
else
  requested_targets=("${DEFAULT_SIGNAL_FFI_BUILD_TARGETS[@]}")
fi

needs_ios_xcframework=0
needs_macos_xcframework=0
for target in "${requested_targets[@]}"; do
  case "$target" in
    *-apple-ios*) needs_ios_xcframework=1 ;;
    *-apple-darwin*) needs_macos_xcframework=1 ;;
  esac
done

metadata_value() {
  local metadata_file="$1"
  local key="$2"
  local metadata_key
  local metadata_value
  while IFS='=' read -r metadata_key metadata_value; do
    if [[ "$metadata_key" == "$key" ]]; then
      printf '%s\n' "$metadata_value"
      return
    fi
  done < "$metadata_file"
}

target_list_contains() {
  local target_list="$1"
  local target="$2"
  case " ${target_list} " in
    *" ${target} "*) return 0 ;;
    *) return 1 ;;
  esac
}

artifact_matches_requested_build() {
  local artifact_dir="$1"
  local metadata_file="${artifact_dir}/${metadata_file_name}"
  local artifact_profile
  local artifact_targets

  if [[ ! -f "$metadata_file" ]]; then
    echo ">>> Signal FFI artifact metadata missing for ${artifact_dir}; rebuilding."
    return 1
  fi

  artifact_profile="$(metadata_value "$metadata_file" profile)"
  artifact_targets="$(metadata_value "$metadata_file" targets)"
  if [[ "$artifact_profile" != "$requested_profile" ]]; then
    echo ">>> Signal FFI artifact profile ${artifact_profile:-<missing>} does not match requested ${requested_profile}; rebuilding."
    return 1
  fi

  for target in "${requested_targets[@]}"; do
    if ! target_list_contains "$artifact_targets" "$target"; then
      echo ">>> Signal FFI artifact ${artifact_dir} is missing target ${target}; rebuilding."
      return 1
    fi
  done
  return 0
}

artifact_family_satisfies_requested_build() {
  local artifact_dir
  for artifact_dir in "$@"; do
    if [[ -d "$artifact_dir" ]] && artifact_matches_requested_build "$artifact_dir"; then
      return 0
    fi
  done
  return 1
}

artifacts_satisfy_requested_targets() {
  if [[ "$needs_ios_xcframework" == "1" ]] && ! artifact_family_satisfies_requested_build "$ios_xcframework"; then
    return 1
  fi
  if [[ "$needs_macos_xcframework" == "1" ]] && ! artifact_family_satisfies_requested_build "$macos_xcframework" "$legacy_xcframework"; then
    return 1
  fi
  return 0
}

if artifacts_satisfy_requested_targets; then
  echo ">>> Using existing ${requested_profile} Signal FFI XCFramework artifacts for requested targets."
  exit 0
fi

if [[ -f "$repo_root/.gitmodules" ]] && command -v git >/dev/null 2>&1; then
  bash "$repo_root/scripts/ci/update-submodules-with-retry.sh" Vendor/libsignal
fi

if [[ ! -d "$libsignal_dir" ]]; then
  echo "Missing $libsignal_dir; initialize Vendor/libsignal before running Xcode tests." >&2
  exit 1
fi

if [[ ! -x "$build_script" ]]; then
  echo "Missing executable build script: $build_script" >&2
  exit 1
fi

if ! command -v protoc >/dev/null 2>&1; then
  echo "Missing protoc; install protobuf before running Xcode libsignal tests." >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1 && [[ ! -x "$HOME/.cargo/bin/cargo" ]]; then
  echo "Missing cargo; install Rust before running Xcode libsignal tests." >&2
  exit 1
fi

echo ">>> Building ${requested_profile} Signal FFI XCFramework artifacts for Xcode tests."
build_environment=(
  "SIGNAL_FFI_BUILD_PROFILE=${requested_profile}"
  "CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-2}"
)
if [[ -n "$signal_ffi_build_root" ]]; then
  build_environment+=("SIGNAL_FFI_BUILD_ROOT=${signal_ffi_build_root}")
fi
if [[ -n "$signal_ffi_cargo_target_root" ]]; then
  build_environment+=("SIGNAL_FFI_CARGO_TARGET_ROOT=${signal_ffi_cargo_target_root}")
fi
env "${build_environment[@]}" bash "$build_script"
