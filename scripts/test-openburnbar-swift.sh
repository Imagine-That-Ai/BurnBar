#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=scripts/lib/libsignal-swift-compat.sh
source "${repo_root}/scripts/lib/libsignal-swift-compat.sh"

cleanup() {
  local original_status="${1:-0}"
  local restore_status=0
  openburnbar_restore_libsignal_swift_compat || restore_status=$?
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

# When the focused domain-core consumer job requires the native Rust domain-core
# artifact but does NOT need libsignal, skip building libsignal-ffi entirely and
# gate the local LibSignalClient Swift package out of the package graph. This
# prevents two Rust staticlibs (domain-core + libsignal) from colliding on
# `_rust_eh_personality` at link time. Full-app CI gates still exercise libsignal.
if [[ "${OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE:-}" == "1" ]]; then
  export OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE=1
fi

prepare_libsignal_ffi() {
  local libsignal_dir="${repo_root}/Vendor/libsignal"
  local host_target

  # These compatibility rewrites are required even when the XCFramework cache
  # hits: the cached binary does not include SwiftPM source compatibility, and
  # a warm cache must behave exactly like a cold build. The shared helper
  # checksum-binds the edits, serializes concurrent builds, and restores the
  # public submodule byte-for-byte on exit.
  openburnbar_prepare_libsignal_swift_compat "${repo_root}"

  case "$(uname -m)" in
    arm64) host_target="aarch64-apple-darwin" ;;
    x86_64) host_target="x86_64-apple-darwin" ;;
    *)
      echo "Unsupported macOS architecture for Signal FFI: $(uname -m)" >&2
      exit 1
      ;;
  esac

  # An existing XCFramework directory is not proof of health: several CI
  # workflows share the Signal FFI cache key, and single-target writers (the
  # CodeQL Swift lanes build x86_64-only) can populate it with an artifact the
  # host architecture cannot link. Delegate to the shared preparer, which
  # validates the target/profile metadata embedded by
  # build-signal-ffi-xcframework.sh and rebuilds on any mismatch. The rebuild
  # path reuses the production builder's reviewed cdylib/XCFramework flow:
  # macOS must not link libsignal and domain-core as two Rust static archives,
  # because both bundle Rust std and collide on symbols such as
  # rust_eh_personality.
  SIGNAL_FFI_BUILD_TARGETS="${host_target}" \
  SIGNAL_FFI_BUILD_PROFILE=debug \
  CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
  MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    bash "${repo_root}/scripts/lib/prepare-signal-ffi-xcframework.sh"
}

coverage_flags=()
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
  coverage_flags+=(--enable-code-coverage)
fi

swiftpm_has_build_metadata() {
  local scratch_path="$1"
  local marker

  for marker in \
    build.db \
    debug.yaml \
    release.yaml \
    description.json
  do
    if find "$scratch_path" -maxdepth 6 -type f -name "$marker" -print -quit | grep -q .; then
      return 0
    fi
  done

  if find "$scratch_path" -maxdepth 6 -type d \
    \( -name '*.build' -o -name Intermediates.noindex \) \
    -print -quit | grep -q .
  then
    return 0
  fi

  return 1
}

if [[ "${OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE:-}" != "1" ]]; then
  prepare_libsignal_ffi
fi

