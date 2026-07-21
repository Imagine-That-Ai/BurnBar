#!/usr/bin/env bash
# Build OpenBurnBar Signal FFI XCFrameworks from the vendored libsignal FFI.
#
# Usage:
#   ./scripts/build-signal-ffi-xcframework.sh
#   SIGNAL_FFI_SKIP_BUILD=1 ./scripts/build-signal-ffi-xcframework.sh
#   SIGNAL_FFI_BUILD_TARGETS="aarch64-apple-darwin x86_64-apple-darwin" ./scripts/build-signal-ffi-xcframework.sh
#   SIGNAL_FFI_RUST_TOOLCHAIN=1.94.0 ./scripts/build-signal-ffi-xcframework.sh
#   SIGNAL_FFI_BUILD_ROOT=/absolute/scratch/ffi-build ./scripts/build-signal-ffi-xcframework.sh
#   SIGNAL_FFI_CARGO_TARGET_ROOT=/absolute/scratch/ffi-target ./scripts/build-signal-ffi-xcframework.sh
#   SIGNAL_FFI_PRUNE_CARGO_TARGETS=1 SIGNAL_FFI_CARGO_TARGET_ROOT=/absolute/scratch/ffi-target ./scripts/build-signal-ffi-xcframework.sh
#   OPENBURNBAR_MOBILE_PRUNE_SIGNAL_FFI_CARGO_TARGETS=1 ...
#
# Output:
#   Vendor/OpenBurnBarSignalFfiIOS.xcframework/
#   Vendor/OpenBurnBarSignalFfiMac.xcframework/
#
# The Swift libsignal package links a library named `signal_ffi`. iOS must use
# a static library so App Store archives never embed a loose libsignal_ffi.dylib
# in Payload/*.app/Frameworks. macOS must stay dynamic because static libsignal
# duplicates Rust and BoringSSL symbols with iroh/gRPC in the app link.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBSIGNAL_DIR="${ROOT_DIR}/Vendor/libsignal"
VENDOR_DIR="${ROOT_DIR}/Vendor"
LEGACY_XCFRAMEWORK="${VENDOR_DIR}/OpenBurnBarSignalFfi.xcframework"
IOS_XCFRAMEWORK="${VENDOR_DIR}/OpenBurnBarSignalFfiIOS.xcframework"
MACOS_XCFRAMEWORK="${VENDOR_DIR}/OpenBurnBarSignalFfiMac.xcframework"
BUILD_DIR="${ROOT_DIR}/build/signal-ffi-xcframework"

log() { printf '[signal-ffi-xcframework] %s\n' "$*"; }

abort() {
  echo "[signal-ffi-xcframework] FATAL: $*" >&2
  exit 1
}

# The build and cargo target roots are intentionally independent: the former
# contains small XCFramework staging helpers, while the latter can contain
# several gigabytes of Rust intermediates.  Keeping both configurable lets a
# physical-device XCTest run put all transient state under its caller-owned
# scratch directory without changing the historical defaults.
if [[ "${SIGNAL_FFI_BUILD_ROOT+x}" == "x" ]]; then
  [[ -n "${SIGNAL_FFI_BUILD_ROOT}" ]] || {
    echo "[signal-ffi-xcframework] FATAL: SIGNAL_FFI_BUILD_ROOT cannot be empty" >&2
    exit 64
  }
  BUILD_DIR="${SIGNAL_FFI_BUILD_ROOT}"
elif [[ "${OPENBURNBAR_SIGNAL_FFI_BUILD_ROOT+x}" == "x" ]]; then
  [[ -n "${OPENBURNBAR_SIGNAL_FFI_BUILD_ROOT}" ]] || {
    echo "[signal-ffi-xcframework] FATAL: OPENBURNBAR_SIGNAL_FFI_BUILD_ROOT cannot be empty" >&2
    exit 64
  }
  BUILD_DIR="${OPENBURNBAR_SIGNAL_FFI_BUILD_ROOT}"