run_swift_tests() {
  local package_path="$1"
  local filter="${2:-}"
  local args=(--package-path "$package_path")
  local scratch_path=""

  case "$package_path" in
    "$repo_root/OpenBurnBarCore")
      scratch_path="${OPENBURNBAR_CORE_SWIFT_SCRATCH_PATH:-}"
      ;;
    "$repo_root/OpenBurnBarDaemon")
      scratch_path="${OPENBURNBAR_DAEMON_SWIFT_SCRATCH_PATH:-}"
      ;;
  esac

  if [[ -n "$scratch_path" ]]; then
    mkdir -p "$scratch_path"
    args+=(--scratch-path "$scratch_path")
  fi

  if ((${#coverage_flags[@]})); then
    args+=("${coverage_flags[@]}")
  fi
  if [[ -n "$filter" ]]; then
    args+=(--filter "$filter")
  fi

  if [[ "$package_path" == "$repo_root/OpenBurnBarDaemon" ]]; then
    local resolved_scratch_path="${scratch_path:-${package_path}/.build}"
    local had_build_metadata=0
    local package_args=(
      --package-path "$package_path"
      --scratch-path "$resolved_scratch_path"
    )
    local build_args=(--package-path "$package_path" --build-tests)
    local show_bin_args=(--package-path "$package_path" --show-bin-path)
    local sqlcipher_framework_relpath="artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework/macos-arm64_x86_64/SQLCipher.framework"

    mkdir -p "$resolved_scratch_path"
    if swiftpm_has_build_metadata "$resolved_scratch_path"; then
      had_build_metadata=1
    fi

    build_args+=(--scratch-path "$resolved_scratch_path")
    show_bin_args+=(--scratch-path "$resolved_scratch_path")
    if ((${#coverage_flags[@]})); then
      build_args+=("${coverage_flags[@]}")
    fi

    if [[ ! -f "$resolved_scratch_path/workspace-state.json" ]] \
      || [[ ! -d "$resolved_scratch_path/$sqlcipher_framework_relpath" ]]
    then
      swift package "${package_args[@]}" \
        --only-use-versions-from-resolved-file \
        resolve
    fi

    local bin_path
    bin_path="$(swift build "${show_bin_args[@]}")"

    local stage_args=(
      --package-path "$package_path"
      --scratch-path "$resolved_scratch_path"
      --bin-path "$bin_path"
    )
    local staging_plan
    staging_plan="$(
      python3 "$repo_root/scripts/lib/stage_sqlcipher_framework.py" \
        "${stage_args[@]}" \
        --plan-only
    )"
    case "$staging_plan" in
      retained | install-required) ;;
      *)
        echo "Unexpected SQLCipher staging plan: ${staging_plan}" >&2
        exit 1
        ;;
    esac

    if [[ "$staging_plan" == "install-required" ]] \
      && [[ "$had_build_metadata" == "1" ]]
    then
      echo "SQLCipher changed in an existing SwiftPM scratch tree; cleaning that exact build graph before staging."
      swift package "${package_args[@]}" clean
      bin_path="$(swift build "${show_bin_args[@]}")"
      stage_args=(
        --package-path "$package_path"
        --scratch-path "$resolved_scratch_path"
        --bin-path "$bin_path"
      )
    fi

    if [[ -n "${OPENBURNBAR_SQLCIPHER_STAGE_REPORT:-}" ]]; then
      stage_args+=(--report-path "$OPENBURNBAR_SQLCIPHER_STAGE_REPORT")
    fi
    python3 "$repo_root/scripts/lib/stage_sqlcipher_framework.py" "${stage_args[@]}"

    swift build "${build_args[@]}"

    # SwiftPM owns the product directory. Re-verify after compilation so a
    # toolchain that removes PackageFrameworks cannot produce an un-runnable
    # XCTest bundle; an unchanged destination is retained byte-for-byte.
    python3 "$repo_root/scripts/lib/stage_sqlcipher_framework.py" "${stage_args[@]}"

    swift test "${args[@]}" --skip-build
    return
  fi

  swift test "${args[@]}"
}

# OPENBURNBAR_SKIP_CORE_SWIFT_TESTS=1 runs the daemon package on its own — the
# symmetric counterpart to OPENBURNBAR_SKIP_DAEMON_SWIFT_TESTS, used by the
# focused daemon PR gate so daemon correctness blocks merges without paying for
# the full Core suite on every PR.
if [[ "${OPENBURNBAR_SKIP_CORE_SWIFT_TESTS:-}" != "1" ]]; then
  run_swift_tests "$repo_root/OpenBurnBarCore" "${OPENBURNBAR_CORE_SWIFT_FILTER:-}"
fi
if [[ "${OPENBURNBAR_SKIP_DAEMON_SWIFT_TESTS:-}" != "1" ]]; then
  run_swift_tests "$repo_root/OpenBurnBarDaemon" "${OPENBURNBAR_DAEMON_SWIFT_FILTER:-}"
fi