fi
if [[ "${SIGNAL_FFI_CARGO_TARGET_ROOT+x}" == "x" ]]; then
  [[ -n "${SIGNAL_FFI_CARGO_TARGET_ROOT}" ]] || {
    echo "[signal-ffi-xcframework] FATAL: SIGNAL_FFI_CARGO_TARGET_ROOT cannot be empty" >&2
    exit 64
  }
  CARGO_TARGET_DIR="${SIGNAL_FFI_CARGO_TARGET_ROOT}"
elif [[ "${OPENBURNBAR_SIGNAL_FFI_CARGO_TARGET_ROOT+x}" == "x" ]]; then
  [[ -n "${OPENBURNBAR_SIGNAL_FFI_CARGO_TARGET_ROOT}" ]] || {
    echo "[signal-ffi-xcframework] FATAL: OPENBURNBAR_SIGNAL_FFI_CARGO_TARGET_ROOT cannot be empty" >&2
    exit 64
  }
  CARGO_TARGET_DIR="${OPENBURNBAR_SIGNAL_FFI_CARGO_TARGET_ROOT}"
else
  CARGO_TARGET_DIR="${LIBSIGNAL_DIR}/target"
fi

validate_absolute_root() {
  local label="$1"
  local path="$2"
  [[ "${path}" == /* ]] || abort "${label} must be an absolute path: ${path}"
  # Resolve existing symlink components before any child is created. This
  # prevents a caller-provided scratch path from silently redirecting build
  # intermediates outside the path they asked us to own.
  local canonical
  # These snippets use only the standard library.  Skip user/site hooks so a
  # concurrent Rust build cannot be interrupted by an unrelated editable
  # Python package on the developer machine.
  canonical="$(python3 -S - "${path}" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
  [[ "${canonical}" == /* ]] || abort "${label} resolved to a non-absolute path"
  printf '%s\n' "${canonical}"
}

BUILD_DIR="$(validate_absolute_root SIGNAL_FFI_BUILD_ROOT "${BUILD_DIR}")"
CARGO_TARGET_DIR="$(validate_absolute_root SIGNAL_FFI_CARGO_TARGET_ROOT "${CARGO_TARGET_DIR}")"

if [[ "${SIGNAL_FFI_PRUNE_CARGO_TARGETS+x}" != "x" &&
      "${OPENBURNBAR_MOBILE_PRUNE_SIGNAL_FFI_CARGO_TARGETS+x}" == "x" ]]; then
  SIGNAL_FFI_PRUNE_CARGO_TARGETS="${OPENBURNBAR_MOBILE_PRUNE_SIGNAL_FFI_CARGO_TARGETS}"
else
  SIGNAL_FFI_PRUNE_CARGO_TARGETS="${SIGNAL_FFI_PRUNE_CARGO_TARGETS:-0}"
fi
case "${SIGNAL_FFI_PRUNE_CARGO_TARGETS}" in
  0 | 1) ;;
  *)
    echo "[signal-ffi-xcframework] FATAL: invalid SIGNAL_FFI_PRUNE_CARGO_TARGETS=${SIGNAL_FFI_PRUNE_CARGO_TARGETS}; expected 0 or 1" >&2
    exit 64
    ;;
esac
if [[ "${SIGNAL_FFI_PRUNE_CARGO_TARGETS}" == "1" &&
      "${SIGNAL_FFI_CARGO_TARGET_ROOT+x}" != "x" &&
      "${OPENBURNBAR_SIGNAL_FFI_CARGO_TARGET_ROOT+x}" != "x" ]]; then
  echo "[signal-ffi-xcframework] FATAL: SIGNAL_FFI_PRUNE_CARGO_TARGETS=1 requires an explicit Cargo target root" >&2
  exit 64
fi

# The pruning mode is intentionally opt-in and only accepts an explicit target
# root. Physical-device callers can therefore prove that generated Cargo
# intermediates stay in their owned scratch directory before enabling removal.
source "${ROOT_DIR}/scripts/lib/signal-ffi-cargo-cleanup.sh"
ARCHS_DIR="${BUILD_DIR}/archs"
HEADERS_DIR="${BUILD_DIR}/Headers"
EXPORTS_FILE="${BUILD_DIR}/signal_ffi.exports"
MACHO_REPAIR_TOOL="${BUILD_DIR}/repair_macho_linkedit_alignment.py"
RUSTC_WRAPPER_SCRIPT="${BUILD_DIR}/rustc-wrapper.sh"
METADATA_FILE_NAME=".openburnbar-signal-ffi-build.env"

PROFILE="${SIGNAL_FFI_BUILD_PROFILE:-release}"
case "${PROFILE}" in
  debug)
    PROFILE_FLAG=""
    PROFILE_DIR="debug"
    ;;
  release)
    PROFILE_FLAG="--release"
    PROFILE_DIR="release"
    ;;
  *)
    echo "[signal-ffi-xcframework] FATAL: invalid SIGNAL_FFI_BUILD_PROFILE=${PROFILE}; expected debug or release" >&2
    exit 64
    ;;
esac

DEFAULT_TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)
if [[ -n "${SIGNAL_FFI_BUILD_TARGETS:-}" ]]; then
  # shellcheck disable=SC2206
  TARGETS=(${SIGNAL_FFI_BUILD_TARGETS})
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi
if [[ "${SIGNAL_FFI_PRUNE_CARGO_TARGETS}" == "1" ]]; then
  for target in "${TARGETS[@]}"; do
    case "${target}" in
      aarch64-apple-darwin | x86_64-apple-darwin | aarch64-apple-ios | aarch64-apple-ios-sim | x86_64-apple-ios) ;;
      *)
        echo "[signal-ffi-xcframework] FATAL: pruning mode does not support unknown target ${target}" >&2
        exit 64
        ;;
    esac
  done
fi

write_build_metadata() {
  local xcframework="$1"
  [[ -d "${xcframework}" ]] || return 0
  {
    printf 'profile=%s\n' "${PROFILE}"
    printf 'targets=%s\n' "${TARGETS[*]}"
  } > "${xcframework}/${METADATA_FILE_NAME}"
}

write_build_metadata() {
  local xcframework="$1"
  [[ -d "${xcframework}" ]] || return 0
  {
    printf 'profile=%s\n' "${PROFILE}"
    printf 'targets=%s\n' "${TARGETS[*]}"
  } > "${xcframework}/${METADATA_FILE_NAME}"
}

[[ -d "${LIBSIGNAL_DIR}" ]] || abort "missing ${LIBSIGNAL_DIR}; clone libsignal v0.94.4 first"
[[ -x "/usr/bin/xcodebuild" ]] || abort "xcodebuild is required"
[[ -x "/usr/bin/lipo" ]] || abort "lipo is required"

if [[ -x "${HOME}/.cargo/bin/rustup" ]]; then
  RUSTUP_BIN="${HOME}/.cargo/bin/rustup"
else
  RUSTUP_BIN="$(command -v rustup || true)"
fi
[[ -x "${RUSTUP_BIN}" ]] || abort "rustup not found in PATH"

if [[ -x "${HOME}/.cargo/bin/cargo" ]]; then
  CARGO_BIN="${HOME}/.cargo/bin/cargo"
else
  CARGO_BIN="$(command -v cargo || true)"
fi
[[ -x "${CARGO_BIN}" ]] || abort "cargo not found in PATH"

RUST_TOOLCHAIN="${SIGNAL_FFI_RUST_TOOLCHAIN:-stable}"
[[ -n "${RUST_TOOLCHAIN}" ]] || abort "SIGNAL_FFI_RUST_TOOLCHAIN cannot be empty"

write_macho_repair_tool() {
  mkdir -p "${BUILD_DIR}"
  cat > "${MACHO_REPAIR_TOOL}" <<'PY'
import struct
import subprocess
import sys

for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        data = bytearray(handle.read())

    # Xcode 27's linker rejects dylibs whose LINKEDIT string pool is not
    # 8-byte aligned. Rust proc-macro dylibs can hit the same issue before the
    # final libsignal cdylib is staged, so repair generated dylibs immediately.
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        continue

    _, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    offset = 32
    symtab_offset = None
    linkedit_offset = None
    codesig_offset = None
    string_offset = None

    for _ in range(ncmds):
        command, command_size = struct.unpack_from("<II", data, offset)
        if command == 0x19:  # LC_SEGMENT_64
            segment_name = struct.unpack_from("<16s", data, offset + 8)[0].rstrip(b"\0")
            if segment_name == b"__LINKEDIT":
                linkedit_offset = offset
        elif command == 0x2:  # LC_SYMTAB
            symtab_offset = offset
            _, _, string_offset, _ = struct.unpack_from("<IIII", data, offset + 8)
        elif command == 0x1D:  # LC_CODE_SIGNATURE
            codesig_offset = offset
        offset += command_size

    if symtab_offset is None or string_offset is None:
        continue

    string_padding = (-string_offset) % 8
    insertions = []
    if string_padding:
        insertions.append((string_offset, string_padding))
        struct.pack_into("<I", data, symtab_offset + 16, string_offset + string_padding)

    if codesig_offset is not None:
        signature_offset, _ = struct.unpack_from("<II", data, codesig_offset + 8)
        shifted_signature_offset = signature_offset
        if string_padding and signature_offset >= string_offset:
            shifted_signature_offset += string_padding
        signature_padding = (-shifted_signature_offset) % 16
        if signature_padding:
            insertions.append((signature_offset, signature_padding))
        struct.pack_into(
            "<I",
            data,
            codesig_offset + 8,
            shifted_signature_offset + signature_padding,
        )

    if linkedit_offset is not None:
        linkedit_file_offset, linkedit_size = struct.unpack_from("<QQ", data, linkedit_offset + 40)
        inserted_size = sum(size for where, size in insertions if where >= linkedit_file_offset)
        if inserted_size:
            struct.pack_into("<Q", data, linkedit_offset + 48, linkedit_size + inserted_size)

    if not insertions:
        continue

    for where, size in sorted(insertions, reverse=True):
        data[where:where] = b"\0" * size

    with open(path, "wb") as handle:
        handle.write(data)

    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", path],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
PY
}

write_rustc_wrapper() {
  write_macho_repair_tool
  cat > "${RUSTC_WRAPPER_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repair_tool="${OPENBURNBAR_SIGNAL_FFI_MACHO_REPAIR_TOOL:?}"
real_rustc="$1"
shift

set +e
"${real_rustc}" "$@"
status=$?
set -e
if [[ "${status}" -ne 0 ]]; then
  exit "${status}"
fi

args=("$@")
crate_name=""
out_dir=""
for ((index = 0; index < ${#args[@]}; index++)); do
  case "${args[$index]}" in
    --crate-name)
      if (( index + 1 < ${#args[@]} )); then
        crate_name="${args[$((index + 1))]}"
      fi
      ;;
    --out-dir)
      if (( index + 1 < ${#args[@]} )); then
        out_dir="${args[$((index + 1))]}"
      fi
      ;;
  esac
done

if [[ -z "${crate_name}" || -z "${out_dir}" || ! -d "${out_dir}" ]]; then
  exit 0
fi

safe_crate_name="${crate_name//-/_}"
shopt -s nullglob
for dylib in "${out_dir}/lib${safe_crate_name}"*.dylib; do
  python3 -S "${repair_tool}" "${dylib}"
done
EOF
  chmod +x "${RUSTC_WRAPPER_SCRIPT}"
}

ensure_rust_target() {
  local target="$1"
  if ! "${RUSTUP_BIN}" "+${RUST_TOOLCHAIN}" target list --installed | grep -q "^${target}$"; then
    log "installing rust target ${target}"
    "${RUSTUP_BIN}" "+${RUST_TOOLCHAIN}" target add "${target}"
  fi
}

build_target() {
  local target="$1"
  local features="log/release_max_level_info"
  local crate_type="staticlib"
  local exports_dynamic_symbols=0
  if [[ "${target}" != "aarch64-apple-ios" ]]; then
    features="libsignal-bridge-testing ${features}"
  fi
  if [[ "${target}" == *"-apple-darwin" ]]; then
    crate_type="cdylib"
    exports_dynamic_symbols=1
  fi
  local rustc_args=(--crate-type "${crate_type}")
  if [[ "${exports_dynamic_symbols}" == "1" ]]; then
    rustc_args+=(
      -C "link-arg=-Wl,-install_name,@rpath/libsignal_ffi.dylib"
      -C "link-arg=-Wl,-exported_symbols_list,${EXPORTS_FILE}"
    )
  fi
  ensure_rust_target "${target}"
  log "cargo +${RUST_TOOLCHAIN} rustc ${PROFILE} ${target} (${crate_type})"
  (
    cd "${LIBSIGNAL_DIR}"
    CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
    CARGO_TARGET_DIR="${CARGO_TARGET_DIR}" \
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    IPHONE_SIMULATOR_DEPLOYMENT_TARGET=17.0 \
    OPENBURNBAR_SIGNAL_FFI_MACHO_REPAIR_TOOL="${MACHO_REPAIR_TOOL}" \
    RUSTC_WRAPPER="${RUSTC_WRAPPER_SCRIPT}" \
    PATH="${HOME}/.cargo/bin:${PATH}" \
      "${CARGO_BIN}" "+${RUST_TOOLCHAIN}" rustc \
        -p libsignal-ffi \
        ${PROFILE_FLAG} \
        --target "${target}" \
        --features "${features}" \
        -- "${rustc_args[@]}"
  )
}

latest_target_dylib() {
  local target="$1"
  local dir="${CARGO_TARGET_DIR}/${target}/${PROFILE_DIR}/deps"
  [[ -d "${dir}" ]] || abort "missing build output dir ${dir}"
  local dylib
  dylib="$(
    find "${dir}" -maxdepth 1 -type f -name 'libsignal_ffi-*.dylib' -exec stat -f '%m %N' {} + 2>/dev/null \
      | sort -rn \
      | head -n 1 \
      | cut -d' ' -f2-
  )"
  [[ -f "${dylib}" ]] || abort "missing libsignal_ffi dylib for ${target}"
  printf '%s\n' "${dylib}"
}

latest_target_staticlib() {
  local target="$1"
  local lib="${CARGO_TARGET_DIR}/${target}/${PROFILE_DIR}/libsignal_ffi.a"
  [[ -f "${lib}" ]] || abort "missing libsignal_ffi static library for ${target}"
  printf '%s\n' "${lib}"
}

stage_headers() {
  rm -rf "${HEADERS_DIR}"
  mkdir -p "${HEADERS_DIR}"
  cat > "${HEADERS_DIR}/OpenBurnBarSignalFfi.h" <<'EOF'
void OpenBurnBarSignalFfiLinkAnchor(void);
EOF
}

stage_static_target() {
  local target="$1"
  local platform_id="$2"
  local staticlib
  staticlib="$(latest_target_staticlib "${target}")"
  local out_dir="${ARCHS_DIR}/${platform_id}"
  mkdir -p "${out_dir}/Headers"
  cp "${staticlib}" "${out_dir}/libsignal_ffi.a"
  cp "${HEADERS_DIR}/"* "${out_dir}/Headers/"
}

stage_exports() {
  mkdir -p "${BUILD_DIR}"
  printf '_signal_*\n' > "${EXPORTS_FILE}"
  log "exporting public Signal FFI symbols only for dynamic macOS slices"
}

repair_macho_linkedit_alignment() {
  local dylib="$1"
  python3 -S - "${dylib}" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, "rb") as handle:
    data = bytearray(handle.read())

# Xcode 27's linker rejects dylibs whose LINKEDIT string pool is not
# 8-byte aligned. The Rust-produced libsignal cdylib can land the
# LC_SYMTAB string table on a 4-byte boundary after export pruning.
if struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
    sys.exit(0)

_, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
offset = 32
symtab_offset = None
linkedit_offset = None
codesig_offset = None
string_offset = None

for _ in range(ncmds):
    command, command_size = struct.unpack_from("<II", data, offset)
    if command == 0x19:  # LC_SEGMENT_64
        segment_name = struct.unpack_from("<16s", data, offset + 8)[0].rstrip(b"\0")
        if segment_name == b"__LINKEDIT":
            linkedit_offset = offset
    elif command == 0x2:  # LC_SYMTAB
        symtab_offset = offset
        _, _, string_offset, _ = struct.unpack_from("<IIII", data, offset + 8)
    elif command == 0x1D:  # LC_CODE_SIGNATURE
        codesig_offset = offset
    offset += command_size

if symtab_offset is None or string_offset is None:
    sys.exit(0)

string_padding = (-string_offset) % 8
insertions = []
if string_padding:
    insertions.append((string_offset, string_padding))
    struct.pack_into("<I", data, symtab_offset + 16, string_offset + string_padding)

if codesig_offset is not None:
    signature_offset, _ = struct.unpack_from("<II", data, codesig_offset + 8)
    shifted_signature_offset = signature_offset
    if string_padding and signature_offset >= string_offset:
        shifted_signature_offset += string_padding
    signature_padding = (-shifted_signature_offset) % 16
    if signature_padding:
        insertions.append((signature_offset, signature_padding))
    struct.pack_into(
        "<I",
        data,
        codesig_offset + 8,
        shifted_signature_offset + signature_padding,
    )

if linkedit_offset is not None:
    linkedit_file_offset, linkedit_size = struct.unpack_from("<QQ", data, linkedit_offset + 40)
    inserted_size = sum(size for where, size in insertions if where >= linkedit_file_offset)
    if inserted_size:
        struct.pack_into("<Q", data, linkedit_offset + 48, linkedit_size + inserted_size)

for where, size in sorted(insertions, reverse=True):
    data[where:where] = b"\0" * size

if insertions:
    with open(path, "wb") as handle:
        handle.write(data)
PY
}

stage_dynamic_target() {
  local target="$1"
  local platform_id="$2"
  local dylib
  dylib="$(latest_target_dylib "${target}")"
  local out_dir="${ARCHS_DIR}/${platform_id}"
  mkdir -p "${out_dir}/Headers"
  cp "${dylib}" "${out_dir}/libsignal_ffi.dylib"
  repair_macho_linkedit_alignment "${out_dir}/libsignal_ffi.dylib"
  cp "${HEADERS_DIR}/"* "${out_dir}/Headers/"
}

# Pruned builds stage each slice before deleting its Cargo target directory.
# The final packaging pass must reuse those staged files instead of asking
# Cargo for outputs that have intentionally been removed.
stage_dynamic_target_if_needed() {
  [[ "${pruned_staging_ready:-0}" == "1" ]] || stage_dynamic_target "$@"
}

stage_static_target_if_needed() {
  [[ "${pruned_staging_ready:-0}" == "1" ]] || stage_static_target "$@"
}

stage_built_target_for_pruned_build() {
  local target="$1"
  case "${target}" in
    aarch64-apple-darwin) stage_dynamic_target "${target}" macos-arm64 ;;
    x86_64-apple-darwin) stage_dynamic_target "${target}" macos-x86_64 ;;
    aarch64-apple-ios) stage_static_target "${target}" ios-arm64 ;;
    aarch64-apple-ios-sim) stage_static_target "${target}" ios-arm64-simulator ;;
    x86_64-apple-ios) stage_static_target "${target}" ios-x86_64-simulator ;;
    *)
      echo "[signal-ffi-xcframework] FATAL: cannot stage unknown target ${target} in pruning mode" >&2
      return 64
      ;;
  esac
}

validate_staged_target_for_pruned_build() {
  local target="$1"
  local platform_id
  local library_name
  case "${target}" in
    aarch64-apple-darwin) platform_id=macos-arm64; library_name=libsignal_ffi.dylib ;;
    x86_64-apple-darwin) platform_id=macos-x86_64; library_name=libsignal_ffi.dylib ;;
    aarch64-apple-ios) platform_id=ios-arm64; library_name=libsignal_ffi.a ;;
    aarch64-apple-ios-sim) platform_id=ios-arm64-simulator; library_name=libsignal_ffi.a ;;
    x86_64-apple-ios) platform_id=ios-x86_64-simulator; library_name=libsignal_ffi.a ;;
    *)
      echo "[signal-ffi-xcframework] FATAL: cannot validate unknown target ${target} in pruning mode" >&2
      return 64
      ;;
  esac
  local staged_dir="${ARCHS_DIR}/${platform_id}"
  [[ -s "${staged_dir}/${library_name}" ]] || {
    echo "[signal-ffi-xcframework] FATAL: staged Signal FFI slice is missing ${library_name} for ${target}" >&2
    return 64
  }
  [[ -f "${staged_dir}/Headers/OpenBurnBarSignalFfi.h" ]] || {
    echo "[signal-ffi-xcframework] FATAL: staged Signal FFI headers are missing for ${target}" >&2
    return 64
  }
}

prepare_pruned_staging_dirs() {
  mkdir -p "${VENDOR_DIR}"
  rm -rf "${ARCHS_DIR}" "${LEGACY_XCFRAMEWORK}" "${IOS_XCFRAMEWORK}" "${MACOS_XCFRAMEWORK}"
  mkdir -p "${ARCHS_DIR}"
  stage_headers
}

stage_exports

write_rustc_wrapper

pruned_staging_ready=0
if [[ "${SIGNAL_FFI_SKIP_BUILD:-0}" != "1" ]]; then
  if [[ "${SIGNAL_FFI_PRUNE_CARGO_TARGETS}" == "1" ]]; then
    # Stage each slice before deleting its target-specific Cargo directory.
    # This keeps the final packaging path identical while bounding peak disk
    # usage for physical-device builds that compile several architectures.
    prepare_pruned_staging_dirs
    pruned_staging_ready=1
    for target in "${TARGETS[@]}"; do
      build_target "${target}"
      stage_built_target_for_pruned_build "${target}"
      validate_staged_target_for_pruned_build "${target}"
      if ! signal_ffi_prune_cargo_target_dir "${CARGO_TARGET_DIR}" "${target}"; then
        echo "[signal-ffi-xcframework] FATAL: failed to prune Cargo output for ${target}" >&2
        exit 64
      fi
    done
    # Host proc-macro output is shared at target/{debug,release}. It is no
    # longer needed once every requested slice has been staged.
    if ! signal_ffi_prune_cargo_target_dir "${CARGO_TARGET_DIR}" "${PROFILE_DIR}"; then
      echo "[signal-ffi-xcframework] FATAL: failed to prune shared Cargo output ${PROFILE_DIR}" >&2
      exit 64
    fi
  else
    for target in "${TARGETS[@]}"; do
      build_target "${target}"
    done
  fi
else
  log "skipping cargo builds; packaging existing target outputs"
fi

if [[ "${pruned_staging_ready}" != "1" ]]; then
  mkdir -p "${VENDOR_DIR}"
  rm -rf "${ARCHS_DIR}" "${LEGACY_XCFRAMEWORK}" "${IOS_XCFRAMEWORK}" "${MACOS_XCFRAMEWORK}"
  mkdir -p "${ARCHS_DIR}"
  stage_headers
fi

ios_xcframework_args=()
macos_xcframework_args=()

macos_library_args=()
if [[ " ${TARGETS[*]} " == *" aarch64-apple-darwin "* ]]; then
  stage_dynamic_target_if_needed aarch64-apple-darwin macos-arm64
  macos_library_args+=("${ARCHS_DIR}/macos-arm64/libsignal_ffi.dylib")
fi
if [[ " ${TARGETS[*]} " == *" x86_64-apple-darwin "* ]]; then
  stage_dynamic_target_if_needed x86_64-apple-darwin macos-x86_64
  macos_library_args+=("${ARCHS_DIR}/macos-x86_64/libsignal_ffi.dylib")
fi
if [[ "${#macos_library_args[@]}" -eq 2 ]]; then
  macos_universal_dir="${ARCHS_DIR}/macos-universal"
  mkdir -p "${macos_universal_dir}/Headers"
  /usr/bin/lipo -create \
    "${ARCHS_DIR}/macos-arm64/libsignal_ffi.dylib" \
    "${ARCHS_DIR}/macos-x86_64/libsignal_ffi.dylib" \
    -output "${macos_universal_dir}/libsignal_ffi.dylib"
  cp "${HEADERS_DIR}/"* "${macos_universal_dir}/Headers/"
  macos_xcframework_args+=(-library "${macos_universal_dir}/libsignal_ffi.dylib" -headers "${macos_universal_dir}/Headers")
elif [[ "${#macos_library_args[@]}" -eq 1 ]]; then
  macos_platform_id="macos-arm64"
  if [[ " ${TARGETS[*]} " == *" x86_64-apple-darwin "* ]]; then
    macos_platform_id="macos-x86_64"
  fi
  macos_xcframework_args+=(-library "${ARCHS_DIR}/${macos_platform_id}/libsignal_ffi.dylib" -headers "${ARCHS_DIR}/${macos_platform_id}/Headers")
fi

if [[ " ${TARGETS[*]} " == *" aarch64-apple-ios "* ]]; then
  stage_static_target_if_needed aarch64-apple-ios ios-arm64
  ios_xcframework_args+=(-library "${ARCHS_DIR}/ios-arm64/libsignal_ffi.a" -headers "${ARCHS_DIR}/ios-arm64/Headers")
fi

if [[ " ${TARGETS[*]} " == *" aarch64-apple-ios-sim "* && " ${TARGETS[*]} " == *" x86_64-apple-ios "* ]]; then
  stage_static_target_if_needed aarch64-apple-ios-sim ios-arm64-simulator
  stage_static_target_if_needed x86_64-apple-ios ios-x86_64-simulator
  local_sim_dir="${ARCHS_DIR}/ios-simulator"
  mkdir -p "${local_sim_dir}/Headers"
  /usr/bin/lipo -create \
    "${ARCHS_DIR}/ios-arm64-simulator/libsignal_ffi.a" \
    "${ARCHS_DIR}/ios-x86_64-simulator/libsignal_ffi.a" \
    -output "${local_sim_dir}/libsignal_ffi.a"
  cp "${HEADERS_DIR}/"* "${local_sim_dir}/Headers/"
  ios_xcframework_args+=(-library "${local_sim_dir}/libsignal_ffi.a" -headers "${local_sim_dir}/Headers")
else
  if [[ " ${TARGETS[*]} " == *" aarch64-apple-ios-sim "* ]]; then
    stage_static_target_if_needed aarch64-apple-ios-sim ios-arm64-simulator
    ios_xcframework_args+=(-library "${ARCHS_DIR}/ios-arm64-simulator/libsignal_ffi.a" -headers "${ARCHS_DIR}/ios-arm64-simulator/Headers")
  fi
  if [[ " ${TARGETS[*]} " == *" x86_64-apple-ios "* ]]; then
    stage_static_target_if_needed x86_64-apple-ios ios-x86_64-simulator
    ios_xcframework_args+=(-library "${ARCHS_DIR}/ios-x86_64-simulator/libsignal_ffi.a" -headers "${ARCHS_DIR}/ios-x86_64-simulator/Headers")
  fi
fi

if [[ "${#macos_xcframework_args[@]}" -gt 0 ]]; then
  log "assembling ${MACOS_XCFRAMEWORK}"
  /usr/bin/xcodebuild -create-xcframework \
    "${macos_xcframework_args[@]}" \
    -output "${MACOS_XCFRAMEWORK}"
  write_build_metadata "${MACOS_XCFRAMEWORK}"
fi

if [[ "${#ios_xcframework_args[@]}" -gt 0 ]]; then
  log "assembling ${IOS_XCFRAMEWORK}"
  /usr/bin/xcodebuild -create-xcframework \
    "${ios_xcframework_args[@]}" \
    -output "${IOS_XCFRAMEWORK}"
  write_build_metadata "${IOS_XCFRAMEWORK}"
fi

if [[ "${#macos_xcframework_args[@]}" -eq 0 && "${#ios_xcframework_args[@]}" -eq 0 ]]; then
  abort "no XCFramework libraries staged"
fi

log "DONE: Signal FFI XCFrameworks"
